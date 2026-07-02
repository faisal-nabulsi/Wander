//
//  SpeedFormat.swift
//  Wander
//
//  Speed unit conversion (km/h <-> mph) driven by the "useMph" preference,
//  and horizontal coordinate jitter to avoid a perfectly-frozen location.
//

import Foundation
import CoreLocation

enum SpeedFormat {
    private static let mphFactor = 2.2369362920544   // m/s -> mph
    private static let kmhFactor = 3.6                // m/s -> km/h

    static func unitLabel(useMph: Bool) -> String { useMph ? "mph" : "km/h" }

    /// meters/second -> display value in the chosen unit
    static func fromMps(_ mps: Double, useMph: Bool) -> Double {
        mps * (useMph ? mphFactor : kmhFactor)
    }

    /// display value in the chosen unit -> meters/second
    static func toMps(_ value: Double, useMph: Bool) -> Double {
        value / (useMph ? mphFactor : kmhFactor)
    }

    /// Slider range in the chosen unit (walking-ish up to highway).
    static func sliderRange(useMph: Bool) -> ClosedRange<Double> {
        useMph ? 1...100 : 1...160
    }
}

enum LocationJitter {
    /// Adds a small random horizontal drift so the point isn't perfectly static.
    /// If `maxMeters` is nil, uses the user's "jitterRadius" preference (default 1.5 m).
    static func apply(_ c: CLLocationCoordinate2D, maxMeters: Double? = nil) -> CLLocationCoordinate2D {
        let stored = UserDefaults.standard.double(forKey: "jitterRadius")
        let maxM = maxMeters ?? (stored > 0 ? stored : 1.5)
        let metersPerDegLat = 111_320.0
        let dLatMeters = Double.random(in: -maxM...maxM)
        let dLonMeters = Double.random(in: -maxM...maxM)
        let lonScale = max(cos(c.latitude * .pi / 180), 0.000001)
        return CLLocationCoordinate2D(
            latitude: c.latitude + dLatMeters / metersPerDegLat,
            longitude: c.longitude + dLonMeters / (metersPerDegLat * lonScale)
        )
    }
}
