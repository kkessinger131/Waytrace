import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SamplingPolicy.Key.interval) private var interval = SamplingPolicy.defaults.interval
    @AppStorage(SamplingPolicy.Key.minDistance) private var minDistance = SamplingPolicy.defaults.minDistance
    @AppStorage(SamplingPolicy.Key.maxAccuracy) private var maxAccuracy = SamplingPolicy.defaults.maxAccuracy
    @AppStorage(SamplingPolicy.Key.splitAtMidnight) private var splitAtMidnight = SamplingPolicy.defaults.splitAtMidnight
    @AppStorage(SamplingPolicy.Key.driftGuard) private var driftGuard = SamplingPolicy.defaults.driftGuard

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
                    Button("Restore defaults (15 s, 20 m, ±50 m, drift guard on)") {
                        interval = SamplingPolicy.defaults.interval
                        minDistance = SamplingPolicy.defaults.minDistance
                        maxAccuracy = SamplingPolicy.defaults.maxAccuracy
                        splitAtMidnight = SamplingPolicy.defaults.splitAtMidnight
                        driftGuard = SamplingPolicy.defaults.driftGuard
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
        }
    }
}
