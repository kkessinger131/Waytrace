import Foundation

/// The bookkeeping behind the automatic daily road map: which days are waiting, when to try
/// again after a failure, and which points belong to a day. Each day becomes one file,
/// roads_YYYY-MM-DD.kml; there is no running "everywhere" map.
struct DailyPlan: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        /// "2026-11-08", in the phone's time zone.
        var day: String
        var attempts = 0
        var notBefore: Date?
    }

    private(set) var days: [Day] = []

    /// After this many failed runs a day is dropped (it can still be mapped by hand).
    static let maxAttempts = 3

    var isEmpty: Bool { days.isEmpty }
    var pendingDays: [String] { days.map(\.day) }

    /// Queue days (again). A day already waiting starts over with a fresh count: new points
    /// were recorded for it, so its map needs redoing anyway.
    mutating func add(_ new: [String]) {
        for d in Set(new).sorted() {
            if let i = days.firstIndex(where: { $0.day == d }) {
                days[i].attempts = 0
                days[i].notBefore = nil
            } else {
                days.append(Day(day: d))
            }
        }
        days.sort { $0.day < $1.day }
    }

    /// The next day to map now, if any. `busyDay` (the day a running recording is still
    /// adding to) waits until that recording stops.
    func next(now: Date, busyDay: String?) -> String? {
        days.first { d in d.day != busyDay && (d.notBefore ?? .distantPast) <= now }?.day
    }

    /// When the earliest waiting retry is due (for a timer).
    func nextRetry(after now: Date) -> Date? {
        days.compactMap(\.notBefore).filter { $0 > now }.min()
    }

    mutating func finished(_ day: String) {
        days.removeAll { $0.day == day }
    }

    /// A failed run: try again later (30 min, then 2 h), or give up after `maxAttempts`.
    /// Returns true if the day will be retried.
    @discardableResult
    mutating func failed(_ day: String, now: Date) -> Bool {
        guard let i = days.firstIndex(where: { $0.day == day }) else { return false }
        days[i].attempts += 1
        if days[i].attempts >= Self.maxAttempts {
            days.remove(at: i)
            return false
        }
        days[i].notBefore = now.addingTimeInterval(days[i].attempts == 1 ? 30 * 60 : 2 * 3600)
        return true
    }

    // MARK: - Days and points

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func days(of points: [TrackPoint], calendar: Calendar = .current) -> [String] {
        Array(Set(points.map { dayString($0.time, calendar: calendar) })).sorted()
    }

    /// The points recorded on `day`, from every recording, in time order. Segment numbers
    /// are kept apart per recording so two recordings are never joined by a straight line.
    static func points(on day: String, from recordings: [[TrackPoint]], calendar: Calendar = .current) -> [TrackPoint] {
        var out: [TrackPoint] = []
        var nextSegment = 0
        for rec in recordings {
            let todays = rec.filter { dayString($0.time, calendar: calendar) == day }
            guard !todays.isEmpty else { continue }
            var map: [Int: Int] = [:]
            for var p in todays {
                if map[p.segment] == nil { map[p.segment] = nextSegment; nextSegment += 1 }
                p.segment = map[p.segment]!
                out.append(p)
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
