import Foundation
import CoreLocation
import Combine
import UIKit

/// Owns the CLLocationManager and turns its stream of fixes into saved points.
///
/// How the sampling works
/// - Core Location runs with best accuracy and a small distance filter (5 m), so while you
///   stand still iOS stops waking the app; while you move it delivers roughly one fix a second.
/// - Every `interval` seconds (15 by default) the recorder makes one save attempt, using the
///   newest fix, or a slightly older one from the last 3 s if it is more accurate.
/// - The attempt is dropped if the fix is within `minDistance` (20 m) of the previously saved
///   point, or if its accuracy is worse than `maxAccuracy`. With the drift guard on, a fix
///   must also have moved further than its own uncertainty.
/// - Saved points are appended to a CSV file immediately.
/// - When you stay in one place for a while, the GPS rests (StillnessDetector): Core Location
///   keeps running at cell-tower accuracy, which keeps the app alive exactly as before, and
///   the GPS comes back the moment the motion coprocessor, the step counter, a geofence or a
///   GPS check every 3 minutes says you're moving.
@MainActor
final class LocationRecorder: NSObject, ObservableObject {
    static let shared = LocationRecorder()

    struct Stats: Equatable {
        var attempts = 0
        var saved = 0
        var skippedTooClose = 0
        var skippedPoorAccuracy = 0
    }

    @Published private(set) var isRecording = false
    @Published private(set) var sessionName: String?
    @Published private(set) var sessionStart: Date?
    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var stats = Stats()
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var hasPreciseLocation = true
    /// Bumped whenever files on disk change, so lists can reload.
    @Published private(set) var libraryRevision = 0
    @Published var message: String?
    /// When the GPS started resting (nil while it's on).
    @Published private(set) var restingSince: Date?
    /// The last rest or wake, for the status card ("GPS woke at 14:02: 12 steps").
    @Published private(set) var restNote: String?

    private let manager = CLLocationManager()
    private let store = TrackStore.shared
    private var policy = SamplingPolicy.defaults
    private var writer: CSVAppender?
    private var sessionURL: URL?
    private var segment = 0
    private var lastSaved: CLLocation?
    private var latestFix: CLLocation?
    private var windowBest: CLLocation?
    private var nextAttemptAt = Date.distantPast
    private var updatesStartedAt = Date.distantPast
    private var startWhenAuthorized = false
    private let motion = MotionWatch()
    private var stillness: StillnessDetector?
    private var tickTimer: Timer?
    private static let restRegionID = "waytrace.resting"

    private enum Key {
        static let activeSession = "recorder.activeSession"
        static let askedForAlways = "recorder.askedForAlways"
    }

    private override init() {
        super.init()
        SamplingPolicy.registerDefaults()
        manager.delegate = self
        authorization = manager.authorizationStatus
        hasPreciseLocation = manager.accuracyAuthorization == .fullAccuracy
    }

    // MARK: - Buttons

    func record() {
        guard !isRecording else { return }
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            startWhenAuthorized = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            message = "Location access is off for Waytrace. Turn it on in Settings › Privacy & Security › Location Services."
        default:
            beginRecording()
        }
    }

    func stop() {
        guard isRecording else { return }
        stopRestWatch()
        stopUpdates()
        let finished = sessionURL
        closeWriter()
        sessionURL = nil
        UserDefaults.standard.removeObject(forKey: Key.activeSession)
        isRecording = false
        guard let finished else { return }
        if points.isEmpty {
            try? FileManager.default.removeItem(at: finished)
            libraryRevision += 1
        } else {
            annotateActivity(of: finished, thenMapDays: DailyPlan.days(of: points))
        }
        Backup.shared.backUp(reason: "recording stopped")
    }

    /// Called whenever the app comes to the foreground. Starting updates that are already
    /// running is harmless; it covers the case where they couldn't be started from the
    /// background (e.g. a relaunch with only "While Using" permission).
    func appBecameActive() {
        if isRecording {
            manager.startUpdatingLocation()
            // Resting? Take a sharp look so the screen shows where you really are.
            if let e = stillness?.checkNow(Date()) { handle(e) }
        } else {
            resumeIfNeeded()
        }
    }

    /// Re-runs the motion lookup for a finished recording (Core Motion keeps 7 days).
    func fillActivity(for session: TrackSession) {
        annotateActivity(of: session.url)
    }

    // MARK: - Relaunch

    /// Continues an interrupted recording: after iOS terminated the app and relaunched it
    /// for a significant location change, after a crash, or when the app is simply reopened.
    func resumeIfNeeded() {
        guard !isRecording,
              let fileName = UserDefaults.standard.string(forKey: Key.activeSession) else { return }
        let url = store.tracksDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: Key.activeSession)
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: return // keep the flag; authorizationChanged() retries when access returns
        }

        let existing = store.loadPoints(from: url)
        do {
            writer = try CSVAppender(url: url)
        } catch {
            message = "Couldn't reopen the track file: \(error.localizedDescription)"
            return
        }
        sessionURL = url
        sessionName = url.deletingPathExtension().lastPathComponent
        sessionStart = TrackStore.date(fromSessionName: sessionName ?? "") ?? existing.first?.time ?? Date()
        points = existing
        stats = Stats(saved: existing.count)
        segment = (existing.last?.segment ?? -1) + 1
        // The 20 m rule still applies against the last point saved before the interruption.
        lastSaved = existing.last.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        policy = SamplingPolicy.current
        startUpdates()
        isRecording = true
        startRestWatch()
    }

    // MARK: - Session files

    private func beginRecording() {
        policy = SamplingPolicy.current
        lastSaved = nil
        guard openSession(start: Date()) else { return }
        startUpdates()
        isRecording = true
        startRestWatch()
        requestAlwaysIfNeeded()
    }

    @discardableResult
    private func openSession(start: Date) -> Bool {
        let url = store.newSessionURL(start: start)
        do {
            writer = try CSVAppender(url: url)
        } catch {
            message = "Couldn't create a track file: \(error.localizedDescription)"
            return false
        }
        sessionURL = url
        sessionName = url.deletingPathExtension().lastPathComponent
        sessionStart = start
        points = []
        stats = Stats()
        segment = 0
        UserDefaults.standard.set(url.lastPathComponent, forKey: Key.activeSession)
        libraryRevision += 1
        return true
    }

    private func closeWriter() {
        writer?.close()
        writer = nil
    }

    /// With "New file each day" on, the first point saved after midnight starts a new file.
    private func rollOverIfNeeded(for date: Date) {
        guard policy.splitAtMidnight,
              let start = sessionStart,
              !Calendar.current.isDate(date, inSameDayAs: start) else { return }
        let finished = sessionURL
        let finishedDays = DailyPlan.days(of: points)
        closeWriter()
        openSession(start: Calendar.current.startOfDay(for: date))
        if let finished { annotateActivity(of: finished, thenMapDays: finishedDays) }
    }

    /// Fills in walking/driving labels, then (for a finished recording) queues its days for
    /// the automatic road map; the labels decide which trips are drives and which are walks.
    private func annotateActivity(of url: URL, thenMapDays days: [String] = []) {
        Task {
            let original = store.loadPoints(from: url)
            if !original.isEmpty, original.contains(where: { $0.activity == nil }) {
                let annotated = await MotionAnnotator.annotate(original)
                // Never touch the file that is currently being appended to.
                if annotated != original, url != sessionURL {
                    try? store.rewrite(annotated, to: url)
                }
            }
            libraryRevision += 1
            if !days.isEmpty { DailyRoads.shared.enqueue(days) }
        }
    }

    // MARK: - Resting the GPS while you stay put

    private func startRestWatch() {
        stopRestWatch()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { LocationRecorder.shared.tick() }
        }
        guard policy.restWhenStill else { return }
        var config = StillnessDetector.Config()
        config.restAfter = policy.restAfterMinutes * 60
        stillness = StillnessDetector(config: config, motionAvailable: MotionWatch.isAvailable, now: Date())
        motion.start(onActivity: { reading, at in
            LocationRecorder.shared.motionReading(reading, at: at)
        }, onSteps: { steps, at in
            LocationRecorder.shared.stepCount(steps, at: at)
        })
    }

    private func stopRestWatch() {
        tickTimer?.invalidate()
        tickTimer = nil
        motion.stop()
        if stillness?.isResting == true { setPrecise() }
        stillness = nil
        stopRestRegion()
        restingSince = nil
    }

    private func tick() {
        guard isRecording else { return }
        if let e = stillness?.tick(Date()) { handle(e) }
        Backup.shared.recordingTick()
    }

    private func motionReading(_ r: MotionReading, at t: Date) {
        if let e = stillness?.motion(r, at: t) { handle(e) }
    }

    private func stepCount(_ n: Int, at t: Date) {
        if let e = stillness?.steps(n, at: t) { handle(e) }
    }

    private func handle(_ event: StillnessDetector.Event) {
        let clock = Date().formatted(date: .omitted, time: .shortened)
        switch event {
        case .rest:
            setCoarse()
            restingSince = Date()
            restNote = "GPS resting since \(clock): you've stayed in one place."
            startRestRegion()
        case .startCheck:
            setPrecise()
        case .endCheck:
            setCoarse()
        case .wake(let reason):
            setPrecise()
            if let since = restingSince {
                let mins = Int(Date().timeIntervalSince(since) / 60)
                restNote = "GPS woke at \(clock) after resting \(mins) min (\(reason))."
            } else {
                restNote = "GPS woke at \(clock) (\(reason))."
            }
            restingSince = nil
            stopRestRegion()
            // Start sampling afresh: the next good fix is saved straight away.
            updatesStartedAt = Date()
            nextAttemptAt = .distantPast
            windowBest = nil
        }
    }

    /// GPS off; cell towers only. Location updates keep running (never stopped), which is what
    /// keeps the app alive in the background and the recording going.
    private func setCoarse() {
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 100
    }

    private func setPrecise() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = policy.platformDistanceFilter > 0 ? policy.platformDistanceFilter : kCLDistanceFilterNone
    }

    /// A geofence around the resting spot (needs "Always"). iOS watches it even while the
    /// GPS is off, and reports leaving it.
    private func startRestRegion() {
        guard manager.authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let a = stillness?.anchor else { return }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude),
                                      radius: 150, identifier: Self.restRegionID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    private func stopRestRegion() {
        for r in manager.monitoredRegions where r.identifier == Self.restRegionID {
            manager.stopMonitoring(for: r)
        }
    }

    fileprivate func exitedRegion(_ id: String) {
        guard id == Self.restRegionID else { return }
        if let e = stillness?.leftRegion(at: Date()) { handle(e) }
    }

    // MARK: - Core Location

    private func startUpdates() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = policy.platformDistanceFilter > 0 ? policy.platformDistanceFilter : kCLDistanceFilterNone
        // .other: no road snapping (that is what .automotiveNavigation does), so walks across
        // plazas and fields are recorded as walked.
        manager.activityType = .other
        // Never let iOS decide you've stopped and silently end updates.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        updatesStartedAt = Date()
        latestFix = nil
        windowBest = nil
        nextAttemptAt = .distantPast
        manager.startUpdatingLocation()
        // Costs almost nothing extra; it is what lets iOS relaunch the app if it gets killed.
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        if manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseTrack")
        }
    }

    private func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
    }

    private func requestAlwaysIfNeeded() {
        guard manager.authorizationStatus == .authorizedWhenInUse,
              !UserDefaults.standard.bool(forKey: Key.askedForAlways) else { return }
        UserDefaults.standard.set(true, forKey: Key.askedForAlways)
        manager.requestAlwaysAuthorization()
    }

    private func ingest(_ locations: [CLLocation]) {
        guard isRecording else { return }
        for location in locations {
            guard location.horizontalAccuracy >= 0, // invalid fix
                  location.timestamp >= updatesStartedAt.addingTimeInterval(-SamplingPolicy.cachedFixTolerance),
                  location.timestamp > (latestFix?.timestamp ?? .distantPast) // out of order
            else { continue }
            latestFix = location

            if stillness != nil {
                let f = StillnessDetector.Fix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                              accuracy: location.horizontalAccuracy, time: location.timestamp)
                if let e = stillness?.fix(f) {
                    handle(e)
                    // A rough cell-tower position woke the GPS: wait for a sharp one to save.
                    if case .wake = e, location.horizontalAccuracy > (stillness?.config.goodAccuracy ?? 100) { continue }
                }
                if stillness?.isResting == true { continue }   // nothing is saved while resting
                // Just after waking, iOS may still hand over a cell-tower position.
                if location.horizontalAccuracy > 1000 { continue }
            }

            // Track the sharpest fix in the few seconds leading up to the next attempt.
            if location.timestamp >= nextAttemptAt.addingTimeInterval(-SamplingPolicy.lookback),
               location.horizontalAccuracy <= (windowBest?.horizontalAccuracy ?? .infinity) {
                windowBest = location
            }
            guard location.timestamp >= nextAttemptAt else { continue }

            var candidate = location
            if let best = windowBest,
               location.timestamp.timeIntervalSince(best.timestamp) <= SamplingPolicy.lookback {
                candidate = best
            }
            attempt(candidate)
            nextAttemptAt = location.timestamp.addingTimeInterval(policy.interval)
            windowBest = nil
        }
        // Only drive the on-screen readout when someone can see it (and not with the rough
        // positions that come in while the GPS rests).
        if UIApplication.shared.applicationState != .background, stillness?.isResting != true,
           let fix = latestFix, fix.horizontalAccuracy <= 1000 {
            lastFix = fix
        }
    }

    private func attempt(_ location: CLLocation) {
        stats.attempts += 1
        if policy.maxAccuracy > 0, location.horizontalAccuracy > policy.maxAccuracy {
            stats.skippedPoorAccuracy += 1
            return
        }
        if let last = lastSaved,
           location.distance(from: last) <= policy.requiredMove(forAccuracy: location.horizontalAccuracy) {
            stats.skippedTooClose += 1
            return
        }
        rollOverIfNeeded(for: location.timestamp)
        guard let writer else {
            message = "No open track file; press STOP and RECORD again."
            return
        }
        let point = TrackPoint(location: location, segment: segment)
        do {
            try writer.append(point)
        } catch {
            message = "Couldn't save a point: \(error.localizedDescription)"
            return
        }
        points.append(point)
        lastSaved = location
        stats.saved += 1
    }

    private func authorizationChanged() {
        authorization = manager.authorizationStatus
        hasPreciseLocation = manager.accuracyAuthorization == .fullAccuracy
        switch authorization {
        case .authorizedAlways, .authorizedWhenInUse:
            if startWhenAuthorized {
                startWhenAuthorized = false
                beginRecording()
            } else if !isRecording {
                resumeIfNeeded()
            }
        case .denied, .restricted:
            if startWhenAuthorized {
                startWhenAuthorized = false
                message = "Waytrace needs location access to record."
            }
        default:
            break
        }
    }

    private func handleFailure(code: CLError.Code?, text: String) {
        switch code {
        case .some(.locationUnknown):
            return // transient: no fix yet (tunnel, deep indoors); Core Location keeps trying
        case .some(.denied):
            stop()
            message = "Location access was turned off, so recording stopped."
        default:
            message = text
        }
    }
}

extension LocationRecorder: CLLocationManagerDelegate {
    // Core Location calls the delegate on the run loop of the thread that created the
    // manager, which is the main thread here.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.ingest(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let text = error.localizedDescription
        MainActor.assumeIsolated { self.handleFailure(code: code, text: text) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let id = region.identifier
        MainActor.assumeIsolated { self.exitedRegion(id) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        // The geofence is only a helper; the motion and GPS checks still wake the GPS.
    }
}
