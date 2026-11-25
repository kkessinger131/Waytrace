import SwiftUI
import UIKit

@main
struct WaytraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = LocationRecorder.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = "record"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                ContentView()
                    .tabItem { Label("Record", systemImage: "record.circle") }
                    .tag("record")
                RoadsView()
                    .tabItem { Label("Roads", systemImage: "road.lanes") }
                    .tag("roads")
                PhotosView()
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag("photos")
            }
            .environmentObject(recorder)
            .preferredColorScheme(.dark)
            // Control Center's Start and Stop buttons land on the Record tab.
            .onChange(of: recorder.controlRevision) { _, _ in tab = "record" }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recorder.appBecameActive()
                Notifier.shared.appCameForward()
                DailyRoads.shared.kick()
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Runs on every launch, including a silent background relaunch that iOS performs
        // for a significant-location-change event after it has terminated the app.
        // If a recording was in progress, it picks up exactly where it left off.
        LocationRecorder.shared.resumeIfNeeded()
        // Control Center, Shortcuts and Siri: Start records at once; Stop asks first.
        RecordingControl.handler = { action in
            let recorder = LocationRecorder.shared
            switch action {
            case .start: recorder.record()
            case .stop: recorder.requestStop()
            }
            recorder.controlUsed()
        }
        Notifier.shared.attach()
        Task { await Notifier.shared.scheduleSigningReminder() }
        _ = RoadJobs.shared            // installs the background pacing hook
        return true
    }
}
