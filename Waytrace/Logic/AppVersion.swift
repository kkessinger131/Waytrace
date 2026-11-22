import Foundation

/// The app's version as Settings shows it: "1.0 (build 57, commit 4d5b3a5)". The build number
/// is the GitHub Actions run that made the .ipa and the commit is the code it was built from,
/// so two installs can always be told apart. A build made in Xcode shows just "1.0 (1)".
struct AppVersion: Equatable, Sendable {
    var version: String
    var build: String
    var commit: String

    static var current: AppVersion {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppVersion(version: info["CFBundleShortVersionString"] as? String ?? "?",
                          build: info["CFBundleVersion"] as? String ?? "?",
                          commit: info["WaytraceCommit"] as? String ?? "")
    }

    var text: String {
        let c = commit.trimmingCharacters(in: .whitespaces)
        // An unexpanded "$(WAYTRACE_COMMIT)" means the build didn't set it.
        guard !c.isEmpty, !c.hasPrefix("$(") else { return "\(version) (\(build))" }
        return "\(version) (build \(build), commit \(c))"
    }
}
