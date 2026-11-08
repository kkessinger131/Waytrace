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

    /// The expiry of the running app, or nil when there's no profile (simulator, or an App
    /// Store / TestFlight build).
    static var current: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return expirationDate(fromProfile: data)
    }

    /// How long before expiry the warning goes out.
    static let warning: TimeInterval = 24 * 3600

    /// When to show the warning: 24 hours before expiry; right away if that moment has
    /// passed but the app still runs; never once it has expired.
    static func reminderDate(expiry: Date, now: Date) -> Date? {
        guard expiry > now else { return nil }
        let at = expiry.addingTimeInterval(-warning)
        return at > now ? at : now.addingTimeInterval(5)
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
