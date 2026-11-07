import Foundation

extension Tracks {
    /// Stable sort (Python's sorted).
    static func stableSorted<T>(_ xs: [T], by less: (T, T) -> Bool) -> [T] {
        xs.enumerated().sorted { a, b in
            less(a.element, b.element) ? true : less(b.element, a.element) ? false : a.offset < b.offset
        }.map(\.element)
    }

    /// bisect.bisect_right / bisect_left on a sorted array.
    static func bisectRight(_ keys: [Stamp], _ x: Stamp) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if x < keys[m] { hi = m } else { lo = m + 1 } }
        return lo
    }

    static func bisectLeft(_ keys: [Stamp], _ x: Stamp) -> Int {
        var lo = 0, hi = keys.count
        while lo < hi { let m = (lo + hi) / 2; if keys[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// _localize: give UTC-stamped points the UTC offset of the nearest activity or visit
    /// (the iPhone export stamps path points in UTC but activities and visits locally).
    static func localize(_ points: [TrackPoint], _ acts: [Activity], _ visits: [Visit], window: Double = 12 * 3600) -> [TrackPoint] {
        var refs: [Stamp] = []
        for a in acts { refs += [a.start, a.end] }
        for v in visits { refs += [v.start, v.end] }
        refs = stableSorted(refs.filter { $0.offset != 0 }, by: <)
        if refs.isEmpty { return points }
        return points.map { p0 in
            var p = p0
            if let t = p.t, t.offset == 0 {
                let i = bisectLeft(refs, t)
                let near = [i - 1, i].filter { $0 >= 0 && $0 < refs.count }.map { refs[$0] }
                var best = near[0]
                for r in near.dropFirst() where abs(r.seconds(since: t)) < abs(best.seconds(since: t)) { best = r }
                if abs(best.seconds(since: t)) <= window { p.t = Stamp(t.date, offset: best.offset) }
            }
            return p
        }
    }

    /// _assign_modes: the activity mode for points without one.
    static func assignModes(_ points: [TrackPoint], _ activities: [Activity]) -> [TrackPoint] {
        if activities.isEmpty { return points }
        let acts = stableSorted(activities) { a, b in
            a.start != b.start ? a.start < b.start : a.end != b.end ? a.end < b.end : (a.mode ?? "") < (b.mode ?? "")
        }
        let starts = acts.map(\.start)
        return points.map { p0 in
            var p = p0
            if let t = p.t {
                var i = bisectRight(starts, t) - 1
                while i >= 0 && acts[i].start <= t {
                    if acts[i].end >= t {
                        if (p.mode ?? "").isEmpty { p.mode = acts[i].mode }
                        p.act = i
                        break
                    }
                    i -= 1
                }
            }
            return p
        }
    }

    static let visitMoveM = 1000.0
    static let visitMinSpeed = 0.8

    static func length(_ pts: [TrackPoint]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
    }

    /// _drop_visits: drop the points recorded while staying somewhere — unless the "visit"
    /// was really travel (its points spread over more than 1 km at 0.8 m/s or more), when
    /// they are kept and given a travel mode.
    static func dropVisits(_ points: [TrackPoint], _ visits: [Visit], margin: Double = 120, activities: [Activity] = [],
                           log: (String) -> Void) -> [TrackPoint] {
        if visits.isEmpty { return points }
        let vs = stableSorted(visits) { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        let starts = vs.map(\.start)
        var whereIdx: [Int?] = []
        var inside: [Int: [Int]] = [:]
        for (k, p) in points.enumerated() {
            var hit: Int?
            if let t = p.t {
                var i = bisectRight(starts, t) - 1
                while i >= 0 {
                    let (s, e) = vs[i]
                    if s <= t && t <= e {
                        inside[i, default: []].append(k)
                        if hit == nil && s.adding(seconds: margin) < t && t < e.adding(seconds: -margin) { hit = i }
                    }
                    if e < t.adding(seconds: -2 * 86400) { break }
                    i -= 1
                }
            }
            whereIdx.append(hit)
        }

        func pathPoints(_ ks: [Int]) -> [TrackPoint] {
            let ps = stableSorted(ks.map { points[$0] }.filter { ($0.mode ?? "").isEmpty }) { $0.t! < $1.t! }
            var out: [TrackPoint] = []
            for (j, p) in ps.enumerated() {
                let nb = [j > 0 ? ps[j - 1] : nil, j + 1 < ps.count ? ps[j + 1] : nil].compactMap { $0 }
                if !nb.isEmpty && nb.allSatisfy({ dist(p, $0) > 60 * max(1, abs(p.t!.seconds(since: $0.t!))) }) { continue }
                out.append(p)
            }
            return out
        }
        func spread(_ ps: [TrackPoint]) -> Double {
            haversine(ps.map(\.lat).min()!, ps.map(\.lon).min()!, ps.map(\.lat).max()!, ps.map(\.lon).max()!)
        }
        func travelled(_ ks: [Int]) -> Bool {
            let ps = pathPoints(ks)
            if ps.count < 3 || spread(ps) <= visitMoveM { return false }
            let secs = max(1, ps.last!.t!.seconds(since: ps[0].t!))
            return length(ps) / secs >= visitMinSpeed
        }

        let moving = inside.keys.sorted().filter { travelled(inside[$0]!) }
        var runs: [(start: Stamp, idx: [Int], end: Stamp)] = []
        for i in moving {
            if let last = runs.last, vs[i].start <= last.end.adding(seconds: 120) {
                runs[runs.count - 1].idx.append(i)
                runs[runs.count - 1].end = max(last.end, vs[i].end)
            } else {
                runs.append((vs[i].start, [i], vs[i].end))
            }
        }

        var keepAs: [Int: (String, Int)] = [:]
        for (n, run) in runs.enumerated() {
            let ks = stableSorted(Array(Set(run.idx.flatMap { inside[$0]! })).sorted()) { points[$0].t! < points[$1].t! }
            let clean = pathPoints(ks)
            let d = length(clean)
            let secs = max(1, clean.last!.t!.seconds(since: clean[0].t!))
            let mode = movingVisitMode(d / secs, run.start, run.end, activities)
            let idx = Set(run.idx)
            for k in ks where whereIdx[k].map(idx.contains) ?? (points[k].mode ?? "").isEmpty {
                keepAs[k] = (mode, -(n + 1))
            }
            let cat = TrackRules.category(mode) ?? "other"
            let what = cat == "other" ? "unknown travel" : ["drive": "driving", "walk": "walking", "bike": "cycling"][cat] ?? cat
            log("  Note: Timeline marked \(run.start.localTime.format("yyyy-MM-dd HH:mm"))-\(run.end.localTime.format("HH:mm")) "
                + "as a stop, but the GPS moved \(PyFmt.f(d / 1000, 1)) km (about \(PyFmt.f(d / secs * 3.6, 0)) km/h); "
                + "treating it as \(what).")
        }

        var out: [TrackPoint] = []
        for (k, p) in points.enumerated() {
            if let (mode, act) = keepAs[k] {
                if (p.mode ?? "").isEmpty {
                    var q = p
                    q.mode = mode
                    q.act = act
                    out.append(q)
                } else {
                    out.append(p)
                }
            } else if whereIdx[k] == nil {
                out.append(p)
            }
        }
        return out
    }

    /// _drop_spikes: single points impossibly far from both neighbours (faster than vmax
    /// m/s each way) whose neighbours join up.
    static func dropSpikes(_ pts: [TrackPoint], vmax: Double = 90.0) -> [TrackPoint] {
        var out: [TrackPoint] = []
        for (j, p) in pts.enumerated() {
            if j > 0 && j < pts.count - 1 {
                let a = pts[j - 1], b = pts[j + 1]
                let far = [a, b].map { dist(p, $0) > vmax * max(1, abs(p.t!.seconds(since: $0.t!))) }
                if far.allSatisfy({ $0 }) && dist(a, b) <= vmax * max(1, b.t!.seconds(since: a.t!)) { continue }
            }
            out.append(p)
        }
        return out
    }

    /// _moving_visit_mode: a travel mode for a mislabeled visit from its average speed (m/s)
    /// and the activities just before and after it.
    static func movingVisitMode(_ speed: Double, _ start: Stamp, _ end: Stamp, _ activities: [Activity], near: Double = 300) -> String {
        var around = Set<String>()
        for a in activities where abs(a.end.seconds(since: start)) <= near || abs(a.start.seconds(since: end)) <= near {
            if let c = TrackRules.category(a.mode), ["drive", "walk", "bike"].contains(c) { around.insert(c) }
        }
        if speed >= 8.0 { return "IN_PASSENGER_VEHICLE" }
        if speed > 2.5 && around.contains("drive") { return "IN_PASSENGER_VEHICLE" }
        if speed > 2.5 && around.contains("bike") { return "CYCLING" }
        if speed <= 2.5 { return "WALKING" }
        return "UNKNOWN_TRAVEL"
    }

    /// _downsample: at least the category's spacing between kept points, plus the last point.
    static func downsample(_ pts: [TrackPoint], _ category: String) -> [TrackPoint] {
        guard let first = pts.first else { return pts }
        let spacing = TrackRules.spacing[category] ?? 15.0
        var out = [first]
        var lastIndex = 0
        for (i, p) in pts.enumerated().dropFirst() where dist(out.last!, p) >= spacing {
            out.append(p)
            lastIndex = i
        }
        if lastIndex != pts.count - 1 && pts.count > 1 { out.append(pts.last!) }
        return out
    }

    public static func tripLengthKm(_ t: Trip) -> Double { length(t.points) / 1000 }

    /// load_trips: read files, filter by date and mode, and split into trips.
    static func loadTrips(_ files: [(path: String, data: Data)], dateSpec: String?, travelModes: [String] = TrackRules.categories,
                          gapMinutes: Double = 10, maxDaysWithoutDate: Int = 31, log: (String) -> Void) throws -> [Trip] {
        var points: [TrackPoint] = [], activities: [Activity] = [], visits: [Visit] = []
        for f in files {
            let (r, kind) = try readTrackFile(f.data, path: f.path)
            log("  \((f.path as NSString).lastPathComponent): \(kind), \(r.points.count) point(s)")
            points += r.points
            activities += r.activities
            visits += r.visits
        }
        points = localize(points, activities, visits)
        let rng = try parseDateSpec(dateSpec)
        let timed = points.compactMap(\.t)
        if rng == nil && dateSpec == nil && !timed.isEmpty {
            let days = Set(timed.map(\.localDate))
            if days.count > maxDaysWithoutDate {
                throw InputError("These files cover \(days.count) days (\(days.min()!) to \(days.max()!)). "
                    + "Pick the dates to map with --date, e.g. --date 2026-10-30 or "
                    + "--date 2026-10-01..2026-10-31 (or --date all).")
            }
        }
        if let rng {
            if points.contains(where: { $0.t == nil }) {
                log("  Note: some points have no time, so --date can't filter them; they're kept.")
            }
            points = points.filter { p in
                guard let t = p.t else { return true }
                let d = t.localDate
                return (rng.first.map { d >= $0 } ?? true) && (rng.last.map { d <= $0 } ?? true)
            }
        }
        points = assignModes(points, activities)
        points = dropVisits(points, visits, activities: activities, log: log)

        let wanted = Set(travelModes)
        var segOrder: [String] = [], groups: [String: [TrackPoint]] = [:]
        for p in points {
            if groups[p.seg] == nil { segOrder.append(p.seg) }
            groups[p.seg, default: []].append(p)
        }
        var trips: [Trip] = []
        for seg in segOrder {
            var pts = groups[seg]!
            if pts.allSatisfy({ $0.t != nil }) {
                pts = stableSorted(pts) { $0.t! < $1.t! }
                pts = dropSpikes(pts)
            }
            var cur: [TrackPoint] = []
            var cat: String?
            func flush() {
                if cur.count >= 2 {
                    let c = cat ?? "other"
                    if wanted.contains(c) { trips.append(Trip(c, downsample(cur, c))) }
                }
            }
            var prev: TrackPoint?
            for p in pts {
                let pc = TrackRules.category(p.mode)
                if pc == "skip" {
                    flush()
                    cur = []; cat = nil; prev = nil
                    continue
                }
                var split = false
                if let prev {
                    let d = dist(prev, p)
                    if let t = p.t, let pt = prev.t {
                        let dt = t.seconds(since: pt)
                        let sameActivity = p.act != nil && p.act == prev.act
                        if (dt > gapMinutes * 60 && !sameActivity) || (dt > 0 && d / dt > 90) || (dt <= 0 && d > 2000) { split = true }
                    } else if d > 5000 {
                        split = true
                    }
                    if let pc, let cat, pc != cat { split = true }
                }
                if split {
                    flush()
                    cur = []; cat = nil
                }
                cur.append(p)
                if pc != nil && cat == nil { cat = pc }
                prev = p
            }
            flush()
        }
        trips = trips.filter { $0.points.count >= 2 && length($0.points) >= 50 }
        trips = stableSorted(trips) { a, b in
            (a.points[0].t?.date ?? .distantPast) < (b.points[0].t?.date ?? .distantPast)
        }
        for i in trips.indices { trips[i].uid = i + 1 }
        return trips
    }

    // MARK: - Map cells and download boxes

    public static let cellDeg = 0.005
    static let radiusSteps = [150.0, 300.0, 600.0]
    public static let maxRequestKm2 = 80.0

    struct Cell: Hashable, Comparable {
        let r: Int, c: Int
        static func < (a: Cell, b: Cell) -> Bool { a.r != b.r ? a.r < b.r : a.c < b.c }
    }

    static func corridorRadius(_ gap: Double) -> Double {
        let want = 120.0 + 0.3 * gap
        return radiusSteps.first { $0 >= want } ?? radiusSteps.last!
    }

    /// trip_cells: grid cells covering a trip's corridor.
    static func tripCells(_ trip: Trip) -> Set<Cell> {
        var cells = Set<Cell>()
        var pts = trip.points
        if pts.count == 1 { pts = pts + pts }
        for (a, b) in zip(pts, pts.dropFirst()) {
            let gap = dist(a, b)
            let r = corridorRadius(gap)
            let n = max(1, Int(gap / 100))
            for k in 0...n {
                let lat = a.lat + (b.lat - a.lat) * Double(k) / Double(n)
                let lon = a.lon + (b.lon - a.lon) * Double(k) / Double(n)
                let dlat = r / 111320.0
                let dlon = r / (111320.0 * max(0.2, cos(lat * .pi / 180)))
                for row in Int(floor((lat - dlat) / cellDeg))...Int(floor((lat + dlat) / cellDeg)) {
                    for col in Int(floor((lon - dlon) / cellDeg))...Int(floor((lon + dlon) / cellDeg)) {
                        cells.insert(Cell(r: row, c: col))
                    }
                }
            }
        }
        return cells
    }

    static func round6(_ v: Double) -> Double { (v * 1e6).rounded(.toNearestOrEven) / 1e6 }

    /// cells_to_boxes: one (south, west, north, east) box per run of neighbouring cells in a row.
    static func cellsToBoxes(_ cells: Set<Cell>) -> [Box] {
        var rows: [Int: [Int]] = [:]
        for c in cells { rows[c.r, default: []].append(c.c) }
        var boxes: [Box] = []
        for r in rows.keys.sorted() {
            let cols = rows[r]!.sorted()
            var start = cols[0], prev = cols[0]
            for c in cols.dropFirst().map({ Optional($0) }) + [nil] {
                if let c, c == prev + 1 { prev = c; continue }
                boxes.append((round6(Double(r) * cellDeg), round6(Double(start) * cellDeg),
                              round6(Double(r + 1) * cellDeg), round6(Double(prev + 1) * cellDeg)))
                if let c { start = c; prev = c }
            }
        }
        return boxes
    }

    static func pointCell(_ lat: Double, _ lon: Double) -> Cell { Cell(r: Int(floor(lat / cellDeg)), c: Int(floor(lon / cellDeg))) }

    /// line_cells: cells a polyline of (lat, lon) points passes through.
    static func lineCells(_ coords: [LatLon], step: Double = 100) -> Set<Cell> {
        var cells = Set<Cell>()
        for (a, b) in zip(coords, coords.dropFirst()) {
            let n = max(1, Int(haversine(a.lat, a.lon, b.lat, b.lon) / step))
            for k in 0...n {
                cells.insert(pointCell(a.lat + (b.lat - a.lat) * Double(k) / Double(n), a.lon + (b.lon - a.lon) * Double(k) / Double(n)))
            }
        }
        if coords.count == 1 { cells.insert(pointCell(coords[0].lat, coords[0].lon)) }
        return cells
    }

    static func dilateCells(_ cells: Set<Cell>, steps: Int = 1) -> Set<Cell> {
        var out = cells
        for _ in 0..<steps {
            var next = out
            for c in out { for dr in -1...1 { for dc in -1...1 { next.insert(Cell(r: c.r + dr, c: c.c + dc)) } } }
            out = next
        }
        return out
    }

    public static func boxAreaKm2(_ b: Box) -> Double {
        (b.n - b.s) * 111.32 * (b.e - b.w) * 111.32 * cos((b.n + b.s) / 2 * .pi / 180)
    }

    /// batch_boxes: requests of at most ~maxKm2 each.
    static func batchBoxes(_ boxes: [Box], maxKm2: Double = maxRequestKm2) -> [[Box]] {
        var batches: [[Box]] = [], cur: [Box] = []
        var area = 0.0
        for b in boxes {
            let a = boxAreaKm2(b)
            if !cur.isEmpty && area + a > maxKm2 {
                batches.append(cur)
                cur = []
                area = 0
            }
            cur.append(b)
            area += a
        }
        if !cur.isEmpty { batches.append(cur) }
        return batches
    }

    /// group_trips: consecutive trips grouped so each group needs one road download.
    static func groupTrips(_ trips: [Trip], maxKm: Double = 60, maxJumpKm: Double = 100) -> [[Trip]] {
        var groups: [[Trip]] = [], cur: [Trip] = []
        var km = 0.0
        for t in trips {
            let tk = tripLengthKm(t)
            var jump = 0.0
            if let last = cur.last { jump = dist(last.points.last!, t.points[0]) / 1000 }
            if !cur.isEmpty && (km + tk > maxKm || jump > maxJumpKm) {
                groups.append(cur)
                cur = []
                km = 0
            }
            cur.append(t)
            km += tk
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups
    }
}
