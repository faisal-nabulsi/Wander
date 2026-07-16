//
//  AdventureSyncManager.swift
//  Wander
//
//  "Adventure Sync" — mirrors the app's SIMULATED walking distance into Apple
//  Health as step + walking/running-distance samples, so fitness-reading games
//  (Pokémon GO's Adventure Sync, Pikmin Bloom, etc.) can credit the spoofed walk.
//
//  Those games credit DISTANCE WALKED by reading the phone's fitness store, not
//  GPS. A user who spoofs GPS movement but whose pedometer reads 0 gets no
//  credit. This writer closes that gap by writing HealthKit samples that MIRROR
//  the movement the app is already simulating.
//
//  DESIGN CONTRACT (see also the toggle in Settings):
//   • REALISTIC PACING ONLY. Distance/steps are derived from the ACTUAL simulated
//     movement as it advances (accumulated great-circle distance since the last
//     write), at a human cadence (~1390 steps/km, ~0.72 m stride). Samples are
//     written incrementally over time as movement progresses. We NEVER dump a
//     huge instant distance — a single implausibly large jump (a teleport, not a
//     walk) is discarded, never written.
//   • TELEPORT-ONLY = NOTHING. Only the continuous movers (Joystick / Route drive)
//     feed this. A one-shot teleport produces one coordinate with no "walk"
//     between samples, so nothing is written.
//   • OPT-IN + PERMISSION-GATED. Default OFF. Enabling requests HealthKit write
//     authorization. If HealthKit is unavailable, the entitlement isn't present
//     in this build's signature, or the user denies, the feature is a NO-OP with
//     an honest status message. It NEVER crashes and NEVER affects spoofing.
//   • BEST-EFFORT UX. Whether a given game actually reads these samples in 2026 is
//     not guaranteed, so the UI is labelled best-effort rather than a promise.
//
//  SHIP-SAFETY NOTE (entitlement): HealthKit needs the com.apple.developer.healthkit
//  entitlement. That entitlement is NOT deliberately added to the always-on
//  Wander.entitlements, because a signing-profile that can't grant it would break
//  signing for the WHOLE app — a far worse outcome than this one feature being
//  unavailable. The writer therefore runs entirely behind a runtime capability
//  check; on a build whose signature lacks the entitlement, authorization simply
//  fails (com.apple.healthkit error 4) and the feature reports itself .unavailable.
//
//  TO ENABLE ON A PAID-TEAM INSTALL (optional): add
//      <key>com.apple.developer.healthkit</key><true/>
//      <key>com.apple.developer.healthkit.access</key><array/>
//  to Wander/Wander.entitlements AND register an EXPLICIT App ID (not a wildcard)
//  with the HealthKit capability for the signing team. Only do this if the signing
//  team can grant HealthKit — otherwise it BREAKS SIGNING FOR THE WHOLE APP, which
//  is why it is intentionally left OUT of the shipped entitlements. The runtime
//  guard below makes the feature a clean no-op when the entitlement is absent.
//

import Foundation
import CoreLocation
#if canImport(HealthKit)
import HealthKit
#endif

/// UserDefaults keys shared between the manager and its Settings toggle.
enum AdventureSyncKeys {
    /// Master opt-in. Default OFF. Mirrors the existing power-feature toggles.
    static let enabled = "adventureSyncEnabled"
}

@MainActor
final class AdventureSyncManager: ObservableObject {
    static let shared = AdventureSyncManager()

    // MARK: Tuning (realistic pacing)

    /// Average stride length in metres. ~0.72 m ⇒ ~1389 steps/km, a normal human
    /// walking cadence. Used to derive a plausible step count from distance walked.
    private static let strideMeters = 0.72

    /// Minimum accumulated distance (metres) before we flush a HealthKit sample.
    /// Batching a handful of movement ticks into one sample keeps write volume sane
    /// while still writing incrementally as the walk progresses.
    private static let flushThresholdMeters = 25.0

    /// A per-tick delta larger than this (metres) is treated as a TELEPORT, not a
    /// step, and is DISCARDED — never written. This is the guard against dumping a
    /// huge instant distance (the exact thing that flags accounts). At the app's
    /// fastest continuous "drive" pace (~50 km/h ≈ 14 m per 0.5 s tick) a real tick
    /// is tens of metres; anything past ~2 km in one tick is a jump, not a walk.
    private static let teleportJumpMeters = 2_000.0

    /// Running-pace cap. Any tick whose implied speed EXCEEDS this is not credited
    /// (its distance is skipped entirely, never laundered into a slower-looking
    /// sample). ~3.0 m/s ≈ 10.8 km/h — Pokémon GO's Adventure Sync ignores distance
    /// accrued faster than ~10.5 km/h, so faster movement is both useless in-game
    /// and less believable. This is the SINGLE shared cap; iOS and Android must use
    /// the same value so both platforms credit only walk/jog pace and drop drive/
    /// plane/fast movement identically.
    private static let runningPaceCapMetersPerSecond = 3.0

    // MARK: Published state

    /// Whether the feature is switched on by the user (persisted). Toggling this is
    /// the ONLY way samples ever get written.
    @Published private(set) var isEnabled: Bool = UserDefaults.standard.bool(forKey: AdventureSyncKeys.enabled)

    /// Authorization / capability status, surfaced to the UI so the toggle can show
    /// an honest state (available, denied, unavailable on this build, …).
    @Published private(set) var status: Status = .idle

    /// Total distance (metres) mirrored into Health during the current app session.
    /// Purely informational for the UI; not persisted.
    @Published private(set) var sessionMetersWritten: Double = 0

    enum Status: Equatable {
        /// Feature off, or on but not yet asked for permission this launch.
        case idle
        /// Authorized to write — samples will be mirrored while moving.
        case authorized
        /// User (or a prior decision) denied write access. Honest no-op.
        case denied
        /// HealthKit isn't available on this device (e.g. iPad without Health) OR
        /// this build's signature lacks the HealthKit entitlement, so the OS won't
        /// grant write access. Honest no-op with a "needs paid-signing install" hint.
        case unavailable

        var isWritable: Bool { self == .authorized }
    }

    // MARK: Movement accumulation state

    /// Last simulated coordinate we saw, to measure the per-tick delta from.
    private var lastCoordinate: CLLocationCoordinate2D?
    /// Wall-clock time of `lastCoordinate`, to time the written sample window.
    private var lastTimestamp: Date?
    /// Metres accumulated but not yet flushed to a HealthKit sample.
    private var pendingMeters: Double = 0
    /// Start time of the pending (un-flushed) window — the sample's start date.
    private var pendingWindowStart: Date?

    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    #endif

    private init() {
        // If the user had it enabled from a previous launch, re-check authorization
        // silently so the status reflects reality without prompting again.
        if isEnabled {
            refreshAuthorizationStatus()
        }
    }

    // MARK: - Enable / disable (opt-in, permission-gated)

    /// Turn the feature on or off. Turning ON requests HealthKit write authorization
    /// (the OS shows its permission sheet the first time). Turning OFF stops all
    /// writing and clears accumulation. Safe to call from the UI toggle.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AdventureSyncKeys.enabled)
        isEnabled = enabled
        if enabled {
            requestAuthorization()
        } else {
            resetAccumulation()
            status = .idle
        }
    }

    /// Ask for HealthKit write access to step count + walking/running distance.
    /// No-op (with an honest status) when HealthKit is unavailable or the build's
    /// signature can't carry the entitlement.
    func requestAuthorization() {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            status = .unavailable
            return
        }
        guard
            let stepType = HKObjectType.quantityType(forIdentifier: .stepCount),
            let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        else {
            status = .unavailable
            return
        }
        let toShare: Set<HKSampleType> = [stepType, distanceType]
        healthStore.requestAuthorization(toShare: toShare, read: []) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    // A signature WITHOUT the HealthKit entitlement makes the OS
                    // refuse authorization with an error rather than a sheet. Treat
                    // that as "unavailable on this build" — honest, never a crash.
                    LogManager.shared.addInfoLog("AdventureSync: HealthKit authorization error: \(error.localizedDescription)")
                    self.status = .unavailable
                    return
                }
                // `granted == true` only means the sheet was handled, not that WRITE
                // was allowed (Apple hides read status but exposes write status).
                self.refreshAuthorizationStatus()
            }
        }
        #else
        status = .unavailable
        #endif
    }

    /// Recompute `status` from the current HealthKit write authorization without
    /// prompting. Called on launch and after the permission sheet resolves.
    func refreshAuthorizationStatus() {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            status = .unavailable
            return
        }
        switch healthStore.authorizationStatus(for: stepType) {
        case .sharingAuthorized:
            status = .authorized
        case .sharingDenied:
            status = .denied
        case .notDetermined:
            // Enabled but never prompted (or prompt dismissed without a decision).
            status = .idle
        @unknown default:
            status = .denied
        }
        #else
        status = .unavailable
        #endif
    }

    // MARK: - Movement hook (called by the continuous movers)

    /// Feed the manager a freshly-simulated coordinate. Called on every position
    /// update by the CONTINUOUS movers (Joystick step, Route drive sample). The
    /// manager measures the great-circle delta from the previous coordinate,
    /// accumulates it, and flushes a HealthKit sample once enough real distance has
    /// built up. Teleport-sized jumps are discarded. No-op unless enabled + writable.
    func recordSimulatedMovement(to coordinate: CLLocationCoordinate2D) {
        guard isEnabled, status.isWritable else {
            // Still track position so that re-enabling mid-walk doesn't retroactively
            // count the gap as one giant step.
            lastCoordinate = coordinate
            lastTimestamp = Date()
            return
        }

        let now = Date()
        defer {
            lastCoordinate = coordinate
            lastTimestamp = now
        }

        guard let previous = lastCoordinate else {
            // First fix of the walk — nothing to measure yet. Open a window.
            pendingWindowStart = now
            return
        }

        let meters = greatCircleMeters(from: previous, to: coordinate)

        // Discard teleport-sized jumps: a real walking/driving tick is tens of
        // metres; a multi-kilometre delta is a teleport and must NOT be written.
        guard meters > 0, meters < Self.teleportJumpMeters else {
            // Re-anchor the window at the new position; don't count the jump.
            pendingWindowStart = now
            return
        }

        // ENFORCE THE RUNNING-PACE CAP PER TICK. Derive this tick's dt from the
        // wall-clock time of the previous coordinate and compute the implied speed
        // (delta / dt). If it EXCEEDS the cap, DO NOT credit this tick — skip it
        // entirely. We never launder fast movement into a slower-looking sample and
        // never write a segment whose implied pace exceeds the cap. Drive/plane/fast
        // ticks therefore write nothing; walk/jog ticks accumulate normally.
        let dt = now.timeIntervalSince(lastTimestamp ?? now)
        if dt > 0 {
            let impliedSpeed = meters / dt
            guard impliedSpeed <= Self.runningPaceCapMetersPerSecond else {
                // Over the cap: skip this tick's distance. First flush any legit
                // distance already accumulated, over its TRUE window ending at the
                // previous tick — otherwise that pending walk distance would be
                // restamped over the compressed post-skip window and imply a pace
                // well above the cap. Then re-anchor so the next sample starts after
                // the skipped fast jump.
                if pendingMeters > 0 { flush(windowEnd: lastTimestamp ?? now) }
                pendingWindowStart = now
                return
            }
        }

        if pendingWindowStart == nil { pendingWindowStart = lastTimestamp ?? now }
        pendingMeters += meters

        if pendingMeters >= Self.flushThresholdMeters {
            flush(windowEnd: now)
        }
    }

    /// Called when a continuous walk starts, so the first tick isn't measured
    /// against a stale coordinate from a previous, unrelated run.
    func beginWalk() {
        resetAccumulation()
    }

    /// Called when movement stops. Flushes whatever distance has accumulated so the
    /// tail of the walk is credited, then clears state.
    func endWalk() {
        if isEnabled, status.isWritable, pendingMeters > 0 {
            flush(windowEnd: Date())
        }
        resetAccumulation()
    }

    // MARK: - Flushing to HealthKit

    /// Write the pending accumulated distance (and a stride-derived step count) as
    /// HealthKit samples spanning the TRUE wall-clock window over which the distance
    /// was actually accrued, then reset the pending counter. The pace cap is already
    /// enforced per tick in `recordSimulatedMovement` (over-cap ticks are skipped, not
    /// credited), so the window is stamped as-is — never stretched to disguise pace.
    private func flush(windowEnd: Date) {
        let meters = pendingMeters
        pendingMeters = 0
        guard meters > 0 else { pendingWindowStart = windowEnd; return }

        // Stamp the true wall-clock window this distance was accrued over. Every
        // credited tick is already at/below the running-pace cap, so the implied
        // pace of this sample is inherently plausible — no window stretching.
        let rawStart = pendingWindowStart ?? windowEnd.addingTimeInterval(-1)
        let start = rawStart
        var end = windowEnd
        if end <= start { end = start.addingTimeInterval(1) }

        // Stride-derived step count — a plausible cadence for the distance walked.
        let steps = max(1, Int((meters / Self.strideMeters).rounded()))

        pendingWindowStart = windowEnd
        sessionMetersWritten += meters

        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let stepType = HKObjectType.quantityType(forIdentifier: .stepCount),
              let distanceType = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        else { return }

        let stepQuantity = HKQuantity(unit: .count(), doubleValue: Double(steps))
        let distanceQuantity = HKQuantity(unit: .meter(), doubleValue: meters)

        // Tag samples with our bundle + a marker so they're identifiable/deletable
        // and clearly attributed to Wander rather than the device pedometer.
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: false,
            "WanderAdventureSync": true
        ]

        let stepSample = HKQuantitySample(
            type: stepType, quantity: stepQuantity,
            start: start, end: end, metadata: metadata
        )
        let distanceSample = HKQuantitySample(
            type: distanceType, quantity: distanceQuantity,
            start: start, end: end, metadata: metadata
        )

        healthStore.save([stepSample, distanceSample]) { success, error in
            if let error {
                LogManager.shared.addInfoLog("AdventureSync: HealthKit save failed: \(error.localizedDescription)")
            } else if !success {
                LogManager.shared.addInfoLog("AdventureSync: HealthKit save returned false")
            }
        }
        #endif
    }

    // MARK: - Helpers

    private func resetAccumulation() {
        lastCoordinate = nil
        lastTimestamp = nil
        pendingMeters = 0
        pendingWindowStart = nil
    }

    /// Great-circle distance in metres between two coordinates (haversine).
    private func greatCircleMeters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadius * c
    }
}
