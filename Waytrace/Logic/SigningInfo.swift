import Foundation

/// When this install stops opening. Apps installed with a free Apple ID (Sideloadly) are
/// signed for 7 days; the date is in the provisioning profile iOS keeps inside the app
/// (embedded.mobileprovision).
enum SigningInfo {
    /// The profile's ExpirationDate. The profile is a signed (CMS) blob with a plain XML
    /// property list inside it, so the plist is cut out and read directly.
    static func expirationDate(fromProfile data: Data) -> Date? {
        let start = Data("<?xml".utf8), end = Data("</plist>".utf8)
        guard let a = data.range(of: start),
              let b = data.range(of: end, in: a.upperBound..<data.count) else { return nil }
        let xml = data.subdata(in: a.lowerBound..<b.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }

    private static var profileURL: URL? { Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") }

    /// True when the app carries a signing profile (every sideloaded install does).
    static var hasProfile: Bool { profileURL != nil }

    /// The expiry of the running app, or nil when there's no profile (simulator, or an App
    /// Store / TestFlight build).
    static var current: Date? {
        guard let url = profileURL, let data = try? Data(contentsOf: url) else { return nil }
        return expirationDate(fromProfile: data)
    }

    /// How long before expiry the first warning goes out.
    static let warning: TimeInterval = 24 * 3600
    /// And the last call.
    static let lastCall: TimeInterval = 3 * 3600

    struct Reminder: Equatable, Sendable {
        enum Kind: String, Sendable { case day, lastCall }
        var kind: Kind
        var at: Date
    }

    /// The warnings to schedule: 24 hours before expiry (right away instead, once, if the app
    /// is first opened after that), and a last call 3 hours before. None once it has expired.
    static func reminders(expiry: Date, now: Date, alreadyWarnedNow: Bool) -> [Reminder] {
        guard expiry > now else { return [] }
        var out: [Reminder] = []
        let day = expiry.addingTimeInterval(-warning)
        if day > now {
            out.append(Reminder(kind: .day, at: day))
        } else if !alreadyWarnedNow {
            out.append(Reminder(kind: .day, at: now.addingTimeInterval(5)))
        }
        let last = expiry.addingTimeInterval(-lastCall)
        if last > now.addingTimeInterval(60) {
            out.append(Reminder(kind: .lastCall, at: last))
        }
        return out
    }

    /// When to show the first warning (kept for callers that only want that one).
    static func reminderDate(expiry: Date, now: Date) -> Date? {
        reminders(expiry: expiry, now: now, alreadyWarnedNow: false).first { $0.kind == .day }?.at
    }

    /// True in the final 24 hours, when the Record screen shows a banner.
    static func isExpiringSoon(expiry: Date, now: Date) -> Bool {
        expiry > now && expiry.timeIntervalSince(now) <= warning
    }

    /// A newer expiry than the one seen before means the app was re-signed (Sideloadly's
    /// automatic refresh, or a reinstall).
    static func wasResigned(previous: Date?, current: Date?) -> Bool {
        guard let previous, let current else { return false }
        return current.timeIntervalSince(previous) > 60
    }

    static func describe(expiry: Date, now: Date) -> String {
        let left = expiry.timeIntervalSince(now)
        let when = expiry.formatted(date: .abbreviated, time: .shortened)
        if left <= 0 { return "Expired \(when)" }
        let hours = Int(left / 3600)
        if hours < 48 { return "Expires \(when) (in \(max(1, hours)) h)" }
        return "Expires \(when) (in \(hours / 24) days)"
    }
}
