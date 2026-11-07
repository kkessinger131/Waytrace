import Foundation

/// Python's csv.reader (excel dialect): commas, double quotes, "" for a quote,
/// quoted fields may span lines. A blank line gives an empty row.
public enum CSVReader {
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        let chars = Array(text.unicodeScalars)
        var k = 0
        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() {
            if fieldStarted || !row.isEmpty { endField() }
            rows.append(row)
            row = []
        }
        while k < chars.count {
            let c = chars[k]
            if inQuotes {
                if c == "\"" {
                    if k + 1 < chars.count && chars[k + 1] == "\"" { field.unicodeScalars.append("\""); k += 1 }
                    else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" && field.isEmpty && !(fieldStarted && !field.isEmpty) {
                inQuotes = true
                fieldStarted = true
            } else if c == "," {
                fieldStarted = true
                endField()
                fieldStarted = true
            } else if c == "\r" || c == "\n" {
                if c == "\r" && k + 1 < chars.count && chars[k + 1] == "\n" { k += 1 }
                endRow()
            } else {
                field.unicodeScalars.append(c)
                fieldStarted = true
            }
            k += 1
        }
        if fieldStarted || !row.isEmpty || !field.isEmpty { endRow() }
        return rows
    }

    /// csv.DictReader: the first non-empty row names the columns; blank lines are
    /// skipped. Each row is an ordered list of (column, value or nil if the row was short);
    /// extra values beyond the header are dropped (the restkey None column).
    public static func dictRows(_ text: String) -> (headers: [String], rows: [[(String, String?)]]) {
        var all = rows(text).filter { !$0.isEmpty }
        guard !all.isEmpty else { return ([], []) }
        let headers = all.removeFirst()
        let out = all.map { r -> [(String, String?)] in
            headers.enumerated().map { (k, h) in (h, k < r.count ? r[k] : nil) }
        }
        return (headers, out)
    }
}

/// Small helpers for writing numbers the way Python's f-strings do.
enum PyFmt {
    static func f(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }

    /// str(float): shortest repr, with ".0" for whole numbers.
    static func repr(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v > 0 ? "inf" : "-inf" }
        if v == v.rounded() && abs(v) < 1e16 { return String(format: "%.1f", v) }
        return "\(v)"
    }

    /// Python's repr() of a list of strings: ['a', 'b']
    static func list(_ items: [String]) -> String {
        "[" + items.map { AliasEngine.pyRepr($0) }.joined(separator: ", ") + "]"
    }
}

/// Regular-expression helpers on NSRegularExpression.
enum Re {
    static func compile(_ pattern: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: opts)
    }

    static func groups(_ re: NSRegularExpression, _ s: String) -> [String?]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { k in
            let r = m.range(at: k)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    static func sub(_ re: NSRegularExpression, _ template: String, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                    withTemplate: template)
    }

    static func split(_ re: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }
}

/// Calendar dates as Python's datetime.date: a proleptic Gregorian day number.
public struct DayDate: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let year: Int, month: Int, day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) { self.year = year; self.month = month; self.day = day }

    /// date.fromisoformat (YYYY-MM-DD only); nil if it isn't a real date.
    public init?(iso: String) {
        let s = iso.trimmingCharacters(in: .whitespaces)
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), d >= 1, d <= DayDate.daysIn(y, m) else { return nil }
        self.init(y, m, d)
    }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01.
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(ordinal z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public func adding(days: Int) -> DayDate { DayDate(ordinal: ordinal + days) }

    public static func < (a: DayDate, b: DayDate) -> Bool { a.ordinal < b.ordinal }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The local calendar date of a moment in a time zone.
    public init(_ date: Date, in tz: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(c.year!, c.month!, c.day!)
    }
}
