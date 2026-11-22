import Foundation
import UIKit

/// The line KML of a finished recording, saved next to it as Tracks/<name>.kml so the backup
/// copies it into Recordings/ beside the CSV. It's the same file as Export › KML: the line, a
/// marker per point, and the photos and videos taken during the recording as points on the
/// line. Written when a recording stops (or rolls over at midnight) once its walking/driving
/// labels are filled in, again whenever the labels are filled in later, and with "Back up
/// now" for any finished recording that doesn't have one yet.
enum RecordingKML {
    static func url(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("kml")
    }

    /// Recordings whose KML is being made right now (so a backup doesn't make an older one
    /// at the same time).
    @MainActor private static var busy: Set<URL> = []

    /// Makes (or remakes) the KML for one finished recording. Asks for photo access only if
    /// the app is on screen; without it the KML has no photos.
    @MainActor
    @discardableResult
    static func write(for recording: URL) async -> Bool {
        busy.insert(recording)
        defer { busy.remove(recording) }
        let photos = await canSeePhotos(ask: UIApplication.shared.applicationState == .active)
        return await Task.detached(priority: .utility) { make(recording, photos: photos) }.value
    }

    /// The finished recordings in `directory` that have no KML yet, leaving out `active` and
    /// any being made now.
    @MainActor
    static func missing(in directory: URL, except active: URL?) -> [URL] {
        let fm = FileManager.default
        let csvs = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "csv" }
        return csvs.filter { csv in
            csv != active && !busy.contains(csv) && !fm.fileExists(atPath: url(for: csv).path)
        }
    }

    @MainActor
    static func canSeePhotos(ask: Bool) async -> Bool {
        var access = PhotoLibrary.currentAccess
        if access == nil, ask { access = await PhotoLibrary.requestAccess() }
        return access == .allowed || access == .limited
    }

    /// Off the main thread. False if the recording is empty or the file couldn't be written.
    @discardableResult
    nonisolated static func make(_ recording: URL, photos: Bool) -> Bool {
        let points = TrackStore.shared.loadPoints(from: recording)
        guard !points.isEmpty else { return false }
        let name = recording.deletingPathExtension().lastPathComponent
        let track = ExportTrack(name: name, points: points, gaps: RecordingLog.load(for: recording).gaps)
        var markers: [PhotoMarker] = []
        if photos, let w = PhotoPlacer.window(points) {
            markers = PhotoPlacer.place(PhotoLibrary.items(from: w.lowerBound, to: w.upperBound), on: points).markers
        }
        let text = Exporter.kml([track], title: name, photos: [markers])
        do {
            try Data(text.utf8).write(to: url(for: recording), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
