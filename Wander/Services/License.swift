//
//  License.swift
//  Wander
//
//  Offline license check. A license key is an Ed25519-signed token
//  (`base64url(payload).base64url(signature)`) minted with the developer's private
//  key. The app verifies it against the embedded public key — no server needed, and
//  keys can't be forged without the private key.
//
//  The signed payload is JSON: {"e": email, "t": issuedAt, "p": plan, "exp": expiry?}.
//  A key with no `exp` is a lifetime license; monthly/yearly keys carry an `exp` unix
//  time and stop unlocking once it passes (checked offline against the device clock).
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
    @Published private(set) var plan: String? = nil
    @Published private(set) var expiry: Date? = nil

    private init() {
        refresh()
    }

    /// Re-evaluate the stored key (catches a subscription that has since expired). The token
    /// lives in the Keychain so a valid license survives deleting + reinstalling the app —
    /// combined with the persistent device id, a licensed user never has to re-enter a code.
    ///
    /// Pro is ADDITIVE: the app is licensed if the offline key is valid OR the signed-in
    /// Wander account is Pro (WanderProAccount). Either path alone unlocks; neither weakens
    /// the other. WanderProAccount calls this whenever its `isPro` flips, and
    /// WanderDeviceActivation calls it whenever this device's registration flips, so the gates
    /// recompute.
    ///
    /// DEVICE CAP: account-Pro additionally requires THIS device to be within the account's
    /// 5-device cap (WanderDeviceActivation). This is FAIL-SAFE — the device gate only withholds
    /// Pro on an explicit "over the limit and not one of the 5" signal; offline / unknown /
    /// registered all allow it, so a paying user is never locked out by a network hiccup. The
    /// offline-key path is unaffected by the cap (a signed key is already device-bound on its own).
    func refresh() {
        let keyResult: Evaluation
        if let token = WanderKeychain.string(Self.storeKey) {
            keyResult = Self.evaluate(token)
        } else {
            keyResult = Evaluation(valid: false, plan: nil, expiry: nil)
        }
        // Account-Pro only counts on this device when the device cap allows it (fail-safe).
        let accountPro = WanderProAccount.shared.isPro
            && WanderDeviceActivation.shared.allowsAccountPro
        // Effective Pro = offline key valid OR account is Pro (within the device cap).
        isLicensed = keyResult.valid || accountPro
        // plan/expiry describe the offline key only (an account carries no local expiry).
        plan = keyResult.plan
        expiry = keyResult.expiry
    }

    /// Store + activate a license key if its signature is valid and it isn't expired.
    @discardableResult
    func redeem(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Self.evaluate(token)
        guard result.valid else { return false }
        WanderKeychain.set(Self.storeKey, token)
        // Recompute through the OR so account-Pro state is preserved/merged.
        refresh()
        return true
    }

    static func verify(_ token: String) -> Bool { evaluate(token).valid }

    struct Evaluation {
        let valid: Bool
        let plan: String?
        let expiry: Date?
    }

    static func evaluate(_ token: String) -> Evaluation {
        let parts = token.split(separator: ".")
        guard parts.count == 2,
              let payload = b64urlDecode(String(parts[0])),
              let signature = b64urlDecode(String(parts[1])),
              let pkData = Data(base64Encoded: publicKeyB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pkData),
              publicKey.isValidSignature(signature, for: payload)
        else { return Evaluation(valid: false, plan: nil, expiry: nil) }

        var plan: String? = nil
        var expiry: Date? = nil
        if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
            plan = obj["p"] as? String
            if let exp = obj["exp"] as? Double { expiry = Date(timeIntervalSince1970: exp) }
            // A server-issued key is bound to one device (`d`). If present, it must match
            // THIS device — a key copied to another phone fails here even though the
            // signature is valid. Keys without `d` (offline/legacy) unlock anywhere.
            if let boundDevice = obj["d"] as? String, boundDevice != WanderDevice.id {
                return Evaluation(valid: false, plan: plan, expiry: expiry)
            }
        }
        // A subscription key stops unlocking once its expiry passes. No `exp` = lifetime.
        if let expiry, Date() >= expiry {
            return Evaluation(valid: false, plan: plan, expiry: expiry)
        }
        return Evaluation(valid: true, plan: plan, expiry: expiry)
    }

    private static func b64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
