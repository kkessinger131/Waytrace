import Foundation
import Combine
import UserNotifications
import UIKit

/// The app's notifications: a Road to KML run has finished (saying whether anything went
/// wrong); this install's signing runs out in 24 hours, and a last call 3 hours before; the
/// app was re-signed; a recording picked up again after a long gap.
@MainActor
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Whether iOS lets Waytrace show notifications (shown in Settings).
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    /// When the expiry warnings are due, read back from iOS's own list of pending notifications.
    @Published private(set) var reminderDates: [Date] = []
    /// The last time the app found itself re-signed, and the expiry it had before.
    @Published private(set) var resigned: (at: Date, previousExpiry: Date)?
    /// Why the last attempt to schedule it failed, if it did.
    @Published private(set) var problem: String?

    private let center = UNUserNotificationCenter.current()
    private static let signingIDs: [SigningInfo.Reminder.Kind: String] = [.day: "signing-expiry", .lastCall: "signing-expiry-final"]

    private enum Key {
        static let warnedExpiry = "notify.warnedExpiry"
        static let runs = "notify.runs"
        static let lastExpiry = "signing.lastExpiry"
        static let resignedAt = "signing.resignedAt"
        static let previousExpiry = "signing.previousExpiry"
    }

    override init() {
        super.init()
        let d = UserDefaults.standard
        let at = d.double(forKey: Key.resignedAt), prev = d.double(forKey: Key.previousExpiry)
        if at > 0, prev > 0 { resigned = (Date(timeIntervalSince1970: at), Date(timeIntervalSince1970: prev)) }
    }

    /// Notify when a run finishes (manual runs only when you're not looking at the app).
    var notifyRuns: Bool {
        get { UserDefaults.standard.object(forKey: Key.runs) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Key.runs) }
    }

    /// Call at launch, before any notification can arrive. Also notices a re-signed install
    /// (a later expiry than last time): Sideloadly's refresh closes the app, so this launch is
    /// the first chance to tell.
    func attach() {
        center.delegate = self
        let d = UserDefaults.standard
        let current = SigningInfo.current
        let stored = d.double(forKey: Key.lastExpiry)
        let previous = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        if SigningInfo.wasResigned(previous: previous, current: current), let previous, let current {
            let now = Date()
            d.set(now.timeIntervalSince1970, forKey: Key.resignedAt)
            d.set(previous.timeIntervalSince1970, forKey: Key.previousExpiry)
            resigned = (now, previous)
            // Opened by hand after a reinstall, you can see it; in the background (after an
            // automatic refresh) a notification is the only way to know it happened.
            if UIApplication.shared.applicationState == .background {
                let content = UNMutableNotificationContent()
                content.title = "Waytrace was re-signed"
                content.body = "It now runs until \(current.formatted(date: .abbreviated, time: .shortened)) "
                    + "(it was due to stop \(previous.formatted(date: .abbreviated, time: .shortened))). Sideloadly's refresh worked."
                center.add(UNNotificationRequest(identifier: "resigned", content: content, trigger: nil))
            }
        }
        if let current { d.set(current.timeIntervalSince1970, forKey: Key.lastExpiry) }
    }

    /// The recording picked up again after a long gap.
    func recordingResumed(after gap: RecordingLog.Gap) {
        let content = UNMutableNotificationContent()
        content.title = "Recording resumed after a \(Interruption.duration(gap.duration)) gap"
        content.body = "Waytrace wasn't running from \(gap.from.formatted(date: .omitted, time: .shortened)) "
            + "to \(gap.to.formatted(date: .omitted, time: .shortened)). \(gap.cause)."
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "gap-\(Int(gap.to.timeIntervalSince1970))", content: content, trigger: nil))
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
        let ids = Set(Self.signingIDs.values)
        reminderDates = pending.filter { ids.contains($0.identifier) }
            .compactMap { ($0.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate() }
            .sorted()
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

    /// (Re)schedules the expiry warnings for the current install: 24 hours before, and a last
    /// call 3 hours before. Safe to call often: on launch, whenever the app comes to the
    /// front, and after a reinstall (a new expiry).
    func scheduleSigningReminder(now: Date = Date()) async {
        center.removePendingNotificationRequests(withIdentifiers: Array(Self.signingIDs.values))
        defer { Task { await refreshStatus() } }
        guard let expiry = SigningInfo.current else {
            problem = SigningInfo.hasProfile ? "Couldn't read the expiry date from this install's signing profile." : nil
            return
        }
        // Only one "right away" warning per install, not one every time the app opens.
        let warned = UserDefaults.standard.double(forKey: Key.warnedExpiry) == expiry.timeIntervalSince1970
        let when = expiry.formatted(date: .abbreviated, time: .shortened)
        problem = nil
        for r in SigningInfo.reminders(expiry: expiry, now: now, alreadyWarnedNow: warned) {
            let content = UNMutableNotificationContent()
            switch r.kind {
            case .day:
                content.title = "Waytrace needs re-signing"
                content.body = "This install stops opening \(when). "
                    + "Refresh it with Sideloadly before then (automatic refresh does it when the phone's screen is on, on the same Wi-Fi as your PC). "
                    + "Your recordings are kept when you refresh or update; deleting the app would erase them."
            case .lastCall:
                content.title = "Last call: Waytrace stops opening at \(expiry.formatted(date: .omitted, time: .shortened))"
                content.body = "It hasn't been refreshed yet. Plug the phone into your PC, or open Sideloadly and install Waytrace.ipa again over the app."
            }
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(5, r.at.timeIntervalSince(now)), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: Self.signingIDs[r.kind]!, content: content, trigger: trigger))
                if r.kind == .day && r.at.timeIntervalSince(now) < 60 {
                    UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: Key.warnedExpiry)
                }
            } catch {
                problem = "iOS didn't accept the expiry warning: \(error.localizedDescription)"
            }
        }
    }

    // Show notifications even while the app is open (an automatic run finishing, say).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
