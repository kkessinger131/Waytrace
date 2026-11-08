import Foundation
import CoreLocation

/// Keeps a Road to KML run going when you switch to another app.
///
/// iOS gives an app about 30 seconds in the background, which isn't enough for a run. While a
/// run is going, this asks Core Location for cell-tower-accuracy updates (the GPS stays off,
/// so it costs very little); an app receiving location updates is allowed to keep running,
/// just as it does while recording. It stops the moment the run ends. iOS shows the location
/// arrow while it's on.
///
/// (iOS 26's "continued processing" tasks would be the textbook tool, but they need the app's
/// exact bundle ID registered in advance, and Sideloadly changes the ID when it signs.)
@MainActor
final class RunKeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = RunKeepAlive()

    private let manager = CLLocationManager()
    private(set) var isActive = false

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// Starts the keep-alive if location access allows it. Returns false if it couldn't
    /// (then the run only has iOS's ~30 s grace in the background).
    @discardableResult
    func start() -> Bool {
        if isActive { return true }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: break
        default: return false
        }
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        isActive = true
        return true
    }

    func stop() {
        guard isActive else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isActive = false
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
