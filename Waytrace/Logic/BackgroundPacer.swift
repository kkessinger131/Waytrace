import Foundation

/// Keeps a Road to KML run from looking like a runaway while the app is in the background.
///
/// iOS ends a background app that keeps the CPU busy for too long (about 80% over a minute;
/// the recording would be cut off with it). The engine calls `tick()` between small pieces of
/// work; while the app is in the background, the pacer sleeps just long enough to hold the
/// run's thread to about half of one CPU core. In the foreground it does nothing.
final class BackgroundPacer: @unchecked Sendable {
    /// Share of one core the run may use in the background.
    let limit: Double
    /// The pacer looks at CPU use over windows at least this long.
    let window: TimeInterval
    /// Longest single sleep.
    let maxSleep: TimeInterval

    private let lock = NSLock()
    private var _inBackground = false
    private var thread: pthread_t?
    private var windowWall = 0.0
    private var windowCPU = 0.0
    private let sleep: (TimeInterval) -> Void
    private let clock: () -> (wall: Double, cpu: Double)

    init(limit: Double = 0.5, window: TimeInterval = 1, maxSleep: TimeInterval = 5,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         clock: (() -> (wall: Double, cpu: Double))? = nil) {
        self.limit = limit
        self.window = window
        self.maxSleep = maxSleep
        self.sleep = sleep
        self.clock = clock ?? BackgroundPacer.systemClock
    }

    var inBackground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _inBackground }
        set { lock.lock(); _inBackground = newValue; lock.unlock() }
    }

    /// Call on the engine's thread when a run starts: only that thread is paced.
    func attachToCurrentThread() {
        let now = clock()
        lock.lock()
        thread = pthread_self()
        windowWall = now.wall
        windowCPU = now.cpu
        lock.unlock()
    }

    func detach() {
        lock.lock(); thread = nil; lock.unlock()
    }

    /// Returns how long it slept (for tests).
    @discardableResult
    func tick() -> TimeInterval {
        lock.lock()
        guard let t = thread, pthread_equal(t, pthread_self()) != 0 else { lock.unlock(); return 0 }
        let background = _inBackground
        let now = clock()
        let wall = now.wall - windowWall
        guard wall >= window else { lock.unlock(); return 0 }
        let used = now.cpu - windowCPU
        lock.unlock()

        var slept: TimeInterval = 0
        if background {
            // Enough idle time that used / (wall + pause) comes down to the limit.
            let pause = min(maxSleep, used / limit - wall)
            if pause > 0.01 {
                sleep(pause)
                slept = pause
            }
        }
        let after = clock()
        lock.lock()
        windowWall = after.wall
        windowCPU = after.cpu
        lock.unlock()
        return slept
    }

    static func systemClock() -> (wall: Double, cpu: Double) {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        let cpu = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
        return (ProcessInfo.processInfo.systemUptime, cpu)
    }
}
