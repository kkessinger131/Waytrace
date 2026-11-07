import Foundation

/// A bad --state/--county value and the like (Python's ValueError).
public struct InputError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// abbr: "md" (nil when --source xml was given a state it doesn't know); typed: as entered.
public struct StateInfo: Hashable {
    public var abbr: String?
    public var name: String
    public var typed: String
}

/// One area to search; county nil = the whole state.
public struct SearchArea: Hashable {
    public var state: StateInfo
    public var county: String?
    public var fips: String?
}

public enum Planning {
    public static let dcFIPS = "11001"
    static let countySuffixes = [" county", " parish", " borough", " municipality", " census area",
                                 " city and borough", " planning region"]
    public static let countyTableMaxAgeDays = 365

    /// _split_list: a comma- or semicolon-delimited option value, cleaned.
    public static func splitList(_ value: String?) -> [String] {
        (value ?? "").split(whereSeparator: { $0 == "," || $0 == ";" }).map { Py.strip(String($0)) }.filter { !$0.isEmpty }
    }

    /// _county_norm: case, periods, apostrophes, Saint -> St.
    public static func countyNorm(_ name: String) -> String {
        var s = Py.strip(name).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "-", with: " ")
        s = Re.sub(Re.compile("^saint\\s+"), "st ", s)
        s = Re.sub(Re.compile("^sainte\\s+"), "ste ", s)
        return Py.strip(Re.sub(Re.compile("\\s+"), " ", s))
    }

    /// {state abbr: {normalized county name: fips}}
    static let countyIndex: [String: [String: String]] = {
        var idx: [String: [String: String]] = [:]
        for (st, name, fips) in countyFIPSTable {
            let k = countyNorm(name)
            if idx[st]?[k] == nil { idx[st, default: [:]][k] = fips }
        }
        return idx
    }()

    /// _check_county_fips_age: a reminder if the county table is over a year past its date.
    public static func checkCountyTableAge(_ stamp: String?, today: DayDate) -> String? {
        guard let stamp, !stamp.isEmpty else {
            return "Reminder: the county table has no update date. Add one after checking it against the Census Bureau's current county list."
        }
        guard let updated = DayDate(iso: stamp) else {
            return "Reminder: can't read the county table's update date \(AliasEngine.pyRepr(stamp))."
        }
        let age = today.ordinal - updated.ordinal
        if age > countyTableMaxAgeDays {
            return "Reminder: the county table (county_fips.py) was last checked \(updated) (\(age) days ago). "
                + "Counties occasionally change (e.g. Connecticut's 2022 switch to planning regions); "
                + "refresh it from the Census Bureau's county list and update its date."
        }
        return nil
    }

    /// _lookup_county: (fips, matched name) or (nil, candidate names).
    public static func lookupCounty(_ county: String, _ abbr: String, allowPartial: Bool = true)
        -> (fips: String?, matched: String?, candidates: [String]) {
        if abbr == "dc" { return (dcFIPS, "district of columbia", []) }
        let table = countyIndex[abbr] ?? [:]
        let name = countyNorm(county)
        var bare = name
        for sfx in countySuffixes where name.hasSuffix(sfx) {
            bare = Py.strip(String(name.dropLast(sfx.count)))
            break
        }
        for cand in [name, bare] + countySuffixes.map({ bare + $0 }) {
            if let f = table[cand] { return (f, cand, []) }
        }
        if !allowPartial || bare.isEmpty { return (nil, nil, []) }
        var hits = table.keys.filter { $0.hasPrefix(bare + " ") }.sorted()
        if hits.isEmpty { hits = table.keys.filter { $0.contains(bare) }.sorted() }
        if hits.count == 1 { return (table[hits[0]], hits[0], []) }
        return (nil, nil, hits)
    }

    /// _resolve_county_fips
    static func resolveCountyFIPS(_ county: String, _ state: String) throws -> String {
        guard let abbr = AliasEngine.resolveState(state) else {
            throw InputError("State not recognised: '\(state)'. Use a name or postal code, e.g. 'California' or 'CA'.")
        }
        let r = lookupCounty(county, abbr)
        if let f = r.fips { return f }
        let whereName = AliasEngine.stateName(abbr)
        if !r.candidates.isEmpty {
            throw InputError("County '\(county)' is ambiguous in \(whereName): \(r.candidates.joined(separator: ", ")).")
        }
        throw InputError("County '\(county)' not found in \(whereName). Check spelling — try 'Marin County' or just 'Marin'.")
    }

    public static func areaLabel(_ a: SearchArea, city: String = "") -> String {
        if a.state.abbr == "dc" { return city.isEmpty ? "District of Columbia" : "\(city), District of Columbia" }
        if let c = a.county { return "\(c), \(a.state.name)" }
        if !city.isEmpty { return "\(city), \(a.state.name)" }
        return "\(a.state.name) (statewide)"
    }

    /// _safe_name
    static func safeName(_ s: String?) -> String {
        let t = Re.sub(Re.compile("[^A-Za-z0-9._-]+"), "_", s ?? "")
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
    }

    public static let maxFilenameLength = 120

    /// default_output_name: <road>[_<from>_to_<to>][_<city or county>]_<state(s)>_<source>.kml
    public static func defaultOutputName(_ road: String, city: String, states: [StateInfo], areas: [SearchArea],
                                         sourceTags: [String], clip: (String, String)? = nil) -> String {
        let suffix = (sourceTags.isEmpty ? "" : "_" + sourceTags.joined(separator: "_")) + ".kml"
        var parts = [safeName(road)]
        if let clip { parts.append("\(safeName(clip.0))_to_\(safeName(clip.1))") }
        let counties = areas.compactMap(\.county)
        if !city.isEmpty { parts.append(safeName(city)) } else if counties.count == 1 { parts.append(safeName(counties[0])) }
        if states.count == 1 {
            parts.append(safeName(states[0].typed))
        } else if states.count > 1 {
            parts.append(states.map { ($0.abbr ?? safeName($0.typed)).uppercased() }.joined(separator: "_"))
        }
        var stem = parts.filter { !$0.isEmpty }.joined(separator: "_")
        if stem.isEmpty { stem = "road" }
        let budget = maxFilenameLength - suffix.count
        if stem.count > budget {
            stem = String(stem.prefix(budget)).trimmingTrailing(in: "._-")
            if stem.isEmpty { stem = "road" }
        }
        return stem + suffix
    }

    /// _parse_sources: ["xml"] + path, ["auto"], or a non-empty subset of ["osm", "tiger"].
    public static func parseSources(_ tokens: [String]) throws -> (modes: [String], xml: String) {
        if let first = tokens.first, Py.strip(first).lowercased() == "xml" {
            if tokens.count < 2 {
                throw UsageError("--source xml requires a URL or file path, e.g.\n  --source xml \"https://www.openstreetmap.org/api/0.6/way/12188784\"")
            }
            return (["xml"], Py.strip(tokens.dropFirst().joined(separator: " ")))
        }
        let modes = Re.split(Re.compile("[,+\\s]+"), Py.strip(tokens.joined(separator: " ")).lowercased()).filter { !$0.isEmpty }
        if modes.isEmpty { throw UsageError("--source needs a value (osm, tiger, auto, or xml <url-or-path>)") }
        if modes.contains("xml") { throw UsageError("--source xml can't be combined with other sources") }
        let bad = modes.filter { !["osm", "tiger", "auto"].contains($0) }
        if !bad.isEmpty {
            throw UsageError("--source: invalid mode(s) \(PyFmt.list(bad)) (choose from osm, tiger, auto, xml)")
        }
        if modes.contains("auto") {
            if Set(modes).count > 1 {
                throw UsageError("--source auto already tries OSM and falls back to TIGER/Line; use --source osm,tiger to search both everywhere")
            }
            return (["auto"], "")
        }
        return (["osm", "tiger"].filter { modes.contains($0) }, "")
    }

    static let latLonRe = Re.compile("^\\s*(-?\\d+(?:\\.\\d+)?)\\s*,\\s*(-?\\d+(?:\\.\\d+)?)\\s*$")

    /// parse_clip_point: "38.93,-77.07" -> (lat, lon); a street name -> nil.
    public static func parseClipPoint(_ text: String) throws -> (lat: Double, lon: Double)? {
        guard let g = Re.groups(latLonRe, text), let a = g[1].flatMap(Double.init), let b = g[2].flatMap(Double.init) else {
            return nil
        }
        if !((-90...90).contains(a) && (-180...180).contains(b)) {
            throw InputError("'\(text)' isn't a valid latitude,longitude.")
        }
        return (a, b)
    }
}

extension String {
    func trimmingTrailing(in chars: String) -> String {
        var s = Substring(self)
        while let c = s.last, chars.contains(c) { s = s.dropLast() }
        return String(s)
    }
}

extension RoadToKML {
    /// The county table's reminder, once per engine (road_to_kml prints it once per run).
    func countyTableReminder() {
        if fipsReminderShown { return }
        fipsReminderShown = true
        if let r = Planning.checkCountyTableAge(countyFIPSUpdated, today: DayDate(today())) { log("  \(r)") }
    }

    /// _parse_states: "Maryland, VA, DC" -> states. "Washington, DC" is the District of Columbia.
    func parseStates(_ value: String) throws -> [StateInfo] {
        let parts = Planning.splitList(value)
        var states: [StateInfo] = [], seen = Set<String>()
        var i = 0
        while i < parts.count {
            var part = parts[i]
            if i + 1 < parts.count && part.lowercased() == "washington" && AliasEngine.resolveState(parts[i + 1]) == "dc" {
                log("  Note: reading \"Washington, DC\" as the District of Columbia (use \"WA, DC\" to search both).")
                part = "\(part) \(parts[i + 1])"
                i += 1
            }
            guard let abbr = AliasEngine.resolveState(part) else {
                throw InputError("State not recognised: '\(part)'. Use a name or postal code, e.g. 'Texas' or 'TX'.")
            }
            if !seen.contains(abbr) {
                seen.insert(abbr)
                states.append(StateInfo(abbr: abbr, name: AliasEngine.stateName(abbr), typed: part))
            }
            i += 1
        }
        return states
    }

    func lookupCounty(_ county: String, _ abbr: String, allowPartial: Bool = true)
        -> (fips: String?, matched: String?, candidates: [String]) {
        if abbr != "dc" { countyTableReminder() }
        return Planning.lookupCounty(county, abbr, allowPartial: allowPartial)
    }

    static let qualifiedCountyRe = Re.compile("^(.*?)\\s*\\(([^)]*)\\)\\s*$", .dotMatchesLineSeparators)

    /// _plan_search_areas: --state and --county -> the areas to search.
    func planSearchAreas(_ states: [StateInfo], _ countyValue: String) throws -> [SearchArea] {
        var listed: [String: StateInfo] = [:]
        for s in states { if let a = s.abbr { listed[a] = s } }

        // 1. county entries, with optional state qualifiers
        var entries: [(name: String, q: String?)] = []
        for tok in Planning.splitList(countyValue) {
            if let g = Re.groups(RoadToKML.qualifiedCountyRe, tok), let name = g[1], !name.isEmpty {
                guard let q = AliasEngine.resolveState(g[2]) else {
                    throw InputError("Unknown state '\(g[2] ?? "")' in --county entry '\(tok)'.")
                }
                entries.append((Py.strip(name), q))
                continue
            }
            let q = AliasEngine.resolveState(tok)
            if let q, q != "dc", let last = entries.last, last.q == nil,
               !states.contains(where: { $0.abbr != "dc" && $0.abbr != nil && lookupCounty(tok, $0.abbr!, allowPartial: false).fips != nil }) {
                entries[entries.count - 1].q = q          // "Montgomery County, MD"
                continue
            }
            entries.append((tok, nil))
        }

        // 2. each county to a state
        var byState: [String: [String]] = [:]
        for s in states { if let a = s.abbr { byState[a] = [] } }
        for (name, q) in entries {
            var abbr: String
            if let q {
                if listed[q] == nil {
                    throw InputError("--county '\(name) (\(q.uppercased()))' is in \(AliasEngine.stateName(q)), which isn't in --state.")
                }
                abbr = q
            } else if states.count == 1, let a = states[0].abbr {
                abbr = a
            } else if AliasEngine.resolveState(name) == "dc" && listed["dc"] != nil {
                abbr = "dc"
            } else {
                let candidates = states.compactMap(\.abbr).filter { $0 != "dc" }
                let exact = candidates.filter { lookupCounty(name, $0, allowPartial: false).fips != nil }
                let found = !exact.isEmpty ? exact : candidates.filter { lookupCounty(name, $0).fips != nil }
                if found.count > 1 {
                    let opts = found.map { "'\(name) (\($0.uppercased()))'" }.joined(separator: ", ")
                    throw InputError("County '\(name)' exists in more than one listed state "
                        + "(\(found.map { AliasEngine.stateName($0) }.joined(separator: ", "))). "
                        + "Qualify it, e.g. \(opts). To search more than one, list each.")
                }
                guard let f = found.first else {
                    throw InputError("County '\(name)' wasn't found in any listed state "
                        + "(\(states.map(\.name).joined(separator: ", "))). Check the spelling, "
                        + "or qualify it like '\(name) (MD)'.")
                }
                abbr = f
            }
            byState[abbr, default: []].append(name)
        }

        // 3. the areas
        var areas: [SearchArea] = []
        for s in states {
            guard let a = s.abbr else { continue }
            if a == "dc" {
                if !(byState["dc"] ?? []).isEmpty {
                    log("  Note: DC is a single county-equivalent (FIPS 11001); searching all of DC.")
                }
                areas.append(SearchArea(state: s, county: nil, fips: Planning.dcFIPS))
                continue
            }
            let names = byState[a] ?? []
            if names.isEmpty {
                areas.append(SearchArea(state: s, county: nil, fips: nil))
                continue
            }
            var seen = Set<String>()
            for name in names {
                let fips = lookupCounty(name, a).fips
                let key = fips ?? Planning.countyNorm(name)
                if seen.contains(key) { continue }
                seen.insert(key)
                areas.append(SearchArea(state: s, county: name, fips: fips))
            }
        }
        return areas
    }

    /// _variants_preview: "A, B, C (+N more)"
    func variantsPreview(_ road: String, _ state: String?, shown: Int = 6) -> String {
        let total = AliasEngine.countVariants(road, state: state)
        let sample = AliasEngine.expandVariants(road, state: state, limit: shown)
        let more = total > sample.count ? " (+\(total - sample.count) more)" : ""
        return sample.joined(separator: ", ") + more
    }
}
