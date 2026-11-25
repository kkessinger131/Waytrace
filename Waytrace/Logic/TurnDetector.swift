import Foundation

/// Extra points at sharp turns. Between the regular save attempts (every 10 s by default),
/// a fix whose direction of travel differs by `minTurn` degrees or more from the direction
/// at the last saved point is saved straight away, so corners stay sharp in the line: at
/// 10 s and 30 mph a corner could otherwise be cut by up to about 130 m.
///
/// It costs nothing in battery: Core Location already delivers about one fix a second while
/// you move, each with its direction of travel; this only looks at it. The usual rules still
/// apply to a turn point (distance from the last point, accuracy, drift guard).
struct TurnDetector: Equatable, Sendable {
    /// Degrees of change that make a turn.
    static let minTurn = 60.0
    /// Directions less certain than this (degrees) are ignored.
    static let maxCourseAccuracy = 30.0
    /// Below this speed (m/s) the direction of travel is too noisy to use.
    static let minSpeed = 1.0

    /// The direction at the last saved point, or the first usable one after it.
    private(set) var reference: Double?

    /// A fix's direction of travel if it can be trusted, else nil. `course` and
    /// `courseAccuracy` are negative when Core Location has no direction.
    static func usableCourse(course: Double, courseAccuracy: Double, speed: Double) -> Double? {
        guard course >= 0, speed >= minSpeed, courseAccuracy >= 0, courseAccuracy <= maxCourseAccuracy else { return nil }
        return course
    }

    /// The smaller angle between two directions, 0...180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Call with every fix. True when its direction has turned far enough from the reference.
    mutating func isTurn(course: Double?) -> Bool {
        guard let course else { return false }
        guard let ref = reference else {
            reference = course
            return false
        }
        return Self.angle(ref, course) >= Self.minTurn
    }

    /// Call when a point is saved, with its usable direction (or nil).
    mutating func saved(course: Double?) {
        reference = course
    }

    /// After a gap or a GPS rest the old direction means nothing.
    mutating func reset() {
        reference = nil
    }
}
