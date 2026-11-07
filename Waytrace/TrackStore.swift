import Foundation

/// A recording on disk: Documents/Tracks/<yyyy-MM-dd_HH-mm-ss>.csv
struct TrackSession: Identifiable, Hashable, Sendable {
    let url: URL
    var id: String { url.lastPathComponent }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var startDate: Date? { TrackStore.date(fromSessionName: name) }

    var fileSize: Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

/// All track files live in the app's Documents folder, which (with UIFileSharingEnabled)
/// shows up in the Files app under On My iPhone › Waytrace.
final class TrackStore: Sendable {
    static let shared = TrackStore()

    let tracksDirectory: URL
    let exportsDirectory: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        tracksDirectory = documents.appendingPathComponent("Tracks", isDirectory: true)
        exportsDirectory = documents.appendingPathComponent("Exports", isDirectory: true)
        for dir in [tracksDirectory, exportsDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func newSessionURL(start: Date) -> URL {
        let base = Self.sessionName(for: start)
        var url = tracksDirectory.appendingPathComponent(base).appendingPathExtension("csv")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = tracksDirectory.appendingPathComponent("\(base)-\(n)").appendingPathExtension("csv")
            n += 1
        }
        return url
    }

    func sessions() -> [TrackSession] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: tracksDirectory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "csv" }
            .map { TrackSession(url: $0) }
            .sorted { $0.name > $1.name }
    }

    func loadPoints(from url: URL) -> [TrackPoint] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        // The header (and any half-written last line after a crash) fails to parse and is skipped.
        return text.split(whereSeparator: \.isNewline).compactMap { TrackPoint(csvLine: String($0)) }
    }

    func rewrite(_ points: [TrackPoint], to url: URL) throws {
        var text = TrackPoint.csvHeader + "\n"
        for p in points { text += p.csvLine + "\n" }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func delete(_ session: TrackSession) throws {
        try FileManager.default.removeItem(at: session.url)
    }

    static func sessionName(for date: Date) -> String {
        sessionFormatter().string(from: date)
    }

    static func date(fromSessionName name: String) -> Date? {
        sessionFormatter().date(from: String(name.prefix(19)))
    }

    private static func sessionFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }
}

/// Appends one line per saved point. Each point goes straight to the file, so a crash or a
/// forced shutdown loses at most the point being written.
final class CSVAppender {
    private let handle: FileHandle
    private var isClosed = false

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data((TrackPoint.csvHeader + "\n").utf8).write(to: url)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ point: TrackPoint) throws {
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((point.csvLine + "\n").utf8))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    deinit { close() }
}
