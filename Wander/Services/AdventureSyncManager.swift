//
//  AdventureSyncManager.swift
//  Wander
//
//  Adventure Sync (mirroring the app's SIMULATED walking distance into Apple Health
//  as step + walking/running-distance samples, so fitness-reading games like Pokémon
//  GO's Adventure Sync can credit the spoofed walk) is DISABLED on iOS and reduced
//  to a no-op stub here.
//
//  WHY — DO NOT re-add HealthKit to the iOS build without a PAID, pre-signed
//  distribution:
//   1. HealthKit cannot function on Wander's free-Apple-ID SIDELOAD model — the
//      `com.apple.developer.healthkit` entitlement can't be granted on a free team,
//      so writes always fail. The feature was already dormant.
//   2. WORSE, and the reason this file was gutted: merely LINKING HealthKit.framework
//      CRASHES a free-signed build ON LAUNCH. Frameworks are loaded by dyld at app
//      start (not lazily), and iOS terminates an app that links a restricted
//      framework (HealthKit) without its entitlement. Build 29 shipped the
//      HealthKit-backed implementation and crashed on open for exactly this reason.
//
//  This file is the ONLY place that imported HealthKit, so removing `import HealthKit`
//  drops the auto-linked framework entirely and fixes the launch crash. Android keeps
//  Adventure Sync via Health Connect (which needs no such entitlement).
//
//  To restore the real iOS HealthKit implementation for a future PAID pre-signed
//  build, recover this file from git history at the build-29 commit.
//

import Foundation
import CoreLocation

/// UserDefaults key shared between the manager and its Settings toggle.
enum AdventureSyncKeys {
    /// Master opt-in. Default OFF.
    static let enabled = "adventureSyncEnabled"
}

/// No-op stub. Adventure Sync is unavailable on iOS (see file header for why HealthKit
/// is not linked). The full public API is preserved so the movement hooks
/// (`WalkModeView` / `RouteModeView`) and the Settings toggle compile unchanged —
/// every method does nothing and `status` is always `.unavailable`.
@MainActor
final class AdventureSyncManager: ObservableObject {
    static let shared = AdventureSyncManager()
    private init() {}

    /// Always false — the feature can't be enabled on iOS.
    @Published private(set) var isEnabled: Bool = false

    /// Always `.unavailable` on iOS. Settings renders an honest "not available" note.
    @Published private(set) var status: Status = .unavailable

    /// Informational only; never advances on iOS.
    @Published private(set) var sessionMetersWritten: Double = 0

    enum Status: Equatable {
        case idle
        case authorized
        case denied
        /// HealthKit isn't linked on iOS — always this on-device.
        case unavailable

        /// Never writable on iOS.
        var isWritable: Bool { false }
    }

    // MARK: - Public API (preserved for call sites; all no-ops on iOS)

    /// The toggle can't turn the feature on — HealthKit is unavailable on this build.
    func setEnabled(_ enabled: Bool) {
        status = .unavailable
    }

    /// No-op. Kept so the Settings toggle / onAppear paths compile unchanged.
    func requestAuthorization() { status = .unavailable }

    /// No-op.
    func refreshAuthorizationStatus() { status = .unavailable }

    /// No-op. Called by the continuous movers at walk start.
    func beginWalk() {}

    /// No-op. Called by the continuous movers at walk stop.
    func endWalk() {}

    /// No-op. Fed a simulated coordinate by the joystick / route movers; ignored.
    func recordSimulatedMovement(to coordinate: CLLocationCoordinate2D) {}

    /// No-op.
    func refresh() {}
}
