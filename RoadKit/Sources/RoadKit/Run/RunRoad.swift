import Foundation

extension RoadToKML {
    static let sourceLabels = ["osm": "OSM", "tiger": "TIGER/Line"]
    static let rule = String(repeating: "=", count: 55)

    /// run_road: a named road from OSM and/or TIGER/Line (or one OSM XML document).
    func runRoad(_ o: Options) throws -> String? {
        var road = Py.strip(o.road)
        let city = Py.strip(o.city), county = Py.strip(o.county)
        var output = Py.strip(o.output)
        let (modes, osmXML) = try Planning.parseSources(o.source)
        let xmlMode = modes == ["xml"]
        if road.isEmpty && osmXML.isEmpty { throw fail("--road is required unless --source xml or --track is given.") }

        // --from / --to
        let clipFrom = Py.strip(o.clipFrom), clipTo = Py.strip(o.clipTo)
        if clipFrom.isEmpty != clipTo.isEmpty { throw UsageError("--from and --to go together") }
        let fromPt: (lat: Double, lon: Double)?, toPt: (lat: Double, lon: Double)?
        do {
            fromPt = try Planning.parseClipPoint(clipFrom)
            toPt = try Planning.parseClipPoint(clipTo)
        } catch let e as InputError {
            throw UsageError(e.description)
        }
        var crossNames: [String] = []
        if !clipFrom.isEmpty && fromPt == nil { crossNames.append(clipFrom) }
        if !clipTo.isEmpty && toPt == nil { crossNames.append(clipTo) }
        if xmlMode && !crossNames.isEmpty { throw UsageError("with --source xml, --from/--to must be lat,lon points") }

        // States
        var states: [StateInfo] = []
        if !Py.strip(o.state).isEmpty {
            do {
                states = try parseStates(o.state)
            } catch let e as InputError {
                if !xmlMode { throw fail(e.description) }
                let s = Py.strip(o.state)
                states = [StateInfo(abbr: nil, name: s, typed: s)]       // only used for the filename
            }
        }

        if o.listAliases {
            if road.isEmpty { throw fail("--list-aliases needs --road.") }
            let ctxs: [String?] = states.compactMap(\.abbr).isEmpty ? [nil] : states.compactMap(\.abbr)
            for c in ctxs {
                log(AliasEngine.describe(road, state: c))
                log()
            }
            return nil
        }
        if !xmlMode && states.isEmpty { throw fail("--state is required for --source \(modes.joined(separator: ",")).") }
        if !city.isEmpty && states.count > 1 { throw fail("--city can only be used with a single --state.") }

        var layers: [Layer] = [], used = Set<String>(), areas: [SearchArea] = []
        var crossLines: [String: [Geometry]] = [:]

        if xmlMode {
            log("\n\(RoadToKML.rule)")
            log("  Road to KML  —  direct OSM XML source")
            log(RoadToKML.rule)
            let xmlState = states.count == 1 ? states[0].abbr : nil
            let ways: [OSMWay]
            do {
                ways = try fetchWaysFromOSMXML(osmXML, road: road, state: xmlState)
            } catch let e as CancelledError {
                throw e
            } catch {
                throw fail("\(error)", blankLine: true)
            }
            if road.isEmpty {
                let t = ways[0].tags
                road = t["name"].flatMap { $0.isEmpty ? nil : $0 } ?? t["ref"].flatMap { $0.isEmpty ? nil : $0 } ?? "OSM_way_\(ways[0].id)"
                log("  No --road given — using name from XML: '\(road)'")
            }
            let (lines, crs) = try waysToProjectedLines(ways)
            layers.append(Layer(lines, crs, "osm"))
            used.insert("osm")
        } else {
            do { areas = try planSearchAreas(states, county) } catch let e as InputError { throw fail(e.description) }

            if modes.contains("tiger") {
                let noCounty = areas.filter { $0.fips == nil && $0.county == nil }.map(\.state.name)
                let unresolved = areas.filter { $0.fips == nil && $0.county != nil }
                if !noCounty.isEmpty || !unresolved.isEmpty {
                    for a in unresolved {
                        do { _ = try Planning.resolveCountyFIPS(a.county!, a.state.abbr ?? "") } catch {
                            log("ERROR: \(error)")
                        }
                    }
                    if !noCounty.isEmpty {
                        log("ERROR: --source tiger requires --county for: \(noCounty.joined(separator: ", ")).")
                        log("  TIGER/Line shapefiles are distributed by county (DC needs no county).")
                        log("  Example: --county \"Travis County\" --state \"Texas\"")
                    }
                    throw ExitError(1, "--source tiger needs a county")
                }
            }

            let modeLabel = modes == ["auto"] ? "OSM, falling back to TIGER/Line" : modes.map { RoadToKML.sourceLabels[$0]! }.joined(separator: " + ")
            log("\n\(RoadToKML.rule)")
            log("  Road to KML  —  \(road)")
            log(RoadToKML.rule)
            log("  Source: \(modeLabel)")
            log("  Areas:  \(areas.map { Planning.areaLabel($0, city: city) }.joined(separator: "; "))")
            log("  Aliases: \(variantsPreview(road, states[0].abbr))")
            if !clipFrom.isEmpty { log("  Stretch: from \(clipFrom) to \(clipTo)") }
            for a in areas {
                if let hint = AliasEngine.renameHint(road, state: a.state.abbr, county: a.county != nil ? a.fips : nil) {
                    log("  Note: \(hint)")
                    break
                }
            }

            var seen = Set<Int64>()
            for area in areas {
                try checkCancel()
                let label = Planning.areaLabel(area, city: city)
                log("\n  --- \(label) ---")
                var gotOSM = false
                if modes == ["auto"] || modes.contains("osm") {
                    if let ways = try fetchOSMForArea(road, city: city, area: area, wait: o.wait), !ways.isEmpty {
                        gotOSM = true
                        let new = ways.filter { !seen.contains($0.id) }
                        seen.formUnion(ways.map(\.id))
                        if !new.isEmpty {
                            let (lines, crs) = try waysToProjectedLines(new)
                            let layer = Layer(lines, crs, "osm", wayIDs: Set(new.map(\.id)))
                            try addOSMContext(layer, junctions: o.junctions, ramps: o.ramps, wait: o.wait)
                            layers.append(layer)
                            used.insert("osm")
                        }
                        for name in crossNames {
                            log("  Looking up cross street '\(name)'...")
                            crossLines[name, default: []] += RoadToKML.osmLinesWGS84(
                                try fetchOSMForArea(name, city: city, area: area, wait: o.wait))
                        }
                    }
                }
                if modes.contains("tiger") || (modes == ["auto"] && !gotOSM) {
                    guard let fips = area.fips else {
                        if let c = area.county {
                            log("  No OSM result here, and '\(c)' isn't in county_fips.py, so there is no TIGER/Line fallback.")
                        } else {
                            log("  No OSM result here, and no county for a TIGER/Line fallback (add --county to enable it).")
                        }
                        continue
                    }
                    if modes == ["auto"] { log("  No OSM ways found in \(label) — trying TIGER/Line...") }
                    if let layer = try fetchWaysTiger(road, fips: fips, state: area.state.abbr, label: label,
                                                      crossNames: crossNames, junctions: o.junctions, ramps: o.ramps) {
                        layers.append(layer)
                        used.insert("tiger")
                        for (name, lines) in layer.cross { crossLines[name, default: []] += lines }
                    }
                }
            }
        }

        if layers.isEmpty { throw fail("No ways found for '\(road)' from any source.", blankLine: true) }

        let sourceTags = ["osm", "tiger"].filter { used.contains($0) }
        let sourceUsed = xmlMode ? "OSM XML (direct)" : sourceTags.map { RoadToKML.sourceLabels[$0]! }.joined(separator: " + ")
        let missing = modes.filter { RoadToKML.sourceLabels[$0] != nil && !used.contains($0) }
        if !missing.isEmpty {
            log("\n  WARNING: \(missing.map { RoadToKML.sourceLabels[$0]! }.joined(separator: " and ")) returned nothing; the output uses \(sourceUsed) only.")
        }
        log("  Source: \(sourceUsed)")

        if !clipFrom.isEmpty {
            func spec(_ text: String, _ pt: (lat: Double, lon: Double)?) -> ClipSpec {
                if let pt { return .point(lat: pt.lat, lon: pt.lon, label: text) }
                return .street(lines: crossLines[text] ?? [], label: "'\(text)'")
            }
            do {
                layers = [try clipLayers(layers, spec(clipFrom, fromPt), spec(clipTo, toPt))]
            } catch let e as ClipError {
                log("\nERROR: \(e)")
                log("  Check the cross-street names (aliases are searched), or use lat,lon points.")
                throw ExitError(1, e.description)
            }
        }

        if used.contains("osm") || xmlMode { try useOutlines(layers, o) }

        if output.isEmpty {
            output = Planning.defaultOutputName(road, city: city, states: states, areas: areas, sourceTags: sourceTags,
                                                clip: clipFrom.isEmpty ? nil : (clipFrom, clipTo))
        }
        var place: String
        if !city.isEmpty { place = "\(city), \(states[0].name)" }
        else if !areas.isEmpty { place = areas.map { Planning.areaLabel($0) }.joined(separator: "; ") }
        else { place = states.map(\.name).joined(separator: ", ") }
        if !clipFrom.isEmpty { place = "from \(clipFrom) to \(clipTo), \(place)" }
        return try finishOutput(layers, o, road: road, place: place, source: sourceUsed, output: output)
    }
}
