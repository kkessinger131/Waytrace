import Foundation

/// A command-line mistake: argparse's parser.error(), exit code 2.
public struct UsageError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// road_to_kml.py's options, as argparse leaves them.
public struct Options: Equatable {
    public var road = ""
    public var state = ""
    public var city = ""
    public var county = ""
    public var clipFrom = ""
    public var clipTo = ""
    public var track: [String]?
    public var date: String?
    public var travelModes = "drive,walk,bike,other"
    public var output = ""
    public var notes = ""
    public var lanes = 0
    public var leftWidth: Double?
    public var rightWidth: Double?
    public var junctions = true
    public var ramps = false
    public var outlines = "on"
    public var wait = false
    public var source = ["auto"]
    public var stripInner = false
    public var listAliases = false
    public var batch = ""
    public var help = false

    public init() {}
}

/// An argparse-compatible reader for road_to_kml.py's command line: --opt value and
/// --opt=value, unique prefixes of long options, nargs="+" / "?", negative numbers as values.
public enum OptionParser {
    enum Kind { case value, int, float, plus, outlines, storeTrue, noOutlines, junctions, noJunctions, help }

    struct Spec {
        let flag: String
        let kind: Kind
        let metavar: String
        let help: String
    }

    static let outlineModes = ["on", "off", "both"]

    static let specs: [Spec] = [
        Spec(flag: "--help", kind: .help, metavar: "", help: "show this help message and exit"),
        Spec(flag: "--road", kind: .value, metavar: "ROAD", help: "Road name, e.g. \"Main Street\", \"US-1\", \"Cathedral Ave NW\". Common aliases are searched automatically (optional with --source xml if the XML has a single way)"),
        Spec(flag: "--state", kind: .value, metavar: "STATE", help: "US state(s), comma-delimited: names or postal codes, e.g. \"Texas\" or \"MD, VA, DC\". Required except for --source xml and --track."),
        Spec(flag: "--city", kind: .value, metavar: "CITY", help: "City name to narrow the OSM search (single --state only)"),
        Spec(flag: "--county", kind: .value, metavar: "COUNTY", help: "County name(s), comma-delimited, e.g. \"Harris County, Dallas County\". Each county goes with the listed state that has it; if several listed states have it, qualify it: \"Montgomery County (MD)\". States with no county listed are searched statewide."),
        Spec(flag: "--from", kind: .value, metavar: "CLIP_FROM", help: "Start of the stretch to keep: a cross street (\"Calvert St NW\") or \"lat,lon\". Use with --to."),
        Spec(flag: "--to", kind: .value, metavar: "CLIP_TO", help: "End of the stretch to keep: a cross street or \"lat,lon\". Use with --from."),
        Spec(flag: "--track", kind: .plus, metavar: "FILE", help: "Map GPS history instead of a named road: Google Maps Timeline exports (Timeline.json / location-history.json, Takeout Records.json or Semantic Location History files), GPX, KML or GeoJSON tracks."),
        Spec(flag: "--date", kind: .value, metavar: "DATE", help: "With --track: day(s) to map — 2026-10-30, 2026-10, 2026-10-01..2026-10-31, or all."),
        Spec(flag: "--travel-modes", kind: .value, metavar: "TRAVEL_MODES", help: "With --track: which trips to map (drive, walk, bike, other = mode unknown). Flights, trains and ferries are always skipped. Default: all four."),
        Spec(flag: "--output", kind: .value, metavar: "OUTPUT", help: "Output .kml filename (default: auto-generated, ending in _osm, _tiger or _osm_tiger)"),
        Spec(flag: "--notes", kind: .value, metavar: "NOTES", help: "Text added to the KML description"),
        Spec(flag: "--lanes", kind: .int, metavar: "LANES", help: "Override/add extra lanes to default width estimate"),
        Spec(flag: "--leftwidth", kind: .float, metavar: "LEFTWIDTH", help: "Distance (m) from centerline to left edge; negative puts that edge on the other side of the centerline (overrides default half-width)"),
        Spec(flag: "--rightwidth", kind: .float, metavar: "RIGHTWIDTH", help: "Distance (m) from centerline to right edge; negative puts that edge on the other side of the centerline (overrides default half-width)"),
        Spec(flag: "--junctions", kind: .junctions, metavar: "", help: "Fill intersections along the road (default: on)"),
        Spec(flag: "--no-junctions", kind: .noJunctions, metavar: "", help: ""),
        Spec(flag: "--ramps", kind: .storeTrue, metavar: "", help: "Also include ramps connected to the road (named-road searches; --track follows the ramps you actually used)"),
        Spec(flag: "--outlines", kind: .outlines, metavar: "{on,off,both}", help: "Mapped pavement outlines (OSM area:highway; needs OSM). on (default): use the outline where one exists and buffered centerlines elsewhere. both: outlines AND every buffered centerline, combined. off: buffered centerlines only (same as --no-outlines)"),
        Spec(flag: "--no-outlines", kind: .noOutlines, metavar: "", help: "Same as --outlines off"),
        Spec(flag: "--wait", kind: .storeTrue, metavar: "", help: "Keep retrying indefinitely if all mirrors are busy"),
        Spec(flag: "--source", kind: .plus, metavar: "MODE", help: "Data source(s): \"osm\", \"tiger\", \"osm,tiger\" (both, combined into one file), \"auto\" (OSM, falling back to TIGER/Line per county; default), or \"xml <url-or-path>\" to bypass Overpass entirely and load a way directly from OSM XML. TIGER/Line needs --county, except in DC. --track always uses OSM."),
        Spec(flag: "--strip-inner", kind: .storeTrue, metavar: "", help: "Remove all <innerBoundaryIs> blocks from the output KML"),
        Spec(flag: "--list-aliases", kind: .storeTrue, metavar: "", help: "Show the aliases that would be searched for --road, then exit (no downloads)"),
        Spec(flag: "--batch", kind: .value, metavar: "CSV", help: "Run every row of a CSV file (columns named like the options: road, state, county, city, source, from, to, track, date, output, notes, ...). Other options on the command line apply to every row."),
    ]

    /// Python 3.13+ argparse: "-1", "-.5", "-77.0,38.9" look like negative numbers, not options.
    static func looksNegative(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count >= 2, u[0] == "-" else { return false }
        if u[1].properties.numericType == .decimal { return true }
        return u.count >= 3 && u[1] == "." && u[2].properties.numericType == .decimal
    }

    /// Would argparse take this token as an option (rather than a value)?
    static func isOptionLike(_ s: String) -> Bool {
        guard s.hasPrefix("-"), s != "-" else { return false }
        if looksNegative(s) { return false }
        if s.contains(" ") && match(String(s.split(separator: "=", maxSplits: 1)[0])) == nil { return false }
        return true
    }

    /// The option a flag (or a unique prefix of one) names.
    static func match(_ flag: String) -> Spec? {
        if flag == "-h" { return specs[0] }
        if let s = specs.first(where: { $0.flag == flag }) { return s }
        return nil
    }

    static func resolve(_ flag: String) throws -> Spec? {
        if let s = match(flag) { return s }
        guard flag.hasPrefix("--") else { return nil }
        let hits = specs.filter { $0.flag.hasPrefix(flag) }
        if hits.count > 1 {
            throw UsageError("ambiguous option: \(flag) could match \(hits.map(\.flag).joined(separator: ", "))")
        }
        return hits.first
    }

    public static func parse(_ argv: [String]) throws -> Options {
        var o = Options()
        var extras: [String] = []
        var i = 0
        while i < argv.count {
            let tok = argv[i]
            i += 1
            if tok == "--" { extras += argv[i...]; break }
            guard isOptionLike(tok) else { extras.append(tok); continue }
            var flag = tok, explicit: String?
            if tok.hasPrefix("--"), let eq = tok.firstIndex(of: "=") {
                flag = String(tok[..<eq])
                explicit = String(tok[tok.index(after: eq)...])
            }
            guard let spec = try resolve(flag) else { extras.append(tok); continue }
            let name = spec.flag
            func values(min: Int, max: Int) throws -> [String] {
                if let explicit { return [explicit] }
                var out: [String] = []
                while i < argv.count && out.count < max && !isOptionLike(argv[i]) && argv[i] != "--" {
                    out.append(argv[i])
                    i += 1
                }
                if out.count < min {
                    throw UsageError("argument \(name): " + (max == 1 ? "expected one argument" : "expected at least one argument"))
                }
                return out
            }
            func noValue() throws {
                if let explicit { throw UsageError("argument \(name): ignored explicit argument \(AliasEngine.pyRepr(explicit))") }
            }
            switch spec.kind {
            case .help:
                try noValue()
                o.help = true
            case .value:
                let v = try values(min: 1, max: 1)[0]
                switch name {
                case "--road": o.road = v
                case "--state": o.state = v
                case "--city": o.city = v
                case "--county": o.county = v
                case "--from": o.clipFrom = v
                case "--to": o.clipTo = v
                case "--date": o.date = v
                case "--travel-modes": o.travelModes = v
                case "--output": o.output = v
                case "--notes": o.notes = v
                case "--batch": o.batch = v
                default: break
                }
            case .int:
                let v = try values(min: 1, max: 1)[0]
                guard let n = RoadWidths.pyInt(v) else { throw UsageError("argument \(name): invalid int value: \(AliasEngine.pyRepr(v))") }
                o.lanes = n
            case .float:
                let v = try values(min: 1, max: 1)[0]
                guard let x = RoadWidths.pyFloat(v) else { throw UsageError("argument \(name): invalid float value: \(AliasEngine.pyRepr(v))") }
                if name == "--leftwidth" { o.leftWidth = x } else { o.rightWidth = x }
            case .plus:
                let v = try values(min: 1, max: .max)
                if name == "--track" { o.track = v } else { o.source = v }
            case .outlines:
                let v = try values(min: 0, max: 1).first?.lowercased() ?? "on"
                guard outlineModes.contains(v) else {
                    throw UsageError("argument --outlines: invalid choice: \(AliasEngine.pyRepr(v)) (choose from on, off, both)")
                }
                o.outlines = v
            case .noOutlines: try noValue(); o.outlines = "off"
            case .junctions: try noValue(); o.junctions = true
            case .noJunctions: try noValue(); o.junctions = false
            case .storeTrue:
                try noValue()
                switch name {
                case "--ramps": o.ramps = true
                case "--wait": o.wait = true
                case "--strip-inner": o.stripInner = true
                case "--list-aliases": o.listAliases = true
                default: break
                }
            }
        }
        if !extras.isEmpty { throw UsageError("unrecognized arguments: " + extras.joined(separator: " ")) }
        return o
    }

    public static let usage = "usage: road_to_kml.py [-h] [--road ROAD] [--state STATE] [--city CITY] [--county COUNTY] "
        + "[--from CLIP_FROM] [--to CLIP_TO] [--track FILE [FILE ...]] [--date DATE] [--travel-modes TRAVEL_MODES] "
        + "[--output OUTPUT] [--notes NOTES] [--lanes LANES] [--leftwidth LEFTWIDTH] [--rightwidth RIGHTWIDTH] "
        + "[--junctions | --no-junctions] [--ramps] [--outlines [{on,off,both}]] [--no-outlines] [--wait] "
        + "[--source MODE [MODE ...]] [--strip-inner] [--list-aliases] [--batch CSV]"

    public static var helpText: String {
        var out = [usage, "", "Generate a KML road surface polygon from OpenStreetMap and/or TIGER/Line data, from a road name or from GPS history.", "", "options:"]
        for s in specs where !s.help.isEmpty {
            let head = s.flag == "--help" ? "-h, --help" : s.flag == "--junctions" ? "--junctions, --no-junctions"
                : s.metavar.isEmpty ? s.flag : "\(s.flag) \(s.metavar)"
            out.append("  \(head)")
            out.append("      \(s.help)")
        }
        return out.joined(separator: "\n")
    }

    /// Quote a command line the way a POSIX shell would read it back (for "Copy command").
    public static func shellQuote(_ argv: [String]) -> String {
        argv.map { a in
            if !a.isEmpty && a.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_./,:=+@%".unicodeScalars.contains($0) }) {
                return a
            }
            return "'" + a.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }.joined(separator: " ")
    }
}
