import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ends a run the way sys.exit() ends road_to_kml.py: code 1 for a failed run, 2 for bad options.
public struct ExitError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    public init(_ code: Int, _ message: String = "") { self.code = code; self.message = message }
    public var description: String { message.isEmpty ? "exit code \(code)" : message }
}

/// Raised when the user presses Cancel.
public struct CancelledError: Error {}

/// A run's printed output, line by line. Remembers the last error line, as run_batch's
/// _Tee does, and passes each line to `onLine` (the app's live log).
public final class RunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    public var onLine: ((String) -> Void)?
    public private(set) var lastError = ""

    public init(onLine: ((String) -> Void)? = nil) { self.onLine = onLine }

    public var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    public var text: String { lines.joined(separator: "\n") }

    /// print(): one call may hold several lines.
    public func callAsFunction(_ s: String = "") {
        let parts = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lock.lock()
        for p in parts {
            _lines.append(p)
            if p.contains("ERROR") || p.contains("error:") { lastError = Py.strip(p) }
        }
        let cb = onLine
        lock.unlock()
        if let cb { for p in parts { cb(p) } }
    }

    func resetLastError() { lock.lock(); lastError = ""; lock.unlock() }
}

/// Everything that reaches outside the phone. Each can be replaced, which is how the
/// tests run offline (the Python tests replace the same functions).
public struct Services {
    /// POST an Overpass QL query to `url`; the parsed reply.
    public var overpassPost: (_ url: String, _ query: String) throws -> OverpassReply
    /// One county TIGER/Line zip (layer ROADS or FEATNAMES); nil if that year/file doesn't exist.
    public var downloadTiger: (_ layer: String, _ fips: String, _ year: Int) throws -> Data?
    /// The Census Bureau's county outlines zip for a year; nil if not published.
    public var downloadCountyShapes: (_ year: Int) throws -> Data?
    public var stateAreaID: (_ state: String) throws -> Int64
    public var countyAreaID: (_ county: String, _ state: String) throws -> Int64
    public var cityAreaID: (_ city: String, _ state: String) throws -> Int64
    /// GET a URL (OSM API way/relation XML).
    public var fetchURL: (_ url: String) throws -> Data

    public static func live(http: HTTPClient) -> Services {
        Services(
            overpassPost: { url, query in try Overpass.post(http: http, url: url, query: query) },
            downloadTiger: { layer, fips, year in
                let url = "https://www2.census.gov/geo/tiger/TIGER\(year)/\(layer.uppercased())/tl_\(year)_\(fips)_\(layer.lowercased()).zip"
                return try http.download(url)
            },
            downloadCountyShapes: { year in
                try http.download("https://www2.census.gov/geo/tiger/GENZ\(year)/shp/cb_\(year)_us_county_5m.zip")
            },
            stateAreaID: { try Nominatim.stateAreaID($0, http: http) },
            countyAreaID: { try Nominatim.countyAreaID($0, $1, http: http) },
            cityAreaID: { try Nominatim.cityAreaID($0, $1, http: http) },
            fetchURL: { url in
                let r = try http.get(url, headers: ["Accept": "application/xml"], timeout: 60)
                guard r.status == 200 else { throw NetError.http(r.status, HTTPClient.reason(r.status)) }
                return r.data
            }
        )
    }
}

/// The road_to_kml engine. One instance holds the settings; each run (`main`) starts with
/// fresh per-run caches, like a new process of road_to_kml.py.
public final class RoadToKML: @unchecked Sendable {
    public var services: Services
    /// Where KML files are written (road_to_kml_ui.py runs the script in this folder).
    public var outputDirectory: URL
    /// OVERPASS_URL: one server to use instead of the built-in list.
    public var overpassURL = ""
    /// Where overpass_mirror_stats.txt is kept.
    public var mirrorStats: MirrorStats
    public var log: RunLog
    /// Pauses between retry rounds (seconds). Replaced in tests.
    public var sleeper: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Today's date, for TIGER/Line years and the county-table reminder.
    public var today: () -> Date = { Date() }
    /// Test hook: makes junction trimming fail with this message (like the Python tests'
    /// patched _query_tree).
    public var junctionTrimFault: String?
    /// Test hook: replaces road_tracks.group_trips.
    public var groupTripsOverride: (([Trip]) -> [[Trip]])?

    private let cancelLock = NSLock()
    private var _cancelled = false

    // per-run state (reset by main)
    var tigerYearFound: Int?
    var countyShapesCache: [ShapeRecord]?
    var tigerRoadsCache: [String: ShapeTable?] = [:]
    var fipsReminderShown = false
    /// The last surface written (WGS84) and its junction pins, for the app's map.
    public internal(set) var lastSurface: Geometry?
    public internal(set) var lastPins: [RoundJunction] = []
    /// Every KML written during the current run (a batch writes several).
    public internal(set) var outputs: [String] = []
    /// The trips read by the last --track run (for the app's map).
    public internal(set) var lastTrips: [Trip] = []

    public init(services: Services, outputDirectory: URL, mirrorStatsPath: URL, log: RunLog = RunLog()) {
        self.services = services
        self.outputDirectory = outputDirectory
        self.mirrorStats = MirrorStats(path: mirrorStatsPath)
        self.log = log
    }

    public var cancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return _cancelled
    }

    public func cancel() { cancelLock.lock(); _cancelled = true; cancelLock.unlock() }

    func checkCancel() throws { if cancelled { throw CancelledError() } }

    /// time.sleep that stops early when the run is cancelled.
    func pause(_ seconds: Double) throws {
        var left = seconds
        while left > 0 {
            try checkCancel()
            let step = min(left, 0.25)
            sleeper(step)
            left -= step
        }
        try checkCancel()
    }

    func resetRunState() {
        tigerYearFound = nil
        countyShapesCache = nil
        tigerRoadsCache = [:]
        fipsReminderShown = false
        _cancelledReset()
    }

    private func _cancelledReset() { cancelLock.lock(); _cancelled = false; cancelLock.unlock() }

    func outputURL(_ name: String) -> URL {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        return outputDirectory.appendingPathComponent(name)
    }

    var currentYear: Int { Calendar(identifier: .gregorian).component(.year, from: today()) }

    /// ERROR line + sys.exit(1)
    func fail(_ message: String, blankLine: Bool = false) -> ExitError {
        log((blankLine ? "\n" : "") + "ERROR: \(message)")
        return ExitError(1, message)
    }
}

// MARK: - HTTP

public enum NetError: Error, CustomStringConvertible {
    case http(Int, String)
    case timeout
    case connection(String)
    case unreadable(String)
    case other(String)

    public var description: String {
        switch self {
        case .http(let c, let r): return "HTTP \(c)" + (r.isEmpty ? "" : " \(r)")
        case .timeout: return "timed out"
        case .connection(let m): return "connection error: \(m)"
        case .unreadable(let m): return "unreadable reply: \(m)"
        case .other(let m): return m
        }
    }
}

public struct HTTPResponse {
    public var status: Int
    public var data: Data
}

/// Blocking HTTP on URLSession, for the engine's background thread. Stops waiting when
/// `isCancelled` turns true.
public final class HTTPClient: @unchecked Sendable {
    public var userAgent = "Waytrace-road_to_kml/1.0"
    public var isCancelled: () -> Bool = { false }
    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    /// Reason phrases as Python's http.HTTPStatus has them ("Gateway Timeout").
    public static func reason(_ code: Int) -> String {
        [400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
         406: "Not Acceptable", 408: "Request Timeout", 410: "Gone", 413: "Request Entity Too Large",
         429: "Too Many Requests", 500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
         503: "Service Unavailable", 504: "Gateway Timeout"][code] ?? ""
    }

    public func send(_ request: URLRequest) throws -> HTTPResponse {
        var req = request
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        final class Holder: @unchecked Sendable { var result: Result<HTTPResponse, Error> = .failure(NetError.other("no reply")) }
        let holder = Holder()
        let task = session.dataTask(with: req) { data, resp, err in
            if let err {
                let ns = err as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
                    holder.result = .failure(NetError.timeout)
                } else if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                    holder.result = .failure(CancelledError())
                } else if ns.domain == NSURLErrorDomain {
                    holder.result = .failure(NetError.connection(err.localizedDescription))
                } else {
                    holder.result = .failure(NetError.other(err.localizedDescription))
                }
            } else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                holder.result = .success(HTTPResponse(status: code, data: data ?? Data()))
            }
            sem.signal()
        }
        task.resume()
        while sem.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled() {
                task.cancel()
                sem.wait()
                throw CancelledError()
            }
        }
        return try holder.result.get()
    }

    public func get(_ url: String, query: [(String, String)] = [], headers: [String: String] = [:],
                    timeout: TimeInterval = 60) throws -> HTTPResponse {
        guard var comps = URLComponents(string: url) else { throw NetError.other("bad URL \(url)") }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let u = comps.url else { throw NetError.other("bad URL \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try send(req)
    }

    public func postForm(_ url: String, form: [String: String], headers: [String: String] = [:],
                         timeout: TimeInterval = 130) throws -> HTTPResponse {
        guard let u = URL(string: url) else { throw NetError.other("bad URL \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").data(using: .utf8)
        return try send(req)
    }

    /// GET a file; nil on 404 (a TIGER/Line year that isn't published yet).
    public func download(_ url: String) throws -> Data? {
        let r = try get(url, timeout: 180)
        if r.status == 404 { return nil }
        guard (200..<300).contains(r.status) else { throw NetError.http(r.status, HTTPClient.reason(r.status)) }
        return r.data
    }
}
