import Foundation

/// A junction whose fill couldn't be trimmed: a pin in the KML.
public struct RoundJunction: Sendable {
    public let lon: Double, lat: Double, reason: String
}

extension RoadToKML {
    /// _dissolve: union the buffered segments and simplify slightly.
    func dissolve(_ buffered: [Geometry]) throws -> Geometry {
        log("  Buffered \(buffered.count) segment(s), dissolving...")
        return try Geometry.unaryUnion(buffered).simplify(0.5)
    }

    /// build_combined_polygon: buffer and dissolve layers from several sources, counties,
    /// states and trips. Lines sharing a UTM zone are buffered together in that zone;
    /// different zones are merged in WGS84. Returns the WGS84 surface and the junctions left round.
    func buildCombinedPolygon(_ layers: [Layer], extraLanes: Int = 0, leftWidth: Double? = nil,
                              rightWidth: Double? = nil) throws -> (Geometry, [RoundJunction]) {
        var keys: [CRS] = []
        var lines: [CRS: [TaggedLine]] = [:], polys: [CRS: [Geometry]] = [:], discs: [CRS: [Geometry]] = [:]
        for layer in layers {
            if lines[layer.crs] == nil { keys.append(layer.crs); lines[layer.crs] = [] }
            lines[layer.crs]! += layer.lines
            polys[layer.crs, default: []] += layer.polys
            discs[layer.crs, default: []] += layer.junctions
        }
        keys.sort { $0.description < $1.description }
        var pieces: [Geometry] = [], pins: [RoundJunction] = []
        var nTrimmed = 0, nKept = 0
        for crs in keys {
            let ls = lines[crs] ?? []
            if keys.count > 1 { log("  \(crs): \(ls.count) segment(s)") }
            var parts: [Geometry] = []
            let buffered = ls.isEmpty ? [] : try RoadGeom.bufferLines(ls, extraLanes: extraLanes, leftWidth: leftWidth,
                                                                       rightWidth: rightWidth)
            if !buffered.isEmpty { parts.append(try dissolve(buffered)) }
            var extra = polys[crs] ?? []
            if let d = discs[crs], !d.isEmpty {
                let r = RoadGeom.trimJunctionFill(d, buffered + extra, fault: junctionTrimFault)
                for p in r.left {
                    let ll = crs.toWGS84(XY(p.x, p.y))
                    pins.append(RoundJunction(lon: ll.x, lat: ll.y, reason: p.reason))
                }
                nTrimmed += r.trimmed
                nKept += r.kept
                extra += r.fills
            }
            if !extra.isEmpty { parts.append(try Geometry.unaryUnion(extra).simplify(0.2)) }
            guard !parts.isEmpty else { continue }
            var projected = try Geometry.unaryUnion(parts)
            if projected.isEmpty { continue }
            if projected.kind != .polygon && projected.kind != .multiPolygon {
                projected = Geometry.multiPolygon(RoadGeom.polygonParts(projected))
            }
            pieces.append(try reproject(projected, from: crs, to: .wgs84))
        }
        if nTrimmed > 0 || nKept > 0 {
            var msg = "  Intersection fill trimmed to the roads at \(nTrimmed) junction(s)"
            msg += nKept > 0 ? "; \(nKept) left round (nothing to trim to, or the trim failed), each marked with a pin in the KML." : "."
            log(msg)
        }
        if pieces.isEmpty { throw fail("No valid geometries to buffer.") }
        var merged = pieces.count == 1 ? pieces[0] : try Geometry.unaryUnion(pieces)
        if merged.kind != .polygon && merged.kind != .multiPolygon {
            merged = Geometry.multiPolygon(RoadGeom.polygonParts(merged))
        }
        return (merged, pins)
    }

    // MARK: - KML

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func kmlCoords(_ ring: [XY]) -> String {
        ring.map { "\($0.x),\($0.y),0" }.joined(separator: " ")
    }

    /// write_kml: the surface as simplekml writes it (gray fill, black outline, clamped to
    /// the ground), with a folder of pins for junctions left round.
    func writeKML(_ geometry: Geometry, road: String, place: String, output: String, source: String = "",
                  notes: String = "", pins: [RoundJunction] = []) throws {
        var description = place.isEmpty ? road : "\(road), \(place)"
        if !source.isEmpty { description += "\nSource: \(source)" }
        if !notes.isEmpty { description += "\nNotes: \(notes)" }
        let e = RoadToKML.xmlEscape
        var id = 0
        func next() -> Int { id += 1; return id }
        let docID = next(), styleID = next(), polyStyleID = next(), lineStyleID = next()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2">
            <Document id="\(docID)">
                <name>\(e("Road surface: \(road)"))</name>
                <description>\(e(description))</description>
                <Style id="\(styleID)">
                    <LineStyle id="\(lineStyleID)">
                        <color>ff000000</color>
                        <colorMode>normal</colorMode>
                        <width>1.5</width>
                    </LineStyle>
                    <PolyStyle id="\(polyStyleID)">
                        <color>a0808080</color>
                        <colorMode>normal</colorMode>
                        <fill>1</fill>
                        <outline>1</outline>
                    </PolyStyle>
                </Style>

        """
        func addPolygon(_ poly: Geometry, _ name: String) {
            let r = poly.rings
            let pm = next(), pg = next()
            out += "        <Placemark id=\"\(pm)\">\n            <name>\(e(name))</name>\n"
            out += "            <styleUrl>#\(styleID)</styleUrl>\n            <Polygon id=\"\(pg)\">\n"
            out += "                <altitudeMode>clampToGround</altitudeMode>\n"
            out += "                <outerBoundaryIs>\n                    <LinearRing id=\"\(next())\">\n"
            out += "                        <coordinates>\(RoadToKML.kmlCoords(r.exterior))</coordinates>\n"
            out += "                    </LinearRing>\n                </outerBoundaryIs>\n"
            for hole in r.interiors {
                out += "                <innerBoundaryIs>\n                    <LinearRing id=\"\(next())\">\n"
                out += "                        <coordinates>\(RoadToKML.kmlCoords(hole))</coordinates>\n"
                out += "                    </LinearRing>\n                </innerBoundaryIs>\n"
            }
            out += "            </Polygon>\n        </Placemark>\n"
        }
        switch geometry.kind {
        case .polygon: addPolygon(geometry, road)
        case .multiPolygon:
            for (i, p) in geometry.parts.enumerated() { addPolygon(p, "\(road) (part \(i + 1))") }
        default:
            throw GeometryError(message: "Cannot write geometry type: \(geometry.typeName)")
        }
        if !pins.isEmpty {
            let folderID = next(), pinStyle = next()
            out += "        <Style id=\"\(pinStyle)\">\n            <IconStyle id=\"\(next())\">\n"
            out += "                <colorMode>normal</colorMode>\n                <scale>0.9</scale>\n"
            out += "                <Icon id=\"\(next())\">\n"
            out += "                    <href>http://maps.google.com/mapfiles/kml/pushpin/red-pushpin.png</href>\n"
            out += "                </Icon>\n            </IconStyle>\n        </Style>\n"
            out += "        <Folder id=\"\(folderID)\">\n            <name>Junctions left round (\(pins.count))</name>\n"
            out += "            <description>Intersection fill that couldn't be trimmed to the roads, so the full circle was kept. Each pin is at the circle's center.</description>\n"
            for (i, p) in pins.enumerated() {
                let desc = "\(p.reason)\nCenter: \(PyFmt.f(p.lat, 7)), \(PyFmt.f(p.lon, 7))"
                out += "            <Placemark id=\"\(next())\">\n                <name>Junction left round \(i + 1)</name>\n"
                out += "                <description>\(e(desc))</description>\n"
                out += "                <styleUrl>#\(pinStyle)</styleUrl>\n"
                out += "                <Point id=\"\(next())\">\n                    <altitudeMode>clampToGround</altitudeMode>\n"
                out += "                    <coordinates>\(p.lon),\(p.lat),0</coordinates>\n"
                out += "                </Point>\n            </Placemark>\n"
            }
            out += "        </Folder>\n"
        }
        out += "    </Document>\n</kml>\n"
        try Data(out.utf8).write(to: outputURL(output), options: .atomic)
        log("  Saved: \(output)")
    }

    /// strip_inner_boundaries: remove every <innerBoundaryIs> block, in place.
    @discardableResult
    func stripInnerBoundaries(_ output: String) throws -> Int {
        let url = outputURL(output)
        let text = try String(contentsOf: url, encoding: .utf8)
        let re = Re.compile("\\s*<innerBoundaryIs>.*?</innerBoundaryIs>", [.dotMatchesLineSeparators, .caseInsensitive])
        let count = re.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        if count > 0 {
            try Data(Re.sub(re, "", text).utf8).write(to: url, options: .atomic)
            log("  Stripped \(count) <innerBoundaryIs> block(s) from \(output)")
        } else {
            log("  No <innerBoundaryIs> blocks found in \(output)")
        }
        return count
    }

    func summarize(_ geometry: Geometry, _ road: String) {
        let n = geometry.kind == .polygon ? 1 : geometry.partCount
        log("\n  Road: \(road)")
        log("  Polygons: \(n)")
        if let b = geometry.bounds {
            log("  Bounding box (lon/lat): \(PyFmt.f(b.minX, 5)),\(PyFmt.f(b.minY, 5)) → \(PyFmt.f(b.maxX, 5)),\(PyFmt.f(b.maxY, 5))")
        }
    }

    /// _finish_output: buffer, write the KML, summarize.
    func finishOutput(_ layers: [Layer], _ opts: Options, road: String, place: String, source: String,
                      output: String) throws -> String {
        let (surface, pins) = try buildCombinedPolygon(layers, extraLanes: opts.lanes, leftWidth: opts.leftWidth,
                                                       rightWidth: opts.rightWidth)
        try writeKML(surface, road: road, place: place, output: output, source: source, notes: opts.notes, pins: pins)
        if opts.stripInner { try stripInnerBoundaries(output) }
        summarize(surface, road)
        log("\nDone. Open \(output) in Google Earth or any KML viewer.\n")
        lastSurface = surface
        lastPins = pins
        outputs.append(output)
        return output
    }
}
