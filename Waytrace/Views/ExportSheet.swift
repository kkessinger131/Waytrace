import SwiftUI

/// Builds every export format for the chosen recordings, then offers each one
/// (or all of them) through the share sheet: AirDrop, Files, Mail, iCloud Drive…
struct ExportSheet: View {
    let sessions: [TrackSession]
    let title: String
    let baseName: String

    @Environment(\.dismiss) private var dismiss
    @State private var files: [ExportFormat: URL] = [:]
    @State private var error: String?
    @State private var working = true
    @State private var photoFile: URL?
    @State private var photoNote: String?
    @State private var photoWorking = false

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
                Section {
                    if let url = photoFile {
                        ShareLink(item: url) { photoRow(url.lastPathComponent) }
                    } else {
                        Button {
                            Task { await buildPhotoMap() }
                        } label: {
                            HStack {
                                photoRow(nil)
                                if photoWorking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(photoWorking)
                    }
                    if let photoNote {
                        Text(photoNote).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Photo map")
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

    private func photoRow(_ fileName: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "camera").frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("KML: line + photo markers")
                Text(fileName == nil
                     ? "The recording's line with a camera marker wherever you took a photo or video during it. Tap to look through your photos for this time (they stay on the phone; only times and places are used)."
                     : "Photos with their own location are in one folder; ones placed on the line by the time they were taken are in a second, yellow folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fileName {
                    Text(fileName).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func buildPhotoMap() async {
        photoWorking = true
        defer { photoWorking = false }
        let access = await PhotoLibrary.requestAccess()
        if access == .denied {
            photoNote = "Waytrace can't see your photos. Allow it in Settings › Privacy & Security › Photos."
            return
        }
        let sessions = self.sessions, title = self.title, baseName = self.baseName
        let result = await Task.detached(priority: .userInitiated) { () -> (URL?, String) in
            let store = TrackStore.shared
            let tracks = sessions.sorted { $0.name < $1.name }
                .map { ExportTrack(name: $0.name, points: store.loadPoints(from: $0.url)) }
            var markers: [[PhotoMarker]] = []
            var own = 0, byTime = 0, unplaced = 0
            for t in tracks {
                guard let w = PhotoPlacer.window(t.points) else { markers.append([]); continue }
                let r = PhotoPlacer.place(PhotoLibrary.items(from: w.lowerBound, to: w.upperBound), on: t.points)
                markers.append(r.markers)
                own += r.markers.filter { $0.source == .photo }.count
                byTime += r.markers.filter { $0.source != .photo }.count
                unplaced += r.unplaced.count
            }
            guard own + byTime > 0 else { return (nil, "No photos or videos were taken during \(tracks.count == 1 ? "this recording" : "these recordings").") }
            let url = store.exportsDirectory.appendingPathComponent("\(baseName)_photos.kml")
            do {
                try Data(Exporter.photoKML(tracks, photos: markers, title: "\(title) (photos)").utf8).write(to: url, options: .atomic)
            } catch {
                return (nil, "Couldn't write the photo map: \(error.localizedDescription)")
            }
            var note = "\(own + byTime) marker(s): \(own) at the photo's own location, \(byTime) placed by time."
            if unplaced > 0 { note += " \(unplaced) couldn't be placed (no location, and taken during a gap in the recording)." }
            return (url, note)
        }.value
        photoFile = result.0
        photoNote = result.1 + (access == .limited ? " Only the photos you've shared with Waytrace were checked." : "")
    }

    private func build() async {
        let sessions = self.sessions
        let title = self.title
        let baseName = self.baseName
        let result = await Task.detached(priority: .userInitiated) { () -> ([ExportFormat: URL], String?) in
            let store = TrackStore.shared
            let tracks = sessions
                .sorted { $0.name < $1.name }
                .map { ExportTrack(name: $0.name, points: store.loadPoints(from: $0.url)) }
            var made: [ExportFormat: URL] = [:]
            var failure: String?
            for format in ExportFormat.allCases {
                do {
                    made[format] = try Exporter.write(format, tracks: tracks, baseName: baseName,
                                                      title: title, to: store.exportsDirectory)
                } catch {
                    failure = "Couldn't write \(format.fileName(base: baseName)): \(error.localizedDescription)"
                }
            }
            return (made, failure)
        }.value
        files = result.0
        error = result.1
        working = false
    }
}
