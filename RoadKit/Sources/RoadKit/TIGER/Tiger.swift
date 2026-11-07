import Foundation

extension RoadToKML {
    /// TIGER/Line years are found automatically: the current year first, back to this one.
    public static let tigerOldestYear = 2022

    /// _tiger_years: newest first; once a year has worked this run, start there.
    func tigerYears() -> [Int] {
        var years = Array(stride(from: currentYear, through: RoadToKML.tigerOldestYear, by: -1))
        if let found = tigerYearFound, let i = years.firstIndex(of: found) { years = Array(years[i...]) }
        return years
    }

    static func isDownloadError(_ e: Error) -> Bool { e is NetError }

    /// _download_tiger: one county TIGER/Line zip (ROADS or FEATNAMES); nil if not published.
    func downloadTiger(_ layer: String, _ fips: String, _ year: Int) throws -> Data? {
        try checkCancel()
        log("  Downloading TIGER/Line \(layer.lowercased()): https://www2.census.gov/geo/tiger/TIGER\(year)/\(layer.uppercased())/tl_\(year)_\(fips)_\(layer.lowercased()).zip")
        return try services.downloadTiger(layer, fips, year)
    }

    /// _download_tiger_roads: one county's roads (newest year), or nil.
    func downloadTigerRoads(_ fips: String) throws -> (ShapeTable, Int)? {
        var zip: Data?, year = 0
        for y in tigerYears() {
            let data: Data?
            do { data = try downloadTiger("ROADS", fips, y) } catch where RoadToKML.isDownloadError(error) {
                log("  Download failed (\(y)): \(error)")
                continue
            }
            guard let data else {
                log("  Not found for \(y), trying earlier year...")
                continue
            }
            zip = data
            year = y
            tigerYearFound = y
            break
        }
        guard let zip else {
            log("  ERROR: Could not download TIGER/Line shapefile for any recent year.")
            return nil
        }
        guard let table = try Shapefile.readZip(zip, ext: ".shp") else {
            log("  ERROR: No .shp file found in TIGER/Line zip.")
            return nil
        }
        return (table, year)
    }

    /// _tiger_name_mask: rows matching the road by FULLNAME or (via the feature-names table)
    /// an alternate name. Returns (mask, rows found only via alternate names).
    static func tigerNameMask(_ roads: ShapeTable, _ featnames: ShapeTable?, _ road: String, state: String?,
                              fips: String?) -> ([Bool], Int) {
        let m = RoadMatcher(road, state: state, county: fips)
        var cache: [String: Bool] = [:]
        func ok(_ n: String?) -> Bool {
            guard let n else { return false }
            if let c = cache[n] { return c }
            let v = m.matches(n)
            cache[n] = v
            return v
        }
        var mask = roads.records.map { ok($0["FULLNAME"]) }
        var viaAlt = 0
        if let fn = featnames, roads.columns.contains("LINEARID") {
            let altIDs = Set(fn.records.filter { ok($0["FULLNAME"]) }.compactMap { $0["LINEARID"] })
            if !altIDs.isEmpty {
                for (i, r) in roads.records.enumerated() {
                    if let id = r["LINEARID"], altIDs.contains(id) {
                        if !mask[i] { viaAlt += 1 }
                        mask[i] = true
                    }
                }
            }
        }
        return (mask, viaAlt)
    }

    static func tigerTags(_ r: ShapeRecord) -> Tags {
        let mtfcc = r["MTFCC"] ?? "S1400"
        return ["tiger_width": PyFmt.repr(RoadWidths.tiger[mtfcc] ?? RoadWidths.fallback), "MTFCC": mtfcc]
    }

    /// fetch_ways_tiger: the county's TIGER/Line features matching the road or its aliases
    /// (primary or alternate names), projected to UTM. nil if none match.
    func fetchWaysTiger(_ road: String, fips: String, state: String?, label: String = "", crossNames: [String] = [],
                        junctions: Bool = false, ramps: Bool = false) throws -> Layer? {
        let label = label.isEmpty ? "county \(fips)" : label
        log("  County FIPS: \(fips)")
        guard let (roads, year) = try downloadTigerRoads(fips) else { return nil }

        var featnames: ShapeTable?
        do {
            if let bytes = try downloadTiger("FEATNAMES", fips, year) {
                featnames = try Shapefile.readZip(bytes, ext: ".dbf", geometry: false)
                if let fn = featnames, !(fn.columns.contains("LINEARID") && fn.columns.contains("FULLNAME")) { featnames = nil }
            }
        } catch let e as CancelledError {
            throw e
        } catch {
            log("  (Skipping TIGER alternate names: \(error))")
        }

        let (mask, viaAlt) = RoadToKML.tigerNameMask(roads, featnames, road, state: state, fips: fips)
        let matched = roads.records.indices.filter { mask[$0] }
        if matched.isEmpty {
            log("  No TIGER/Line features matched '\(road)' in \(label).")
            log("  Tried aliases such as: \(variantsPreview(road, state))")
            return nil
        }
        let names = Set(matched.compactMap { roads.records[$0]["FULLNAME"] }).sorted()
        let shown = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " ..." : "")
        let altNote = viaAlt > 0 ? "; \(viaAlt) found via TIGER alternate names" : ""
        log("  Found \(matched.count) TIGER/Line feature(s) matching '\(road)' (\(shown)\(altNote)).")

        let lons = matched.flatMap { RoadGeom.lineParts(roads.records[$0].geometry).flatMap { $0.coords.map(\.x) } }
        if lons.isEmpty {
            log("  ERROR: No coordinate data in matched TIGER features.")
            return nil
        }
        let utm = UTM(longitudes: lons)
        log("  Using projection: \(utm.epsg) (UTM zone \(utm.zone)N)")
        func project(_ part: Geometry) throws -> Geometry { try Geometry.lineString(part.coords.map { utm.forward($0) }) }

        var lines: [TaggedLine] = []
        for i in matched {
            let tags = RoadToKML.tigerTags(roads.records[i])
            for part in RoadGeom.lineParts(roads.records[i].geometry) where part.coords.count >= 2 {
                lines.append((try project(part), tags))
            }
        }
        if lines.isEmpty { return nil }
        let layer = Layer(lines, .utm(utm), "tiger")

        for name in crossNames {
            let (cmask, _) = RoadToKML.tigerNameMask(roads, featnames, name, state: state, fips: fips)
            layer.cross[name] = roads.records.indices.filter { cmask[$0] }.flatMap { RoadGeom.lineParts(roads.records[$0].geometry) }
        }

        if junctions || ramps {
            var box = BBox(.infinity, .infinity, -.infinity, -.infinity)
            for i in matched { if let b = roads.records[i].geometry?.bounds { box = box.union(b) } }
            let pad = ramps ? 0.03 : 0.002
            let area = Geometry.box(box.minX - pad, box.minY - pad, box.maxX + pad, box.maxY + pad)
            let matchedSet = Set(matched)
            var others: [TaggedLine] = []
            for i in roads.intersecting(area) where !matchedSet.contains(i) {
                let tags = RoadToKML.tigerTags(roads.records[i])
                for part in RoadGeom.lineParts(roads.records[i].geometry) where part.coords.count >= 2 {
                    others.append((try project(part), tags))
                }
            }
            if ramps {
                let added = try RoadGeom.connectedRamps(lines.map(\.line), others.filter { $0.tags["MTFCC"] == "S1630" })
                for (line, tags) in added {
                    var t = tags
                    t["_ramp"] = "1"
                    layer.lines.append((line, t))
                }
                if !added.isEmpty { log("  Added \(added.count) connected ramp segment(s).") }
            }
            if junctions {
                let cross = others.filter { !RoadWidths.tigerMinor.contains($0.tags["MTFCC"] ?? "") }
                let discs = try RoadGeom.junctionDiscsByGeometry(layer.lines, cross)
                layer.junctions += discs
                if !discs.isEmpty { log("  Filled \(discs.count) intersection(s).") }
            }
        }
        return layer
    }

    // MARK: - Road networks for --track

    /// county_shapes: the Census Bureau's county outlines (GEOID, NAME, STATEFP), or nil.
    func countyShapes() throws -> [ShapeRecord]? {
        if let c = countyShapesCache { return c }
        for y in stride(from: currentYear, through: RoadToKML.tigerOldestYear, by: -1) {
            let data: Data?
            do {
                try checkCancel()
                log("  Downloading county outlines: https://www2.census.gov/geo/tiger/GENZ\(y)/shp/cb_\(y)_us_county_5m.zip")
                data = try services.downloadCountyShapes(y)
            } catch where RoadToKML.isDownloadError(error) {
                log("  Download failed (\(y)): \(error)")
                continue
            }
            if let data, !data.isEmpty {
                countyShapesCache = try Shapefile.readZip(data, ext: ".shp")?.records ?? []
                return countyShapesCache
            }
        }
        log("  ERROR: Could not download the county outlines.")
        return nil
    }

    static func boxGeometry(_ boxes: [Box]) throws -> Geometry {
        try Geometry.unaryUnion(boxes.map { Geometry.box($0.w, $0.s, $0.e, $0.n) })
    }

    /// counties_for_boxes: [(fips, "Harris County, TX")] for counties touching the boxes
    /// (with ~1 km to spare, since the outlines are simplified).
    func countiesForBoxes(_ boxes: [Box]) throws -> [(fips: String, label: String)] {
        guard let shapes = try countyShapes() else { return [] }
        let area = try RoadToKML.boxGeometry(boxes).buffer(0.01)
        var stateOf: [String: String] = [:]
        for (st, _, f) in countyFIPSTable { stateOf[String(f.prefix(2))] = st }
        var out: [(String, String)] = []
        for r in shapes where r.geometry?.intersects(area) ?? false {
            let geoid = r["GEOID"] ?? "None"
            let st = stateOf[String(geoid.prefix(2))] ?? ""
            let name = r["NAMELSAD"] ?? r["NAME"] ?? geoid
            out.append((geoid, st.isEmpty ? name : "\(name), \(st.uppercased())"))
        }
        return out.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }

    /// tiger_track_network: TIGER/Line roads inside the boxes as ways and nodes for
    /// RoadNetwork. Intersections are where lines share a point (so overpasses stay
    /// unconnected); TIGER/Line has no one-way information, so every road is two-way.
    func tigerTrackNetwork(_ boxes: [Box], idStart: Int64 = 1_000_000_000_000) throws
        -> (ways: [NetWay], nodes: [Int64: LatLon], counties: [String], complete: Bool) {
        let counties = try countiesForBoxes(boxes)
        if counties.isEmpty { return ([], [:], [], false) }
        let area = try RoadToKML.boxGeometry(boxes)
        var ways: [NetWay] = [], nodes: [Int64: LatLon] = [:], keyToID: [NodeKey: Int64] = [:]
        var complete = true
        var wid = idStart
        for (fips, name) in counties {
            if tigerRoadsCache[fips] == nil {
                log("  TIGER/Line roads for \(name) (\(fips))")
                tigerRoadsCache[fips] = .some(try downloadTigerRoads(fips)?.0)
            }
            guard let table = tigerRoadsCache[fips] ?? nil else {
                complete = false
                continue
            }
            for i in table.intersecting(area) {
                let r = table.records[i]
                let mtfcc = r["MTFCC"] ?? "S1400"
                let tags: Tags = ["highway": RoadWidths.tigerHighway[mtfcc] ?? "road", "oneway": "no",
                                  "name": r["FULLNAME"] ?? "", "MTFCC": mtfcc,
                                  "tiger_width": PyFmt.repr(RoadWidths.tiger[mtfcc] ?? RoadWidths.fallback)]
                for part in RoadGeom.lineParts(r.geometry) {
                    var ids: [Int64] = []
                    for c in part.coords {
                        let k = NodeKey(c, digits: 1e7)
                        var nid = keyToID[k]
                        if nid == nil {
                            nid = Int64(keyToID.count + 1)
                            keyToID[k] = nid
                            nodes[nid!] = (c.y, c.x)
                        }
                        if ids.last != nid { ids.append(nid!) }
                    }
                    if ids.count >= 2 {
                        ways.append(NetWay(id: wid, tags: tags, nodes: ids))
                        wid += 1
                    }
                }
            }
        }
        return (ways, nodes, counties.map(\.label), complete)
    }
}
