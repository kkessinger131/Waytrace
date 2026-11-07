import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RoadKit

/// The Road to KML tab: the same four forms as road_to_kml_ui.html (Road, GPS history,
/// OSM way, Batch), the command-line preview, and runs with a live log and map.
struct RoadsView: View {
    @ObservedObject private var forms = RoadFormStore.shared
    @ObservedObject private var jobs = RoadJobs.shared

    @State private var message: String?
    @State private var messageOK = false
    @State private var bad: Set<String> = []
    @State private var showRun = false
    @State private var showAliases = false
    @State private var showFiles = false
    @State private var showSettings = false
    @State private var picking: PickTarget?
    @State private var importKind: ImportKind = .track
    @State private var showImporter = false
    @State private var confirmClear = false

    enum ImportKind { case track, xml, csv }

    struct PickTarget: Identifiable {
        let id = UUID()
        let title: String
        let text: Binding<String>
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("What to map", selection: $forms.mode) {
                        ForEach(RoadMode.allCases) { m in
                            Text(m == .batch && !forms.batch.isEmpty ? "Batch (\(forms.batch.count))" : m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(lede)
                }

                switch forms.mode {
                case .road: RoadSections(form: $forms.road, bad: bad, pick: pick)
                case .track: TrackSections(form: $forms.track, bad: bad, addFiles: { importKind = .track; showImporter = true })
                case .xml: XMLSections(form: $forms.xml, bad: bad, pick: pick, chooseFile: { importKind = .xml; showImporter = true })
                case .batch: BatchSections(forms: forms, openCSV: { importKind = .csv; showImporter = true },
                                           saveCSV: saveCSVFile(), confirmClear: $confirmClear, message: setMessage)
                }

                actions

                if let message {
                    Section {
                        Label(message, systemImage: messageOK ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(messageOK ? Color.green : Color.orange)
                    }
                }

                Section {
                    Text(forms.command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = forms.command.components(separatedBy: "\n\n")[0]
                        setMessage("Copied the command.", ok: true)
                    } label: {
                        Label("Copy command", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Same run from a terminal")
                } footer: {
                    Text("For road_to_kml.py on a computer. In the app, Run does the same thing.")
                }
            }
            .navigationTitle("Road to KML")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showFiles = true } label: { Label("Output files", systemImage: "map") }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let job = jobs.current {
                        Button { showRun = true } label: {
                            Label("Last run", systemImage: job.status == .running ? "hourglass" : "list.bullet.rectangle")
                        }
                    }
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .onChange(of: forms.mode) { _, _ in clearMessage() }
            .sheet(isPresented: $showRun) {
                if let job = jobs.current { RunView(job: job) }
            }
            .sheet(isPresented: $showAliases) {
                AliasSheet(road: aliasRoad, state: aliasState, county: forms.mode == .road ? forms.road.county : "")
            }
            .sheet(isPresented: $showFiles) { OutputFilesView() }
            .sheet(isPresented: $showSettings) { RoadSettingsView() }
            .sheet(item: $picking) { t in PointPicker(title: t.title, text: t.text) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes,
                          allowsMultipleSelection: importKind == .track) { result in
                imported(result)
            }
            .confirmationDialog("Remove all \(forms.batch.count) row(s) from the batch?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Remove all", role: .destructive) {
                    forms.batch = []
                    forms.editing = nil
                }
            }
        }
    }

    private var lede: String {
        switch forms.mode {
        case .road: return "Map the surface of a named road. Abbreviations and route numbers are matched automatically, so \"Cathedral Ave NW\" also finds \"Cathedral Avenue Northwest\"."
        case .track: return "Map the roads you actually traveled, from your recordings, a Google Maps Timeline export or a GPS track. Each trip is matched to the road network, ramps and turns included."
        case .xml: return "Map one specific OpenStreetMap way or relation straight from the OSM API or a saved .osm/.xml file, skipping the name search."
        case .batch: return "A list of runs done one after another. Add rows from the other tabs, or open a CSV. A row that fails doesn't stop the rest."
        }
    }

    private var aliasRoad: String { forms.mode == .xml ? forms.xml.road : forms.road.road }
    private var aliasState: String { forms.mode == .xml ? forms.xml.state : forms.road.state }

    @ViewBuilder private var actions: some View {
        Section {
            if forms.mode == .road || forms.mode == .xml {
                Button {
                    if aliasRoad.trimmingCharacters(in: .whitespaces).isEmpty {
                        bad = ["road"]
                        setMessage("Enter a road name first.")
                    } else {
                        showAliases = true
                    }
                } label: { Label("Show aliases", systemImage: "text.magnifyingglass") }
            }
            if forms.mode != .batch {
                Button(action: addToBatch) {
                    if let e = forms.editing, e.mode == forms.mode {
                        Label("Update row \(e.index + 1)", systemImage: "square.and.pencil")
                    } else {
                        Label("Add to batch", systemImage: "text.badge.plus")
                    }
                }
                if let e = forms.editing, e.mode == forms.mode {
                    Button("Stop editing row \(e.index + 1)", role: .cancel) {
                        forms.editing = nil
                        clearMessage()
                    }
                }
            }
            Button(action: run) {
                HStack {
                    Spacer()
                    Text(jobs.isRunning ? "Running…" : forms.mode == .batch ? "Run batch" : "Run")
                        .font(.headline)
                    Spacer()
                }
            }
            .disabled(jobs.isRunning)
            .listRowBackground(jobs.isRunning ? Color.gray.opacity(0.3) : Color.roadMarking)
            .foregroundStyle(Color.black)
        }
    }

    private func pick(_ title: String, _ text: Binding<String>) { picking = PickTarget(title: title, text: text) }

    private func setMessage(_ text: String, ok: Bool = false) {
        message = text
        messageOK = ok
    }

    private func clearMessage() {
        message = nil
        bad = []
    }

    private func check(_ m: RoadMode) -> [String]? {
        let (argv, problems) = forms.build(m)
        bad = Set(problems.map(\.field))
        if !problems.isEmpty {
            setMessage(problems.map(\.message).joined(separator: " "))
            return nil
        }
        if m != .batch, let err = RoadToKML.validate(argv) {
            setMessage(err)
            return nil
        }
        return argv
    }

    private func addToBatch() {
        guard check(forms.mode) != nil else { return }
        setMessage(forms.addToBatch(forms.mode), ok: true)
    }

    private func run() {
        guard !jobs.isRunning else { setMessage("A run is already in progress."); return }
        let m = forms.mode
        guard var argv = check(m) else { return }
        let label: String
        switch m {
        case .road: label = "Road: \(forms.road.road)"
        case .track: label = "GPS history"
        case .xml: label = "OSM way"
        case .batch:
            let url = jobs.inputsDirectory.appendingPathComponent("batch.csv")
            do { try BatchRows.csv(forms.batch).write(to: url, atomically: true, encoding: .utf8) } catch {
                setMessage("Couldn't write the batch file: \(error.localizedDescription)")
                return
            }
            argv = ["--batch", jobs.argPath(url)] + argv
            label = "Batch of \(forms.batch.count)"
        }
        clearMessage()
        if jobs.run(argv, label: label) != nil { showRun = true }
    }

    private func saveCSVFile() -> URL? {
        guard !forms.batch.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trips.csv")
        try? BatchRows.csv(forms.batch).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var importTypes: [UTType] {
        switch importKind {
        case .csv: return [.commaSeparatedText, .plainText, .text]
        default: return [.item]
        }
    }

    private func imported(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let e) = result { setMessage("Couldn't open the file: \(e.localizedDescription)") }
            return
        }
        switch importKind {
        case .track:
            var added = 0
            for u in urls {
                do {
                    let local = try jobs.importFile(u)
                    let p = jobs.argPath(local)
                    if !forms.track.files.contains(p) { forms.track.files.append(p); added += 1 }
                } catch {
                    setMessage("Couldn't copy \(u.lastPathComponent): \(error.localizedDescription)")
                    return
                }
            }
            setMessage("Added \(added) file(s).", ok: true)
        case .xml:
            guard let u = urls.first else { return }
            do {
                forms.xml.file = jobs.argPath(try jobs.importFile(u))
                forms.xml.kind = .file
                setMessage("Using \(u.lastPathComponent).", ok: true)
            } catch {
                setMessage("Couldn't copy \(u.lastPathComponent): \(error.localizedDescription)")
            }
        case .csv:
            guard let u = urls.first else { return }
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: u, encoding: .utf8) else {
                setMessage("Couldn't read \(u.lastPathComponent).")
                return
            }
            let rows = BatchRows.parse(text)
            if rows.isEmpty { setMessage("\(u.lastPathComponent) has no rows."); return }
            forms.batch += rows
            setMessage("Added \(rows.count) row(s) from \(u.lastPathComponent).", ok: true)
        }
    }
}

extension Color {
    /// Road-marking yellow, the browser UI's accent.
    static let roadMarking = Color(red: 0xF2 / 255, green: 0xB7 / 255, blue: 0x05 / 255)
}

// MARK: - Shared pieces

/// A text field that shows a red edge when the form marked it as a problem.
struct FormField: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var invalid = false
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .words

    var body: some View {
        LabeledContent {
            TextField(title, text: $text, prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(capitalization)
                .autocorrectionDisabled()
        } label: {
            Text(title).foregroundStyle(invalid ? Color.red : Color.primary)
        }
    }
}

struct SourceSection: View {
    @Binding var source: SourceChoice
    let track: Bool

    var body: some View {
        Section("Data source") {
            Picker("Data source", selection: $source) {
                ForEach(SourceChoice.allCases) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title)
                        if let d = s.detail(track: track) {
                            Text(d).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(s)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

struct OutlinesPicker: View {
    @Binding var outlines: OutlineChoice
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mapped pavement outlines (OSM area:highway)").font(.subheadline)
            Picker("Outlines", selection: $outlines) {
                ForEach(OutlineChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

struct ShapeSection: View {
    @Binding var shape: ShapeOptions
    let bad: Set<String>
    @State private var open = false

    var body: some View {
        Section {
            DisclosureGroup("Width and output", isExpanded: $open) {
                FormField(title: "Extra lanes", text: $shape.lanes, prompt: "0", invalid: bad.contains("lanes"),
                          keyboard: .numbersAndPunctuation, capitalization: .never)
                FormField(title: "Left edge (m)", text: $shape.leftWidth, prompt: "auto", invalid: bad.contains("leftwidth"),
                          keyboard: .numbersAndPunctuation, capitalization: .never)
                FormField(title: "Right edge (m)", text: $shape.rightWidth, prompt: "auto", invalid: bad.contains("rightwidth"),
                          keyboard: .numbersAndPunctuation, capitalization: .never)
                FormField(title: "Output file name", text: $shape.output, prompt: "Automatic", capitalization: .never)
                FormField(title: "Notes", text: $shape.notes, prompt: "Shown in the KML description", capitalization: .sentences)
                Toggle("Remove holes from the polygons", isOn: $shape.stripInner)
                Toggle("Keep retrying when map servers are busy", isOn: $shape.wait)
            }
        } footer: {
            if open {
                Text("Edges are measured from the centerline in the direction the road was drawn. A negative value puts that edge on the other side of the centerline, e.g. left 8 and right −5 for a sidewalk strip.")
            }
        }
    }
}

/// A from/to field with a Pick-on-map button.
struct PointField: View {
    let title: String
    @Binding var text: String
    var prompt: String
    var invalid: Bool
    let pick: (String, Binding<String>) -> Void

    var body: some View {
        HStack {
            FormField(title: title, text: $text, prompt: prompt, invalid: invalid)
            Button {
                pick(title == "From" || title == "From point" ? "Start of the stretch" : "End of the stretch", $text)
            } label: {
                Image(systemName: "mappin.and.ellipse")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Pick \(title.lowercased()) on the map")
        }
    }
}

// MARK: - Road

struct RoadSections: View {
    @Binding var form: RoadForm
    let bad: Set<String>
    let pick: (String, Binding<String>) -> Void

    var body: some View {
        Section {
            FormField(title: "Road name", text: $form.road, prompt: "Cathedral Ave NW, I-95, MD 355", invalid: bad.contains("road"))
            HStack {
                FormField(title: "States", text: $form.state, prompt: "DC", invalid: bad.contains("state"), capitalization: .characters)
                StateMenu(text: $form.state)
            }
            FormField(title: "Counties", text: $form.county, prompt: "Montgomery County (MD)")
            FormField(title: "City", text: $form.city, prompt: "Austin", invalid: bad.contains("city"))
        } header: {
            Text("Road")
        } footer: {
            Text("States: comma-separated names or postal codes, e.g. MD, VA, DC; one with no county listed is searched statewide. Counties go with whichever listed state has them; add the state in brackets when two listed states share a county name. City narrows the OSM search and needs a single state.")
        }

        Section {
            PointField(title: "From", text: $form.from, prompt: "Calvert St NW", invalid: bad.contains("from"), pick: pick)
            PointField(title: "To", text: $form.to, prompt: "Nebraska Ave NW", invalid: bad.contains("to"), pick: pick)
        } header: {
            Text("Stretch")
        } footer: {
            Text("Leave both empty for the whole road. Each end is a cross street or a latitude,longitude point; the pin button picks a point on the map.")
        }

        SourceSection(source: $form.source, track: false)

        Section {
            Toggle("Fill intersections", isOn: $form.junctions)
            Toggle("Include connected ramps", isOn: $form.ramps)
            OutlinesPicker(outlines: $form.outlines)
        } header: {
            Text("Surface")
        } footer: {
            Text("Combining keeps the full buffered centerline as well, so each spot gets whichever is wider.")
        }

        ShapeSection(shape: $form.shape, bad: bad)
    }
}

struct StateItem: Identifiable {
    let abbr: String
    let name: String
    var id: String { abbr }
    static let all = AliasEngine.allStates.map { StateItem(abbr: $0.abbr, name: $0.name) }
}

/// Appends a state's postal code to a comma-separated list.
struct StateMenu: View {
    @Binding var text: String

    var body: some View {
        Menu {
            ForEach(StateItem.all) { s in
                Button("\(s.name) (\(s.abbr.uppercased()))") {
                    let parts = Planning.splitList(text)
                    if !parts.map({ $0.lowercased() }).contains(s.abbr) {
                        text = (parts + [s.abbr.uppercased()]).joined(separator: ", ")
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .accessibilityLabel("Add a state")
    }
}

// MARK: - GPS history

struct TrackSections: View {
    @Binding var form: TrackForm
    let bad: Set<String>
    let addFiles: () -> Void
    @ObservedObject private var recorder = LocationRecorder.shared
    @State private var sessions: [TrackSession] = []
    @State private var note: String?

    var body: some View {
        Section {
            ForEach(form.files, id: \.self) { f in
                Label((f as NSString).lastPathComponent, systemImage: f.hasSuffix("_Records.json") ? "record.circle" : "doc")
                    .lineLimit(1)
            }
            .onDelete { form.files.remove(atOffsets: $0) }
            Menu {
                if sessions.isEmpty { Text("No recordings yet") }
                ForEach(sessions) { s in
                    Button(s.startDate?.formatted(date: .abbreviated, time: .shortened) ?? s.name) { addRecording(s) }
                }
            } label: {
                Label("Add a recording", systemImage: "record.circle")
            }
            Button(action: addFiles) { Label("Add files…", systemImage: "folder") }
                .foregroundStyle(bad.contains("files") ? Color.red : Color.accentColor)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Files")
        } footer: {
            Text("Waytrace recordings, Timeline.json or location-history.json from the Google Maps app, older Takeout Records.json and Semantic Location History files, GPX, KML or GeoJSON tracks. Files are copied into Road KML › Inputs.")
        }
        .task(id: recorder.libraryRevision) { sessions = TrackStore.shared.sessions() }

        Section {
            Picker("Dates", selection: $form.dateKind) {
                ForEach(DateKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch form.dateKind {
            case .day: DatePicker("Day", selection: $form.day, displayedComponents: .date)
            case .month: DatePicker("Any day in the month", selection: $form.month, displayedComponents: .date)
            case .range:
                DatePicker("First day", selection: $form.rangeFrom, displayedComponents: .date)
                DatePicker("Last day", selection: $form.rangeTo, displayedComponents: .date)
                    .foregroundStyle(bad.contains("date") ? Color.red : Color.primary)
            case .all: EmptyView()
            }
        } header: {
            Text("Dates")
        } footer: {
            Text("Files covering more than 31 days need a date choice. Dates are in local time where you were. Selected: \(form.dateSpec)")
        }

        Section {
            Toggle("Driving", isOn: $form.drive)
            Toggle("Walking", isOn: $form.walk)
            Toggle("Cycling", isOn: $form.bike)
            Toggle("Mode unknown", isOn: $form.other)
        } header: {
            Text("Trips to include").foregroundStyle(bad.contains("modes") ? Color.red : Color.secondary)
        } footer: {
            Text("Flights, trains and ferries are always left out, and so are stops.")
        }

        SourceSection(source: $form.source, track: true)

        Section {
            Toggle("Fill intersections", isOn: $form.junctions)
            OutlinesPicker(outlines: $form.outlines)
        } header: {
            Text("Surface")
        } footer: {
            Text("Ramps you actually used are followed automatically.")
        }

        ShapeSection(shape: $form.shape, bad: bad)
    }

    private func addRecording(_ s: TrackSession) {
        do {
            let url = try RoadJobs.shared.recordingInput(s)
            let p = RoadJobs.shared.argPath(url)
            if !form.files.contains(p) { form.files.append(p) }
            if let start = s.startDate, form.dateKind == .day, form.files.count == 1 { form.day = start }
            note = "Added \(url.lastPathComponent)."
        } catch {
            note = "Couldn't read that recording: \(error.localizedDescription)"
        }
    }
}

// MARK: - OSM way

struct XMLSections: View {
    @Binding var form: XMLForm
    let bad: Set<String>
    let pick: (String, Binding<String>) -> Void
    let chooseFile: () -> Void

    var body: some View {
        Section {
            Picker("From", selection: $form.kind) {
                Text("OpenStreetMap link").tag(XMLForm.Kind.url)
                Text("File").tag(XMLForm.Kind.file)
            }
            .pickerStyle(.segmented)
            if form.kind == .url {
                FormField(title: "Link", text: $form.url, prompt: "https://www.openstreetmap.org/way/12188784",
                          invalid: bad.contains("url"), keyboard: .URL, capitalization: .never)
            } else {
                Button(action: chooseFile) {
                    Label(form.file.isEmpty ? "Choose file…" : (form.file as NSString).lastPathComponent, systemImage: "doc")
                }
                .foregroundStyle(bad.contains("file") ? Color.red : Color.accentColor)
            }
        } header: {
            Text("Way")
        } footer: {
            Text(form.kind == .url ? "A way or relation page, or an API link. It's switched to the /full version automatically."
                 : "A saved .osm or .xml file with the way's nodes.")
        }

        Section {
            FormField(title: "Road name filter", text: $form.road, prompt: "From the XML if empty")
            FormField(title: "State", text: $form.state, prompt: "For the filename", capitalization: .characters)
            PointField(title: "From point", text: $form.from, prompt: "lat,lon", invalid: bad.contains("from"), pick: pick)
            PointField(title: "To point", text: $form.to, prompt: "lat,lon", invalid: bad.contains("to"), pick: pick)
        } header: {
            Text("Optional")
        } footer: {
            Text("With a downloaded way, the ends of a stretch must be points rather than street names.")
        }

        ShapeSection(shape: $form.shape, bad: bad)
    }
}

// MARK: - Batch

struct BatchSections: View {
    @ObservedObject var forms: RoadFormStore
    let openCSV: () -> Void
    let saveCSV: URL?
    @Binding var confirmClear: Bool
    let message: (String, Bool) -> Void

    var body: some View {
        Section {
            if forms.batch.isEmpty {
                Text("No rows yet. Fill in the Road, GPS history or OSM way tab and choose Add to batch, or open a CSV.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(forms.batch.enumerated()), id: \.offset) { i, r in
                let s = BatchRows.summary(r)
                Button {
                    forms.edit(i)
                    message("Editing batch row \(i + 1). Change what you need, then choose Update row \(i + 1).", true)
                } label: {
                    HStack(alignment: .top) {
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.what).fontWeight(.semibold)
                            Text(s.kind).font(.caption).foregroundStyle(.secondary)
                            if !s.whereText.isEmpty { Text(s.whereText).font(.caption) }
                        }
                        Spacer()
                        if let e = forms.editing, e.index == i { Image(systemName: "pencil").foregroundStyle(Color.roadMarking) }
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { idx in
                forms.batch.remove(atOffsets: idx)
                forms.editing = nil
            }
            .onMove { from, to in
                forms.batch.move(fromOffsets: from, toOffset: to)
                forms.editing = nil
            }
        } header: {
            Text("Rows")
        } footer: {
            if !forms.batch.isEmpty { Text("Tap a row to edit it in its tab; swipe to remove.") }
        }

        Section {
            Button(action: openCSV) { Label("Open CSV…", systemImage: "tablecells") }
            if let saveCSV {
                ShareLink(item: saveCSV) { Label("Save as CSV", systemImage: "square.and.arrow.up") }
            }
            if !forms.batch.isEmpty {
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear all", systemImage: "trash") }
            }
        }

        Section("For every row") {
            Picker("Source for rows that don't set one", selection: $forms.batchSource) {
                Text("Default (OSM, with TIGER/Line fallback)").tag(SourceChoice?.none)
                Text("OSM only").tag(SourceChoice?.some(.osm))
                Text("TIGER/Line only").tag(SourceChoice?.some(.tiger))
                Text("OSM and TIGER/Line, combined").tag(SourceChoice?.some(.both))
            }
            Toggle("Keep retrying when map servers are busy", isOn: $forms.batchWait)
        }
    }
}
