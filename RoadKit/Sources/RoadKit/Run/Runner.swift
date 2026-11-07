import Foundation

/// How a run ended.
public struct RunResult: Sendable {
    /// 0 ok, 1 failed, 2 bad options, -1 cancelled.
    public let code: Int
    /// The KML written (the last one, for a batch).
    public let output: String?
    /// Every KML written.
    public let outputs: [String]
    /// The last error line, if it failed.
    public let error: String?
}

extension RoadToKML {
    /// One command line, start to finish, as a fresh run of road_to_kml.py.
    public func run(_ argv: [String]) -> RunResult {
        resetRunState()
        outputs = []
        lastSurface = nil
        lastPins = []
        lastTrips = []
        log.resetLastError()
        do {
            let out = try main(argv)
            return RunResult(code: 0, output: out, outputs: outputs, error: nil)
        } catch let e as ExitError {
            return RunResult(code: e.code, output: nil, outputs: outputs, error: log.lastError.isEmpty ? e.message : log.lastError)
        } catch let e as UsageError {
            reportUsage(e)
            return RunResult(code: 2, output: nil, outputs: outputs, error: e.description)
        } catch is CancelledError {
            log("\nCancelled.")
            return RunResult(code: -1, output: nil, outputs: outputs, error: "Cancelled.")
        } catch {
            let msg = "\(RoadToKML.errorName(error)): \(error)"
            log("ERROR: \(msg)")
            return RunResult(code: 1, output: nil, outputs: outputs, error: msg)
        }
    }

    static func errorName(_ e: Error) -> String {
        switch e {
        case is InputError: return "ValueError"
        case is NetError: return "RequestException"
        case is GeometryError: return "GEOSException"
        default: return String(describing: type(of: e))
        }
    }

    func reportUsage(_ e: UsageError) {
        log(OptionParser.usage)
        log("road_to_kml.py: error: \(e.description)")
    }

    /// Check a command line without running it (road_to_kml_ui.py's /api/validate):
    /// nil if it's fine, else argparse's message.
    public static func validate(_ argv: [String]) -> String? {
        do {
            let o = try OptionParser.parse(argv)
            if !o.batch.isEmpty || o.help { return nil }
            let (modes, _) = try Planning.parseSources(o.source)
            if o.track != nil {
                if !o.road.isEmpty { return "--track and --road can't be used together" }
                if modes == ["xml"] { return "--source xml can't be used with --track" }
            } else {
                if Py.strip(o.clipFrom).isEmpty != Py.strip(o.clipTo).isEmpty { return "--from and --to go together" }
                _ = try Planning.parseClipPoint(Py.strip(o.clipFrom))
                _ = try Planning.parseClipPoint(Py.strip(o.clipTo))
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// main(argv)
    func main(_ argv: [String]) throws -> String? {
        let o = try OptionParser.parse(argv)
        if o.help {
            log(OptionParser.helpText)
            return nil
        }
        if !o.batch.isEmpty { return try runBatch(o.batch, argv) }
        if o.track != nil { return try runTracks(o) }
        return try runRoad(o)
    }

    /// A file path as given on the command line, relative to the output folder (the
    /// working directory road_to_kml_ui.py runs the script in).
    func resolvePath(_ p: String) -> URL {
        if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
        if p.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(p.dropFirst(2))) }
        return outputDirectory.appendingPathComponent(p)
    }

    // MARK: - --batch

    static let batchValueColumns: [String: String] = [
        "road": "--road", "state": "--state", "county": "--county", "city": "--city", "source": "--source",
        "output": "--output", "notes": "--notes", "lanes": "--lanes", "leftwidth": "--leftwidth",
        "rightwidth": "--rightwidth", "from": "--from", "to": "--to", "track": "--track", "date": "--date",
        "travel_modes": "--travel-modes",
    ]
    static let batchFlagColumns: [String: (String, String?)] = [
        "strip_inner": ("--strip-inner", nil), "wait": ("--wait", nil), "ramps": ("--ramps", nil),
        "junctions": ("--junctions", "--no-junctions"), "outlines": ("--outlines", "--no-outlines"),
    ]
    static let trueWords: Set<String> = ["1", "y", "yes", "true", "x", "on"]
    static let falseWords: Set<String> = ["0", "n", "no", "false", "off"]

    /// _batch_row_args: one CSV row -> command-line tokens.
    public static func batchRowArgs(_ row: [(String, String?)]) -> [String] {
        var tokens: [String] = []
        for (col, raw) in row {
            let value = Py.strip(raw ?? "")
            if value.isEmpty { continue }
            if let flag = batchValueColumns[col] {
                if col == "source" {
                    tokens.append(flag)
                    let parts = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    tokens += parts.map { Py.strip(String($0)) }
                } else if col == "track" {
                    tokens += [flag] + value.split(separator: ";").map { Py.strip(String($0)) }.filter { !$0.isEmpty }
                } else {
                    tokens += [flag, value]
                }
            } else if let (on, off) = batchFlagColumns[col] {
                let v = value.lowercased()
                if col == "outlines" && v == "both" { tokens += ["--outlines", "both"] }
                else if trueWords.contains(v) { tokens.append(on) }
                else if falseWords.contains(v), let off { tokens.append(off) }
            }
        }
        return tokens
    }

    static func normHeader(_ h: String?) -> String {
        var s = Py.strip(h ?? "")
        while s.hasPrefix("-") { s.removeFirst() }
        return Re.sub(Re.compile("[\\s-]+"), "_", s.lowercased())
    }

    /// run_batch: each CSV row as its own job; options given alongside --batch apply to every
    /// row, and row values override them.
    func runBatch(_ path: String, _ argv: [String]) throws -> String? {
        var base: [String] = [], skip = false
        for tok in argv {
            if skip { skip = false; continue }
            if tok == "--batch" { skip = true; continue }
            if tok.hasPrefix("--batch=") { continue }
            base.append(tok)
        }
        let text: String
        do {
            var data = try Data(contentsOf: resolvePath(path))
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            text = String(decoding: data, as: UTF8.self)
        } catch {
            throw fail("can't read \(path): \(error.localizedDescription)")
        }
        let (rawHeaders, rawRows) = CSVReader.dictRows(text)
        let headers = rawHeaders.map { RoadToKML.normHeader($0) }
        // {norm(k): v} keeps the first position of a repeated column and its last value
        let rows: [[(String, String?)]] = rawRows.map { r in
            var order: [String] = [], vals: [String: String?] = [:]
            for (k, v) in r {
                let n = RoadToKML.normHeader(k)
                if vals[n] == nil { order.append(n) }
                vals[n] = .some(v)
            }
            return order.map { ($0, vals[$0]!) }
        }
        let known = Set(RoadToKML.batchValueColumns.keys).union(RoadToKML.batchFlagColumns.keys)
        let ignored = headers.filter { !$0.isEmpty && !known.contains($0) }
        if !ignored.isEmpty { log("  Note: ignoring column(s) \(ignored.joined(separator: ", ")).") }

        var results: [(Int, String, String, String)] = []
        for (n, row) in rows.enumerated() {
            try checkCancel()
            let lineNo = n + 2
            let values = row.map { Py.strip($0.1 ?? "") }
            if !values.contains(where: { !$0.isEmpty }) || (values.first ?? "").hasPrefix("#") { continue }
            func col(_ k: String) -> String? { row.first { $0.0 == k }?.1.flatMap { $0.isEmpty ? nil : $0 } }
            let label = col("road") ?? col("track") ?? "row \(lineNo)"
            log("\n######## Row \(lineNo): \(label) ########")
            log.resetLastError()
            do {
                let out = try main(base + RoadToKML.batchRowArgs(row))
                results.append((lineNo, label, "OK", out ?? ""))
            } catch let e as CancelledError {
                throw e
            } catch let e as ExitError {
                results.append((lineNo, label, "FAILED", log.lastError.isEmpty ? "exit code \(e.code)" : log.lastError))
            } catch let e as UsageError {
                reportUsage(e)
                results.append((lineNo, label, "FAILED", log.lastError))
            } catch {
                results.append((lineNo, label, "FAILED", "\(RoadToKML.errorName(error)): \(error)"))
            }
        }
        log("\n\(RoadToKML.rule)\n  Batch summary: \(path)\n\(RoadToKML.rule)")
        for (lineNo, label, status, detail) in results {
            let num = String(lineNo).padding(toLength: max(4, String(lineNo).count), withPad: " ", startingAt: 0)
            let st = status.padding(toLength: 6, withPad: " ", startingAt: 0)
            log("  Row \(num) \(st)  \(label)  ->  \(detail)")
        }
        let failed = results.filter { $0.2 != "OK" }.count
        log("\n  \(results.count - failed) succeeded, \(failed) failed.")
        if failed > 0 { throw ExitError(1, "\(failed) batch row(s) failed") }
        return nil
    }
}
