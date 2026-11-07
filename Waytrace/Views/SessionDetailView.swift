import SwiftUI
import MapKit

struct SessionDetailView: View {
    let session: TrackSession
    @EnvironmentObject private var recorder: LocationRecorder
    @State private var points: [TrackPoint] = []
    @State private var loaded = false
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
            loaded = true
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
