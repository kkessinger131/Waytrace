import Foundation

/// The Photos tab's KML: a line through the places your photos were taken, in the order
/// they were taken, with an optional marker at each one named by its file (IMG_1234). The
/// same file exif2kml.py made from an ExifTool export, plus each photo's time, so QGIS and
/// Google Earth can sort and filter by it.
enum PhotoPath {
    struct Point: Equatable, Sendable {
        /// The file name without its extension: IMG_1234.
        var name: String
        var time: Date
        var latitude: Double
        var longitude: Double
        var altitude: Double?
    }

    /// Which photos: one day, a range of days, or all of them (local time).
    enum Span: String, CaseIterable, Sendable {
        case day = "Day", range = "Range", all = "All"
    }

    /// The moments a span covers, from the start of its first day to the end of its last,
    /// or nil for all. The two ends of a range can be given either way round.
    static func interval(_ span: Span, day: Date, from: Date, to: Date, calendar: Calendar = .current) -> DateInterval? {
        switch span {
        case .all:
            return nil
        case .day:
            let start = calendar.startOfDay(for: day)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .range:
            let a = calendar.startOfDay(for: min(from, to))
            let b = calendar.startOfDay(for: max(from, to))
            return DateInterval(start: a, end: calendar.date(byAdding: .day, value: 1, to: b)!)
        }
    }

    /// photos_2026-11-20.kml, photos_2026-11-18_to_2026-11-20.kml or photos_all.kml.
    static func fileName(_ span: Span, day: Date, from: Date, to: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        switch span {
        case .all: return "photos_all.kml"
        case .day: return "photos_\(f.string(from: day)).kml"
        case .range:
            let a = f.string(from: min(from, to)), b = f.string(from: max(from, to))
            return a == b ? "photos_\(a).kml" : "photos_\(a)_to_\(b).kml"
        }
    }

    /// "Photo Path - IMG_0001 to IMG_0042", as exif2kml.py titled it.
    static func title(_ points: [Point]) -> String {
        let s = points.sorted { $0.time < $1.time }
        guard let first = s.first, let last = s.last else { return "Photo Path" }
        return "Photo Path - \(first.name) to \(last.name)"
    }

    static func kml(_ points: [Point], title: String, pins: Bool, calendar: Calendar = .current) -> String {
        let pts = points.sorted { $0.time < $1.time }
        let local = DateFormatter()
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let utc = ISO8601DateFormatter()
        func coord(_ p: Point) -> String {
            var s = String(format: "%.6f,%.6f", p.longitude, p.latitude)
            if let a = p.altitude { s += String(format: ",%.1f", a) }
            return s
        }
        var x: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<kml xmlns="http://www.opengis.net/kml/2.2">"#,
            "<Document>",
            "<name>\(escape(title))</name>",
            #"<Style id="path"><LineStyle><color>ff0000ff</color><width>4</width></LineStyle></Style>"#,
        ]
        if pins {
            x.append(#"<Style id="pin"><IconStyle><Icon><href>http://maps.google.com/mapfiles/kml/paddle/wht-circle-lv.png</href></Icon><scale>0.6</scale></IconStyle><LabelStyle><scale>0.7</scale></LabelStyle></Style>"#)
            for p in pts {
                x.append("<Placemark><name>\(escape(p.name))</name>"
                         + "<description>Taken \(local.string(from: p.time))</description>"
                         + "<TimeStamp><when>\(utc.string(from: p.time))</when></TimeStamp>"
                         + "<styleUrl>#pin</styleUrl><Point><coordinates>\(coord(p))</coordinates></Point></Placemark>")
            }
        }
        if pts.count >= 2 {
            x.append("<Placemark><name>Route Path</name><styleUrl>#path</styleUrl><LineString><tessellate>1</tessellate><coordinates>")
            x += pts.map(coord)
            x.append("</coordinates></LineString></Placemark>")
        }
        x += ["</Document>", "</kml>"]
        return x.joined(separator: "\n") + "\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
