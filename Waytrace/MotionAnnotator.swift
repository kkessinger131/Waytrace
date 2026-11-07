import Foundation
import CoreMotion

/// Labels points as walking / running / cycling / automotive / stationary using the
/// motion coprocessor's own history. The iPhone records this continuously whether or not
/// any app asks (it keeps 7 days), so querying it after a recording costs nothing while
/// recording. Note: Core Motion's "automotive" also covers buses and trains.
@MainActor
enum MotionAnnotator {
    private static let manager = CMMotionActivityManager()

    struct Sample: Sendable {
        let start: Date
        let label: String
    }

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    /// Returns the points with `activity` filled in where Core Motion has data.
    static func annotate(_ points: [TrackPoint]) async -> [TrackPoint] {
        guard isAvailable, let first = points.first?.time, let last = points.last?.time else { return points }
        let samples = await query(from: first.addingTimeInterval(-15 * 60), to: last.addingTimeInterval(1))
        guard !samples.isEmpty else { return points }

        var result = points
        var j = 0
        for i in result.indices {
            let t = result[i].time
            while j + 1 < samples.count, samples[j + 1].start <= t { j += 1 }
            if samples[j].start <= t { result[i].activity = samples[j].label }
        }
        return result
    }

    private static func query(from start: Date, to end: Date) async -> [Sample] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Sample], Never>) in
            manager.queryActivityStarting(from: start, to: end, to: OperationQueue.main) { activities, _ in
                let samples = (activities ?? [])
                    .compactMap { activity -> Sample? in
                        guard let label = MotionAnnotator.label(for: activity) else { return nil }
                        return Sample(start: activity.startDate, label: label)
                    }
                    .sorted { $0.start < $1.start }
                continuation.resume(returning: samples)
            }
        }
    }

    /// Several flags can be true at once (stopped at a light: automotive + stationary),
    /// so the most specific way of moving wins.
    nonisolated static func label(for a: CMMotionActivity) -> String? {
        if a.automotive { return "automotive" }
        if a.cycling { return "cycling" }
        if a.running { return "running" }
        if a.walking { return "walking" }
        if a.stationary { return "stationary" }
        return nil
    }
}
