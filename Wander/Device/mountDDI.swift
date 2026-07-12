//
//  mountDDI.swift
//  Wander
//
//  Created by Stossy11 on 29/03/2025.
//

import Foundation

typealias RpPairingFileHandle = OpaquePointer
typealias AdapterHandle = OpaquePointer
typealias RsdHandshakeHandle = OpaquePointer
typealias ImageMounterHandle = OpaquePointer
typealias LockdowndClientHandle = OpaquePointer

func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
    MountingProgress.shared.progressCallback(progress: progress, total: total, context: context)
}

enum MountCheckResult {
    case mounted
    case notMounted
    case unreachable
}

/// Positive-proof readiness signal. The image-mounter device count is unreliable for
/// personalized DDIs on iOS 17+ (image_mounter_copy_devices returns 0 even when the
/// image is mounted), so we also remember when a real location simulation has
/// succeeded — which is definitive proof the DDI is mounted and Developer Mode is on.
enum DeviceReadiness {
    private static let ddiProvenKey = "wander.ddiProvenMounted"

    /// A location simulation just succeeded → the DDI is mounted and Developer Mode is on.
    static func markSimulationSucceeded() {
        UserDefaults.standard.set(true, forKey: ddiProvenKey)
    }

    /// True once a simulation has ever succeeded on this install.
    static var ddiProven: Bool {
        UserDefaults.standard.bool(forKey: ddiProvenKey)
    }
}

func isMounted() -> Bool {
    return checkMountStatus() == .mounted
}

func checkMountStatus() -> MountCheckResult {
    do {
        // Live round-trip FIRST so a dead/absent tunnel fails fast and honestly reports
        // "unreachable". (rsd_service_available reads a cached snapshot from when the tunnel
        // handshake was created, so on its own it would keep reporting "reachable" even after
        // the VPN drops — that's why the checklist used to go stale.)
        _ = try JITEnableContext.shared.getDeveloperModeStatus()

        // iOS 17+: image_mounter_copy_devices under-reports (returns 0 even when the
        // personalized DDI is mounted), so use the advertised developer services as the
        // reliable "mounted" signal.
        if try JITEnableContext.shared.isDeveloperServiceAvailable() {
            return .mounted
        }
        let result = try JITEnableContext.shared.getMountedDeviceCount()
        return result > 0 ? .mounted : .notMounted
    } catch {
        return .unreachable
    }
}

enum DeveloperModeState {
    case on, off, unknown
}

/// Asks the device directly whether Developer Mode is on — no DDI mount or simulation needed.
func checkDeveloperMode() -> DeveloperModeState {
    do {
        return try JITEnableContext.shared.getDeveloperModeStatus() ? .on : .off
    } catch {
        return .unknown
    }
}

func mountPersonalDDI(imagePath: String, trustcachePath: String, manifestPath: String) -> String? {
    do {
        try JITEnableContext.shared.mountPersonalDDI(withImagePath: imagePath, trustcachePath: trustcachePath, manifestPath: manifestPath)
    } catch {
        LogManager.shared.addErrorLog("Failed to mount DDI: \(error.localizedDescription)")
        return error.localizedDescription
    }
    return nil
}
