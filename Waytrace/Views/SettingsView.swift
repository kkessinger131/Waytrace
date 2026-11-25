import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SamplingPolicy.Key.interval) private var interval = SamplingPolicy.defaults.interval
    @AppStorage(SamplingPolicy.Key.minDistance) private var minDistance = SamplingPolicy.defaults.minDistance
    @AppStorage(SamplingPolicy.Key.maxAccuracy) private var maxAccuracy = SamplingPolicy.defaults.maxAccuracy
    @AppStorage(SamplingPolicy.Key.splitAtMidnight) private var splitAtMidnight = SamplingPolicy.defaults.splitAtMidnight
    @AppStorage(SamplingPolicy.Key.driftGuard) private var driftGuard = SamplingPolicy.defaults.driftGuard
    @AppStorage(SamplingPolicy.Key.restWhenStill) private var restWhenStill = SamplingPolicy.defaults.restWhenStill
    @AppStorage(SamplingPolicy.Key.restAfterMinutes) private var restAfterMinutes = SamplingPolicy.defaults.restAfterMinutes
    @ObservedObject private var daily = DailyRoads.shared
    @ObservedObject private var backup = Backup.shared
    @ObservedObject private var notifier = Notifier.shared
    @State private var notifyRuns = Notifier.shared.notifyRuns
    @State private var pickFolder = false
    @State private var cleanup: (delete: [TrackSession], notBackedUp: [String])?
    @State private var confirmCleanup = false
    @State private var cleanupNote: String?

    private let accuracyChoices: [Double] = [10, 20, 30, 40, 50, 65, 100, 200]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $interval, in: 5...300, step: 5) {
                        LabeledContent("Try to save a point every", value: "\(Int(interval)) s")
                    }
                    Stepper(value: $minDistance, in: 0...200, step: 5) {
                        LabeledContent("Skip if within", value: "\(Int(minDistance)) m of the last point")
                    }
                    Picker("Skip fixes less accurate than", selection: $maxAccuracy) {
                        Text("Don't skip").tag(0.0)
                        ForEach(accuracyChoices, id: \.self) { value in
                            Text("±\(Int(value)) m").tag(value)
                        }
                    }
                    Toggle("Start a new file each day", isOn: $splitAtMidnight)
                } header: {
                    Text("Sampling")
                } footer: {
                    Text("Changes apply the next time you press RECORD. While you stand still the app is asleep; while you move it checks your position about once a second and saves at most one point per interval. road_to_kml.py ignores points less accurate than ±40 m.")
                }

                Section {
                    Toggle("Drift guard", isOn: $driftGuard)
                } footer: {
                    Text("Indoors, positions from wifi can wander 20–50 m while you sit still. With the drift guard on, a point is also skipped unless you've moved further than its accuracy (a ±35 m fix needs a 35 m move). Outdoors, with ±3–10 m GPS, the \(Int(minDistance)) m rule applies exactly as set. Turn it off to use only the \(Int(minDistance)) m rule.")
                }

                Section {
                    Toggle("Rest the GPS when I stay put", isOn: $restWhenStill)
                    if restWhenStill {
                        Stepper(value: $restAfterMinutes, in: 3...30, step: 1) {
                            LabeledContent("After being still for", value: "\(Int(restAfterMinutes)) min")
                        }
                    }
                } header: {
                    Text("Battery")
                } footer: {
                    Text("Once every sign (no movement beyond a small circle, no walking or driving from the motion sensor, and almost no steps) agrees you've stopped for that long. Red lights or traffic jams count as driving, so GPS stays on; the same for a short break on a hike. The recording never stops. The GPS comes back after about 10 steps, as soon as the phone senses walking or driving, when you leave the spot (“Always” location access required), or at a quick GPS check every 3 minutes. Applies from the next RECORD.")
                }

                Section {
                    Toggle("Map the day's roads automatically", isOn: $daily.enabled)
                    if !daily.plan.isEmpty {
                        LabeledContent("Waiting", value: daily.plan.pendingSummary)
                    }
                    if let r = daily.lastResult {
                        Text(r).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Daily road map")
                } footer: {
                    Text("When you press STOP, the recording is mapped using the GPS history settings from the Roads tab, into its own file named after it: Road KML/roads_YYYY-MM-DD_HH-MM-SS.kml (a part after midnight gets that day's date and 00-00-00). A recording running past midnight maps the finished day the next time you open the app. If the map servers are busy it tries again after 30 minutes and again after 2 hours.")
                }

                Section {
                    LabeledContent("Folder", value: backup.folderName ?? "Not set")
                    Button(backup.isSet ? "Choose a different folder…" : "Choose a folder in iCloud Drive…") { pickFolder = true }
                    if backup.isSet {
                        Button {
                            backup.backUp(reason: "by hand")
                        } label: {
                            HStack {
                                Text("Back up now")
                                if backup.working { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(backup.working)
                        if let r = backup.lastResult {
                            Text(r).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Delete backed-up recordings…", role: .destructive) { planCleanup() }
                        if let cleanupNote {
                            Text(cleanupNote).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Stop backing up", role: .destructive) { backup.forgetFolder() }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Copies recordings into Recordings/ (each finished one with a KML of its line, points and photos beside it) and road maps into Road KML/ inside the folder: every 15 minutes while recording, when you press STOP, and after each Road to KML run. Make a folder such as iCloud Drive › Waytrace and pick it here.")
                }

                Section {
                    Toggle("Tell me when a Road to KML run finishes", isOn: $notifyRuns)
                        .onChange(of: notifyRuns) { _, on in Notifier.shared.notifyRuns = on }
                    LabeledContent("This install", value: signingText)
                    LabeledContent("Notifications", value: permissionText)
                    if notifier.permission == .denied {
                        Button("Turn them on in iOS Settings…") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    if SigningInfo.current != nil {
                        LabeledContent("Expiry warnings", value: reminderText)
                    }
                    if let r = notifier.resigned {
                        LabeledContent("Last re-signed", value: r.at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let problem = notifier.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Send a test notification") { notifier.sendTest() }
                } header: {
                    Text("Notifications and signing")
                } footer: {
                    Text("A notification comes when a run finishes, saying if anything went wrong (only if you've left the app). Two more notifications come before this install expires: one at 24 hours remaining, and a last call at 3 hours. “Last re-signed” shows when a Sideloadly refresh (or reinstall) last renewed it. If it says Not set, open the app once more, or send a test. With Sideloadly's automatic refresh (see the Waytrace README), your PC re-signs it over Wi-Fi before then. Reinstalling over the app keeps your recordings; deleting it erases them.")
                }

                Section {
                    Button("Restore defaults (\(SamplingPolicy.defaultsSummary))") {
                        interval = SamplingPolicy.defaults.interval
                        minDistance = SamplingPolicy.defaults.minDistance
                        maxAccuracy = SamplingPolicy.defaults.maxAccuracy
                        splitAtMidnight = SamplingPolicy.defaults.splitAtMidnight
                        driftGuard = SamplingPolicy.defaults.driftGuard
                        restWhenStill = SamplingPolicy.defaults.restWhenStill
                        restAfterMinutes = SamplingPolicy.defaults.restAfterMinutes
                    }
                }

                Section {
                    LabeledContent("Version", value: AppVersion.current.text)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { backup.setFolder(url) }
            }
            .task { await notifier.refreshStatus() }
            .confirmationDialog(cleanupTitle, isPresented: $confirmCleanup, titleVisibility: .visible) {
                Button("Delete \(cleanup?.delete.count ?? 0) from this iPhone", role: .destructive) {
                    if let list = cleanup?.delete { backup.deleteBackedUp(list) }
                    cleanup = nil
                    cleanupNote = nil
                }
                Button("Cancel", role: .cancel) { cleanup = nil }
            } message: {
                Text(cleanupMessage)
            }
        }
    }

    /// Works out which recordings can go, then asks.
    private func planCleanup() {
        guard let plan = backup.cleanupPlan() else {
            cleanupNote = "Can't reach the backup folder. Choose it again above."
            return
        }
        let waiting = plan.notBackedUp.isEmpty ? "" : " \(plan.notBackedUp.count) older one(s) aren't fully in the backup yet; press Back up now, then try again."
        if plan.delete.isEmpty {
            cleanupNote = "Nothing to delete: no recording that ended 7 or more days ago is confirmed in the backup." + waiting
            return
        }
        cleanupNote = waiting.isEmpty ? nil : String(waiting.dropFirst())
        cleanup = plan
        confirmCleanup = true
    }

    private var cleanupTitle: String {
        let n = cleanup?.delete.count ?? 0
        return n == 1 ? "Delete 1 backed-up recording?" : "Delete \(n) backed-up recordings?"
    }

    private var cleanupMessage: String {
        "These ended 7 or more days ago, and their files (CSV, KML and log) are in \(backup.folderName ?? "the backup folder") › Recordings. They're deleted from this iPhone only; the backup copies stay."
    }

    private var permissionText: String {
        switch notifier.permission {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off (iOS Settings › Waytrace)"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    private var reminderText: String {
        if !notifier.reminderDates.isEmpty {
            return notifier.reminderDates
                .map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()) }
                .joined(separator: " and ")
        }
        return notifier.permission == .denied ? "Can't be shown (notifications off)" : "Not set"
    }

    private var signingText: String {
        guard let expiry = SigningInfo.current else { return "No expiry (not a sideloaded build)" }
        return SigningInfo.describe(expiry: expiry, now: Date())
    }
}
