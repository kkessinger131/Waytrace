import SwiftUI
import UIKit

@main
struct WaytraceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = LocationRecorder.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Record", systemImage: "record.circle") }
                RoadsView()
                    .tabItem { Label("Roads", systemImage: "road.lanes") }
            }
            .environmentObject(recorder)
            .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recorder.appBecameActive()
                Notifier.shared.askOnce()
                Notifier.shared.scheduleSigningReminder()
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
        Notifier.shared.attach()
        Notifier.shared.scheduleSigningReminder()
        _ = RoadJobs.shared            // installs the background pacing hook
        return true
    }
}
