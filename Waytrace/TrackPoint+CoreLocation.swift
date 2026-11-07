import CoreLocation

extension TrackPoint {
    /// Copies everything Core Location knows about a fix. iOS marks invalid values
    /// with a negative number; those become nil.
    init(location l: CLLocation, segment: Int) {
        self.init(
            segment: segment,
            time: l.timestamp,
            latitude: l.coordinate.latitude,
            longitude: l.coordinate.longitude,
            horizontalAccuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil,
            altitude: l.verticalAccuracy >= 0 ? l.altitude : nil,
            verticalAccuracy: l.verticalAccuracy >= 0 ? l.verticalAccuracy : nil,
            speed: l.speed >= 0 ? l.speed : nil,
            speedAccuracy: l.speedAccuracy >= 0 ? l.speedAccuracy : nil,
            course: l.course >= 0 ? l.course : nil,
            courseAccuracy: l.courseAccuracy >= 0 ? l.courseAccuracy : nil,
            activity: nil
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
