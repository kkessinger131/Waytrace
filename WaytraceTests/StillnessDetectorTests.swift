import Foundation
import XCTest
#if canImport(FormsCheck)
@testable import FormsCheck
#endif

/// The rules for resting the GPS: never during a red light, a short break or a traffic jam;
/// always back on at the first sign of moving.
final class StillnessDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    let lat = 38.93, lon = -77.07

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// A fix `north` meters north of the start, `s` seconds in.
    func fix(_ s: TimeInterval, north: Double = 0, acc: Double = 8) -> StillnessDetector.Fix {
        .init(latitude: lat + north / (6_371_008.8 * .pi / 180), longitude: lon, accuracy: acc, time: at(s))
    }

    let still = MotionReading.from(walking: false, running: false, cycling: false, automotive: false, stationary: true, confidence: .high)
    let walking = MotionReading.from(walking: true, running: false, cycling: false, automotive: false, stationary: false, confidence: .high)
    let stoppedInCar = MotionReading.from(walking: false, running: false, cycling: false, automotive: true, stationary: true, confidence: .high)
    let driving = MotionReading.from(walking: false, running: false, cycling: false, automotive: true, stationary: false, confidence: .low)

    /// Ticks every 15 s from `from` to `to` (seconds); returns the events.
    func run(_ d: inout StillnessDetector, _ from: TimeInterval, _ to: TimeInterval) -> [(TimeInterval, StillnessDetector.Event)] {
        var out: [(TimeInterval, StillnessDetector.Event)] = []
        var s = from
        while s <= to {
            if let e = d.tick(at(s)) { out.append((s, e)) }
            s += 15
        }
        return out
    }

    func testRestsAfterFiveStillMinutes() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        XCTAssertNil(d.fix(fix(0)))
        XCTAssertNil(d.motion(still, at: at(1)))
        XCTAssertTrue(run(&d, 0, 285).isEmpty, "not before 5 minutes")
        XCTAssertEqual(d.tick(at(300)), .rest)
        XCTAssertTrue(d.isResting)
    }

    func testRedLightAndTrafficJamNeverRest() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(stoppedInCar, at: at(0))       // automotive + stationary: waiting at a light
        XCTAssertTrue(run(&d, 0, 1800).isEmpty, "30 minutes stuck in traffic: GPS stays on")
        XCTAssertFalse(d.isResting)
    }

    func testShortHikingBreakDoesntRest() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(walking, at: at(0))
        _ = d.steps(400, at: at(60))
        _ = d.motion(still, at: at(70))             // sit on a rock
        XCTAssertTrue(run(&d, 70, 70 + 4 * 60).isEmpty, "a 4-minute break")
        _ = d.motion(walking, at: at(70 + 250))     // and off again
        _ = d.steps(450, at: at(70 + 260))
        XCTAssertTrue(run(&d, 330, 600).isEmpty)
    }

    func testLongBreakRestsAndStepsWakeIt() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(walking, at: at(0))
        _ = d.steps(400, at: at(30))
        _ = d.motion(still, at: at(60))
        XCTAssertEqual(run(&d, 60, 400).map(\.1), [.rest])
        XCTAssertNil(d.steps(405, at: at(500)), "a few steps (shifting about) don't wake it")
        XCTAssertEqual(d.steps(412, at: at(510)), .wake("12 steps"))
        XCTAssertFalse(d.isResting)
        XCTAssertNil(d.anchor, "re-anchored by the next sharp fix")
    }

    func testPacingAroundDoesntRest() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(still, at: at(0))
        var steps = 0
        for m in 0..<20 {                           // 40 steps a minute in a shop, inside the circle
            steps += 40
            _ = d.steps(steps, at: at(Double(m) * 60 + 30))
            XCTAssertTrue(run(&d, Double(m) * 60, Double(m) * 60 + 45).isEmpty, "minute \(m)")
        }
    }

    func testMovingOutOfTheCircleRestartsTheClock() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(still, at: at(0))
        _ = d.fix(fix(200, north: 35))              // inside 40 m
        XCTAssertNil(d.tick(at(240)))
        _ = d.fix(fix(250, north: 90))              // outside: you moved
        XCTAssertNil(d.tick(at(320)))
        XCTAssertNil(d.tick(at(540)))
        XCTAssertEqual(d.tick(at(550)), .rest)
    }

    func testIndoorDriftStillRests() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0, acc: 65))
        _ = d.motion(still, at: at(0))
        for (i, n) in [30.0, -45, 60, -20, 75].enumerated() {   // wifi wander, ±65 m
            _ = d.fix(fix(Double(i + 1) * 50, north: n, acc: 65))
        }
        XCTAssertEqual(d.tick(at(300)), .rest)
    }

    func testWithoutMotionDataTheWaitDoubles() {
        var d = StillnessDetector(motionAvailable: false, now: t0)
        _ = d.fix(fix(0))
        XCTAssertNil(d.tick(at(300)))
        XCTAssertNil(d.tick(at(599)))
        XCTAssertEqual(d.tick(at(600)), .rest)

        var e = StillnessDetector(motionAvailable: true, now: t0)   // allowed, but nothing heard yet
        _ = e.fix(fix(0))
        XCTAssertNil(e.tick(at(300)))
        XCTAssertEqual(e.tick(at(600)), .rest)
    }

    func testNoFixNoRest() {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.motion(still, at: at(0))
        _ = d.fix(fix(10, acc: 400))                // too vague to anchor on
        XCTAssertTrue(run(&d, 0, 1200).isEmpty)
    }

    func resting() -> StillnessDetector {
        var d = StillnessDetector(motionAvailable: true, now: t0)
        _ = d.fix(fix(0))
        _ = d.motion(still, at: at(0))
        _ = d.steps(100, at: at(0))
        XCTAssertEqual(d.tick(at(300)), .rest)
        return d
    }

    func testDrivingOffWakesEvenAtLowConfidence() {
        var d = resting()
        XCTAssertNil(d.motion(stoppedInCar, at: at(400)), "sitting in the parked car")
        XCTAssertEqual(d.motion(driving, at: at(420)), .wake("motion: driving"))
    }

    func testCoarseFixWakesOnlyWhenClearlyElsewhere() {
        var d = resting()
        XCTAssertNil(d.fix(fix(350, north: 1500, acc: 1414)), "cell-tower jitter")
        XCTAssertEqual(d.fix(fix(360, north: 3000, acc: 1414)), .wake("a rough position 3000 m away"))
    }

    func testGeofenceExitWakes() {
        var d = resting()
        XCTAssertEqual(d.leftRegion(at: at(400)), .wake("left the area"))
        XCTAssertNil(d.leftRegion(at: at(410)), "already awake")
    }

    func testGPSCheckEveryThreeMinutes() {
        var d = resting()
        XCTAssertNil(d.tick(at(300 + 170)))
        XCTAssertEqual(d.tick(at(300 + 180)), .startCheck)
        XCTAssertNil(d.fix(fix(485, acc: 300)), "too vague to decide")
        XCTAssertEqual(d.fix(fix(490, north: 10)), .endCheck, "still here")
        XCTAssertTrue(d.isResting)
        XCTAssertNil(d.tick(at(600)))
        XCTAssertEqual(d.tick(at(670)), .startCheck)
        XCTAssertEqual(d.fix(fix(675, north: 400)), .wake("the GPS check found you 400 m away"))
    }

    func testCheckWithNoFixGivesUpAndRestsAgain() {
        var d = resting()
        XCTAssertEqual(d.tick(at(480)), .startCheck)
        XCTAssertNil(d.tick(at(495)))
        XCTAssertEqual(d.tick(at(505)), .endCheck)
        XCTAssertTrue(d.isResting)
        XCTAssertEqual(d.checkNow(at(510)), .startCheck, "opening the app looks right away")
    }

    func testMotionReadings() {
        XCTAssertFalse(still.moving)
        XCTAssertFalse(still.wakes)
        XCTAssertTrue(stoppedInCar.moving, "a red light keeps the GPS on")
        XCTAssertFalse(stoppedInCar.wakes)
        XCTAssertTrue(driving.wakes)
        XCTAssertFalse(driving.moving, "low confidence doesn't hold off resting")
        let unsure = MotionReading.from(walking: true, running: false, cycling: false, automotive: false, stationary: false, confidence: .low)
        XCTAssertFalse(unsure.wakes)
        let cycling = MotionReading.from(walking: false, running: false, cycling: true, automotive: false, stationary: false, confidence: .medium)
        XCTAssertTrue(cycling.moving && cycling.wakes)
        XCTAssertEqual(cycling.label, "motion: cycling")
    }
}
