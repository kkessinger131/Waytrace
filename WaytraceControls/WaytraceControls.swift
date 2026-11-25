import AppIntents
import SwiftUI
import WidgetKit

/// Waytrace's Control Center buttons (iOS 18 and later): Start recording and Stop recording.
/// Add them from Control Center › + › Add a Control, then search for Waytrace. Each opens
/// Waytrace; Stop asks first, as the STOP button does.
@main
struct WaytraceControlsBundle: WidgetBundle {
    var body: some Widget {
        StartRecordingControl()
        StopRecordingControl()
    }
}

struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Waytrace.StartRecording") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Start recording", systemImage: "record.circle")
            }
        }
        .displayName("Start recording")
        .description("Opens Waytrace and starts recording.")
    }
}

struct StopRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "Waytrace.StopRecording") {
            ControlWidgetButton(action: StopRecordingIntent()) {
                Label("Stop recording", systemImage: "stop.circle")
            }
        }
        .displayName("Stop recording")
        .description("Opens Waytrace and asks whether to stop recording.")
    }
}
