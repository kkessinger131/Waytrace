import Foundation
import UserNotifications
import UIKit

/// The app's two notifications: a Road to KML run has finished (saying whether anything went
/// wrong), and this install's signing runs out in 24 hours.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private static let signingID = "signing-expiry"

    private enum Key {
        static let asked = "notify.asked"
        static let warnedExpiry = "notify.warnedExpiry"
        static let runs = "notify.runs"
    }

    /// Notify when a run finishes (manual runs only when you're not looking at the app).
    var notifyRuns: Bool {
        get { UserDefaults.standard.object(forKey: Key.runs) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.runs) }
    }

    /// Call at launch, before any notification can arrive.
    func attach() {
        center.delegate = self
    }

    /// Asks for permission once, the first time the app is on screen (never during a silent
    /// background relaunch, where the question couldn't be shown).
    func askOnce() {
        guard UIApplication.shared.applicationState == .active,
              !UserDefaults.standard.bool(forKey: Key.asked) else { return }
        UserDefaults.standard.set(true, forKey: Key.asked)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Notifier.shared.scheduleSigningReminder() } }
        }
    }

    // MARK: - Runs

    func runFinished(_ job: RoadJob, automatic: Bool) {
        guard notifyRuns else { return }
        if !automatic && UIApplication.shared.applicationState == .active { return }
        let outcome: RunSummary.Outcome = job.status == .done ? .done : job.status == .cancelled ? .cancelled : .failed
        let text = RunSummary.make(label: job.label, outcome: outcome, error: job.errorLine,
                                   log: job.lines.map(\.text), outputs: job.outputs.map(\.path))
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = text.hasProblems ? .default : nil
        content.threadIdentifier = "runs"
        center.add(UNNotificationRequest(identifier: "run-\(job.id.uuidString)", content: content, trigger: nil))
    }

    // MARK: - Signing

    /// (Re)schedules the 24-hour warning for the current install. Safe to call often: on
    /// launch, whenever the app comes to the front, and after a reinstall (a new expiry).
    func scheduleSigningReminder(now: Date = Date()) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.signingID])
        guard let expiry = SigningInfo.current, let at = SigningInfo.reminderDate(expiry: expiry, now: now) else { return }
        let immediate = at.timeIntervalSince(now) < 60
        // Only one "right away" warning per install, not one every time the app opens.
        if immediate && UserDefaults.standard.double(forKey: Key.warnedExpiry) == expiry.timeIntervalSince1970 { return }

        let content = UNMutableNotificationContent()
        content.title = "Waytrace needs re-signing"
        content.body = "This install stops opening \(expiry.formatted(date: .abbreviated, time: .shortened)). "
            + "Refresh it with Sideloadly before then (automatic refresh does it when your PC and iPhone share Wi-Fi). "
            + "Your recordings are kept when you reinstall over it; deleting the app would erase them."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(5, at.timeIntervalSince(now)), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.signingID, content: content, trigger: trigger))
        if immediate { UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: Key.warnedExpiry) }
    }

    // Show notifications even while the app is open (an automatic run finishing, say).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
