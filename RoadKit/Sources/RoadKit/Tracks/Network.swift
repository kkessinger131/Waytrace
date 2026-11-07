import Foundation

/// A place on a road edge a GPS point might really have been.
struct Candidate {
    let eid: Int
    let s: Double
    let d: Double
    let x: Double, y: Double
}

/// road_tracks.MatchResult
public struct MatchResult {
    public var lines: [TaggedLine]
    public var nodes: [Int64]
    public var wayIDs: Set<Int64>
    public var used: Int
    public var breaks: Int
    public var skipped: Int
}

/// road_tracks.RoadNetwork: a directed road graph for one kind of trip, in UTM meters.
public final class RoadNetwork {
    struct Edge { let u: Int64, v: Int64, way: Int64, length: Double, fwd: Double, bwd: Double }
    struct Nbr: Hashable { let node: Int64, way: Int64 }

    public let category: String
    public let utm: UTM
    var xy: [Int64: XY] = [:]
    var edges: [Edge] = []
    var adj: [Int64: [(Int64, Double, Int)]] = [:]
    var nbrs: [Int64: Set<Nbr>] = [:]
    public internal(set) var wayTags: [Int64: Tags] = [:]
    var segments: [(XY, XY)] = []
    var tree: STRTree?

    public init(_ ways: [NetWay], _ nodes: [Int64: LatLon], category: String, utm: UTM) {
        self.category = category
        self.utm = utm
        let allowed = Set(TrackRules.networkTypes[category] ?? TrackRules.networkTypes["other"]!)
        for w in ways {
            let hw = w.tags["highway"] ?? ""
            guard allowed.contains(hw) else { continue }
            let ns = w.nodes.filter { nodes[$0] != nil }
            if ns.count < 2 { continue }
            wayTags[w.id] = w.tags
            let (ffac, bfac) = costFactors(w.tags, hw)
            for (a, b) in zip(ns, ns.dropFirst()) where a != b {
                for n in [a, b] where xy[n] == nil {
                    let ll = nodes[n]!
                    xy[n] = utm.forward(lon: ll.lon, lat: ll.lat)
                }
                let p = xy[a]!, q = xy[b]!
                let length = hypot(q.x - p.x, q.y - p.y)
                if length == 0 { continue }
                let eid = edges.count
                edges.append(Edge(u: a, v: b, way: w.id, length: length, fwd: ffac, bwd: bfac))
                adj[a, default: []].append((b, length * ffac, eid))
                adj[b, default: []].append((a, length * bfac, eid))
                nbrs[a, default: []].insert(Nbr(node: b, way: w.id))
                nbrs[b, default: []].insert(Nbr(node: a, way: w.id))
            }
        }
        segments = edges.map { (xy[$0.u]!, xy[$0.v]!) }
        if !segments.isEmpty {
            tree = STRTree(segments.map { BBox(min($0.0.x, $0.1.x), min($0.0.y, $0.1.y), max($0.0.x, $0.1.x), max($0.0.y, $0.1.y)) })
        }
    }

    /// _cost_factors: (forward, backward) multipliers. Against a one-way is allowed but
    /// expensive, so a bad tag or a mislabelled trip can't derail the match.
    func costFactors(_ tags: Tags, _ hw: String) -> (Double, Double) {
        var base = category == "other" && TrackRules.pedTypes.contains(hw) ? 1.5 : 1.0
        if category == "drive" || category == "other" { base *= TrackRules.roadClassCost[hw] ?? 1.0 }
        if category == "walk" { return (base, base) }
        if category == "bike" && (tags["oneway:bicycle"] ?? "").lowercased() == "no" { return (base, base) }
        let ow = (tags["oneway"] ?? "").lowercased()
        var fwd = true, bwd = true
        if ["yes", "true", "1"].contains(ow) { fwd = true; bwd = false }
        else if ["-1", "reverse"].contains(ow) { fwd = false; bwd = true }
        else if ow == "no" { fwd = true; bwd = true }
        else if ["roundabout", "circular"].contains(tags["junction"] ?? "") || hw == "motorway" { fwd = true; bwd = false }
        let wrong = category == "other" ? 3.0 : 5.0
        return (base * (fwd ? 1 : wrong), base * (bwd ? 1 : wrong))
    }

    func candidates(_ x: Double, _ y: Double, _ radius: Double, k: Int = 5) -> [Candidate] {
        guard let tree else { return [] }
        let p = XY(x, y)
        var best: [Int64: (Double, Int)] = [:]
        for i in tree.query(BBox(x - radius, y - radius, x + radius, y + radius)) {
            let d = LineMath.pointSegment(p, segments[i].0, segments[i].1).distance
            if d > radius { continue }
            let wid = edges[i].way
            if best[wid] == nil || d < best[wid]!.0 { best[wid] = (d, i) }
        }
        return best.values.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(k).map { d, i in
            let r = LineMath.pointSegment(p, segments[i].0, segments[i].1)
            return Candidate(eid: i, s: r.t * edges[i].length, d: d, x: r.point.x, y: r.point.y)
        }
    }

    func sources(_ c: Candidate) -> [Int64: Double] {
        let e = edges[c.eid]
        var src: [Int64: Double] = [e.v: (e.length - c.s) * e.fwd]
        src[e.u] = min(src[e.u] ?? .infinity, c.s * e.bwd)
        return src
    }

    func dijkstra(_ sources: [Int64: Double], _ cutoff: Double, _ targets: Set<Int64>?) -> ([Int64: Double], [Int64: (Int64, Int)?]) {
        var dist = sources
        var pred: [Int64: (Int64, Int)?] = [:]
        for n in sources.keys { pred[n] = .some(nil) }
        var heap = MinHeap<Int64>(tieBreak: <)
        for (n, d) in sources { heap.push(d, n) }
        var remaining = (targets?.isEmpty ?? true) ? nil : targets
        var done = Set<Int64>()
        while let (d, n) = heap.pop() {
            if done.contains(n) || d > (dist[n] ?? .infinity) { continue }
            done.insert(n)
            if remaining != nil {
                remaining!.remove(n)
                if remaining!.isEmpty { break }
            }
            if d > cutoff { break }
            for (m, cost, eid) in adj[n] ?? [] {
                let nd = d + cost
                if nd <= cutoff && nd < (dist[m] ?? .infinity) {
                    dist[m] = nd
                    pred[m] = .some((n, eid))
                    heap.push(nd, m)
                }
            }
        }
        return (dist, pred)
    }

    enum Entry: Equatable { case none, direct, node(Int64) }

    /// _arrivals: the cheapest way to reach candidate c.
    func arrivals(_ a: Candidate, _ c: Candidate, _ dist: [Int64: Double]) -> (Double, Entry) {
        var best: (Double, Entry) = (.infinity, .none)
        func consider(_ x: (Double, Entry)) { if x.0 < best.0 { best = x } }
        if c.eid == a.eid {
            let e = edges[a.eid]
            consider(c.s >= a.s ? ((c.s - a.s) * e.fwd, .direct) : ((a.s - c.s) * e.bwd, .direct))
        }
        let ce = edges[c.eid]
        if let d = dist[ce.u] { consider((d + c.s * ce.fwd, .node(ce.u))) }
        if let d = dist[ce.v] { consider((d + (ce.length - c.s) * ce.bwd, .node(ce.v))) }
        return best
    }

    func routeCosts(_ a: Candidate, _ cands: [Candidate], _ cutoff: Double) -> [Double] {
        var targets = Set<Int64>()
        for c in cands { targets.insert(edges[c.eid].u); targets.insert(edges[c.eid].v) }
        let (dist, _) = dijkstra(sources(a), cutoff, targets)
        return cands.map { arrivals(a, $0, dist).0 }
    }

    typealias Piece = (way: Int64, p: XY, q: XY)

    /// route_path: straight pieces from a to b, plus the graph nodes passed through.
    func routePath(_ a: Candidate, _ b: Candidate, _ cutoff: Double) -> ([Piece]?, [Int64]) {
        let (dist, pred) = dijkstra(sources(a), cutoff, [edges[b.eid].u, edges[b.eid].v])
        let (cost, entry) = arrivals(a, b, dist)
        if cost == .infinity { return (nil, []) }
        let wa = edges[a.eid].way, wb = edges[b.eid].way
        guard case .node(let entryNode) = entry else { return ([(wa, XY(a.x, a.y), XY(b.x, b.y))], []) }
        var chain: [(Int64, Int64, Int)] = []
        var n = entryNode
        while case .some(.some(let (prev, eid))) = pred[n] {
            chain.append((prev, n, eid))
            n = prev
        }
        chain.reverse()
        let start = n
        var pieces: [Piece] = [(wa, XY(a.x, a.y), xy[start]!)]
        for (p, q, eid) in chain { pieces.append((edges[eid].way, xy[p]!, xy[q]!)) }
        pieces.append((wb, xy[entryNode]!, XY(b.x, b.y)))
        return (pieces, [start] + chain.map(\.1))
    }

    /// junction_nodes: nodes along the path where 3+ road directions meet.
    func junctionNodes(_ nodes: [Int64], _ usedWays: Set<Int64>) -> [(Int64, [Int64])] {
        var out: [(Int64, [Int64])] = []
        for n in Set(nodes).sorted() {
            let ns = nbrs[n] ?? []
            let ways = Set(ns.map(\.way).filter { usedWays.contains($0) || !TrackRules.minorTypes.contains(wayTags[$0]?["highway"] ?? "") })
            if ways.count < 2 { continue }
            let dirs = Set(ns.filter { ways.contains($0.way) }.map(\.node))
            if dirs.count >= 3 { out.append((n, ways.sorted())) }
        }
        return out
    }
}

extension Tracks {
    /// _merge_pieces: consecutive straight pieces of the same way joined into lines.
    static func mergePieces(_ pieces: [RoadNetwork.Piece], _ wayTags: [Int64: Tags]) throws -> [(Geometry, Tags, Int64)] {
        var lines: [(Geometry, Tags, Int64)] = []
        var cur: [XY] = []
        var curWay: Int64 = 0
        func emit() throws {
            if cur.count >= 2 { lines.append((try Geometry.lineString(cur), wayTags[curWay] ?? [:], curWay)) }
        }
        for (wid, p, q) in pieces {
            if hypot(q.x - p.x, q.y - p.y) < 0.01 { continue }
            if !cur.isEmpty && wid == curWay && hypot(cur.last!.x - p.x, cur.last!.y - p.y) < 0.01 {
                cur.append(q)
                continue
            }
            try emit()
            cur = [p, q]
            curWay = wid
        }
        try emit()
        return lines
    }

    /// match_trip: map-match one trip with a hidden Markov model that routes along the
    /// network between consecutive points.
    public static func matchTrip(_ net: RoadNetwork, _ trip: Trip) throws -> MatchResult {
        var obs: [(x: Double, y: Double, t: Stamp?, sigma: Double)] = []
        for p in trip.points {
            let q = net.utm.forward(lon: p.lon, lat: p.lat)
            let acc = (p.acc ?? 0) != 0 ? p.acc! : TrackRules.noAccSigma
            obs.append((q.x, q.y, p.t, min(50, max(8, acc))))
        }
        let vmax = TrackRules.vmax[trip.category] ?? 60
        typealias LayerT = (cands: [Candidate], scores: [Double], back: [Int]?)
        var chains: [[Candidate]] = [], layers: [LayerT] = []
        var fails = 0, skipped = 0

        func finish() {
            guard let last = layers.last else { return }
            var j = 0
            for k in last.scores.indices where last.scores[k] > last.scores[j] { j = k }
            var seq: [Candidate] = []
            for li in stride(from: layers.count - 1, through: 0, by: -1) {
                seq.append(layers[li].cands[j])
                j = layers[li].back?[j] ?? 0
            }
            chains.append(seq.reversed())
        }

        var prevXY = XY(0, 0)
        var prevT: Stamp?
        for o in obs {
            let radius = min(200, max(40, 4 * o.sigma))
            var cands = net.candidates(o.x, o.y, radius)
            if cands.isEmpty { cands = net.candidates(o.x, o.y, radius * 2) }
            if cands.isEmpty { skipped += 1; continue }
            let emis = cands.map { -0.5 * pow($0.d / o.sigma, 2) }
            if layers.isEmpty {
                layers.append((cands, emis, nil))
                prevXY = XY(o.x, o.y)
                prevT = o.t
                continue
            }
            let (pCands, pScores, _) = layers[layers.count - 1]
            let gc = hypot(o.x - prevXY.x, o.y - prevXY.y)
            let dt: Double? = (o.t != nil && prevT != nil) ? o.t!.seconds(since: prevT!) : nil
            let beta = 4.0 + 0.15 * gc
            let cutoff = 2.5 * gc + 400.0
            var newScores = [Double](repeating: -.infinity, count: cands.count)
            var back = [Int](repeating: 0, count: cands.count)
            for (i, pc) in pCands.enumerated() where pScores[i] != -.infinity {
                for (j, cost) in net.routeCosts(pc, cands, cutoff).enumerated() where cost != .infinity {
                    if let dt, dt > 0, cost / dt > vmax * 1.5 { continue }
                    let sc = pScores[i] - abs(cost - gc) / beta + emis[j]
                    if sc > newScores[j] { newScores[j] = sc; back[j] = i }
                }
            }
            if newScores.allSatisfy({ $0 == -.infinity }) {
                fails += 1
                if fails <= 2 {                      // probably a stray point: skip it
                    skipped += 1
                    continue
                }
                finish()
                layers = [(cands, emis, nil)]
                fails = 0
            } else {
                fails = 0
                layers.append((cands, newScores, back))
            }
            prevXY = XY(o.x, o.y)
            prevT = o.t
        }
        finish()

        var lines: [TaggedLine] = [], pathNodes: [Int64] = [], wayIDs = Set<Int64>()
        for seq in chains {
            var pieces: [RoadNetwork.Piece] = []
            for (a, b) in zip(seq, seq.dropFirst()) {
                let gc = hypot(b.x - a.x, b.y - a.y)
                let (pcs, ns) = net.routePath(a, b, 3.0 * gc + 1000.0)
                if let pcs, !pcs.isEmpty {
                    pieces += pcs
                    pathNodes += ns
                }
            }
            var merged = try mergePieces(pieces, net.wayTags)
            // GPS noise at the very start/end of a stretch can poke a few meters into a
            // cross street; trim those stubs.
            while merged.count > 1 && merged[0].0.length < TrackRules.endStubM { merged.removeFirst() }
            while merged.count > 1 && merged[merged.count - 1].0.length < TrackRules.endStubM { merged.removeLast() }
            lines += merged.map { ($0.0, $0.1) }
            wayIDs.formUnion(merged.map(\.2))
        }
        return MatchResult(lines: lines, nodes: pathNodes, wayIDs: wayIDs, used: obs.count - skipped,
                           breaks: max(0, chains.count - 1), skipped: skipped)
    }
}
