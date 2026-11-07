import Foundation

/// UTM north zones on WGS84 (EPSG:32601-32660), the only projections road_to_kml uses.
/// Krüger's series to sixth order (Karney 2011), the same method PROJ uses for UTM, so
/// results agree with pyproj to well under a millimetre.
public struct UTM: Hashable, Sendable, CustomStringConvertible {
    public let zone: Int

    public init(zone: Int) { self.zone = max(1, min(60, zone)) }

    /// road_to_kml._utm_for_lons / road_tracks.utm_epsg: the zone of the mean longitude.
    public init(longitudes lons: [Double]) {
        let mean = lons.isEmpty ? 0 : lons.reduce(0, +) / Double(lons.count)
        self.init(zone: Int((mean + 180) / 6) + 1)
    }

    /// "EPSG:32618"
    public var epsg: String { "EPSG:\(32600 + zone)" }
    public var description: String { epsg }

    private var lon0: Double { Double(zone * 6 - 183) * .pi / 180 }

    // WGS84 and UTM constants
    private static let a = 6_378_137.0
    private static let f = 1 / 298.257223563
    private static let k0 = 0.9996
    private static let falseEasting = 500_000.0
    private static let n = f / (2 - f)
    private static let e = sqrt(f * (2 - f))
    private static let A: Double = {
        let n2 = n * n
        return a / (1 + n) * (1 + n2 / 4 + n2 * n2 / 64 + n2 * n2 * n2 / 256)
    }()
    private static let alpha: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - 2 * n2 / 3 + 5 * n3 / 16 + 41 * n4 / 180 - 127 * n5 / 288 + 7891 * n6 / 37800,
            13 * n2 / 48 - 3 * n3 / 5 + 557 * n4 / 1440 + 281 * n5 / 630 - 1983433 * n6 / 1935360,
            61 * n3 / 240 - 103 * n4 / 140 + 15061 * n5 / 26880 + 167603 * n6 / 181440,
            49561 * n4 / 161280 - 179 * n5 / 168 + 6601661 * n6 / 7257600,
            34729 * n5 / 80640 - 3418889 * n6 / 1995840,
            212378941 * n6 / 319334400,
        ]
    }()
    private static let beta: [Double] = {
        let n2 = n * n, n3 = n2 * n, n4 = n3 * n, n5 = n4 * n, n6 = n5 * n
        return [
            n / 2 - 2 * n2 / 3 + 37 * n3 / 96 - n4 / 360 - 81 * n5 / 512 + 96199 * n6 / 604800,
            n2 / 48 + n3 / 15 - 437 * n4 / 1440 + 46 * n5 / 105 - 1118711 * n6 / 3870720,
            17 * n3 / 480 - 37 * n4 / 840 - 209 * n5 / 4480 + 5569 * n6 / 90720,
            4397 * n4 / 161280 - 11 * n5 / 504 - 830251 * n6 / 7257600,
            4583 * n5 / 161280 - 108847 * n6 / 3991680,
            20648693 * n6 / 638668800,
        ]
    }()

    /// (lon, lat) degrees -> (x, y) metres.
    public func forward(lon: Double, lat: Double) -> XY {
        let phi = lat * .pi / 180
        let lam = lon * .pi / 180 - lon0
        let e = UTM.e
        let s = sin(phi)
        let t = sinh(atanh(s) - e * atanh(e * s))
        let xiP = atan2(t, cos(lam))
        let etaP = atanh(sin(lam) / sqrt(1 + t * t))
        var xi = xiP, eta = etaP
        for j in 1...6 {
            let a = UTM.alpha[j - 1], jj = 2 * Double(j)
            xi += a * sin(jj * xiP) * cosh(jj * etaP)
            eta += a * cos(jj * xiP) * sinh(jj * etaP)
        }
        return XY(UTM.falseEasting + UTM.k0 * UTM.A * eta, UTM.k0 * UTM.A * xi)
    }

    public func forward(_ p: XY) -> XY { forward(lon: p.x, lat: p.y) }

    /// (x, y) metres -> (lon, lat) degrees.
    public func inverse(_ p: XY) -> XY {
        let xi = p.y / (UTM.k0 * UTM.A)
        let eta = (p.x - UTM.falseEasting) / (UTM.k0 * UTM.A)
        var xiP = xi, etaP = eta
        for j in 1...6 {
            let b = UTM.beta[j - 1], jj = 2 * Double(j)
            xiP -= b * sin(jj * xi) * cosh(jj * eta)
            etaP -= b * cos(jj * xi) * sinh(jj * eta)
        }
        let tauP = sin(xiP) / sqrt(sinh(etaP) * sinh(etaP) + cos(xiP) * cos(xiP))
        let lam = atan2(sinh(etaP), cos(xiP))
        let e = UTM.e, e2 = e * e
        var tau = tauP
        for _ in 0..<8 {
            let sig = sinh(e * atanh(e * tau / sqrt(1 + tau * tau)))
            let tauI = tau * sqrt(1 + sig * sig) - sig * sqrt(1 + tau * tau)
            let d = (tauP - tauI) / sqrt(1 + tauI * tauI) * (1 + (1 - e2) * tau * tau)
                / ((1 - e2) * sqrt(1 + tau * tau))
            tau += d
            if abs(d) < 1e-14 { break }
        }
        return XY((lam + lon0) * 180 / .pi, atan(tau) * 180 / .pi)
    }
}

/// A coordinate system a geometry can be in: WGS84 degrees or a UTM zone.
public enum CRS: Hashable, Sendable, CustomStringConvertible {
    case wgs84
    case utm(UTM)

    public var description: String {
        switch self {
        case .wgs84: return "EPSG:4326"
        case .utm(let u): return u.epsg
        }
    }

    func toWGS84(_ p: XY) -> XY {
        switch self {
        case .wgs84: return p
        case .utm(let u): return u.inverse(p)
        }
    }

    func fromWGS84(_ p: XY) -> XY {
        switch self {
        case .wgs84: return p
        case .utm(let u): return u.forward(p)
        }
    }
}

/// road_to_kml._reproject
public func reproject(_ g: Geometry, from src: CRS, to dst: CRS) throws -> Geometry {
    if src == dst || g.isEmpty { return g }
    return try g.mapCoords { dst.fromWGS84(src.toWGS84($0)) }
}
