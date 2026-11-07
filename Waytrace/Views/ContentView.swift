import SwiftUI
import MapKit
import UIKit

struct ContentView: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @State private var sessions: [TrackSession] = []
    @State private var showSettings = false
    @State private var showExportAll = false
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Map(position: $camera) {
                        UserAnnotation()
                        ForEach(TrackLine.lines(from: recorder.points)) { line in
                            MapPolyline(coordinates: line.coordinates)
                                .stroke(.red, lineWidth: 4)
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                }

                Section { StatusView() }

                Section("Recordings") {
                    if sessions.isEmpty {
                        Text("Nothing recorded yet. Press RECORD to start.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        let active = recorder.isRecording && session.name == recorder.sessionName
                        NavigationLink(value: session) {
                            SessionRow(session: session, isActive: active)
                        }
                        .deleteDisabled(active)
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("Waytrace")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: TrackSession.self) { session in
                SessionDetailView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showExportAll = true
                    } label: {
                        Label("Export all", systemImage: "square.and.arrow.up.on.square")
                    }
                    .disabled(sessions.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { ControlBar() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showExportAll) {
                ExportSheet(sessions: sessions, title: "All recordings", baseName: "waytrace_all")
            }
            .task(id: recorder.libraryRevision) { reload() }
            .refreshable { reload() }
        }
    }

    private func reload() {
        sessions = TrackStore.shared.sessions()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            if recorder.isRecording && session.name == recorder.sessionName { continue }
            try? TrackStore.shared.delete(session)
        }
        reload()
    }
}

/// The two big buttons, pinned to the bottom of the screen within thumb reach.
private struct ControlBar: View {
    @EnvironmentObject private var recorder: LocationRecorder

    var body: some View {
        HStack(spacing: 12) {
            Button {
                recorder.record()
            } label: {
                Label("RECORD", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
            .disabled(recorder.isRecording)

            Button {
                recorder.stop()
            } label: {
                Label("STOP", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.gray)
            .disabled(!recorder.isRecording)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .font(.headline)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct StatusView: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                if recorder.isRecording, let start = recorder.sessionStart {
                    Text("Recording")
                    Text(start, style: .timer).monospacedDigit()
                } else {
                    Text("Stopped")
                }
                Spacer()
                Text("\(recorder.stats.saved) points").monospacedDigit()
            }
            .font(.headline)

            if recorder.isRecording || recorder.stats.attempts > 0 {
                Text("\(recorder.stats.attempts) attempts · \(recorder.stats.skippedTooClose) within \(Int(SamplingPolicy.current.minDistance)) m · \(recorder.stats.skippedPoorAccuracy) low accuracy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let fix = recorder.lastFix, recorder.isRecording {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Position", Fmt.coordinate(fix.coordinate))
                    row("Accuracy", Fmt.accuracy(fix.horizontalAccuracy))
                    row("Speed", Fmt.speed(fix.speed))
                    row("Direction", Fmt.course(fix.course))
                    row("Altitude", Fmt.altitude(fix.altitude, accuracy: fix.verticalAccuracy))
                    row("Fix time", fix.timestamp.formatted(date: .omitted, time: .standard))
                }
                .font(.footnote.monospacedDigit())
            }

            if recorder.authorization == .authorizedWhenInUse {
                notice("Location is set to “While Using the App”.",
                       "Recording keeps going in the background, but if iOS ever closes the app it can't restart itself. Set Location to “Always” to let it resume on its own.",
                       button: "Open Settings")
            }
            if !recorder.hasPreciseLocation {
                notice("Precise Location is off.",
                       "Points will be off by up to a few kilometres. Turn on Precise Location for Waytrace.",
                       button: "Open Settings")
            }
            if let message = recorder.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func notice(_ title: String, _ body: String, button: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.footnote).foregroundStyle(.secondary)
            Button(button) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.top, 4)
    }
}

private struct SessionRow: View {
    let session: TrackSession
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.startDate?.formatted(date: .abbreviated, time: .shortened) ?? session.name)
            Text(isActive ? "Recording…" : Fmt.fileSize(session.fileSize))
                .font(.caption)
                .foregroundStyle(isActive ? Color.red : Color.secondary)
        }
    }
}
