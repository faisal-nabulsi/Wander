//
//  WanderKeychain.swift
//  Wander
//
//  A tiny Keychain-backed key/value store for values that must survive DELETING and
//  reinstalling the app. iOS preserves Keychain items across app deletion, so this is how
//  the one-time free trial (and the device ID) resist a delete-and-reinstall reset — unlike
//  UserDefaults, which is wiped with the app.
//

import Foundation
import Security

enum WanderKeychain {
    private static let service = "com.wander.store"

    static func string(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
    }

    static func int(_ key: String) -> Int { Int(string(key) ?? "") ?? 0 }
    static func setInt(_ key: String, _ value: Int) { set(key, String(value)) }
}
