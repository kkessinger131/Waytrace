import Foundation

/// Port of mirror_stats.py: a running tally of how each Overpass server answers, kept in a
/// text file that is never reset. The file is rewritten after each attempt as a readable
/// report whose last line holds the raw counts. Recording never stops a run.
public final class MirrorStats {
    public static let succeeded = "Succeeded"
    public static let couldntFinish = "Couldn't finish the query (timeout / out of memory)"
    public static let busy = "Busy (rate limited / overloaded)"
    public static let rejected = "Rejected the query (HTTP 400)"
    public static let noReply = "No reply in time (timed out)"
    public static let connection = "Couldn't connect"
    public static let unreadable = "Unreadable reply"
    public static let other = "Other error"
    static let order = [succeeded, couldntFinish, busy, rejected, noReply, connection, unreadable, other]
    static let dataPrefix = "# data: "

    public var path: URL
    var warned = false
    private let lock = NSLock()
    /// Where notes go (the run log).
    var note: (String) -> Void = { _ in }

    public init(path: URL) { self.path = path }

    /// classify_exception
    public static func classify(_ error: Error) -> String {
        switch error {
        case NetError.http(let code, let reason):
            if code == 400 { return rejected }
            return "HTTP \(code)" + (reason.isEmpty ? "" : " \(reason)")
        case NetError.timeout: return noReply
        case NetError.connection: return connection
        case NetError.unreadable: return unreadable
        default:
            let text = String(describing: error).lowercased()
            if text.contains("timed out") || text.contains("timeout") { return noReply }
            if text.contains("connection") { return connection }
            return other
        }
    }

    static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    struct Record {
        var outcomes: [String: Int] = [:]
        var lastTry: String?
        var lastOK: String?
        var okSeconds = 0.0
    }

    struct DataFile {
        var first: String?
        var updated: String?
        var mirrors: [String: Record] = [:]
    }

    struct Unreadable: Error, CustomStringConvertible {
        let description: String
    }

    /// The saved counts, or an empty record if there is no file yet.
    func load() throws -> DataFile {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return DataFile() }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed()
        where line.hasPrefix(MirrorStats.dataPrefix) {
            let json = Data(line.dropFirst(MirrorStats.dataPrefix.count).utf8)
            guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                throw Unreadable(description: "the data line isn't valid JSON")
            }
            var d = DataFile(first: obj["first"] as? String, updated: obj["updated"] as? String)
            for (url, v) in (obj["mirrors"] as? [String: Any]) ?? [:] {
                guard let m = v as? [String: Any] else { continue }
                var r = Record()
                for (k, c) in (m["outcomes"] as? [String: Any]) ?? [:] { r.outcomes[k] = (c as? NSNumber)?.intValue ?? 0 }
                r.lastTry = m["last_try"] as? String
                r.lastOK = m["last_ok"] as? String
                r.okSeconds = (m["ok_seconds"] as? NSNumber)?.doubleValue ?? 0
                d.mirrors[url] = r
            }
            return d
        }
        throw Unreadable(description: "the data line at the end of the file is missing")
    }

    private static func pct(_ n: Int, _ d: Int) -> String {
        d > 0 ? String(format: "%5.1f%%", 100.0 * Double(n) / Double(d)) : "    -"
    }

    private static func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
        let n = s.count
        if n >= w { return s }
        let fill = String(repeating: " ", count: w - n)
        return right ? fill + s : s + fill
    }

    static func jsonLine(_ d: DataFile) -> String {
        var mirrors: [String: Any] = [:]
        for (u, r) in d.mirrors {
            var m: [String: Any] = ["outcomes": r.outcomes]
            if let t = r.lastTry { m["last_try"] = t }
            if let t = r.lastOK { m["last_ok"] = t }
            if r.okSeconds > 0 || r.outcomes[succeeded] != nil { m["ok_seconds"] = r.okSeconds }
            mirrors[u] = m
        }
        let obj: [String: Any] = ["version": 1, "first": d.first ?? NSNull(), "updated": d.updated ?? NSNull(),
                                  "mirrors": mirrors]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The readable report, ending with the data line.
    static func render(_ d: DataFile, mirrorOrder: [String]) -> String {
        var order: [String] = []
        for u in mirrorOrder where !order.contains(u) { order.append(u) }
        order += d.mirrors.keys.filter { !mirrorOrder.contains($0) }.sorted()
        var out = [
            "Overpass mirror outcomes  (road_to_kml)",
            String(repeating: "=", count: 39),
            "Every attempt to reach an Overpass mirror is counted here, across all runs.",
            "The counts carry on from run to run; delete this file to start over.",
            "First recorded: \(d.first ?? "-")    Last updated: \(d.updated ?? "-")",
            "",
        ]
        if order.isEmpty {
            out.append("No attempts recorded yet.")
        } else {
            let width = order.map(\.count).max()!
            let head = "  \(pad("Mirror", width))  \(pad("Attempts", 8, right: true))  \(pad("Succeeded", 9, right: true))  \(pad("Rate", 6, right: true))  Last success"
            out += ["SUMMARY  (mirrors are tried in this order; one further down is only",
                    "         reached when the ones above it fail)",
                    head, "  " + String(repeating: "-", count: head.count - 2)]
            for u in order {
                let m = d.mirrors[u] ?? Record()
                let attempts = m.outcomes.values.reduce(0, +), ok = m.outcomes[succeeded] ?? 0
                let last = m.lastOK ?? (attempts > 0 ? "never" : "never tried")
                out.append("  \(pad(u, width))  \(pad(String(attempts), 8, right: true))  \(pad(String(ok), 9, right: true))  \(pad(pct(ok, attempts), 6, right: true))  \(last)")
            }
            let retired = order.filter { !mirrorOrder.isEmpty && !mirrorOrder.contains($0) }
            if !retired.isEmpty {
                out.append("  (not in the script's current mirror list: " + retired.joined(separator: ", ") + ")")
            }
            out += ["", "DETAILS"]
            let tried = order.filter { d.mirrors[$0] != nil }
            let allNames = Set(tried.flatMap { d.mirrors[$0]!.outcomes.keys })
            let nw = allNames.map(\.count).max() ?? 10
            for u in tried {
                let m = d.mirrors[u]!
                let attempts = m.outcomes.values.reduce(0, +), ok = m.outcomes[succeeded] ?? 0
                out += ["", u, "  Attempts: \(attempts)    Last attempt: \(m.lastTry ?? "-")"]
                if ok > 0 {
                    out.append(String(format: "  Average time for a successful reply: %.1f s", m.okSeconds / Double(ok)))
                }
                let names = sortedOutcomes(m.outcomes.keys)
                for n in names {
                    let c = m.outcomes[n]!
                    out.append("    \(pad(n, nw))  \(pad(String(c), 7, right: true))  \(pct(c, attempts))")
                }
            }
        }
        out += ["", dataPrefix + jsonLine(d)]
        return out.joined(separator: "\n") + "\n"
    }

    private static func sortedOutcomes<S: Sequence>(_ names: S) -> [String] where S.Element == String {
        let set = Set(names)
        return MirrorStats.order.filter { set.contains($0) } + set.filter { !MirrorStats.order.contains($0) }.sorted()
    }

    /// Add one attempt to the file. Never throws.
    public func record(_ url: String, _ outcome: String, seconds: Double = 0, mirrorOrder: [String] = []) {
        lock.lock()
        defer { lock.unlock() }
        do {
            var d: DataFile
            do {
                d = try load()
            } catch {
                // Don't silently wipe weeks of counts: set the old file aside.
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                var keep = path.path
                if keep.hasSuffix(".txt") { keep = String(keep.dropLast(4)) }
                keep += ".unreadable-\(f.string(from: Date())).txt"
                try FileManager.default.moveItem(atPath: path.path, toPath: keep)
                note("  Note: couldn't read the mirror tally (\(error)); kept it as \(keep) and started a new one.")
                d = DataFile()
            }
            let now = MirrorStats.now()
            d.first = d.first ?? now
            d.updated = now
            var m = d.mirrors[url] ?? Record()
            m.outcomes[outcome, default: 0] += 1
            m.lastTry = now
            if outcome == MirrorStats.succeeded {
                m.okSeconds = ((m.okSeconds + seconds) * 100).rounded() / 100
                m.lastOK = now
            }
            d.mirrors[url] = m
            let text = MirrorStats.render(d, mirrorOrder: mirrorOrder)
            let dir = path.deletingLastPathComponent()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                throw NetError.other("No such folder: \(dir.path)")
            }
            try Data(text.utf8).write(to: path, options: .atomic)
        } catch {
            if !warned {
                warned = true
                note("  Note: couldn't update the mirror tally at \(path.path): \(error)")
            }
        }
    }

    /// The saved counts as plain values, for the app's settings screen.
    public func summary() -> [(mirror: String, attempts: Int, succeeded: Int, lastSuccess: String?)] {
        guard let d = try? load() else { return [] }
        return d.mirrors.map { (u, r) in (u, r.outcomes.values.reduce(0, +), r.outcomes[MirrorStats.succeeded] ?? 0, r.lastOK) }
            .sorted { $0.mirror < $1.mirror }
    }

    public var reportText: String? { try? String(contentsOf: path, encoding: .utf8) }
}
