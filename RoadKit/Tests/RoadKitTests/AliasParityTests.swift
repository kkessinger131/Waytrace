import XCTest
@testable import RoadKit

/// Compares the Swift alias engine with road_aliases.py on ~27,000 name/state/county
/// combinations. The fixture is produced by the Python reference; skipped when absent
/// (it isn't shipped with the app).
final class AliasParityTests: XCTestCase {
    static let fixture = ProcessInfo.processInfo.environment["ROADKIT_ALIAS_FIXTURE"]
        ?? "/home/claude/fixtures/aliases.json"

    func load() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: Self.fixture) else {
            throw XCTSkip("no alias fixture at \(Self.fixture)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.fixture))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testEveryCaseMatchesPython() throws {
        let fx = try load()
        var failures = 0
        for case let c as [String: Any] in fx["cases"] as! [Any] {
            let name = c["name"] as! String
            let st = c["state"] as? String
            let county = c["county"] as? String
            let ctx = AliasEngine.ctx(st)
            let elems = AliasEngine.parse(name, ctx, AliasEngine.county(county))
            let label = "\(name) [\(st ?? "-")/\(county ?? "-")]"
            var ok = true
            if AliasEngine.overpassTagRegex(name, state: st, county: county) != c["regex"] as! String { ok = false }
            if elems.map(\.kind) != c["kinds"] as! [String] { ok = false }
            if elems.map(\.alts) != c["alts"] as! [[String]] { ok = false }
            if AliasEngine.expandVariants(name, state: st, limit: 30, county: county) != c["variants"] as! [String] { ok = false }
            if AliasEngine.countVariants(name, state: st, county: county) != (c["count"] as! NSNumber).intValue { ok = false }
            if AliasEngine.renameHint(name, state: st, county: county) != c["hint"] as? String { ok = false }
            if !ok {
                failures += 1
                if failures <= 15 {
                    XCTFail("""
                    \(label)
                      py regex: \(c["regex"]!)
                      sw regex: \(AliasEngine.overpassTagRegex(name, state: st, county: county))
                      py kinds: \(c["kinds"]!)  sw: \(elems.map(\.kind))
                      py alts: \(c["alts"]!)
                      sw alts: \(elems.map(\.alts))
                      py variants: \((c["variants"] as! [String]).prefix(6))
                      sw variants: \(AliasEngine.expandVariants(name, state: st, limit: 30, county: county).prefix(6))
                      py count \(c["count"]!) sw \(AliasEngine.countVariants(name, state: st, county: county))
                      py hint \(c["hint"] ?? "nil") sw \(AliasEngine.renameHint(name, state: st, county: county) ?? "nil")
                    """)
                }
            }
        }
        XCTAssertEqual(failures, 0, "\(failures) cases differ from road_aliases.py")
    }

    func testMatcherMatchesPython() throws {
        let fx = try load()
        var failures = 0
        for case let p as [String: Any] in fx["pairs"] as! [Any] {
            let m = RoadMatcher(p["q"] as! String, state: p["state"] as? String, county: p["county"] as? String)
            let cand = p["cand"] as! String
            if m.matches(cand) != p["contains"] as! Bool || m.matches(cand, contains: false) != p["exact"] as! Bool {
                failures += 1
                if failures <= 10 { XCTFail("\(p)") }
            }
        }
        XCTAssertEqual(failures, 0)
    }

    func testStatesAndDescribe() throws {
        let fx = try load()
        for (k, v) in fx["states"] as! [String: Any] {
            XCTAssertEqual(AliasEngine.resolveState(k), v as? String, k)
        }
        for (k, v) in fx["describe"] as! [String: String] {
            let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let st = parts[1] == "None" || parts[1].isEmpty ? nil : parts[1]
            XCTAssertEqual(AliasEngine.describe(parts[0], state: st), v, k)
        }
    }
}
