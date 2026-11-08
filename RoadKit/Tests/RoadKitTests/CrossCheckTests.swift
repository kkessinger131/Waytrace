import Foundation
import XCTest
@testable import RoadKit

/// Runs the jobs road_to_kml/crosscheck.py ran through road_to_kml.py, through the Swift
/// engine, and checks both drew the same road surface: same exit code, same file name, and
/// polygons that cover the same ground (within a sliver, since GEOS versions round a little
/// differently). CI sets ROADKIT_PY_OUT to the folder crosscheck.py wrote; without it the
/// test is skipped.
final class CrossCheckTests: EngineTestCase {
    struct Job: Decodable {
        let name: String
        let argv: [String]
        let input: String?
        let code: Int
        let output: String?
    }

    func testSameRoadSurfaceAsPython() throws {
        guard let dir = ProcessInfo.processInfo.environment["ROADKIT_PY_OUT"], !dir.isEmpty else {
            throw XCTSkip("set ROADKIT_PY_OUT to the folder road_to_kml/crosscheck.py wrote")
        }
        let base = URL(fileURLWithPath: dir)
        let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
        XCTAssertFalse(jobs.isEmpty)
        var report: [String] = []
        for job in jobs {
            // A fresh folder and fresh fakes for every job, like a new run of the script.
            try setUpWithError()
            defer { try? tearDownWithError() }
            if let input = job.input {
                try FileManager.default.copyItem(at: base.appendingPathComponent("inputs").appendingPathComponent(input),
                                                  to: path(input))
            }
            let (code, log, out) = runMain(job.argv)
            XCTAssertEqual(code, job.code, "\(job.name): exit code\n\(log)")
            XCTAssertEqual(out, job.output, "\(job.name): output file name")
            guard job.code == 0, code == 0, let out else { continue }

            try FileManager.default.copyItem(at: base.appendingPathComponent("\(job.name).kml"), to: path("python.kml"))
            let swift = try readKML(out)
            let python = try readKML("python.kml")
            // Areas in square degrees; only the ratios matter.
            let a = swift.area, b = python.area
            XCTAssertGreaterThan(b, 0, job.name)
            let sizeDiff = abs(a - b) / max(a, b)
            let apart = try (swift.difference(python).area + python.difference(swift).area) / max(a, b)
            report.append(job.name.padding(toLength: 16, withPad: " ", startingAt: 0)
                          + String(format: " area %+.3f%%  not shared %.3f%%  pieces %ld/%ld", 100 * (a - b) / b, 100 * apart,
                                   swift.partCount, python.partCount))
            XCTAssertLessThan(sizeDiff, 0.005, "\(job.name): Swift area \(a), Python \(b)")
            XCTAssertLessThan(apart, 0.01, "\(job.name): \(100 * apart)% of the surface isn't shared")
        }
        print("Cross-check against road_to_kml.py:\n" + report.joined(separator: "\n"))
    }
}
