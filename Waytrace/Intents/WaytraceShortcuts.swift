import AppIntents

/// Puts Start recording and Stop recording in the Shortcuts app and Siri without any setup
/// (Back Tap and automations can use them too).
struct WaytraceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Start recording",
                    systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording in \(.applicationName)", "Stop \(.applicationName)"],
                    shortTitle: "Stop recording",
                    systemImageName: "stop.circle")
    }
}
