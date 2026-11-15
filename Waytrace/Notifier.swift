import Foundation
import Combine
import UserNotifications
import UIKit

/// The app's two notifications: a Road to KML run has finished (saying whether anything went
/// wrong), and this install's signing runs out in 24 hours.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Whether iOS lets Waytrace show notifications (shown in Settings).
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    /// When the expiry warning is due, read back from iOS's own list of pending notifications.
    @Published private(set) var reminderAt: Date?
    /// Why the last attempt to schedule it failed, if it did.
    @Published private(set) var problem: String?

    private let center = UNUserNotificationCenter.current()
    private static let signingID = "signing-expiry"

    private enum Key {
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

    /// Called whenever the app comes on screen: asks for permission if iOS has never asked
    /// (iOS itself only ever asks once), then schedules the expiry warning and reads back
    /// what iOS actually has pending. Earlier versions asked only if a separate "app is
    /// active" check passed at that exact moment; when it didn't, iOS never asked, and every
    /// notification was silently dropped.
    func appCameForward() {
        Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            await scheduleSigningReminder()
        }
    }

    /// A notification 5 seconds from now, to check they come through (lock the phone to see
    /// it on the Lock Screen).
    func sendTest() {
        Task {
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            let content = UNMutableNotificationContent()
            content.title = "Waytrace test notification"
            content.body = "Notifications are working. The expiry warning will arrive like this."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: "test", content: content, trigger: trigger))
                problem = nil
            } catch {
                problem = "iOS refused the test notification: \(error.localizedDescription)"
            }
            await refreshStatus()
        }
    }

    /// Reads the permission and the pending expiry warning back from iOS.
    func refreshStatus() async {
        permission = await center.notificationSettings().authorizationStatus
        let pending = await center.pendingNotificationRequests()
        let trigger = pending.first { $0.identifier == Self.signingID }?.trigger as? UNTimeIntervalNotificationTrigger
        reminderAt = trigger?.nextTriggerDate()
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
    func scheduleSigningReminder(now: Date = Date()) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.signingID])
        defer { Task { await refreshStatus() } }
        guard let expiry = SigningInfo.current else {
            problem = SigningInfo.hasProfile ? "Couldn't read the expiry date from this install's signing profile." : nil
            return
        }
        guard let at = SigningInfo.reminderDate(expiry: expiry, now: now) else { problem = nil; return }
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
        do {
            try await center.add(UNNotificationRequest(identifier: Self.signingID, content: content, trigger: trigger))
            problem = nil
            if immediate { UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: Key.warnedExpiry) }
        } catch {
            problem = "iOS didn't accept the expiry warning: \(error.localizedDescription)"
        }
    }

    // Show notifications even while the app is open (an automatic run finishing, say).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
