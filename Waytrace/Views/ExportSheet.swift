import SwiftUI

/// Builds every export format for the chosen recordings, then offers each one
/// (or all of them) through the share sheet: AirDrop, Files, Mail, iCloud Drive…
/// The KML gets the photos and videos taken during the recordings as points on the line.
struct ExportSheet: View {
    let sessions: [TrackSession]
    let title: String
    let baseName: String

    @Environment(\.dismiss) private var dismiss
    @State private var files: [ExportFormat: URL] = [:]
    @State private var error: String?
    @State private var working = true
    @State private var photoNote: String?

    var body: some View {
        NavigationStack {
            List {
                if working {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Preparing files…")
                    }
                }
                Section {
                    ForEach(ExportFormat.allCases) { format in
                        if let url = files[format] {
                            ShareLink(item: url) {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: format.symbol)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(format.title)
                                        Text(format.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(url.lastPathComponent)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                        if format == .kml, let photoNote {
                                            Text(photoNote)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if files.count > 1 {
                    Section {
                        ShareLink(items: ExportFormat.allCases.compactMap { files[$0] }) {
                            Label("Share all formats", systemImage: "square.and.arrow.up.on.square")
                        }
                    } footer: {
                        Text("Copies are saved in the Files app under On My iPhone › Waytrace › Exports.")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await build() }
        }
    }

    private func build() async {
        let sessions = self.sessions
        let title = self.title
        let baseName = self.baseName
        var access = PhotoLibrary.currentAccess
        if access == nil { access = await PhotoLibrary.requestAccess() }
        let canSeePhotos = access == .allowed || access == .limited
        let result = await Task.detached(priority: .userInitiated) { () -> ([ExportFormat: URL], String?, String?) in
            let store = TrackStore.shared
            let tracks = sessions
                .sorted { $0.name < $1.name }
                .map { ExportTrack(name: $0.name, points: store.loadPoints(from: $0.url), gaps: RecordingLog.load(for: $0.url).gaps) }
            // Photos and videos taken during each recording, for the KML.
            var photos: [[PhotoMarker]] = []
            var placed = 0, unplaced = 0
            if canSeePhotos {
                for t in tracks {
                    guard let w = PhotoPlacer.window(t.points) else { photos.append([]); continue }
                    let r = PhotoPlacer.place(PhotoLibrary.items(from: w.lowerBound, to: w.upperBound), on: t.points)
                    photos.append(r.markers)
                    placed += r.markers.count
                    unplaced += r.unplaced.count
                }
            }
            var made: [ExportFormat: URL] = [:]
            var failure: String?
            for format in ExportFormat.allCases {
                do {
                    made[format] = try Exporter.write(format, tracks: tracks, photos: photos, baseName: baseName,
                                                      title: title, to: store.exportsDirectory)
                } catch {
                    failure = "Couldn't write \(format.fileName(base: baseName)): \(error.localizedDescription)"
                }
            }
            var note: String?
            if canSeePhotos {
                note = placed == 0
                    ? "No photos or videos were taken during \(tracks.count == 1 ? "this recording" : "these recordings")."
                    : "\(placed) photo(s) and video(s) added."
                if unplaced > 0 { note! += " \(unplaced) couldn't be placed (no location, and taken during a gap in the recording)." }
            }
            return (made, failure, note)
        }.value
        files = result.0
        error = result.1
        switch access {
        case .denied?: photoNote = "No photos added: Waytrace can't see your photos. Allow it in Settings › Privacy & Security › Photos."
        case .limited?: photoNote = (result.2 ?? "") + " Only the photos you've shared with Waytrace were checked."
        default: photoNote = result.2
        }
        working = false
    }
}
