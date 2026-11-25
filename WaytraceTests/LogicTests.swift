import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
#if canImport(FormsCheck)
@testable import FormsCheck
#endif

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private func pt(_ s: TimeInterval, _ lat: Double, _ lon: Double, seg: Int = 0, activity: String? = nil) -> TrackPoint {
    pt(at: t0.addingTimeInterval(s), lat, lon, seg: seg, activity: activity)
}

private func pt(at time: Date, _ lat: Double, _ lon: Double, seg: Int = 0, activity: String? = nil) -> TrackPoint {
    TrackPoint(segment: seg, time: time, latitude: lat, longitude: lon, horizontalAccuracy: 5,
               altitude: nil, verticalAccuracy: nil, speed: nil, speedAccuracy: nil, course: nil, courseAccuracy: nil,
               activity: activity)
}

private func photo(_ s: TimeInterval, _ name: String, lat: Double? = nil, lon: Double? = nil) -> PhotoInfo {
    PhotoInfo(id: name, fileName: name, taken: t0.addingTimeInterval(s), latitude: lat, longitude: lon)
}

final class PhotoPlacerTests: XCTestCase {
    // A walk north 0.001° (≈111 m) a minute for 10 minutes, a 30-minute stop, then on again.
    let walk: [TrackPoint] = (0...10).map { pt(Double($0) * 60, 38.900 + Double($0) * 0.001, -77.0) }
        + [pt(10 * 60 + 30 * 60, 38.9102, -77.0), pt(41 * 60 + 60, 38.912, -77.0)]

    func testOwnLocationWins() {
        let (m, u) = PhotoPlacer.place([photo(90, "IMG_1.HEIC", lat: 40, lon: -75)], on: walk)
        XCTAssertEqual(u, [])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].source, .photo)
        XCTAssertEqual(m[0].latitude, 40)
    }

    func testPlacedBetweenPointsByTime() throws {
        let (m, _) = PhotoPlacer.place([photo(90, "IMG_2.HEIC")], on: walk)
        let one = try XCTUnwrap(m.first)
        XCTAssertEqual(one.latitude, 38.9015, accuracy: 1e-9)
        XCTAssertEqual(one.source, .track(gap: 30))
    }

    func testDuringAStopItStaysWhereYouStopped() throws {
        // 10 minutes into the 30-minute stop: still at the 10:00 point, not part way along.
        let (m, _) = PhotoPlacer.place([photo(20 * 60, "IMG_3.HEIC")], on: walk)
        XCTAssertEqual(try XCTUnwrap(m.first).latitude, 38.910, accuracy: 1e-9)
        // 30 s before the next point: on the way.
        let (n, _) = PhotoPlacer.place([photo(40 * 60 - 30, "IMG_4.HEIC")], on: walk)
        XCTAssertEqual(try XCTUnwrap(n.first).latitude, 38.9101, accuracy: 1e-9)
    }

    func testBeforeAndAfterTheRecording() {
        let (m, u) = PhotoPlacer.place([photo(-180, "early"), photo(42 * 60 + 240, "late"), photo(-3600, "way before"),
                                        photo(42 * 60 + 3600, "way after")], on: walk)
        XCTAssertEqual(m.map(\.photo.fileName), ["early", "late"], "an hour out is another day's business")
        XCTAssertEqual(m[0].latitude, 38.900)
        XCTAssertEqual(m[0].source, .track(gap: 180))
        XCTAssertEqual(m[1].latitude, 38.912)
        XCTAssertEqual(u, [])
    }

    func testAcrossAnInterruptionNeedsANearbyPoint() {
        let pts = [pt(0, 38.9, -77.0, seg: 0), pt(40 * 60, 39.0, -77.0, seg: 1)]
        let (m, u) = PhotoPlacer.place([photo(20 * 60, "lost"), photo(5 * 60, "near the start")], on: pts)
        XCTAssertEqual(m.map(\.photo.fileName), ["near the start"])
        XCTAssertEqual(m[0].latitude, 38.9)
        XCTAssertEqual(u.map(\.fileName), ["lost"])
    }

    func testNullIslandIsNoLocation() {
        let (m, _) = PhotoPlacer.place([photo(90, "zero", lat: 0, lon: 0)], on: walk)
        XCTAssertNotEqual(m.first?.source, .photo)
    }

    func testPhotosInTheLineKML() throws {
        let markers = PhotoPlacer.place([photo(90, "IMG_0001.HEIC", lat: 38.95, lon: -77.01), photo(150, "IMG_<2>.HEIC")], on: walk).markers
        let kml = Exporter.kml([ExportTrack(name: "walk", points: walk)], title: "Walk & photos", photos: [markers])
        XCTAssertNoThrow(try XMLParserCheck.parse(kml))
        XCTAssertTrue(kml.contains("<name>Walk &amp; photos</name>"))
        XCTAssertTrue(kml.contains("<name>IMG_0001</name>"), "labelled by file name")
        XCTAssertTrue(kml.contains("<name>IMG_&lt;2&gt;</name>"))
        XCTAssertTrue(kml.contains("<name>Points and photos (2 photos)</name>"))
        XCTAssertTrue(kml.contains("#wtPhotoByTime"), "the one placed by time is yellow")
        XCTAssertTrue(kml.contains("location from the photo"))
        // A vertex of the line at each photo, in time order: 60 s, photo at 90 s, 120 s, photo at 150 s, 180 s.
        XCTAssertTrue(kml.contains("-77.0000000,38.9010000 -77.0100000,38.9500000 -77.0000000,38.9020000 -77.0000000,38.9025000 -77.0000000,38.9030000"))
        // Among the points, between the ones before and after it.
        let before = try XCTUnwrap(kml.range(of: "<coordinates>-77.0000000,38.9010000</coordinates>")).lowerBound
        let img = try XCTUnwrap(kml.range(of: "<name>IMG_0001</name>")).lowerBound
        let after = try XCTUnwrap(kml.range(of: "<coordinates>-77.0000000,38.9020000</coordinates>")).lowerBound
        XCTAssertTrue(before < img && img < after)

        let plain = Exporter.kml([ExportTrack(name: "walk", points: walk)], title: "Walk")
        XCTAssertTrue(plain.contains("<name>Points</name>"))
        XCTAssertFalse(plain.contains("wtPhoto"))
    }

    func testPhotoVertexJoinsTheNearerStretch() {
        let pts = [pt(0, 38.9, -77.0, seg: 0), pt(60, 38.901, -77.0, seg: 0), pt(600, 38.95, -77.0, seg: 1)]
        let m = { (s: TimeInterval) in PhotoMarker(photo: photo(s, "IMG"), latitude: 1, longitude: 2, source: .photo) }
        XCTAssertEqual(Exporter.lineWithPhotos(pts, [m(30)]).map(\.segment), [0, 0, 0, 1])
        XCTAssertEqual(Exporter.lineWithPhotos(pts, [m(100)]).first { $0.latitude == 1 }?.segment, 0, "nearer the first stretch")
        XCTAssertEqual(Exporter.lineWithPhotos(pts, [m(550)]).first { $0.latitude == 1 }?.segment, 1, "nearer the second")
        XCTAssertEqual(Exporter.lineWithPhotos(pts, [m(700)]).last?.latitude, 1, "after the end, last")
    }
}

final class DefaultsAndVersionTests: XCTestCase {
    func testNewDefaults() {
        XCTAssertEqual(SamplingPolicy.defaults.interval, 10)
        XCTAssertEqual(SamplingPolicy.defaults.minDistance, 10)
        XCTAssertEqual(SamplingPolicy.defaultsSummary, "10 s, 10 m, ±50 m, drift guard on, rest after 5 min")
    }

    func testOldDefaultsMoveToTheNewOnes() {
        let k = SamplingPolicy.Key.self
        XCTAssertEqual(SamplingPolicy.migration(storedInterval: 15, storedMinDistance: 20, version: 0),
                       [k.interval: 10, k.minDistance: 10])
        XCTAssertEqual(SamplingPolicy.migration(storedInterval: 30, storedMinDistance: 20, version: 0),
                       [k.minDistance: 10], "a chosen interval stays")
        XCTAssertEqual(SamplingPolicy.migration(storedInterval: nil, storedMinDistance: nil, version: 0), [:],
                       "never set: the new defaults apply anyway")
        XCTAssertEqual(SamplingPolicy.migration(storedInterval: 15, storedMinDistance: 20, version: 2), [:],
                       "only once: 15 s chosen after the update stays")
    }

    func testVersionText() {
        XCTAssertEqual(AppVersion(version: "1.0", build: "57", commit: "4d5b3a5").text, "1.0 (build 57, commit 4d5b3a5)")
        XCTAssertEqual(AppVersion(version: "1.0", build: "1", commit: "").text, "1.0 (1)")
        XCTAssertEqual(AppVersion(version: "1.0", build: "1", commit: "$(WAYTRACE_COMMIT)").text, "1.0 (1)")
    }
}

/// Just enough to show the KML is well-formed.
enum XMLParserCheck {
    final class Delegate: NSObject, XMLParserDelegate {
        var error: Error?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    static func parse(_ text: String) throws {
        let p = XMLParser(data: Data(text.utf8))
        let d = Delegate()
        p.delegate = d
        if !p.parse() { throw d.error ?? NSError(domain: "xml", code: 1) }
    }
}

final class SigningInfoTests: XCTestCase {
    func profile(expiry: String) -> Data {
        var d = Data([0x30, 0x82, 0x0f, 0x01, 0x06, 0x09])          // CMS header bytes
        d += Data((0..<300).map { UInt8($0 % 251) })
        d += Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key><string>Waytrace</string>
            <key>CreationDate</key><date>2026-11-01T15:00:00Z</date>
            <key>ExpirationDate</key><date>\(expiry)</date>
            <key>Name</key><string>iOS Team Provisioning Profile</string>
        </dict>
        </plist>
        """.utf8)
        d += Data((0..<500).map { UInt8(($0 * 7) % 256) })          // signature
        return d
    }

    func testReadsTheExpiry() {
        let date = SigningInfo.expirationDate(fromProfile: profile(expiry: "2026-11-08T15:00:00Z"))
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-11-08T15:00:00Z"))
        XCTAssertNil(SigningInfo.expirationDate(fromProfile: Data("not a profile".utf8)))
    }

    func testReminderTime() {
        let expiry = ISO8601DateFormatter().date(from: "2026-11-08T15:00:00Z")!
        let early = expiry.addingTimeInterval(-3 * 24 * 3600)
        XCTAssertEqual(SigningInfo.reminderDate(expiry: expiry, now: early), expiry.addingTimeInterval(-24 * 3600))
        let late = expiry.addingTimeInterval(-3600)
        XCTAssertEqual(SigningInfo.reminderDate(expiry: expiry, now: late), late.addingTimeInterval(5), "right away")
        XCTAssertNil(SigningInfo.reminderDate(expiry: expiry, now: expiry.addingTimeInterval(1)))
        XCTAssertTrue(SigningInfo.describe(expiry: expiry, now: early).hasSuffix("(in 3 days)"))
        XCTAssertTrue(SigningInfo.describe(expiry: expiry, now: late).hasSuffix("(in 1 h)"))
    }
}

final class RunSummaryTests: XCTestCase {
    func testCleanRun() {
        let t = RunSummary.make(label: "Roads traveled: Nov 8", outcome: .done, error: nil,
                                log: ["  Saved: roads_2026-11-08.kml", "Done. Open roads_2026-11-08.kml"],
                                outputs: ["/x/Road KML/roads_2026-11-08.kml"])
        XCTAssertEqual(t.title, "Road to KML finished")
        XCTAssertEqual(t.body, "Roads traveled: Nov 8\nSaved roads_2026-11-08.kml.")
        XCTAssertFalse(t.hasProblems)
    }

    func testTrackWarnings() {
        let log = ["  WARNING: part of the OSM road data is missing.", "  WARNING: part of the OSM road data is missing.",
                   "", "  WARNING: 2 trip(s) couldn't be matched to any road (re-run with --wait if the map servers were busy).",
                   "", "  Note: 3 gap(s) where a trip couldn't be followed on the road network (missing road, tunnel, or GPS jump); those stretches are left out."]
        let t = RunSummary.make(label: "Daily roads: 2026-11-08", outcome: .done, error: nil, log: log, outputs: ["a.kml"])
        XCTAssertEqual(t.title, "Road to KML finished, with problems")
        XCTAssertTrue(t.body.hasSuffix("Problems: some map data couldn't be downloaded; 2 trip(s) couldn't be matched to a road; 3 gap(s) left out."), t.body)
        XCTAssertTrue(t.hasProblems)
    }

    func testBatchWithFailures() {
        let t = RunSummary.make(label: "Batch: 3 rows", outcome: .failed, error: "ERROR: State not recognised: 'Atlantis'.",
                                log: ["  Row 2    OK      ...", "", "  2 succeeded, 1 failed."], outputs: ["a.kml", "c.kml"])
        XCTAssertEqual(t.title, "Road to KML failed")
        XCTAssertEqual(t.body, "Batch: 3 rows\nState not recognised: 'Atlantis'.\nSaved 2 KML files.\nAlso: 1 of 3 batch rows failed.")
    }

    func testCancelled() {
        XCTAssertEqual(RunSummary.make(label: "x", outcome: .cancelled, error: nil, log: [], outputs: []).title,
                       "Road to KML cancelled")
    }
}

final class DailyPlanTests: XCTestCase {
    var newYork: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    func testTwoRecordingsOnOneDayAreTwoMaps() {
        var p = DailyPlan()
        p.add(recording: "2026-11-07_09-12-44", days: ["2026-11-07"])
        p.add(recording: "2026-11-07_17-30-02", days: ["2026-11-07"])
        p.add(recording: "2026-11-06_22-00-00", days: ["2026-11-07", "2026-11-06", "2026-11-07"])
        XCTAssertEqual(p.entries.map(\.id), ["2026-11-06|2026-11-06_22-00-00", "2026-11-07|2026-11-06_22-00-00",
                                              "2026-11-07|2026-11-07_09-12-44", "2026-11-07|2026-11-07_17-30-02"])
        XCTAssertEqual(p.pendingSummary, "2026-11-06, 2026-11-07 (3 recordings)")
        let first = p.next(now: t0)!
        XCTAssertEqual(first.recording, "2026-11-06_22-00-00")
        p.setOutput("roads_2026-11-06_22-00-00.kml", for: first.id)
        XCTAssertEqual(p.reservedOutputs(except: "2026-11-07|2026-11-07_09-12-44"), ["roads_2026-11-06_22-00-00.kml"])
        XCTAssertEqual(p.reservedOutputs(except: first.id), [], "an entry doesn't block its own name")
    }

    func testQueueRetryAndGiveUp() {
        var p = DailyPlan()
        let a = "2026-11-06|2026-11-06_08-00-00", b = "2026-11-07|2026-11-07_08-00-00"
        p.add(recording: "2026-11-07_08-00-00", days: ["2026-11-07"])
        p.add(recording: "2026-11-06_08-00-00", days: ["2026-11-06"])
        XCTAssertEqual(p.next(now: t0)?.id, a)
        p.setOutput("roads_2026-11-06_08-00-00.kml", for: a)
        XCTAssertTrue(p.failed(a, now: t0))
        XCTAssertEqual(p.next(now: t0)?.id, b, "a failed map waits")
        XCTAssertEqual(p.nextRetry(after: t0), t0.addingTimeInterval(1800))
        XCTAssertEqual(p.next(now: t0.addingTimeInterval(1800))?.id, a)
        XCTAssertTrue(p.failed(a, now: t0))
        XCTAssertEqual(p.nextRetry(after: t0), t0.addingTimeInterval(7200))
        p.add(recording: "2026-11-06_08-00-00", days: ["2026-11-06"])          // queued again: fresh start
        XCTAssertEqual(p.next(now: t0)?.id, a)
        XCTAssertEqual(p.next(now: t0)?.output, "roads_2026-11-06_08-00-00.kml", "keeps the name it was given")
        XCTAssertTrue(p.failed(a, now: t0))
        XCTAssertTrue(p.failed(a, now: t0))
        XCTAssertFalse(p.failed(a, now: t0), "third failure: dropped")
        XCTAssertEqual(p.entries.map(\.id), [b])
        let round = try? JSONDecoder().decode(DailyPlan.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(round, p)
        p.finished(b)
        XCTAssertTrue(p.isEmpty)
    }

    func testQueueFromEarlierVersionIsSplitPerRecording() throws {
        let old = #"{"days":[{"day":"2026-11-06","attempts":1},{"day":"2026-11-07","attempts":0}]}"#
        var p = try JSONDecoder().decode(DailyPlan.self, from: Data(old.utf8))
        XCTAssertEqual(p.entries.map(\.id), ["2026-11-06|*", "2026-11-07|*"])
        p.split("2026-11-06|*", into: ["2026-11-06_09-00-00", "2026-11-06_14-00-00"])
        XCTAssertEqual(p.entries.map(\.id), ["2026-11-06|2026-11-06_09-00-00", "2026-11-06|2026-11-06_14-00-00", "2026-11-07|*"])
        XCTAssertEqual(p.entries.map(\.attempts), [0, 0, 0])
    }

    func testFileNamesAreNeverReused() {
        XCTAssertEqual(DailyPlan.preferredStem(day: "2026-11-07", recording: "2026-11-07_09-12-44"), "roads_2026-11-07_09-12-44")
        XCTAssertEqual(DailyPlan.preferredStem(day: "2026-11-07", recording: "2026-11-07_09-12-44-2"), "roads_2026-11-07_09-12-44-2")
        XCTAssertEqual(DailyPlan.preferredStem(day: "2026-11-08", recording: "2026-11-07_22-00-00"), "roads_2026-11-08_00-00-00",
                       "the part after midnight")
        let stem = "roads_2026-11-07_09-12-44"
        XCTAssertEqual(DailyPlan.uniqueName(stem, taken: []), "roads_2026-11-07_09-12-44.kml")
        XCTAssertEqual(DailyPlan.uniqueName(stem, taken: ["roads_2026-11-07_09-12-44.kml"]), "roads_2026-11-07_09-12-44_2.kml")
        XCTAssertEqual(DailyPlan.uniqueName(stem, taken: ["roads_2026-11-07_09-12-44.kml", "roads_2026-11-07_09-12-44_2.kml"]),
                       "roads_2026-11-07_09-12-44_3.kml")
        XCTAssertEqual(DailyPlan.uniqueName(stem, taken: [], exists: { $0 == "roads_2026-11-07_09-12-44.kml" }),
                       "roads_2026-11-07_09-12-44_2.kml", "the file system is asked too")
        // Listing names: lowercased; a file iCloud has offloaded still counts.
        let taken = DailyPlan.takenNames(["Roads_2026-11-07_09-12-44.KML", ".roads_2026-11-07_09-12-44_2.kml.icloud", ".icloud", "notes.txt"])
        XCTAssertEqual(taken, ["roads_2026-11-07_09-12-44.kml", "roads_2026-11-07_09-12-44_2.kml", ".icloud", "notes.txt"])
        XCTAssertEqual(DailyPlan.uniqueName(stem, taken: taken), "roads_2026-11-07_09-12-44_3.kml")
        // The old one-file-per-day name is never produced again.
        XCTAssertNotEqual(DailyPlan.uniqueName(DailyPlan.preferredStem(day: "2026-11-07", recording: "2026-11-07_17-30-02"), taken: []),
                          "roads_2026-11-07.kml")
    }

    func testPointsOfOneDayFromSeveralRecordings() {
        func d(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
        let morning = [pt(at: d("2026-10-30T13:00:00Z"), 38.9, -77.0),                // 09:00 in New York
                       pt(at: d("2026-10-30T13:01:00Z"), 38.91, -77.0, seg: 1)]
        let night = [pt(at: d("2026-10-31T03:30:00Z"), 39.0, -77.0),                  // 23:30
                     pt(at: d("2026-10-31T05:00:00Z"), 39.1, -77.0)]                  // 01:00 the next day
        XCTAssertEqual(DailyPlan.days(of: morning + night, calendar: newYork), ["2026-10-30", "2026-10-31"])
        let day = DailyPlan.points(on: "2026-10-30", from: [morning, night], calendar: newYork)
        XCTAssertEqual(day.map(\.latitude), [38.9, 38.91, 39.0])
        XCTAssertEqual(day.map(\.segment), [0, 1, 2], "recordings are never joined")
    }
}

final class BackgroundPacerTests: XCTestCase {
    final class FakeClock: @unchecked Sendable {
        var wall = 0.0, cpu = 0.0
        var slept: [Double] = []
    }

    func testHoldsTheRunToHalfACoreInTheBackground() {
        let c = FakeClock()
        let pacer = BackgroundPacer(sleep: { c.slept.append($0); c.wall += $0 }, clock: { (c.wall, c.cpu) })
        pacer.attachToCurrentThread()
        c.wall += 0.5; c.cpu += 0.5
        XCTAssertEqual(pacer.tick(), 0, "window not over yet")
        c.wall += 0.7; c.cpu += 0.7                              // flat out for 1.2 s
        XCTAssertEqual(pacer.tick(), 0, "in the foreground nothing slows down")
        pacer.inBackground = true
        c.wall += 2; c.cpu += 2
        XCTAssertEqual(pacer.tick(), 2, accuracy: 1e-9, "2 s busy -> 2 s idle")
        c.wall += 4; c.cpu += 1                                  // mostly waiting on the network
        XCTAssertEqual(pacer.tick(), 0)
        c.wall += 20; c.cpu += 20
        XCTAssertEqual(pacer.tick(), 5, "one sleep is capped")
    }

    func testOnlyTheRunsThreadIsPaced() {
        let c = FakeClock()
        let pacer = BackgroundPacer(sleep: { c.slept.append($0) }, clock: { (c.wall, c.cpu) })
        pacer.inBackground = true
        c.wall += 5; c.cpu += 5
        XCTAssertEqual(pacer.tick(), 0, "not attached")
        pacer.attachToCurrentThread()
        c.wall += 5; c.cpu += 5
        let other = Thread {
            XCTAssertEqual(pacer.tick(), 0)
        }
        other.start()
        while !other.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(pacer.tick(), 5)
    }
}

final class ExporterTests: XCTestCase {
    func testRecordsModesBridgeShortStops() {
        let pts = ["walking", "stationary", "walking", "automotive", "stationary", "stationary"].enumerated().map {
            pt(Double($0.offset) * 15, 38.9, -77.0, activity: $0.element)
        }
        XCTAssertEqual(Exporter.recordsModes(pts), ["WALKING", "WALKING", "WALKING", "IN_VEHICLE", "STILL", "STILL"])
    }

    func testCSVRoundTrip() {
        let p = pt(12.345, 38.9123456, -77.0654321, seg: 2, activity: "cycling")
        XCTAssertEqual(TrackPoint(csvLine: p.csvLine)?.latitude, 38.9123456)
        XCTAssertEqual(TrackPoint(csvLine: p.csvLine)?.activity, "cycling")
        XCTAssertNil(TrackPoint(csvLine: TrackPoint.csvHeader))
    }
}

final class TurnDetectorTests: XCTestCase {
    func testUsableCourse() {
        XCTAssertEqual(TurnDetector.usableCourse(course: 90, courseAccuracy: 10, speed: 5), 90)
        XCTAssertNil(TurnDetector.usableCourse(course: -1, courseAccuracy: 10, speed: 5), "no direction")
        XCTAssertNil(TurnDetector.usableCourse(course: 90, courseAccuracy: -1, speed: 5), "direction invalid")
        XCTAssertNil(TurnDetector.usableCourse(course: 90, courseAccuracy: 45, speed: 5), "too uncertain")
        XCTAssertNil(TurnDetector.usableCourse(course: 90, courseAccuracy: 10, speed: 0.5), "too slow")
    }

    func testAngleWrapsAround() {
        XCTAssertEqual(TurnDetector.angle(350, 20), 30)
        XCTAssertEqual(TurnDetector.angle(20, 350), 30)
        XCTAssertEqual(TurnDetector.angle(0, 180), 180)
        XCTAssertEqual(TurnDetector.angle(90, 90), 0)
    }

    func testSixtyDegreesMakesATurn() {
        var t = TurnDetector()
        XCTAssertFalse(t.isTurn(course: 0), "the first usable direction becomes the reference")
        XCTAssertEqual(t.reference, 0)
        XCTAssertFalse(t.isTurn(course: 45), "a bend")
        XCTAssertFalse(t.isTurn(course: 59.9))
        XCTAssertFalse(t.isTurn(course: nil), "no usable direction: nothing to say")
        XCTAssertTrue(t.isTurn(course: 60))
        XCTAssertTrue(t.isTurn(course: 300), "60° the other way, across north")
        t.saved(course: 90)
        XCTAssertFalse(t.isTurn(course: 120), "measured from the new point")
        XCTAssertTrue(t.isTurn(course: 170))
        t.saved(course: nil)
        XCTAssertFalse(t.isTurn(course: 270), "saved while too slow: the next direction is the reference")
        XCTAssertEqual(t.reference, 270)
        t.reset()
        XCTAssertNil(t.reference)
    }
}

final class CleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func rec(_ name: String, daysAgo: Double, kml: Bool = true) -> Cleanup.Local {
        var files = ["\(name).csv": 1000]
        if kml { files["\(name).kml"] = 5000 }
        return Cleanup.Local(name: name, ended: now.addingTimeInterval(-daysAgo * 86400), files: files)
    }

    func testOnlyOldBackedUpRecordingsGo() {
        let backup: [String: Cleanup.Backed] = [
            "a.csv": .init(size: 1000, uploaded: true), "a.kml": .init(size: 5000, uploaded: true),
            "b.csv": .init(size: 1000), "b.kml": .init(size: 4000),                       // KML changed since
            "c.csv": .init(size: nil, inCloudOnly: true), "c.kml": .init(size: nil, inCloudOnly: true),
            "d.csv": .init(size: 1000, uploaded: false), "d.kml": .init(size: 5000),       // not uploaded yet
            "e.csv": .init(size: 1000),
        ]
        XCTAssertEqual(Cleanup.check(rec("a", daysAgo: 8), backup: backup, active: nil, now: now), .delete)
        XCTAssertEqual(Cleanup.check(rec("a", daysAgo: 6.9), backup: backup, active: nil, now: now), .tooNew)
        XCTAssertEqual(Cleanup.check(rec("a", daysAgo: 8), backup: backup, active: "a", now: now), .recording)
        XCTAssertEqual(Cleanup.check(rec("b", daysAgo: 8), backup: backup, active: nil, now: now), .notBackedUp("b.kml"))
        XCTAssertEqual(Cleanup.check(rec("c", daysAgo: 8), backup: backup, active: nil, now: now), .delete, "kept in iCloud only")
        XCTAssertEqual(Cleanup.check(rec("d", daysAgo: 8), backup: backup, active: nil, now: now), .notBackedUp("d.csv"))
        XCTAssertEqual(Cleanup.check(rec("e", daysAgo: 8), backup: backup, active: nil, now: now), .notBackedUp("e.kml"))
        XCTAssertEqual(Cleanup.check(rec("e", daysAgo: 8, kml: false), backup: backup, active: nil, now: now), .delete,
                       "no KML on the phone: the CSV is enough")
        XCTAssertEqual(Cleanup.check(rec("z", daysAgo: 30), backup: backup, active: nil, now: now), .notBackedUp("z.csv"))
    }

    func testWhichFilesAreBackedUp() {
        for name in ["2026-11-08_09-12-44.csv", "2026-11-08_09-12-44.kml", "2026-11-08_09-12-44.log.json",
                     "roads_2026-11-08_09-12-44.KML"] {
            XCTAssertTrue(Cleanup.isBackedUp(name), name)
        }
        for name in ["Inputs", "notes.json", "2026-11-08.gpx", ".DS_Store"] {
            XCTAssertFalse(Cleanup.isBackedUp(name), name)
        }
        let withLog = Cleanup.Local(name: "f", ended: now.addingTimeInterval(-8 * 86400),
                                    files: ["f.csv": 1000, "f.kml": 5000, "f.log.json": 300])
        let backup: [String: Cleanup.Backed] = ["f.csv": .init(size: 1000), "f.kml": .init(size: 5000)]
        XCTAssertEqual(Cleanup.check(withLog, backup: backup, active: nil, now: now), .notBackedUp("f.log.json"),
                       "a log not in the backup yet keeps the recording")
        var all = backup
        all["f.log.json"] = .init(size: 300)
        XCTAssertEqual(Cleanup.check(withLog, backup: all, active: nil, now: now), .delete)
    }

    func testReadingTheBackupListing() {
        let p = Cleanup.backed(name: ".2026-11-08_09-12-44.csv.icloud", size: 120, notDownloaded: false, uploaded: nil)
        XCTAssertEqual(p.key, "2026-11-08_09-12-44.csv")
        XCTAssertTrue(p.value.inCloudOnly)
        let f = Cleanup.backed(name: "2026-11-08_09-12-44.KML", size: 99, notDownloaded: false, uploaded: true)
        XCTAssertEqual(f.key, "2026-11-08_09-12-44.kml")
        XCTAssertEqual(f.value, Cleanup.Backed(size: 99, inCloudOnly: false, uploaded: true))
        XCTAssertTrue(Cleanup.backed(name: "x.csv", size: 10, notDownloaded: true, uploaded: nil).value.inCloudOnly)
    }
}

final class PhotoPathTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        return c
    }
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    func testSpans() {
        let day = date("2026-11-20 15:00")
        let d = PhotoPath.interval(.day, day: day, from: day, to: day, calendar: cal)!
        XCTAssertEqual(d.start, date("2026-11-20 00:00"))
        XCTAssertEqual(d.end, date("2026-11-21 00:00"))
        let r = PhotoPath.interval(.range, day: day, from: date("2026-11-22 09:00"), to: date("2026-11-18 23:00"), calendar: cal)!
        XCTAssertEqual(r.start, date("2026-11-18 00:00"), "ends either way round")
        XCTAssertEqual(r.end, date("2026-11-23 00:00"))
        XCTAssertNil(PhotoPath.interval(.all, day: day, from: day, to: day, calendar: cal))
        XCTAssertEqual(PhotoPath.fileName(.day, day: day, from: day, to: day, calendar: cal), "photos_2026-11-20.kml")
        XCTAssertEqual(PhotoPath.fileName(.range, day: day, from: date("2026-11-22 09:00"), to: date("2026-11-18 09:00"), calendar: cal),
                       "photos_2026-11-18_to_2026-11-22.kml")
        XCTAssertEqual(PhotoPath.fileName(.range, day: day, from: day, to: day, calendar: cal), "photos_2026-11-20.kml")
        XCTAssertEqual(PhotoPath.fileName(.all, day: day, from: day, to: day, calendar: cal), "photos_all.kml")
    }

    func testKMLLikeExif2kml() throws {
        let pts = [
            PhotoPath.Point(name: "IMG_0002", time: date("2026-11-20 10:05"), latitude: 38.91, longitude: -77.04, altitude: 30),
            PhotoPath.Point(name: "IMG_0001", time: date("2026-11-20 10:00"), latitude: 38.90, longitude: -77.03, altitude: nil),
            PhotoPath.Point(name: "A&B", time: date("2026-11-20 10:10"), latitude: 38.92, longitude: -77.05, altitude: nil),
        ]
        XCTAssertEqual(PhotoPath.title(pts), "Photo Path - IMG_0001 to A&B")
        let kml = PhotoPath.kml(pts, title: PhotoPath.title(pts), pins: true, calendar: cal)
        XCTAssertNoThrow(try XMLParserCheck.parse(kml))
        XCTAssertTrue(kml.contains("<name>Photo Path - IMG_0001 to A&amp;B</name>"))
        XCTAssertTrue(kml.contains("<name>IMG_0001</name><description>Taken 2026-11-20 10:00:00</description>"))
        XCTAssertTrue(kml.contains("wht-circle-lv.png"))
        // The line goes in the order the photos were taken, with altitude where known.
        XCTAssertTrue(kml.contains("-77.030000,38.900000\n-77.040000,38.910000,30.0\n-77.050000,38.920000\n</coordinates>"))
        let first = try XCTUnwrap(kml.range(of: "<name>IMG_0001</name>")).lowerBound
        let second = try XCTUnwrap(kml.range(of: "<name>IMG_0002</name>")).lowerBound
        XCTAssertTrue(first < second)

        let noPins = PhotoPath.kml(pts, title: "x", pins: false, calendar: cal)
        XCTAssertFalse(noPins.contains("<Point>"))
        XCTAssertTrue(noPins.contains("<name>Route Path</name>"))
        let one = PhotoPath.kml([pts[0]], title: "x", pins: true, calendar: cal)
        XCTAssertFalse(one.contains("LineString"), "one photo: a marker, no line")
    }
}
