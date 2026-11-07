import Foundation

/// road_tracks.py: reading GPS history (Google Timeline exports, Takeout files, GPX, KML,
/// GeoJSON) and turning it into trips.
public enum Tracks {
    // MARK: - Parsing helpers

    static let latLngRe = Re.compile("(-?\\d+(?:\\.\\d+)?)\\s*°?\\s*,\\s*(-?\\d+(?:\\.\\d+)?)")

    static func pyFloat(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return RoadWidths.pyFloat(s) }
        return nil
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// Python truthiness of a JSON value.
    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil: return false
        case is NSNull: return false
        case let s as String: return !s.isEmpty
        case let n as NSNumber: return n.doubleValue != 0
        case let a as [Any]: return !a.isEmpty
        case let d as [String: Any]: return !d.isEmpty
        default: return true
        }
    }

    /// `a or b` on JSON values.
    static func or(_ a: Any?, _ b: Any?) -> Any? { truthy(a) ? a : b }

    /// parse_latlng: (lat, lon) from "38.9°, -77.0°", "geo:38.9,-77.0", E7 dicts, etc.
    public static func parseLatLng(_ v: Any?) -> LatLon? {
        var lat = 0.0, lon = 0.0
        if let s0 = v as? String {
            var s = Py.strip(s0)
            if s.lowercased().hasPrefix("geo:") { s = String(s.dropFirst(4)) }
            guard let g = Re.groups(latLngRe, s), let a = g[1].flatMap(Double.init), let b = g[2].flatMap(Double.init) else { return nil }
            lat = a; lon = b
        } else if let d = v as? [String: Any] {
            var found = false
            for (la, lo, scale) in [("latitudeE7", "longitudeE7", 1e7), ("latE7", "lngE7", 1e7), ("lat", "lng", 1.0),
                                    ("lat", "lon", 1.0), ("latitude", "longitude", 1.0)] where d[la] != nil && d[lo] != nil {
                guard let a = pyFloat(d[la]), let b = pyFloat(d[lo]) else { return nil }
                lat = a / scale; lon = b / scale
                found = true
                break
            }
            if !found {
                for key in ["latLng", "LatLng", "point", "placeLocation", "location"] where d[key] != nil {
                    return parseLatLng(d[key])
                }
                return nil
            }
        } else {
            return nil
        }
        if (-90...90).contains(lat) && (-180...180).contains(lon) && !(lat == 0 && lon == 0) { return (lat, lon) }
        return nil
    }

    static let isoRe = Re.compile("^(\\d{4})-(\\d{2})-(\\d{2})(?:[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:[.,](\\d+))?)?)?\\s*(Z|[+-]\\d{2}(?::?\\d{2}(?::?\\d{2})?)?)?$",
                                  .caseInsensitive)

    /// parse_time: a timezone-aware moment from ISO strings or epoch seconds/milliseconds.
    /// A time with no offset is read as this device's local time.
    public static func parseTime(_ v: Any?) -> Stamp? {
        guard let v, !(v is NSNull) else { return nil }
        var epoch: Double?
        if let n = v as? NSNumber { epoch = n.doubleValue }
        if let s = v as? String {
            let t = Py.strip(s)
            if t.isEmpty { return nil }
            if t.count >= 10 && t.count <= 16 && t.allSatisfy({ $0.isASCII && $0.isNumber }) { epoch = Double(t) }
        }
        if var x = epoch {
            if x > 1e11 { x /= 1000 }
            return Stamp(Date(timeIntervalSince1970: x), offset: 0)
        }
        guard let s = v as? String, let g = Re.groups(isoRe, Py.strip(s)) else { return nil }
        var c = DateComponents()
        c.year = Int(g[1]!); c.month = Int(g[2]!); c.day = Int(g[3]!)
        c.hour = g[4].flatMap { Int($0) } ?? 0
        c.minute = g[5].flatMap { Int($0) } ?? 0
        c.second = g[6].flatMap { Int($0) } ?? 0
        guard let m = c.month, (1...12).contains(m), let d = c.day, d >= 1, d <= DayDate.daysIn(c.year!, m),
              c.hour! < 24, c.minute! < 60, c.second! < 60 else { return nil }
        let frac = g[7].map { Double("0." + String($0.prefix(6))) ?? 0 } ?? 0
        var cal = Calendar(identifier: .gregorian)
        if let tz = g[8] {
            var off = 0
            if tz.uppercased() != "Z" {
                let sign = tz.hasPrefix("-") ? -1 : 1
                let digits = tz.dropFirst().filter(\.isNumber)
                let h = Int(digits.prefix(2)) ?? 0
                let mi = digits.count >= 4 ? Int(digits.dropFirst(2).prefix(2)) ?? 0 : 0
                let se = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 0 : 0
                off = sign * (h * 3600 + mi * 60 + se)
            }
            cal.timeZone = TimeZone(secondsFromGMT: off)!
            guard let date = cal.date(from: c) else { return nil }
            return Stamp(date.addingTimeInterval(frac), offset: off)
        }
        cal.timeZone = .current
        guard let date = cal.date(from: c) else { return nil }
        return Stamp.local(date.addingTimeInterval(frac))
    }

    public static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371008.8
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let a = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 2 * r * asin(min(1.0, a.squareRoot()))
    }

    static func dist(_ a: TrackPoint, _ b: TrackPoint) -> Double { haversine(a.lat, a.lon, b.lat, b.lon) }

    /// parse_date_spec: "2026-10-30", "2026-10", "2026-10-01..2026-10-31", "..2026-10-31",
    /// "2026-10-01..", or "all". nil = all dates.
    public static func parseDateSpec(_ spec: String?) throws -> (first: DayDate?, last: DayDate?)? {
        guard let spec else { return nil }
        let s = Py.strip(spec).lowercased()
        if s.isEmpty || s == "all" { return nil }
        let bad = InputError("Can't read --date '\(spec)'. Use YYYY-MM-DD, YYYY-MM, a range like 2026-10-01..2026-10-31, or 'all'.")
        func one(_ part0: String, end: Bool) throws -> DayDate? {
            let part = Py.strip(part0)
            if part.isEmpty { return nil }
            let p = part.split(separator: "-", omittingEmptySubsequences: false)
            if p.count == 2, p[0].count == 4, p[1].count == 2, let y = Int(p[0]), let m = Int(p[1]) {
                guard (1...12).contains(m) else { throw bad }
                return end ? DayDate(y, m, DayDate.daysIn(y, m)) : DayDate(y, m, 1)
            }
            guard let d = DayDate(iso: part) else { throw bad }
            return d
        }
        if let r = s.range(of: "..") {
            return (try one(String(s[..<r.lowerBound]), end: false), try one(String(s[r.upperBound...]), end: true))
        }
        return (try one(s, end: false), try one(s, end: true))
    }

    // MARK: - File readers

    typealias Activity = (start: Stamp, end: Stamp, mode: String?)
    typealias Visit = (start: Stamp, end: Stamp)

    struct Read {
        var points: [TrackPoint] = []
        var activities: [Activity] = []
        var visits: [Visit] = []

        mutating func add(_ t: Stamp?, _ ll: LatLon?, acc: Double? = nil, mode: String? = nil, seg: String = "timeline") {
            if let ll { points.append(TrackPoint(t, ll.lat, ll.lon, acc, mode, seg)) }
        }
    }

    static func offsetTime(_ start: Stamp?, _ minutes: Any?) -> Stamp? {
        guard let start, let m = pyFloat(minutes) else { return nil }
        return start.adding(seconds: m * 60)
    }

    static func modeString(_ v: Any?) -> String? { truthy(v) ? str(v) : nil }

    /// Phone export semanticSegments, or the iPhone array (same item shapes).
    static func readTimelineSegments(_ items: [Any], _ r: inout Read) {
        for case let seg as [String: Any] in items {
            let st = parseTime(seg["startTime"]), et = parseTime(seg["endTime"])
            for case let p as [String: Any] in (seg["timelinePath"] as? [Any]) ?? [] {
                let t = parseTime(p["time"]) ?? offsetTime(st, p["durationMinutesOffsetFromStartTime"])
                r.add(t, parseLatLng(p["point"]))
            }
            if let act = seg["activity"] as? [String: Any] {
                let top = act["topCandidate"] as? [String: Any] ?? [:]
                let mode = modeString(or(top["type"], act["type"]))
                if let st, let et { r.activities.append((st, et, mode)) }
                r.add(st, parseLatLng(act["start"]), mode: mode)
                r.add(et, parseLatLng(act["end"]), mode: mode)
            }
            if seg["visit"] is [String: Any], let st, let et { r.visits.append((st, et)) }
        }
    }

    static func readRawSignals(_ items: [Any], _ r: inout Read, maxAcc: Double) {
        for case let sig as [String: Any] in items {
            guard let pos = sig["position"] as? [String: Any] else { continue }
            let acc = pyFloat(pos["accuracyMeters"])
            if let acc, acc > maxAcc { continue }
            r.add(parseTime(pos["timestamp"]), parseLatLng(or(pos["LatLng"], pos["latLng"])), acc: acc)
        }
    }

    static func readRecords(_ locs: [Any], _ r: inout Read, maxAcc: Double) {
        for case let rec as [String: Any] in locs {
            let acc = pyFloat(rec["accuracy"])
            if let acc, acc > maxAcc { continue }
            var mode: String?
            if let acts = rec["activity"] as? [Any], let first = acts.first as? [String: Any],
               let inner = first["activity"] as? [[String: Any]], !inner.isEmpty {
                var best = inner[0]
                for a in inner.dropFirst() where (pyFloat(a["confidence"]) ?? 0) > (pyFloat(best["confidence"]) ?? 0) { best = a }
                mode = str(best["type"])
            }
            r.add(parseTime(or(rec["timestamp"], rec["timestampMs"])), parseLatLng(rec), acc: acc, mode: mode)
        }
    }

    static func readSemanticHistory(_ objs: [Any], _ r: inout Read) {
        for case let o as [String: Any] in objs {
            if let seg = o["activitySegment"] as? [String: Any], !seg.isEmpty {
                let dur = seg["duration"] as? [String: Any] ?? [:]
                let st = parseTime(or(dur["startTimestamp"], dur["startTimestampMs"]))
                let et = parseTime(or(dur["endTimestamp"], dur["endTimestampMs"]))
                let wpath = seg["waypointPath"] as? [String: Any] ?? [:]
                let mode = modeString(or(seg["activityType"], wpath["travelMode"]))
                if let st, let et { r.activities.append((st, et, mode)) }
                r.add(st, parseLatLng(seg["startLocation"]), mode: mode)
                for case let p as [String: Any] in ((seg["simplifiedRawPath"] as? [String: Any])?["points"] as? [Any]) ?? [] {
                    r.add(parseTime(or(p["timestamp"], p["timestampMs"])), parseLatLng(p), mode: mode)
                }
                let wps = (wpath["waypoints"] as? [Any]) ?? []
                if !wps.isEmpty, let st, let et {
                    let n = Double(wps.count)
                    for (i, wp) in wps.enumerated() {           // no times: spread evenly
                        r.add(st.adding(seconds: et.seconds(since: st) * (Double(i + 1) / (n + 1))), parseLatLng(wp), mode: mode)
                    }
                }
                r.add(et, parseLatLng(seg["endLocation"]), mode: mode)
            }
            if let visit = o["placeVisit"] as? [String: Any], !visit.isEmpty {
                let dur = visit["duration"] as? [String: Any] ?? [:]
                if let st = parseTime(or(dur["startTimestamp"], dur["startTimestampMs"])),
                   let et = parseTime(or(dur["endTimestamp"], dur["endTimestampMs"])) {
                    r.visits.append((st, et))
                }
            }
        }
    }

    static func readGPX(_ root: MiniXMLNode, _ path: String, _ r: inout Read) {
        var n = 0
        for trk in root.iter() where trk.local == "trkseg" || trk.local == "rte" {
            n += 1
            let seg = "\(path)#\(n)"
            for pt in trk.children where pt.local == "trkpt" || pt.local == "rtept" {
                guard let lat = pt.get("lat").flatMap({ RoadWidths.pyFloat($0) }),
                      let lon = pt.get("lon").flatMap({ RoadWidths.pyFloat($0) }) else { continue }
                var t: Stamp?
                for c in pt.children where c.local == "time" { t = parseTime(c.text) }
                r.points.append(TrackPoint(t, lat, lon, nil, nil, seg))
            }
        }
    }

    static func readKML(_ root: MiniXMLNode, _ path: String, _ r: inout Read) {
        var n = 0
        for el in root.iter() {
            if el.local == "Track" {
                n += 1
                let whens = el.children.filter { $0.local == "when" }.map { parseTime($0.text) }
                let coords = el.children.filter { $0.local == "coord" }.map(\.text)
                for (i, c) in coords.enumerated() {
                    let parts = c.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                    if parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                        r.points.append(TrackPoint(i < whens.count ? whens[i] : nil, lat, lon, nil, nil, "\(path)#\(n)"))
                    }
                }
            } else if el.local == "LineString" {
                n += 1
                for child in el.children where child.local == "coordinates" {
                    for c in child.text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
                        let parts = c.split(separator: ",")
                        if parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                            r.points.append(TrackPoint(nil, lat, lon, nil, nil, "\(path)#\(n)"))
                        }
                    }
                }
            }
        }
    }

    static func readGeoJSON(_ data: [String: Any], _ path: String, _ r: inout Read) {
        let feats: [Any] = (data["type"] as? String) == "FeatureCollection" ? (data["features"] as? [Any]) ?? [] : [data]
        var n = 0
        for f in feats {
            guard let fd = f as? [String: Any], let geom = (fd["geometry"] ?? fd) as? [String: Any], !geom.isEmpty else { continue }
            var lines: [[Any]] = []
            if (geom["type"] as? String) == "LineString" { lines = [(geom["coordinates"] as? [Any]) ?? []] }
            else if (geom["type"] as? String) == "MultiLineString" { lines = ((geom["coordinates"] as? [Any]) ?? []).map { ($0 as? [Any]) ?? [] } }
            let times = ((fd["properties"] as? [String: Any])?["coordTimes"] as? [Any]) ?? []
            for line in lines {
                n += 1
                for (i, c) in line.enumerated() {
                    guard let xy = c as? [Any], xy.count >= 2, let lon = pyFloat(xy[0]), let lat = pyFloat(xy[1]) else { continue }
                    let t = i < times.count && times[i] is String ? parseTime(times[i]) : nil
                    r.points.append(TrackPoint(t, lat, lon, nil, nil, "\(path)#\(n)"))
                }
            }
        }
    }

    /// read_track_file: one GPS/history file -> (points, activities, visits, kind).
    static func readTrackFile(_ data: Data, path: String, maxAcc: Double = 40.0) throws -> (Read, String) {
        var r = Read()
        var head = data.prefix(2000)
        while let b = head.first, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C { head = head.dropFirst() }
        if head.first == UInt8(ascii: "<") || head.starts(with: [0xEF, 0xBB, 0xBF, UInt8(ascii: "<")]) {
            let root = try MiniXML.parse(data)
            if root.local == "gpx" {
                readGPX(root, path, &r)
                return (r, "GPX")
            }
            readKML(root, path, &r)
            return (r, "KML")
        }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) } catch {
            throw InputError("Can't read \(path): it isn't valid JSON, GPX or KML.")
        }
        let kind: String
        if let list = json as? [Any] {
            readTimelineSegments(list, &r)
            kind = "Google Timeline (iPhone export)"
        } else if let d = json as? [String: Any], d["semanticSegments"] != nil || d["rawSignals"] != nil {
            readTimelineSegments((d["semanticSegments"] as? [Any]) ?? [], &r)
            readRawSignals((d["rawSignals"] as? [Any]) ?? [], &r, maxAcc: maxAcc)
            kind = "Google Timeline (phone export)"
        } else if let d = json as? [String: Any], d["locations"] != nil {
            readRecords((d["locations"] as? [Any]) ?? [], &r, maxAcc: maxAcc)
            kind = "Google Takeout Records.json"
        } else if let d = json as? [String: Any], d["timelineObjects"] != nil {
            readSemanticHistory((d["timelineObjects"] as? [Any]) ?? [], &r)
            kind = "Google Takeout Semantic Location History"
        } else if let d = json as? [String: Any], let t = d["type"] as? String,
                  ["FeatureCollection", "Feature", "LineString", "MultiLineString"].contains(t) {
            readGeoJSON(d, path, &r)
            kind = "GeoJSON"
        } else {
            throw InputError("Don't recognise the format of \(path).")
        }
        return (r, kind)
    }
}
