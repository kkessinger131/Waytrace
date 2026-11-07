import Foundation
import XCTest
@testable import RoadKit

// Ports of test_road_to_kml.py sections 1-3 and the mirror-stats and batch tests.

final class AliasTests: XCTestCase {
    func testMatcher() {
        let cases: [(String, String, [String], [String])] = [
            ("Cathedral Avenue Northwest", "dc", ["Cathedral Ave NW"], ["Cathedral Ave NE"]),
            ("MD 355", "md", ["State Rte 355", "MD- 355", "Rte 355"], ["State Rte 35", "US Hwy 355"]),
            ("US 1", "md", ["US Hwy 1", "US Hwy 1 Bus"], ["US Hwy 15", "Old Domain St"]),
            ("I-95", "md", ["I- 95", "Interstate 95"], ["I- 395", "I- 9"]),
            ("TX 71", "tx", ["State Hwy 71", "Hwy 71"], ["US Hwy 71", "Fm 71"]),
            ("Main St", "tx", ["Main St", "N Main St"], ["Domain St", "Main Ave"]),
            ("MD 355", "va", [], ["State Rte 355"]),
        ]
        for (q, st, pos, neg) in cases {
            let m = RoadMatcher(q, state: st)
            for c in pos { XCTAssertTrue(m.matches(c), "\(q) -> \(c)") }
            for c in neg { XCTAssertFalse(m.matches(c), "\(q) -/-> \(c)") }
        }
        XCTAssertFalse(RoadMatcher("x").matches(nil))
    }

    func testRenamesAreCountyScoped() {
        XCTAssertTrue(RoadMatcher("Langston Blvd", state: "va", county: "51013").matches("Lee Hwy"))
        XCTAssertFalse(RoadMatcher("Langston Blvd", state: "va").matches("Lee Hwy"))
        XCTAssertFalse(RoadMatcher("Lee Highway", state: "va", county: "51059").matches("Langston Blvd"))
        XCTAssertTrue(AliasEngine.renameHint("Lee Hwy", state: "va")?.contains("--county") ?? false)
        XCTAssertNil(AliasEngine.renameHint("Lee Hwy", state: "va", county: "51013"))
    }
}

final class PlanningTests: EngineTestCase {
    func testStates() throws {
        XCTAssertEqual(try engine.parseStates("Washington, DC").map(\.abbr), ["dc"])
        XCTAssertEqual(try engine.parseStates("WA, DC").map(\.abbr), ["wa", "dc"])
        XCTAssertEqual(try engine.parseStates("texas, Calif., N.Y., Penn, D.C.").map(\.abbr), ["tx", "ca", "ny", "pa", "dc"])
    }

    func testCounties() {
        for (name, st, want) in [("Prince Georges County", "md", "24033"), ("St. Mary's", "md", "24037"),
                                 ("Saint Louis City", "mo", "29510"), ("Fairfax", "va", "51059"),
                                 ("Fairfax City", "va", "51600"), ("Alexandria", "va", "51510"),
                                 ("Baltimore City", "md", "24510"), ("Orleans", "la", "22071"),
                                 ("anything", "dc", "11001")] {
            XCTAssertEqual(Planning.lookupCounty(name, st).fips, want, name)
        }
        XCTAssertNil(Planning.lookupCounty("King", "va").fips)
    }

    func testAreaPlan() throws {
        let areas = try engine.planSearchAreas(try engine.parseStates("MD, DC"), "Montgomery County")
        XCTAssertEqual(areas.map { "\($0.state.abbr!) \($0.fips!)" }, ["md 24031", "dc 11001"])
        XCTAssertThrowsError(try engine.planSearchAreas(try engine.parseStates("MD, PA"), "Montgomery County"))
        let q = try engine.planSearchAreas(try engine.parseStates("MD, PA"), "Montgomery County (MD)")
        XCTAssertEqual(q.map { "\($0.state.abbr!) \($0.county ?? "None")" }, ["md Montgomery County", "pa None"])
        XCTAssertEqual(try engine.planSearchAreas(try engine.parseStates("Maryland"), "Montgomery County, MD").count, 1)
    }

    func testFilenames() {
        let st = [StateInfo(abbr: "dc", name: "District of Columbia", typed: "DC")]
        XCTAssertEqual(Planning.defaultOutputName("Cathedral Ave NW", city: "", states: st, areas: [], sourceTags: ["tiger"]),
                       "Cathedral_Ave_NW_DC_tiger.kml")
        let long = Planning.defaultOutputName(String(repeating: "A Very Long Road ", count: 20), city: "", states: st,
                                              areas: [], sourceTags: ["osm", "tiger"])
        XCTAssertLessThanOrEqual(long.count, Planning.maxFilenameLength)
        XCTAssertTrue(long.hasSuffix("_osm_tiger.kml"))
    }

    func testOffsetBuffer() throws {
        let line = try Geometry.lineString([XY(0, 0), XY(100, 0)])        // heading east; left = north
        let band = try RoadGeom.offsetBuffer(line, 8, -5)                   // sidewalk 5..8 m left
        XCTAssertEqual(band.area, 300, accuracy: 1)
        XCTAssertTrue(band.contains(XY(50, 6.5)))
        XCTAssertFalse(band.contains(XY(50, 2)))
        XCTAssertEqual(try RoadGeom.offsetBuffer(line, 5, 2).area, 700, accuracy: 1)
        let right = try RoadGeom.offsetBuffer(line, -2, 6)                  // 2..6 m right
        XCTAssertTrue(right.contains(XY(50, -4)))
        XCTAssertEqual(right.area, 400, accuracy: 1)
    }

    func testCountyTableAgeReminder() {
        XCTAssertNil(Planning.checkCountyTableAge("2026-10-31", today: DayDate(2027, 10, 30)))
        XCTAssertTrue(Planning.checkCountyTableAge("2026-10-31", today: DayDate(2027, 11, 2))?.contains("days ago") ?? false)
        XCTAssertNotNil(DayDate(iso: countyFIPSUpdated))
    }

    func testTigerYears() {
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        engine.tigerYearFound = nil
        let years = engine.tigerYears()
        XCTAssertEqual(years.first, year)
        XCTAssertEqual(years.last, RoadToKML.tigerOldestYear)
        engine.tigerYearFound = 2024
        XCTAssertEqual(engine.tigerYears().first, 2024)
    }
}

final class NamedRoadTests: EngineTestCase {
    func testAliasOSMAndOutline() throws {
        var (code, out, p) = runMain(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm", "--no-junctions"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "Conn_Ave_NW_DC_osm.kml")
        var g = try readKML(p!)
        XCTAssertTrue(g.contains(World.at(4, 3, east: 5)))
        XCTAssertTrue(g.contains(World.at(1.5, 3, east: 9)), "outline should be used")
        XCTAssertFalse(g.contains(World.at(3.5, 3, east: 9)), "buffer elsewhere")
        runMain(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm", "--no-junctions", "--no-outlines", "--output", "x.kml"])
        XCTAssertFalse(try readKML("x.kml").contains(World.at(1.5, 3, east: 9)))
        (code, out, p) = runMain(["--road", "Conn Ave NW", "--state", "DC", "--source", "osm", "--no-junctions",
                                  "--outlines", "both", "--output", "b.kml"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("Combining 1 pavement outline(s) with the buffered centerlines"))
        g = try readKML("b.kml")
        XCTAssertTrue(g.contains(World.at(1.5, 3, east: 9)), "outline kept")
        XCTAssertTrue(g.contains(World.at(4, 3, east: 5)), "centerline kept")
    }

    func testOutlineModes() throws {
        let utm = CRS.utm(UTM(zone: 18))
        func layer() throws -> Layer {
            Layer([(try Geometry.lineString([XY(0, 0), XY(100, 0)]), ["highway": "primary"])], utm, "osm")
        }
        let narrow = try reproject(try Geometry.polygon([XY(10, -3), XY(90, -3), XY(90, 3), XY(10, 3)]), from: utm, to: .wgs84)
        let on = try layer(), both = try layer()
        XCTAssertEqual(try RoadToKML.applyOutlines([on], [narrow]), 1)
        XCTAssertEqual(try RoadToKML.applyOutlines([both], [narrow], keepLines: true), 1)
        XCTAssertEqual(on.lines.reduce(0) { $0 + $1.line.length }, 20, accuracy: 1)
        XCTAssertEqual(both.lines.reduce(0) { $0 + $1.line.length }, 100, accuracy: 0.01)
        XCTAssertEqual(on.polys.count, 1)
        XCTAssertEqual(both.polys.count, 1)
        XCTAssertEqual(try OptionParser.parse([]).outlines, "on")
        XCTAssertEqual(try OptionParser.parse(["--outlines"]).outlines, "on")
        XCTAssertEqual(try OptionParser.parse(["--outlines", "Both"]).outlines, "both")
        XCTAssertEqual(try OptionParser.parse(["--no-outlines"]).outlines, "off")
        XCTAssertEqual(try OptionParser.parse(["--outlines", "off"]).outlines, "off")
        XCTAssertThrowsError(try OptionParser.parse(["--outlines", "maybe"]))
        XCTAssertEqual(RoadToKML.batchRowArgs([("outlines", "both")]), ["--outlines", "both"])
        XCTAssertEqual(RoadToKML.batchRowArgs([("outlines", "no")]), ["--no-outlines"])
        XCTAssertEqual(RoadToKML.batchRowArgs([("outlines", "yes")]), ["--outlines"])
    }

    func testJunctionTrim() throws {
        let a = try Geometry.lineString([XY(-60, 20), XY(0, 0)]).buffer(10, cap: .flat, join: .mitre)
        let b = try Geometry.lineString([XY(0, 0), XY(0, -60)]).buffer(6, cap: .flat, join: .mitre)
        let disc = try RoadGeom.junctionDisc(XY(0, 0), [20, 12])!
        let r = RoadGeom.trimJunctionFill([disc], [a, b])
        XCTAssertEqual(r.trimmed, 1)
        XCTAssertEqual(r.kept, 0)
        let fill = r.fills[0]
        XCTAssertTrue(fill.within(try disc.buffer(1e-6)))
        XCTAssertTrue(fill.contains(XY(2, 2)), "notch between the road ends")
        XCTAssertFalse(try a.union(b).contains(XY(2, 2)))
        XCTAssertTrue(disc.contains(XY(8, 8)))
        XCTAssertFalse(fill.contains(XY(8, 8)), "bulge beyond the roads")
        let none = RoadGeom.trimJunctionFill([disc], [])
        XCTAssertEqual(none.trimmed, 0)
        XCTAssertEqual(none.kept, 1, "nothing to trim to")
        XCTAssertEqual(none.left.count, 1)
        XCTAssertEqual(none.left[0].x, 0, accuracy: 1e-6)
        XCTAssertEqual(none.left[0].y, 0, accuracy: 1e-6)
        XCTAssertTrue(none.left[0].reason.contains("No drawn road"))
        let failed = RoadGeom.trimJunctionFill([disc], [a, b], fault: "GEOS error")
        XCTAssertEqual(failed.kept, 1, "failure keeps the circle")
        XCTAssertEqual(failed.fills[0].area, disc.area, accuracy: 1e-9)
    }

    func pins(_ name: String) -> [(Double, Double, String)] {
        let t = text(name)
        let pm = try! NSRegularExpression(pattern: "<Placemark.*?</Placemark>", options: .dotMatchesLineSeparators)
        let pt = try! NSRegularExpression(pattern: "<Point[ >].*?<coordinates>(.*?)</coordinates>", options: .dotMatchesLineSeparators)
        let ds = try! NSRegularExpression(pattern: "<description>(.*?)</description>", options: .dotMatchesLineSeparators)
        let ns = t as NSString
        var out: [(Double, Double, String)] = []
        for m in pm.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let block = ns.substring(with: m.range)
            guard let g = Re.groups(pt, block), let c = g[1] else { continue }
            let p = c.split(separator: ",").map { Double($0)! }
            out.append((p[0], p[1], Re.groups(ds, block)?[1] ?? ""))
        }
        return out
    }

    func testPinsForJunctionsLeftRound() throws {
        let args = ["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm", "--no-outlines"]
        var (code, out, _) = runMain(args + ["--output", "ok.kml"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(pins("ok.kml").isEmpty, "every junction trimmed: no pins")
        engine.junctionTrimFault = "TopologyException"
        (code, out, _) = runMain(args + ["--output", "round.kml"])
        engine.junctionTrimFault = nil
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("each marked with a pin in the KML"))
        let got = pins("round.kml")
        XCTAssertFalse(got.isEmpty)
        XCTAssertTrue(text("round.kml").contains("Junctions left round ("))
        let newark = World.at(2, 3)
        XCTAssertTrue(got.contains { abs($0.0 - newark.x) < 1e-5 && abs($0.1 - newark.y) < 1e-5 })
        XCTAssertTrue(got.allSatisfy { $0.2.contains("Trimming failed: TopologyException") })
        XCTAssertTrue(try readKML("round.kml").contains(World.at(2, 3, east: 7.3, north: 1.5)))
    }

    func testJunctionsAndRamps() throws {
        let corner = World.at(2, 3, east: 7.3, north: 1.5)          // just past a 14 m road, into Newark St
        var (code, out, _) = runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm", "--no-outlines", "--output", "j.kml"])
        XCTAssertTrue(out.contains("Intersection fill trimmed to the roads"), out)
        runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm", "--no-outlines", "--no-junctions", "--output", "nj.kml"])
        XCTAssertFalse(try readKML("j.kml").contains(corner))
        XCTAssertFalse(try readKML("nj.kml").contains(corner))
        XCTAssertTrue(try readKML("j.kml").contains(World.at(2, 3, east: 6.5)))
        let n6100 = World.NODES[6100]!, n1025 = World.NODES[1025]!
        let rampMid = XY((n6100.lon + n1025.lon) / 2, (n6100.lat + n1025.lat) / 2)
        (code, out, _) = runMain(["--road", "I-95", "--state", "DC", "--source", "osm", "--ramps", "--no-outlines", "--output", "r.kml"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(try readKML("r.kml").contains(rampMid))
        runMain(["--road", "I-95", "--state", "DC", "--source", "osm", "--no-outlines", "--output", "nr.kml"])
        XCTAssertFalse(try readKML("nr.kml").contains(rampMid))
    }

    func testOldName() throws {
        let (code, out, p) = runMain(["--road", "Lee Hwy", "--state", "DC", "--source", "osm", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(try readKML(p!).contains(World.at(4, 2.5)))
    }

    func testClipOSM() throws {
        let (code, out, p) = runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                      "--from", "Macomb St NW", "--to", "Ordway St NW", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "Connecticut_Ave_NW_Macomb_St_NW_to_Ordway_St_NW_DC_osm.kml")
        let g = try readKML(p!)
        XCTAssertTrue(g.contains(World.at(2, 3)))
        XCTAssertTrue(g.contains(World.at(1, 3, north: -10)), "pad past the cross street")
        XCTAssertFalse(g.contains(World.at(0.5, 3)))
        XCTAssertFalse(g.contains(World.at(4, 3)))
    }

    func testClipPoints() throws {
        let a = World.ll(1, 3), b = World.ll(2, 3)
        let (code, out, _) = runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                      "--from", "\(a.lat),\(a.lon)", "--to", "\(b.lat),\(b.lon)", "--no-outlines", "--output", "p.kml"])
        XCTAssertEqual(code, 0, out)
        let g = try readKML("p.kml")
        XCTAssertTrue(g.contains(World.at(1.5, 3)))
        XCTAssertFalse(g.contains(World.at(3, 3)))
    }

    func testBadCrossStreet() {
        let (code, out, _) = runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "osm",
                                      "--from", "Nowhere St NW", "--to", "Ordway St NW"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(out.contains("Couldn't find 'Nowhere St NW' near the road"), out)
    }

    func testSourceErrors() {
        XCTAssertEqual(runMain(["--road", "x", "--state", "DC", "--source", "auto,osm"]).0, 2)
        XCTAssertEqual(runMain(["--road", "x", "--state", "DC", "--source", "bing"]).0, 2)
        let (_, out, _) = runMain(["--road", "Main St", "--state", "MD, VA", "--city", "Rockville"])
        XCTAssertTrue(out.contains("single --state"))
        XCTAssertTrue(RoadToKML.validate(["--road", "x", "--source", "bing"])?.contains("invalid mode") ?? false)
    }

    func testErrorReplyRotatesToNextServer() {
        fakes.nameOnceFails = true
        let (code, out, _) = runMain(["--road", "Cathedral Ave NW", "--state", "DC", "--source", "osm", "--no-outlines", "--no-junctions"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("couldn't finish the query"))
        XCTAssertTrue(out.contains("Attempt 2"))
        XCTAssertTrue(out.contains("Found 2 OSM way(s)"), out)
    }

    func testListAliasesOffline() {
        let (_, out, _) = runMain(["--road", "Cathedral Ave NW", "--state", "DC", "--list-aliases"])
        XCTAssertTrue(out.contains("Cathedral Avenue Northwest"))
        XCTAssertTrue(fakes.queries.isEmpty)
    }

    func testOptionParsing() throws {
        var o = try OptionParser.parse(["--road=Main St", "--sta", "TX", "--leftwidth", "-5", "--source", "osm", "tiger", "--wait"])
        XCTAssertEqual(o.road, "Main St")
        XCTAssertEqual(o.state, "TX")
        XCTAssertEqual(o.leftWidth, -5)
        XCTAssertEqual(o.source, ["osm", "tiger"])
        XCTAssertTrue(o.wait)
        o = try OptionParser.parse(["--track", "a.json", "b.gpx", "--no-junctions"])
        XCTAssertEqual(o.track, ["a.json", "b.gpx"])
        XCTAssertFalse(o.junctions)
        XCTAssertThrowsError(try OptionParser.parse(["--s", "x"]))          // --state or --source
        XCTAssertThrowsError(try OptionParser.parse(["--lanes", "two"]))
        XCTAssertThrowsError(try OptionParser.parse(["--road"]))
        XCTAssertThrowsError(try OptionParser.parse(["stray"]))
    }
}

final class TigerTests: EngineTestCase {
    func testDCWithoutCounty() {
        let (code, out, p) = runMain(["--road", "Cathedral Ave NW", "--state", "DC", "--source", "tiger"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "Cathedral_Ave_NW_DC_tiger.kml")
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        XCTAssertTrue(fakes.downloads.contains { $0 == ("ROADS", "11001", 2024) })
        XCTAssertTrue(fakes.downloads.contains { $0 == ("ROADS", "11001", year) })
    }

    func testFeatnamesAliasAndMultistate() {
        let (code, out, p) = runMain(["--road", "MD 355", "--state", "MD, DC", "--county", "Montgomery County",
                                      "--source", "osm,tiger", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("Rockville Pike; 1 found via TIGER alternate names"), out)
        XCTAssertEqual(p, "MD_355_Montgomery_County_MD_DC_osm_tiger.kml")
    }

    func testTigerNeedsCountyOutsideDC() {
        let (code, out, _) = runMain(["--road", "Main St", "--state", "MD, DC", "--source", "tiger"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(out.contains("requires --county for: Maryland"), out)
    }

    func testTigerClipAndJunctions() throws {
        let (code, out, p) = runMain(["--road", "Connecticut Ave NW", "--state", "DC", "--source", "tiger",
                                      "--from", "Macomb St NW", "--to", "Ordway St NW"])
        XCTAssertEqual(code, 0, out)
        let g = try readKML(p!)
        XCTAssertTrue(g.contains(World.at(2, 3)))
        XCTAssertFalse(g.contains(World.at(4, 3)))
        XCTAssertFalse(g.contains(World.at(2, 3, east: 7.3, north: 1.5)), "junction bulge trimmed")
        XCTAssertTrue(g.contains(World.at(2, 3, east: 6.5)))
    }

    func testCombinedSourcesWarning() {
        let (code, out, p) = runMain(["--road", "Cathedral Ave NW", "--state", "DC", "--source", "tiger,osm", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "Cathedral_Ave_NW_DC_osm_tiger.kml")
    }

    func testShapefileRoundTrip() throws {
        let rows = World.tigerRows()["11001"]!
        let z = try ShapefileWriter.zipped(stem: "t", columns: ["LINEARID", "FULLNAME", "MTFCC"], rows: rows.roads.map(\.0),
                                           shapes: rows.roads.map(\.1))
        let t = try XCTUnwrap(try Shapefile.readZip(z, ext: ".shp"))
        XCTAssertEqual(t.records.count, 12)
        XCTAssertEqual(t.records[0]["FULLNAME"], "Cathedral Ave NW")
        XCTAssertEqual(t.records[0].geometry?.coords.count, 6)
        XCTAssertEqual(t.records[0].geometry!.length, rows.roads[0].1.length, accuracy: 1e-12)
    }
}

final class MirrorStatsTests: EngineTestCase {
    func testEveryAttemptIsCountedAndKept() throws {
        let m = Overpass.mirrors
        var plan: [String] = []
        engine.services.overpassPost = { _, _ in
            let what = plan.removeFirst()
            switch what {
            case "504": throw NetError.http(504, "Gateway Timeout")
            case "refused": throw NetError.connection("Connection refused")
            case "busy": return OverpassReply(elements: [], remark: "runtime error: rate_limited")
            default: return OverpassReply(elements: [])
            }
        }
        plan = ["504", "refused", "busy", "ok"]
        XCTAssertNotNil(try engine.overpassJSON("[out:json];"))
        plan = ["ok"]
        _ = try engine.overpassJSON("[out:json];")
        let text = try String(contentsOf: engine.mirrorStats.path, encoding: .utf8)
        let data = try engine.mirrorStats.load().mirrors
        XCTAssertEqual(data[m[0]]?.outcomes, ["HTTP 504 Gateway Timeout": 1, "Succeeded": 1])
        XCTAssertEqual(data[m[1]]?.outcomes, [MirrorStats.connection: 1])
        XCTAssertEqual(data[m[2]]?.outcomes, [MirrorStats.busy: 1])
        XCTAssertEqual(data[m[3]]?.outcomes, ["Succeeded": 1])
        XCTAssertNotNil(text.range(of: NSRegularExpression.escapedPattern(for: m[0]) + "\\s+2\\s+1\\s+50\\.0%", options: .regularExpression))
        XCTAssertNotNil(text.range(of: NSRegularExpression.escapedPattern(for: m[4]) + "\\s+0\\s+0\\s+-\\s+never tried", options: .regularExpression))
        XCTAssertTrue(text.contains("HTTP 504 Gateway Timeout"))
    }

    func testDamagedFileIsSetAside() throws {
        let stats = MirrorStats(path: path("stats.txt"))
        var notes: [String] = []
        stats.note = { notes.append($0) }
        try "someone edited this\n".write(to: path("stats.txt"), atomically: true, encoding: .utf8)
        stats.record("https://example.org/api/interpreter", MirrorStats.succeeded, seconds: 1.0)
        XCTAssertTrue(notes.joined().contains("couldn't read the mirror tally"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tmp.path).contains { $0.contains(".unreadable-") })
        XCTAssertEqual(try stats.load().mirrors["https://example.org/api/interpreter"]?.outcomes, ["Succeeded": 1])
    }

    func testFileProblemsNeverStopARun() {
        let stats = MirrorStats(path: tmp.appendingPathComponent("no/such/dir/s.txt"))
        var notes: [String] = []
        stats.note = { notes.append($0) }
        stats.record("u", MirrorStats.succeeded, seconds: 1.0)
        stats.record("u", MirrorStats.succeeded, seconds: 1.0)
        XCTAssertEqual(notes.filter { $0.contains("couldn't update the mirror tally") }.count, 1)
    }
}

final class BatchTests: EngineTestCase {
    func testBatch() throws {
        let csv = """
        Road,State,From,To,Output,Junctions,Notes,Visited
        Connecticut Ave NW,DC,Macomb St NW,Ordway St NW,a.kml,no,lunch run,2026-10-30
        # commented out,,,,,,,
        Cathedral Ave NW,Atlantis,,,b.kml,,,
        Cathedral Ave NW,DC,,,c.kml,,,

        """
        try csv.replacingOccurrences(of: "\n", with: "\r\n").write(to: path("trips.csv"), atomically: true, encoding: .utf8)
        let (code, out, _) = runMain(["--batch", "trips.csv", "--source", "osm", "--no-outlines"])
        XCTAssertEqual(code, 1, out)                         // one row failed
        XCTAssertTrue(out.contains("ignoring column(s) visited"))
        XCTAssertTrue(out.contains("2 succeeded, 1 failed"), out)
        XCTAssertTrue(out.contains("State not recognised: 'Atlantis'"))
        XCTAssertTrue(exists("a.kml") && exists("c.kml"))
        XCTAssertTrue(text("a.kml").contains("lunch run"))
    }

    func testCSVReader() {
        let rows = CSVReader.rows("a,\"b,c\",\"d \"\"q\"\"\"\n\nx,\"multi\nline\",\n")
        XCTAssertEqual(rows, [["a", "b,c", "d \"q\""], [], ["x", "multi\nline", ""]])
    }
}
