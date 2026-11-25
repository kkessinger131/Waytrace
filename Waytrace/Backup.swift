import Foundation
import Combine

/// Copies recordings and road maps into a folder you pick once, normally in iCloud Drive, so
/// they're safe if the phone is lost or the app has to be deleted.
///
///   <folder>/Recordings/2026-11-08_09-12-44.csv   the raw recordings (Tracks)
///   <folder>/Recordings/2026-11-08_09-12-44.kml   each finished recording's line, points and photos
///   <folder>/Recordings/2026-11-08_09-12-44.log.json   its gaps, GPS rests and battery log
///   <folder>/Road KML/roads_2026-11-08_09-12-44.kml   every KML Road to KML made
///
/// Copies are made every 15 minutes while recording, when a recording stops, after each Road
/// to KML run, and with "Back up now". A file is only copied when it has changed. Nothing is
/// ever deleted from the backup folder: deleting a recording on the phone leaves its copy.
/// The folder is remembered with a bookmark, which is how an app keeps access to a folder
/// outside its own; a free Apple ID can't use iCloud's own app storage, but this works.
@MainActor
final class Backup: ObservableObject {
    static let shared = Backup()

    @Published private(set) var folderName: String?
    @Published private(set) var lastBackup: Date?
    @Published private(set) var lastResult: String?
    @Published private(set) var working = false

    private var lastTick = Date.distantPast
    private var again = false

    private enum Key {
        static let bookmark = "backup.bookmark"
        static let last = "backup.last"
        static let result = "backup.result"
    }

    static let every: TimeInterval = 15 * 60

    private init() {
        let d = UserDefaults.standard
        if let url = resolve() { folderName = url.lastPathComponent }
        let t = d.double(forKey: Key.last)
        lastBackup = t > 0 ? Date(timeIntervalSince1970: t) : nil
        lastResult = d.string(forKey: Key.result)
    }

    var isSet: Bool { folderName != nil }

    /// Remember a folder picked in the Files picker.
    func setFolder(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: Key.bookmark)
            folderName = url.lastPathComponent
            backUp(reason: "folder chosen")
        } catch {
            note("Couldn't keep access to that folder: \(error.localizedDescription)")
        }
    }

    func forgetFolder() {
        UserDefaults.standard.removeObject(forKey: Key.bookmark)
        folderName = nil
    }

    /// Called every 15 s while recording; backs up every 15 minutes.
    func recordingTick() {
        guard isSet, Date().timeIntervalSince(lastTick) >= Self.every else { return }
        lastTick = Date()
        backUp(reason: "while recording")
    }

    func backUp(reason: String) {
        guard isSet else { return }
        if working { again = true; return }
        guard let folder = resolve() else {
            note("Lost access to the backup folder. Choose it again in Settings.")
            return
        }
        working = true
        lastTick = Date()
        let tracks = TrackStore.shared.tracksDirectory
        let sources: [(URL, String)] = [(tracks, "Recordings"),
                                         (RoadJobs.shared.outputDirectory, "Road KML")]
        // Backing up by hand also makes the KML for finished recordings that don't have one
        // (made before this was added, or the app was closed before it was written).
        let byHand = reason == "by hand" || reason == "folder chosen"
        let missing = byHand ? RecordingKML.missing(in: tracks, except: LocationRecorder.shared.currentRecording) : []
        Task.detached(priority: .utility) {
            if !missing.isEmpty {
                let photos = await RecordingKML.canSeePhotos(ask: false)
                for csv in missing { RecordingKML.make(csv, photos: photos) }
            }
            let result = Backup.copyChanged(sources, into: folder)
            await MainActor.run {
                let b = Backup.shared
                b.working = false
                b.lastBackup = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Key.last)
                b.note(result)
                if b.again { b.again = false; b.backUp(reason: reason) }
            }
        }
    }

    /// The file names in the backup's Road KML folder (including files iCloud keeps only in
    /// the cloud, listed as ".name.icloud"), so a new road map never takes the name of one
    /// that's there and the backup copy is never replaced, even if it's gone from the phone.
    func roadKMLNames() -> [String] {
        guard isSet, let folder = resolve() else { return [] }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let dir = folder.appendingPathComponent("Road KML", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// What "Delete backed-up recordings" would do: the recordings that can go (see Cleanup),
    /// and the names of older ones whose files aren't confirmed in the backup yet. nil if
    /// there's no backup folder or it can't be reached.
    func cleanupPlan(now: Date = Date()) -> (delete: [TrackSession], notBackedUp: [String])? {
        guard isSet, let folder = resolve() else { return nil }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let dir = folder.appendingPathComponent("Recordings", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return ([], []) }
        let keys: [URLResourceKey] = [.fileSizeKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey]
        var backup: [String: Cleanup.Backed] = [:]
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [] {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let b = Cleanup.backed(name: url.lastPathComponent, size: v?.fileSize,
                                   notDownloaded: v?.ubiquitousItemDownloadingStatus == .notDownloaded,
                                   uploaded: v?.ubiquitousItemIsUploaded)
            backup[b.key] = b.value
        }
        let store = TrackStore.shared
        let recorder = LocationRecorder.shared
        let active = recorder.isRecording ? recorder.sessionName : nil
        var delete: [TrackSession] = [], missing: [String] = []
        for s in store.sessions() {
            var files: [String: Int] = [:]
            for url in [s.url, RecordingKML.url(for: s.url), RecordingLog.url(for: s.url)] {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { files[url.lastPathComponent] = size }
            }
            let modified = (try? s.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let ended = store.loadPoints(from: s.url).last?.time ?? modified ?? now
            switch Cleanup.check(.init(name: s.name, ended: ended, files: files), backup: backup, active: active, now: now) {
            case .delete: delete.append(s)
            case .notBackedUp: missing.append(s.name)
            case .tooNew, .recording: break
            }
        }
        return (delete, missing)
    }

    /// Deletes those recordings from the phone (their backup copies stay).
    func deleteBackedUp(_ sessions: [TrackSession]) {
        var n = 0
        for s in sessions where (try? TrackStore.shared.delete(s)) != nil { n += 1 }
        LocationRecorder.shared.libraryChanged()
        note("Deleted \(n) backed-up recording(s) from this iPhone; the copies in \(folderName ?? "the backup folder") stay.")
    }

    private func note(_ s: String) {
        lastResult = s
        UserDefaults.standard.set(s, forKey: Key.result)
    }

    private func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Key.bookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Key.bookmark)
        }
        return url
    }

    /// Copies new and changed .csv, .kml and .log.json files. Runs off the main thread.
    nonisolated static func copyChanged(_ sources: [(URL, String)], into folder: URL) -> String {
        let fm = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        var copied = 0, failed = 0
        var firstError: String?
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        for (dir, name) in sources {
            let dest = folder.appendingPathComponent(name, isDirectory: true)
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? [])
                .filter { Cleanup.isBackedUp($0.lastPathComponent) }
            guard !files.isEmpty else { continue }
            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            coordinator.coordinate(writingItemAt: dest, options: [], error: &coordError) { dest in
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            }
            for src in files {
                let target = dest.appendingPathComponent(src.lastPathComponent)
                let s = try? src.resourceValues(forKeys: Set(keys))
                let t = try? target.resourceValues(forKeys: Set(keys))
                if let t, t.fileSize == s?.fileSize,
                   let tm = t.contentModificationDate, let sm = s?.contentModificationDate, tm >= sm { continue }
                var err: NSError?
                var ok = false
                coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &err) { target in
                    do {
                        let data = try Data(contentsOf: src)
                        try data.write(to: target, options: .atomic)
                        ok = true
                    } catch {
                        if firstError == nil { firstError = error.localizedDescription }
                    }
                }
                if let err, firstError == nil { firstError = err.localizedDescription }
                if ok { copied += 1 } else { failed += 1 }
            }
            if let coordError, firstError == nil { firstError = coordError.localizedDescription }
        }
        let when = Date().formatted(date: .omitted, time: .shortened)
        if failed > 0 { return "\(when): \(failed) file(s) couldn't be copied (\(firstError ?? "unknown error"))." }
        return copied == 0 ? "\(when): everything already backed up." : "\(when): copied \(copied) file(s)."
    }
}
