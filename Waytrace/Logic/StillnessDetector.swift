import Foundation

/// Decides when the GPS can rest during a recording, and when it must wake again.
///
/// Resting never stops the recording. Core Location keeps running the whole time, just at
/// cell-tower accuracy, so iOS keeps the app alive exactly as before; only the GPS chip is
/// let off. Nothing is saved while resting, because you haven't gone anywhere.
///
/// Rest only after **all** of these have held, without a break, for `restAfter` (5 min):
///  - every good fix stayed inside a small circle (40 m, or 1.5 × the fix's accuracy);
///  - the motion coprocessor reported no walking, running, cycling or driving. Sitting at a
///    red light reads as "automotive", so it counts as driving and keeps the GPS on;
///  - fewer than 30 steps were counted (pacing around a room or a trailhead doesn't rest).
/// Without motion data (permission off, or no reading yet) the wait doubles.
///
/// Wake at the first sign of movement: 10 steps, any walking/running/cycling/driving report,
/// a coarse fix clearly outside the circle, leaving a 150 m geofence, or the GPS check made
/// every 3 minutes finding you've moved. That last one needs no motion data at all, so the
/// longest a move can go unnoticed is about 3 minutes even if every other signal fails.
struct StillnessDetector: Sendable {
    struct Config: Equatable, Sendable {
        var restAfter: TimeInterval = 300
        var radiusFloor = 40.0
        var radiusPerAccuracy = 1.5
        /// Fixes vaguer than this don't count as evidence either way while the GPS is on.
        /// (Indoors, wifi positions are often ±65 m, and indoors is where resting matters.)
        var goodAccuracy = 100.0
        var stepsToReset = 30
        var stepsToWake = 10
        var checkEvery: TimeInterval = 180
        var checkTimeout: TimeInterval = 25
        /// A coarse (cell-tower) fix wakes the GPS when it is this far outside the circle,
        /// on top of its own uncertainty.
        var coarseMargin = 200.0
        var coarseMaxAccuracy = 3000.0
    }

    struct Fix: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var accuracy: Double
        var time: Date
    }

    enum Phase: Equatable, Sendable {
        case active
        case resting
        case checking(since: Date)
    }

    enum Event: Equatable, Sendable {
        /// Turn the GPS down: you've been still long enough.
        case rest
        /// Turn the GPS back up and start saving again.
        case wake(String)
        /// Turn the GPS up briefly to look where you are.
        case startCheck
        /// The look found you still where you were: turn it back down.
        case endCheck
    }

    var config: Config
    var motionAvailable: Bool
    private(set) var phase: Phase = .active
    private(set) var anchor: Fix?
    private(set) var stillSince: Date
    private(set) var restedSince: Date?
    private var steps = 0
    private var stepsAtStill = 0
    private var stepsAtRest = 0
    /// nil until the motion coprocessor has said anything.
    private var lastMotionMoving: Bool?
    private var lastMotionAt: Date?
    private var lastCheck: Date?

    init(config: Config = Config(), motionAvailable: Bool, now: Date) {
        self.config = config
        self.motionAvailable = motionAvailable
        self.stillSince = now
    }

    var isResting: Bool { phase != .active }

    func radius(of f: Fix) -> Double { max(config.radiusFloor, config.radiusPerAccuracy * f.accuracy) }

    /// How long you must be still before resting, given what the motion coprocessor has said.
    var requiredStill: TimeInterval {
        motionAvailable && lastMotionMoving != nil ? config.restAfter : config.restAfter * 2
    }

    // MARK: - Inputs

    mutating func fix(_ f: Fix) -> Event? {
        switch phase {
        case .active:
            guard f.accuracy >= 0, f.accuracy <= config.goodAccuracy else { return nil }
            guard let a = anchor else {
                anchor = f
                restartClock(at: f.time)
                return nil
            }
            if Self.distance(a, f) > radius(of: a) {
                anchor = f
                restartClock(at: f.time)
            }
            return nil
        case .resting:
            guard let a = anchor, f.accuracy >= 0, f.accuracy <= config.coarseMaxAccuracy else { return nil }
            let d = Self.distance(a, f)
            if d > radius(of: a) + f.accuracy + config.coarseMargin {
                return wake("a rough position \(Int(d.rounded())) m away", at: f.time)
            }
            return nil
        case .checking:
            guard let a = anchor, f.accuracy >= 0, f.accuracy <= config.goodAccuracy else { return nil }
            let d = Self.distance(a, f)
            if d > radius(of: a) {
                return wake("the GPS check found you \(Int(d.rounded())) m away", at: f.time)
            }
            phase = .resting
            lastCheck = f.time
            return .endCheck
        }
    }

    /// One reading from the motion coprocessor (see `MotionReading`).
    mutating func motion(_ r: MotionReading, at t: Date) -> Event? {
        lastMotionAt = t
        switch phase {
        case .active:
            lastMotionMoving = r.moving
            if r.moving { restartClock(at: t) }
            return nil
        case .resting, .checking:
            lastMotionMoving = r.moving
            return r.wakes ? wake(r.label, at: t) : nil
        }
    }

    /// Steps counted since recording began (CMPedometer's running total).
    mutating func steps(_ total: Int, at t: Date) -> Event? {
        steps = total
        switch phase {
        case .active:
            if total - stepsAtStill >= config.stepsToReset { restartClock(at: t) }
            return nil
        case .resting, .checking:
            if total - stepsAtRest >= config.stepsToWake {
                return wake("\(total - stepsAtRest) steps", at: t)
            }
            return nil
        }
    }

    /// The geofence around the resting spot reported that you left it.
    mutating func leftRegion(at t: Date) -> Event? {
        isResting ? wake("left the area", at: t) : nil
    }

    /// Called every few seconds by a timer: no fixes arrive while you stand still, so time
    /// alone has to move things on.
    mutating func tick(_ now: Date) -> Event? {
        switch phase {
        case .active:
            guard anchor != nil, lastMotionMoving != true,
                  now.timeIntervalSince(stillSince) >= requiredStill else { return nil }
            phase = .resting
            restedSince = now
            stepsAtRest = steps
            lastCheck = now
            return .rest
        case .resting:
            if now.timeIntervalSince(lastCheck ?? now) >= config.checkEvery {
                phase = .checking(since: now)
                return .startCheck
            }
            return nil
        case .checking(let since):
            if now.timeIntervalSince(since) >= config.checkTimeout {
                // No good fix in time (indoors): stay resting and look again later.
                phase = .resting
                lastCheck = now
                return .endCheck
            }
            return nil
        }
    }

    /// Look now (the app was opened while resting, so show a sharp position).
    mutating func checkNow(_ now: Date) -> Event? {
        guard phase == .resting else { return nil }
        phase = .checking(since: now)
        return .startCheck
    }

    // MARK: - Helpers

    private mutating func restartClock(at t: Date) {
        stillSince = t
        stepsAtStill = steps
    }

    private mutating func wake(_ reason: String, at t: Date) -> Event {
        phase = .active
        restedSince = nil
        anchor = nil            // re-anchored by the next sharp fix
        restartClock(at: t)
        return .wake(reason)
    }

    static func distance(_ a: Fix, _ b: Fix) -> Double {
        let r = 6_371_008.8
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }
}

/// What a motion-coprocessor reading means for resting. Built from CMMotionActivity's flags
/// by `MotionWatch`; kept separate so the rules can be tested without a phone.
struct MotionReading: Equatable, Sendable {
    /// Counts as movement while deciding whether to rest (any travel flag at medium or high
    /// confidence, including "automotive" while stopped at a light).
    var moving: Bool
    /// Wakes the GPS while resting. Deliberately eager: a false wake only costs a little
    /// battery, a missed one costs track.
    var wakes: Bool
    var label: String

    enum Confidence: Int, Sendable { case low, medium, high }

    static func from(walking: Bool, running: Bool, cycling: Bool, automotive: Bool, stationary: Bool,
                     confidence: Confidence) -> MotionReading {
        let travel = walking || running || cycling || automotive
        let label = running ? "running" : cycling ? "cycling" : walking ? "walking"
            : automotive ? (stationary ? "in a vehicle, stopped" : "driving") : stationary ? "still" : "unknown"
        let moving = travel && confidence != .low
        let wakes = ((walking || running || cycling) && confidence != .low) || (automotive && !stationary)
        return MotionReading(moving: moving, wakes: wakes, label: "motion: \(label)")
    }
}
