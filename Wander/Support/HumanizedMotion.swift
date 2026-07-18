//
//  HumanizedMotion.swift
//  Wander
//
//  Turns robotically-perfect simulated movement into something that reads like a real person
//  walking. A dead-straight line at a dead-constant speed is THE signature of a spoofed GPS
//  track — real traces wander a few degrees, vary pace stride to stride, pause at curbs, and
//  carry a couple of metres of receiver error. This is the anti-detection core, and it needs
//  no root: it's just math on the coordinates we already inject through the tunnel.
//
//  One `HumanizedMotion` instance models one active movement session (a joystick run, a route
//  drive). Feed it the INTENDED speed + heading each tick; it returns the humanized speed +
//  heading to actually apply. `gpsNoise` is a separate pure helper for scattering the REPORTED
//  fix without disturbing the underlying path.
//

import Foundation
import CoreLocation

/// Global on/off for realistic motion. Defaults ON (unset ⇒ true) so new installs get the
/// believable behaviour without having to discover a toggle.
enum MotionRealism {
    static let key = "realisticMotion"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)
    }
}

/// A stateful, per-run model of human locomotion.
struct HumanizedMotion {
    enum Context {
        /// The user is actively driving a joystick — subtle realism (pace + heading wander),
        /// but never a full stop, so the stick always feels responsive.
        case steered
        /// The app is playing a route or patrol autonomously — full realism, including the
        /// occasional micro-pause at pedestrian speeds.
        case autonomous
    }

    let context: Context

    // Evolving state.
    private var currentSpeed: Double = 0     // m/s, acceleration-limited
    private var headingBias: Double = 0      // radians, mean-reverting random walk off the true course
    private var pauseTicksLeft: Int = 0
    private var ticksSinceStop: Int = 0

    init(context: Context) { self.context = context }

    /// The humanized `(speed, heading)` to apply this tick.
    /// - Parameters:
    ///   - targetSpeed: intended ground speed in m/s (0 ⇒ idle / stick centred)
    ///   - baseHeading: intended heading in radians (0 = north, +east), matching the caller's
    ///     `dLat = d·cos(h)`, `dLon = d·sin(h)` convention
    ///   - dt: tick length in seconds
    ///   - allowPause: pass false to forbid (and abort) micro-pauses — e.g. the final metres of an
    ///     auto-walk, so it can't freeze right at the destination.
    mutating func next(targetSpeed: Double, baseHeading: Double, dt: TimeInterval, allowPause: Bool = true) -> (speed: Double, heading: Double) {
        guard MotionRealism.isEnabled, targetSpeed > 0 else {
            // Pass-through: exactly the old straight-line behaviour when realism is off or idle.
            currentSpeed = max(targetSpeed, 0)
            headingBias = 0
            return (targetSpeed, baseHeading)
        }

        let step = max(dt, 0.01)
        let pedestrian = targetSpeed <= 3.0                       // ≤ ~10.8 km/h: a walk/jog gait
        let allowPauses = allowPause && (context == .autonomous) && pedestrian

        // Final approach (allowPause == false): abort any pause in progress so we keep closing.
        if !allowPause { pauseTicksLeft = 0 }

        // --- micro-pause: ease to a stop, hold, then resume ------------------------------
        if pauseTicksLeft > 0 {
            pauseTicksLeft -= 1
            currentSpeed = approach(currentSpeed, 0, maxDelta: decel(pedestrian) * step)
            return (currentSpeed, baseHeading + headingBias)
        }
        if allowPauses {
            let minRunTicks = Int(10.0 / step)                    // ≥10s of walking between pauses
            let pausesPerMinute = 0.7
            if ticksSinceStop > minRunTicks,
               Double.random(in: 0..<1) < pausesPerMinute * step / 60.0 {
                pauseTicksLeft = max(1, Int(Double.random(in: 2.0...6.0) / step))   // 2–6s pause
                ticksSinceStop = 0
                currentSpeed = approach(currentSpeed, 0, maxDelta: decel(pedestrian) * step)
                return (currentSpeed, baseHeading + headingBias)
            }
        }
        ticksSinceStop += 1

        // --- pace variation, ramped so starts/stops aren't instant ------------------------
        let wobble = pedestrian ? Double.random(in: 0.86...1.12) : Double.random(in: 0.95...1.05)
        let desired = targetSpeed * wobble
        currentSpeed = approach(currentSpeed, desired, maxDelta: accel(pedestrian) * step)

        // --- heading wander: a bounded, mean-reverting drift so the path gently curves -----
        //     (scaled by √dt so the character is the same at any tick rate).
        let stepStd = (pedestrian ? 4.0 : 1.0) * .pi / 180 * sqrt(step / 0.5)
        let maxBias = (pedestrian ? 12.0 : 4.0) * .pi / 180
        headingBias += Double.random(in: -stepStd...stepStd)
        headingBias *= 0.9                                        // pull back toward the true course
        headingBias = min(max(headingBias, -maxBias), maxBias)

        return (currentSpeed, baseHeading + headingBias)
    }

    // MARK: - Reported-fix noise (pure)

    /// Scatter the REPORTED coordinate by a few metres of radial error, like a real receiver.
    /// Pure — no preference read — so callers decide when to apply it and it never disturbs the
    /// clean path we advance internally (which stays the anchor for the next tick + Health/UI).
    static func gpsNoise(_ c: CLLocationCoordinate2D, meters: Double = 2.5) -> CLLocationCoordinate2D {
        let metersPerDegLat = 111_320.0
        // Triangular radius (sum of two uniforms) clusters near 0 like a real error distribution.
        let r = (Double.random(in: -1...1) + Double.random(in: -1...1)) / 2 * meters
        let theta = Double.random(in: 0..<(2 * .pi))
        let dNorth = r * cos(theta)
        let dEast = r * sin(theta)
        let lonScale = max(cos(c.latitude * .pi / 180), 0.000001)
        return CLLocationCoordinate2D(
            latitude: c.latitude + dNorth / metersPerDegLat,
            longitude: c.longitude + dEast / (metersPerDegLat * lonScale)
        )
    }

    // MARK: - Helpers

    private func accel(_ pedestrian: Bool) -> Double { pedestrian ? 0.9 : 2.5 }   // m/s²
    private func decel(_ pedestrian: Bool) -> Double { pedestrian ? 1.4 : 3.5 }   // m/s²

    /// Move `v` toward `target` by at most `maxDelta`.
    private func approach(_ v: Double, _ target: Double, maxDelta: Double) -> Double {
        let d = target - v
        if abs(d) <= maxDelta { return target }
        return v + (d > 0 ? maxDelta : -maxDelta)
    }
}
