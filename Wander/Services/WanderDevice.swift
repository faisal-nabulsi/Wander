//
//  WanderDevice.swift
//  Wander
//
//  A stable per-device identifier that SURVIVES deleting + reinstalling Wander (it lives in
//  the Keychain, which iOS preserves across reinstall — unlike identifierForVendor, which
//  resets when the app is removed). Used to bind a license to one device (server-side
//  bind-on-first-redeem) and to keep the free trial from resetting on reinstall.
//

import Foundation

enum WanderDevice {
    private static let key = "wander.device.id"

    /// Get-or-create a persistent UUID for this device+install identity.
    static var id: String {
        if let existing = WanderKeychain.string(key), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        WanderKeychain.set(key, fresh)
        return fresh
    }
}
