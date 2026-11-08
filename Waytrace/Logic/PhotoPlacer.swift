import Foundation

/// A photo or video from the library, reduced to what the map needs.
struct PhotoInfo: Equatable, Sendable {
    var id: String
    var fileName: String
    var taken: Date
    var latitude: Double?
    var longitude: Double?
    var isVideo = false
}

/// Where a photo goes on the map.
struct PhotoMarker: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// The photo's own location (the camera's GPS).
        case photo
        /// No location in the photo: placed on the recording by its time. `gap` is how far
        /// in time the nearest recorded point is, in seconds.
        case track(gap: TimeInterval)
    }

    var photo: PhotoInfo
    var latitude: Double
    var longitude: Double
    var source: Source
}

/// Puts photos on a recording: each photo taken while the recording ran (with a few minutes'
/// grace either side) gets a marker, at its own location if it has one, otherwise where the
/// recording says you were at that moment. Only the recordings' own time spans are looked
/// at, so nothing from before Waytrace was recording is ever added.
enum PhotoPlacer {
    /// Photos this long before the first point or after the last still belong to the recording.
    static let grace: TimeInterval = 5 * 60
    /// Outside the recording (or across an interruption), a photo without a location is only
    /// placed if a recorded point is this close in time.
    static let maxGap: TimeInterval = 10 * 60

    /// The time span to fetch photos for.
    static func window(_ points: [TrackPoint]) -> ClosedRange<Date>? {
        guard let first = points.map(\.time).min(), let last = points.map(\.time).max() else { return nil }
        return first.addingTimeInterval(-grace)...last.addingTimeInterval(grace)
    }

    /// Markers in time order, and the photos that couldn't be placed (no location, and no
    /// recorded point within `maxGap`).
    static func place(_ photos: [PhotoInfo], on points: [TrackPoint]) -> (markers: [PhotoMarker], unplaced: [PhotoInfo]) {
        let pts = points.sorted { $0.time < $1.time }
        guard let span = window(pts) else { return ([], []) }
        var markers: [PhotoMarker] = [], unplaced: [PhotoInfo] = []
        for photo in photos.sorted(by: { $0.taken < $1.taken }) where span.contains(photo.taken) {
            if let lat = photo.latitude, let lon = photo.longitude, (-90...90).contains(lat), (-180...180).contains(lon),
               !(lat == 0 && lon == 0) {
                markers.append(PhotoMarker(photo: photo, latitude: lat, longitude: lon, source: .photo))
            } else if let spot = position(at: photo.taken, on: pts) {
                markers.append(PhotoMarker(photo: photo, latitude: spot.lat, longitude: spot.lon, source: .track(gap: spot.gap)))
            } else {
                unplaced.append(photo)
            }
        }
        return (markers, unplaced)
    }

    /// Where the recording puts you at time `t`.
    ///
    /// Inside one stretch of recording, the recorder was running the whole time, so a long
    /// wait between two points means you stayed put (nothing moved 20 m): you were at the
    /// earlier point until about a minute before the later one. Unless the two points are far
    /// apart for the time between them (a tunnel or the subway, where there was no GPS):
    /// then the position is spread evenly over the gap. Before the first point, after the
    /// last, or across an interruption, the nearest point is used if it is within `maxGap`.
    static func position(at t: Date, on pts: [TrackPoint]) -> (lat: Double, lon: Double, gap: TimeInterval)? {
        guard !pts.isEmpty else { return nil }
        // first index with time >= t
        var lo = 0, hi = pts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        let after = lo < pts.count ? pts[lo] : nil
        let before = lo > 0 ? pts[lo - 1] : nil
        if let a = before, let b = after, a.segment == b.segment {
            let gap = min(t.timeIntervalSince(a.time), b.time.timeIntervalSince(t))
            let span = b.time.timeIntervalSince(a.time)
            let travelled = Geo.distance(a, b)
            var f: Double
            if span <= 2 * leaveTime || travelled / span > 0.5 {
                f = span > 0 ? t.timeIntervalSince(a.time) / span : 0
            } else {
                let left = b.time.addingTimeInterval(-leaveTime)
                f = t <= left ? 0 : t.timeIntervalSince(left) / leaveTime
            }
            f = min(1, max(0, f))
            return (a.latitude + (b.latitude - a.latitude) * f, a.longitude + (b.longitude - a.longitude) * f, gap)
        }
        let candidates = [before, after].compactMap { $0 }
        guard let near = candidates.min(by: { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }) else {
            return nil
        }
        let gap = abs(near.time.timeIntervalSince(t))
        return gap <= maxGap ? (near.latitude, near.longitude, gap) : nil
    }

    /// After a wait, roughly how long before the next saved point you set off.
    static let leaveTime: TimeInterval = 60
}
