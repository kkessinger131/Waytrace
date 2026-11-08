import Foundation
import Combine
import UIKit

/// The automatic daily road map: after a recording stops (and at midnight, when a recording
/// rolls over to a new day), the day's points from every recording are run through Road to
/// KML with the GPS history settings from the Roads tab, giving one file per day:
/// Road KML/roads_YYYY-MM-DD.kml. There's no running map of everywhere; that stays in QGIS.
///
/// Runs wait while a Road to KML run is already going. A day still being recorded waits for
/// STOP. While a recording runs in the background, maps wait until you next open the app, so
/// the heavy work never competes with the recording. A run that fails (usually busy map
/// servers) is tried again after 30 minutes, then 2 hours, then left for you to run by hand.
@MainActor
final class DailyRoads: ObservableObject {
    static let shared = DailyRoads()

    @Published private(set) var plan: DailyPlan
    @Published private(set) var lastResult: String?
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) }
    }

    private var retryTimer: Timer?
    private var runningDay: String?

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

    static func outputName(_ day: String) -> String { "roads_\(day).kml" }

    func enqueue(_ days: [String]) {
        guard enabled, !days.isEmpty else { return }
        plan.add(days)
        save()
        kick()
    }

    /// Start the next waiting day if now is a good time. Called after enqueueing, when the
    /// app comes to the front, and when any Road to KML run ends.
    func kick() {
        retryTimer?.invalidate()
        retryTimer = nil
        guard enabled, !plan.isEmpty, runningDay == nil, !RoadJobs.shared.isRunning else { return }
        let recorder = LocationRecorder.shared
        // Don't start heavy work in the background while a recording is running.
        if recorder.isRecording && UIApplication.shared.applicationState == .background { return }
        let busy: String? = recorder.isRecording ? DailyPlan.dayString(Date()) : nil
        if let day = plan.next(now: Date(), busyDay: busy) {
            start(day)
        } else if let at = plan.nextRetry(after: Date()) {
            retryTimer = Timer.scheduledTimer(withTimeInterval: max(5, at.timeIntervalSinceNow), repeats: false) { _ in
                MainActor.assumeIsolated { DailyRoads.shared.kick() }
            }
        }
    }

    private func start(_ day: String) {
        let jobs = RoadJobs.shared
        let store = TrackStore.shared
        // Recordings that can hold points of this day: started that day or up to two days before.
        let recordings = store.sessions().filter { s in
            guard let start = s.startDate else { return true }
            let d = DailyPlan.dayString(start)
            return d <= day && d >= DailyPlan.dayString(Self.date(day).addingTimeInterval(-2 * 86400))
        }.map { store.loadPoints(from: $0.url) }
        let points = DailyPlan.points(on: day, from: recordings)
        guard points.count >= 2 else {
            plan.finished(day)
            save()
            kick()
            return
        }
        let input = jobs.inputsDirectory.appendingPathComponent("daily_\(day)_Records.json")
        do {
            try Exporter.records([ExportTrack(name: "roads \(day)", points: points)]).write(to: input, options: .atomic)
        } catch {
            note("\(day): couldn't prepare the day's points (\(error.localizedDescription)).")
            plan.finished(day)
            save()
            return
        }
        var form = RoadFormStore.shared.track
        form.files = [jobs.argPath(input)]
        form.dateKind = .day
        form.day = Self.date(day)
        form.shape.output = Self.outputName(day)
        if form.modes.isEmpty { form.drive = true; form.walk = true; form.bike = true; form.other = true }
        let (argv, problems) = form.build()
        guard problems.isEmpty else {
            note("\(day): the GPS history settings in the Roads tab have a problem: \(problems[0].message)")
            plan.finished(day)
            save()
            return
        }
        let label = "Daily roads: " + Self.date(day).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        runningDay = day
        let started = jobs.run(argv, label: label, automatic: true) { job in
            DailyRoads.shared.finished(day, job: job, input: input)
        }
        if started == nil { runningDay = nil }
    }

    private func finished(_ day: String, job: RoadJob, input: URL) {
        runningDay = nil
        switch job.status {
        case .done:
            plan.finished(day)
            try? FileManager.default.removeItem(at: input)
            note("\(day): saved \(Self.outputName(day)).")
        case .failed where (job.errorLine ?? "").contains("No trips found"):
            // Nothing to map that day (only standing still, or only trip types switched off).
            plan.finished(day)
            try? FileManager.default.removeItem(at: input)
            note("\(day): no trips to map.")
        case .failed:
            if plan.failed(day, now: Date()) {
                note("\(day): failed (\(job.errorLine ?? "error")); will try again later.")
            } else {
                note("\(day): failed three times (\(job.errorLine ?? "error")). Run it from the Roads tab when the map servers are less busy.")
                try? FileManager.default.removeItem(at: input)
            }
        case .cancelled:
            plan.finished(day)
            try? FileManager.default.removeItem(at: input)
            note("\(day): cancelled.")
        case .running:
            return
        }
        save()
        kick()
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
