//
//  RealGPSSeeder.swift
//  Wander
//
//  "First fix is real" — a self-inflicted-ban guardrail (companion to SpeedGovernor).
//
//  When a spoof session begins, the very FIRST injected fix normally IS the teleport target, so the
//  jump from the device's real GPS to the target is one instantaneous, physically-impossible delta.
//  Some anti-cheat systems key on that opening jump. This seeder instead injects the device's REAL
//  current location FIRST, then lets the caller proceed to the target — so the session opens from a
//  believable "you are here" fix and the impossible jump isn't the very first thing the app sees.
//
//  ⚠️ OFF by default — enable only after verifying the real→fake handoff timing on a device
//  (soft-ban risk if the handoff is too fast). The window between the real fix and the following
//  teleport must be long enough to read as a normal jump-cut, not a same-instant contradiction; that
//  timing has to be measured on-device before this is turned on. Gated behind the hidden
//  UserDefaults flag `firstFixRealEnabled` (default false); there is intentionally NO UI toggle yet.
//

import Foundation
import CoreLocation

@MainActor
final class RealGPSSeeder: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Hidden UserDefaults flag. Defaults to FALSE — see the file header before enabling.
    static let enabledKey = "firstFixRealEnabled"

    /// Whether the guardrail is turned on. Cheap to read at each session start.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Fetch ONE real device fix, fail-safe. Returns the real coordinate, or nil if the guardrail is
    /// off, authorization is denied/restricted, or no fix arrives within `timeout`. Never throws and
    /// never blocks the session — a nil result means "skip the seed, proceed to the target as usual".
    func currentRealFix(timeout: TimeInterval = 3) async -> CLLocationCoordinate2D? {
        guard Self.isEnabled else { return nil }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        default:
            // Not authorized (or not yet determined) → don't prompt mid-teleport; just skip.
            return nil
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            self.continuation = cont
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.1) * 1_000_000_000))
                await self?.finish(with: nil)
            }
            self.manager.requestLocation()
        }
    }

    /// Seed the tunnel with the real fix (if available + enabled) BEFORE the caller teleports to the
    /// target. Fire-and-forget from the session-start path; fail-safe throughout. Does nothing (and
    /// injects nothing) when the flag is off or no real fix is obtainable. Sends on the shared serial
    /// location queue so it's ordered ahead of the target inject the caller issues next.
    ///
    /// ⚠️ OFF by default — see the file header. Enable via the hidden `firstFixRealEnabled` flag only
    /// after verifying the real→fake handoff timing on a device.
    func seedRealFirstFix(pairingFilePath: String) async {
        guard Self.isEnabled else { return }
        guard let real = await currentRealFix() else { return }
        LocationSimulationCommandQueue.shared.async {
            // Ordered on the serial queue ahead of the caller's target inject: the device sees the
            // real "you are here" fix first, then the jump to the target as the next command.
            _ = simulate_location(DeviceConnectionContext.targetIPAddress,
                                  real.latitude, real.longitude, pairingFilePath)
        }
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(returning: coordinate)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        Task { @MainActor in self.finish(with: coord) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(with: nil) }
    }
}
