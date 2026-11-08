import SwiftUI
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
    @State private var notifyRuns = Notifier.shared.notifyRuns
    @State private var pickFolder = false

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
                    Text("Indoors, positions from wifi can wander 20–50 m while you sit still. With the drift guard on, a point is also skipped unless you've moved further than its accuracy (a ±35 m fix needs a 35 m move). Outdoors, with ±3–10 m GPS, the 20 m rule applies exactly as set. Turn it off to use only the 20 m rule.")
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
                    Text("Only after every sign agrees you've stopped for that long: no movement beyond a small circle, no walking or driving from the motion sensor, and almost no steps. A red light or a traffic jam counts as driving, so the GPS stays on; so does a short break on a hike. The recording never stops: location keeps running on cell towers, which keeps Waytrace alive exactly as before. The GPS comes back after about 10 steps, as soon as the phone senses walking or driving, when you leave the spot (with “Always” location access), or at a quick GPS check every 3 minutes. Applies from the next RECORD.")
                }

                Section {
                    Toggle("Map the day's roads automatically", isOn: $daily.enabled)
                    if !daily.plan.isEmpty {
                        LabeledContent("Waiting", value: daily.plan.pendingDays.joined(separator: ", "))
                    }
                    if let r = daily.lastResult {
                        Text(r).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Daily road map")
                } footer: {
                    Text("When you press STOP, each day in the recording is mapped with the GPS history settings from the Roads tab, into Road KML/roads_YYYY-MM-DD.kml (one file per day; all of that day's recordings together). A recording running past midnight maps the finished day the next time you open the app. If the map servers are busy it tries again after 30 minutes and 2 hours.")
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
                        Button("Stop backing up", role: .destructive) { backup.forgetFolder() }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Copies recordings into Recordings/ and road maps into Road KML/ inside the folder: every 15 minutes while recording, when you press STOP, and after each Road to KML run. Only changed files are copied, and nothing is ever deleted from the backup. Make a folder such as iCloud Drive › Waytrace and pick it here.")
                }

                Section {
                    Toggle("Tell me when a Road to KML run finishes", isOn: $notifyRuns)
                        .onChange(of: notifyRuns) { _, on in Notifier.shared.notifyRuns = on }
                    LabeledContent("This install", value: signingText)
                } header: {
                    Text("Notifications and signing")
                } footer: {
                    Text("A notification comes when a run finishes, saying if anything went wrong (only if you've left the app, or for the automatic daily map). Another comes 24 hours before this install stops opening. With Sideloadly's automatic refresh (see the Waytrace README), your PC re-signs it over Wi-Fi before then. Reinstalling over the app keeps your recordings; deleting it erases them.")
                }

                Section {
                    Button("Restore defaults (15 s, 20 m, ±50 m, drift guard on, rest after 5 min)") {
                        interval = SamplingPolicy.defaults.interval
                        minDistance = SamplingPolicy.defaults.minDistance
                        maxAccuracy = SamplingPolicy.defaults.maxAccuracy
                        splitAtMidnight = SamplingPolicy.defaults.splitAtMidnight
                        driftGuard = SamplingPolicy.defaults.driftGuard
                        restWhenStill = SamplingPolicy.defaults.restWhenStill
                        restAfterMinutes = SamplingPolicy.defaults.restAfterMinutes
                    }
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
        }
    }

    private var signingText: String {
        guard let expiry = SigningInfo.current else { return "No expiry (not a sideloaded build)" }
        return SigningInfo.describe(expiry: expiry, now: Date())
    }
}
