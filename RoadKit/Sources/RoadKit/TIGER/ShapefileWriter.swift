import Foundation
import ZIPFoundation

/// Writes small shapefiles into a zip (lines or polygons plus a dBase table). The tests
/// use it to build fake TIGER/Line and county downloads; the app can use it to share a
/// surface as a shapefile.
public enum ShapefileWriter {
    struct Bytes {
        var d: [UInt8] = []
        mutating func i32be(_ v: Int) { let u = UInt32(bitPattern: Int32(v)); d += [UInt8(u >> 24 & 255), UInt8(u >> 16 & 255), UInt8(u >> 8 & 255), UInt8(u & 255)] }
        mutating func i32le(_ v: Int) { let u = UInt32(bitPattern: Int32(v)); d += [UInt8(u & 255), UInt8(u >> 8 & 255), UInt8(u >> 16 & 255), UInt8(u >> 24 & 255)] }
        mutating func u16le(_ v: Int) { d += [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        mutating func f64le(_ v: Double) { let b = v.bitPattern; for k in 0..<8 { d.append(UInt8(b >> (8 * UInt64(k)) & 255)) } }
    }

    static func header(_ b: inout Bytes, type: Int, fileWords: Int, box: BBox) {
        b.i32be(9994)
        for _ in 0..<5 { b.i32be(0) }
        b.i32be(fileWords)
        b.i32le(1000)
        b.i32le(type)
        b.f64le(box.minX); b.f64le(box.minY); b.f64le(box.maxX); b.f64le(box.maxY)
        for _ in 0..<4 { b.f64le(0) }
    }

    /// .shp and .shx for line (type 3) or polygon (type 5) shapes; nil = null shape.
    static func shp(_ shapes: [Geometry?], polygon: Bool) -> (Data, Data) {
        let type = polygon ? 5 : 3
        var records: [[UInt8]] = []
        var all = BBox(.infinity, .infinity, -.infinity, -.infinity)
        for g in shapes {
            var c = Bytes()
            guard let g, !g.isEmpty else { c.i32le(0); records.append(c.d); continue }
            var parts: [[XY]] = []
            if polygon {
                for p in g.polygonParts {
                    let r = p.rings
                    var shell = r.exterior
                    if Shapefile.signedArea(shell) > 0 { shell.reverse() }          // shells clockwise
                    parts.append(shell)
                    for h in r.interiors { parts.append(Shapefile.signedArea(h) < 0 ? h.reversed() : h) }
                }
            } else {
                parts = g.lineParts.map(\.coords)
            }
            let pts = parts.flatMap { $0 }
            let box = BBox(points: pts)
            all = all.union(box)
            c.i32le(type)
            c.f64le(box.minX); c.f64le(box.minY); c.f64le(box.maxX); c.f64le(box.maxY)
            c.i32le(parts.count); c.i32le(pts.count)
            var start = 0
            for p in parts { c.i32le(start); start += p.count }
            for p in pts { c.f64le(p.x); c.f64le(p.y) }
            records.append(c.d)
        }
        if all.minX == .infinity { all = BBox(0, 0, 0, 0) }
        var shp = Bytes(), shx = Bytes()
        let total = 100 + records.reduce(0) { $0 + 8 + $1.count }
        header(&shp, type: type, fileWords: total / 2, box: all)
        header(&shx, type: type, fileWords: (100 + 8 * records.count) / 2, box: all)
        var offset = 100
        for (i, r) in records.enumerated() {
            shx.i32be(offset / 2); shx.i32be(r.count / 2)
            shp.i32be(i + 1); shp.i32be(r.count / 2)
            shp.d += r
            offset += 8 + r.count
        }
        return (Data(shp.d), Data(shx.d))
    }

    /// A dBase III table of text columns.
    static func dbf(columns: [String], rows: [[String: String]]) -> Data {
        let widths = columns.map { c in max(1, rows.map { ($0[c] ?? "").utf8.count }.max() ?? 1) }
        var b = Bytes()
        b.d.append(0x03)
        b.d += [126, 1, 1]
        b.i32le(rows.count)
        b.u16le(32 + 32 * columns.count + 1)
        b.u16le(1 + widths.reduce(0, +))
        b.d += [UInt8](repeating: 0, count: 20)
        for (c, w) in Swift.zip(columns, widths) {
            var name = Array(c.utf8.prefix(10))
            name += [UInt8](repeating: 0, count: 11 - name.count)
            b.d += name
            b.d.append(UInt8(ascii: "C"))
            b.d += [0, 0, 0, 0]
            b.d.append(UInt8(w))
            b.d.append(0)
            b.d += [UInt8](repeating: 0, count: 14)
        }
        b.d.append(0x0D)
        for r in rows {
            b.d.append(0x20)
            for (c, w) in Swift.zip(columns, widths) {
                var v = Array((r[c] ?? "").utf8.prefix(w))
                v += [UInt8](repeating: 0x20, count: w - v.count)
                b.d += v
            }
        }
        b.d.append(0x1A)
        return Data(b.d)
    }

    static func zip(_ files: [(String, Data)]) throws -> Data {
        let archive = try Archive(data: Data(), accessMode: .create)
        for (name, data) in files {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<(Int(pos) + size))
            }
        }
        return archive.data ?? Data()
    }

    /// A zipped shapefile: <stem>.shp/.shx/.dbf/.prj/.cpg (or only the .dbf when
    /// `geometry` is false, like a TIGER/Line feature-names file).
    public static func zipped(stem: String, columns: [String], rows: [[String: String]], shapes: [Geometry?],
                              polygon: Bool = false, geometry: Bool = true) throws -> Data {
        var files: [(String, Data)] = [("\(stem).dbf", dbf(columns: columns, rows: rows)), ("\(stem).cpg", Data("UTF-8".utf8))]
        if geometry {
            let (shp, shx) = shp(shapes, polygon: polygon)
            files += [("\(stem).shp", shp), ("\(stem).shx", shx),
                      ("\(stem).prj", Data("GEOGCS[\"GCS_North_American_1983\",DATUM[\"D_North_American_1983\",SPHEROID[\"GRS_1980\",6378137.0,298.257222101]],PRIMEM[\"Greenwich\",0.0],UNIT[\"Degree\",0.0174532925199433]]".utf8))]
        }
        return try zip(files)
    }
}
