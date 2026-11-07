import Foundation

// Port of the engine half of road_aliases.py. Given a road name, works out the common ways
// the same road can be written, in both directions, and produces:
//   * overpassTagRegex(name, state)  - one POSIX regular expression covering every alias
//   * RoadMatcher(name, state)        - same-road comparison for TIGER/Line names and OSM tags

// MARK: - Python string semantics used by the original

enum Py {
    /// Python str.isalnum() for one code point.
    static func isAlnum(_ s: Unicode.Scalar) -> Bool { isAlpha(s) || s.properties.numericType != nil }

    /// Python str.isalpha() for one code point (Unicode letter categories).
    static func isAlpha(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    static func isAlpha(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(isAlpha) }

    /// Python str.isupper(): has a cased character and no lowercase ones.
    static func isUpper(_ s: String) -> Bool {
        var cased = false
        for c in s.unicodeScalars {
            switch c.properties.generalCategory {
            case .lowercaseLetter, .titlecaseLetter: return false
            case .uppercaseLetter: cased = true
            default: if c.properties.isLowercase { return false }
            }
        }
        return cased
    }

    static func isASCIILetter(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z")
    }

    static func isDigit(_ s: Unicode.Scalar) -> Bool { s.properties.numericType == .decimal }

    /// len() in code points.
    static func len(_ s: String) -> Int { s.unicodeScalars.count }

    /// str.split() with no argument.
    static func split(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func stripAccents(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.decomposedStringWithCompatibilityMapping.unicodeScalars
        where c.properties.canonicalCombiningClass.rawValue == 0 {
            out.append(c)
        }
        return String(out)
    }

    /// Python's str.strip()
    static func strip(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Tokens

struct Token: Hashable {
    let norm: String
    let orig: String
}

enum Tokenizer {
    private static let punct: [Character: Character] = [
        "\u{2019}": "'", "\u{2018}": "'", "`": "'", "\u{00B4}": "'",
        "\u{2013}": "-", "\u{2014}": "-", "\u{2012}": "-", "\u{2212}": "-",
    ]
    private static let spaced: Set<Character> = Set("/,;:()[]{}\"!?#*+=<>|\\")

    /// road_aliases.tokenize: split a road name into (normalized, original) tokens.
    static func tokenize(_ text: String) -> [Token] {
        var s = ""
        for ch in text {
            var c = punct[ch] ?? ch
            if c == "&" { s += " & "; continue }
            if spaced.contains(c) { c = " " }
            if c == "-" { c = " " }
            s.append(c)
        }
        // (?<=[A-Za-z])(?=\d): I95 -> I 95, MD355 -> MD 355
        var spacedOut = String.UnicodeScalarView()
        var prev: Unicode.Scalar?
        for u in s.unicodeScalars {
            if let p = prev, Py.isASCIILetter(p), Py.isDigit(u) { spacedOut.append(" ") }
            spacedOut.append(u)
            prev = u
        }
        var out: [Token] = []
        for orig in Py.split(String(spacedOut)) {
            let norm = Py.stripAccents(orig).lowercased()
                .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "'", with: "")
            if !norm.isEmpty { out.append(Token(norm: norm, orig: orig)) }
        }
        return out
    }

    static func key(_ form: String) -> [String] { tokenize(form).map(\.norm) }
    static func normPhrase(_ form: String) -> String { key(form).joined(separator: " ") }
}

// MARK: - Regex helpers (POSIX ERE without backslashes, so it embeds cleanly in Overpass QL)

enum Rx {
    private static let bracket: Set<Unicode.Scalar> = Set("$*+?()[{}|".unicodeScalars)

    static func chars(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if Py.isAlnum(ch) {
                out.unicodeScalars.append(ch)
            } else if ch == "'" {
                out += "('|\u{2019})?"
            } else if ch == "." {
                out += "[.]?"
            } else if ch == " " || ch == "-" {
                out += "[ -]*"
            } else if ch == "]" {
                out += "[]]"
            } else if bracket.contains(ch) {
                out += "[\(Character(ch))]"
            } else if ch == "^" || ch == "\\" || ch == "\"" {
                continue
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    static func phrase(_ form: String) -> String {
        var parts: [String] = []
        for tok in Py.split(form) {
            var r = chars(tok)
            let bare = tok.replacingOccurrences(of: ".", with: "")
            if Py.isAlpha(bare) && Py.len(bare) <= 4 && !tok.hasSuffix(".") {
                r += "[.]?"                     // "Ave" also matches "Ave."
            }
            parts.append(r)
        }
        return parts.joined(separator: "[ -]*")
    }

    /// re.fullmatch(r"[A-Za-z]{2,}s", s)
    private static func isPossessiveCandidate(_ s: String) -> Bool {
        let u = Array(s.unicodeScalars)
        guard u.count >= 3, u.last == "s" else { return false }
        return u.allSatisfy(Py.isASCIILetter)
    }

    static func literal(_ orig: String) -> String {
        func one(_ s: String) -> String {
            if isPossessiveCandidate(s) {             // Georges / George's
                var scalars = Array(s.unicodeScalars)
                let last = scalars.removeLast()
                var headStr = ""
                headStr.unicodeScalars.append(contentsOf: scalars)
                return chars(headStr) + "('|\u{2019})?" + String(Character(last))
            }
            var r = chars(s)
            if Py.len(s) == 1 && Py.isAlpha(s) { r += "[.]?" }     // initials: "F" / "F."
            return r
        }
        var r = one(orig)
        let plain = Py.stripAccents(orig)
        if plain != orig { r = "(\(r)|\(one(plain)))" }
        return r
    }

    static func alt<S: Sequence>(_ list: S) -> String where S.Element == String {
        var seen = Set<String>(), out: [String] = []
        for r in list where !r.isEmpty && !seen.contains(r) {
            seen.insert(r)
            out.append(r)
        }
        if out.count == 1 { return out[0] }
        return "(" + out.joined(separator: "|") + ")"
    }
}

// MARK: - Elements

enum ElemKey: Hashable {
    case route(cls: String, num: String, state: String?)
    case named(String)
    case group(String)
    case ordinal(Int)
    case word(String)
}

/// One piece of a parsed road name (a word, a street type, a route, ...).
public struct AliasElement: Hashable {
    /// word | group | ordinal | named | route
    public let kind: String
    let key: ElemKey
    /// Display alternatives (first = preferred).
    public let alts: [String]
    /// POSIX regex covering every alternative.
    let rx: String
}

// MARK: - Indexes built from the tables

final class AliasIndex {
    static let shared = AliasIndex()

    var groups: [String: [String]] = [:]          // gid -> display forms
    var groupIndex: [[String]: String] = [:]      // phrase key -> gid
    var groupKind: [String: String] = [:]         // gid -> table name
    let special: [String: (String, String)] = ["st": ("street", "saint"), "dr": ("drive", "doctor")]
    var typeWords = Set<String>()
    var dirWords = Set<String>()
    var trailingWords = Set<String>()
    var avenueWords = Set<String>()
    var groupMaxLen = 1

    var ordIndex: [[String]: Int] = [:]

    var named: [String: [String]] = [:]
    var namedIndex: [[String]: String] = [:]
    var namedMaxLen = 1

    struct Rename { let index: Int; let state: String; let fips: Set<String>; let whereText: String; let forms: [String] }
    var renames: [String: Rename] = [:]
    var renameIndex: [[String]: [String]] = [:]
    var renameMaxLen = 1

    var staveIndex: [[String]: (abbr: String, needsUpper: Bool)] = [:]
    var staveMaxLen = 1

    var classIndex: [[String]: String] = [:]
    var stateFormIndex: [[String]: (abbr: String, needsCtx: Bool)] = [:]
    var afterStateIndex: [[String]: String] = [:]
    var routeMaxLen = 1
    var afterMaxLen = 1

    var stateLookup: [String: String] = [:]
    var states: [String: StateRow] = [:]

    let statey: Set<String> = ["STATE", "GENERIC"]
    let letterClasses: Set<String> = ["COUNTY", "GENERIC", "TOWNSHIP"]
    let notRouteCodes: Set<String> = ["ne", "nw", "se", "sw", "nb", "sb", "eb", "wb", "of", "at", "to",
                                      "on", "in", "by", "the", "and"]

    private init() {
        let key = Tokenizer.key
        for s in AliasTables.states { states[s.abbr] = s }

        func gid(_ forms: [String]) -> String { key(String(forms[0].drop(while: { $0 == "~" }))).joined(separator: "_") }
        func register(_ kind: String, _ forms: [String]) {
            let id = gid(forms)
            if groups[id] != nil { return }
            groups[id] = forms.filter { !$0.hasPrefix("~") }
            groupKind[id] = kind
            for f in forms {
                let k = key(String(f.drop(while: { $0 == "~" })))
                if k.count == 1 && special[k[0]] != nil { continue }
                if groupIndex[k] == nil { groupIndex[k] = id }
            }
        }
        for f in AliasTables.streetTypes { register("type", f) }
        for f in AliasTables.directionals { register("dir", f) }
        for f in AliasTables.modifiers { register("mod", f) }
        for f in AliasTables.words { register("word", f) }

        for (k, g) in groupIndex {
            if k.count == 1 && groupKind[g] == "type" { typeWords.insert(k[0]) }
            if groupKind[g] == "dir" { dirWords.formUnion(k) }
            if k.count == 1 && g == "avenue" { avenueWords.insert(k[0]) }
            groupMaxLen = max(groupMaxLen, k.count)
        }
        typeWords.formUnion(["st", "dr"])
        trailingWords = dirWords
        for (k, g) in groupIndex where groupKind[g] == "mod" || g == "extension" || g == "bypass" {
            trailingWords.formUnion(k)
        }

        for n in 1..<100 { ordIndex[key(AliasEngine.ordinalWord(n))] = n }

        for forms in AliasTables.namedRoads {
            let nid = "named:" + key(forms[0]).joined(separator: "_")
            let expanded = expandTypeForms(forms)
            named[nid] = expanded
            for f in expanded where namedIndex[key(f)] == nil { namedIndex[key(f)] = nid }
        }
        namedMaxLen = namedIndex.keys.map(\.count).max() ?? 1

        for (n, r) in AliasTables.renamedRoads.enumerated() {
            let rid = "rename\(n):" + key(r.forms[0]).joined(separator: "_")
            let expanded = expandTypeForms(r.forms)
            renames[rid] = Rename(index: n, state: r.state, fips: Set(r.fips), whereText: r.whereText, forms: expanded)
            for f in expanded { renameIndex[key(f), default: []].append(rid) }
        }
        renameMaxLen = renameIndex.keys.map(\.count).max() ?? 1

        for s in AliasTables.states where !s.nicknames.isEmpty {
            staveIndex[key(s.name)] = (s.abbr, false)
            for nk in s.nicknames { staveIndex[key(nk)] = (s.abbr, nk.count <= 2) }
        }
        staveMaxLen = staveIndex.keys.map(\.count).max() ?? 1

        for cls in AliasTables.routeClassOrder {
            for p in AliasTables.routeClasses[cls]! where classIndex[key(p)] == nil { classIndex[key(p)] = cls }
        }
        for s in AliasTables.states {
            for f in [s.abbr, s.name] + s.forms where stateFormIndex[key(f)] == nil {
                stateFormIndex[key(f)] = (s.abbr, false)
            }
            for f in s.prefixes where stateFormIndex[key(f)] == nil {
                stateFormIndex[key(f)] = (s.abbr, key(f)[0].count == 1)
            }
        }
        for w in AliasTables.stateRouteWords + AliasTables.routeClasses["STATE"]! where afterStateIndex[key(w)] == nil {
            afterStateIndex[key(w)] = "STATE"
        }
        for s in AliasTables.states {
            for w in s.words where afterStateIndex[key(w)] == nil { afterStateIndex[key(w)] = "STATE" }
        }
        for cls in ["COUNTY", "TOWNSHIP", "FM", "LOOP", "SPUR", "PARK", "BELTWAY"] {
            for p in AliasTables.routeClasses[cls]! where afterStateIndex[key(p)] == nil { afterStateIndex[key(p)] = cls }
        }
        routeMaxLen = (Array(classIndex.keys) + Array(stateFormIndex.keys)).map(\.count).max() ?? 1
        afterMaxLen = afterStateIndex.keys.map(\.count).max() ?? 1

        for s in AliasTables.states {
            for f in [s.abbr, s.name] + s.forms { stateLookup[Tokenizer.normPhrase(f)] = s.abbr }
        }
        for (k, v) in AliasTables.stateInputExtras { stateLookup[k] = v }
    }

    func typeAlternatives(_ wordNorm: String) -> [String]? {
        if let g = groupIndex[[wordNorm]], groupKind[g] == "type" { return groups[g] }
        return nil
    }

    func expandTypeForms(_ forms: [String]) -> [String] {
        var out: [String] = []
        for f in forms {
            let toks = Py.split(f)
            if let last = toks.last, let lastKey = Tokenizer.key(last).last, let alts = typeAlternatives(lastKey) {
                for a in alts { out.append((toks.dropLast() + [a]).joined(separator: " ")) }
            } else {
                out.append(f)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - Engine

public enum AliasEngine {
    private static let ones = ["", "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth"]
    private static let teens = ["Tenth", "Eleventh", "Twelfth", "Thirteenth", "Fourteenth", "Fifteenth",
                                "Sixteenth", "Seventeenth", "Eighteenth", "Nineteenth"]
    private static let tensOrd = [2: "Twentieth", 3: "Thirtieth", 4: "Fortieth", 5: "Fiftieth",
                                  6: "Sixtieth", 7: "Seventieth", 8: "Eightieth", 9: "Ninetieth"]
    private static let tens = [2: "Twenty", 3: "Thirty", 4: "Forty", 5: "Fifty", 6: "Sixty",
                               7: "Seventy", 8: "Eighty", 9: "Ninety"]

    static func ordinalWord(_ n: Int) -> String {
        if n < 10 { return ones[n] }
        if n < 20 { return teens[n - 10] }
        let t = n / 10, o = n % 10
        return o == 0 ? tensOrd[t]! : "\(tens[t]!)-\(ones[o])"
    }

    static func ordinalSuffix(_ n: Int) -> String {
        if (10...20).contains(n % 100) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// _ORD_RE.fullmatch: (\d+)(st|nd|rd|th) -> the number
    static func ordinalMatch(_ tok: String) -> Int? {
        for suf in ["st", "nd", "rd", "th"] where tok.hasSuffix(suf) {
            let digits = String(tok.dropLast(2))
            if !digits.isEmpty && digits.unicodeScalars.allSatisfy(Py.isDigit) { return Int(digits) }
        }
        return nil
    }

    private static var idx: AliasIndex { AliasIndex.shared }

    // MARK: states

    /// The postal code ("md") for a state name or abbreviation, or nil.
    public static func resolveState(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return idx.stateLookup[Tokenizer.normPhrase(text)]
    }

    public static func stateName(_ abbr: String?) -> String {
        guard let abbr else { return "" }
        return idx.states[abbr]?.name ?? abbr.uppercased()
    }

    /// (postal code, name) for every state in the table, in table order.
    public static var allStates: [(abbr: String, name: String)] { AliasTables.states.map { ($0.abbr, $0.name) } }

    static func isState(_ abbr: String) -> Bool { idx.states[abbr] != nil }

    // MARK: routes

    /// _route_number
    static func routeNumber(_ tok: String, _ cls: String, _ state: String?) -> String? {
        let u = Array(tok.unicodeScalars)
        // \d{1,4}[a-z]?
        var digits = 0
        while digits < u.count && Py.isDigit(u[digits]) { digits += 1 }
        let rest = u.count - digits
        if digits >= 1 && digits <= 4 && (rest == 0 || (rest == 1 && u[digits] >= "a" && u[digits] <= "z"))
            && ordinalMatch(tok) == nil {
            return tok.uppercased()
        }
        let letters = u.count >= 1 && u.count <= 2 && u.allSatisfy { $0 >= "a" && $0 <= "z" }
        if (idx.letterClasses.contains(cls) || (cls == "STATE" && state == "mo")) && letters
            && !idx.typeWords.contains(tok) && !idx.notRouteCodes.contains(tok) {
            return tok.uppercased()
        }
        return nil
    }

    static func numRx(_ num: String) -> String {
        let u = Array(num.unicodeScalars)
        var d = 0
        while d < u.count && Py.isDigit(u[d]) { d += 1 }
        guard d >= 1 else { return num }
        let tail = u[d...]
        guard tail.allSatisfy({ $0 >= "A" && $0 <= "Z" }) else { return num }
        if tail.isEmpty { return num }
        var a = "", b = ""
        a.unicodeScalars.append(contentsOf: u[..<d])
        b.unicodeScalars.append(contentsOf: tail)
        return "\(a)[ -]*\(b)"
    }

    private static func fill(_ template: String, _ n: String) -> String {
        template.replacingOccurrences(of: "{n}", with: n)
    }

    /// (display list, regex) for a route designation (_route_render).
    static func routeRender(_ cls: String, _ num: String, _ state: String?, _ ctx: String?) -> ([String], String) {
        let n = num
        var display: [String] = [], parts: [String] = []
        let rc = AliasTables.routeClasses

        if idx.statey.contains(cls) {
            let st = state ?? ctx
            let sameState = ctx == nil || st == nil || st == ctx
            if let st, let row = idx.states[st] {
                let prefixes = [st.uppercased(), row.name] + row.forms + row.prefixes
                let words = AliasTables.stateRouteWords + row.words
                let name = row.name, up = st.uppercased()
                display += row.prefixes.map { "\($0)-\(n)" }
                display += row.prefixes.map { "\($0) \(n)" }
                display += ["\(up) \(n)", "\(up)-\(n)", "\(up)\(n)", "\(name) Route \(n)",
                            "\(name) State Route \(n)", "\(name) Highway \(n)",
                            "\(name) State Highway \(n)", "\(up) Route \(n)", "\(up) Highway \(n)",
                            "\(name) \(n)"]
                display += row.words.map { "\(name) \($0) \(n)" }
                parts.append(Rx.alt(prefixes.map(Rx.phrase)) + "([ -]*" + Rx.alt(words.map(Rx.phrase)) + ")?")
            }
            if sameState || cls == "GENERIC" {
                display += AliasTables.stateAgnosticDisplay.map { fill($0, n) }
                parts.append(Rx.alt((rc["STATE"]! + rc["GENERIC"]!).map(Rx.phrase)))
            }
            if cls == "GENERIC" {
                display += ["US \(n)", "US Route \(n)", "US Highway \(n)"]
                parts.append(Rx.alt(rc["US"]!.map(Rx.phrase)))
            }
        } else {
            display += (AliasTables.routeDisplay[cls] ?? []).map { fill($0, n) }
            if cls == "US" {
                display += ["Route \(n)", "Highway \(n)", "Hwy \(n)"]
                parts.append(Rx.alt((rc["US"]! + rc["GENERIC"]!).map(Rx.phrase)))
            } else {
                parts.append(Rx.alt(rc[cls]!.map(Rx.phrase)))
            }
        }

        var seen = Set<String>()
        display = display.filter { seen.insert($0).inserted }
        var body = parts.count == 1 ? parts[0] : "(" + parts.joined(separator: "|") + ")"
        if !body.hasPrefix("(") { body = "(\(body))" }
        return (display, "\(body)[ -]*\(numRx(n))")
    }

    static func routeElem(_ cls: String, _ num: String, _ state: String?, _ ctx: String?) -> AliasElement {
        let (display, rx) = routeRender(cls, num, state, ctx)
        return AliasElement(kind: "route", key: .route(cls: cls, num: num, state: state), alts: display, rx: rx)
    }

    // MARK: parsing

    private static func slice(_ toks: [Token], _ i: Int, _ L: Int) -> [String] { toks[i..<(i + L)].map(\.norm) }

    static func tryRoute(_ toks: [Token], _ i: Int, _ ctx: String?) -> (AliasElement, Int)? {
        let n = toks.count
        let top = min(idx.routeMaxLen, n - i - 1)
        guard top >= 1 else { return nil }
        for L in stride(from: top, through: 1, by: -1) {
            let key = slice(toks, i, L)
            let j = i + L
            if let cls = idx.classIndex[key], let num = routeNumber(toks[j].norm, cls, ctx) {
                return (routeElem(cls, num, idx.statey.contains(cls) ? ctx : nil, ctx), j + 1)
            }
            if let st = idx.stateFormIndex[key] {
                if st.needsCtx && ctx != nil && ctx != st.abbr { continue }
                if let num = routeNumber(toks[j].norm, "STATE", st.abbr) {
                    return (routeElem("STATE", num, st.abbr, ctx), j + 1)
                }
                let top2 = min(idx.afterMaxLen, n - j - 1)
                if top2 >= 1 {
                    for L2 in stride(from: top2, through: 1, by: -1) {
                        if let cls2 = idx.afterStateIndex[slice(toks, j, L2)],
                           let num = routeNumber(toks[j + L2].norm, cls2, st.abbr) {
                            return (routeElem(cls2, num, st.abbr, ctx), j + L2 + 1)
                        }
                    }
                }
            }
        }
        return nil
    }

    static func tryIndex<V>(_ toks: [Token], _ i: Int, _ index: [[String]: V], _ maxLen: Int) -> (V, Int)? {
        let top = min(maxLen, toks.count - i)
        guard top >= 1 else { return nil }
        for L in stride(from: top, through: 1, by: -1) {
            if let v = index[slice(toks, i, L)] { return (v, L) }
        }
        return nil
    }

    static func renameAt(_ toks: [Token], _ i: Int, _ ctx: String?, _ county: String?) -> (String, Int)? {
        let top = min(idx.renameMaxLen, toks.count - i)
        guard top >= 1 else { return nil }
        for L in stride(from: top, through: 1, by: -1) {
            for rid in idx.renameIndex[slice(toks, i, L)] ?? [] {
                let r = idx.renames[rid]!
                if ctx == r.state, let county, r.fips.contains(county) { return (rid, L) }
            }
        }
        return nil
    }

    static func parseUncached(_ name: String, _ ctx: String?, _ county: String?) -> [AliasElement] {
        let toks = Tokenizer.tokenize(name)
        let n = toks.count
        let trailing = toks.map { idx.trailingWords.contains($0.norm) }
        let suffixPos = (0..<n).map { i in trailing[(i + 1)...].allSatisfy { $0 } }
        var elems: [AliasElement] = []
        var i = 0
        while i < n {
            if let (e, next) = tryRoute(toks, i, ctx) {
                elems.append(e)
                i = next
                continue
            }

            if county != nil, let (rid, L) = renameAt(toks, i, ctx, county) {
                let forms = idx.renames[rid]!.forms
                elems.append(AliasElement(kind: "named", key: .named(rid), alts: forms, rx: Rx.alt(forms.map(Rx.phrase))))
                i += L
                continue
            }

            if let (nid, L) = tryIndex(toks, i, idx.namedIndex, idx.namedMaxLen) {
                let forms = idx.named[nid]!
                elems.append(AliasElement(kind: "named", key: .named(nid), alts: forms, rx: Rx.alt(forms.map(Rx.phrase))))
                i += L
                continue
            }

            if let (hit, L) = tryIndex(toks, i, idx.staveIndex, idx.staveMaxLen) {
                let nxt = i + L < n ? toks[i + L].norm : ""
                if idx.avenueWords.contains(nxt) && (!hit.needsUpper || Py.isUpper(toks[i].orig)) {
                    let row = idx.states[hit.abbr]!
                    let forms = [row.name] + row.nicknames
                    elems.append(AliasElement(kind: "group", key: .group("stave:" + hit.abbr), alts: forms,
                                              rx: Rx.alt(forms.map(Rx.phrase))))
                    i += L
                    continue
                }
            }

            let tok = toks[i].norm
            let m = ordinalMatch(tok)
            let hit = m == nil ? tryIndex(toks, i, idx.ordIndex, 2) : nil
            if m != nil || hit != nil {
                let num = m ?? hit!.0
                let L = m != nil ? 1 : hit!.1
                var forms = ["\(num)\(ordinalSuffix(num))"]
                if (1...99).contains(num) { forms.append(ordinalWord(num)) }
                elems.append(AliasElement(kind: "ordinal", key: .ordinal(num), alts: forms, rx: Rx.alt(forms.map(Rx.phrase))))
                i += L
                continue
            }

            var gid: String?
            var L = 0
            if let sp = idx.special[tok] {
                gid = suffixPos[i] ? sp.0 : sp.1
                L = 1
            } else if let (g, len) = tryIndex(toks, i, idx.groupIndex, idx.groupMaxLen) {
                gid = g
                L = len
            }
            if let gid {
                var forms = idx.groups[gid]!
                // A lone letter that IS the street name ("N St NW", "E St SE") is not a direction.
                if idx.groupKind[gid] == "dir" && L == 1 && Py.len(tok) == 1 && i == 0
                    && i + 1 < n && idx.typeWords.contains(toks[i + 1].norm) && suffixPos[i + 1] {
                    forms = [toks[i].orig.uppercased()]
                }
                elems.append(AliasElement(kind: "group", key: .group(gid), alts: forms, rx: Rx.alt(forms.map(Rx.phrase))))
                i += L
                continue
            }

            let orig = toks[i].orig
            let lit = Py.len(tok) > 1 ? orig.replacingOccurrences(of: ".", with: "") : orig
            elems.append(AliasElement(kind: "word", key: .word(tok), alts: [orig], rx: Rx.literal(lit)))
            i += 1
        }
        return elems
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: [AliasElement]] = [:]

    /// Parse a road name. `ctx` is the postal code of the state being searched (or nil);
    /// `county` is the 5-digit FIPS of the county being searched (switches on renames).
    public static func parse(_ name: String, _ ctx: String? = nil, _ county: String? = nil) -> [AliasElement] {
        let k = "\(name)\u{1}\(ctx ?? "")\u{1}\(county ?? "")"
        cacheLock.lock()
        if let hit = cache[k] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let r = parseUncached(name, ctx, county)
        cacheLock.lock()
        if cache.count > 300_000 { cache.removeAll() }
        cache[k] = r
        cacheLock.unlock()
        return r
    }

    static func elemEq(_ a: AliasElement, _ b: AliasElement) -> Bool {
        if case let .route(c1, n1, s1) = a.key, case let .route(c2, n2, s2) = b.key {
            if n1 != n2 { return false }
            if c1 != c2 {
                let pair: Set<String> = [c1, c2]
                if !(pair.contains("GENERIC") && !pair.isDisjoint(with: ["STATE", "US"])) { return false }
            }
            if idx.statey.contains(c1) && idx.statey.contains(c2), let s1, let s2, !s1.isEmpty, !s2.isEmpty, s1 != s2 {
                return false
            }
            return true
        }
        return a.key == b.key
    }

    static func ctx(_ state: String?) -> String? {
        guard let state, !state.isEmpty else { return nil }
        let s = Py.strip(state).lowercased()
        return idx.states[s] != nil ? s : resolveState(state)
    }

    static func county(_ county: String?) -> String? {
        let c = Py.strip(county ?? "")
        return (c.count == 5 && c.allSatisfy { $0.isASCII && $0.isNumber }) ? c : nil
    }

    // MARK: public API (same names as road_aliases.py)

    /// POSIX ERE (no anchors) matching every alias of road_name.
    public static func overpassRegex(_ road: String, state: String? = nil, county: String? = nil) -> String {
        parse(road, ctx(state), self.county(county)).map(\.rx).joined(separator: "[ -]*")
    }

    /// Regex for an OSM tag value; also matches one entry of a ';' list.
    public static func overpassTagRegex(_ road: String, state: String? = nil, county: String? = nil) -> String {
        "(^|;) *\(overpassRegex(road, state: state, county: county)) *(;|$)"
    }

    /// Concrete spellings of road_name (input first), up to `limit`.
    public static func expandVariants(_ road: String, state: String? = nil, limit: Int = 500,
                                      county: String? = nil) -> [String] {
        let elems = parse(road, ctx(state), self.county(county))
        if elems.isEmpty { return road.isEmpty ? [] : [road] }
        var out = [Py.strip(road)]
        var seen = Set(out)
        let alts = elems.map(\.alts)
        if alts.contains(where: { $0.isEmpty }) { return out }
        var counters = [Int](repeating: 0, count: alts.count)
        var produced = 0
        while produced < limit * 4 {
            let s = (0..<alts.count).map { alts[$0][counters[$0]] }.joined(separator: " ")
            produced += 1
            if seen.insert(s).inserted { out.append(s) }
            if out.count >= limit { break }
            // odometer: last element varies fastest (itertools.product)
            var k = alts.count - 1
            while k >= 0 {
                counters[k] += 1
                if counters[k] < alts[k].count { break }
                counters[k] = 0
                k -= 1
            }
            if k < 0 { break }
        }
        return out
    }

    public static func countVariants(_ road: String, state: String? = nil, county: String? = nil) -> Int {
        var total = 1
        for e in parse(road, ctx(state), self.county(county)) {
            let (r, overflow) = total.multipliedReportingOverflow(by: max(1, e.alts.count))
            total = overflow ? Int.max : r
        }
        return total
    }

    /// If road_name is a renamed road that only applies inside particular counties, and
    /// this search isn't in one of them, a short hint.
    public static func renameHint(_ road: String, state: String? = nil, county: String? = nil) -> String? {
        let c = ctx(state), cty = self.county(county)
        let toks = Tokenizer.tokenize(road)
        for i in toks.indices {
            let top = min(idx.renameMaxLen, toks.count - i)
            guard top >= 1 else { continue }
            for L in stride(from: top, through: 1, by: -1) {
                for rid in idx.renameIndex[slice(toks, i, L)] ?? [] {
                    let r = idx.renames[rid]!
                    if r.state == c && !(cty.map { r.fips.contains($0) } ?? false) {
                        let others = AliasTables.renamedRoads[r.index].forms
                        return "'\(road)' matches a road renamed in \(r.whereText) "
                            + "(\(others.joined(separator: " / "))). Add that county with --county "
                            + "to search both names."
                    }
                }
            }
        }
        return nil
    }

    /// Human-readable summary of how a name is expanded (--list-aliases).
    public static func describe(_ road: String, state: String? = nil, sample: Int = 25, county: String? = nil) -> String {
        let c = ctx(state), cty = self.county(county)
        var whereText = c.map { stateName($0) } ?? ""
        if let cty { whereText += ", county \(cty)" }
        var lines = ["Road: \(pyRepr(road))" + (whereText.isEmpty ? "" : "   (searching in \(whereText))")]
        for e in parse(road, c, cty) {
            let kind = e.kind.padding(toLength: max(7, e.kind.count), withPad: " ", startingAt: 0)
            lines.append("  [\(kind)] " + e.alts.prefix(14).joined(separator: " | ")
                         + (e.alts.count > 14 ? "  (+\(e.alts.count - 14) more)" : ""))
        }
        let total = countVariants(road, state: c, county: cty)
        lines.append("  \(total) spelling combination(s); first \(min(sample, total)):")
        for v in expandVariants(road, state: c, limit: sample, county: cty) { lines.append("    \(v)") }
        if let hint = renameHint(road, state: c, county: cty) { lines.append("  Note: \(hint)") }
        lines.append("  Overpass regex:")
        lines.append("    \(overpassTagRegex(road, state: c, county: cty))")
        return lines.joined(separator: "\n")
    }

    /// Python repr() of a string, as used in describe().
    static func pyRepr(_ s: String) -> String {
        if s.contains("'") && !s.contains("\"") { return "\"\(s)\"" }
        return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }
}

/// Decide whether another road name is the same road as `roadName`.
///
/// contains=true (used for TIGER/Line) accepts the road appearing inside a longer name,
/// but only on whole words, so "US 1" doesn't match "US Hwy 15".
public final class RoadMatcher {
    let ctx: String?
    let county: String?
    public let roadName: String
    let query: [AliasElement]

    public init(_ roadName: String, state: String? = nil, county: String? = nil) {
        ctx = AliasEngine.ctx(state)
        self.county = AliasEngine.county(county)
        self.roadName = roadName
        query = AliasEngine.parse(roadName, ctx, self.county)
    }

    public func matches(_ candidate: String?, contains: Bool = true) -> Bool {
        guard let candidate, !Py.strip(candidate).isEmpty, !query.isEmpty else { return false }
        let cand = AliasEngine.parse(candidate, ctx, county)
        let m = query.count, n = cand.count
        if !contains {
            return m == n && zip(query, cand).allSatisfy { AliasEngine.elemEq($0, $1) }
        }
        if n < m { return false }
        for i in 0...(n - m) where (0..<m).allSatisfy({ AliasEngine.elemEq(query[$0], cand[i + $0]) }) {
            return true
        }
        return false
    }
}
