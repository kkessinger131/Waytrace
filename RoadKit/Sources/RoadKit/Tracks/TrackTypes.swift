import Foundation

/// A moment with the UTC offset it was written in (a timezone-aware Python datetime).
public struct Stamp: Comparable, Hashable, Sendable {
    public var date: Date
    /// Seconds east of UTC.
    public var offset: Int

    public init(_ date: Date, offset: Int) { self.date = date; self.offset = offset }

    /// t.astimezone(): the same moment in this device's time zone.
    public static func local(_ date: Date) -> Stamp {
        Stamp(date, offset: TimeZone.current.secondsFromGMT(for: date))
    }

    public static func < (a: Stamp, b: Stamp) -> Bool { a.date < b.date }
    public static func == (a: Stamp, b: Stamp) -> Bool { a.date == b.date }
    public func hash(into h: inout Hasher) { h.combine(date) }

    public func adding(seconds s: Double) -> Stamp { Stamp(date.addingTimeInterval(s), offset: offset) }
    public func seconds(since o: Stamp) -> Double { date.timeIntervalSince(o.date) }

    var zone: TimeZone { TimeZone(secondsFromGMT: offset) ?? .current }

    /// local_time: wall-clock time where you were — its own offset when the file gives
    /// one, else this device's time zone.
    public var localTime: Stamp { offset == 0 ? Stamp.local(date) : self }

    /// local_date
    public var localDate: DayDate { DayDate(date, in: localTime.zone) }

    /// strftime in this stamp's own offset ("%Y-%m-%d %H:%M" style, using DateFormatter patterns).
    public func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// road_tracks.TrackPoint
public struct TrackPoint {
    public var t: Stamp?
    public var lat: Double
    public var lon: Double
    public var acc: Double?
    public var mode: String?
    public var seg: String
    public var act: Int?
    /// Identity, for "is this the same point" checks (Python's `is`).
    var uid: Int = 0

    public init(_ t: Stamp?, _ lat: Double, _ lon: Double, _ acc: Double? = nil, _ mode: String? = nil,
                _ seg: String = "timeline", _ act: Int? = nil) {
        self.t = t; self.lat = lat; self.lon = lon; self.acc = acc; self.mode = mode; self.seg = seg; self.act = act
    }
}

/// road_tracks.Trip
public struct Trip {
    public var category: String
    public var points: [TrackPoint]
    /// Identity within a run (Python's id(t)).
    var uid: Int = 0
    public init(_ category: String, _ points: [TrackPoint]) { self.category = category; self.points = points }
}

/// (south, west, north, east) in degrees.
public typealias Box = (s: Double, w: Double, n: Double, e: Double)

/// A road for map matching: OSM ids, or TIGER/Line lines turned into ways.
public struct NetWay {
    public var id: Int64
    public var tags: Tags
    public var nodes: [Int64]
    public init(id: Int64, tags: Tags, nodes: [Int64]) { self.id = id; self.tags = tags; self.nodes = nodes }
}

public typealias LatLon = (lat: Double, lon: Double)

/// road_tracks.py's travel-mode and road-type tables.
public enum TrackRules {
    static let driveModes: Set<String> = ["IN_PASSENGER_VEHICLE", "IN_VEHICLE", "IN_ROAD_VEHICLE", "IN_CAR", "DRIVING",
                                          "DRIVE", "IN_BUS", "IN_TAXI", "MOTORCYCLING", "IN_FOUR_WHEELER_VEHICLE",
                                          "IN_TWO_WHEELER_VEHICLE"]
    static let walkModes: Set<String> = ["WALKING", "WALK", "ON_FOOT", "RUNNING", "HIKING"]
    static let bikeModes: Set<String> = ["CYCLING", "CYCLE", "ON_BICYCLE", "BIKING"]
    static let skipModes: Set<String> = ["FLYING", "IN_TRAIN", "IN_RAIL_VEHICLE", "IN_SUBWAY", "IN_TRAM", "IN_FERRY",
                                         "SAILING", "BOATING", "IN_CABLECAR", "IN_FUNICULAR", "IN_GONDOLA_LIFT",
                                         "SKIING", "KAYAKING", "ROWING", "SURFING", "SWIMMING", "STILL"]
    public static let categories = ["drive", "walk", "bike", "other"]

    static let roads = ["motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
                        "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
                        "residential", "living_street", "service", "road", "track", "busway"]
    static let foot = ["footway", "path", "pedestrian", "steps", "cycleway", "bridleway", "corridor"]
    public static let networkTypes: [String: [String]] = [
        "drive": roads,
        "walk": roads.filter { !$0.hasPrefix("motorway") } + foot,
        "bike": roads.filter { !$0.hasPrefix("motorway") } + foot.filter { $0 != "steps" },
        "other": roads + foot,
    ]
    /// Ways that don't count as a junction unless the trip actually used them.
    static let minorTypes: Set<String> = ["service", "track", "footway", "path", "pedestrian", "steps", "cycleway",
                                          "bridleway", "corridor"]
    static let pedTypes = Set(foot)
    static let spacing: [String: Double] = ["drive": 25.0, "bike": 12.0, "walk": 8.0, "other": 15.0]
    static let vmax: [String: Double] = ["drive": 60.0, "bike": 20.0, "walk": 8.0, "other": 60.0]
    static let endStubM = 12.0
    static let noAccSigma = 35.0
    static let roadClassCost: [String: Double] = [
        "tertiary": 1.1, "tertiary_link": 1.1, "unclassified": 1.3, "residential": 1.3, "road": 1.3, "busway": 1.3,
        "living_street": 1.6, "service": 1.6, "track": 2.0,
    ]

    /// mode_category: "drive" / "walk" / "bike" / "skip" / "other", or nil when unknown.
    public static func category(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let m = Re.sub(Re.compile("[\\s-]+"), "_", Py.strip(raw).uppercased())
        if skipModes.contains(m) { return "skip" }
        if driveModes.contains(m) { return "drive" }
        if walkModes.contains(m) { return "walk" }
        if bikeModes.contains(m) { return "bike" }
        if m == "UNKNOWN_TRAVEL" { return "other" }
        return nil
    }
}
