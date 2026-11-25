import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
#if canImport(FormsCheck)
@testable import FormsCheck
#endif

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private func pt(_ s: TimeInterval, _ lat: Double, _ lon: Double, seg: Int = 0) -> TrackPoint {
    TrackPoint(segment: seg, time: t0.addingTimeInterval(s), latitude: lat, longitude: lon, horizontalAccuracy: 5,
               altitude: nil, verticalAccuracy: nil, speed: nil, speedAccuracy: nil, course: nil, courseAccuracy: nil,
               activity: nil)
}

final class RecordingLogTests: XCTestCase {
    let boot = t0.addingTimeInterval(-86400)
    let expiry = t0.addingTimeInterval(5 * 86400)

    func beat(_ s: TimeInterval, boot: Date? = nil, expiry: Date?? = nil, build: String = "1.0 (1)") -> Interruption.Heartbeat {
        Interruption.Heartbeat(time: t0.addingTimeInterval(s), boot: boot ?? self.boot,
                               expiry: expiry ?? self.expiry, build: build)
    }

    func cause(_ last: Interruption.Heartbeat?, bootNow: Date? = nil, expiryNow: Date?? = nil, build: String = "1.0 (1)",
               access: Bool = false, now: TimeInterval = 3600) -> String {
        Interruption.cause(last: last, bootNow: bootNow ?? boot, expiryNow: expiryNow ?? expiry, buildNow: build,
                           waitedForLocationAccess: access, now: t0.addingTimeInterval(now))
    }

    func testCauses() {
        XCTAssertTrue(cause(beat(0)).hasPrefix("iOS closed Waytrace"))
        XCTAssertTrue(cause(beat(0), bootNow: t0.addingTimeInterval(1800)).hasPrefix("The phone was off or restarted"))
        XCTAssertTrue(cause(beat(0), bootNow: boot.addingTimeInterval(2)).hasPrefix("iOS closed"), "boot time read twice wobbles a little")
        XCTAssertTrue(cause(beat(0), expiryNow: expiry.addingTimeInterval(7 * 86400)).hasPrefix("Waytrace was re-signed"))
        let expired = beat(0, expiry: t0.addingTimeInterval(600))
        XCTAssertTrue(cause(expired, expiryNow: t0.addingTimeInterval(7 * 86400)).hasPrefix("Waytrace's signing ran out"))
        XCTAssertEqual(cause(beat(0), access: true), "Location access was off")
        XCTAssertEqual(cause(beat(0), build: "1.0 (2)"), "Waytrace was updated")
        XCTAssertEqual(cause(nil), "Waytrace was reinstalled or updated")
    }

    func testGapDescription() {
        var g = RecordingLog.Gap(from: t0, to: t0.addingTimeInterval(17 * 60), cause: "The phone was off or restarted")
        XCTAssertEqual(Interruption.describe(g), "17-minute gap: the phone was off or restarted.")
        g.before = .init(latitude: 38.90, longitude: -77.0, time: t0)
        g.after = .init(latitude: 38.94, longitude: -77.0, time: g.to)
        XCTAssertEqual(g.distance ?? 0, 4448, accuracy: 2)
        XCTAssertEqual(Interruption.describe(g), "17-minute gap: the phone was off or restarted; moved 4.4 km meanwhile.")
        g.to = t0.addingTimeInterval(2 * 3600 + 5 * 60)
        XCTAssertTrue(Interruption.describe(g).hasPrefix("2 h 5 min gap"))
    }

    func testRests() {
        var log = RecordingLog()
        log.restStarted(at: t0)
        log.restEnded(at: t0.addingTimeInterval(600), wokeBy: "12 steps")
        log.restStarted(at: t0.addingTimeInterval(900))
        log.restEnded(at: t0.addingTimeInterval(1500), wokeBy: "the GPS check found you 300 m away")
        log.restStarted(at: t0.addingTimeInterval(2000))
        log.restEnded(at: t0.addingTimeInterval(2100), wokeBy: "15 steps")
        log.restEnded(at: t0.addingTimeInterval(2200), wokeBy: "motion: driving")    // nothing open: ignored
        XCTAssertEqual(log.restedTime, 1300)
        XCTAssertEqual(log.wakeCounts.map(\.reason), ["steps", "3-minute GPS check"])
        XCTAssertEqual(log.wakeCounts.map(\.count), [2, 1])
        XCTAssertEqual(log.lateWakes.count, 1)
    }

    func testSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = dir.appendingPathComponent("2026-11-16_08-00-00.csv")
        XCTAssertEqual(RecordingLog.url(for: rec).lastPathComponent, "2026-11-16_08-00-00.log.json")
        XCTAssertEqual(RecordingLog.load(for: rec), RecordingLog(), "no file yet")
        var log = RecordingLog()
        log.gaps.append(.init(from: t0, to: t0.addingTimeInterval(900), cause: "x"))
        log.restStarted(at: t0)
        log.save(for: rec)
        XCTAssertEqual(RecordingLog.load(for: rec), log)
    }

    func testGapsInKML() throws {
        var g = RecordingLog.Gap(from: t0.addingTimeInterval(60), to: t0.addingTimeInterval(1200), cause: "iOS closed Waytrace")
        g.before = .init(latitude: 38.90, longitude: -77.0, time: g.from)
        g.after = .init(latitude: 38.91, longitude: -77.01, time: g.to)
        let pts = [pt(0, 38.9, -77.0), pt(60, 38.9, -77.0), pt(1200, 38.91, -77.01, seg: 1)]
        let kml = Exporter.kml([ExportTrack(name: "t", points: pts, gaps: [g])], title: "t")
        XCTAssertTrue(kml.contains("<name>Gaps (1)</name>"))
        XCTAssertTrue(kml.contains("<coordinates>-77.0000000,38.9000000 -77.0100000,38.9100000</coordinates>"))
        XCTAssertTrue(kml.contains("<Data name=\"minutes\"><value>19</value></Data>"))
        XCTAssertNoThrow(try XMLParserCheck.parse(kml))
        XCTAssertFalse(Exporter.kml([ExportTrack(name: "t", points: pts)], title: "t").contains("Gaps"))
    }
}

final class ExpiryReminderTests: XCTestCase {
    let expiry = t0.addingTimeInterval(5 * 86400)

    func testBothRemindersAhead() {
        let r = SigningInfo.reminders(expiry: expiry, now: t0, alreadyWarnedNow: false)
        XCTAssertEqual(r, [.init(kind: .day, at: expiry.addingTimeInterval(-86400)),
                           .init(kind: .lastCall, at: expiry.addingTimeInterval(-3 * 3600))])
    }

    func testOpenedInTheLastDay() {
        let now = expiry.addingTimeInterval(-10 * 3600)
        XCTAssertEqual(SigningInfo.reminders(expiry: expiry, now: now, alreadyWarnedNow: false),
                       [.init(kind: .day, at: now.addingTimeInterval(5)), .init(kind: .lastCall, at: expiry.addingTimeInterval(-3 * 3600))])
        XCTAssertEqual(SigningInfo.reminders(expiry: expiry, now: now, alreadyWarnedNow: true),
                       [.init(kind: .lastCall, at: expiry.addingTimeInterval(-3 * 3600))], "the right-away warning only once")
        let late = expiry.addingTimeInterval(-3600)
        XCTAssertEqual(SigningInfo.reminders(expiry: expiry, now: late, alreadyWarnedNow: true), [])
        XCTAssertEqual(SigningInfo.reminders(expiry: expiry, now: expiry.addingTimeInterval(1), alreadyWarnedNow: false), [])
    }

    func testBannerAndResign() {
        XCTAssertFalse(SigningInfo.isExpiringSoon(expiry: expiry, now: t0))
        XCTAssertTrue(SigningInfo.isExpiringSoon(expiry: expiry, now: expiry.addingTimeInterval(-3600)))
        XCTAssertFalse(SigningInfo.isExpiringSoon(expiry: expiry, now: expiry.addingTimeInterval(60)))
        XCTAssertTrue(SigningInfo.wasResigned(previous: expiry, current: expiry.addingTimeInterval(5 * 86400)))
        XCTAssertFalse(SigningInfo.wasResigned(previous: expiry, current: expiry))
        XCTAssertFalse(SigningInfo.wasResigned(previous: nil, current: expiry), "first launch of this version")
    }
}

final class DailyPhotoTests: XCTestCase {
    // Two recordings that day: 0–10 min walking north, and 60–70 min.
    let morning = (0...10).map { pt(Double($0) * 60, 38.900 + Double($0) * 0.001, -77.0) }
    let later = (60...70).map { pt(Double($0) * 60, 39.000 + Double($0 - 60) * 0.001, -77.0) }

    func photo(_ s: TimeInterval, _ name: String, lat: Double? = nil, lon: Double? = nil) -> PhotoInfo {
        PhotoInfo(id: name, fileName: name, taken: t0.addingTimeInterval(s), latitude: lat, longitude: lon)
    }

    func testOnlyPhotosTakenDuringARecording() {
        let photos = [photo(90, "IMG_0001.HEIC", lat: 38.95, lon: -77.02), photo(30 * 60, "IMG_0002.HEIC", lat: 38.97, lon: -77.0),
                      photo(65 * 60 + 30, "IMG_0003.HEIC"), photo(90, "IMG_0001.HEIC", lat: 38.95, lon: -77.02)]
        let (m, u) = PhotoPlacer.place(photos, onEach: [morning, later])
        XCTAssertEqual(m.map(\.photo.fileName), ["IMG_0001.HEIC", "IMG_0003.HEIC"], "the one between recordings is left out")
        XCTAssertEqual(m[1].latitude, 39.0055, accuracy: 1e-9, "placed between the points either side")
        XCTAssertEqual(u, [])
    }

    func testNeighbors() {
        let (b, a) = PhotoPlacer.neighbors(at: t0.addingTimeInterval(90), in: morning)
        XCTAssertEqual(b?.time, t0.addingTimeInterval(60))
        XCTAssertEqual(a?.time, t0.addingTimeInterval(120))
        XCTAssertNil(PhotoPlacer.neighbors(at: t0.addingTimeInterval(-10), in: morning).before)
    }

    func testFolderInTheRoadsFile() throws {
        let (m, _) = PhotoPlacer.place([photo(90, "IMG_0001.HEIC", lat: 38.95, lon: -77.02), photo(65 * 60 + 30, "IMG_0003.MOV")],
                                       onEach: [morning, later])
        let folder = Exporter.dailyPhotoFolder(m, points: morning + later)
        XCTAssertTrue(folder.contains("<name>Photos (2)</name>"))
        XCTAssertTrue(folder.contains("<name>IMG_0001</name>"), "labelled by file name, not time")
        XCTAssertTrue(folder.contains("<coordinates>-77.0200000,38.9500000</coordinates>"), "at the photo's own location")
        XCTAssertTrue(folder.contains("Between the recorded points at"))
        XCTAssertTrue(folder.contains("<Data name=\"point_before_time\">"))
        XCTAssertTrue(folder.contains("#wtPhotoByTime"))

        let roads = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Road surface</name>
        <Placemark><name>track 2026-11-16</name><Polygon><outerBoundaryIs><LinearRing><coordinates>-77,38.9,0 -77.001,38.9,0 -77.001,38.901,0 -77,38.9,0</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
        </Document></kml>
        """
        let once = try XCTUnwrap(Exporter.addingFolder(folder, to: roads))
        XCTAssertNoThrow(try XMLParserCheck.parse(once))
        XCTAssertTrue(once.contains("<Polygon>"), "the road surface stays")
        let twice = try XCTUnwrap(Exporter.addingFolder(folder, to: once))
        XCTAssertEqual(twice.components(separatedBy: "<name>Photos (2)</name>").count, 2, "re-running replaces, not doubles")
        XCTAssertNil(Exporter.addingFolder(folder, to: "not kml"))
    }
}

final class BatteryLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func s(_ minutes: Double, _ level: Double, charging: Bool = false, low: Bool = false) -> RecordingLog.BatterySample {
        RecordingLog.BatterySample(time: t0.addingTimeInterval(minutes * 60), level: level, charging: charging, lowPower: low)
    }

    func testOnlyChangesAreNoted() {
        var log = RecordingLog()
        XCTAssertTrue(log.noteBattery(s(0, 0.9)))
        XCTAssertFalse(log.noteBattery(s(1, 0.9)), "nothing changed")
        XCTAssertTrue(log.noteBattery(s(2, 0.9), force: true), "start, stop and rests always count")
        XCTAssertTrue(log.noteBattery(s(3, 0.85)))
        XCTAssertTrue(log.noteBattery(s(4, 0.85, low: true)), "Low Power Mode turned on")
        XCTAssertFalse(log.noteBattery(s(5, -1)), "level unknown")
        XCTAssertEqual(log.battery.count, 4)
    }

    func testOldLogsStillLoad() throws {
        let old = #"{"gaps":[],"rests":[{"from":1800000000,"to":1800000600,"wokeBy":"12 steps"}]}"#
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        let log = try d.decode(RecordingLog.self, from: Data(old.utf8))
        XCTAssertEqual(log.rests.count, 1)
        XCTAssertEqual(log.battery, [])
        XCTAssertNil(log.batteryReport, "no samples, no report")
    }

    func testReport() throws {
        var log = RecordingLog()
        // 0–60 min GPS on: 100% -> 95%. 60–120 resting: 95% -> 94%. 120–150 on the charger.
        // 150–210 on: 99% -> 95%.
        log.rests = [RecordingLog.Rest(from: t0.addingTimeInterval(3600), to: t0.addingTimeInterval(7200), wokeBy: "motion: walking")]
        for x in [s(0, 1.0), s(60, 0.95), s(120, 0.94), s(121, 0.94, charging: true), s(150, 0.99, charging: true),
                  s(151, 0.99), s(210, 0.95, low: true)] {
            log.noteBattery(x, force: true)
        }
        let r = try XCTUnwrap(log.batteryReport)
        XCTAssertEqual(r.used, 0.05 + 0.01 + 0.04, accuracy: 1e-9)
        // The minutes plugging in and unplugging count as charger time.
        XCTAssertEqual(r.onBattery, (60 + 60 + 59) * 60, accuracy: 1e-6)
        XCTAssertEqual(r.charging, (1 + 29 + 1) * 60, accuracy: 1e-6)
        XCTAssertEqual(r.perHour!, 0.10 / (179.0 / 60), accuracy: 1e-9)
        XCTAssertEqual(r.perHourResting!, 0.01, accuracy: 1e-9)
        XCTAssertEqual(r.perHourActive!, 0.09 / (119.0 / 60), accuracy: 1e-9)
        XCTAssertTrue(r.lowPower)
        XCTAssertEqual(r.first, 1.0)
        XCTAssertEqual(r.last, 0.95)
    }

    func testShortRecordingsGiveNoRates() throws {
        var log = RecordingLog()
        log.noteBattery(s(0, 0.8))
        log.noteBattery(s(20, 0.75))
        let r = try XCTUnwrap(log.batteryReport)
        XCTAssertEqual(r.used, 0.05, accuracy: 1e-9)
        XCTAssertNil(r.perHour, "under half an hour")
        XCTAssertNil(r.perHourResting)
    }
}
