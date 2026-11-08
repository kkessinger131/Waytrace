import Foundation
#if canImport(Combine)
import Combine
#endif
import RoadKit

// The forms of road_to_kml_ui.html (Road, GPS history, OSM way, Batch), turned into
// command lines for the engine, batch rows and CSV.

enum RoadMode: String, CaseIterable, Identifiable, Codable {
    // Same order as the browser UI's tabs: GPS history first.
    case track, road, xml, batch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .road: return "Road"
        case .track: return "GPS history"
        case .xml: return "OSM way"
        case .batch: return "Batch"
        }
    }
}

enum SourceChoice: String, CaseIterable, Identifiable, Codable {
    case auto, osm, tiger, both = "osm,tiger"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "OSM, with TIGER/Line where OSM has nothing"
        case .osm: return "OSM only"
        case .tiger: return "TIGER/Line only"
        case .both: return "OSM and TIGER/Line, combined"
        }
    }
    func detail(track: Bool) -> String? {
        switch self {
        case .auto: return track ? "TIGER/Line steps in for stretches OSM couldn't match and for trips whose OSM data couldn't be downloaded."
                                 : "Per county, so TIGER/Line fallback needs counties (DC excepted)."
        case .tiger: return track ? "The counties you passed through are found automatically, and each one's road file is downloaded."
                                  : "Needs counties, except in DC."
        default: return nil
        }
    }
}

enum OutlineChoice: String, CaseIterable, Identifiable, Codable {
    case on, both, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .on: return "Use where mapped"
        case .both: return "Combine with centerlines"
        case .off: return "Don't use"
        }
    }
}

struct Problem: Hashable {
    let field: String
    let message: String
}

/// "Width and output", shared by every form.
struct ShapeOptions: Codable, Equatable {
    var lanes = ""
    var leftWidth = ""
    var rightWidth = ""
    var output = ""
    var notes = ""
    var stripInner = false
    var wait = false

    func args(_ a: inout [String]) {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if let n = Int(t(lanes)), n != 0 { a += ["--lanes", String(n)] }
        if !t(leftWidth).isEmpty { a += ["--leftwidth", t(leftWidth)] }
        if !t(rightWidth).isEmpty { a += ["--rightwidth", t(rightWidth)] }
        if !t(output).isEmpty { a += ["--output", t(output)] }
        if !t(notes).isEmpty { a += ["--notes", t(notes)] }
        if stripInner { a.append("--strip-inner") }
        if wait { a.append("--wait") }
    }

    func problems() -> [Problem] {
        var p: [Problem] = []
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if !t(lanes).isEmpty && Int(t(lanes)) == nil { p.append(Problem(field: "lanes", message: "Extra lanes must be a whole number.")) }
        if !t(leftWidth).isEmpty && Double(t(leftWidth)) == nil { p.append(Problem(field: "leftwidth", message: "Left edge must be a number of meters.")) }
        if !t(rightWidth).isEmpty && Double(t(rightWidth)) == nil { p.append(Problem(field: "rightwidth", message: "Right edge must be a number of meters.")) }
        return p
    }

    func row(_ r: inout [String: String]) {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if let n = Int(t(lanes)), n != 0 { r["lanes"] = String(n) }
        if !t(leftWidth).isEmpty { r["leftwidth"] = t(leftWidth) }
        if !t(rightWidth).isEmpty { r["rightwidth"] = t(rightWidth) }
        if !t(output).isEmpty { r["output"] = t(output) }
        if !t(notes).isEmpty { r["notes"] = t(notes) }
        if stripInner { r["strip_inner"] = "yes" }
        if wait { r["wait"] = "yes" }
    }

    init() {}

    init(row r: [String: String]) {
        lanes = r["lanes"] ?? ""
        leftWidth = r["leftwidth"] ?? ""
        rightWidth = r["rightwidth"] ?? ""
        output = r["output"] ?? ""
        notes = r["notes"] ?? ""
        stripInner = BatchRows.isTrue(r["strip_inner"])
        wait = BatchRows.isTrue(r["wait"])
    }
}

func outlineArgs(_ o: OutlineChoice, _ a: inout [String]) {
    if o == .off { a.append("--no-outlines") } else if o == .both { a += ["--outlines", "both"] }
}

struct RoadForm: Codable, Equatable {
    var road = ""
    var state = ""
    var county = ""
    var city = ""
    var from = ""
    var to = ""
    var source = SourceChoice.auto
    var junctions = true
    var ramps = false
    var outlines = OutlineChoice.on
    var shape = ShapeOptions()

    func build() -> ([String], [Problem]) {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        var p: [Problem] = [], a: [String] = []
        if t(road).isEmpty { p.append(Problem(field: "road", message: "Enter a road name.")) }
        if t(state).isEmpty { p.append(Problem(field: "state", message: "Enter at least one state.")) }
        if t(from).isEmpty != t(to).isEmpty {
            p.append(Problem(field: t(from).isEmpty ? "from" : "to", message: "Give both ends of the stretch, or neither."))
        }
        if !t(city).isEmpty && Planning.splitList(state).count > 1 {
            p.append(Problem(field: "city", message: "City works with a single state."))
        }
        p += shape.problems()
        a += ["--road", t(road)]
        if !t(state).isEmpty { a += ["--state", t(state)] }
        if !t(county).isEmpty { a += ["--county", t(county)] }
        if !t(city).isEmpty { a += ["--city", t(city)] }
        if source != .auto { a += ["--source", source.rawValue] }
        if !t(from).isEmpty && !t(to).isEmpty { a += ["--from", t(from), "--to", t(to)] }
        if !junctions { a.append("--no-junctions") }
        if ramps { a.append("--ramps") }
        outlineArgs(outlines, &a)
        shape.args(&a)
        return (a, p)
    }

    var row: [String: String] {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        var r: [String: String] = ["road": t(road), "state": t(state), "county": t(county), "city": t(city)]
        if source != .auto { r["source"] = source.rawValue }
        if !t(from).isEmpty && !t(to).isEmpty { r["from"] = t(from); r["to"] = t(to) }
        if !junctions { r["junctions"] = "no" }
        if ramps { r["ramps"] = "yes" }
        if outlines == .off { r["outlines"] = "no" } else if outlines == .both { r["outlines"] = "both" }
        shape.row(&r)
        return r.filter { !$0.value.isEmpty }
    }

    init() {}

    init(row r: [String: String]) {
        road = r["road"] ?? ""; state = r["state"] ?? ""; county = r["county"] ?? ""; city = r["city"] ?? ""
        source = SourceChoice(rawValue: (r["source"] ?? "auto").lowercased().replacingOccurrences(of: " ", with: "")) ?? .auto
        from = r["from"] ?? ""; to = r["to"] ?? ""
        junctions = !BatchRows.isFalse(r["junctions"])
        ramps = BatchRows.isTrue(r["ramps"])
        outlines = BatchRows.outlineMode(r["outlines"])
        shape = ShapeOptions(row: r)
    }
}

enum DateKind: String, CaseIterable, Identifiable, Codable {
    case day, month, range, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "One day"
        case .month: return "A month"
        case .range: return "A range"
        case .all: return "Everything"
        }
    }
}

struct TrackForm: Codable, Equatable {
    /// Paths as given to --track (relative to the output folder when inside it).
    var files: [String] = []
    var dateKind = DateKind.day
    var day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    var month = Date()
    var rangeFrom = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    var rangeTo = Date()
    var drive = true, walk = true, bike = true, other = true
    var source = SourceChoice.auto
    var junctions = true
    var outlines = OutlineChoice.on
    var shape = ShapeOptions()

    static func ymd(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    var dateSpec: String {
        switch dateKind {
        case .day: return TrackForm.ymd(day)
        case .month: return String(TrackForm.ymd(month).prefix(7))
        case .range: return "\(TrackForm.ymd(rangeFrom))..\(TrackForm.ymd(rangeTo))"
        case .all: return "all"
        }
    }

    var modes: [String] {
        [("drive", drive), ("walk", walk), ("bike", bike), ("other", other)].filter(\.1).map(\.0)
    }

    func build() -> ([String], [Problem]) {
        var p: [Problem] = [], a: [String] = []
        if files.isEmpty { p.append(Problem(field: "files", message: "Add at least one file or recording.")) }
        if modes.isEmpty { p.append(Problem(field: "modes", message: "Pick at least one kind of trip.")) }
        if dateKind == .range && rangeTo < rangeFrom { p.append(Problem(field: "date", message: "The last day is before the first.")) }
        p += shape.problems()
        a += ["--track"] + (files.isEmpty ? ["<file>"] : files)
        a += ["--date", dateSpec]
        if source != .auto { a += ["--source", source.rawValue] }
        if !modes.isEmpty && modes.count < 4 { a += ["--travel-modes", modes.joined(separator: ",")] }
        if !junctions { a.append("--no-junctions") }
        outlineArgs(outlines, &a)
        shape.args(&a)
        return (a, p)
    }

    var row: [String: String] {
        var r: [String: String] = ["track": files.joined(separator: ";"), "date": dateSpec]
        if source != .auto { r["source"] = source.rawValue }
        if modes.count < 4 { r["travel_modes"] = modes.joined(separator: ",") }
        if !junctions { r["junctions"] = "no" }
        if outlines == .off { r["outlines"] = "no" } else if outlines == .both { r["outlines"] = "both" }
        shape.row(&r)
        return r.filter { !$0.value.isEmpty }
    }

    init() {}

    init(row r: [String: String]) {
        files = (r["track"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        source = SourceChoice(rawValue: (r["source"] ?? "auto").lowercased().replacingOccurrences(of: " ", with: "")) ?? .auto
        let d = (r["date"] ?? "").trimmingCharacters(in: .whitespaces)
        func date(_ s: String) -> Date? {
            let p = s.split(separator: "-").compactMap { Int($0) }
            guard p.count >= 2 else { return nil }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p.count > 2 ? p[2] : 1))
        }
        if d.isEmpty || d.lowercased() == "all" { dateKind = .all }
        else if d.contains("..") {
            dateKind = .range
            let parts = d.components(separatedBy: "..")
            if let a = date(parts[0]) { rangeFrom = a }
            if parts.count > 1, let b = date(parts[1]) { rangeTo = b }
        } else if d.count == 7, let m = date(d) { dateKind = .month; month = m }
        else if let x = date(d) { dateKind = .day; day = x }
        let modes = (r["travel_modes"] ?? "drive,walk,bike,other").lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        drive = modes.contains("drive"); walk = modes.contains("walk"); bike = modes.contains("bike"); other = modes.contains("other")
        junctions = !BatchRows.isFalse(r["junctions"])
        outlines = BatchRows.outlineMode(r["outlines"])
        shape = ShapeOptions(row: r)
    }
}

struct XMLForm: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable { case url, file; var id: String { rawValue } }
    var kind = Kind.url
    var url = ""
    var file = ""
    var road = ""
    var state = ""
    var from = ""
    var to = ""
    var shape = ShapeOptions()

    var sourcePath: String { (kind == .url ? url : file).trimmingCharacters(in: .whitespaces) }

    func build() -> ([String], [Problem]) {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        var p: [Problem] = [], a: [String] = []
        if sourcePath.isEmpty { p.append(Problem(field: kind == .url ? "url" : "file", message: "Give a link or a file.")) }
        if t(from).isEmpty != t(to).isEmpty { p.append(Problem(field: t(from).isEmpty ? "from" : "to", message: "Give both points, or neither.")) }
        for (f, v) in [("from", from), ("to", to)] where !t(v).isEmpty && (try? Planning.parseClipPoint(t(v))) == nil {
            p.append(Problem(field: f, message: "With a downloaded way, the ends of a stretch must be latitude,longitude points."))
        }
        p += shape.problems()
        a += ["--source", "xml", sourcePath.isEmpty ? "<link-or-file>" : sourcePath]
        if !t(road).isEmpty { a += ["--road", t(road)] }
        if !t(state).isEmpty { a += ["--state", t(state)] }
        if !t(from).isEmpty && !t(to).isEmpty { a += ["--from", t(from), "--to", t(to)] }
        shape.args(&a)
        return (a, p)
    }

    var row: [String: String] {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        var r: [String: String] = ["source": "xml " + sourcePath, "road": t(road), "state": t(state)]
        if !t(from).isEmpty && !t(to).isEmpty { r["from"] = t(from); r["to"] = t(to) }
        shape.row(&r)
        return r.filter { !$0.value.isEmpty }
    }

    init() {}

    init(row r: [String: String]) {
        let src = String((r["source"] ?? "").dropFirst(3)).trimmingCharacters(in: .whitespaces)
        if src.lowercased().hasPrefix("http") { kind = .url; url = src } else { kind = .file; file = src }
        road = r["road"] ?? ""; state = r["state"] ?? ""; from = r["from"] ?? ""; to = r["to"] ?? ""
        shape = ShapeOptions(row: r)
    }
}

/// The batch: rows as CSV columns, saved between launches.
enum BatchRows {
    static let columns = ["road", "state", "county", "city", "source", "from", "to", "track", "date", "travel_modes",
                          "output", "notes", "lanes", "leftwidth", "rightwidth", "junctions", "ramps", "outlines",
                          "strip_inner", "wait"]

    static func isTrue(_ v: String?) -> Bool { ["y", "yes", "1", "true", "x", "on"].contains((v ?? "").trimmingCharacters(in: .whitespaces).lowercased()) }
    static func isFalse(_ v: String?) -> Bool { ["n", "no", "0", "false", "off"].contains((v ?? "").trimmingCharacters(in: .whitespaces).lowercased()) }
    static func outlineMode(_ v: String?) -> OutlineChoice {
        let c = (v ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return c == "both" ? .both : isFalse(c) ? .off : .on
    }

    static func mode(_ r: [String: String]) -> RoadMode {
        if !(r["track"] ?? "").isEmpty { return .track }
        if (r["source"] ?? "").lowercased().hasPrefix("xml") { return .xml }
        return .road
    }

    static func summary(_ r: [String: String]) -> (what: String, kind: String, whereText: String) {
        let m = mode(r)
        let base = { (p: String) in p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? p }
        let what: String
        switch m {
        case .track: what = (r["track"] ?? "").split(separator: ";").map { base(String($0)) }.joined(separator: ", ")
        case .xml: what = r["road"] ?? base(String((r["source"] ?? "").dropFirst(4)))
        default: what = r["road"] ?? ""
        }
        var kind = m.title
        if let o = r["output"] { kind += " to \(o)" }
        if let n = r["notes"] { kind += ", “\(n)”" }
        let whereText: String
        if m == .track {
            whereText = (r["date"] ?? "all dates") + (r["travel_modes"].map { ", \($0)" } ?? "")
        } else {
            whereText = [r["city"], r["county"], r["state"]].compactMap { $0 }.joined(separator: ", ")
                + (r["from"].map { ", \($0) to \(r["to"] ?? "")" } ?? "")
        }
        return (what.isEmpty ? "(no name)" : what, kind, whereText)
    }

    static func escape(_ s: String?) -> String {
        let v = s ?? ""
        let needs = v.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" })
            || v.first?.isWhitespace == true || v.last?.isWhitespace == true
        return needs ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    static func csv(_ rows: [[String: String]]) -> String {
        var extra: [String] = []
        for r in rows { for k in r.keys.sorted() where !columns.contains(k) && !extra.contains(k) { extra.append(k) } }
        let cols = columns + extra
        return ([cols.joined(separator: ",")] + rows.map { r in cols.map { escape(r[$0]) }.joined(separator: ",") })
            .joined(separator: "\r\n") + "\r\n"
    }

    /// Rows of a CSV (empty cells dropped, blank and #-commented rows skipped).
    static func parse(_ text: String) -> [[String: String]] {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        let rows = CSVReader.rows(t).filter { !$0.isEmpty }
        guard let head = rows.first else { return [] }
        let names = head.map { h -> String in
            var s = h.trimmingCharacters(in: .whitespaces)
            while s.hasPrefix("-") { s.removeFirst() }
            return s.lowercased().replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression)
        }
        return rows.dropFirst().compactMap { r -> [String: String]? in
            guard r.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            if r.first?.trimmingCharacters(in: .whitespaces).hasPrefix("#") == true { return nil }
            var o: [String: String] = [:]
            for (i, h) in names.enumerated() where !h.isEmpty && i < r.count {
                let v = r[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { o[h] = v }
            }
            return o
        }
    }
}

/// The forms, the batch and the chosen tab, kept between launches.
@MainActor
final class RoadFormStore: ObservableObject {
    static let shared = RoadFormStore()

    @Published var mode: RoadMode { didSet { save() } }
    @Published var road: RoadForm { didSet { save() } }
    @Published var track: TrackForm { didSet { save() } }
    @Published var xml: XMLForm { didSet { save() } }
    @Published var batch: [[String: String]] { didSet { save() } }
    @Published var batchSource: SourceChoice? { didSet { save() } }
    @Published var batchWait: Bool { didSet { save() } }
    /// The batch row being edited in a form, if any.
    @Published var editing: (index: Int, mode: RoadMode)?

    private struct Saved: Codable {
        var mode: RoadMode, road: RoadForm, track: TrackForm, xml: XMLForm
        var batch: [[String: String]], batchSource: SourceChoice?, batchWait: Bool
    }

    private init() {
        let s = UserDefaults.standard.data(forKey: "roads.forms").flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        mode = s?.mode ?? .track
        road = s?.road ?? RoadForm()
        track = s?.track ?? TrackForm()
        xml = s?.xml ?? XMLForm()
        batch = s?.batch ?? []
        batchSource = s?.batchSource
        batchWait = s?.batchWait ?? false
    }

    private func save() {
        let s = Saved(mode: mode, road: road, track: track, xml: xml, batch: batch, batchSource: batchSource, batchWait: batchWait)
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "roads.forms") }
    }

    func build(_ m: RoadMode) -> ([String], [Problem]) {
        switch m {
        case .road: return road.build()
        case .track: return track.build()
        case .xml: return xml.build()
        case .batch: return (batchArgs, batch.isEmpty ? [Problem(field: "batch", message: "Add some rows first.")] : [])
        }
    }

    var batchArgs: [String] {
        var a: [String] = []
        if let s = batchSource { a += ["--source", s.rawValue] }
        if batchWait { a.append("--wait") }
        return a
    }

    func row(_ m: RoadMode) -> [String: String] {
        switch m {
        case .road: return road.row
        case .track: return track.row
        case .xml: return xml.row
        case .batch: return [:]
        }
    }

    /// Add the form as a batch row, or update the row being edited. Returns a message.
    func addToBatch(_ m: RoadMode) -> String {
        let r = row(m)
        if let e = editing, e.mode == m, e.index < batch.count {
            var merged = batch[e.index].filter { !BatchRows.columns.contains($0.key) }
            merged.merge(r) { $1 }
            batch[e.index] = merged
            editing = nil
            return "Updated batch row \(e.index + 1)."
        }
        batch.append(r)
        return "Added as row \(batch.count) of the batch."
    }

    func edit(_ i: Int) {
        let r = batch[i]
        let m = BatchRows.mode(r)
        switch m {
        case .road: road = RoadForm(row: r)
        case .track: track = TrackForm(row: r)
        case .xml: xml = XMLForm(row: r)
        case .batch: break
        }
        editing = (i, m)
        mode = m
    }

    /// "python road_to_kml.py ..." for the current tab.
    var command: String {
        if mode == .batch {
            return batch.isEmpty ? "Add rows to the batch to see its command."
                : OptionParser.shellQuote(["python", "road_to_kml.py", "--batch", "trips.csv"] + batchArgs)
                    + "\n\n(Save the rows as trips.csv first.)"
        }
        return OptionParser.shellQuote(["python", "road_to_kml.py"] + build(mode).0)
    }
}
