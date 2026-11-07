import SwiftUI
import MapKit
import UIKit
import RoadKit

/// MapKit overlays for one surface, built once on the main thread.
final class SurfaceShape: Identifiable {
    let id = UUID()
    let name: String
    let polygons: [MKPolygon]
    let pins: [MapSurface.Pin]
    let rect: MKMapRect?
    let description: String

    init(_ s: MapSurface, name: String) {
        self.name = name
        polygons = s.mkPolygons
        pins = s.pins
        rect = s.rect
        description = s.description
    }

    var isEmpty: Bool { polygons.isEmpty && pins.isEmpty }

    static func fit(_ shapes: [SurfaceShape]) -> MapCameraPosition? {
        var r: MKMapRect?
        for s in shapes { if let x = s.rect { r = r.map { $0.union(x) } ?? x } }
        guard let r else { return nil }
        let pad = max(r.size.width, r.size.height) * 0.15 + 400
        return .rect(r.insetBy(dx: -pad, dy: -pad))
    }
}

/// Road surfaces on a map: yellow fill, dark edge, red pins for junctions left round.
struct SurfaceMap: View {
    let shapes: [SurfaceShape]
    @Binding var position: MapCameraPosition
    @AppStorage("roads.satellite") private var satellite = false
    @State private var selected: Int?

    private struct PinRef: Identifiable { let id: Int; let pin: MapSurface.Pin }

    private var pins: [PinRef] {
        shapes.enumerated().flatMap { i, s in s.pins.map { PinRef(id: i * 1_000_000 + $0.id, pin: $0) } }
    }

    var body: some View {
        Map(position: $position, selection: $selected) {
            ForEach(shapes) { s in
                ForEach(s.polygons.indices, id: \.self) { k in
                    MapPolygon(s.polygons[k])
                        .foregroundStyle(Color.roadMarking.opacity(0.72))
                        .stroke(Color.black.opacity(0.85), lineWidth: 1.2)
                }
            }
            ForEach(pins) { p in
                Marker(p.pin.title, systemImage: "exclamationmark", coordinate: p.pin.coordinate)
                    .tint(.red)
                    .tag(p.id)
            }
            UserAnnotation()
        }
        .mapStyle(satellite ? .imagery : .standard(elevation: .flat, emphasis: .muted))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
        .overlay(alignment: .topLeading) {
            Picker("Map", selection: $satellite) {
                Text("Streets").tag(false)
                Text("Satellite").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .padding(8)
        }
        .overlay(alignment: .bottom) {
            if let id = selected, let p = pins.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.pin.title).font(.subheadline.weight(.semibold))
                    Text(p.pin.detail).font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
                .onTapGesture { selected = nil }
            }
        }
    }
}

/// A run: status, the result on a map, the files written, and the live log.
struct RunView: View {
    @ObservedObject var job: RoadJob
    @ObservedObject private var jobs = RoadJobs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shape: SurfaceShape?
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                status
                if let shape, !shape.isEmpty {
                    SurfaceMap(shapes: [shape], position: $position)
                        .frame(height: 300)
                }
                if !job.outputs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(job.outputs, id: \.self) { url in
                                ShareLink(item: url) {
                                    Label(url.lastPathComponent, systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
                LogView(lines: job.lines)
            }
            .navigationTitle(job.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if job.status == .running {
                        Button("Cancel run", role: .destructive) { jobs.cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = job.lines.map(\.text).joined(separator: "\n")
                    } label: {
                        Label("Copy log", systemImage: "doc.on.doc")
                    }
                }
            }
            .onAppear(perform: buildShape)
            .onChange(of: job.status) { _, _ in buildShape() }
        }
    }

    private func buildShape() {
        guard job.status != .running, shape == nil, !job.surface.isEmpty else { return }
        let s = SurfaceShape(job.surface, name: job.outputs.last?.lastPathComponent ?? job.label)
        shape = s
        if let p = SurfaceShape.fit([s]) { position = p }
    }

    private var dotColor: Color {
        switch job.status {
        case .running: return .roadMarking
        case .done: return .green
        case .failed, .cancelled: return .red
        }
    }

    private var status: some View {
        TimelineView(.periodic(from: job.started, by: 1)) { ctx in
            let end = job.ended ?? ctx.date
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                Text("\(job.statusWords.prefix(1).uppercased() + job.statusWords.dropFirst()) (\(Int(end.timeIntervalSince(job.started).rounded())) s)")
                    .font(.subheadline)
                Spacer()
                if job.status == .running { ProgressView() }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

/// The run log, colored like the browser UI's, following the newest line.
struct LogView: View {
    let lines: [LogLine]

    private func color(_ k: LogLine.Kind) -> Color {
        switch k {
        case .plain: return Color(white: 0.88)
        case .error: return Color(red: 1, green: 0.56, blue: 0.53)
        case .warning: return Color(red: 0.95, green: 0.79, blue: 0.30)
        case .ok: return Color(red: 0.44, green: 0.83, blue: 0.64)
        case .heading: return .white
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.caption2.monospaced())
                            .fontWeight(line.kind == .heading ? .semibold : .regular)
                            .foregroundStyle(color(line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .textSelection(.enabled)
                .padding(10)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.10))
            .onChange(of: lines.count) { _, _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

/// Every KML in the output folder: show any of them on the map, share, delete.
struct OutputFilesView: View {
    @ObservedObject private var jobs = RoadJobs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shown: [String: SurfaceShape] = [:]
    @State private var loading: Set<String> = []
    @State private var position: MapCameraPosition = .automatic
    @State private var failed: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SurfaceMap(shapes: jobs.files.compactMap { shown[$0.name] }, position: $position)
                    .frame(height: 320)
                List {
                    Section {
                        if jobs.files.isEmpty {
                            Text("Nothing here yet. Finished runs appear in this list and on the map.").foregroundStyle(.secondary)
                        }
                        ForEach(jobs.files) { f in row(f) }
                            .onDelete { idx in
                                for i in idx {
                                    let f = jobs.files[i]
                                    shown[f.name] = nil
                                    jobs.delete(f)
                                }
                            }
                    } header: {
                        Text("Output files (\(jobs.files.count))")
                    } footer: {
                        Text(failed ?? "Also in the Files app: On My iPhone › Waytrace › Road KML.")
                    }
                }
            }
            .navigationTitle("Output files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Show all") { Task { for f in jobs.files { await show(f) }; fit() } }
                        Button("Hide all") { shown = [:] }
                        Button("Zoom to shown") { fit() }
                        Button("Refresh") { jobs.refreshFiles() }
                    } label: {
                        Label("Map", systemImage: "ellipsis.circle")
                    }
                }
            }
            .onAppear { jobs.refreshFiles() }
        }
    }

    private func row(_ f: OutputFile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if shown[f.name] != nil { shown[f.name] = nil } else { Task { await show(f) } }
            } label: {
                Image(systemName: loading.contains(f.name) ? "hourglass" : shown[f.name] != nil ? "checkmark.square.fill" : "square")
                    .foregroundStyle(shown[f.name] != nil ? Color.roadMarking : Color.secondary)
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file)), \(f.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task {
                    await show(f)
                    if let s = shown[f.name], let p = SurfaceShape.fit([s]) { position = p }
                }
            } label: { Image(systemName: "scope") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Zoom to \(f.name)")
            ShareLink(item: f.url) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
        }
    }

    private func show(_ f: OutputFile) async {
        if shown[f.name] != nil || loading.contains(f.name) { return }
        loading.insert(f.name)
        defer { loading.remove(f.name) }
        let url = f.url
        let result = await Task.detached(priority: .userInitiated) { () -> Result<MapSurface, Error> in
            Result { try MapSurface(kml: Data(contentsOf: url)) }
        }.value
        switch result {
        case .success(let s): shown[f.name] = SurfaceShape(s, name: f.name)
        case .failure(let e): failed = "Couldn't load \(f.name): \(e.localizedDescription)"
        }
    }

    private func fit() {
        if let p = SurfaceShape.fit(Array(shown.values)) { position = p }
    }
}

/// The aliases that would be searched for a road (road_to_kml.py --list-aliases).
struct AliasSheet: View {
    let road: String
    let state: String
    let county: String
    @Environment(\.dismiss) private var dismiss

    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let elements: [(kind: String, alts: [String])]
        let count: Int
        let variants: [String]
        let hint: String?
        let regex: String
    }

    static let kindNames = ["word": "Word", "group": "Abbreviation", "ordinal": "Number", "named": "Named road", "route": "Route"]

    private var results: [Result] {
        let r = road.trimmingCharacters(in: .whitespaces)
        let abbrs = Planning.splitList(state).compactMap { AliasEngine.resolveState($0) }
        let counties = Planning.splitList(county).map { $0.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression) }
        let ctxs: [String?] = abbrs.isEmpty ? [nil] : Array(Set(abbrs)).sorted().map { Optional($0) }
        return ctxs.map { ctx in
            let fips = ctx.flatMap { a in counties.lazy.compactMap { Planning.lookupCounty($0, a).fips }.first }
            let title = ctx.map { "Searching in \(AliasEngine.stateName($0))" + (fips.map { " (county \($0))" } ?? "") } ?? "Any state"
            return Result(title: title,
                          elements: AliasEngine.parse(r, ctx, fips).map { ($0.kind, $0.alts) },
                          count: AliasEngine.countVariants(r, state: ctx, county: fips),
                          variants: AliasEngine.expandVariants(r, state: ctx, limit: 40, county: fips),
                          hint: AliasEngine.renameHint(r, state: ctx, county: fips),
                          regex: AliasEngine.overpassTagRegex(r, state: ctx, county: fips))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { r in
                    Section(r.title) {
                        ForEach(r.elements.indices, id: \.self) { i in
                            LabeledContent(AliasSheet.kindNames[r.elements[i].kind] ?? r.elements[i].kind) {
                                Text(r.elements[i].alts.joined(separator: "  |  ")).multilineTextAlignment(.trailing)
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(r.count.formatted()) spelling combination\(r.count == 1 ? "" : "s"). The first \(r.variants.count):")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(r.variants.joined(separator: "\n")).font(.callout)
                        }
                        if let h = r.hint { Text(h).font(.caption).foregroundStyle(.orange) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OSM search pattern").font(.caption.weight(.semibold))
                            Text(r.regex).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Aliases for “\(road)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Tap the map to choose a latitude,longitude for --from / --to.
struct PointPicker: View {
    let title: String
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition
    @State private var chosen: CLLocationCoordinate2D?
    @AppStorage("roads.satellite") private var satellite = false

    init(title: String, text: Binding<String>) {
        self.title = title
        _text = text
        let parts = text.wrappedValue.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 {
            let c = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
            _chosen = State(initialValue: c)
            _position = State(initialValue: .camera(MapCamera(centerCoordinate: c, distance: 1500)))
        } else if let rect = RoadJobs.shared.current.flatMap({ SurfaceShape($0.surface, name: "").rect }) {
            _position = State(initialValue: .rect(rect.insetBy(dx: -500, dy: -500)))
        } else {
            _position = State(initialValue: .userLocation(fallback: .automatic))
        }
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if let chosen { Marker(title, coordinate: chosen).tint(Color.roadMarking) }
                    UserAnnotation()
                }
                .mapStyle(satellite ? .imagery : .standard(elevation: .flat))
                .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                .onTapGesture { pt in
                    if let c = proxy.convert(pt, from: .local) { chosen = c }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(chosen.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? "Tap the map to set the point.")
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use point") {
                        if let c = chosen { text = String(format: "%.6f,%.6f", c.latitude, c.longitude) }
                        dismiss()
                    }
                    .disabled(chosen == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { satellite.toggle() } label: { Image(systemName: satellite ? "map" : "globe.americas") }
                }
            }
        }
    }
}

/// Overpass server, the mirror tally and what's built in.
struct RoadSettingsView: View {
    @ObservedObject private var jobs = RoadJobs.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Built-in list of public servers", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if invalid { Text("That isn't an http(s) address.").foregroundStyle(.red) }
                } header: {
                    Text("Overpass server")
                } footer: {
                    Text("Leave empty to use the built-in list of servers. Set one only if you run your own.")
                }

                Section {
                    ForEach(Array(Overpass.mirrors.enumerated()), id: \.offset) { i, m in
                        Text("\(i + 1). \(URL(string: m)?.host ?? m)").font(.caption.monospaced())
                    }
                    NavigationLink("How each server has answered") {
                        ScrollView {
                            Text(jobs.mirrorReport ?? "No attempts recorded yet.")
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                        .navigationTitle("Overpass mirror tally")
                    }
                } header: {
                    Text("Built-in servers, in the order they're tried")
                }

                Section("About") {
                    LabeledContent("County list checked", value: countyFIPSUpdated)
                    if let r = Planning.checkCountyTableAge(countyFIPSUpdated, today: DayDate(Date())) {
                        Text(r).font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent("TIGER/Line support", value: "Built in")
                    LabeledContent("Output folder", value: "On My iPhone › Waytrace › Road KML")
                    LabeledContent("Engine", value: "road_to_kml.py, in Swift")
                }
            }
            .navigationTitle("Road to KML settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard RoadJobs.validOverpassURL(draft) else { invalid = true; return }
                        jobs.overpassURL = draft.trimmingCharacters(in: .whitespaces)
                        dismiss()
                    }
                }
            }
            .onAppear { draft = jobs.overpassURL }
        }
    }
}
