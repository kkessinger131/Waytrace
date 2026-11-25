import AppIntents

// Start and stop recording from Control Center, Shortcuts or Siri. This file is built into
// both the app and the Control Center extension (WaytraceControls): the extension needs the
// intents to show its buttons, and the app runs them. Each one opens Waytrace first, because
// iOS only lets an app on screen start the GPS.

/// What a control asked for. The app sets `handler` at launch; in the extension it stays nil.
enum RecordingControl {
    enum Action: Sendable { case start, stop }

    @MainActor static var handler: (@MainActor (Action) -> Void)?

    @MainActor static func run(_ action: Action) {
        handler?(action)
    }
}

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start recording"
    static var description = IntentDescription("Opens Waytrace and starts recording, as RECORD does.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingControl.run(.start)
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var description = IntentDescription("Opens Waytrace and asks whether to stop the recording, as STOP does.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordingControl.run(.stop)
        return .result()
    }
}
