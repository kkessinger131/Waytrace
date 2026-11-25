import Foundation

/// Which recordings "Delete backed-up recordings" may take off the phone: ones that ended at
/// least a week ago, aren't being recorded, and whose files (the CSV, and its KML if it has
/// one) are all confirmed in the backup's Recordings folder.
enum Cleanup {
    static let minAge: TimeInterval = 7 * 86400

    /// A recording on the phone: its name, when it ended, and its files (name -> size).
    struct Local: Equatable, Sendable {
        var name: String
        var ended: Date
        var files: [String: Int]
    }

    /// A file in the backup folder. `inCloudOnly`: iCloud keeps it in the cloud and not on
    /// this phone (so it's uploaded, and its size here can't be compared). `uploaded`: what
    /// iCloud says about it, when it says.
    struct Backed: Equatable, Sendable {
        var size: Int?
        var inCloudOnly = false
        var uploaded: Bool?
    }

    enum Verdict: Equatable, Sendable {
        case delete
        case recording
        case tooNew
        /// The first file that isn't confirmed in the backup.
        case notBackedUp(String)
    }

    /// `backup` is keyed by lowercased file name.
    static func check(_ r: Local, backup: [String: Backed], active: String?, now: Date) -> Verdict {
        if r.name == active { return .recording }
        if now.timeIntervalSince(r.ended) < minAge { return .tooNew }
        for (file, size) in r.files.sorted(by: { $0.key < $1.key }) {
            guard let b = backup[file.lowercased()], b.uploaded != false else { return .notBackedUp(file) }
            if b.inCloudOnly { continue }
            if b.size != size { return .notBackedUp(file) }
        }
        return .delete
    }

    /// Reads a folder listing: ".name.icloud" placeholders count as `name`, kept in iCloud only.
    static func backed(name: String, size: Int?, notDownloaded: Bool, uploaded: Bool?) -> (key: String, value: Backed) {
        let lower = name.lowercased()
        if lower.hasPrefix("."), lower.hasSuffix(".icloud"), lower.count > 8 {
            return (String(lower.dropFirst().dropLast(7)), Backed(size: nil, inCloudOnly: true, uploaded: uploaded))
        }
        return (lower, Backed(size: size, inCloudOnly: notDownloaded, uploaded: uploaded))
    }
}
