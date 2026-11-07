import Foundation

/// The OSM roads for a whole --track run, downloaded once: every grid cell any trip passes
/// through is fetched in one pass, then each trip group takes the ways near its own cells.
final class TrackRoads {
    var ways: [Int64: NetWay] = [:]
    var order: [Int64] = []
    var nodes: [Int64: LatLon] = [:]
    var missing = Set<Tracks.Cell>()
    var wayCells: [Int64: Set<Tracks.Cell>] = [:]

    init(_ engine: RoadToKML, _ trips: [Trip], wait: Bool) throws {
        var cellTypes: [Tracks.Cell: Set<String>] = [:], cellOrder: [Tracks.Cell] = []
        for t in trips {
            for c in Tracks.tripCells(t).sorted() {
                if cellTypes[c] == nil { cellOrder.append(c) }
                cellTypes[c, default: []].formUnion(TrackRules.networkTypes[t.category] ?? [])
            }
        }
        var byTypes: [Set<String>: Set<Tracks.Cell>] = [:], typeOrder: [Set<String>] = []
        for c in cellOrder {
            let ty = cellTypes[c]!
            if byTypes[ty] == nil { typeOrder.append(ty) }
            byTypes[ty, default: []].insert(c)
        }
        typeOrder = Tracks.stableSorted(typeOrder) { byTypes[$0]!.count > byTypes[$1]!.count }
        var jobs: [(Set<String>, [Box])] = []
        for ty in typeOrder {
            for batch in Tracks.batchBoxes(Tracks.cellsToBoxes(byTypes[ty]!)) { jobs.append((ty, batch)) }
        }
        let km2 = jobs.reduce(0.0) { $0 + $1.1.reduce(0.0) { $0 + Tracks.boxAreaKm2($1) } }
        engine.log("\n  Downloading OSM roads for all trips at once: \(jobs.count) request(s), \(PyFmt.f(km2, 0)) km² in total")
        var down = 0
        for (i, job) in jobs.enumerated() {
            if down >= 2 && !wait {
                for (_, rest) in jobs[i...] { markMissing(rest) }
                engine.log("  The OSM servers aren't answering; skipping the other \(jobs.count - i) request(s). Re-run with --wait to keep retrying.")
                break
            }
            if jobs.count > 1 { engine.log("  OSM request \(i + 1) of \(jobs.count)") }
            var failed: [Box] = []
            var budget = 8
            let (w, n, _) = try engine.fetchTrackNetwork(job.1, job.0, wait: wait, depth: 0, budget: &budget, failed: &failed)
            markMissing(failed)
            for way in w {
                if ways[way.id] == nil { order.append(way.id) }
                ways[way.id] = way
            }
            nodes.merge(n) { $1 }
            down = (!failed.isEmpty && w.isEmpty) ? down + 1 : 0
        }
        for wid in order {
            let pts = ways[wid]!.nodes.compactMap { nodes[$0] }
            wayCells[wid] = pts.isEmpty ? [] : Tracks.lineCells(pts)
        }
        engine.log("  \(ways.count) OSM road way(s) downloaded" + (missing.isEmpty ? "." : "; \(missing.count) map cell(s) couldn't be downloaded."))
    }

    func markMissing(_ boxes: [Box]) {
        let d = Tracks.cellDeg
        for b in boxes {
            let r0 = Int((b.s / d).rounded()), r1 = Int((b.n / d).rounded())
            let c0 = Int((b.w / d).rounded()), c1 = Int((b.e / d).rounded())
            for r in stride(from: r0, to: r1, by: 1) { for c in stride(from: c0, to: c1, by: 1) { missing.insert(Tracks.Cell(r: r, c: c)) } }
        }
    }

    /// for_cells: (ways, nodes, complete) for the roads in and next to the cells.
    func forCells(_ cells: Set<Tracks.Cell>) -> ([NetWay], [Int64: LatLon], Bool) {
        let near = Tracks.dilateCells(cells)
        let ws = order.filter { !(wayCells[$0] ?? []).isDisjoint(with: near) }.map { ways[$0]! }
        var ns: [Int64: LatLon] = [:]
        for w in ws { for n in w.nodes { if let p = nodes[n] { ns[n] = p } } }
        return (ws, ns, cells.isDisjoint(with: missing))
    }
}

extension RoadToKML {
    /// build_network_query: all roads of the given types in each (south, west, north, east) box.
    static func buildNetworkQuery(_ boxes: [Box], _ types: Set<String>) -> String {
        let t = types.sorted().joined(separator: "|")
        let lines = boxes.map { "  way[\"highway\"~\"^(\(t))$\"](\(PyFmt.f($0.s, 6)),\(PyFmt.f($0.w, 6)),\(PyFmt.f($0.n, 6)),\(PyFmt.f($0.e, 6)));" }
        return "[out:json][timeout:180];\n(\n" + lines.joined(separator: "\n") + "\n);\nout body;\n>;\nout skel qt;\n"
    }

    /// parse_overpass_network
    static func parseNetwork(_ data: OverpassReply) -> ([NetWay], [Int64: LatLon]) {
        var nodes: [Int64: LatLon] = [:], ways: [NetWay] = []
        for e in data.elements {
            if e.type == "node", let la = e.lat, let lo = e.lon { nodes[e.id] = (la, lo) }
            else if e.type == "way" { ways.append(NetWay(id: e.id, tags: e.tags, nodes: e.nodes)) }
        }
        return (ways, nodes)
    }

    /// fetch_track_network: the roads in the boxes. If Overpass can't finish, split the
    /// request in half and try each half (up to 8 extra requests per call).
    func fetchTrackNetwork(_ boxes: [Box], _ types: Set<String>, wait: Bool, depth: Int, budget: inout Int,
                           failed: inout [Box]) throws -> ([NetWay], [Int64: LatLon], Bool) {
        guard let data = try overpassJSON(RoadToKML.buildNetworkQuery(boxes, types), waitMode: wait, returnErrors: true) else {
            failed += boxes
            return ([], [:], false)
        }
        if !Overpass.error(data).isEmpty {
            budget -= 2
            if boxes.count == 1 || depth >= 6 || budget < 0 {
                log("  WARNING: Overpass couldn't return the roads for one area even after splitting; that stretch will be left out.")
                failed += boxes
                return ([], [:], false)
            }
            log("  Splitting this request into two smaller ones (\(boxes.count) boxes)...")
            let half = boxes.count / 2
            let (w1, n1, ok1) = try fetchTrackNetwork(Array(boxes[..<half]), types, wait: wait, depth: depth + 1, budget: &budget, failed: &failed)
            let (w2, n2, ok2) = try fetchTrackNetwork(Array(boxes[half...]), types, wait: wait, depth: depth + 1, budget: &budget, failed: &failed)
            return (w1 + w2, n1.merging(n2) { $1 }, ok1 && ok2)
        }
        let (w, n) = RoadToKML.parseNetwork(data)
        return (w, n, true)
    }

    func trackOutputName(_ o: Options, _ sourceTags: [String]) -> String {
        var part: String
        if let d = o.date, Py.strip(d).lowercased() != "all" {
            part = Py.strip(d).replacingOccurrences(of: "..", with: "_to_")
        } else {
            let base = o.track![0].replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
            part = Planning.safeName(Re.sub(Re.compile("\\.[^.]+$"), "", base))
        }
        var stem = Planning.safeName("track_\(part)")
        if stem.isEmpty { stem = "track" }
        let suffix = "_" + (sourceTags.isEmpty ? ["osm"] : sourceTags).joined(separator: "_") + ".kml"
        return String(stem.prefix(Planning.maxFilenameLength - suffix.count)).trimmingTrailing(in: "._-") + suffix
    }

    static func junctionPolys(_ net: RoadNetwork, _ res: MatchResult, _ on: Bool) throws -> [Geometry] {
        guard on else { return [] }
        return try net.junctionNodes(res.nodes, res.wayIDs).compactMap { n, ws in
            try RoadGeom.junctionDisc(net.xy[n]!, ws.map { roadWidth(net.wayTags[$0] ?? [:]) })
        }
    }

    static func km(_ lines: [TaggedLine]) -> Double { lines.reduce(0) { $0 + $1.line.length } / 1000 }

    /// _detoured: matched road far longer than the trip itself (usually a road missing from
    /// the map, so the matcher went around it).
    static func detoured(_ lines: [TaggedLine], _ trip: Trip) -> Bool {
        !lines.isEmpty && km(lines) > 1.5 * Tracks.tripLengthKm(trip) + 0.2
    }

    /// _outside: parts of lines more than gap m from every line in others.
    static func outside(_ lines: [TaggedLine], _ others: [TaggedLine], gap: Double = 20, minLen: Double = 30) throws -> [TaggedLine] {
        if others.isEmpty { return lines }
        let zone = try Geometry.unaryUnion(others.map(\.line)).buffer(gap)
        var out: [TaggedLine] = []
        for (line, tags) in lines {
            for part in RoadGeom.lineParts(try line.difference(zone)) where part.length >= minLen { out.append((part, tags)) }
        }
        return out
    }

    /// run_tracks: map-match GPS history onto OSM and/or TIGER/Line roads.
    func runTracks(_ o: Options) throws -> String? {
        if !o.road.isEmpty { throw UsageError("--track and --road can't be used together") }
        let (modes, _) = try Planning.parseSources(o.source)
        if modes == ["xml"] { throw UsageError("--source xml can't be used with --track") }
        if !o.clipFrom.isEmpty || !o.clipTo.isEmpty {
            throw UsageError("--from/--to apply to --road searches (a track is already clipped to where you went)")
        }
        let travel = Re.split(Re.compile("[,\\s]+"), o.travelModes).map { Py.strip($0).lowercased() }.filter { !$0.isEmpty }
        let bad = travel.filter { !TrackRules.categories.contains($0) }
        if !bad.isEmpty {
            throw UsageError("--travel-modes: unknown \(PyFmt.list(bad)) (choose from \(TrackRules.categories.joined(separator: ", ")))")
        }
        if !o.state.isEmpty || !o.county.isEmpty || !o.city.isEmpty {
            log("  Note: --state/--county/--city are ignored with --track (the track sets the area).")
        }
        let useOSM = modes != ["tiger"]
        let tigerAll = modes.contains("tiger")
        let tigerFill = modes == ["auto"]
        let label = ["auto": "OSM, with TIGER/Line where OSM has nothing", "osm": "OSM", "tiger": "TIGER/Line",
                     "osm,tiger": "OSM + TIGER/Line"][modes.joined(separator: ",")]!
        log("\n\(RoadToKML.rule)")
        log("  Road to KML  —  GPS track\(o.date.map { " " + $0 } ?? "")")
        log(RoadToKML.rule)
        log("  Source: \(label)")

        let trips: [Trip]
        do {
            var files: [(path: String, data: Data)] = []
            for p in o.track! {
                do { files.append((p, try Data(contentsOf: resolvePath(p)))) } catch {
                    throw InputError("[Errno 2] No such file or directory: \(AliasEngine.pyRepr(p))")
                }
            }
            trips = try Tracks.loadTrips(files, dateSpec: o.date, travelModes: travel, log: { [unowned self] in self.log($0) })
        } catch let e as InputError {
            throw fail(e.description)
        } catch let e as XMLParseError {
            throw fail(e.description)
        }
        if trips.isEmpty { throw fail("No trips found for those dates and travel modes.") }

        var byCat: [String: Double] = [:]
        for t in trips { byCat[t.category, default: 0] += Tracks.tripLengthKm(t) }
        log("  \(trips.count) trip(s): " + byCat.keys.sorted().map { "\($0) \(PyFmt.f(byCat[$0]!, 1)) km" }.joined(separator: ", "))
        lastTrips = trips

        var layers: [Layer] = [], used = Set<String>()
        var totalGaps = 0, unmatched = 0
        let osmRoads = useOSM ? try TrackRoads(self, trips, wait: o.wait) : nil
        let groups = groupTripsOverride?(trips) ?? Tracks.groupTrips(trips)
        for (gi, group) in groups.enumerated() {
            try checkCancel()
            let cells = group.reduce(into: Set<Tracks.Cell>()) { $0.formUnion(Tracks.tripCells($1)) }
            let boxes = Tracks.cellsToBoxes(cells)
            let utm = UTM(longitudes: group.flatMap { $0.points.map(\.lon) })
            let crs = CRS.utm(utm)
            let when = group[0].points[0].t.map { ", from \($0.localTime.format("yyyy-MM-dd HH:mm"))" } ?? ""
            log("\n  --- Trip group \(gi + 1) of \(groups.count) (\(group.count) trip(s)\(when)) ---")

            // OSM, from the one download made for the whole run
            var osmRes: [Int: (RoadNetwork, MatchResult)] = [:], osmNets: [String: RoadNetwork] = [:]
            if let osmRoads {
                let (ways, nodes, complete) = osmRoads.forCells(cells)
                log("  \(ways.count) OSM road way(s) around the track.")
                if ways.isEmpty {
                    if complete {
                        let b = boxes[0]
                        log("  WARNING: Overpass answered but found no roads for these trips (first area: south \(PyFmt.repr(b.s)), west \(PyFmt.repr(b.w)), north \(PyFmt.repr(b.n)), east \(PyFmt.repr(b.e))).")
                    } else {
                        log("  WARNING: no OSM road data for these trips (Overpass didn't answer).")
                    }
                } else {
                    if !complete { log("  WARNING: part of the OSM road data is missing.") }
                    for t in group {
                        let net = osmNets[t.category] ?? RoadNetwork(ways, nodes, category: t.category, utm: utm)
                        osmNets[t.category] = net
                        osmRes[t.uid] = (net, try Tracks.matchTrip(net, t))
                    }
                }
            }

            // TIGER/Line, for every trip or only where OSM came up short
            var needTiger: [Trip] = []
            for t in group {
                let r = osmRes[t.uid]
                let offRoad = r.map { Double($0.1.skipped) >= max(3, 0.1 * Double(t.points.count)) } ?? false
                if tigerAll || (tigerFill && (r == nil || r!.1.lines.isEmpty || r!.1.breaks > 0 || offRoad
                                              || RoadToKML.detoured(r!.1.lines, t))) {
                    needTiger.append(t)
                }
            }
            var tigerRes: [Int: (RoadNetwork, MatchResult)] = [:], tigerNets: [String: RoadNetwork] = [:]
            if !needTiger.isEmpty {
                log("  Using TIGER/Line\(tigerAll ? "" : " to fill what OSM couldn't match")...")
                let tcells = needTiger.reduce(into: Set<Tracks.Cell>()) { $0.formUnion(Tracks.tripCells($1)) }
                let (tways, tnodes, counties, tcomplete) = try tigerTrackNetwork(Tracks.cellsToBoxes(tcells))
                if !counties.isEmpty { log("  Counties: \(counties.joined(separator: "; "))") }
                log("  \(tways.count) TIGER/Line road segment(s) around the track.")
                if !tcomplete { log("  WARNING: some TIGER/Line data couldn't be downloaded.") }
                if !tways.isEmpty {
                    for t in needTiger {
                        let net = tigerNets[t.category] ?? RoadNetwork(tways, tnodes, category: t.category, utm: utm)
                        tigerNets[t.category] = net
                        tigerRes[t.uid] = (net, try Tracks.matchTrip(net, t))
                    }
                }
            }

            // results per trip
            for t in group {
                let stamp = t.points[0].t.map { $0.localTime.format("yyyy-MM-dd HH:mm") } ?? "untimed"
                var parts: [String] = []
                var oRes = osmRes[t.uid]
                let g = tigerRes[t.uid]
                var oLines = oRes?.1.lines ?? []
                if tigerFill, !oLines.isEmpty, let g, !g.1.lines.isEmpty, RoadToKML.detoured(oLines, t), !RoadToKML.detoured(g.1.lines, t) {
                    log("  \(stamp)  OSM went the long way round here (a road missing from OSM?); using TIGER/Line for this trip.")
                    oRes = nil
                    oLines = []
                }
                if let oRes, !oLines.isEmpty {
                    layers.append(Layer(oLines, crs, "osm", wayIDs: oRes.1.wayIDs,
                                        junctions: try RoadToKML.junctionPolys(oRes.0, oRes.1, o.junctions)))
                    used.insert("osm")
                    parts.append("\(PyFmt.f(RoadToKML.km(oLines), 1)) km OSM")
                }
                if let g, !g.1.lines.isEmpty {
                    let tLines = tigerAll || oLines.isEmpty ? g.1.lines : try RoadToKML.outside(g.1.lines, oLines)
                    if !tLines.isEmpty {
                        let keep = try Geometry.unaryUnion(tLines.map(\.line)).buffer(1.0)
                        let polys = try RoadToKML.junctionPolys(g.0, g.1, o.junctions).filter { $0.intersects(keep) }
                        layers.append(Layer(tLines, crs, "tiger", junctions: polys))
                        used.insert("tiger")
                        parts.append("\(PyFmt.f(RoadToKML.km(tLines), 1)) km TIGER/Line" + (tigerAll || oLines.isEmpty ? "" : " filling gaps"))
                    }
                }
                // a stretch only counts as a gap if no source covered it
                let gaps = [oRes, g].compactMap { $0?.1.breaks }.min() ?? 0
                totalGaps += gaps
                if parts.isEmpty { unmatched += 1 }
                let note = gaps > 0 && !parts.isEmpty ? ", \(gaps) gap(s)" : ""
                let cat = t.category.padding(toLength: max(5, t.category.count), withPad: " ", startingAt: 0)
                let km = PyFmt.f(Tracks.tripLengthKm(t), 1)
                let kmPadded = String(repeating: " ", count: max(0, 6 - km.count)) + km
                log("  \(stamp)  \(cat)  \(kmPadded) km tracked -> " + (parts.isEmpty ? "nothing matched" : parts.joined(separator: " + ")) + note)
            }
        }

        if layers.isEmpty {
            throw fail("Nothing could be matched to roads." + (useOSM ? " The map servers may be busy: re-run with --wait." : ""), blankLine: true)
        }
        if unmatched > 0 {
            log("\n  WARNING: \(unmatched) trip(s) couldn't be matched to any road" + (useOSM ? " (re-run with --wait if the map servers were busy)." : "."))
        }
        if totalGaps > 0 {
            log("\n  Note: \(totalGaps) gap(s) where a trip couldn't be followed on the road network (missing road, tunnel, or GPS jump); those stretches are left out.")
        }
        if used.contains("osm") { try useOutlines(layers, o) }
        let sourceTags = ["osm", "tiger"].filter { used.contains($0) }
        let output = Py.strip(o.output).isEmpty ? trackOutputName(o, sourceTags) : Py.strip(o.output)
        let roadLabel = o.date.map { "track \($0)" } ?? "track"
        let place = byCat.keys.sorted().joined(separator: ", ") + " trips"
        let sources = sourceTags.map { RoadToKML.sourceLabels[$0]! }.joined(separator: " + ")
        return try finishOutput(layers, o, road: roadLabel, place: place, source: "\(sources) (map-matched GPS track)", output: output)
    }
}
