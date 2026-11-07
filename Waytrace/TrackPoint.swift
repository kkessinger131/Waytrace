import Foundation

/// One saved GPS fix. Optional fields are nil when iOS reported them as invalid
/// (for example, course and speed are unknown until you start moving).
struct TrackPoint: Hashable, Sendable {
    /// Increments each time recording resumes after an interruption, so exports can
    /// break the line instead of drawing a straight jump across the gap.
    var segment: Int
    var time: Date
    var latitude: Double
    var longitude: Double
    /// Radius of uncertainty, metres (68% confidence).
    var horizontalAccuracy: Double?
    /// Metres above mean sea level (same reference as EXIF GPSAltitude).
    var altitude: Double?
    var verticalAccuracy: Double?
    /// Metres per second.
    var speed: Double?
    var speedAccuracy: Double?
    /// Direction of travel, degrees clockwise from true north.
    var course: Double?
    var courseAccuracy: Double?
    /// Motion label from the iPhone's motion coprocessor: walking, running, cycling,
    /// automotive or stationary. Filled in when a recording stops.
    var activity: String?
}

// MARK: - CSV storage format

extension TrackPoint {
    static let csvHeader = "segment,time_utc,unix_time,latitude,longitude,horizontal_accuracy_m,altitude_m,vertical_accuracy_m,speed_mps,speed_accuracy_mps,course_deg,course_accuracy_deg,activity"

    var csvLine: String {
        [
            String(segment),
            TimeFormats.utc.format(time),
            String(format: "%.3f", time.timeIntervalSince1970),
            String(format: "%.7f", latitude),
            String(format: "%.7f", longitude),
            Self.number(horizontalAccuracy, decimals: 1),
            Self.number(altitude, decimals: 1),
            Self.number(verticalAccuracy, decimals: 1),
            Self.number(speed, decimals: 2),
            Self.number(speedAccuracy, decimals: 2),
            Self.number(course, decimals: 1),
            Self.number(courseAccuracy, decimals: 1),
            activity ?? "",
        ].joined(separator: ",")
    }

    /// Parses one line written by `csvLine`. Returns nil for the header or a damaged line.
    init?(csvLine line: String) {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 12,
              let segment = Int(f[0]),
              let unix = Double(f[2]),
              let latitude = Double(f[3]),
              let longitude = Double(f[4])
        else { return nil }

        func value(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }

        self.init(
            segment: segment,
            time: Date(timeIntervalSince1970: unix),
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: value(5),
            altitude: value(6),
            verticalAccuracy: value(7),
            speed: value(8),
            speedAccuracy: value(9),
            course: value(10),
            courseAccuracy: value(11),
            activity: (f.count > 12 && !f[12].isEmpty) ? f[12] : nil
        )
    }

    private static func number(_ v: Double?, decimals: Int) -> String {
        guard let v, v.isFinite else { return "" }
        return String(format: "%.\(decimals)f", v)
    }
}

// MARK: - Shared helpers

enum TimeFormats {
    /// 2026-11-06T13:02:11.123Z
    static let utc = Date.ISO8601FormatStyle(includingFractionalSeconds: true,
                                             timeZone: TimeZone(secondsFromGMT: 0)!)

    /// 2026-11-06T08:02:11.123-05:00 (the style Google's location-history.json uses).
    static func local() -> Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZoneSeparator: .colon,
                                includingFractionalSeconds: true,
                                timeZone: .current)
    }
}

enum Geo {
    /// Great-circle distance in metres.
    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let r = 6_371_008.8
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Splits points into runs that share a segment number.
    static func segments(_ points: [TrackPoint]) -> [[TrackPoint]] {
        var result: [[TrackPoint]] = []
        for p in points {
            if let last = result.last?.last, last.segment == p.segment {
                result[result.count - 1].append(p)
            } else {
                result.append([p])
            }
        }
        return result
    }

    /// Path length in metres, not counting jumps across interruptions.
    static func length(_ points: [TrackPoint]) -> Double {
        var total = 0.0
        for seg in segments(points) {
            for (a, b) in zip(seg, seg.dropFirst()) { total += distance(a, b) }
        }
        return total
    }
}
