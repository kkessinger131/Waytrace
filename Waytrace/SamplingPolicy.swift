import Foundation

/// The rules that decide which GPS fixes become saved points.
struct SamplingPolicy: Equatable, Sendable {
    /// Seconds between save attempts while recording.
    var interval: TimeInterval
    /// A fix within this many metres of the previously *saved* point is not saved.
    var minDistance: Double
    /// Fixes whose horizontal accuracy is worse than this (metres) are not saved. 0 = accept all.
    var maxAccuracy: Double
    /// Start a new file at local midnight so each day is its own recording.
    var splitAtMidnight: Bool
    /// Also require a move larger than the new fix's own uncertainty. Indoors, wifi-based
    /// fixes (±30–65 m) wander more than 20 m while you sit still; this keeps most of that
    /// drift out. Outdoors (±3–10 m) it changes nothing.
    var driftGuard: Bool

    /// The distance a fix must exceed (from the last saved point) to be saved.
    func requiredMove(forAccuracy accuracy: Double) -> Double {
        driftGuard ? max(minDistance, accuracy) : minDistance
    }

    /// Distance filter handed to Core Location. While you stand still, iOS stops waking the
    /// app at all, which is most of the "lightweight" part. It stays well below `minDistance`
    /// so it can never hide a real move.
    var platformDistanceFilter: Double { max(0, min(5, minDistance / 4)) }

    /// Before each attempt, a fix up to this many seconds older may be used instead of the
    /// newest one if it is more accurate.
    static let lookback: TimeInterval = 3
    /// iOS often hands over a cached fix from before updates started; anything older than
    /// this (relative to the start of updates) is ignored.
    static let cachedFixTolerance: TimeInterval = 5

    static let defaults = SamplingPolicy(interval: 15, minDistance: 20, maxAccuracy: 50,
                                         splitAtMidnight: true, driftGuard: true)

    enum Key {
        static let interval = "sampling.interval"
        static let minDistance = "sampling.minDistance"
        static let maxAccuracy = "sampling.maxAccuracy"
        static let splitAtMidnight = "sampling.splitAtMidnight"
        static let driftGuard = "sampling.driftGuard"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.interval: defaults.interval,
            Key.minDistance: defaults.minDistance,
            Key.maxAccuracy: defaults.maxAccuracy,
            Key.splitAtMidnight: defaults.splitAtMidnight,
            Key.driftGuard: defaults.driftGuard,
        ])
    }

    /// The policy as currently set in Settings.
    static var current: SamplingPolicy {
        let d = UserDefaults.standard
        return SamplingPolicy(
            interval: max(1, d.double(forKey: Key.interval)),
            minDistance: max(0, d.double(forKey: Key.minDistance)),
            maxAccuracy: max(0, d.double(forKey: Key.maxAccuracy)),
            splitAtMidnight: d.bool(forKey: Key.splitAtMidnight),
            driftGuard: d.bool(forKey: Key.driftGuard)
        )
    }
}
