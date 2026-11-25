import SwiftUI
import MapKit
import UIKit

/// The Photos tab: every photo and video with a location on a map (grouped where they're
/// dense), for one day, a range of days or all of them, and a KML line through them in the
/// order they were taken, like exif2kml.py made from an ExifTool export.
struct PhotosView: View {
    @State private var spots: [PhotoLibrary.Spot] = []
    @State private var unlocated: [Date] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var loadedAt: Date?
    @State private var access: PhotoLibrary.Access?
    @AppStorage("photos.span") private var spanRaw = PhotoPath.Span.all.rawValue
    @AppStorage("photos.pins") private var pins = true
    @State private var day = Date()
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var to = Date()
    @State private var file: URL?
    @State private var making = false
    @State private var note: String?

    private var span: PhotoPath.Span { PhotoPath.Span(rawValue: spanRaw) ?? .all }
    private var interval: DateInterval? { PhotoPath.interval(span, day: day, from: from, to: to) }

    private func inSpan(_ d: Date) -> Bool {
        guard let i = interval else { return true }
        return d >= i.start && d < i.end
    }

    private var shown: [PhotoLibrary.Spot] { spots.filter { inSpan($0.taken) } }

    var body: some View {
        NavigationStack {
            Group {
                if access == .denied {
                    ContentUnavailableView {
                        Label("Waytrace can't see your photos", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("Allow it in Settings › Privacy & Security › Photos.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        PhotoMapView(spots: shown)
                            .overlay {
                                if loading && !loaded { ProgressView("Reading your photo library…") }
                            }
                        panel
                    }
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(loading)
                    .accessibilityLabel("Read the photo library again")
                }
            }
        }
        .task { await load(force: false) }
        .onChange(of: spanRaw) { _, _ in file = nil }
        .onChange(of: day) { _, _ in file = nil }
        .onChange(of: from) { _, _ in file = nil }
        .onChange(of: to) { _, _ in file = nil }
        .onChange(of: pins) { _, _ in file = nil }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Photos from", selection: $spanRaw) {
                ForEach(PhotoPath.Span.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            switch span {
            case .day:
                DatePicker("Day", selection: $day, displayedComponents: .date)
            case .range:
                DatePicker("First day", selection: $from, displayedComponents: .date)
                DatePicker("Last day", selection: $to, displayedComponents: .date)
            case .all:
                EmptyView()
            }
            Text(countText).font(.footnote).foregroundStyle(.secondary)
            Toggle("Photo markers in the KML", isOn: $pins)
            HStack {
                Button(action: make) {
                    Label(making ? "Making…" : "Make KML line", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(shown.isEmpty || making)
                if let file {
                    ShareLink(item: file) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding()
        .background(.bar)
    }

    private var countText: String {
        guard loaded else { return loading ? "Reading your photo library…" : " " }
        var s = "\(shown.count) photo(s) and video(s) with a location"
        let without = unlocated.filter(inSpan).count
        if without > 0 { s += "; \(without) without one aren't shown" }
        if access == .limited { s += ". Only the photos you've shared with Waytrace are here" }
        return s + "."
    }

    private func load(force: Bool) async {
        if !force, let at = loadedAt, Date().timeIntervalSince(at) < 300 { return }
        var a = PhotoLibrary.currentAccess
        if a == nil { a = await PhotoLibrary.requestAccess() }
        access = a
        guard a == .allowed || a == .limited else { return }
        loading = true
        let result = await Task.detached(priority: .userInitiated) { PhotoLibrary.allSpots() }.value
        spots = result.spots
        unlocated = result.unlocated
        loaded = true
        loading = false
        loadedAt = Date()
    }

    /// Writes the KML for what's on the map into Exports, named for the days it covers.
    private func make() {
        let chosen = shown, withPins = pins
        let name = PhotoPath.fileName(span, day: day, from: from, to: to)
        making = true
        note = chosen.count > 500 ? "Looking up \(chosen.count) file names; this can take a minute." : nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (URL?, String?) in
                let names = PhotoLibrary.fileNames(for: chosen.map(\.id))
                let points = chosen.map {
                    PhotoPath.Point(name: names[$0.id] ?? ($0.isVideo ? "Video" : "Photo"), time: $0.taken,
                                    latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude)
                }
                let url = TrackStore.shared.exportsDirectory.appendingPathComponent(name)
                do {
                    try Data(PhotoPath.kml(points, title: PhotoPath.title(points), pins: withPins).utf8).write(to: url, options: .atomic)
                    return (url, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            making = false
            if let url = result.0 {
                file = url
                note = "\(chosen.count) photo(s) in \(url.lastPathComponent). It's also in the Files app under On My iPhone › Waytrace › Exports."
            } else {
                note = "Couldn't write the KML: \(result.1 ?? "unknown error")"
            }
        }
    }
}

/// A map of photos, grouped into numbered clusters where they're dense. Tap a cluster to
/// zoom in, a photo to see its name, time and a small picture.
private struct PhotoMapView: UIViewRepresentable {
    let spots: [PhotoLibrary.Spot]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.register(PhotoPinView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let ids = spots.map(\.id)
        guard ids != context.coordinator.shownIDs else { return }
        context.coordinator.shownIDs = ids
        map.removeAnnotations(map.annotations)
        let pins = spots.map(PhotoAnnotation.init)
        map.addAnnotations(pins)
        if !pins.isEmpty { map.showAnnotations(pins, animated: false) }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var shownIDs: [String] = []

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }
            guard let pin = view.annotation as? PhotoAnnotation else { return }
            let id = pin.id
            if !pin.named {
                pin.named = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let name = PhotoLibrary.fileNames(for: [id])[id]
                    DispatchQueue.main.async { if let name { pin.title = name } }
                }
            }
            let side: CGFloat = 56
            PhotoLibrary.thumbnail(id: id, side: side) { image in
                let iv = UIImageView(frame: CGRect(x: 0, y: 0, width: side, height: side))
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 6
                iv.image = image
                view.leftCalloutAccessoryView = iv
            }
        }
    }
}

private final class PhotoAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    let subtitle: String?
    var named = false

    init(_ spot: PhotoLibrary.Spot) {
        id = spot.id
        coordinate = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
        title = spot.isVideo ? "Video" : "Photo"
        subtitle = spot.taken.formatted(date: .abbreviated, time: .shortened)
    }
}

private final class PhotoPinView: MKMarkerAnnotationView {
    override var annotation: MKAnnotation? {
        willSet {
            clusteringIdentifier = "photo"
            canShowCallout = true
            markerTintColor = .systemOrange
            glyphImage = UIImage(systemName: "camera.fill")
            displayPriority = .defaultLow
        }
    }
}
