import Foundation
import Combine
import UIKit

/// The automatic road map: after a recording stops (and at midnight, when a recording rolls
/// over to a new day), each day it covers is run through Road to KML with the GPS history
/// settings from the Roads tab, one file per recording per day, named after the recording:
/// Road KML/roads_2026-11-08_09-12-44.kml. A file name is never reused: not one on the phone,
/// not one in the backup folder (even if it's gone from the phone), not one another waiting
/// map has taken. If the preferred name is taken, _2, _3… is added, so a second recording on
/// the same day can never overwrite the first one's map. There's no running map of
/// everywhere; that stays in QGIS.
///
/// Runs wait while a Road to KML run is already going. While a recording runs in the
/// background, maps wait until you next open the app, so the heavy work never competes with
/// the recording. A run that fails (usually busy map servers) is tried again after 30
/// minutes, then 2 hours, then left for you to run by hand.
@MainActor
final class DailyRoads: ObservableObject {
    static let shared = DailyRoads()

    @Published private(set) var plan: DailyPlan
    @Published private(set) var lastResult: String?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) }
    }

    private var retryTimer: Timer?
    private var runningID: String?

    private enum Key {
        static let plan = "daily.plan"
        static let enabled = "daily.enabled"
        static let result = "daily.result"
    }

    private init() {
        let d = UserDefaults.standard
        plan = d.data(forKey: Key.plan).flatMap { try? JSONDecoder().decode(DailyPlan.self, from: $0) } ?? DailyPlan()
        enabled = d.object(forKey: Key.enabled) as? Bool ?? true
        lastResult = d.string(forKey: Key.result)
    }

    /// Queue a finished recording's days (its name is its file name without .csv).
    func enqueue(recording: String, days: [String]) {
        guard enabled, !days.isEmpty else { return }
        plan.add(recording: recording, days: days)
        save()
        kick()
    }

    /// Start the next waiting map if now is a good time. Called after enqueueing, when the
    /// app comes to the front, and when any Road to KML run ends.
    func kick() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard enabled, !plan.isEmpty, runningID == nil, !RoadJobs.shared.isRunning else { return }
        // Don't start heavy work in the background while a recording is running.
        if LocationRecorder.shared.isRecording && UIApplication.shared.applicationState == .background { return }
        if let entry = plan.next(now: Date()) {
            start(entry)
        } else if let at = plan.nextRetry(after: Date()) {
            retryTimer = Timer.scheduledTimer(withTimeInterval: max(5, at.timeIntervalSinceNow), repeats: false) { _ in
                MainActor.assumeIsolated { DailyRoads.shared.kick() }
            }
        }
    }

    /// One recording's points from `day`.
    private func points(of recording: String, on day: String) -> [TrackPoint] {
        let store = TrackStore.shared
        let url = store.tracksDirectory.appendingPathComponent(recording).appendingPathExtension("csv")
        return store.loadPoints(from: url).filter { DailyPlan.dayString($0.time) == day }
    }

    /// The recordings with points on `day` (those that started that day or up to two days
    /// before, in case one ran past midnight). Only needed for days queued by an earlier version.
    private func recordings(on day: String) -> [String] {
        TrackStore.shared.sessions().filter { s in
            guard let start = s.startDate else { return true }
            let d = DailyPlan.dayString(start)
            return d <= day && d >= DailyPlan.dayString(Self.date(day).addingTimeInterval(-2 * 86400))
        }
        .map(\.name)
        .filter { !points(of: $0, on: day).isEmpty }
        .sorted()
    }

    /// The file this map writes. The name it was given on an earlier try is kept if it's
    /// still free (a failed run writes nothing); otherwise it gets one that no file on the
    /// phone, in the backup folder, or any other waiting map has.
    private func outputName(for entry: DailyPlan.Entry, recording: String) -> String {
        let dir = RoadJobs.shared.outputDirectory
        var taken = DailyPlan.takenNames((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        taken.formUnion(DailyPlan.takenNames(Backup.shared.roadKMLNames()))
        taken.formUnion(plan.reservedOutputs(except: entry.id))
        // Ask the file system too, in case the folder listing failed.
        let exists = { (name: String) in FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }
        if let kept = entry.output, !taken.contains(kept.lowercased()), !exists(kept) { return kept }
        return DailyPlan.uniqueName(DailyPlan.preferredStem(day: entry.day, recording: recording), taken: taken, exists: exists)
    }

    private func start(_ entry: DailyPlan.Entry) {
        let jobs = RoadJobs.shared
        let day = entry.day
        guard let recording = entry.recording else {
            // Queued by an earlier version for the whole day: one map per recording instead.
            plan.split(entry.id, into: recordings(on: day))
            save()
            kick()
            return
        }
        let dayPoints = DailyPlan.points(on: day, from: [points(of: recording, on: day)])
        guard dayPoints.count >= 2 else {
            plan.finished(entry.id)
            save()
            kick()
            return
        }
        let name = outputName(for: entry, recording: recording)
        plan.setOutput(name, for: entry.id)
        save()
        let stem = (name as NSString).deletingPathExtension
        let input = jobs.inputsDirectory.appendingPathComponent("daily_\(stem)_Records.json")
        do {
            try Exporter.records([ExportTrack(name: stem, points: dayPoints)]).write(to: input, options: .atomic)
        } catch {
            note("\(name): couldn't prepare the recording's points (\(error.localizedDescription)).")
            plan.finished(entry.id)
            save()
            return
        }
        var form = RoadFormStore.shared.track
        form.files = [jobs.argPath(input)]
        form.dateKind = .day
        form.day = Self.date(day)
        form.shape.output = name
        if form.modes.isEmpty { form.drive = true; form.walk = true; form.bike = true; form.other = true }
        let (argv, problems) = form.build()
        guard problems.isEmpty else {
            note("\(name): the GPS history settings in the Roads tab have a problem: \(problems[0].message)")
            plan.finished(entry.id)
            save()
            return
        }
        let label = "Daily roads: " + dayPoints[0].time.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        runningID = entry.id
        let started = jobs.run(argv, label: label, automatic: true) { job in
            DailyRoads.shared.finished(entry, recording: recording, name: name, job: job, input: input)
        }
        if started == nil { runningID = nil }
    }

    private func finished(_ entry: DailyPlan.Entry, recording: String, name: String, job: RoadJob, input: URL) {
        runningID = nil
        switch job.status {
        case .done:
            plan.finished(entry.id)
            try? FileManager.default.removeItem(at: input)
            note("Saved \(name).")
            addPhotos(day: entry.day, recording: recording, name: name)
        case .failed where (job.errorLine ?? "").contains("No trips found"):
            // Nothing to map (only standing still, or only trip types switched off).
            plan.finished(entry.id)
            try? FileManager.default.removeItem(at: input)
            note("\(name): no trips to map.")
        case .failed:
            if plan.failed(entry.id, now: Date()) {
                note("\(name): failed (\(job.errorLine ?? "error")); will try again later.")
            } else {
                note("\(name): failed three times (\(job.errorLine ?? "error")). Run it from the Roads tab when the map servers are less busy.")
                try? FileManager.default.removeItem(at: input)
            }
        case .cancelled:
            plan.finished(entry.id)
            try? FileManager.default.removeItem(at: input)
            note("\(name): cancelled.")
        case .running:
            return
        }
        save()
        kick()
    }

    /// Adds a Photos folder to the recording's roads file: every photo and video taken during
    /// it that day, named by file (IMG_1234), at its own location, or on the recording
    /// between the points just before and after it when it has none.
    private func addPhotos(day: String, recording: String, name: String) {
        let url = RoadJobs.shared.outputDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let mine = points(of: recording, on: day)
        Task {
            var access = PhotoLibrary.currentAccess
            if access == nil, UIApplication.shared.applicationState == .active {
                access = await PhotoLibrary.requestAccess()
            }
            guard access == .allowed || access == .limited else {
                note("Saved \(name); no photo markers, because Waytrace can't see your photos (Settings › Privacy & Security › Photos).")
                return
            }
            let result = await Task.detached(priority: .utility) { () -> String? in
                guard let w = PhotoPlacer.window(mine) else { return "no photos taken during the recording" }
                let photos = PhotoLibrary.items(from: w.lowerBound, to: w.upperBound)
                let markers = PhotoPlacer.place(photos, onEach: [mine]).markers
                guard !markers.isEmpty else { return "no photos taken during the recording" }
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let out = Exporter.addingFolder(Exporter.dailyPhotoFolder(markers, points: mine), to: text)
                else { return "couldn't add the photo markers" }
                do { try out.write(to: url, atomically: true, encoding: .utf8) } catch { return "couldn't add the photo markers" }
                return "\(markers.count) photo marker(s)"
            }.value
            note("Saved \(name) with \(result ?? "photos").")
            RoadJobs.shared.refreshFiles()
            Backup.shared.backUp(reason: "photo markers added")
        }
    }

    private func note(_ s: String) {
        lastResult = s
        UserDefaults.standard.set(s, forKey: Key.result)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(plan) { UserDefaults.standard.set(d, forKey: Key.plan) }
    }

    /// Noon on that day, in the phone's time zone.
    static func date(_ day: String) -> Date {
        let p = day.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p.first; c.month = p.count > 1 ? p[1] : 1; c.day = p.count > 2 ? p[2] : 1; c.hour = 12
        return Calendar.current.date(from: c) ?? Date()
    }
}
