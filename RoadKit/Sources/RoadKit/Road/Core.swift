import Foundation

public typealias Tags = [String: String]
public typealias TaggedLine = (line: Geometry, tags: Tags)

/// Default road widths (meters, edge-to-edge) keyed on the OSM highway= tag, and the
/// TIGER/Line MTFCC classes. Same values as road_to_kml.py.
public enum RoadWidths {
    public static let defaults: [String: Double] = [
        "motorway": 24.0, "motorway_link": 10.0, "trunk": 18.0, "trunk_link": 9.0,
        "primary": 14.0, "primary_link": 7.0, "secondary": 11.0, "secondary_link": 6.0,
        "tertiary": 9.0, "tertiary_link": 5.5, "unclassified": 7.0, "residential": 7.5,
        "living_street": 5.0, "service": 4.5, "pedestrian": 4.0, "footway": 2.0, "path": 2.0,
        "cycleway": 2.5, "steps": 2.0, "bridleway": 2.5, "corridor": 2.0, "track": 4.0,
        "busway": 7.0, "road": 7.0,
    ]
    public static let laneWidth = 3.7
    public static let fallback = 7.0

    /// TIGER/Line MTFCC road classes -> approximate widths.
    public static let tiger: [String: Double] = [
        "S1100": 24.0, "S1200": 14.0, "S1400": 7.5, "S1500": 4.5, "S1630": 9.0, "S1640": 14.0,
        "S1710": 4.0, "S1720": 5.0, "S1730": 5.0, "S1740": 4.5, "S1750": 7.0, "S1780": 4.5,
        "S1820": 4.0, "S1830": 4.0,
    ]
    static let tigerMinor: Set<String> = ["S1500", "S1710", "S1720", "S1730", "S1740", "S1780", "S1820", "S1830"]
    /// How TIGER/Line road classes behave for map matching (OSM highway types).
    static let tigerHighway: [String: String] = [
        "S1100": "motorway", "S1200": "primary", "S1400": "residential", "S1500": "track",
        "S1630": "motorway_link", "S1640": "tertiary", "S1710": "footway", "S1720": "steps",
        "S1730": "service", "S1740": "service", "S1750": "road", "S1780": "service",
        "S1820": "cycleway", "S1830": "bridleway",
    ]

    static func pyFloat(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "")
        if t.lowercased().hasPrefix("0x") || t.lowercased().hasPrefix("-0x") { return nil }
        return Double(t)
    }

    static func pyInt(_ s: String) -> Int? {
        Int(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: ""))
    }
}

/// get_road_width: explicit width= > tiger_width= > lanes= > highway= default table.
public func roadWidth(_ tags: Tags) -> Double {
    if let w = tags["width"], let v = RoadWidths.pyFloat(w.replacingOccurrences(of: "m", with: "")) { return v }
    if let w = tags["tiger_width"], let v = RoadWidths.pyFloat(w) { return v }
    if let l = tags["lanes"], let n = RoadWidths.pyInt(l) { return Double(n) * RoadWidths.laneWidth }
    let hw = tags["highway"] ?? "road"
    return RoadWidths.defaults[hw] ?? RoadWidths.fallback
}

/// Projected road centerlines with their tags, plus extra polygons in the same CRS
/// (pavement outlines), intersection-fill circles, the OSM way IDs involved, and (for
/// --from/--to) cross streets in WGS84.
public final class Layer {
    public var lines: [TaggedLine]
    public var crs: CRS
    public var source: String
    public var polys: [Geometry]
    public var junctions: [Geometry]
    public var wayIDs: Set<Int64>
    public var cross: [String: [Geometry]] = [:]

    public init(_ lines: [TaggedLine], _ crs: CRS, _ source: String, polys: [Geometry] = [],
                wayIDs: Set<Int64> = [], junctions: [Geometry] = []) {
        self.lines = lines
        self.crs = crs
        self.source = source
        self.polys = polys
        self.junctions = junctions
        self.wayIDs = wayIDs
    }
}

/// A rounded coordinate used as a graph node key (round(x, 1), round(y, 1)).
struct NodeKey: Hashable, Comparable {
    let x: Double, y: Double
    init(_ p: XY, digits: Double = 10) {
        x = (p.x * digits).rounded(.toNearestOrEven) / digits
        y = (p.y * digits).rounded(.toNearestOrEven) / digits
    }
    var xy: XY { XY(x, y) }
    static func < (a: NodeKey, b: NodeKey) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
}

/// A binary min-heap (heapq).
struct MinHeap<T> {
    private var items: [(Double, T)] = []
    private let less: (T, T) -> Bool

    init(tieBreak: @escaping (T, T) -> Bool) { less = tieBreak }

    var isEmpty: Bool { items.isEmpty }

    private func lower(_ a: (Double, T), _ b: (Double, T)) -> Bool {
        a.0 != b.0 ? a.0 < b.0 : less(a.1, b.1)
    }

    mutating func push(_ d: Double, _ v: T) {
        items.append((d, v))
        var k = items.count - 1
        while k > 0 {
            let p = (k - 1) / 2
            if lower(items[k], items[p]) { items.swapAt(k, p); k = p } else { break }
        }
    }

    mutating func pop() -> (Double, T)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let top = items.removeLast()
        var k = 0
        while true {
            let l = 2 * k + 1, r = l + 1
            var m = k
            if l < items.count && lower(items[l], items[m]) { m = l }
            if r < items.count && lower(items[r], items[m]) { m = r }
            if m == k { break }
            items.swapAt(k, m)
            k = m
        }
        return top
    }
}

public enum RoadGeom {
    /// _junction_disc: a circle covering the box where roads of these widths cross; its
    /// radius is the distance from the center to the box's corner.
    public static func junctionDisc(_ xy: XY, _ widths: [Double]) throws -> Geometry? {
        let halves = widths.filter { $0 != 0 }.map { $0 / 2 }.sorted(by: >)
        if halves.count < 2 { return nil }
        return try Geometry.point(xy).buffer(hypot(halves[0], halves[1]), quadSegs: 8)
    }

    public struct LeftRound { public let x: Double, y: Double, reason: String }

    /// trim_junction_fill: cut the round bulge off each intersection-fill circle. Inside the
    /// circle, keep only the convex hull of the road surfaces there. A circle that can't be
    /// trimmed is kept as it was and listed in `left` with its center and the reason.
    /// `fault` makes every trim fail with that message (the tests' patched _query_tree).
    public static func trimJunctionFill(_ discs: [Geometry], _ surfaces: [Geometry], fault: String? = nil)
        -> (fills: [Geometry], trimmed: Int, kept: Int, left: [LeftRound]) {
        if discs.isEmpty { return ([], 0, 0, []) }
        let surf = surfaces.filter { !$0.isEmpty }
        let tree = surf.isEmpty ? nil : STRTree(surf.map { $0.bounds ?? BBox(0, 0, 0, 0) })
        var out: [Geometry] = [], left: [LeftRound] = []
        var trimmed = 0, kept = 0
        func keep(_ disc: Geometry, _ reason: String) {
            out.append(disc)
            if let c = disc.centroid { left.append(LeftRound(x: c.x, y: c.y, reason: reason)) }
        }
        for disc in discs {
            do {
                if let fault { throw GeometryError(message: fault) }
                let near = tree?.query(disc) ?? []
                let inside = try near.map { try surf[$0].intersection(disc) }.filter { !$0.isEmpty && $0.area > 0 }
                if inside.isEmpty {
                    keep(disc, "No drawn road inside the circle to trim it to.")
                    kept += 1
                    continue
                }
                let hull = try Geometry.unaryUnion(inside).convexHull()
                if hull.kind != .polygon || hull.isEmpty || !hull.isValid || hull.area < 1.0 || hull.area > disc.area * 1.001 {
                    throw GeometryError(message: "the trimmed shape was unusable")
                }
                out.append(hull)
                trimmed += 1
            } catch {
                keep(disc, Py.strip("Trimming failed: \(error)"))
                kept += 1
            }
        }
        return (out, trimmed, kept, left)
    }

    /// _junction_discs_by_geometry: discs where cross-street lines touch road vertices (TIGER).
    static func junctionDiscsByGeometry(_ road: [TaggedLine], _ cross: [TaggedLine], tol: Double = 0.5) throws -> [Geometry] {
        if road.isEmpty || cross.isEmpty { return [] }
        let crossGeoms = cross.map(\.line)
        let tree = STRTree(crossGeoms.map { $0.bounds ?? BBox(0, 0, 0, 0) })
        var order: [NodeKey] = []
        var roadW: [NodeKey: Double] = [:]
        for (line, tags) in road {
            let w = roadWidth(tags)
            for c in line.coords {
                let k = NodeKey(c)
                if roadW[k] == nil { order.append(k); roadW[k] = 0 }
                roadW[k] = max(roadW[k]!, w)
            }
        }
        var discs: [Geometry] = []
        for k in order {
            let p = Geometry.point(k.xy)
            let hits = tree.query(BBox(k.x - tol, k.y - tol, k.x + tol, k.y + tol))
            let widths = hits.filter { crossGeoms[$0].distance(p) <= tol }.map { roadWidth(cross[$0].tags) }
            if !widths.isEmpty, let disc = try junctionDisc(k.xy, [roadW[k]!] + widths) {
                discs.append(disc)
            }
        }
        return discs
    }

    /// _connected_ramps: ramp lines touching the road, then ramps touching those (a few levels).
    static func connectedRamps(_ roadLines: [Geometry], _ candidates: [TaggedLine], levels: Int = 4,
                               tol: Double = 1.0) throws -> [TaggedLine] {
        if roadLines.isEmpty || candidates.isEmpty { return [] }
        var frontier = try Geometry.unaryUnion(roadLines)
        var remaining = Array(candidates.indices)
        var added: [TaggedLine] = []
        for _ in 0..<levels {
            let new = remaining.filter { candidates[$0].line.distance(frontier) <= tol }
            if new.isEmpty { break }
            added += new.map { candidates[$0] }
            let set = Set(new)
            remaining = remaining.filter { !set.contains($0) }
            frontier = try Geometry.unaryUnion(new.map { candidates[$0].line })
        }
        return added
    }

    /// _offset_buffer: the band from right_dist m on the right of the centerline to
    /// left_dist m on its left. Negative values cross to the other side.
    public static func offsetBuffer(_ line: Geometry, _ leftDist: Double, _ rightDist: Double) throws -> Geometry {
        var hi = leftDist, lo = -rightDist
        if hi < lo { swap(&hi, &lo) }
        if hi == lo { return Geometry.empty }
        func side(_ d: Double) throws -> Geometry {
            d == 0 ? Geometry.empty : try line.singleSidedBuffer(d, join: .mitre, mitreLimit: 5.0)
        }
        var band: Geometry
        if lo >= 0 {
            band = try side(hi).difference(side(lo))
        } else if hi <= 0 {
            band = try side(lo).difference(side(hi))
        } else {
            band = try side(hi).union(side(lo))
        }
        if !band.isValid { band = try band.buffer(0) }
        return band
    }

    /// _buffer_lines: each segment buffered by its own road width.
    static func bufferLines(_ lines: [TaggedLine], extraLanes: Int = 0, leftWidth: Double? = nil,
                            rightWidth: Double? = nil) throws -> [Geometry] {
        try lines.map { line, tags in
            var base = roadWidth(tags)
            if extraLanes != 0 { base += Double(extraLanes) * RoadWidths.laneWidth }
            let half = base / 2
            let l = leftWidth ?? half, r = rightWidth ?? half
            if l == r && l > 0 {
                return try line.buffer(l, quadSegs: 8, cap: .flat, join: .mitre)
            }
            return try offsetBuffer(line, l, r)
        }
    }

    /// Every LineString inside (_geom_parts).
    static func lineParts(_ g: Geometry?) -> [Geometry] {
        guard let g, !g.isEmpty else { return [] }
        return g.lineParts
    }

    /// Every Polygon inside (_polygon_parts).
    static func polygonParts(_ g: Geometry?) -> [Geometry] {
        guard let g, !g.isEmpty else { return [] }
        return g.polygonParts
    }
}
