import Foundation

/// The bookkeeping behind the automatic road map: which maps are waiting, when to try again
/// after a failure, which points belong to a day, and what each file is called. Every
/// recording gets its own file for each day it covers, named after the recording
/// (roads_2026-11-08_09-12-44.kml), and a name that's already used is never used again, so
/// a later run can never overwrite an earlier map. There is no running "everywhere" map.
struct DailyPlan: Codable, Equatable, Sendable {
    /// One map to make: the points one recording saved on one day.
    struct Entry: Codable, Equatable, Sendable {
        /// "2026-11-08", in the phone's time zone.
        var day: String
        /// The recording's name (its file name without .csv). nil only for days queued by
        /// an earlier version, which meant every recording that day; those are split into
        /// one entry per recording before they run.
        var recording: String?
        /// The file it writes, chosen when it first runs and kept for retries.
        var output: String?
        var attempts = 0
        var notBefore: Date?

        var id: String { day + "|" + (recording ?? "*") }
    }

    /// Stored under "days", the key earlier versions used, so a waiting queue survives updates.
    private(set) var entries: [Entry] = []
    private enum CodingKeys: String, CodingKey { case entries = "days" }

    /// After this many failed runs a map is dropped (it can still be made by hand).
    static let maxAttempts = 3

    var isEmpty: Bool { entries.isEmpty }

    /// For Settings: "2026-11-08 (2 recordings), 2026-11-09".
    var pendingSummary: String {
        var order: [String] = [], count: [String: Int] = [:]
        for e in entries {
            if count[e.day] == nil { order.append(e.day) }
            count[e.day, default: 0] += 1
        }
        return order.map { count[$0]! > 1 ? "\($0) (\(count[$0]!) recordings)" : $0 }.joined(separator: ", ")
    }

    /// Queue `recording`'s days. One already waiting starts over with a fresh count and
    /// keeps the name it was given.
    mutating func add(recording: String?, days new: [String]) {
        for d in Set(new).sorted() {
            if let i = entries.firstIndex(where: { $0.day == d && $0.recording == recording }) {
                entries[i].attempts = 0
                entries[i].notBefore = nil
            } else {
                entries.append(Entry(day: d, recording: recording))
            }
        }
        entries.sort { ($0.day, $0.recording ?? "") < ($1.day, $1.recording ?? "") }
    }

    /// Replaces an entry from an earlier version (a whole day) with one per recording.
    mutating func split(_ id: String, into recordings: [String]) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let day = entries[i].day
        entries.remove(at: i)
        for r in recordings { add(recording: r, days: [day]) }
    }

    /// The next map to make now, if any.
    func next(now: Date) -> Entry? {
        entries.first { ($0.notBefore ?? .distantPast) <= now }
    }

    /// When the earliest waiting retry is due (for a timer).
    func nextRetry(after now: Date) -> Date? {
        entries.compactMap(\.notBefore).filter { $0 > now }.min()
    }

    mutating func setOutput(_ name: String, for id: String) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].output = name }
    }

    /// Names held by other waiting maps (lowercased), so two never pick the same one.
    func reservedOutputs(except id: String) -> Set<String> {
        Set(entries.filter { $0.id != id }.compactMap { $0.output?.lowercased() })
    }

    mutating func finished(_ id: String) {
        entries.removeAll { $0.id == id }
    }

    /// A failed run: try again later (30 min, then 2 h), or give up after `maxAttempts`.
    /// Returns true if it will be retried.
    @discardableResult
    mutating func failed(_ id: String, now: Date) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[i].attempts += 1
        if entries[i].attempts >= Self.maxAttempts {
            entries.remove(at: i)
            return false
        }
        entries[i].notBefore = now.addingTimeInterval(entries[i].attempts == 1 ? 30 * 60 : 2 * 3600)
        return true
    }

    // MARK: - File names

    /// The name a recording's map of `day` would like: the recording's own name for the day
    /// it started (roads_2026-11-08_09-12-44), and for a later day it ran into, that day
    /// from midnight (roads_2026-11-09_00-00-00), which is also how "Start a new file each
    /// day" names the recording it starts at midnight.
    static func preferredStem(day: String, recording: String) -> String {
        recording.hasPrefix(day) ? "roads_\(recording)" : "roads_\(day)_00-00-00"
    }

    /// `stem`.kml, or `stem`_2.kml, _3… if that's taken: in `taken` (lowercased file names)
    /// or, asked one by one, by `exists`.
    static func uniqueName(_ stem: String, taken: Set<String>, exists: (String) -> Bool = { _ in false }) -> String {
        var name = stem + ".kml"
        var n = 2
        while taken.contains(name.lowercased()) || exists(name) {
            name = "\(stem)_\(n).kml"
            n += 1
        }
        return name
    }

    /// The file names in a folder listing, lowercased. A file iCloud has moved off the phone
    /// shows up as ".name.kml.icloud"; it still counts as name.kml.
    static func takenNames(_ listing: [String]) -> Set<String> {
        Set(listing.map { name in
            let lower = name.lowercased()
            if lower.hasPrefix("."), lower.hasSuffix(".icloud"), lower.count > 8 {
                return String(lower.dropFirst().dropLast(7))
            }
            return lower
        })
    }

    // MARK: - Days and points

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func days(of points: [TrackPoint], calendar: Calendar = .current) -> [String] {
        Array(Set(points.map { dayString($0.time, calendar: calendar) })).sorted()
    }

    /// The points recorded on `day`, from the given recordings, in time order. Segment
    /// numbers are kept apart per recording so two recordings are never joined by a straight line.
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
