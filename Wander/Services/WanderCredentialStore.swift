//
//  WanderCredentialStore.swift
//  Wander
//
//  Keychain-backed storage so an Apple ID sign-in survives app close (and self-refresh).
//  Stores only what's needed to re-authenticate: the Apple ID email + password, plus the
//  last session's dsid + auth token as a fast-path that skips 2FA while Apple still honors
//  the token. Everything is this-device-only and never iCloud-synced.
//

import Foundation
import Security

enum WanderCredentialStore {
    private static let service = "com.wander.appleid"

    // MARK: Credentials (email + password)

    static func saveCredentials(email: String, password: String) {
        set("email", email)
        set("password", password)
    }

    static func loadCredentials() -> (email: String, password: String)? {
        guard let email = get("email"), !email.isEmpty,
              let password = get("password"), !password.isEmpty else { return nil }
        return (email, password)
    }

    // MARK: Session fast-path (dsid + authToken)
    // Reusing a still-valid token is the ONLY thing that skips 2FA on relaunch. Apple
    // controls its lifetime (hours to a day or two) and it can't be refreshed, so treat
    // it purely as a cache: try it, and drop it the moment it stops working.

    static func saveSessionCache(dsid: String, authToken: String) {
        set("dsid", dsid)
        set("authToken", authToken)
    }

    static func loadSessionCache() -> (dsid: String, authToken: String)? {
        guard let dsid = get("dsid"), !dsid.isEmpty,
              let authToken = get("authToken"), !authToken.isEmpty else { return nil }
        return (dsid, authToken)
    }

    /// Drop only the cached session (e.g. token expired) while keeping the credentials.
    static func clearSessionCache() {
        delete("dsid")
        delete("authToken")
    }

    // MARK: Wipe everything (explicit sign-out)

    static func clear() {
        for account in ["email", "password", "dsid", "authToken"] { delete(account) }
    }

    // MARK: - SecItem primitives

    private static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
