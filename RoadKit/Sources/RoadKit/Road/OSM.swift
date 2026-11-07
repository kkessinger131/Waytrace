import Foundation

/// A way from Overpass's "out geom" (junction/ramp context).
struct ContextWay {
    var id: Int64
    var tags: Tags
    var nodes: [Int64]
    var geometry: [(lat: Double, lon: Double)]
}

extension RoadToKML {
    /// build_overpass_query: one regex covers every alias of the name, checked against the
    /// main, alternate, official and former names and route refs.
    func buildOverpassQuery(_ road: String, city: String, county: String, state: String, fips: String?) throws -> String {
        let areaID: Int64
        if !city.isEmpty { areaID = try services.cityAreaID(city, state) }
        else if !county.isEmpty { areaID = try services.countyAreaID(county, state) }
        else { areaID = try services.stateAreaID(state) }
        let regex = AliasEngine.overpassTagRegex(road, state: state, county: fips)
        let escaped = regex.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let clauses = ["name", "alt_name", "official_name", "old_name", "ref"].map {
            "  way[\"highway\"][\"\($0)\"~\"\(escaped)\",i](area:\(areaID));"
        }
        return "[out:json][timeout:120];\n(\n" + clauses.joined(separator: "\n") + "\n)->.w;\n(\n   .w;\n   >;\n);\nout body;\n"
    }

    /// fetch_ways: the OSM ways for a named road (nil if Overpass couldn't be reached).
    func fetchWays(_ road: String, city: String, county: String, state: String, wait: Bool, fips: String?) throws -> [OSMWay]? {
        let query = try buildOverpassQuery(road, city: city, county: county, state: state, fips: fips)
        let place = city.isEmpty ? county : city
        log("  Querying Overpass API for '\(road)' in \(place.isEmpty ? "" : place + ", ")\(state)...")
        guard let data = try overpassJSON(query, waitMode: wait) else { return nil }
        let ways = Overpass.ways(data)
        log("  Found \(ways.count) OSM way(s).")
        return ways
    }

    /// _fetch_osm_for_area
    func fetchOSMForArea(_ road: String, city: String, area: SearchArea, wait: Bool) throws -> [OSMWay]? {
        let state = area.state.name
        let fips = area.county != nil ? area.fips : nil
        if area.state.abbr == "dc" || area.county == nil {
            return try fetchWays(road, city: city, county: "", state: state, wait: wait, fips: fips)
        }
        return try fetchWays(road, city: "", county: area.county!, state: state, wait: wait, fips: fips)
    }

    static func osmLinesWGS84(_ ways: [OSMWay]?) -> [Geometry] {
        (ways ?? []).filter { $0.nodes.count >= 2 }.compactMap { w in
            try? Geometry.lineString(w.nodes.map { XY($0.lon, $0.lat) })
        }
    }

    /// ways_to_projected_lines: OSM ways -> UTM lines (zone from the mean longitude).
    func waysToProjectedLines(_ ways: [OSMWay]) throws -> ([TaggedLine], CRS) {
        let lons = ways.flatMap { $0.nodes.map(\.lon) }
        if lons.isEmpty { throw fail("No node coordinates found in OSM response.") }
        let utm = UTM(longitudes: lons)
        log("  Using projection: \(utm.epsg) (UTM zone \(utm.zone)N)")
        var out: [TaggedLine] = []
        for w in ways {
            let coords = w.nodes.map { utm.forward(lon: $0.lon, lat: $0.lat) }
            if coords.count >= 2 { out.append((try Geometry.lineString(coords), w.tags)) }
        }
        return (out, .utm(utm))
    }

    // MARK: - Direct OSM XML

    static func looksLikeURL(_ s: String) -> Bool { s.hasPrefix("http://") || s.hasPrefix("https://") }

    /// _normalize_osm_xml_url: viewer and bare API URLs -> the /full API call.
    static func normalizeOSMXMLURL(_ url: String) -> String {
        if let g = Re.groups(Re.compile("^https?://(?:www\\.)?openstreetmap\\.org/way/(\\d+)/?(?:[?#].*)?$"), url) {
            return "https://api.openstreetmap.org/api/0.6/way/\(g[1]!)/full"
        }
        if let g = Re.groups(Re.compile("^https?://(?:www\\.)?openstreetmap\\.org/relation/(\\d+)/?(?:[?#].*)?$"), url) {
            return "https://api.openstreetmap.org/api/0.6/relation/\(g[1]!)/full"
        }
        if let g = Re.groups(Re.compile("^(https?://[^/]+/api/0\\.6/(?:way|relation)/\\d+)/?(?:[?#].*)?$"), url) {
            return g[1]! + "/full"
        }
        return url
    }

    struct XMLSourceError: Error, CustomStringConvertible { let description: String }

    /// fetch_ways_from_osm_xml: ways from an OSM API URL, an openstreetmap.org page URL, or a
    /// saved .xml file.
    func fetchWaysFromOSMXML(_ source: String, road: String, state: String?) throws -> [OSMWay] {
        let bytes: Data
        if RoadToKML.looksLikeURL(source) {
            let api = RoadToKML.normalizeOSMXMLURL(source)
            if api != source { log("  Rewriting to '/full' endpoint for node coordinates: \(api)") }
            log("  Fetching OSM XML from \(api) ...")
            bytes = try services.fetchURL(api)
        } else {
            log("  Reading local OSM XML file: \(source)")
            bytes = try Data(contentsOf: resolvePath(source))
        }
        let root: MiniXMLNode
        do { root = try MiniXML.parse(bytes) } catch {
            throw XMLSourceError(description: "Could not parse OSM XML from '\(source)': \(error)")
        }
        var nodes: [String: (Double, Double)] = [:]
        for n in root.findAll("node") {
            guard let id = n.get("id"), let la = n.get("lat").flatMap(Double.init), let lo = n.get("lon").flatMap(Double.init) else { continue }
            nodes[id] = (la, lo)
        }
        var ways: [OSMWay] = []
        for w in root.findAll("way") {
            let wid = w.get("id") ?? ""
            var tags: Tags = [:]
            for t in w.findAll("tag") { if let k = t.get("k") { tags[k] = t.get("v") ?? "" } }
            let refs = w.findAll("nd").map { $0.get("ref") ?? "" }
            let missing = refs.filter { nodes[$0] == nil }
            if !missing.isEmpty {
                throw XMLSourceError(description: "Way \(wid) references \(missing.count) node(s) with no coordinates "
                    + "in this XML — it looks like a way-only export (no embedded nodes). Fetch the '/full' variant instead, e.g.\n"
                    + "    https://api.openstreetmap.org/api/0.6/way/\(wid)/full")
            }
            let wn = refs.map { (id: Int64($0) ?? 0, lat: nodes[$0]!.0, lon: nodes[$0]!.1) }
            if wn.count < 2 {
                log("  Warning: way \(wid) has fewer than 2 nodes — skipping.")
                continue
            }
            ways.append(OSMWay(id: Int64(wid) ?? 0, tags: tags, nodes: wn))
        }
        if ways.isEmpty { throw XMLSourceError(description: "No usable <way> elements found in OSM XML from '\(source)'.") }
        if !road.isEmpty && ways.count > 1 {
            let m = RoadMatcher(road, state: state)
            let filtered = ways.filter { w in
                ["name", "alt_name", "official_name", "old_name", "ref"].contains { key in
                    (w.tags[key] ?? "").split(separator: ";", omittingEmptySubsequences: false)
                        .contains { m.matches(Py.strip(String($0)), contains: false) }
                }
            }
            if !filtered.isEmpty { ways = filtered }
        }
        log("  Loaded \(ways.count) way(s) from XML.")
        return ways
    }

    // MARK: - Junctions, ramps, pavement outlines

    /// fetch_osm_context: ways touching the road's nodes and, with ramps, chains of *_link
    /// ramps leading off the road.
    func fetchOSMContext(_ wayIDs: Set<Int64>, ramps: Bool, wait: Bool) throws -> [ContextWay] {
        var out: [Int64: ContextWay] = [:], order: [Int64] = []
        let ids = wayIDs.sorted()
        for start in stride(from: 0, to: ids.count, by: 800) {
            let chunk = ids[start..<min(ids.count, start + 800)]
            var q = "[out:json][timeout:180];\nway(id:\(chunk.map(String.init).joined(separator: ",")))->.w;\nnode(w.w)->.n;\nway(bn.n)[\"highway\"]->.x;\n"
            if ramps {
                q += "way.x[\"highway\"~\"_link$\"]->.l1;\nnode(w.l1)->.n1;\nway(bn.n1)[\"highway\"~\"_link$\"]->.l2;\n"
                    + "node(w.l2)->.n2;\nway(bn.n2)[\"highway\"~\"_link$\"]->.l3;\n(.x; .l2; .l3;);\nout geom;\n"
            } else {
                q += ".x out geom;\n"
            }
            let data = try overpassJSON(q, waitMode: wait)
            for el in data?.elements ?? [] where el.type == "way" {
                if out[el.id] == nil { order.append(el.id) }
                out[el.id] = ContextWay(id: el.id, tags: el.tags, nodes: el.nodes, geometry: el.geometry.compactMap { $0 })
            }
        }
        return order.map { out[$0]! }
    }

    /// add_osm_context: junction discs and/or connected ramps for an OSM layer.
    func addOSMContext(_ layer: Layer, junctions: Bool, ramps: Bool, wait: Bool) throws {
        if layer.wayIDs.isEmpty || !(junctions || ramps) { return }
        let what = [("intersections", junctions), ("ramps", ramps)].filter(\.1).map(\.0).joined(separator: " and ")
        log("  Looking up \(what)...")
        let ctx = try fetchOSMContext(layer.wayIDs, ramps: ramps, wait: wait)
        if ctx.isEmpty { return }
        guard case .utm(let utm) = layer.crs else { return }
        let roadIDs = layer.wayIDs

        if ramps {
            var n = 0
            for w in ctx {
                if roadIDs.contains(w.id) || !(w.tags["highway"] ?? "").hasSuffix("_link") { continue }
                let coords = w.geometry.map { utm.forward(lon: $0.lon, lat: $0.lat) }
                if coords.count >= 2 {
                    var t = w.tags
                    t["_ramp"] = "1"
                    layer.lines.append((try Geometry.lineString(coords), t))
                    layer.wayIDs.insert(w.id)
                    n += 1
                }
            }
            if n > 0 { log("  Added \(n) connected ramp(s).") }
        }

        if junctions {
            var xy: [Int64: XY] = [:], incident: [Int64: Set<Int64>] = [:]
            var nbrs: [Int64: Set<[Int64]>] = [:], tags: [Int64: Tags] = [:]
            for w in ctx {
                tags[w.id] = w.tags
                let ns = w.nodes
                for (i, nid) in ns.enumerated() {
                    if i < w.geometry.count { xy[nid] = utm.forward(lon: w.geometry[i].lon, lat: w.geometry[i].lat) }
                    incident[nid, default: []].insert(w.id)
                    if i > 0 { nbrs[nid, default: []].insert([ns[i - 1], w.id]) }
                    if i + 1 < ns.count { nbrs[nid, default: []].insert([ns[i + 1], w.id]) }
                }
            }
            var roadNodes: [Int64] = [], seen = Set<Int64>()
            for w in ctx where roadIDs.contains(w.id) {
                for nid in w.nodes where !seen.contains(nid) { seen.insert(nid); roadNodes.append(nid) }
            }
            var n = 0
            for nid in roadNodes {
                let here = (incident[nid] ?? []).filter {
                    roadIDs.contains($0) || !TrackRules.minorTypes.contains(tags[$0]?["highway"] ?? "")
                }
                let dirs = Set((nbrs[nid] ?? []).filter { here.contains($0[1]) }.map { $0[0] })
                if here.count >= 2 && dirs.count >= 3, let p = xy[nid],
                   let disc = try RoadGeom.junctionDisc(p, here.sorted().map { roadWidth(tags[$0] ?? [:]) }) {
                    layer.junctions.append(disc)
                    n += 1
                }
            }
            if n > 0 { log("  Filled \(n) intersection(s).") }
        }
    }

    /// _outline_polygons: area:highway ways/relations from an "out geom" reply -> WGS84 polygons.
    static func outlinePolygons(_ data: OverpassReply?) throws -> [Geometry] {
        var polys: [Geometry] = []
        for el in data?.elements ?? [] {
            if el.type == "way" {
                let g = el.geometry.compactMap { $0 }.map { XY($0.lon, $0.lat) }
                if g.count >= 4 && g.first == g.last {
                    polys += RoadGeom.polygonParts(try Geometry.polygon(g).buffer(0))
                }
            } else if el.type == "relation" {
                var outer: [Geometry] = [], inner: [Geometry] = []
                for m in el.members {
                    let g = m.geometry.compactMap { $0 }.map { XY($0.lon, $0.lat) }
                    if m.type == "way" && g.count >= 2 {
                        let line = try Geometry.lineString(g)
                        if m.role == "inner" { inner.append(line) } else { outer.append(line) }
                    }
                }
                if outer.isEmpty { continue }
                var shape = try Geometry.unaryUnion(try Geometry.polygonize([try Geometry.unaryUnion(outer)]))
                if shape.isEmpty { continue }
                if !inner.isEmpty {
                    shape = try shape.difference(try Geometry.unaryUnion(try Geometry.polygonize([try Geometry.unaryUnion(inner)])))
                }
                polys += RoadGeom.polygonParts(try shape.buffer(0))
            }
        }
        return polys.filter { !$0.isEmpty && $0.area > 0 }
    }

    /// fetch_area_outlines: mapped pavement outlines (OSM area:highway) near the ways.
    func fetchAreaOutlines(_ wayIDs: Set<Int64>, wait: Bool) throws -> [Geometry] {
        var polys: [Geometry] = []
        let ids = wayIDs.sorted()
        for start in stride(from: 0, to: ids.count, by: 800) {
            let chunk = ids[start..<min(ids.count, start + 800)]
            let q = "[out:json][timeout:180];\nway(id:\(chunk.map(String.init).joined(separator: ",")))->.w;\n(\n"
                + "  way[\"area:highway\"](around.w:25);\n  relation[\"area:highway\"](around.w:25);\n);\nout geom;\n"
            polys += try RoadToKML.outlinePolygons(try overpassJSON(q, waitMode: wait))
        }
        return polys
    }

    /// apply_outlines: where a mapped outline covers a road's centerline, use the outline and
    /// drop that stretch of centerline (unless keepLines). Returns the number of outlines used.
    public static func applyOutlines(_ layers: [Layer], _ outlinesWGS84: [Geometry], keepLines: Bool = false) throws -> Int {
        var used = 0
        if outlinesWGS84.isEmpty { return 0 }
        for layer in layers where !layer.lines.isEmpty {
            let polys = try outlinesWGS84.map { try reproject($0, from: .wgs84, to: layer.crs) }
            let centers = try Geometry.unaryUnion(layer.lines.map(\.line))
            let area = try centers.buffer(30)
            let chosen = try polys.filter { p in
                guard p.intersects(area) else { return false }
                return try centers.intersection(p).length >= 2.0
            }
            if chosen.isEmpty { continue }
            layer.polys += chosen
            used += chosen.count
            if keepLines { continue }
            let covered = try Geometry.unaryUnion(chosen)
            var kept: [TaggedLine] = []
            for (line, tags) in layer.lines {
                for part in RoadGeom.lineParts(try line.difference(covered)) where part.length >= 0.5 {
                    kept.append((part, tags))
                }
            }
            layer.lines = kept
        }
        return used
    }

    /// _use_outlines
    func useOutlines(_ layers: [Layer], _ opts: Options) throws {
        if opts.outlines == "off" { return }
        let ids = layers.reduce(into: Set<Int64>()) { $0.formUnion($1.wayIDs) }
        if ids.isEmpty { return }
        log("\n  Looking for mapped pavement outlines (OSM area:highway)...")
        let outlines = try fetchAreaOutlines(ids, wait: opts.wait)
        let used = try RoadToKML.applyOutlines(layers, outlines, keepLines: opts.outlines == "both")
        if used == 0 {
            log("  None mapped here; using buffered centerlines.")
        } else if opts.outlines == "both" {
            log("  Combining \(used) pavement outline(s) with the buffered centerlines.")
        } else {
            log("  Using \(used) pavement outline(s); buffered centerlines elsewhere.")
        }
    }
}
