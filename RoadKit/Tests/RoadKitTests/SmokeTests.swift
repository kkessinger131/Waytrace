import XCTest
@testable import RoadKit

final class GeometryCoreTests: XCTestCase {
    func testUTMMatchesPyproj() throws {
        // lon, lat, zone, easting, northing from pyproj (EPSG:4326 -> EPSG:326xx)
        let ref: [[Double]] = [[-77.07, 38.93, 18, 320570.2912216906, 4311045.851905919], [-77.5, 39.1, 18, 283811.48667843104, 4330849.418480337], [-74.0, 40.7, 18, 584482.3522822947, 4505935.869447077], [-80.9, 25.7, 17, 510033.05194554816, 2842465.219699777], [-122.4, 37.8, 10, 552821.3829931149, 4183794.4989348184], [-75.1, 39.9, 18, 491451.5906169893, 4416663.078042446], [-78.2, 38.2, 17, 745186.5470104385, 4231712.384172439]]
        for r in ref {
            let u = UTM(zone: Int(r[2]))
            let p = u.forward(lon: r[0], lat: r[1])
            XCTAssertEqual(p.x, r[3], accuracy: 0.001)
            XCTAssertEqual(p.y, r[4], accuracy: 0.001)
            let back = u.inverse(p)
            XCTAssertEqual(back.x, r[0], accuracy: 1e-9)
            XCTAssertEqual(back.y, r[1], accuracy: 1e-9)
        }
    }

    func testBufferAndOps() throws {
        let line = try Geometry.lineString([XY(0, 0), XY(100, 0)])
        let b = try line.buffer(7, quadSegs: 8, cap: .flat, join: .mitre)
        XCTAssertEqual(b.area, 1400, accuracy: 1e-6)
        let left = try line.singleSidedBuffer(8)
        XCTAssertTrue(left.contains(XY(50, 4)))
        XCTAssertFalse(left.contains(XY(50, -4)))
        XCTAssertEqual(left.area, 800, accuracy: 1)
        let u = try Geometry.unaryUnion([b, try Geometry.point(200, 0).buffer(5)])
        XCTAssertEqual(u.kind, .multiPolygon)
        XCTAssertEqual(u.polygonParts.count, 2)
        let tree = STRTree([BBox(0, 0, 1, 1), BBox(5, 5, 6, 6), BBox(0.5, 0.5, 2, 2)])
        XCTAssertEqual(tree.query(BBox(0.8, 0.8, 0.9, 0.9)), [0, 2])
        XCTAssertEqual(LineMath.substring([XY(0, 0), XY(10, 0), XY(10, 10)], 5, 15)!, [XY(5, 0), XY(10, 0), XY(10, 5)])
        let polys = try Geometry.polygonize([try Geometry.lineString([XY(0, 0), XY(1, 0), XY(1, 1), XY(0, 1), XY(0, 0)])])
        XCTAssertEqual(polys.count, 1)
    }
}
