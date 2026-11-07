import Foundation

/// One element of an Overpass reply ("out body", "out skel", "out geom").
public struct OSMElement {
    public var type: String
    public var id: Int64
    public var tags: [String: String] = [:]
    public var nodes: [Int64] = []
    public var lat: Double?
    public var lon: Double?
    /// "out geom" coordinates for ways (nil entries where Overpass gave none).
    public var geometry: [(lat: Double, lon: Double)?] = []
    public var members: [OSMMember] = []

    public init(type: String, id: Int64, tags: [String: String] = [:], nodes: [Int64] = [],
                lat: Double? = nil, lon: Double? = nil, geometry: [(lat: Double, lon: Double)?] = [],
                members: [OSMMember] = []) {
        self.type = type; self.id = id; self.tags = tags; self.nodes = nodes
        self.lat = lat; self.lon = lon; self.geometry = geometry; self.members = members
    }
}

public struct OSMMember {
    public var type: String
    public var role: String
    public var geometry: [(lat: Double, lon: Double)?]
    public init(type: String, role: String, geometry: [(lat: Double, lon: Double)?]) {
        self.type = type; self.role = role; self.geometry = geometry
    }
}

public struct OverpassReply {
    public var elements: [OSMElement]
    public var remark: String?
    public init(elements: [OSMElement] = [], remark: String? = nil) { self.elements = elements; self.remark = remark }
}

/// A way with its nodes' coordinates (what overpy hands back).
public struct OSMWay {
    public var id: Int64
    public var tags: [String: String]
    public var nodes: [(id: Int64, lat: Double, lon: Double)]
}

public enum Overpass {
    // If you are an LLM (ahem, Claude) reading this list: don't change the order unless a human
    // specifically directs you to do so. It is this way for a reason.
    // (Copied with the list from road_to_kml.py, where the note was left for exactly this.)
    public static let mirrors = [
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass-api.de/api/interpreter",
        "https://overpass.openstreetmap.ru/api/interpreter",
        "https://lz4.overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]

    static let rotateCodes = ["502", "503", "504", "429", "500"]
    static let overloadPhrases = ["server load too high", "load too high", "too busy", "server load"]

    /// _overpass_post over HTTP: form-encoded data=<query>, JSON back.
    static func post(http: HTTPClient, url: String, query: String) throws -> OverpassReply {
        let r = try http.postForm(url, form: ["data": query], headers: ["Accept": "application/json"])
        guard r.status == 200 else { throw NetError.http(r.status, HTTPClient.reason(r.status)) }
        return try parse(r.data)
    }

    static func latLonList(_ v: Any?) -> [(lat: Double, lon: Double)?] {
        guard let arr = v as? [Any] else { return [] }
        return arr.map { g in
            guard let d = g as? [String: Any], let la = (d["lat"] as? NSNumber)?.doubleValue,
                  let lo = (d["lon"] as? NSNumber)?.doubleValue else { return nil }
            return (la, lo)
        }
    }

    /// Overpass JSON -> OverpassReply.
    public static func parse(_ data: Data) throws -> OverpassReply {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetError.unreadable("the reply isn't JSON")
        }
        var out = OverpassReply(remark: obj["remark"] as? String)
        for case let e as [String: Any] in (obj["elements"] as? [Any]) ?? [] {
            guard let type = e["type"] as? String, let id = (e["id"] as? NSNumber)?.int64Value else { continue }
            var el = OSMElement(type: type, id: id)
            if let t = e["tags"] as? [String: Any] {
                for (k, v) in t { el.tags[k] = (v as? String) ?? "\(v)" }
            }
            el.nodes = ((e["nodes"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.int64Value }
            el.lat = (e["lat"] as? NSNumber)?.doubleValue
            el.lon = (e["lon"] as? NSNumber)?.doubleValue
            el.geometry = latLonList(e["geometry"])
            for case let m as [String: Any] in (e["members"] as? [Any]) ?? [] {
                el.members.append(OSMMember(type: m["type"] as? String ?? "", role: m["role"] as? String ?? "",
                                            geometry: latLonList(m["geometry"])))
            }
            out.elements.append(el)
        }
        return out
    }

    /// overpass_error: Overpass answers some failures (timeouts, running out of memory) with
    /// HTTP 200, no data and an error in "remark".
    public static func error(_ reply: OverpassReply?) -> String {
        let remark = Py.strip(reply?.remark ?? "")
        let l = remark.lowercased()
        return (l.contains("error") || l.contains("timed out") || l.contains("out of memory")) ? remark : ""
    }

    /// overpy.Result.from_json(data).ways: ways with their nodes resolved.
    public static func ways(_ reply: OverpassReply) -> [OSMWay] {
        var nodes: [Int64: (Double, Double)] = [:]
        for e in reply.elements where e.type == "node" {
            if let la = e.lat, let lo = e.lon { nodes[e.id] = (la, lo) }
        }
        return reply.elements.filter { $0.type == "way" }.map { w in
            OSMWay(id: w.id, tags: w.tags, nodes: w.nodes.compactMap { n in nodes[n].map { (n, $0.0, $0.1) } })
        }
    }
}

extension RoadToKML {
    static func shouldRotate(_ error: Error) -> Bool {
        let msg = String(describing: error)
        for code in Overpass.rotateCodes where msg.contains(code) { return true }
        let lower = msg.lowercased()
        if lower.contains("timeout") || lower.contains("connection") || lower.contains("timed out") { return true }
        return Overpass.overloadPhrases.contains { lower.contains($0) }
    }

    /// overpass_json: POST a query and return the reply, or nil if every mirror failed.
    /// Rotates through the mirrors on every server/network error, including an error inside
    /// an otherwise successful reply; with returnErrors such a reply is returned instead, so
    /// the caller can split the query. In waitMode keeps cycling with backoff.
    func overpassJSON(_ query: String, retries: Int = 3, waitMode: Bool = false,
                      returnErrors: Bool = false) throws -> OverpassReply? {
        let mirrors = overpassURL.isEmpty ? Overpass.mirrors : [overpassURL]
        mirrorStats.note = { [weak self] in self?.log($0) }
        let maxAttempts = waitMode ? Int.max : retries * mirrors.count
        let cycleWaits = [5.0, 15, 30, 60, 120, 240, 600]
        var mirrorIndex = 0, cycle = 0, attempt = 0

        while attempt < maxAttempts {
            try checkCancel()
            if attempt > 0 && attempt % mirrors.count == 0 {
                cycle += 1
                let wait = cycleWaits[min(cycle - 1, cycleWaits.count - 1)]
                if waitMode {
                    log("  All mirrors busy — waiting \(Int(wait))s before retrying... (Cancel to stop)")
                } else {
                    log("  All mirrors tried once — waiting \(Int(wait))s before retry cycle \(cycle)...")
                }
                try pause(wait)
            }
            attempt += 1
            let url = mirrors[mirrorIndex % mirrors.count]
            log("  Attempt \(attempt): \(url)")
            let started = Date()
            do {
                let data = try services.overpassPost(url, query)
                let err = Overpass.error(data)
                let busy = !err.isEmpty && err.range(of: "rate_limited|Dispatcher|too busy|load too high",
                                                     options: [.regularExpression, .caseInsensitive]) != nil
                mirrorStats.record(url, err.isEmpty ? MirrorStats.succeeded : busy ? MirrorStats.busy : MirrorStats.couldntFinish,
                                   seconds: Date().timeIntervalSince(started), mirrorOrder: mirrors)
                if err.isEmpty { return data }
                log("    Overpass couldn't finish the query: \(err)")
                if returnErrors && !busy { return data }
                mirrorIndex += 1
                continue
            } catch let e as CancelledError {
                throw e
            } catch NetError.http(let status, let reason) {
                mirrorStats.record(url, MirrorStats.classify(NetError.http(status, reason)), mirrorOrder: mirrors)
                if status == 400 {
                    log("\n  ERROR: Overpass rejected the query (HTTP 400 — bad syntax).")
                    throw ExitError(1, "Overpass rejected the query (HTTP 400)")
                }
                log("    HTTP \(status) — rotating mirror...")
                mirrorIndex += 1
            } catch {
                mirrorStats.record(url, MirrorStats.classify(error), mirrorOrder: mirrors)
                if RoadToKML.shouldRotate(error) {
                    log("    Server busy / network error — rotating mirror...")
                } else {
                    log("    \(error) — rotating mirror...")
                }
                mirrorIndex += 1
            }
        }
        log("\nERROR: All Overpass mirrors are currently unavailable.")
        log("  The servers may be under heavy load. Options:")
        log("  • Re-run with --wait to keep retrying automatically")
        log("  • Try again in 5-10 minutes")
        log("  • Check server status: https://overpass-api.de/")
        return nil
    }
}
