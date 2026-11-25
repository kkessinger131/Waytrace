import SwiftUI
import MapKit
import Charts

struct SessionDetailView: View {
    let session: TrackSession
    @EnvironmentObject private var recorder: LocationRecorder
    @State private var points: [TrackPoint] = []
    @State private var loaded = false
    @State private var log = RecordingLog()
    @State private var showExport = false
    @State private var showRoadRun = false
    @State private var roadsMessage: String?
    @ObservedObject private var roads = RoadJobs.shared

    private var isActive: Bool { recorder.isRecording && session.name == recorder.sessionName }

    /// Run road_to_kml --track on this recording (as Takeout Records.json, which keeps the
    /// accuracy and walking/driving label of every point), with the Roads tab's options.
    private func mapRoads() {
        do {
            let url = try roads.recordingInput(session)
            var form = RoadFormStore.shared.track
            form.files = [roads.argPath(url)]
            form.dateKind = .all
            form.shape.output = ""
            if form.modes.isEmpty { form.drive = true; form.walk = true; form.bike = true; form.other = true }
            let (argv, _) = form.build()
            let label = "Roads traveled: " + (session.startDate?.formatted(date: .abbreviated, time: .shortened) ?? session.name)
            if roads.run(argv, label: label) != nil {
                roadsMessage = nil
                showRoadRun = true
            } else {
                roadsMessage = "A Road to KML run is already in progress."
            }
        } catch {
            roadsMessage = "Couldn't prepare the recording: \(error.localizedDescription)"
        }
    }

    var body: some View {
        List {
            if loaded && !points.isEmpty {
                Section {
                    Map(initialPosition: .automatic) {
                        ForEach(TrackLine.lines(from: points)) { line in
                            MapPolyline(coordinates: line.coordinates)
                                .stroke(.red, lineWidth: 4)
                        }
                        if let first = points.first {
                            Marker("Start", systemImage: "flag", coordinate: first.coordinate)
                                .tint(.green)
                        }
                        if points.count > 1, let last = points.last {
                            Marker("End", systemImage: "flag.checkered", coordinate: last.coordinate)
                                .tint(.red)
                        }
                    }
                    .mapControls { MapCompass(); MapScaleView() }
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section("Summary") {
                if let first = points.first, let last = points.last {
                    LabeledContent("Start", value: first.time.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("End", value: last.time.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Duration", value: Duration.seconds(last.time.timeIntervalSince(first.time))
                        .formatted(.time(pattern: .hourMinuteSecond)))
                    LabeledContent("Distance", value: Fmt.distance(Geo.length(points)))
                    LabeledContent("Points", value: "\(points.count)")
                    let resumes = Set(points.map(\.segment)).count - 1
                    if resumes > 0 {
                        LabeledContent("Interruptions", value: "\(resumes)")
                    }
                    if let summary = activitySummary {
                        LabeledContent("Activity", value: summary)
                    }
                } else if loaded {
                    Text("No points in this recording.").foregroundStyle(.secondary)
                }
            }

            if !log.gaps.isEmpty {
                Section {
                    ForEach(Array(log.gaps.enumerated()), id: \.offset) { _, gap in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(gap.from.formatted(date: .omitted, time: .shortened)) – \(gap.to.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline.weight(.semibold))
                            Text(Interruption.describe(gap, distance: Fmt.distance)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Gaps")
                } footer: {
                    Text("Times Waytrace wasn't running. Exported KML files show each one as a yellow line from the last point before to the first one after.")
                }
            }

            if !log.rests.isEmpty {
                Section {
                    LabeledContent("GPS rested", value: "\(log.rests.count)× · \(Fmt.duration(log.restedTime)) in all")
                    LabeledContent("Woken by", value: log.wakeCounts.map { "\($0.reason) \($0.count)" }.joined(separator: " · "))
                    if !log.lateWakes.isEmpty {
                        Text("\(log.lateWakes.count) time(s) only the 3-minute GPS check noticed you'd left: up to 3 minutes of track before \(log.lateWakes.compactMap { $0.to?.formatted(date: .omitted, time: .shortened) }.joined(separator: ", ")) may be missing. If this happens often, report bug.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Battery saver")
                } footer: {
                    Text("Steps, the motion sensor or the geofence should wake the GPS within seconds of setting off.")
                }
            }

            if let report = log.batteryReport {
                batterySection(report)
            }

            Section {
                Button {
                    showExport = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(points.isEmpty)

                if canFillActivity {
                    Button {
                        recorder.fillActivity(for: session)
                    } label: {
                        Label("Fill in walking / driving labels", systemImage: "figure.walk")
                    }
                }

                Button(action: mapRoads) {
                    Label("Map roads traveled", systemImage: "road.lanes")
                }
                .disabled(points.count < 2 || roads.isRunning || isActive)
            } footer: {
                if let roadsMessage {
                    Text(roadsMessage).foregroundStyle(.orange)
                } else {
                    Text("Map roads traveled matches the recording to the road network and writes the road surface as KML (Roads tab settings for GPS history apply). Files are also in the Files app under On My iPhone › Waytrace.")
                }
            }
        }
        .navigationTitle(session.startDate?.formatted(date: .abbreviated, time: .omitted) ?? session.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            ExportSheet(sessions: [session], title: session.name, baseName: session.name)
        }
        .sheet(isPresented: $showRoadRun) {
            if let job = roads.current { RunView(job: job) }
        }
        .task(id: recorder.libraryRevision) {
            points = TrackStore.shared.loadPoints(from: session.url)
            log = RecordingLog.load(for: session.url)
            loaded = true
        }
    }

    /// Battery use while recording, and a chart of the level with the GPS rests shaded.
    @ViewBuilder
    private func batterySection(_ r: BatteryReport) -> some View {
        let pct = { (x: Double) in "\(Int((x * 100).rounded()))%" }
        let rate = { (x: Double) in String(format: "about %.1f%%/h", x * 100) }
        let end = log.battery.last?.time ?? Date()
        Section {
            Chart {
                ForEach(Array(log.rests.enumerated()), id: \.offset) { _, rest in
                    RectangleMark(xStart: .value("Rest from", rest.from), xEnd: .value("Rest to", rest.to ?? end))
                        .foregroundStyle(.green.opacity(0.18))
                }
                ForEach(Array(log.battery.enumerated()), id: \.offset) { _, b in
                    LineMark(x: .value("Time", b.time), y: .value("Battery", b.level * 100))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(.orange)
                }
            }
            .chartYScale(domain: 0.0...100.0)
            .chartYAxis {
                AxisMarks(values: [0.0, 50.0, 100.0]) { v in
                    AxisGridLine()
                    AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))%") }
                }
            }
            .frame(height: 140)
            LabeledContent("Used", value: "\(pct(r.used)) over \(Fmt.duration(r.onBattery))")
            LabeledContent("Level", value: "\(pct(r.first)) at the start, \(pct(r.last)) at the end")
            if let x = r.perHour { LabeledContent("Rate", value: rate(x)) }
            if let a = r.perHourActive, let b = r.perHourResting {
                LabeledContent("With the GPS on", value: rate(a))
                LabeledContent("With the GPS resting", value: rate(b))
            }
            if r.charging >= 60 { LabeledContent("On the charger", value: Fmt.duration(r.charging)) }
            if r.lowPower {
                Text("Low Power Mode was on for at least part of the recording.").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Battery")
        } footer: {
            Text("From the phone's battery level, which counts everything else the phone did too and moves in steps, so short stretches are rough. Time on the charger is left out. Shaded: the GPS was resting.")
        }
    }

    private var activitySummary: String? {
        let labels = points.compactMap(\.activity)
        guard !labels.isEmpty else { return nil }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        return counts
            .sorted { $0.value > $1.value }
            .map { "\($0.key) \(Int((Double($0.value) * 100 / Double(labels.count)).rounded()))%" }
            .joined(separator: " · ")
    }

    /// Core Motion only keeps a week of history.
    private var canFillActivity: Bool {
        guard MotionAnnotator.isAvailable,
              let last = points.last?.time,
              Date().timeIntervalSince(last) < 7 * 24 * 3600,
              !(recorder.isRecording && session.name == recorder.sessionName) else { return false }
        return points.contains { $0.activity == nil }
    }
}
