import Foundation
import Combine
import MapKit
import RoadKit
import UIKit

/// One line of a run's log, colored the way road_to_kml_ui.html colors it.
struct LogLine: Identifiable, Hashable {
    enum Kind { case plain, error, warning, ok, heading }
    let id: Int
    let text: String
    let kind: Kind

    static func classify(_ line: String) -> Kind {
        if line.contains("ERROR") || line.contains("error:") || line.contains("FAILED") { return .error }
        if line.contains("WARNING") || line.contains("Note:") || line.contains("Reminder:") { return .warning }
        if line.contains("Saved:") || line.hasPrefix("Done.") || line.range(of: "\\bOK\\b", options: .regularExpression) != nil { return .ok }
        if line.range(of: "^\\s*(=+|-{3}|#{4})", options: .regularExpression) != nil || line.contains("Road to KML") { return .heading }
        return .plain
    }
}

/// A road surface ready for MapKit: polygons (with holes) and pins for junctions left round.
struct MapSurface: Sendable {
    struct Polygon: Sendable { let exterior: [CLLocationCoordinate2D]; let holes: [[CLLocationCoordinate2D]] }
    struct Pin: Identifiable, Sendable { let id: Int; let coordinate: CLLocationCoordinate2D; let title: String; let detail: String }
    var polygons: [Polygon] = []
    var pins: [Pin] = []
    var description = ""

    var isEmpty: Bool { polygons.isEmpty && pins.isEmpty }

    var mkPolygons: [MKPolygon] {
        polygons.map { p in
            let holes = p.holes.map { MKPolygon(coordinates: $0, count: $0.count) }
            return MKPolygon(coordinates: p.exterior, count: p.exterior.count, interiorPolygons: holes)
        }
    }

    var rect: MKMapRect? {
        var r: MKMapRect?
        for p in polygons {
            for c in p.exterior {
                let pt = MKMapPoint(c)
                let one = MKMapRect(x: pt.x, y: pt.y, width: 0, height: 0)
                r = r.map { $0.union(one) } ?? one
            }
        }
        for p in pins {
            let pt = MKMapPoint(p.coordinate)
            let one = MKMapRect(x: pt.x, y: pt.y, width: 0, height: 0)
            r = r.map { $0.union(one) } ?? one
        }
        return r
    }

    /// From the engine's WGS84 result.
    init(geometry: Geometry?, pins: [RoundJunction]) {
        if let g = geometry {
            for p in g.polygonParts {
                let r = p.rings
                polygons.append(Polygon(exterior: r.exterior.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) },
                                        holes: r.interiors.map { $0.map { CLLocationCoordinate2D(latitude: $0.y, longitude: $0.x) } }))
            }
        }
        self.pins = pins.enumerated().map { i, p in
            Pin(id: i, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), title: "Junction left round \(i + 1)",
                detail: p.reason)
        }
    }

    init() {}

    /// From a KML file written by road_to_kml (or anything with Polygons and Points).
    init(kml data: Data) throws {
        let root = try MiniXML.parse(data)
        func coords(_ text: String) -> [CLLocationCoordinate2D] {
            text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).compactMap { item in
                let p = item.split(separator: ",")
                guard p.count >= 2, let lon = Double(p[0]), let lat = Double(p[1]) else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        func ring(_ boundary: MiniXMLNode?) -> [CLLocationCoordinate2D]? {
            guard let b = boundary, let c = b.iter().first(where: { $0.local == "coordinates" }) else { return nil }
            return coords(c.text)
        }
        var n = 0
        for el in root.iter() {
            if el.local == "Polygon" {
                guard let outer = ring(el.children.first { $0.local == "outerBoundaryIs" }), outer.count >= 3 else { continue }
                let holes = el.children.filter { $0.local == "innerBoundaryIs" }.compactMap { ring($0) }
                polygons.append(Polygon(exterior: outer, holes: holes))
            } else if el.local == "Placemark", let pt = el.iter().first(where: { $0.local == "Point" }),
                      let c = pt.iter().first(where: { $0.local == "coordinates" }), let ll = coords(c.text).first {
                n += 1
                let name = el.children.first { $0.local == "name" }?.text ?? "Point \(n)"
                let desc = el.children.first { $0.local == "description" }?.text ?? ""
                pins.append(Pin(id: n, coordinate: ll, title: name, detail: desc))
            } else if el.local == "Document", description.isEmpty {
                description = el.children.first { $0.local == "description" }?.text ?? ""
            }
        }
    }
}

/// A KML file in the output folder.
struct OutputFile: Identifiable, Hashable {
    let url: URL
    let size: Int
    let modified: Date
    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }
}

/// One run of the engine, watched by the UI.
@MainActor
final class RoadJob: ObservableObject, Identifiable {
    enum Status: Equatable { case running, done, failed, cancelled }

    let id = UUID()
    let label: String
    let argv: [String]
    let started = Date()
    @Published var lines: [LogLine] = []
    @Published var status: Status = .running
    @Published var ended: Date?
    @Published var outputs: [URL] = []
    @Published var surface = MapSurface()
    @Published var errorLine: String?

    init(label: String, argv: [String]) {
        self.label = label
        self.argv = argv
    }

    var statusWords: String {
        switch status {
        case .running: return "running"
        case .done: return "finished"
        case .failed: return "stopped with an error"
        case .cancelled: return "cancelled"
        }
    }
}

/// Runs road_to_kml jobs one at a time on a background thread and keeps the output folder.
@MainActor
final class RoadJobs: ObservableObject {
    static let shared = RoadJobs()

    let outputDirectory: URL
    let inputsDirectory: URL
    let statsURL: URL

    @Published var current: RoadJob?
    @Published private(set) var files: [OutputFile] = []
    @Published var overpassURL: String {
        didSet { UserDefaults.standard.set(overpassURL, forKey: "roads.overpassURL") }
    }

    private var engine: RoadToKML?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let pending = PendingLines()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = docs.appendingPathComponent("Road KML", isDirectory: true)
        let inputs = out.appendingPathComponent("Inputs", isDirectory: true)
        for d in [out, inputs] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        outputDirectory = out
        inputsDirectory = inputs
        statsURL = out.appendingPathComponent("overpass_mirror_stats.txt")
        _overpassURL = Published(initialValue: UserDefaults.standard.string(forKey: "roads.overpassURL") ?? "")
        refreshFiles()
    }

    var isRunning: Bool { current?.status == .running }

    /// A path for the command line: relative to the output folder when it's inside it
    /// (the app's folder moves when iOS updates the app, so saved batches keep working).
    func argPath(_ url: URL) -> String {
        let base = outputDirectory.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : p
    }

    func url(forArg p: String) -> URL {
        p.hasPrefix("/") ? URL(fileURLWithPath: p) : outputDirectory.appendingPathComponent(p)
    }

    /// Copy a file the user picked (Files app, iCloud Drive…) into Inputs.
    func importFile(_ source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var dest = inputsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            let same = (try? Data(contentsOf: dest)) == (try? Data(contentsOf: source))
            if !same {
                let stem = source.deletingPathExtension().lastPathComponent, ext = source.pathExtension
                var k = 2
                repeat {
                    dest = inputsDirectory.appendingPathComponent("\(stem)-\(k)" + (ext.isEmpty ? "" : ".\(ext)"))
                    k += 1
                } while FileManager.default.fileExists(atPath: dest.path)
            } else {
                return dest
            }
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Write a recording as Takeout Records.json into Inputs (what --track reads, with
    /// accuracy and walking/driving per point).
    func recordingInput(_ session: TrackSession) throws -> URL {
        let points = TrackStore.shared.loadPoints(from: session.url)
        let data = try Exporter.records([ExportTrack(name: session.name, points: points)])
        let url = inputsDirectory.appendingPathComponent("\(session.name)_Records.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Start a run. Returns the job, or nil if one is already running.
    @discardableResult
    func run(_ argv: [String], label: String) -> RoadJob? {
        if isRunning { return nil }
        let job = RoadJob(label: label, argv: argv)
        current = job

        let http = HTTPClient()
        let engine = RoadToKML(services: .live(http: http), outputDirectory: outputDirectory, mirrorStatsPath: statsURL)
        engine.overpassURL = overpassURL.trimmingCharacters(in: .whitespaces)
        http.isCancelled = { [weak engine] in engine?.cancelled ?? true }
        let pending = self.pending
        pending.reset()
        engine.log = RunLog(onLine: { line in
            if pending.add(line) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { RoadJobs.shared.flush(into: job) }
                }
            }
        })
        self.engine = engine
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Road to KML") { [weak self] in
            MainActor.assumeIsolated { self?.cancel() }
        }

        let thread = Thread {
            let result = engine.run(argv)
            let surface = MapSurface(geometry: engine.lastSurface, pins: engine.lastPins)
            let outputs = engine.outputs
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RoadJobs.shared.finish(job, result, surface, outputs) }
            }
        }
        thread.stackSize = 16 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
        return job
    }

    func cancel() { engine?.cancel() }

    private func flush(into job: RoadJob) {
        let new = pending.take()
        guard !new.isEmpty else { return }
        let start = job.lines.count
        job.lines += new.enumerated().map { LogLine(id: start + $0.offset, text: $0.element, kind: LogLine.classify($0.element)) }
    }

    private func finish(_ job: RoadJob, _ result: RunResult, _ surface: MapSurface, _ outputs: [String]) {
        flush(into: job)
        job.ended = Date()
        job.status = result.code == 0 ? .done : result.code == -1 ? .cancelled : .failed
        job.errorLine = result.error
        job.outputs = outputs.map { url(forArg: $0) }
        job.surface = surface
        engine = nil
        refreshFiles()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    func refreshFiles() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: keys)) ?? []
        files = urls.filter { $0.pathExtension.lowercased() == "kml" }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return OutputFile(url: u, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }

    func delete(_ file: OutputFile) {
        try? FileManager.default.removeItem(at: file.url)
        refreshFiles()
    }

    var mirrorReport: String? { MirrorStats(path: statsURL).reportText }

    /// Is this a usable Overpass server address? (road_to_kml_ui.py's check)
    static func validOverpassURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil else { return false }
        return true
    }
}

/// Log lines waiting to be shown (written from the engine's thread).
final class PendingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var scheduled = false

    func reset() { lock.lock(); lines = []; scheduled = false; lock.unlock() }

    /// Add a line; true if the caller should schedule a flush.
    func add(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines = []
        scheduled = false
        return out
    }
}
