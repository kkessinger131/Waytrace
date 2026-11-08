import Foundation
import CoreMotion

/// Live motion readings while a recording runs: the motion coprocessor's activity (walking,
/// driving, still…) and the step count. Both come from the low-power coprocessor that runs
/// anyway, so watching them costs next to nothing. They are what lets the GPS rest when you
/// stop and wake within seconds when you set off.
@MainActor
final class MotionWatch {
    private let activity = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private(set) var running = false

    /// True if this iPhone has the coprocessor and Waytrace may use it (or hasn't asked yet).
    static var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() != .denied
            && CMMotionActivityManager.authorizationStatus() != .restricted
    }

    func start(onActivity: @escaping @MainActor (MotionReading, Date) -> Void,
               onSteps: @escaping @MainActor (Int, Date) -> Void) {
        guard !running else { return }
        running = true
        if CMMotionActivityManager.isActivityAvailable() {
            activity.startActivityUpdates(to: .main) { a in
                guard let a else { return }
                let conf: MotionReading.Confidence
                switch a.confidence {
                case .low: conf = .low
                case .medium: conf = .medium
                case .high: conf = .high
                @unknown default: conf = .low
                }
                let reading = MotionReading.from(walking: a.walking, running: a.running, cycling: a.cycling,
                                                 automotive: a.automotive, stationary: a.stationary, confidence: conf)
                // Stamped with when it arrived, not when the activity began (a drive that began
                // an hour ago mustn't make the stillness clock think you stopped an hour ago).
                MainActor.assumeIsolated { onActivity(reading, Date()) }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { data, _ in
                guard let steps = data?.numberOfSteps.intValue else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onSteps(steps, Date()) }
                }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        activity.stopActivityUpdates()
        pedometer.stopUpdates()
    }
}
