import Foundation

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case kml, records, gpx, csv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kml: return "KML: line, points and photos"
        case .records: return "Records.json for road_to_kml.py"
        case .gpx: return "GPX track"
        case .csv: return "CSV: every field"
        }
    }

    var detail: String {
        switch self {
        case .kml: return "Google Earth / My Maps. Each point carries its time, accuracy, speed, direction and altitude. Photos and videos taken during the recording are points too, named by file (IMG_1234), and the line runs through them in time order."
        case .records: return "Google Takeout format with per-point accuracy and travel mode: python road_to_kml.py --track <file> --date …"
        case .gpx: return "Works with almost any GPS tool, and with exiftool -geotag for photos."
        case .csv: return "The raw recording, one row per point."
        }
    }

    var symbol: String {
        switch self {
        case .kml: return "map"
        case .records: return "road.lanes"
        case .gpx: return "point.3.connected.trianglepath.dotted"
        case .csv: return "tablecells"
        }
    }

    func fileName(base: String) -> String {
        switch self {
        case .kml: return "\(base).kml"
        case .records: return "\(base)_Records.json"
        case .gpx: return "\(base).gpx"
        case .csv: return "\(base).csv"
        }
    }
}

struct ExportTrack: Sendable {
    let name: String
    let points: [TrackPoint]
    /// Times Waytrace wasn't running during the recording (from its log).
    var gaps: [RecordingLog.Gap] = []
}

enum Exporter {
    /// `photos` (one list per track) go into the KML only.
    static func write(_ format: ExportFormat, tracks: [ExportTrack], photos: [[PhotoMarker]] = [],
                      baseName: String, title: String, to directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(format.fileName(base: baseName))
        let data: Data
        switch format {
        case .kml: data = Data(kml(tracks, title: title, photos: photos).utf8)
        case .records: data = try records(tracks)
        case .gpx: data = Data(gpx(tracks, title: title).utf8)
        case .csv: data = Data(csv(tracks).utf8)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - KML (replaces the photo-EXIF → KML workflow)

    /// The recording's line and every point, plus a camera point for each photo or video in
    /// `photos` (one list per track). A photo is also a vertex of the line, slotted in by the
    /// time it was taken, and sits among the points in time order.
    static func kml(_ tracks: [ExportTrack], title: String, photos: [[PhotoMarker]] = []) -> String {
        let local = TimeFormats.local()
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"

        var x: [String] = []
        x.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        x.append(#"<kml xmlns="http://www.opengis.net/kml/2.2">"#)
        x.append("<Document>")
        x.append("<name>\(xml(title))</name>")
        x.append(#"<Style id="track"><LineStyle><color>ff0000ff</color><width>4</width></LineStyle></Style>"#)
        x.append(#"<Style id="fix"><IconStyle><scale>0.6</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle><LabelStyle><scale>0</scale></LabelStyle></Style>"#)
        x.append(#"<Style id="gap"><LineStyle><color>ff00ffff</color><width>2</width></LineStyle><IconStyle><color>ff00ffff</color><Icon><href>http://maps.google.com/mapfiles/kml/shapes/caution.png</href></Icon></IconStyle></Style>"#)
        if photos.contains(where: { !$0.isEmpty }) { x += photoStyles }

        for (i, track) in tracks.enumerated() where !track.points.isEmpty {
            // Points the motion coprocessor says you were standing still for (and that aren't
            // just a pause mid-walk or at a red light) are usually indoor GPS drift. They go
            // in their own folder, hidden until ticked, and the line skips them.
            let modes = recordsModes(track.points)
            let moving = zip(track.points, modes).filter { $0.1 != "STILL" }.map { $0.0 }
            let still = zip(track.points, modes).filter { $0.1 == "STILL" }.map { $0.0 }

            let markers = (i < photos.count ? photos[i] : []).sorted { $0.photo.taken < $1.photo.taken }
            let allPoints = track.points.sorted { $0.time < $1.time }

            x.append("<Folder>")
            x.append("<name>\(xml(track.name))</name>")

            x += trackLine(lineWithPhotos(moving, markers))

            // Points and photos together, in time order.
            if !moving.isEmpty || !markers.isEmpty {
                var items: [(time: Date, text: String)] = moving.map { ($0.time, placemark($0, visible: true, local: local, clock: clock)) }
                items += markers.map { ($0.photo.taken, photoPlacemark($0, points: allPoints, local: local, clock: clock)) }
                items.sort { $0.time < $1.time }
                x.append("<Folder>")
                x.append(markers.isEmpty ? "<name>Points</name>" : "<name>Points and photos (\(markers.count) photo\(markers.count == 1 ? "" : "s"))</name>")
                x += items.map(\.text)
                x.append("</Folder>")
            }
            if !still.isEmpty {
                x.append("<Folder>")
                x.append("<name>Stationary (hidden)</name>")
                x.append("<visibility>0</visibility>")
                for p in still { x.append(placemark(p, visible: false, local: local, clock: clock)) }
                x.append("</Folder>")
            }
            if !track.gaps.isEmpty {
                x.append("<Folder>")
                x.append("<name>Gaps (\(track.gaps.count))</name>")
                x.append("<description>Times Waytrace wasn't running. A yellow line joins the last point before each gap to the first one after.</description>")
                for g in track.gaps { x.append(gapPlacemark(g, clock: clock)) }
                x.append("</Folder>")
            }
            x.append("</Folder>")
        }
        x.append("</Document>")
        x.append("</kml>")
        return x.joined(separator: "\n") + "\n"
    }

    /// The red line of a recording, broken at interruptions.
    private static func trackLine(_ moving: [TrackPoint]) -> [String] {
        var x: [String] = []
        let lines = Geo.segments(moving).filter { $0.count >= 2 }
        if let first = moving.first, let last = moving.last, !lines.isEmpty {
            x.append("<Placemark>")
            x.append("<name>Track</name>")
            x.append("<TimeSpan><begin>\(TimeFormats.utc.format(first.time))</begin><end>\(TimeFormats.utc.format(last.time))</end></TimeSpan>")
            x.append("<styleUrl>#track</styleUrl>")
            x.append("<MultiGeometry>")
            for line in lines {
                x.append("<LineString><tessellate>1</tessellate><coordinates>")
                x.append(line.map(kmlCoordinate).joined(separator: " "))
                x.append("</coordinates></LineString>")
            }
            x.append("</MultiGeometry>")
            x.append("</Placemark>")
        }
        return x
    }

    /// The line's points with a vertex added at each photo, in time order. A photo joins the
    /// stretch of recording it was taken in (the points either side), or the nearer one in time
    /// when it falls between two stretches.
    static func lineWithPhotos(_ moving: [TrackPoint], _ markers: [PhotoMarker]) -> [TrackPoint] {
        guard !markers.isEmpty else { return moving }
        let sorted = moving.sorted { $0.time < $1.time }
        var out = sorted
        for m in markers {
            let t = m.photo.taken
            let (before, after) = PhotoPlacer.neighbors(at: t, in: sorted)
            let segment: Int
            if let b = before, let a = after {
                segment = b.segment == a.segment || t.timeIntervalSince(b.time) <= a.time.timeIntervalSince(t) ? b.segment : a.segment
            } else {
                segment = (before ?? after)?.segment ?? 0
            }
            out.append(TrackPoint(segment: segment, time: t, latitude: m.latitude, longitude: m.longitude))
        }
        // Stable: a photo taken at the same second as a point comes after it.
        return out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    private static func gapPlacemark(_ g: RecordingLog.Gap, clock: DateFormatter) -> String {
        let name = "Gap \(clock.string(from: g.from))–\(clock.string(from: g.to))"
        var s = "<Placemark><name>\(xml(name))</name><description>\(xml(Interruption.describe(g)))</description>"
        s += "<TimeSpan><begin>\(TimeFormats.utc.format(g.from))</begin><end>\(TimeFormats.utc.format(g.to))</end></TimeSpan>"
        s += "<styleUrl>#gap</styleUrl><ExtendedData>"
        var data = [("from_utc", TimeFormats.utc.format(g.from)), ("to_utc", TimeFormats.utc.format(g.to)),
                    ("minutes", String(Int((g.duration / 60).rounded()))), ("cause", g.cause)]
        if let d = g.distance { data.append(("moved_m", String(Int(d.rounded())))) }
        for (k, v) in data { s += "<Data name=\"\(k)\"><value>\(xml(v))</value></Data>" }
        s += "</ExtendedData>"
        if let a = g.before, let b = g.after {
            s += String(format: "<LineString><tessellate>1</tessellate><coordinates>%.7f,%.7f %.7f,%.7f</coordinates></LineString>",
                        a.longitude, a.latitude, b.longitude, b.latitude)
        } else if let p = g.before ?? g.after {
            s += String(format: "<Point><coordinates>%.7f,%.7f</coordinates></Point>", p.longitude, p.latitude)
        }
        return s + "</Placemark>"
    }

    // MARK: - Photo markers for the daily road map

    /// A "Photos" folder for a recording's roads_YYYY-MM-DD_HH-MM-SS.kml: one marker per photo
    /// or video taken during the recording, named by its file (IMG_1234), at the photo's own
    /// location, or for one without a location, on the recording between the points just
    /// before and after it. Each marker records the times of those two points, so the photos
    /// slot into the recording's sequence of points by time.
    static func dailyPhotoFolder(_ markers: [PhotoMarker], points: [TrackPoint]) -> String {
        let local = TimeFormats.local()
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss"
        let sorted = points.sorted { $0.time < $1.time }

        var x: [String] = ["<Folder>", "<name>Photos (\(markers.count))</name>"]
        x.append("<description>Photos and videos taken during the day's recordings. Yellow ones had no location of their own and were placed on the recording by the time they were taken.</description>")
        x += photoStyles
        for m in markers { x.append(photoPlacemark(m, points: sorted, local: local, clock: clock)) }
        x.append("</Folder>")
        return x.joined(separator: "\n")
    }

    /// Camera (or film) icons; yellow for a photo placed on the recording by time. The ids
    /// start with "wt" so they can't clash with styles in a file the folder is added to.
    private static let photoStyles: [String] = [
        #"<Style id="wtPhoto"><IconStyle><scale>1.1</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/camera.png</href></Icon></IconStyle></Style>"#,
        #"<Style id="wtPhotoByTime"><IconStyle><color>ff00ccff</color><scale>1.1</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/camera.png</href></Icon></IconStyle></Style>"#,
        #"<Style id="wtVideo"><IconStyle><scale>1.1</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/movies.png</href></Icon></IconStyle></Style>"#,
        #"<Style id="wtVideoByTime"><IconStyle><color>ff00ccff</color><scale>1.1</scale><Icon><href>http://maps.google.com/mapfiles/kml/shapes/movies.png</href></Icon></IconStyle></Style>"#,
    ]

    /// One photo or video, named by its file without the extension (IMG_1234), with when it
    /// was taken, where its position came from, and the recorded points just before and after.
    /// `points` must be in time order.
    private static func photoPlacemark(_ m: PhotoMarker, points: [TrackPoint],
                                       local: Date.ISO8601FormatStyle, clock: DateFormatter) -> String {
        let p = m.photo
        let label = (p.fileName as NSString).deletingPathExtension
        let (before, after) = PhotoPlacer.neighbors(at: p.taken, in: points)
        let how: String
        switch m.source {
        case .photo: how = "location from the \(p.isVideo ? "video" : "photo")"
        case .track: how = "no location in the \(p.isVideo ? "video" : "photo"), so placed on the recording by time"
        }
        var desc = "Taken \(clock.string(from: p.taken)), \(how)."
        if let b = before, let a = after {
            desc += " Between the recorded points at \(clock.string(from: b.time)) and \(clock.string(from: a.time))."
        } else if let b = before {
            desc += " After the last recorded point (\(clock.string(from: b.time)))."
        } else if let a = after {
            desc += " Before the first recorded point (\(clock.string(from: a.time)))."
        }
        var data: [(String, String)] = [
            ("file_name", p.fileName),
            ("time_local", local.format(p.taken)),
            ("time_utc", TimeFormats.utc.format(p.taken)),
            ("location_source", m.source == .photo ? "photo" : "recording"),
            ("latitude", String(format: "%.7f", m.latitude)),
            ("longitude", String(format: "%.7f", m.longitude)),
        ]
        if let b = before { data.append(("point_before_time", local.format(b.time))) }
        if let a = after { data.append(("point_after_time", local.format(a.time))) }
        let style = "wt" + (p.isVideo ? "Video" : "Photo") + (m.source == .photo ? "" : "ByTime")
        var s = "<Placemark><name>\(xml(label))</name><description>\(xml(desc))</description>"
        s += "<TimeStamp><when>\(TimeFormats.utc.format(p.taken))</when></TimeStamp>"
        s += "<styleUrl>#\(style)</styleUrl><ExtendedData>"
        for (k, v) in data { s += "<Data name=\"\(k)\"><value>\(xml(v))</value></Data>" }
        s += String(format: "</ExtendedData><Point><coordinates>%.7f,%.7f</coordinates></Point></Placemark>", m.longitude, m.latitude)
        return s
    }

    /// The KML with `folder` added at the end of its Document (replacing a Photos folder added
    /// before, so re-running a day doesn't double them). Nil if it isn't a KML document.
    static func addingFolder(_ folder: String, to kml: String) -> String? {
        var text = kml
        if let start = text.range(of: "<!-- waytrace-photos -->"),
           let end = text.range(of: "<!-- /waytrace-photos -->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        guard let close = text.range(of: "</Document>", options: .backwards) else { return nil }
        text.insert(contentsOf: "<!-- waytrace-photos -->\n" + folder + "\n<!-- /waytrace-photos -->\n", at: close.lowerBound)
        return text
    }

    /// One point marker, with every recorded field as ExtendedData (shown in the balloon).
    private static func placemark(_ p: TrackPoint, visible: Bool,
                                  local: Date.ISO8601FormatStyle, clock: DateFormatter) -> String {
        var data: [(String, String)] = [
            ("time_local", local.format(p.time)),
            ("time_utc", TimeFormats.utc.format(p.time)),
            ("latitude", String(format: "%.7f", p.latitude)),
            ("longitude", String(format: "%.7f", p.longitude)),
        ]
        if let v = p.horizontalAccuracy { data.append(("horizontal_accuracy_m", String(format: "%.1f", v))) }
        if let v = p.altitude { data.append(("altitude_m", String(format: "%.1f", v))) }
        if let v = p.verticalAccuracy { data.append(("vertical_accuracy_m", String(format: "%.1f", v))) }
        if let v = p.speed { data.append(("speed_mps", String(format: "%.2f", v))) }
        if let v = p.speedAccuracy { data.append(("speed_accuracy_mps", String(format: "%.2f", v))) }
        if let v = p.course { data.append(("course_deg", String(format: "%.1f", v))) }
        if let v = p.courseAccuracy { data.append(("course_accuracy_deg", String(format: "%.1f", v))) }
        if let v = p.activity { data.append(("activity", v)) }
        data.append(("segment", String(p.segment)))

        var s = "<Placemark><name>\(clock.string(from: p.time))</name>"
        if !visible { s += "<visibility>0</visibility>" }
        s += "<TimeStamp><when>\(TimeFormats.utc.format(p.time))</when></TimeStamp>"
        s += "<styleUrl>#fix</styleUrl><ExtendedData>"
        for (key, value) in data {
            s += "<Data name=\"\(key)\"><value>\(xml(value))</value></Data>"
        }
        s += "</ExtendedData><Point><coordinates>\(kmlCoordinate(p))</coordinates></Point></Placemark>"
        return s
    }

    // MARK: - Google Records.json (read by road_tracks.py with accuracy and mode per point)

    static func records(_ tracks: [ExportTrack]) throws -> Data {
        let local = TimeFormats.local()
        let all = tracks.flatMap { $0.points }.sorted { $0.time < $1.time }
        let modes = recordsModes(all)

        var locations: [[String: Any]] = []
        locations.reserveCapacity(all.count)
        for (p, mode) in zip(all, modes) {
            let stamp = local.format(p.time)
            var r: [String: Any] = [
                "latitudeE7": Int((p.latitude * 1e7).rounded()),
                "longitudeE7": Int((p.longitude * 1e7).rounded()),
                "timestamp": stamp,
            ]
            if let v = p.horizontalAccuracy { r["accuracy"] = rounded(v) }
            if let v = p.altitude { r["altitude"] = rounded(v) }
            if let v = p.verticalAccuracy { r["verticalAccuracy"] = rounded(v) }
            if let v = p.speed { r["velocity"] = rounded(v, 2) }
            if let v = p.course { r["heading"] = rounded(v) }
            if let v = p.speedAccuracy { r["velocityAccuracy"] = rounded(v, 2) }
            if let v = p.courseAccuracy { r["headingAccuracy"] = rounded(v) }
            if let mode {
                let candidate: [String: Any] = ["type": mode, "confidence": 100]
                let reading: [String: Any] = ["timestamp": stamp, "activity": [candidate]]
                r["activity"] = [reading]
            }
            locations.append(r)
        }
        return try JSONSerialization.data(withJSONObject: ["locations": locations],
                                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Core Motion label -> Google activity type, as road_tracks.py groups them
    /// (IN_VEHICLE = drive, WALKING/RUNNING = walk, ON_BICYCLE = bike, STILL = dropped).
    /// A "stationary" point between two points of the same moving type (a pause at a
    /// crosswalk or a red light) takes that type, so the trip isn't cut in two there.
    static func recordsModes(_ points: [TrackPoint]) -> [String?] {
        func google(_ label: String?) -> String? {
            switch label ?? "" {
            case "automotive": return "IN_VEHICLE"
            case "cycling": return "ON_BICYCLE"
            case "running": return "RUNNING"
            case "walking": return "WALKING"
            case "stationary": return "STILL"
            default: return nil
            }
        }
        var modes = points.map { google($0.activity) }
        var i = 0
        while i < modes.count {
            guard modes[i] == "STILL" else { i += 1; continue }
            var j = i
            while j < modes.count, modes[j] == "STILL" { j += 1 }
            // run of STILL is i..<j
            if i > 0, j < modes.count, let before = modes[i - 1], before == modes[j], before != "STILL" {
                for k in i..<j { modes[k] = before }
            }
            i = j
        }
        return modes
    }

    // MARK: - GPX 1.1

    static func gpx(_ tracks: [ExportTrack], title: String) -> String {
        var x: [String] = []
        x.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        x.append(#"<gpx version="1.1" creator="Waytrace" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:wt="urn:waytrace:gpx:1" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">"#)
        x.append("<metadata><name>\(xml(title))</name><time>\(TimeFormats.utc.format(Date()))</time></metadata>")
        for track in tracks where !track.points.isEmpty {
            x.append("<trk><name>\(xml(track.name))</name>")
            for seg in Geo.segments(track.points) {
                x.append("<trkseg>")
                for p in seg {
                    var s = String(format: #"<trkpt lat="%.7f" lon="%.7f">"#, p.latitude, p.longitude)
                    if let v = p.altitude { s += String(format: "<ele>%.1f</ele>", v) }
                    s += "<time>\(TimeFormats.utc.format(p.time))</time>"
                    var ext = ""
                    if let v = p.horizontalAccuracy { ext += String(format: "<wt:hacc>%.1f</wt:hacc>", v) }
                    if let v = p.verticalAccuracy { ext += String(format: "<wt:vacc>%.1f</wt:vacc>", v) }
                    if let v = p.speed { ext += String(format: "<wt:speed>%.2f</wt:speed>", v) }
                    if let v = p.speedAccuracy { ext += String(format: "<wt:speedacc>%.2f</wt:speedacc>", v) }
                    if let v = p.course { ext += String(format: "<wt:course>%.1f</wt:course>", v) }
                    if let v = p.courseAccuracy { ext += String(format: "<wt:courseacc>%.1f</wt:courseacc>", v) }
                    if let v = p.activity { ext += "<wt:activity>\(xml(v))</wt:activity>" }
                    if !ext.isEmpty { s += "<extensions>\(ext)</extensions>" }
                    s += "</trkpt>"
                    x.append(s)
                }
                x.append("</trkseg>")
            }
            x.append("</trk>")
        }
        x.append("</gpx>")
        return x.joined(separator: "\n") + "\n"
    }

    // MARK: - CSV

    static func csv(_ tracks: [ExportTrack]) -> String {
        var text = "session," + TrackPoint.csvHeader + "\n"
        for track in tracks {
            for p in track.points { text += "\(track.name),\(p.csvLine)\n" }
        }
        return text
    }

    // MARK: - Helpers

    private static func kmlCoordinate(_ p: TrackPoint) -> String {
        String(format: "%.7f,%.7f", p.longitude, p.latitude)
    }

    private static func rounded(_ v: Double, _ places: Int = 1) -> Double {
        let f = pow(10, Double(places))
        return (v * f).rounded() / f
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
