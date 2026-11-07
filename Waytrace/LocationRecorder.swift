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
            annotateActivity(of: finished)
        }
    }

    /// Called whenever the app comes to the foreground. Starting updates that are already
    /// running is harmless; it covers the case where they couldn't be started from the
    /// background (e.g. a relaunch with only "While Using" permission).
    func appBecameActive() {
        if isRecording {
            manager.startUpdatingLocation()
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
    }

    // MARK: - Session files

    private func beginRecording() {
        policy = SamplingPolicy.current
        lastSaved = nil
        guard openSession(start: Date()) else { return }
        startUpdates()
        isRecording = true
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
        closeWriter()
        openSession(start: Calendar.current.startOfDay(for: date))
        if let finished { annotateActivity(of: finished) }
    }

    private func annotateActivity(of url: URL) {
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
        }
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
        // Only drive the on-screen readout when someone can see it.
        if UIApplication.shared.applicationState != .background {
            lastFix = latestFix
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
}
