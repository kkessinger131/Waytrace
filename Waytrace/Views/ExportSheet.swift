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
