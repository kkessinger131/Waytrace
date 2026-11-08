import Foundation

/// The notification text for a finished Road to KML run: what it made, and anything that
/// went wrong along the way (a failed run, failed batch rows, trips that couldn't be matched,
/// gaps), read from the run's own log.
enum RunSummary {
    enum Outcome: Sendable { case done, failed, cancelled }

    struct Text: Equatable, Sendable {
        var title: String
        var body: String
        var hasProblems: Bool
    }

    static func make(label: String, outcome: Outcome, error: String?, log: [String], outputs: [String]) -> Text {
        var problems: [String] = []
        var batch: (ok: Int, failed: Int)?
        for line in log {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let m = t.firstMatch(of: #/^(\d+) succeeded, (\d+) failed\./#), let ok = Int(m.1), let bad = Int(m.2) {
                batch = (ok, bad)
            } else if let m = t.firstMatch(of: #/WARNING: (\d+) trip\(s\) couldn't be matched/#) {
                problems.append("\(m.1) trip(s) couldn't be matched to a road")
            } else if let m = t.firstMatch(of: #/Note: (\d+) gap\(s\) where a trip couldn't be followed/#) {
                problems.append("\(m.1) gap(s) left out")
            } else if t.contains("WARNING: part of the OSM road data is missing")
                        || t.contains("map cell(s) couldn't be downloaded") {
                if !problems.contains(where: { $0.hasPrefix("some map data") }) {
                    problems.append("some map data couldn't be downloaded")
                }
            } else if t.contains("WARNING: some TIGER/Line data couldn't be downloaded") {
                problems.append("some TIGER/Line data couldn't be downloaded")
            }
        }
        if let b = batch, b.failed > 0 { problems.insert("\(b.failed) of \(b.ok + b.failed) batch rows failed", at: 0) }

        let files = outputs.map { ($0 as NSString).lastPathComponent }
        let made = files.isEmpty ? "" : files.count == 1 ? "Saved \(files[0])." : "Saved \(files.count) KML files."
        switch outcome {
        case .done:
            let title = problems.isEmpty ? "Road to KML finished" : "Road to KML finished, with problems"
            var body = label
            if !made.isEmpty { body += "\n" + made }
            if !problems.isEmpty { body += "\nProblems: " + problems.joined(separator: "; ") + "." }
            return Text(title: title, body: body, hasProblems: !problems.isEmpty)
        case .failed:
            var body = label + "\n" + (error.map(clean) ?? "The run stopped with an error.")
            if !made.isEmpty { body += "\n" + made }
            if !problems.isEmpty { body += "\nAlso: " + problems.joined(separator: "; ") + "." }
            return Text(title: "Road to KML failed", body: body, hasProblems: true)
        case .cancelled:
            return Text(title: "Road to KML cancelled", body: label, hasProblems: true)
        }
    }

    private static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("ERROR: ") { t.removeFirst(7) }
        return t
    }
}
