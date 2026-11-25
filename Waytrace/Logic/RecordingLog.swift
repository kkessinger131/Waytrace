import Foundation

/// What happened during a recording besides the points: the times Waytrace wasn't running
/// (gaps), the times the GPS rested, and the battery. Saved next to the recording as
/// <name>.log.json.
struct RecordingLog: Codable, Equatable, Sendable {
    struct Spot: Codable, Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var time: Date
    }

    /// Waytrace wasn't running: the phone was off, iOS closed the app, it was re-signed…
    struct Gap: Codable, Equatable, Sendable {
        /// Last sign of life before the gap.
        var from: Date
        /// When recording picked up again.
        var to: Date
        var cause: String
        /// The last point saved before, and the first one after (filled in when it's saved).
        var before: Spot?
        var after: Spot?

        var duration: TimeInterval { to.timeIntervalSince(from) }
        /// Straight-line distance between the points either side, once both are known.
        var distance: Double? {
            guard let a = before, let b = after else { return nil }
            return Geo.distance(a.latitude, a.longitude, b.latitude, b.longitude)
        }
    }

    /// The GPS rested while you stayed put (StillnessDetector).
    struct Rest: Codable, Equatable, Sendable {
        var from: Date
        var to: Date?
        var wokeBy: String?
    }

    /// The battery level, noted when recording starts and stops, when the GPS rests or wakes,
    /// and whenever the level, charging or Low Power Mode changes.
    struct BatterySample: Codable, Equatable, Sendable {
        var time: Date
        /// 0...1
        var level: Double
        var charging: Bool
        var lowPower: Bool
    }

    var gaps: [Gap] = []
    var rests: [Rest] = []
    var battery: [BatterySample] = []

    init(gaps: [Gap] = [], rests: [Rest] = [], battery: [BatterySample] = []) {
        self.gaps = gaps
        self.rests = rests
        self.battery = battery
    }

    // Logs saved before the battery was added have no "battery" key.
    private enum CodingKeys: String, CodingKey { case gaps, rests, battery }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gaps = try c.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
        rests = try c.decodeIfPresent([Rest].self, forKey: .rests) ?? []
        battery = try c.decodeIfPresent([BatterySample].self, forKey: .battery) ?? []
    }

    /// Gaps shorter than this aren't worth a line (a quick relaunch).
    static let minGap: TimeInterval = 60
    /// Gaps at least this long get a notification when the recording resumes.
    static let notifyGap: TimeInterval = 10 * 60

    // MARK: - Rests

    mutating func restStarted(at t: Date) {
        if let i = rests.indices.last, rests[i].to == nil { rests[i].to = t; rests[i].wokeBy = "recording interrupted" }
        rests.append(Rest(from: t))
    }

    mutating func restEnded(at t: Date, wokeBy: String) {
        guard let i = rests.indices.last, rests[i].to == nil else { return }
        rests[i].to = t
        rests[i].wokeBy = wokeBy
    }

    /// How the GPS woke, counted ("12 steps" and "15 steps" both count as steps).
    var wakeCounts: [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in rests { if let w = r.wokeBy { counts[Self.wakeKind(w), default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Wakes where only the 3-minute GPS check noticed you'd gone: the motion sensor, step
    /// counter and geofence all missed it, so up to ~3 minutes of track before it may be missing.
    var lateWakes: [Rest] { rests.filter { ($0.wokeBy ?? "").hasPrefix("the GPS check") } }

    var restedTime: TimeInterval {
        rests.reduce(0) { $0 + (($1.to ?? $1.from).timeIntervalSince($1.from)) }
    }

    static func wakeKind(_ reason: String) -> String {
        if reason.hasSuffix(" steps") { return "steps" }
        if reason.hasPrefix("motion: ") { return String(reason.dropFirst(8)) }
        if reason.hasPrefix("the GPS check") { return "3-minute GPS check" }
        if reason.hasPrefix("a rough position") { return "cell-tower position" }
        return reason
    }

    // MARK: - Battery

    /// Adds a sample if anything changed since the last one (or `force`, at start, stop and
    /// rest changes). Returns whether it was added. A negative level (unknown) is ignored.
    @discardableResult
    mutating func noteBattery(_ s: BatterySample, force: Bool = false) -> Bool {
        guard s.level >= 0 else { return false }
        if !force, let last = battery.last,
           last.level == s.level, last.charging == s.charging, last.lowPower == s.lowPower { return false }
        battery.append(s)
        return true
    }

    /// Whether the GPS was resting at `t`.
    func isResting(at t: Date) -> Bool {
        rests.contains { $0.from <= t && t < ($0.to ?? .distantFuture) }
    }

    var batteryReport: BatteryReport? { BatteryReport(samples: battery, resting: isResting(at:)) }

    // MARK: - File

    static func url(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("log.json")
    }

    static func load(for recording: URL) -> RecordingLog {
        guard let data = try? Data(contentsOf: url(for: recording)) else { return RecordingLog() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return (try? d.decode(RecordingLog.self, from: data)) ?? RecordingLog()
    }

    func save(for recording: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Self.url(for: recording), options: .atomic)
    }
}

/// Why Waytrace wasn't running for a while, worked out from a "heartbeat" it saves every
/// 15 seconds while recording and what it finds when it starts again.
enum Interruption {
    struct Heartbeat: Codable, Equatable, Sendable {
        var time: Date
        /// When the phone last started up.
        var boot: Date
        /// When the install's signing ran out, as it was then.
        var expiry: Date?
        /// The app's version and build.
        var build: String
    }

    static func cause(last: Heartbeat?, bootNow: Date, expiryNow: Date?, buildNow: String,
                      waitedForLocationAccess: Bool, now: Date) -> String {
        guard let last else { return "Waytrace was reinstalled or updated" }
        if abs(bootNow.timeIntervalSince(last.boot)) > 5 {
            return "The phone was off or restarted (or its battery ran out)"
        }
        if let old = last.expiry, let new = expiryNow, abs(new.timeIntervalSince(old)) > 60 {
            return old <= now
                ? "Waytrace's signing ran out; it ran again once reinstalled"
                : "Waytrace was re-signed (Sideloadly refresh or reinstall), which closes it"
        }
        if waitedForLocationAccess { return "Location access was off" }
        if last.build != buildNow { return "Waytrace was updated" }
        return "iOS closed Waytrace (usually to free memory) or it crashed"
    }

    static func describe(_ gap: RecordingLog.Gap, distance format: (Double) -> String = Interruption.metric) -> String {
        var s = "\(duration(gap.duration)) gap: \(gap.cause.prefix(1).lowercased() + gap.cause.dropFirst())"
        if let d = gap.distance { s += "; moved \(format(d)) meanwhile" }
        return s + "."
    }

    static func metric(_ d: Double) -> String {
        d >= 1000 ? String(format: "%.1f km", d / 1000) : "\(Int(d)) m"
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(max(1, m))-minute" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h)-hour" : "\(h) h \(r) min"
    }
}

/// What the battery did during a recording. Only stretches on battery count towards use:
/// time on the charger is left out. The level includes everything else the phone did
/// meanwhile, and iOS reports it in steps, so short stretches are rough.
struct BatteryReport: Equatable, Sendable {
    /// Level lost while on battery, 0...1.
    var used: Double
    /// Time on battery between the first and last sample.
    var onBattery: TimeInterval
    var charging: TimeInterval
    /// Use per hour on battery, with the GPS running and with it resting (nil without at
    /// least half an hour of each).
    var perHour: Double?
    var perHourActive: Double?
    var perHourResting: Double?
    var lowPower: Bool
    var first: Double
    var last: Double

    static let minHours = 0.5

    init?(samples: [RecordingLog.BatterySample], resting: (Date) -> Bool) {
        let s = samples.sorted { $0.time < $1.time }
        guard s.count >= 2, let a = s.first, let b = s.last, b.time > a.time else { return nil }
        var used = 0.0, onBattery = 0.0, charging = 0.0
        var active = (used: 0.0, time: 0.0), rest = (used: 0.0, time: 0.0)
        for (p, q) in zip(s, s.dropFirst()) {
            let dt = q.time.timeIntervalSince(p.time)
            if p.charging || q.charging {
                charging += dt
                continue
            }
            let drop = max(0, p.level - q.level)
            used += drop
            onBattery += dt
            if resting(p.time) { rest.used += drop; rest.time += dt } else { active.used += drop; active.time += dt }
        }
        let rate = { (u: Double, t: TimeInterval) -> Double? in t / 3600 >= Self.minHours ? u / (t / 3600) : nil }
        self.used = used
        self.onBattery = onBattery
        self.charging = charging
        perHour = rate(used, onBattery)
        perHourActive = rate(active.used, active.time)
        perHourResting = rate(rest.used, rest.time)
        lowPower = s.contains { $0.lowPower }
        first = a.level
        last = b.level
    }
}
