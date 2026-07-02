//
//  License.swift
//  Wander
//
//  Offline license check. A license key is an Ed25519-signed token
//  (`base64url(payload).base64url(signature)`) minted with the developer's private
//  key. The app verifies it against the embedded public key — no server needed, and
//  keys can't be forged without the private key. Used to unlock when RemoteGate locks.
//

import Foundation
import CryptoKit

@MainActor
final class License: ObservableObject {
    static let shared = License()

    // Ed25519 public key (raw 32 bytes, base64). The matching private key is kept
    // OFFLINE by the developer and is used to sign license keys (tools/wander-license.py).
    private static let publicKeyB64 = "XTsRHlEve/xOhJIl9Tjyaly1Gs7UQ/p93aP0TrBL0gg="
    private static let storeKey = "wander.license.token"

    @Published private(set) var isLicensed: Bool = false

    private init() {
        if let token = UserDefaults.standard.string(forKey: Self.storeKey) {
            isLicensed = Self.verify(token)
        }
    }

    /// Store + activate a license key if its signature is valid.
    @discardableResult
    func redeem(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.verify(token) else { return false }
        UserDefaults.standard.set(token, forKey: Self.storeKey)
        isLicensed = true
        return true
    }

    static func verify(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count == 2,
              let payload = b64urlDecode(String(parts[0])),
              let signature = b64urlDecode(String(parts[1])),
              let pkData = Data(base64Encoded: publicKeyB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pkData)
        else { return false }
        return publicKey.isValidSignature(signature, for: payload)
    }

    private static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
