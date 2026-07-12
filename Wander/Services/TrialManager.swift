//
//  TrialManager.swift
//  Wander
//
//  One-time free trial: 5 teleports, 30 minutes of joystick, 3 routes. Counters live in the
//  Keychain (via WanderKeychain) so deleting + reinstalling Wander does NOT reset the trial —
//  iOS preserves Keychain items across app deletion. Each mode charges its own bucket at the
//  point it starts simulating; when a bucket is empty and there's no license, that mode is
//  blocked behind the paywall. A valid License lifts all limits.
//

import Foundation

enum SimMode {
    case teleport, joystick, route
}

@MainActor
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    static let maxTeleports = 5
    static let maxJoystickSeconds = 30 * 60   // 30 minutes
    static let maxRoutes = 3

    @Published private(set) var teleportsUsed: Int
    @Published private(set) var joystickSecondsUsed: Int
    @Published private(set) var routesUsed: Int

    private enum Key {
        static let teleports = "wander.trial.teleports"
        static let joystick = "wander.trial.joystickSeconds"
        static let routes = "wander.trial.routes"
    }

    private init() {
        teleportsUsed = WanderKeychain.int(Key.teleports)
        joystickSecondsUsed = WanderKeychain.int(Key.joystick)
        routesUsed = WanderKeychain.int(Key.routes)
    }

    var teleportsRemaining: Int { max(Self.maxTeleports - teleportsUsed, 0) }
    var joystickSecondsRemaining: Int { max(Self.maxJoystickSeconds - joystickSecondsUsed, 0) }
    var routesRemaining: Int { max(Self.maxRoutes - routesUsed, 0) }

    func remaining(_ mode: SimMode) -> Int {
        switch mode {
        case .teleport: return teleportsRemaining
        case .joystick: return joystickSecondsRemaining
        case .route: return routesRemaining
        }
    }

    /// Whether this mode may still run on the free trial (ignores license — callers OR this
    /// with License.isLicensed).
    func canUse(_ mode: SimMode) -> Bool { remaining(mode) > 0 }

    var allExhausted: Bool {
        teleportsRemaining == 0 && joystickSecondsRemaining == 0 && routesRemaining == 0
    }

    func chargeTeleport() {
        teleportsUsed += 1
        WanderKeychain.setInt(Key.teleports, teleportsUsed)
    }

    func chargeRoute() {
        routesUsed += 1
        WanderKeychain.setInt(Key.routes, routesUsed)
    }

    func addJoystickSeconds(_ seconds: Int) {
        guard seconds > 0 else { return }
        joystickSecondsUsed += seconds
        WanderKeychain.setInt(Key.joystick, joystickSecondsUsed)
    }
}
