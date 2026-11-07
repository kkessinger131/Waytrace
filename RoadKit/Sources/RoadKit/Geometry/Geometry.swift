import Foundation
import geos

/// A planar coordinate: (x, y) in projected metres, or (lon, lat) in degrees.
public struct XY: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public func distance(to o: XY) -> Double { hypot(o.x - x, o.y - y) }
}

public struct GeometryError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The one GEOS context RoadKit uses. Runs are serialised (one job at a time), as in
/// road_to_kml_ui.py, so a single context is enough.
enum GEOSRuntime {
    static let handle: OpaquePointer = {
        let h = GEOS_init_r()!
        GEOSContext_setErrorMessageHandler_r(h, { message, _ in
            if let message { GEOSRuntime.lastError = String(cString: message) }
        }, nil)
        return h
    }()
    static var lastError = ""

    static func fail(_ what: String) -> GeometryError {
        let msg = lastError.isEmpty ? "\(what) failed" : lastError
        lastError = ""
        return GeometryError(message: msg)
    }
}

/// Geometry types, numbered as GEOS numbers them.
public enum GeometryKind: Int32, Sendable {
    case point = 0, lineString = 1, linearRing = 2, polygon = 3
    case multiPoint = 4, multiLineString = 5, multiPolygon = 6, collection = 7
}

/// An owned GEOS geometry: the Swift side of a Shapely geometry.
public final class Geometry: @unchecked Sendable, CustomStringConvertible {
    let g: OpaquePointer

    init(owning g: OpaquePointer) { self.g = g }

    deinit { GEOSGeom_destroy_r(GEOSRuntime.handle, g) }

    private static var ctx: OpaquePointer { GEOSRuntime.handle }

    private static func wrap(_ p: OpaquePointer?, _ what: String) throws -> Geometry {
        guard let p else { throw GEOSRuntime.fail(what) }
        return Geometry(owning: p)
    }

    // MARK: - Construction

    public static func point(_ p: XY) -> Geometry {
        Geometry(owning: GEOSGeom_createPointFromXY_r(ctx, p.x, p.y)!)
    }

    public static func point(_ x: Double, _ y: Double) -> Geometry { point(XY(x, y)) }

    private static func coordSeq(_ pts: [XY]) -> OpaquePointer {
        var buf = [Double]()
        buf.reserveCapacity(pts.count * 2)
        for p in pts { buf.append(p.x); buf.append(p.y) }
        return buf.withUnsafeBufferPointer {
            GEOSCoordSeq_copyFromBuffer_r(ctx, $0.baseAddress, UInt32(pts.count), 0, 0)!
        }
    }

    public static func lineString(_ pts: [XY]) throws -> Geometry {
        guard pts.count >= 2 else { throw GeometryError(message: "A line needs at least 2 points.") }
        return try wrap(GEOSGeom_createLineString_r(ctx, coordSeq(pts)), "LineString")
    }

    private static func ring(_ pts: [XY]) throws -> OpaquePointer {
        var r = pts
        if let f = r.first, let l = r.last, f != l { r.append(f) }
        guard r.count >= 4 else { throw GeometryError(message: "A polygon ring needs at least 3 points.") }
        guard let p = GEOSGeom_createLinearRing_r(ctx, coordSeq(r)) else { throw GEOSRuntime.fail("LinearRing") }
        return p
    }

    public static func polygon(_ shell: [XY], holes: [[XY]] = []) throws -> Geometry {
        let s = try ring(shell)
        var hs: [OpaquePointer?] = []
        for h in holes { hs.append(try ring(h)) }
        let nHoles = UInt32(hs.count)
        let p: OpaquePointer? = hs.withUnsafeMutableBufferPointer {
            GEOSGeom_createPolygon_r(ctx, s, $0.baseAddress, nHoles)
        }
        return try wrap(p, "Polygon")
    }

    public static func box(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> Geometry {
        // Shapely's box() goes counter-clockwise starting at (maxx, miny).
        try! polygon([XY(maxX, minY), XY(maxX, maxY), XY(minX, maxY), XY(minX, minY)])
    }

    /// A collection of copies of `parts` (Multi* when `kind` says so).
    public static func collection(_ parts: [Geometry], kind: GeometryKind = .collection) -> Geometry {
        if parts.isEmpty { return empty }
        var ptrs: [OpaquePointer?] = parts.map { GEOSGeom_clone_r(ctx, $0.g) }
        let n = UInt32(parts.count)
        let p: OpaquePointer? = ptrs.withUnsafeMutableBufferPointer {
            GEOSGeom_createCollection_r(ctx, Int32(kind.rawValue), $0.baseAddress, n)
        }
        return Geometry(owning: p!)
    }

    public static var empty: Geometry {
        Geometry(owning: GEOSGeom_createEmptyCollection_r(ctx, Int32(GeometryKind.collection.rawValue))!)
    }

    public static func multiPolygon(_ polys: [Geometry]) -> Geometry { collection(polys, kind: .multiPolygon) }

    public func clone() -> Geometry { Geometry(owning: GEOSGeom_clone_r(Geometry.ctx, g)!) }

    // MARK: - Inspection

    public var kind: GeometryKind { GeometryKind(rawValue: GEOSGeomTypeId_r(Geometry.ctx, g)) ?? .collection }

    /// Shapely's geom_type name.
    public var typeName: String {
        switch kind {
        case .point: return "Point"
        case .lineString: return "LineString"
        case .linearRing: return "LinearRing"
        case .polygon: return "Polygon"
        case .multiPoint: return "MultiPoint"
        case .multiLineString: return "MultiLineString"
        case .multiPolygon: return "MultiPolygon"
        case .collection: return "GeometryCollection"
        }
    }

    public var isEmpty: Bool { GEOSisEmpty_r(Geometry.ctx, g) == 1 }
    public var isValid: Bool { GEOSisValid_r(Geometry.ctx, g) == 1 }

    public var area: Double {
        var v = 0.0
        return GEOSArea_r(Geometry.ctx, g, &v) == 1 ? v : 0
    }

    public var length: Double {
        var v = 0.0
        return GEOSLength_r(Geometry.ctx, g, &v) == 1 ? v : 0
    }

    /// (minX, minY, maxX, maxY); nil for an empty geometry.
    public var bounds: BBox? {
        if isEmpty { return nil }
        var a = 0.0, b = 0.0, c = 0.0, d = 0.0
        guard GEOSGeom_getExtent_r(Geometry.ctx, g, &a, &b, &c, &d) == 1 else { return nil }
        return BBox(a, b, c, d)
    }

    public var description: String {
        "\(typeName)(\(isEmpty ? "empty" : String(format: "area=%.2f length=%.2f", area, length)))"
    }

    /// Number of parts (1 for a single geometry).
    public var partCount: Int { Int(GEOSGetNumGeometries_r(Geometry.ctx, g)) }

    /// Copies of the parts of a multi-geometry or collection.
    public var parts: [Geometry] {
        switch kind {
        case .multiPoint, .multiLineString, .multiPolygon, .collection:
            return (0..<partCount).map { i in
                Geometry(owning: GEOSGeom_clone_r(Geometry.ctx, GEOSGetGeometryN_r(Geometry.ctx, g, Int32(i)))!)
            }
        default:
            return [self]
        }
    }

    private static func coords(ofSeq seq: OpaquePointer?) -> [XY] {
        guard let seq else { return [] }
        var n: UInt32 = 0
        GEOSCoordSeq_getSize_r(ctx, seq, &n)
        var out = [XY]()
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            var x = 0.0, y = 0.0
            GEOSCoordSeq_getXY_r(ctx, seq, i, &x, &y)
            out.append(XY(x, y))
        }
        return out
    }

    /// Coordinates of a Point, LineString or LinearRing.
    public var coords: [XY] {
        switch kind {
        case .point, .lineString, .linearRing:
            if isEmpty { return [] }
            return Geometry.coords(ofSeq: GEOSGeom_getCoordSeq_r(Geometry.ctx, g))
        default:
            return []
        }
    }

    /// Exterior ring and holes of a Polygon.
    public var rings: (exterior: [XY], interiors: [[XY]]) {
        guard kind == .polygon, !isEmpty else { return ([], []) }
        let ext = GEOSGetExteriorRing_r(Geometry.ctx, g)
        let shell = Geometry.coords(ofSeq: GEOSGeom_getCoordSeq_r(Geometry.ctx, ext))
        let n = GEOSGetNumInteriorRings_r(Geometry.ctx, g)
        var holes: [[XY]] = []
        if n > 0 {
            for i in 0..<n {
                let r = GEOSGetInteriorRingN_r(Geometry.ctx, g, i)
                holes.append(Geometry.coords(ofSeq: GEOSGeom_getCoordSeq_r(Geometry.ctx, r)))
            }
        }
        return (shell, holes)
    }

    public var centroid: XY? {
        guard let c = GEOSGetCentroid_r(Geometry.ctx, g) else { return nil }
        let p = Geometry(owning: c)
        return p.coords.first
    }

    // MARK: - Predicates and measures

    public func intersects(_ o: Geometry) -> Bool { GEOSIntersects_r(Geometry.ctx, g, o.g) == 1 }
    public func contains(_ o: Geometry) -> Bool { GEOSContains_r(Geometry.ctx, g, o.g) == 1 }
    public func within(_ o: Geometry) -> Bool { GEOSWithin_r(Geometry.ctx, g, o.g) == 1 }
    public func contains(_ p: XY) -> Bool { contains(.point(p)) }

    public func distance(_ o: Geometry) -> Double {
        var d = 0.0
        return GEOSDistance_r(Geometry.ctx, g, o.g, &d) == 1 ? d : .infinity
    }

    /// The point on self nearest to `o` (shapely.ops.nearest_points(self, o)[0]).
    public func nearestPoint(to o: Geometry) -> XY? {
        guard let seq = GEOSNearestPoints_r(Geometry.ctx, g, o.g) else { return nil }
        defer { GEOSCoordSeq_destroy_r(Geometry.ctx, seq) }
        return Geometry.coords(ofSeq: seq).first
    }

    // MARK: - Operations

    public enum Cap: Int32 { case round = 1, flat = 2, square = 3 }
    public enum Join: Int32 { case round = 1, mitre = 2, bevel = 3 }

    /// Shapely's buffer(); defaults match Shapely 2 (16 segments per quarter circle,
    /// round caps and joins, mitre limit 5).
    public func buffer(_ distance: Double, quadSegs: Int = 16, cap: Cap = .round, join: Join = .round,
                       mitreLimit: Double = 5.0) throws -> Geometry {
        try Geometry.wrap(GEOSBufferWithStyle_r(Geometry.ctx, g, distance, Int32(quadSegs), cap.rawValue,
                                                join.rawValue, mitreLimit), "buffer")
    }

    /// buffer(distance, single_sided=True, join_style=mitre): positive = left of the line.
    public func singleSidedBuffer(_ distance: Double, quadSegs: Int = 16, join: Join = .mitre,
                                  mitreLimit: Double = 5.0) throws -> Geometry {
        let ctx = Geometry.ctx
        guard let params = GEOSBufferParams_create_r(ctx) else { throw GEOSRuntime.fail("buffer parameters") }
        defer { GEOSBufferParams_destroy_r(ctx, params) }
        GEOSBufferParams_setEndCapStyle_r(ctx, params, Int32(Cap.round.rawValue))
        GEOSBufferParams_setJoinStyle_r(ctx, params, Int32(join.rawValue))
        GEOSBufferParams_setMitreLimit_r(ctx, params, mitreLimit)
        GEOSBufferParams_setQuadrantSegments_r(ctx, params, Int32(quadSegs))
        GEOSBufferParams_setSingleSided_r(ctx, params, 1)
        return try Geometry.wrap(GEOSBufferWithParams_r(ctx, g, params, distance), "single-sided buffer")
    }

    public func union(_ o: Geometry) throws -> Geometry {
        try Geometry.wrap(GEOSUnion_r(Geometry.ctx, g, o.g), "union")
    }

    public func difference(_ o: Geometry) throws -> Geometry {
        try Geometry.wrap(GEOSDifference_r(Geometry.ctx, g, o.g), "difference")
    }

    public func intersection(_ o: Geometry) throws -> Geometry {
        try Geometry.wrap(GEOSIntersection_r(Geometry.ctx, g, o.g), "intersection")
    }

    public func convexHull() throws -> Geometry {
        try Geometry.wrap(GEOSConvexHull_r(Geometry.ctx, g), "convex hull")
    }

    /// simplify(tolerance, preserve_topology=True)
    public func simplify(_ tolerance: Double) throws -> Geometry {
        try Geometry.wrap(GEOSTopologyPreserveSimplify_r(Geometry.ctx, g, tolerance), "simplify")
    }

    public func unaryUnion() throws -> Geometry {
        try Geometry.wrap(GEOSUnaryUnion_r(Geometry.ctx, g), "union")
    }

    /// shapely.ops.unary_union(list)
    public static func unaryUnion(_ geoms: [Geometry]) throws -> Geometry {
        if geoms.isEmpty { return empty }
        return try collection(geoms).unaryUnion()
    }

    /// shapely.ops.linemerge
    public func lineMerge() throws -> Geometry {
        try Geometry.wrap(GEOSLineMerge_r(Geometry.ctx, g), "linemerge")
    }

    /// shapely.ops.polygonize: the polygons formed by a set of lines.
    public static func polygonize(_ lines: [Geometry]) throws -> [Geometry] {
        if lines.isEmpty { return [] }
        let ptrs: [OpaquePointer?] = lines.map { $0.g }
        let result: OpaquePointer? = ptrs.withUnsafeBufferPointer {
            GEOSPolygonize_r(ctx, $0.baseAddress, UInt32(lines.count))
        }
        return try wrap(result, "polygonize").parts.filter { !$0.isEmpty }
    }

    /// A copy with every coordinate passed through `f` (shapely.transform).
    public func mapCoords(_ f: (XY) -> XY) throws -> Geometry {
        switch kind {
        case .point:
            guard let c = coords.first else { return clone() }
            return .point(f(c))
        case .lineString:
            return try .lineString(coords.map(f))
        case .linearRing:
            return try Geometry.wrap(GEOSGeom_createLinearRing_r(Geometry.ctx, Geometry.coordSeq(coords.map(f))),
                                     "LinearRing")
        case .polygon:
            if isEmpty { return clone() }
            let r = rings
            return try .polygon(r.exterior.map(f), holes: r.interiors.map { $0.map(f) })
        case .multiPoint, .multiLineString, .multiPolygon, .collection:
            return Geometry.collection(try parts.map { try $0.mapCoords(f) }, kind: kind)
        }
    }
}

// MARK: - Parts helpers (road_to_kml._geom_parts / _polygon_parts)

public extension Geometry {
    /// Every LineString inside (road_to_kml._geom_parts).
    var lineParts: [Geometry] {
        if isEmpty { return [] }
        switch kind {
        case .lineString: return [self]
        case .multiLineString, .collection, .multiPolygon, .multiPoint: return parts.flatMap { $0.lineParts }
        default: return []
        }
    }

    /// Every Polygon inside (road_to_kml._polygon_parts).
    var polygonParts: [Geometry] {
        if isEmpty { return [] }
        switch kind {
        case .polygon: return [self]
        case .multiPolygon, .collection, .multiLineString, .multiPoint: return parts.flatMap { $0.polygonParts }
        default: return []
        }
    }
}

// MARK: - Line helpers done in Swift (exactly Shapely's LineString.project / interpolate / substring)

public enum LineMath {
    /// Distance along `line` to the point on it nearest `p` (LineString.project).
    public static func project(_ line: [XY], _ p: XY) -> Double {
        var best = Double.infinity, bestAlong = 0.0, along = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = 0.0
            if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) }
            let q = XY(a.x + t * dx, a.y + t * dy)
            let d = q.distance(to: p)
            if d < best {
                best = d
                bestAlong = along + t * sqrt(len2)
            }
            along += sqrt(len2)
        }
        return bestAlong
    }

    /// The point `s` metres along `line` (LineString.interpolate), clamped to its ends.
    public static func interpolate(_ line: [XY], _ s: Double) -> XY {
        guard let first = line.first else { return XY(0, 0) }
        if s <= 0 { return first }
        var along = 0.0
        for (a, b) in zip(line, line.dropFirst()) {
            let len = a.distance(to: b)
            if along + len >= s, len > 0 {
                let t = (s - along) / len
                return XY(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y))
            }
            along += len
        }
        return line[line.count - 1]
    }

    public static func length(_ line: [XY]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// shapely.ops.substring(line, start, end) for 0 <= start <= end. Returns nil when the
    /// result would be a single point (start == end), which callers drop as zero length.
    public static func substring(_ line: [XY], _ start: Double, _ end: Double) -> [XY]? {
        let total = length(line)
        let s = max(0, min(total, start)), e = max(0, min(total, end))
        if e <= s { return nil }
        var out = [interpolate(line, s)]
        var along = 0.0
        for (i, p) in line.enumerated() {
            if i > 0 { along += line[i - 1].distance(to: p) }
            if along > s && along < e { out.append(p) }
        }
        out.append(interpolate(line, e))
        return out
    }

    /// Distance from `p` to segment a-b, the nearest point and its fraction along the segment.
    public static func pointSegment(_ p: XY, _ a: XY, _ b: XY) -> (distance: Double, point: XY, t: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t = 0.0
        if len2 > 0 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) }
        let q = XY(a.x + t * dx, a.y + t * dy)
        return (q.distance(to: p), q, t)
    }
}
