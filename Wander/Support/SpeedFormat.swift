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
    ///
    /// This is a FLAT per-tick offset: each call is an independent random jump, which on a
    /// STATIONARY hold reads as a series of tiny teleports. For a parked/idle location prefer
    /// `BreathingJitter` (below), which wanders and drifts back like a real receiver.
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

/// Stateful "breathing" jitter for a STATIONARY / parked held location. A real GPS receiver
/// sitting still doesn't report a mathematically-perfect frozen point, nor does it teleport a
/// fresh random metre every fix — its reported position slowly wanders a metre or two and drifts
/// back toward the true spot. Detectors (Life360, dating apps) can key on both extremes: a dead
/// point looks parked-but-too-perfect, and flat per-tick scatter looks like micro-teleports.
///
/// This models an Ornstein–Uhlenbeck / mean-reverting random walk. We keep a current offset in
/// metres (north/east) between calls, nudge it by a small random amount each tick, and pull it
/// back toward 0 — so the reported point wanders within a soft ~1–3 m envelope and always returns,
/// never a fresh independent jump. One instance models one hold session; the anchor coordinate
/// passed to `next(around:)` stays clean (the wander lives only in this object's state), so the
/// held point never drifts away over many minutes.
///
/// NOTE: the iOS injection FFI carries lat/lng ONLY — there is no horizontalAccuracy/altitude
/// field to write — so the "accuracy-radius variation" idea can't be expressed here. This does the
/// POSITIONAL breathing only.
struct BreathingJitter {
    /// Current offset from the anchor, in metres.
    private var north: Double = 0
    private var east: Double = 0

    /// Mean-reversion factor per tick: how hard the offset is pulled back toward 0. Matches the
    /// 0.9 pull-back used by HumanizedMotion's heading-bias walk.
    private let reversion = 0.85
    /// Std-dev of the random nudge applied each tick, in metres. Small so a single step is sub-metre.
    private let stepMeters = 0.6
    /// Soft clamp on the offset magnitude, in metres, so the wander stays in a believable envelope.
    private let maxMeters = 3.0

    /// Advance the walk one tick and return the anchor shifted by the current offset.
    /// The passed-in coordinate is treated as the CLEAN anchor and is never mutated.
    mutating func next(around c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        // Nudge (triangular ~ sum of two uniforms clusters near 0 like real receiver error),
        // then pull back toward the anchor, then soft-clamp the magnitude.
        let nudgeN = (Double.random(in: -1...1) + Double.random(in: -1...1)) / 2 * stepMeters
        let nudgeE = (Double.random(in: -1...1) + Double.random(in: -1...1)) / 2 * stepMeters
        north = north * reversion + nudgeN
        east = east * reversion + nudgeE
        let mag = (north * north + east * east).squareRoot()
        if mag > maxMeters {
            let scale = maxMeters / mag
            north *= scale
            east *= scale
        }

        let metersPerDegLat = 111_320.0
        let lonScale = max(cos(c.latitude * .pi / 180), 0.000001)
        return CLLocationCoordinate2D(
            latitude: c.latitude + north / metersPerDegLat,
            longitude: c.longitude + east / (metersPerDegLat * lonScale)
        )
    }
}

/// UserDefaults keys for the frozen-hold and approximate-location privacy toggles.
enum LocationPrivacyKeys {
    /// "Hold perfectly still": when ON, disable the breathing/idle jitter so a held
    /// location is rock-steady (a deliberately parked/stationary look).
    static let frozenHold = "frozenHold"
    /// "Approximate location": when ON, offset the injected coordinate by a STABLE
    /// per-session amount so the reported position is ~3–5 km from the real target.
    static let approximateLocation = "approximateLocation"
}

/// "Approximate location": applies a STABLE per-session offset so the reported position
/// shares a neighborhood (~3–5 km) with the real target instead of the exact spot. The
/// offset is picked once per app session and reused for every fix, so it does NOT jitter
/// between fixes — it reads as a coarse/privacy location, not a moving one.
enum CoarseLocation {
    /// Whether the toggle is on. Cheap to read on every fix.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: LocationPrivacyKeys.approximateLocation)
    }

    /// A stable per-session bearing (radians) and distance (meters, ~3–5 km). Computed
    /// once and cached for the lifetime of the process so every fix gets the SAME shift.
    private static let sessionOffset: (bearing: Double, meters: Double) = (
        Double.random(in: 0..<(2 * .pi)),
        Double.random(in: 3_000...5_000)
    )

    /// Shift `c` by the stable per-session offset. No-op when the toggle is off.
    static func apply(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isEnabled else { return c }
        let (bearing, meters) = sessionOffset
        let metersPerDegLat = 111_320.0
        let lonScale = max(cos(c.latitude * .pi / 180), 0.000001)
        let dNorth = cos(bearing) * meters
        let dEast = sin(bearing) * meters
        return CLLocationCoordinate2D(
            latitude: c.latitude + dNorth / metersPerDegLat,
            longitude: c.longitude + dEast / (metersPerDegLat * lonScale)
        )
    }
}
