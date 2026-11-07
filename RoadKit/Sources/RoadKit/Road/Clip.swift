import Foundation

public struct ClipError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// One end of a --from/--to stretch: a point, or a cross street's WGS84 lines.
public enum ClipSpec {
    case point(lat: Double, lon: Double, label: String)
    case street(lines: [Geometry], label: String)

    var label: String {
        switch self {
        case .point(_, _, let l), .street(_, let l): return l
        }
    }
}

extension RoadToKML {
    static func pointParts(_ g: Geometry) -> [XY] {
        if g.isEmpty { return [] }
        if g.kind == .point { return g.coords.prefix(1).map { $0 } }
        return g.parts.filter { $0.kind == .point && !$0.isEmpty }.compactMap { $0.coords.first }
    }

    /// clip_layers: keep only the stretch of road between two places. The route between them
    /// is found along the road itself; every road line within halfWidth m of it is kept (so
    /// both sides of a divided highway survive), plus pad m past each end.
    func clipLayers(_ layers: [Layer], _ from: ClipSpec, _ to: ClipSpec, pad: Double = 15.0,
                    halfWidth: Double = 75.0) throws -> Layer {
        var lons: [Double] = []
        for layer in layers {
            for (line, _) in layer.lines {
                let c = line.coords
                guard let a = c.first, let b = c.last else { continue }
                lons.append(layer.crs.toWGS84(a).x)
                lons.append(layer.crs.toWGS84(b).x)
            }
        }
        if lons.isEmpty { throw ClipError("No road geometry to clip.") }
        let utm = UTM(longitudes: lons)
        let crs = CRS.utm(utm)

        var lines: [TaggedLine] = [], polys: [Geometry] = [], discs: [Geometry] = []
        for layer in layers {
            for (l, t) in layer.lines { lines.append((try reproject(l, from: layer.crs, to: crs), t)) }
            for p in layer.polys { polys.append(try reproject(p, from: layer.crs, to: crs)) }
            for p in layer.junctions { discs.append(try reproject(p, from: layer.crs, to: crs)) }
        }
        let main = lines.filter { ($0.tags["_ramp"] ?? "").isEmpty }.map(\.line)
        if main.isEmpty { throw ClipError("No road geometry to clip.") }

        // Road network: pieces split at every crossing, nodes at piece ends.
        let pieces = RoadGeom.lineParts(try Geometry.unaryUnion(main))
        let pieceCoords = pieces.map(\.coords)
        let pieceLen = pieceCoords.map { LineMath.length($0) }
        var adj: [NodeKey: [(NodeKey, Double, Int?)]] = [:], nodeOrder: [NodeKey] = []
        var ends: [(NodeKey, NodeKey)] = []
        func addEdge(_ a: NodeKey, _ b: NodeKey, _ w: Double, _ k: Int?) {
            if adj[a] == nil { nodeOrder.append(a); adj[a] = [] }
            adj[a]!.append((b, w, k))
        }
        for (k, c) in pieceCoords.enumerated() {
            let a = NodeKey(c.first!), b = NodeKey(c.last!)
            ends.append((a, b))
            addEdge(a, b, pieceLen[k], k)
            addEdge(b, a, pieceLen[k], k)
        }
        // bridge small gaps between dangling ends (e.g. OSM vs TIGER offsets)
        let dangling = nodeOrder.filter { adj[$0]!.count == 1 }
        for (i, n) in dangling.enumerated() {
            for m in dangling[(i + 1)...] {
                let d = hypot(n.x - m.x, n.y - m.y)
                if d > 0 && d <= 25 {
                    addEdge(n, m, d, nil)
                    addEdge(m, n, d, nil)
                }
            }
        }

        func locate(_ spec: ClipSpec) throws -> [(Int, Double)] {
            switch spec {
            case .point(let lat, let lon, let label):
                let p = Geometry.point(utm.forward(lon: lon, lat: lat))
                var k = 0, best = Double.infinity
                for (i, piece) in pieces.enumerated() {
                    let d = piece.distance(p)
                    if d < best { best = d; k = i }
                }
                if best > 400 { throw ClipError("\(label) is more than 400 m from the road.") }
                return [(k, LineMath.project(pieceCoords[k], p.coords[0]))]
            case .street(let value, let label):
                let cross = try value.map { try reproject($0, from: .wgs84, to: crs) }
                if cross.isEmpty { throw ClipError("Couldn't find \(label) near the road.") }
                var hits: [(Int, Double, XY)] = []
                for (k, piece) in pieces.enumerated() {
                    for c in cross {
                        if piece.intersects(c) {
                            for pt in RoadToKML.pointParts(try piece.intersection(c)) {
                                hits.append((k, LineMath.project(pieceCoords[k], pt), pt))
                            }
                        } else if piece.distance(c) <= 25, let pt = piece.nearestPoint(to: c) {
                            hits.append((k, LineMath.project(pieceCoords[k], pt), pt))
                        }
                    }
                }
                if hits.isEmpty { throw ClipError("\(label) doesn't meet the road.") }
                var clusters: [(Int, Double, XY)] = []
                for h in hits where clusters.allSatisfy({ h.2.distance(to: $0.2) > 80 }) { clusters.append(h) }
                return clusters.map { ($0.0, $0.1) }
            }
        }

        enum Pred { case start; case via(NodeKey, Int?) }
        func dijkstra(_ k: Int, _ s: Double) -> ([NodeKey: Double], [NodeKey: Pred]) {
            let (a, b) = ends[k]
            var dist: [NodeKey: Double] = [a: s]
            dist[b] = pieceLen[k] - s
            var pred: [NodeKey: Pred] = [a: .start, b: .start]
            var heap = MinHeap<NodeKey>(tieBreak: <)
            for (n, d) in dist { heap.push(d, n) }
            var done = Set<NodeKey>()
            while let (d, n) = heap.pop() {
                if done.contains(n) { continue }
                done.insert(n)
                for (m, w, kk) in adj[n] ?? [] where d + w < (dist[m] ?? .infinity) {
                    dist[m] = d + w
                    pred[m] = .via(n, kk)
                    heap.push(d + w, m)
                }
            }
            return (dist, pred)
        }

        enum Entry: Equatable { case direct; case node(NodeKey) }
        typealias Info = (ka: Int, sa: Double, kb: Int, sb: Double, pred: [NodeKey: Pred])
        let A = try locate(from), B = try locate(to)
        var best: (cost: Double, entry: Entry, info: Info)?
        for (ka, sa) in A {
            let (dist, pred) = dijkstra(ka, sa)
            for (kb, sb) in B {
                var opts: [(Double, Entry)] = []
                if ka == kb { opts.append((abs(sb - sa), .direct)) }
                let (a2, b2) = ends[kb]
                if let d = dist[a2] { opts.append((d + sb, .node(a2))) }
                if let d = dist[b2] { opts.append((d + pieceLen[kb] - sb, .node(b2))) }
                for (cost, entry) in opts where best == nil || cost < best!.cost {
                    best = (cost, entry, (ka, sa, kb, sb, pred))
                }
            }
        }
        guard let best else { throw ClipError("No connected stretch of road between \(from.label) and \(to.label).") }
        if A.count > 1 || B.count > 1 {
            log("  Note: a cross street meets the road in more than one place; using the pair closest together (\(PyFmt.f(best.cost, 0)) m apart).")
        }

        let (ka, sa, kb, sb, pred) = best.info
        var pathParts: [Geometry] = []
        func sub(_ k: Int, _ s: Double, _ e: Double) throws -> Geometry? {
            guard let c = LineMath.substring(pieceCoords[k], s, e), c.count >= 2 else { return nil }
            return try Geometry.lineString(c)
        }
        switch best.entry {
        case .direct:
            if let g = try sub(ka, min(sa, sb), max(sa, sb)) { pathParts.append(g) }
        case .node(let entry):
            var bridges: [Geometry] = [], usedPieces: [Int] = []
            var n = entry
            while case .via(let prev, let kk)? = pred[n] {
                if let kk { usedPieces.append(kk) } else { bridges.append(try Geometry.lineString([prev.xy, n.xy])) }
                n = prev
            }
            let (a, _) = ends[ka]
            let first = n == a ? try sub(ka, 0, sa) : try sub(ka, sa, pieceLen[ka])
            let (a2, _) = ends[kb]
            let last = entry == a2 ? try sub(kb, 0, sb) : try sub(kb, sb, pieceLen[kb])
            pathParts = [first, last].compactMap { $0 } + usedPieces.map { pieces[$0] } + bridges
        }
        pathParts = pathParts.filter { !$0.isEmpty && $0.length > 0 }
        var path: Geometry? = pathParts.isEmpty ? nil : try Geometry.unaryUnion(pathParts)
        if let p = path, p.kind == .multiLineString { path = try p.lineMerge() }
        let pa = Geometry.point(LineMath.interpolate(pieceCoords[ka], sa))
        let pb = Geometry.point(LineMath.interpolate(pieceCoords[kb], sb))
        var zone = [try pa.buffer(pad), try pb.buffer(pad)]
        if let path { zone.append(try path.buffer(halfWidth, cap: .flat)) }
        let corridor = try Geometry.unaryUnion(zone)

        var kept: [TaggedLine] = []
        for (line, tags) in lines where (tags["_ramp"] ?? "").isEmpty {
            for part in RoadGeom.lineParts(try line.intersection(corridor)) where part.length >= 1.0 {
                kept.append((part, tags))
            }
        }
        if kept.isEmpty { throw ClipError("Nothing left after clipping.") }
        kept += try RoadGeom.connectedRamps(kept.map(\.line), lines.filter { !($0.tags["_ramp"] ?? "").isEmpty })

        let keepZone = try Geometry.unaryUnion(kept.map(\.line)).buffer(1.0)
        let out = Layer(kept, crs, "clip", polys: polys.filter { $0.intersects(keepZone) },
                        wayIDs: layers.reduce(into: Set<Int64>()) { $0.formUnion($1.wayIDs) },
                        junctions: discs.filter { $0.intersects(keepZone) })
        log("  Clipped to \(PyFmt.f(path?.length ?? 0, 0)) m of road between \(from.label) and \(to.label).")
        return out
    }
}
