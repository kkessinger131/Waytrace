import Foundation

/// get_state_area_id / get_city_area_id / get_county_area_id: the OSM relation for a place,
/// as an Overpass area ID (relation id + 3600000000).
enum Nominatim {
    struct NotFound: Error, CustomStringConvertible { let description: String }

    static func search(_ q: String, extra: [(String, String)] = [], http: HTTPClient) throws -> [[String: Any]] {
        let r = try http.get("https://nominatim.openstreetmap.org/search",
                             query: [("q", q), ("format", "jsonv2"), ("limit", "20")] + extra, timeout: 30)
        guard (200..<300).contains(r.status) else { throw NetError.http(r.status, HTTPClient.reason(r.status)) }
        guard let arr = try? JSONSerialization.jsonObject(with: r.data) as? [[String: Any]] else {
            throw NetError.unreadable("Nominatim reply isn't JSON")
        }
        return arr
    }

    static func osmID(_ item: [String: Any]) -> Int64? {
        if let n = item["osm_id"] as? NSNumber { return n.int64Value }
        if let s = item["osm_id"] as? String { return Int64(s) }
        return nil
    }

    static func stateAreaID(_ state: String, http: HTTPClient) throws -> Int64 {
        // State-level results first, so "New York" gives the state rather than the city.
        for (attempt, extra) in [[("featureType", "state")], []].enumerated() {
            if attempt > 0 { Thread.sleep(forTimeInterval: 1) }   // Nominatim: at most 1 request a second
            let relations = try search("\(state), USA", extra: extra, http: http)
                .filter { ($0["osm_type"] as? String) == "relation" }
            for item in relations where (item["addresstype"] as? String) == "state" {
                if let id = osmID(item) { return id + 3_600_000_000 }
            }
            for item in relations where ((item["display_name"] as? String) ?? "").lowercased().contains("state") {
                if let id = osmID(item) { return id + 3_600_000_000 }
            }
        }
        throw NotFound(description: "State not found: \(state)")
    }

    static func cityAreaID(_ city: String, _ state: String, http: HTTPClient) throws -> Int64 {
        let q = "\(city), \(state), USA"
        let results = try search(q, http: http)
        if results.isEmpty { throw NotFound(description: "City not found: \(q)") }
        for item in results where (item["osm_type"] as? String) == "relation" {
            if let id = osmID(item) { return id + 3_600_000_000 }
        }
        throw NotFound(description: "No administrative relation found for \(q)")
    }

    static func countyAreaID(_ county: String, _ state: String, http: HTTPClient) throws -> Int64 {
        for item in try search("\(county), \(state), USA", http: http) where (item["osm_type"] as? String) == "relation" {
            if let id = osmID(item) { return id + 3_600_000_000 }
        }
        throw NotFound(description: "County not found: \(county), \(state)")
    }
}
