import Foundation
import ZIPFoundation

/// One row of a shapefile: its geometry (WGS84 lon/lat; nil for a null shape or a
/// .dbf-only table) and its attributes (blank values are "").
public struct ShapeRecord {
    public var geometry: Geometry?
    public var attrs: [String: String]
    public subscript(_ key: String) -> String? {
        let v = attrs[key]
        return (v?.isEmpty ?? true) ? nil : v
    }
}

/// A shapefile read into memory, with a spatial index (what geopandas.read_file gives).
public final class ShapeTable {
    public let columns: [String]
    public let records: [ShapeRecord]
    private var _tree: STRTree?

    public init(columns: [String], records: [ShapeRecord]) {
        self.columns = columns
        self.records = records
    }

    var tree: STRTree {
        if let t = _tree { return t }
        let t = STRTree(records.map { $0.geometry?.bounds ?? BBox(.infinity, .infinity, -.infinity, -.infinity) })
        _tree = t
        return t
    }

    /// Rows whose geometry intersects g, in row order (gdf[gdf.intersects(g)]).
    public func intersecting(_ g: Geometry) -> [Int] {
        tree.query(g).filter { records[$0].geometry.map { $0.intersects(g) } ?? false }
    }
}

public struct ShapefileError: Error, CustomStringConvertible {
    public let description: String
}

public enum Shapefile {
    /// _read_tiger_zip: the first file with extension `ext` (".shp" or ".dbf") in a zip.
    /// For .shp the matching .dbf is read too.
    public static func readZip(_ zip: Data, ext: String, geometry: Bool = true) throws -> ShapeTable? {
        let archive = try Archive(data: zip, accessMode: .read)
        var files: [String: Entry] = [:]
        for e in archive where e.type == .file {
            let name = e.path.split(separator: "/").last.map(String.init) ?? e.path
            if !e.path.contains("/") || e.path.hasSuffix("/" + name) { files[name] = files[name] ?? e }
        }
        func bytes(_ e: Entry) throws -> Data {
            var d = Data()
            _ = try archive.extract(e, skipCRC32: true) { d.append($0) }
            return d
        }
        let names = files.keys.filter { $0.lowercased().hasSuffix(ext) }.sorted()
        guard let first = names.first else { return nil }
        let stem = String(first.dropLast(ext.count))
        if ext == ".dbf" || !geometry {
            let dbfName = ext == ".dbf" ? first : files.keys.first { $0.lowercased() == stem.lowercased() + ".dbf" }
            guard let dbfName, let e = files[dbfName] else { return ShapeTable(columns: [], records: []) }
            let (cols, rows) = try readDBF(try bytes(e))
            return ShapeTable(columns: cols, records: rows.map { ShapeRecord(geometry: nil, attrs: $0) })
        }
        let shapes = try readSHP(try bytes(files[first]!))
        var cols: [String] = [], rows: [[String: String]] = []
        if let dbfName = files.keys.first(where: { $0.lowercased() == stem.lowercased() + ".dbf" }) {
            (cols, rows) = try readDBF(try bytes(files[dbfName]!))
        }
        var records: [ShapeRecord] = []
        for (i, g) in shapes.enumerated() {
            records.append(ShapeRecord(geometry: g, attrs: i < rows.count ? rows[i] : [:]))
        }
        return ShapeTable(columns: cols, records: records)
    }

    struct Reader {
        let d: [UInt8]
        func i32le(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24)) }
        func i32be(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(d[o + 3]) | UInt32(d[o + 2]) << 8 | UInt32(d[o + 1]) << 16 | UInt32(d[o]) << 24)) }
        func u16le(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func f64le(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(d[o + k]) << (8 * UInt64(k)) }
            return Double(bitPattern: bits)
        }
    }

    /// The shapes of a .shp file, in record order.
    static func readSHP(_ data: Data) throws -> [Geometry?] {
        let r = Reader(d: [UInt8](data))
        guard r.d.count >= 100, r.i32be(0) == 9994 else { throw ShapefileError(description: "not a shapefile") }
        var out: [Geometry?] = []
        var o = 100
        while o + 8 <= r.d.count {
            let len = r.i32be(o + 4) * 2
            let c = o + 8
            o = c + len
            guard len >= 4, o <= r.d.count else { break }
            let type = r.i32le(c)
            switch type {
            case 1, 11, 21:
                out.append(.point(r.f64le(c + 4), r.f64le(c + 12)))
            case 3, 13, 23, 5, 15, 25:
                let nParts = r.i32le(c + 36), nPoints = r.i32le(c + 40)
                var starts = (0..<nParts).map { r.i32le(c + 44 + 4 * $0) }
                starts.append(nPoints)
                let p0 = c + 44 + 4 * nParts
                let pts = (0..<nPoints).map { XY(r.f64le(p0 + 16 * $0), r.f64le(p0 + 16 * $0 + 8)) }
                var parts: [[XY]] = []
                for k in 0..<nParts where starts[k] < starts[k + 1] {
                    parts.append(Array(pts[starts[k]..<min(nPoints, starts[k + 1])]))
                }
                if type % 10 == 3 {
                    let lines = try parts.filter { $0.count >= 2 }.map { try Geometry.lineString($0) }
                    out.append(lines.isEmpty ? nil : lines.count == 1 ? lines[0] : .collection(lines, kind: .multiLineString))
                } else {
                    out.append(try polygons(from: parts))
                }
            default:
                out.append(nil)
            }
        }
        return out
    }

    static func signedArea(_ ring: [XY]) -> Double {
        var s = 0.0
        for (a, b) in zip(ring, ring.dropFirst()) { s += a.x * b.y - b.x * a.y }
        return s / 2
    }

    /// Shapefile rings -> polygons: clockwise rings are shells, counter-clockwise ones holes.
    static func polygons(from rings: [[XY]]) throws -> Geometry? {
        let usable = rings.filter { $0.count >= 4 }
        var shells: [[XY]] = [], holes: [[XY]] = []
        for r in usable { if signedArea(r) <= 0 { shells.append(r) } else { holes.append(r) } }
        if shells.isEmpty { shells = holes; holes = [] }
        let shellGeoms = try shells.map { try Geometry.polygon($0) }
        var assigned = Array(repeating: [[XY]](), count: shells.count)
        for h in holes {
            let p = Geometry.point(h[0])
            if let k = shellGeoms.firstIndex(where: { $0.contains(p) }) { assigned[k].append(h) }
        }
        let polys = try shells.indices.map { try Geometry.polygon(shells[$0], holes: assigned[$0]) }
        if polys.isEmpty { return nil }
        return polys.count == 1 ? polys[0] : .multiPolygon(polys)
    }

    /// A dBase III table: (column names, rows).
    static func readDBF(_ data: Data) throws -> ([String], [[String: String]]) {
        let r = Reader(d: [UInt8](data))
        guard r.d.count >= 32 else { throw ShapefileError(description: "not a dBase file") }
        let nRecords = r.i32le(4), headerLen = r.u16le(8), recLen = r.u16le(10)
        var fields: [(name: String, len: Int)] = []
        var o = 32
        while o + 32 <= r.d.count && r.d[o] != 0x0D && o < headerLen {
            let raw = r.d[o..<(o + 11)].prefix { $0 != 0 }
            fields.append((String(decoding: raw, as: UTF8.self), Int(r.d[o + 16])))
            o += 32
        }
        func text(_ b: ArraySlice<UInt8>) -> String {
            let s = String(bytes: b, encoding: .utf8) ?? String(bytes: b, encoding: .isoLatin1) ?? ""
            return s.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0")))
        }
        var rows: [[String: String]] = []
        for k in 0..<nRecords {
            let start = headerLen + k * recLen
            guard start + recLen <= r.d.count else { break }
            var row: [String: String] = [:]
            var p = start + 1
            for f in fields {
                row[f.name] = text(r.d[p..<(p + f.len)])
                p += f.len
            }
            rows.append(row)
        }
        return (fields.map(\.name), rows)
    }
}
