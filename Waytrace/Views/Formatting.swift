import Foundation
import CoreLocation

/// Display helpers. Speeds and distances follow the phone's region (mph/ft in the US);
/// accuracy stays in metres because the sampling rules are metric.
enum Fmt {
    static var imperial: Bool { Locale.current.measurementSystem == .us }

    static func coordinate(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    static func accuracy(_ metres: Double) -> String {
        metres < 0 ? "—" : String(format: "±%.0f m", metres)
    }

    static func speed(_ mps: Double) -> String {
        guard mps >= 0 else { return "—" }
        return imperial ? String(format: "%.1f mph", mps * 2.236936) : String(format: "%.1f km/h", mps * 3.6)
    }

    static func course(_ degrees: Double) -> String {
        guard degrees >= 0 else { return "—" }
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let name = names[Int((degrees + 22.5) / 45) % 8]
        return String(format: "%.0f° ", degrees) + name
    }

    static func altitude(_ metres: Double, accuracy: Double) -> String {
        guard accuracy >= 0 else { return "—" }
        return imperial ? String(format: "%.0f ft", metres * 3.28084) : String(format: "%.0f m", metres)
    }

    static func distance(_ metres: Double) -> String {
        if imperial {
            let miles = metres / 1609.344
            return miles >= 0.1 ? String(format: "%.2f mi", miles) : String(format: "%.0f ft", metres * 3.28084)
        }
        return metres >= 1000 ? String(format: "%.2f km", metres / 1000) : String(format: "%.0f m", metres)
    }

    static func fileSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A run of points with the same segment number, ready for MapPolyline.
struct TrackLine: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]

    static func lines(from points: [TrackPoint]) -> [TrackLine] {
        Geo.segments(points).enumerated().map { index, seg in
            TrackLine(id: index, coordinates: seg.map(\.coordinate))
        }
    }
}
