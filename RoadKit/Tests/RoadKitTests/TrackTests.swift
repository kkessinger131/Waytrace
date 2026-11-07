import Foundation
import XCTest
@testable import RoadKit

// Ports of test_road_to_kml.py section 4 (GPS tracks).

/// A deterministic stand-in for random.gauss (the exact noise differs from Python's).
struct Gauss {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func uniform() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func next(_ sigma: Double) -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

func stamp(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double = 0, offsetHours: Int) -> Stamp {
    var c = DateComponents()
    c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
    return Stamp(cal.date(from: c)!.addingTimeInterval(s), offset: offsetHours * 3600)
}

func sameSpot(_ a: TrackPoint, _ b: TrackPoint) -> Bool { a.t == b.t && a.lat == b.lat && a.lon == b.lon }

enum TrackFixtures {
    static func gridNetwork(_ category: String) -> RoadNetwork {
        RoadNetwork(World.WAYS.filter { $0.id != 300 }, World.NODES, category: category, utm: UTM(longitudes: [World.LON0]))
    }

    static func walkPoints(_ cells: [(Int, Int)], _ step: Double) -> [LatLon] {
        var pts: [LatLon] = []
        for (p, q) in zip(cells, cells.dropFirst()) {
            let a = World.ll(Double(p.0), Double(p.1)), b = World.ll(Double(q.0), Double(q.1))
            let n = max(1, Int(Tracks.haversine(a.lat, a.lon, b.lat, b.lon) / step))
            for i in 0..<n {
                pts.append((a.lat + (b.lat - a.lat) * Double(i) / Double(n), a.lon + (b.lon - a.lon) * Double(i) / Double(n)))
            }
        }
        let last = cells.last!
        return pts + [World.ll(Double(last.0), Double(last.1))]
    }

    static func makeTrip(_ pts: [LatLon], _ category: String, noise: Double = 0, secs: Double = 2) -> Trip {
        var g = Gauss(seed: 3)
        let t0 = stamp(2026, 10, 30, 9, 0, offsetHours: -4)
        let out = pts.enumerated().map { i, p in
            TrackPoint(t0.adding(seconds: secs * Double(i)), p.lat + g.next(noise) * World.M_LAT, p.lon + g.next(noise) * World.M_LON,
                       nil, nil, "x")
        }
        return Trip(category, Tracks.downsample(out, category))
    }

    static func names(_ res: MatchResult, minLen: Double = 5) -> Set<String> {
        Set(res.lines.filter { $0.line.length > minLen }.compactMap { $0.tags["name"] })
    }
}

final class MatchingTests: XCTestCase {
    func testDenseNoisyDrive() throws {
        let net = TrackFixtures.gridNetwork("drive")
        let res = try Tracks.matchTrip(net, TrackFixtures.makeTrip(TrackFixtures.walkPoints([(0, 0), (0, 3), (4, 3), (4, 5)], 10), "drive", noise: 6))
        XCTAssertEqual(TrackFixtures.names(res), ["Cathedral Avenue Northwest", "Connecticut Avenue Northwest", "Porter Street Northwest"])
        XCTAssertEqual(res.lines.reduce(0) { $0 + $1.line.length }, 1800, accuracy: 40)
        XCTAssertEqual(res.breaks, 0)
        XCTAssertFalse(res.wayIDs.contains(90), "sidewalk used while driving")
        XCTAssertGreaterThanOrEqual(net.junctionNodes(res.nodes, res.wayIDs).count, 3)
    }

    func testSparsePointsRouteAroundCorners() throws {
        let net = TrackFixtures.gridNetwork("drive")
        let L = World.LAT0, O = World.LON0, A = World.DLAT, B = World.DLON
        let sparse: [LatLon] = [World.ll(0, 0), (L + 1.2 * A, O + 1.6 * B), (L + 3.5 * A, O + 2.6 * B), World.ll(5, 3)]
        let res = try Tracks.matchTrip(net, Trip("drive", sparse.map { TrackPoint(nil, $0.lat, $0.lon, nil, nil, "x") }))
        XCTAssertEqual(res.lines.reduce(0) { $0 + $1.line.length }, 1600, accuracy: 120)
        XCTAssertEqual(res.breaks, 0)
    }

    func testWalkUsesSidewalkWhenOnIt() throws {
        let net = TrackFixtures.gridNetwork("walk")
        let s = World.NODES[5001]!
        let pts: [LatLon] = (0..<17).map { (s.lat + Double($0) * World.DLAT / 4, s.lon) }
        let res = try Tracks.matchTrip(net, TrackFixtures.makeTrip(pts, "walk", noise: 1.5, secs: 20))
        XCTAssertTrue(res.wayIDs.contains(90))
    }
}

/// US 1 -> MD 410: with a point a minute, a smoothed Timeline point drifting toward a side
/// street used to pull the match through Sheridan St and 44th Ave.
final class CornerCutTests: XCTestCase {
    let LAT0 = 38.9660, LON0 = -76.9375

    func ll(_ east: Double, _ north: Double) -> LatLon {
        (LAT0 + north / 111_000.0, LON0 + east / (111_000.0 * cos(LAT0 * .pi / 180)))
    }

    func net() -> RoadNetwork {
        var nodes: [Int64: LatLon] = [:]
        func node(_ e: Double, _ n: Double) -> Int64 { let id = Int64(nodes.count + 1); nodes[id] = ll(e, n); return id }
        let x0 = node(0, 0), xs = node(4, 70), x44n = node(-480, 70), x44s = node(-480, -110)
        let us1n = node(25, 600), us1s = node(-12, -400), mid = node(-250, -55), w410 = node(-900, -200)
        let b1 = node(-240, 160), b2 = node(4, 160)
        let n42 = node(-240, 70)
        let ways = [
            NetWay(id: 1, tags: ["highway": "primary", "ref": "US 1"], nodes: [us1s, x0, xs, b2, us1n]),
            NetWay(id: 2, tags: ["highway": "primary", "ref": "MD 410"], nodes: [x0, mid, x44s, w410]),
            NetWay(id: 3, tags: ["highway": "residential", "name": "Sheridan St"], nodes: [xs, n42, x44n]),
            NetWay(id: 4, tags: ["highway": "residential", "name": "44th Ave"], nodes: [x44n, x44s]),
            NetWay(id: 5, tags: ["highway": "residential", "name": "Tuckerman St"], nodes: [b2, b1]),
            NetWay(id: 6, tags: ["highway": "residential", "name": "42nd Ave"], nodes: [b1, n42]),
        ]
        return RoadNetwork(ways, nodes, category: "drive", utm: UTM(zone: 18))
    }

    func match(_ gps: [(Double, Double)], minutes: Double = 1.0) throws -> Set<Int64> {
        let t0 = stamp(2026, 11, 5, 22, 6, offsetHours: -5)
        let pts = gps.enumerated().map { i, en in
            let p = ll(en.0, en.1)
            return TrackPoint(t0.adding(seconds: minutes * 60 * Double(i)), p.lat, p.lon, nil, "in passenger vehicle", "timeline", 1)
        }
        return try Tracks.matchTrip(net(), Trip("drive", pts)).wayIDs
    }

    func testSmoothedPointDoesntCutTheCorner() throws {
        for north in [-122.0, -92, -62, -30, -10] {
            XCTAssertEqual(try match([(22, 500), (-60, 5), (-560, north), (-900, -200)]), [1, 2], "\(north)")
        }
    }

    func testRealSideStreetTripIsKept() throws {
        XCTAssertTrue(Set<Int64>([3, 4]).isSubset(of: try match([(22, 500), (-250, 72), (-900, -200)])))
        XCTAssertTrue(Set<Int64>([3, 4]).isSubset(of: try match([(22, 500), (-250, 72), (-478, -20), (-900, -200)])))
    }

    func testRoundaboutRouteIsKept() throws {
        let got = try match([(22, 500), (-120, 162), (-242, 120), (-120, 68), (-560, -122)], minutes: 0.5)
        XCTAssertTrue(Set<Int64>([5, 6, 3]).isSubset(of: got), "\(got)")
    }
}

/// Google Timeline sometimes labels a drive as a stop, and puts an activity's start or end
/// point kilometres away.
final class TimelineQuirkTests: XCTestCase {
    let T0 = stamp(2026, 11, 5, 16, 40, offsetHours: -5)

    func pt(_ minute: Double, _ lat: Double, _ lon: Double, _ mode: String? = nil, _ act: Int? = nil) -> TrackPoint {
        TrackPoint(T0.adding(seconds: minute * 60), lat, lon, nil, mode, "timeline", act)
    }

    func driveUp16th(_ start: Int, _ end: Int) -> [TrackPoint] {
        (start...end).map { pt(Double($0), 38.917 + 0.0042 * Double($0 - start), -77.0364) }
    }

    func testDriveLabelledAsAStopIsKept() {
        let walk = (0..<7).map { pt(Double($0), 38.9185 - 0.0002 * Double($0), -77.0343, "walking", 0) }
        let moving = driveUp16th(8, 36)
        let after = (0..<10).map { pt(Double(37 + $0), 39.0352 + 0.004 * Double($0), -77.0364, "in passenger vehicle", 1) }
        let acts: [Tracks.Activity] = [(T0, T0.adding(seconds: 420), "walking"),
                                       (T0.adding(seconds: 36 * 60 + 16), T0.adding(seconds: 47 * 60), "in passenger vehicle")]
        let visits: [Tracks.Visit] = [(T0.adding(seconds: 7 * 60 + 10), T0.adding(seconds: 29 * 60)),
                                      (T0.adding(seconds: 29 * 60), T0.adding(seconds: 36 * 60 + 16))]
        var log: [String] = []
        let kept = Tracks.dropVisits(walk + moving + after, visits, activities: acts, log: { log.append($0) })
        XCTAssertEqual(kept.count, walk.count + moving.count + after.count)
        let drove = kept.filter { $0.t! >= T0.adding(seconds: 480) && $0.t! <= T0.adding(seconds: 36 * 60) }
        XCTAssertFalse(drove.isEmpty)
        XCTAssertTrue(drove.allSatisfy { TrackRules.category($0.mode) == "drive" }, "\(drove.map(\.mode))")
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].contains("as a stop, but the GPS moved"), log[0])
        XCTAssertTrue(log[0].contains("treating it as driving"), log[0])
    }

    func testRealStopIsStillDropped() {
        let pts = [pt(0, 39.7944, -75.5470), pt(1, 39.7981, -75.5475), pt(5, 39.7966, -75.5475),
                   pt(30, 39.7967, -75.5474), pt(65, 39.7856, -75.5462), pt(66, 39.7746, -75.5444)]
        let visits: [Tracks.Visit] = [(T0.adding(seconds: 50), T0.adding(seconds: 65 * 60 + 1))]
        var log: [String] = []
        let kept = Tracks.dropVisits(pts, visits, log: { log.append($0) })
        XCTAssertEqual(log, [])
        XCTAssertFalse(kept.contains { sameSpot($0, pts[2]) })
        XCTAssertFalse(kept.contains { sameSpot($0, pts[3]) })
    }

    func testStrayActivityPointIsIgnored() {
        let stray = pt(5.25, 39.168, -76.884, "in passenger vehicle")      // 25 km away for 15 s
        let pts = Tracks.stableSorted(driveUp16th(0, 10) + [stray]) { $0.t! < $1.t! }
        XCTAssertFalse(Tracks.dropSpikes(pts).contains { sameSpot($0, stray) })
        XCTAssertEqual(Tracks.dropSpikes(pts).count, 11)
        let far = pt(120, 39.5, -77.0)
        XCTAssertTrue(Tracks.dropSpikes(driveUp16th(0, 3) + [far]).contains { sameSpot($0, far) })
    }

    func testTimelineFileEndToEnd() throws {
        let day = "2026-11-05T"
        var segs: [[String: Any]] = [
            ["startTime": day + "16:40:00.000-05:00", "endTime": day + "16:47:10.000-05:00",
             "activity": ["start": "geo:38.918500,-77.034300", "end": "geo:38.917100,-77.033100",
                          "topCandidate": ["type": "walking"], "distanceMeters": "297"]],
            ["startTime": day + "16:47:10.000-05:00", "endTime": day + "17:09:02.000-05:00",
             "visit": ["topCandidate": ["semanticType": "Unknown", "placeLocation": "geo:38.995119,-77.036975"]]],
            ["startTime": day + "17:09:02.000-05:00", "endTime": day + "17:16:16.000-05:00",
             "visit": ["topCandidate": ["semanticType": "Unknown", "placeLocation": "geo:39.009518,-77.040222"]]],
            ["startTime": day + "17:16:16.000-05:00", "endTime": day + "17:30:00.000-05:00",
             "activity": ["start": "geo:39.167955,-76.884383", "end": "geo:39.0700,-77.0364",
                          "topCandidate": ["type": "in passenger vehicle"], "distanceMeters": "7768"]],
        ]
        let path: [[String: Any]] = (0..<44).map {
            ["point": String(format: "geo:%.6f,-77.036400", 38.917 + 0.0034 * Double($0)), "durationMinutesOffsetFromStartTime": "\(47 + $0)"]
        }
        segs.append(["startTime": "2026-11-05T21:00:00.000Z", "endTime": "2026-11-05T23:00:00.000Z", "timelinePath": path])
        let data = try JSONSerialization.data(withJSONObject: segs)
        let trips = try Tracks.loadTrips([("location-history.json", data)], dateSpec: "2026-11-05", log: { _ in })
        let drives = trips.filter { $0.category == "drive" }
        XCTAssertEqual(drives.count, 1, "\(trips.map { ($0.category, $0.points.count) })")
        let d = drives[0].points
        XCTAssertLessThan(d[0].lat, 38.925)
        XCTAssertGreaterThan(d.last!.lat, 39.05)
        XCTAssertTrue(d.allSatisfy { $0.lon < -77.0 }, "stray Columbia, MD point dropped")
    }
}

final class ParserTests: XCTestCase {
    func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testPhoneExport() throws {
        let d = json(["semanticSegments": [
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:20:00.000-04:00",
             "activity": ["start": ["latLng": "38.9300000°, -77.0700000°"], "end": ["latLng": "38.9350000°, -77.0650000°"],
                          "topCandidate": ["type": "IN_PASSENGER_VEHICLE"]]],
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "timelinePath": [["point": "38.9310000°, -77.0690000°", "time": "2026-10-30T09:05:00.000-04:00"],
                              ["point": "38.9330000°, -77.0670000°", "time": "2026-10-30T09:10:00.000-04:00"],
                              ["point": "38.9350000°, -77.0650000°", "time": "2026-10-30T10:30:00.000-04:00"]]],
            ["startTime": "2026-10-30T09:20:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "visit": ["topCandidate": ["placeLocation": ["latLng": "38.935°, -77.065°"]]]],
            ["startTime": "2026-10-31T12:00:00.000-04:00", "endTime": "2026-10-31T13:00:00.000-04:00",
             "activity": ["start": ["latLng": "38.8°, -77.0°"], "end": ["latLng": "39.8°, -78.0°"], "topCandidate": ["type": "FLYING"]]]],
            "rawSignals": [["position": ["LatLng": "38.9320000°, -77.0680000°", "accuracyMeters": 10, "timestamp": "2026-10-30T09:07:00.000-04:00"]],
                           ["position": ["LatLng": "38.9330000°, -77.0670000°", "accuracyMeters": 900, "timestamp": "2026-10-30T09:08:00.000-04:00"]]]])
        let (r, kind) = try Tracks.readTrackFile(d, path: "Timeline.json")
        XCTAssertTrue(kind.contains("phone"))
        XCTAssertEqual(r.points.count, 8)
        let trips = try Tracks.loadTrips([("Timeline.json", d)], dateSpec: "2026-10-30", log: { _ in })
        XCTAssertEqual(trips.map(\.category), ["drive"])
        XCTAssertFalse(trips[0].points.contains { $0.t?.format("H") == "10" }, "visit points dropped")
    }

    func testIPhoneRecordsSemantic() throws {
        let iphone = json([
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:30:00.000-04:00",
             "activity": ["start": "geo:38.930000,-77.070000", "end": "geo:38.935000,-77.065000", "topCandidate": ["type": "walking"]]],
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00",
             "timelinePath": [["point": "geo:38.931000,-77.069000", "durationMinutesOffsetFromStartTime": "5"],
                              ["point": "geo:38.933000,-77.067000", "durationMinutesOffsetFromStartTime": "15"]]]])
        XCTAssertEqual(try Tracks.loadTrips([("location-history.json", iphone)], dateSpec: "2026-10-30", log: { _ in }).map(\.category), ["walk"])
        let records = json(["locations": [
            ["latitudeE7": 389300000, "longitudeE7": -770700000, "timestamp": "2026-10-30T13:00:00Z", "accuracy": 10,
             "activity": [["activity": [["type": "IN_VEHICLE", "confidence": 80]]]]],
            ["latitudeE7": 389350000, "longitudeE7": -770650000, "timestampMs": "1761829500000", "accuracy": 10]]])
        var (r, kind) = try Tracks.readTrackFile(records, path: "Records.json")
        XCTAssertEqual(kind, "Google Takeout Records.json")
        XCTAssertEqual(r.points.count, 2)
        XCTAssertEqual(r.points[0].mode, "IN_VEHICLE")
        let semantic = json(["timelineObjects": [["activitySegment": [
            "startLocation": ["latitudeE7": 389300000, "longitudeE7": -770700000],
            "endLocation": ["latitudeE7": 389350000, "longitudeE7": -770650000],
            "duration": ["startTimestamp": "2026-10-30T13:00:00Z", "endTimestamp": "2026-10-30T13:20:00Z"],
            "activityType": "CYCLING", "waypointPath": ["waypoints": [["latE7": 389320000, "lngE7": -770680000]]]]]]])
        (r, kind) = try Tracks.readTrackFile(semantic, path: "2026_OCTOBER.json")
        XCTAssertEqual(r.points.count, 3)
        XCTAssertEqual(r.activities[0].mode, "CYCLING")
    }

    func testGPXKMLGeoJSON() throws {
        let gpx = "<?xml version=\"1.0\"?><gpx version=\"1.1\" xmlns=\"http://www.topografix.com/GPX/1/1\">"
            + "<trk><trkseg><trkpt lat=\"38.93\" lon=\"-77.07\"><time>2026-10-30T13:00:00Z</time></trkpt>"
            + "<trkpt lat=\"38.935\" lon=\"-77.065\"><time>2026-10-30T13:05:00Z</time></trkpt></trkseg></trk></gpx>"
        let kml = "<kml xmlns=\"http://www.opengis.net/kml/2.2\" xmlns:gx=\"http://www.google.com/kml/ext/2.2\">"
            + "<Placemark><gx:Track><when>2026-10-30T13:00:00Z</when><when>2026-10-30T13:05:00Z</when>"
            + "<gx:coord>-77.07 38.93 0</gx:coord><gx:coord>-77.065 38.935 0</gx:coord></gx:Track></Placemark></kml>"
        let geo = json(["type": "FeatureCollection", "features": [["type": "Feature", "properties": [String: Any](),
                        "geometry": ["type": "LineString", "coordinates": [[-77.07, 38.93], [-77.065, 38.935]]]]]])
        for (name, body, want) in [("t.gpx", Data(gpx.utf8), "GPX"), ("t.kml", Data(kml.utf8), "KML"), ("t.geojson", geo, "GeoJSON")] {
            let (r, k) = try Tracks.readTrackFile(body, path: name)
            XCTAssertEqual(k, want)
            XCTAssertEqual(r.points.count, 2, name)
        }
    }

    func testLongGapInsideOneDriveStaysOneTrip() throws {
        let path: [[String: Any]] = [0, 5, 25, 30].enumerated().map { i, m in
            ["point": String(format: "%.4f°, -77.07°", 38.93 + Double(i) * 0.01), "time": String(format: "2026-10-30T09:%02d:00.000-04:00", m)]
        }
        let act: [String: Any] = ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:40:00.000-04:00",
                                  "activity": ["topCandidate": ["type": "IN_PASSENGER_VEHICLE"]]]
        let seg: [String: Any] = ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00", "timelinePath": path]
        let one = try Tracks.loadTrips([("a.json", json(["semanticSegments": [act, seg]]))], dateSpec: "2026-10-30", log: { _ in })
        let two = try Tracks.loadTrips([("b.json", json(["semanticSegments": [seg]]))], dateSpec: "2026-10-30", log: { _ in })
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(two.count, 2)
    }

    func testDownloadBoxesCoverTheTrack() {
        let t0 = Stamp(Date(timeIntervalSince1970: 1_793_350_800), offset: 0)
        var pts = (0..<20).map { TrackPoint(t0.adding(seconds: 10 * Double($0)), 38.9 + Double($0) * 0.0005, -77.0, nil, nil, "x") }
        pts += (0..<20).map { TrackPoint(t0.adding(seconds: 400 + 10 * Double($0)), 38.94 + Double($0) * 0.0005, -77.0, nil, nil, "x") }
        let boxes = Tracks.cellsToBoxes(Tracks.tripCells(Trip("drive", pts)))
        for p in pts { XCTAssertTrue(boxes.contains { $0.s <= p.lat && p.lat <= $0.n && $0.w <= p.lon && p.lon <= $0.e }) }
        func width(_ lat: Double) -> Double { boxes.filter { $0.s <= lat && lat < $0.n }.reduce(0) { $0 + $1.e - $1.w } }
        XCTAssertGreaterThan(width(38.925), width(38.897))
        for batch in Tracks.batchBoxes(boxes, maxKm2: 5) {
            XCTAssertLessThanOrEqual(batch.reduce(0) { $0 + Tracks.boxAreaKm2($1) }, 5 + batch.map(Tracks.boxAreaKm2).max()!)
        }
    }

    func testIPhoneUTCPathPointsGetLocalTime() throws {
        let d = json([
            ["startTime": "2026-10-30T23:10:00.000-04:00", "endTime": "2026-10-30T23:50:00.000-04:00",
             "activity": ["start": "geo:38.930000,-77.070000", "end": "geo:38.935000,-77.065000", "topCandidate": ["type": "in passenger vehicle"]]],
            ["startTime": "2026-10-31T02:00:00.000Z", "endTime": "2026-10-31T04:00:00.000Z",
             "timelinePath": [["point": "geo:38.931000,-77.069000", "durationMinutesOffsetFromStartTime": "75"],
                              ["point": "geo:38.933000,-77.067000", "durationMinutesOffsetFromStartTime": "80"]]]])
        let trips = try Tracks.loadTrips([("location-history.json", d)], dateSpec: "2026-10-30", log: { _ in })
        XCTAssertEqual(trips.count, 1)
        let times = trips[0].points.map { $0.t!.localTime.format("dd HH:mm") }
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0.hasPrefix("30 23:") }, "\(times)")
    }

    func testDates() throws {
        XCTAssertEqual(try Tracks.parseDateSpec("2026-02")?.first, DayDate(2026, 2, 1))
        XCTAssertEqual(try Tracks.parseDateSpec("2026-02")?.last, DayDate(2026, 2, 28))
        XCTAssertEqual(try Tracks.parseDateSpec("2026-10-01..2026-10-31")?.last, DayDate(2026, 10, 31))
        XCTAssertNil(try Tracks.parseDateSpec("all"))
        XCTAssertThrowsError(try Tracks.parseDateSpec("Oct 5"))
        var segs: [[String: Any]] = []
        for m in 1...3 {
            for d in 1..<20 {
                let day = String(format: "2026-%02d-%02d", m, d)
                segs.append(["startTime": day + "T09:00:00.000-04:00", "endTime": day + "T10:00:00.000-04:00",
                             "timelinePath": [["point": "38.93°, -77.07°", "time": day + "T09:00:00.000-04:00"]]])
            }
        }
        XCTAssertThrowsError(try Tracks.loadTrips([("big.json", json(["semanticSegments": segs]))], dateSpec: nil, log: { _ in }))
    }
}

final class TrackEndToEndTests: EngineTestCase {
    /// A drive along Cathedral then up Connecticut, Timeline-style (sparse).
    @discardableResult
    func timeline(_ name: String = "Timeline.json") throws -> String {
        let route = TrackFixtures.walkPoints([(0, 0), (0, 3), (4, 3)], 250)
        let pathItems: [[String: Any]] = route.enumerated().map { i, p in
            let s = 30 * i
            return ["point": String(format: "%.7f°, %.7f°", p.lat, p.lon),
                    "time": String(format: "2026-10-30T09:%02d:%02d.000-04:00", s / 60, s % 60)]
        }
        let data: [String: Any] = ["semanticSegments": [
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T09:30:00.000-04:00",
             "activity": ["start": ["latLng": pathItems[0]["point"]!], "end": ["latLng": pathItems.last!["point"]!],
                          "topCandidate": ["type": "IN_PASSENGER_VEHICLE"]]],
            ["startTime": "2026-10-30T09:00:00.000-04:00", "endTime": "2026-10-30T11:00:00.000-04:00", "timelinePath": pathItems]]]
        try JSONSerialization.data(withJSONObject: data).write(to: path(name))
        return name
    }

    func networkQueries() -> [String] { fakes.queries.filter { $0.contains("out skel qt") } }

    func testTrackRun() throws {
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_osm.kml")
        let g = try readKML(p!)
        for q in [World.at(0, 1.5), World.at(0, 2.5), World.at(2, 3), World.at(3.5, 3)] { XCTAssertTrue(g.contains(q), "\(q)") }
        XCTAssertFalse(g.contains(World.at(5, 2)), "Quebec St wasn't driven")
        XCTAssertFalse(g.contains(World.at(2, 3.8)), "Newark St east of Connecticut wasn't driven")
        XCTAssertTrue(g.contains(World.at(1.5, 3, east: 9)), "pavement outline used")
        XCTAssertTrue(g.contains(World.at(0, 3, east: -7.3, north: 1.5)), "turn corner filled")
        XCTAssertTrue(g.contains(World.at(0, 3, east: 2, north: -1)), "notch at the turn filled")
        XCTAssertFalse(g.contains(World.at(0, 3, east: 5, north: -5)), "bulge outside the turn trimmed")
    }

    func testTrackSurvivesOverpassErrors() throws {
        fakes.bigTrackRequestsFail = true
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("couldn't finish the query: runtime error"))
        XCTAssertTrue(out.contains("Splitting this request"), out)
        XCTAssertTrue(try readKML(p!).contains(World.at(2, 3)))
    }

    func testTrackAllDownloadsFail() throws {
        fakes.allTrackRequestsFail = true
        let (code, out, _) = runMain(["--track", try timeline(), "--date", "2026-10-30", "--source", "osm"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(out.contains("no OSM road data for these trips"), out)
        XCTAssertTrue(out.contains("re-run with --wait"))
        XCTAssertFalse(out.contains("0.0 km"))
    }

    func testTrackDefaultUsesOSMOnlyWhenItMatches() throws {
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_osm.kml")
        XCTAssertTrue(fakes.downloads.isEmpty, "no TIGER/Line downloads needed")
    }

    func testTrackTigerOnly() throws {
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30", "--source", "tiger"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_tiger.kml")
        XCTAssertTrue(out.contains("Counties: District of Columbia"), out)
        XCTAssertTrue(fakes.downloads.contains { $0 == ("ROADS", "11001", 2024) })
        XCTAssertTrue(networkQueries().isEmpty, "OSM shouldn't be asked")
        let g = try readKML(p!)
        for q in [World.at(0, 1.5), World.at(2, 3), World.at(3.5, 3)] { XCTAssertTrue(g.contains(q), "\(q)") }
        XCTAssertFalse(g.contains(World.at(5, 2)))
    }

    func testTrackOSMAndTigerCombined() throws {
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30", "--source", "osm,tiger"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_osm_tiger.kml")
        XCTAssertTrue(out.contains("km OSM + "), out)
    }

    func testTrackDefaultFallsBackWhenOSMIsDown() throws {
        fakes.allTrackRequestsFail = true
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_tiger.kml")
        XCTAssertTrue(out.contains("Using TIGER/Line to fill what OSM couldn't match"))
        XCTAssertTrue(try readKML(p!).contains(World.at(2, 3)))
    }

    func testTrackDefaultFillsARoadMissingFromOSM() throws {
        fakes.hideWays = Set(World.WAYS.filter { $0.tags["name"] == "Connecticut Avenue Northwest" }.map(\.id))
        let (code, out, p) = runMain(["--track", try timeline(), "--date", "2026-10-30", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertEqual(p, "track_2026-10-30_tiger.kml")
        XCTAssertTrue(out.contains("OSM went the long way round"), out)
        let g = try readKML(p!)
        XCTAssertTrue(g.contains(World.at(2.5, 3)), "Connecticut from TIGER/Line")
        XCTAssertTrue(g.contains(World.at(0, 1.5)), "Cathedral")
        for c in [2.0, 4.0] { XCTAssertFalse(g.contains(World.at(2.5, c)), "OSM's detour on column \(c) left out") }
    }

    func testTrackDownloadsEachAreaOnce() throws {
        try timeline()
        var text = try String(contentsOf: path("Timeline.json"), encoding: .utf8)
        let later = text.replacingOccurrences(of: "2026-10-30T09", with: "2026-10-30T15")
            .replacingOccurrences(of: "2026-10-30T10", with: "2026-10-30T16").replacingOccurrences(of: "2026-10-30T11", with: "2026-10-30T17")
        var a = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let b = try JSONSerialization.jsonObject(with: Data(later.utf8)) as! [String: Any]
        a["semanticSegments"] = (a["semanticSegments"] as! [Any]) + (b["semanticSegments"] as! [Any])
        text = String(decoding: try JSONSerialization.data(withJSONObject: a), as: UTF8.self)
        try text.write(to: path("Twice.json"), atomically: true, encoding: .utf8)
        engine.groupTripsOverride = { $0.map { [$0] } }        // force one group per trip
        let (code, out, p) = runMain(["--track", "Twice.json", "--date", "2026-10-30", "--no-outlines"])
        engine.groupTripsOverride = nil
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("Trip group 2 of 2"))
        XCTAssertTrue(out.contains("Downloading OSM roads for all trips at once: 1 request(s)"), out)
        XCTAssertEqual(networkQueries().count, 1, out)
        XCTAssertEqual(out.components(separatedBy: "km OSM").count - 1, 2, out)
        XCTAssertTrue(try readKML(p!).contains(World.at(2, 3)))
    }

    func testRequestCap() {
        XCTAssertEqual(Tracks.maxRequestKm2, 80.0)
        var boxes: [Box] = []
        for i in 0..<6 {
            let w = -77.1 + Double(i) * 0.05
            boxes.append((s: 38.9, w: w, n: 38.95, e: w + 0.05))
        }
        XCTAssertEqual(Tracks.batchBoxes(boxes).map(\.count), [3, 3])
    }

    func testTrackOptionErrors() throws {
        try timeline()
        XCTAssertEqual(runMain(["--track", "Timeline.json", "--road", "x"]).0, 2)
        XCTAssertEqual(runMain(["--track", "Timeline.json", "--source", "xml", "a.osm"]).0, 2)
        XCTAssertEqual(runMain(["--track", "Timeline.json", "--travel-modes", "boat"]).0, 2)
        let (code, out, _) = runMain(["--track", "Timeline.json", "--date", "2026-10-29"])
        XCTAssertEqual(code, 1)
        XCTAssertTrue(out.contains("No trips"))
    }

    func testBatchWithTrackRow() throws {
        try timeline("drive.json")
        try "road,state,track,date,output\nCathedral Ave NW,DC,,,a.kml\n,,drive.json,2026-10-30,b.kml\n"
            .write(to: path("jobs.csv"), atomically: true, encoding: .utf8)
        let (code, out, _) = runMain(["--batch", "jobs.csv", "--no-outlines"])
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(exists("a.kml") && exists("b.kml"))
        XCTAssertEqual(engine.outputs, ["a.kml", "b.kml"])
    }
}
