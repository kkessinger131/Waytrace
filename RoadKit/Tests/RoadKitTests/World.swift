import Foundation
import XCTest
@testable import RoadKit

/// The synthetic world of test_road_to_kml.py: a 6 x 6 grid of 200 m blocks in northwest DC,
/// with fakes for Overpass, Nominatim and the Census downloads.
enum World {
    static let LAT0 = 38.930, LON0 = -77.070
    static let DLAT = 200 / 111320.0
    static let DLON = 200 / (111320.0 * cos(LAT0 * .pi / 180))
    static let M_LON = 1 / (111320.0 * cos(LAT0 * .pi / 180))
    static let M_LAT = 1 / 111320.0

    static let ROWS = ["Cathedral", "Macomb", "Newark", "Ordway", "Porter", "Quebec"]
    static let COLS = [("36th", "Street", "residential"), ("35th", "Street", "residential"),
                       ("Wisconsin", "Avenue", "secondary"), ("Connecticut", "Avenue", "primary"),
                       ("Reno", "Road", "tertiary"), ("Nebraska", "Avenue", "secondary")]

    static func nodeID(_ r: Int, _ c: Int) -> Int64 { Int64(1000 + r * 10 + c) }
    static func ll(_ r: Double, _ c: Double) -> (lat: Double, lon: Double) { (LAT0 + r * DLAT, LON0 + c * DLON) }

    /// A point r rows north and c columns east of the grid's corner, nudged by meters.
    static func at(_ r: Double, _ c: Double, east: Double = 0, north: Double = 0) -> XY {
        let p = ll(r, c)
        return XY(p.lon + east * M_LON, p.lat + north * M_LAT)
    }

    static let built: (nodes: [Int64: LatLon], ways: [NetWay], areaPolys: [(Int64, [LatLon])]) = {
        var nodes: [Int64: LatLon] = [:]
        for r in 0..<6 { for c in 0..<6 { nodes[nodeID(r, c)] = ll(Double(r), Double(c)) } }
        var ways: [NetWay] = []
        var wid: Int64 = 1
        for (r, name) in ROWS.enumerated() {
            let kind = name == "Cathedral" ? "Avenue" : "Street"
            var tags: Tags = ["highway": "residential", "name": "\(name) \(kind) Northwest"]
            if name == "Porter" { tags["old_name"] = "Lee Highway" }
            ways.append(NetWay(id: wid, tags: tags, nodes: (0..<4).map { nodeID(r, $0) })); wid += 1
            ways.append(NetWay(id: wid, tags: tags, nodes: (3..<6).map { nodeID(r, $0) })); wid += 1
        }
        for (c, col) in COLS.enumerated() {
            ways.append(NetWay(id: wid, tags: ["highway": col.2, "name": "\(col.0) \(col.1) Northwest"],
                               nodes: (0..<6).map { nodeID($0, c) }))
            wid += 1
        }
        // Sidewalk beside Connecticut (driving must never use it)
        nodes[5001] = (LAT0, LON0 + 3 * DLON + 9 * M_LON)
        nodes[5002] = (LAT0 + 5 * DLAT, LON0 + 3 * DLON + 9 * M_LON)
        ways.append(NetWay(id: 90, tags: ["highway": "footway", "footway": "sidewalk"], nodes: [5001, 5002]))
        // A freeway east of the grid with a two-piece ramp to Nebraska Ave at row 2
        for i in 0..<4 { nodes[Int64(6000 + i)] = (LAT0 + Double(i) * 1.5 * DLAT, LON0 + 6.5 * DLON) }
        nodes[6100] = (LAT0 + 2 * DLAT, LON0 + 6.0 * DLON + 40 * M_LON)
        ways.append(NetWay(id: 91, tags: ["highway": "motorway", "ref": "I 95", "oneway": "yes"], nodes: [6000, 6001, 6002, 6003]))
        ways.append(NetWay(id: 92, tags: ["highway": "motorway_link", "oneway": "yes"], nodes: [6001, 6100]))
        ways.append(NetWay(id: 93, tags: ["highway": "motorway_link", "oneway": "yes"], nodes: [6100, nodeID(2, 5)]))
        // Mapped pavement outline: Connecticut between Macomb and Newark, 20 m wide
        let lat1 = LAT0 + DLAT + 10 * M_LAT, lat2 = LAT0 + 2 * DLAT - 10 * M_LAT, lonc = LON0 + 3 * DLON
        let ring: [LatLon] = [(lat1, lonc - 10 * M_LON), (lat1, lonc + 10 * M_LON), (lat2, lonc + 10 * M_LON),
                              (lat2, lonc - 10 * M_LON), (lat1, lonc - 10 * M_LON)]
        ways.append(NetWay(id: 300, tags: ["highway": "primary", "name": "Rockville Pike", "ref": "MD 355"], nodes: [8001, 8002]))
        nodes[8001] = (39.04, -77.10)
        nodes[8002] = (39.06, -77.11)
        return (nodes, ways, [(700, ring)])
    }()

    static var NODES: [Int64: LatLon] { built.nodes }
    static var WAYS: [NetWay] { built.ways }
    static var wayByID: [Int64: NetWay] { Dictionary(uniqueKeysWithValues: WAYS.map { ($0.id, $0) }) }
    static let areaWays: [String: Set<Int64>] = ["1": Set(built.ways.map(\.id).filter { $0 != 300 }), "2": [300]]

    /// TIGER: the same grid with Census-style names, plus Rockville Pike in MD.
    static func tigerRows() -> [String: (roads: [([String: String], Geometry)], featnames: [[String: String]])] {
        func line(_ pts: [(lat: Double, lon: Double)]) -> Geometry { try! Geometry.lineString(pts.map { XY($0.lon, $0.lat) }) }
        var rows: [([String: String], Geometry)] = []
        var lid = 1
        for (r, name) in ROWS.enumerated() {
            let kind = name == "Cathedral" ? "Ave" : "St"
            rows.append((["LINEARID": "\(lid)", "FULLNAME": "\(name) \(kind) NW", "MTFCC": "S1400"],
                         line((0..<6).map { ll(Double(r), Double($0)) })))
            lid += 1
        }
        let mt = ["residential": "S1400", "secondary": "S1200", "primary": "S1200", "tertiary": "S1400"]
        for (c, col) in COLS.enumerated() {
            let k = ["Street": "St", "Avenue": "Ave", "Road": "Rd"][col.1]!
            rows.append((["LINEARID": "\(lid)", "FULLNAME": "\(col.0) \(k) NW", "MTFCC": mt[col.2]!],
                         line((0..<6).map { ll(Double($0), Double(c)) })))
            lid += 1
        }
        let md: [([String: String], Geometry)] = [
            (["LINEARID": "240", "FULLNAME": "Rockville Pike", "MTFCC": "S1200"], line([NODES[8001]!, NODES[8002]!])),
            (["LINEARID": "241", "FULLNAME": "State Rte 35", "MTFCC": "S1200"], line([(39.1, -77.2), (39.11, -77.21)])),
        ]
        return ["11001": (rows, []), "24031": (md, [["LINEARID": "240", "FULLNAME": "State Rte 355"]])]
    }
}

/// One test's fakes: what was asked, and switches for failures.
final class FakeWorld {
    var queries: [String] = []
    var downloads: [(String, String, Int)] = []
    var bigTrackRequestsFail = false
    var allTrackRequestsFail = false
    var nameOnceFails = false
    var hideWays: Set<Int64> = []
    private var tigerCache: [String: Data] = [:]
    private var countyZip: Data?

    static let oom = OverpassReply(elements: [], remark: "runtime error: Query run out of memory using about 2048 MB of RAM.")
    static let bboxRe = try! NSRegularExpression(pattern: "\\]\\((-?[\\d.]+),(-?[\\d.]+),(-?[\\d.]+),(-?[\\d.]+)\\);")
    static let clauseRe = try! NSRegularExpression(pattern: "\\[\"(\\w+)\"~\"(.*?)\",i\\]\\(area:(\\d+)\\)")
    static let typesRe = try! NSRegularExpression(pattern: "\\[\"highway\"~\"\\^\\((.*?)\\)\\$\"\\]")
    static let idsRe = try! NSRegularExpression(pattern: "way\\(id:([\\d,]+)\\)")

    static func all(_ re: NSRegularExpression, _ s: String) -> [[String]] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
        }
    }

    static func geometry(_ w: NetWay) -> [(lat: Double, lon: Double)?] { w.nodes.map { World.NODES[$0].map { ($0.lat, $0.lon) } } }

    /// Overpass's own unescaping of a quoted value.
    static func unescape(_ s: String) -> String {
        var out = "", esc = false
        for ch in s {
            if esc { out.append(ch); esc = false } else if ch == "\\" { esc = true } else { out.append(ch) }
        }
        return out
    }

    func overpass(_ url: String, _ query: String) throws -> OverpassReply {
        queries.append(query)
        var elements: [OSMElement] = []
        if query.contains("area:highway") {
            for (aid, ring) in World.built.areaPolys {
                elements.append(OSMElement(type: "way", id: aid, tags: ["area:highway": "primary"], geometry: ring.map { ($0.lat, $0.lon) }))
            }
            return OverpassReply(elements: elements)
        }
        if query.contains("way(bn.n)") {
            let ids = Set(FakeWorld.all(FakeWorld.idsRe, query)[0][0].split(separator: ",").compactMap { Int64($0) })
            let byID = World.wayByID
            let roadNodes = Set(ids.compactMap { byID[$0] }.flatMap(\.nodes))
            let x = World.WAYS.filter { !Set($0.nodes).isDisjoint(with: roadNodes) }
            var out: [Int64: NetWay] = [:], order: [Int64] = []
            for w in x { out[w.id] = w; order.append(w.id) }
            if query.contains("_link$") {
                var frontier = x.filter { ($0.tags["highway"] ?? "").hasSuffix("_link") }
                for _ in 0..<2 {
                    let fn = Set(frontier.flatMap(\.nodes))
                    frontier = World.WAYS.filter { ($0.tags["highway"] ?? "").hasSuffix("_link") && !Set($0.nodes).isDisjoint(with: fn) && out[$0.id] == nil }
                    for w in frontier { out[w.id] = w; order.append(w.id) }
                }
            }
            for id in order {
                let w = out[id]!
                elements.append(OSMElement(type: "way", id: w.id, tags: w.tags, nodes: w.nodes, geometry: FakeWorld.geometry(w)))
            }
            return OverpassReply(elements: elements)
        }
        let boxes = FakeWorld.all(FakeWorld.bboxRe, query).map { $0.map { Double($0)! } }
        if !boxes.isEmpty && !query.contains("(area:") {
            if allTrackRequestsFail || (bigTrackRequestsFail && boxes.count > 1) { return FakeWorld.oom }
            let types = Set(FakeWorld.all(FakeWorld.typesRe, query)[0][0].split(separator: "|").map(String.init))
            func inside(_ n: Int64) -> Bool {
                guard let p = World.NODES[n] else { return false }
                return boxes.contains { $0[0] <= p.lat && p.lat <= $0[2] && $0[1] <= p.lon && p.lon <= $0[3] }
            }
            var used = Set<Int64>()
            for w in World.WAYS where !hideWays.contains(w.id) {
                if types.contains(w.tags["highway"] ?? "") && w.nodes.contains(where: inside) {
                    elements.append(OSMElement(type: "way", id: w.id, tags: w.tags, nodes: w.nodes))
                    used.formUnion(w.nodes)
                }
            }
            elements += used.sorted().map { OSMElement(type: "node", id: $0, lat: World.NODES[$0]!.lat, lon: World.NODES[$0]!.lon) }
            return OverpassReply(elements: elements)
        }
        if nameOnceFails {
            nameOnceFails = false
            return FakeWorld.oom
        }
        let clauses = FakeWorld.all(FakeWorld.clauseRe, query)
        precondition(!clauses.isEmpty, query)
        let area = clauses[0][2]
        let compiled = clauses.map { ($0[0], try! NSRegularExpression(pattern: FakeWorld.unescape($0[1]), options: .caseInsensitive)) }
        var used = Set<Int64>()
        for w in World.WAYS where World.areaWays[area]?.contains(w.id) ?? false {
            if compiled.contains(where: { k, rx in Re.matches(rx, w.tags[k] ?? "") }) {
                elements.append(OSMElement(type: "way", id: w.id, tags: w.tags, nodes: w.nodes))
                used.formUnion(w.nodes)
            }
        }
        elements += used.sorted().map { OSMElement(type: "node", id: $0, lat: World.NODES[$0]!.lat, lon: World.NODES[$0]!.lon) }
        return OverpassReply(elements: elements)
    }

    func tiger(_ layer: String, _ fips: String, _ year: Int) throws -> Data? {
        downloads.append((layer, fips, year))
        if year > 2024 { return nil }                  // pretend newer years aren't published yet
        guard let data = World.tigerRows()[fips] else { return nil }
        let key = "\(layer)/\(fips)"
        if let z = tigerCache[key] { return z }
        let z: Data
        if layer == "ROADS" {
            z = try ShapefileWriter.zipped(stem: "tl_x_roads", columns: ["LINEARID", "FULLNAME", "MTFCC"],
                                           rows: data.roads.map(\.0), shapes: data.roads.map(\.1))
        } else {
            let rows = data.featnames.isEmpty ? [["LINEARID": "0", "FULLNAME": ""]] : data.featnames
            z = try ShapefileWriter.zipped(stem: "tl_x_featnames", columns: ["LINEARID", "FULLNAME"], rows: rows,
                                           shapes: [], geometry: false)
        }
        tigerCache[key] = z
        return z
    }

    /// County outlines: DC around the grid, Montgomery County MD up north.
    func countyShapes(_ year: Int) throws -> Data? {
        downloads.append(("COUNTY", "us", year))
        if year > 2024 { return nil }
        if let z = countyZip { return z }
        let L0 = World.LON0, A0 = World.LAT0
        let z = try ShapefileWriter.zipped(
            stem: "cb", columns: ["GEOID", "STATEFP", "NAME", "NAMELSAD"],
            rows: [["GEOID": "11001", "STATEFP": "11", "NAME": "District of Columbia", "NAMELSAD": "District of Columbia"],
                   ["GEOID": "24031", "STATEFP": "24", "NAME": "Montgomery", "NAMELSAD": "Montgomery County"]],
            shapes: [Geometry.box(L0 - 0.03, A0 - 0.03, L0 + 0.05, A0 + 0.03), Geometry.box(-77.3, 39.0, -77.0, 39.3)],
            polygon: true)
        countyZip = z
        return z
    }

    struct Missing: Error {}

    var services: Services {
        Services(
            overpassPost: { [unowned self] in try self.overpass($0, $1) },
            downloadTiger: { [unowned self] in try self.tiger($0, $1, $2) },
            downloadCountyShapes: { [unowned self] in try self.countyShapes($0) },
            stateAreaID: { s in
                guard let v = ["District of Columbia": Int64(1), "Maryland": 2, "Virginia": 3, "Pennsylvania": 4][s] else { throw Missing() }
                return v
            },
            countyAreaID: { _, s in s == "Maryland" ? 2 : 5 },
            cityAreaID: { _, _ in 1 },
            fetchURL: { _ in throw NetError.connection("offline") })
    }
}

/// Each test gets a fresh folder, fakes and engine.
class EngineTestCase: XCTestCase {
    var tmp: URL!
    var fakes: FakeWorld!
    var engine: RoadToKML!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("r2k-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        fakes = FakeWorld()
        engine = RoadToKML(services: fakes.services, outputDirectory: tmp,
                           mirrorStatsPath: tmp.appendingPathComponent("overpass_mirror_stats.txt"))
        engine.sleeper = { _ in }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// run_main: (exit code, output text, result)
    @discardableResult
    func runMain(_ argv: [String]) -> (Int, String, String?) {
        fakes.queries = []
        fakes.downloads = []
        engine.log = RunLog()
        let r = engine.run(argv)
        return (r.code, engine.log.text, r.output)
    }

    func path(_ name: String) -> URL { tmp.appendingPathComponent(name) }

    func text(_ name: String) -> String { (try? String(contentsOf: path(name), encoding: .utf8)) ?? "" }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name).path) }

    /// read_kml: the union of the polygons in a KML written by road_to_kml.
    func readKML(_ name: String) throws -> Geometry {
        let t = text(name)
        func all(_ pattern: String, _ s: String) -> [String] {
            let re = try! NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
            let ns = s as NSString
            return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        func ring(_ block: String) -> [XY] {
            let c = all("<coordinates>.*?</coordinates>", block)[0]
            return c.dropFirst(13).dropLast(14).split(whereSeparator: { $0 == " " || $0 == "\n" }).map {
                let p = $0.split(separator: ",")
                return XY(Double(p[0])!, Double(p[1])!)
            }
        }
        var polys: [Geometry] = []
        for pm in all("<Polygon.*?</Polygon>", t) {
            let outer = ring(all("<outerBoundaryIs>.*?</outerBoundaryIs>", pm)[0])
            let inner = all("<innerBoundaryIs>.*?</innerBoundaryIs>", pm).map(ring)
            polys.append(try Geometry.polygon(outer, holes: inner))
        }
        return try Geometry.unaryUnion(polys)
    }
}

extension Geometry {
    func covers(_ p: XY) -> Bool { contains(p) }
}
