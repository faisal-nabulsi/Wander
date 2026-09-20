//
//  GslocCA.swift
//  Wander
//
//  Module 3 of the in-app gs-loc engine (GSLOC_INAPP_PLAN.md): the on-device certificate authority.
//
//  To MITM locationd's TLS connection to gs-loc.apple.com we must present a certificate that the
//  device trusts. That means a self-signed ROOT the user installs and trusts once, plus a LEAF for
//  Apple's WPS hostnames signed by that root.
//
//  WHY OPENSSL AND NOT SECURITY.FRAMEWORK: Security.framework can PARSE X.509
//  (`SecCertificateCreateWithData`) but cannot BUILD one on iOS, and `SecIdentityCreateWithCertificate`
//  is macOS-only (`__IPHONE_NA`). Hand-rolling DER + `SecKeyCreateSignature` is possible but is a lot of
//  ASN.1 to get subtly wrong. OpenSSL 3.3.2 is ALREADY linked and embedded in this app (it ships inside
//  the AltSign dependency, Apache-2.0), it builds and signs X.509 directly, and an OpenSSL server
//  context takes `X509*` + `EVP_PKEY*` — so `SecIdentity` never enters the picture.
//
//  ⚠️ FOUR RULES THAT FAIL SILENTLY IF BROKEN. Each produces "installed fine, TLS still doesn't work",
//  which is the most expensive kind of bug:
//   1. The ROOT must carry `keyUsage` CRITICAL with `keyCertSign`. Without it iOS installs the profile
//      but the certificate NEVER APPEARS under Settings → General → About → Certificate Trust Settings,
//      so the user can't grant full trust and has nothing to tap. (Apple DTS, forum 743058.)
//   2. The LEAF must carry `subjectAltName` dNSName entries. Since iOS 13 the CommonName is IGNORED for
//      hostname matching — a CN-only cert fails validation with no useful error.
//   3. Validity must be SHORT. iOS rejects user-trusted server certs with lifetimes over 398 days
//      (and 825 days for the root). We use 397 / 730 to stay clear of the boundary.
//   4. SHA-256 signatures and P-256 keys. SHA-1 is rejected outright.
//
//  ⚠️ NEVER SHIP A BAKED-IN CA KEY. The root private key is generated ON DEVICE, per install, and kept
//  in the keychain. A CA key inside the IPA could be extracted by anyone who unzips it, and then used to
//  MITM every user who ever trusted our root — that would be a genuine security disaster, not a bug.
//

import Foundation
import Security
import OpenSSL
import OpenSSLShim

/// The hostnames we terminate TLS for. Exactly the endpoints that serve Apple's WPS lookup — see
/// `wander-gsloc-troubleshooting`. Everything else is passed through untouched, so the leaf never needs
/// to impersonate anything beyond this list and no per-SNI issuance is required.
enum GslocHosts {
    static let all = [
        "gs-loc.apple.com",
        "gs-loc-cn.apple.com",
        "gsp-ssl.ls.apple.com",
        "gsp10-ssl.ls.apple.com",
        "iphone-services.apple.com",
    ]

    /// True when a CONNECT target should be MITM'd rather than blindly tunnelled.
    static func shouldIntercept(host: String) -> Bool {
        let h = host.lowercased()
        return all.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

/// Certificate lifetimes, in days. Deliberately inside Apple's ceilings rather than at them.
enum GslocCAPolicy {
    /// Apple rejects user-trusted SERVER certs over 398 days. 397 leaves a day of headroom.
    static let leafDays: Int32 = 397
    /// User-added ROOTS are bounded at 825 days. 730 (2 years) is comfortably inside and means the user
    /// re-trusts at most every other year.
    static let rootDays: Int32 = 730
    /// Regenerating the leaf on every launch costs microseconds and removes a whole class of
    /// "why did this expire" support, so there is no reason to persist it.
    static let regenerateLeafOnLaunch = true
}

/// Keychain storage for the ROOT private key. Only the root key is persisted: the root certificate can
/// be rebuilt deterministically from it, and the leaf is disposable.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly` on purpose — the proxy must be able to start while
/// the phone is locked (a spoof running in the background outlives the lock screen), but the key must
/// never sync to iCloud or migrate to another device in a backup.
enum GslocCAStore {
    private static let service = "com.wander.gsloc.ca"
    private static let account = "root-private-key-pem"

    static func loadRootKeyPEM() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecUseDataProtectionKeychain as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveRootKeyPEM(_ pem: String) -> Bool {
        let data = Data(pem.utf8)
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        attrs[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(attrs as CFDictionary)   // overwrite semantics; add fails on a duplicate
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Wipe the CA. Used when the user resets the engine — after this the old root they trusted is dead
    /// and they must install the new one, so the UI has to say that plainly.
    static func reset() {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        q[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(q as CFDictionary)
    }
}

/// Names shown to the user in Settings → Certificate Trust Settings. Explicit and honest: this is the
/// certificate that lets Wander rewrite Apple's Wi-Fi location lookup, and a user inspecting their
/// trusted roots deserves to recognize it instantly rather than find an anonymous entry.
enum GslocCAIdentity {
    static let rootCommonName = "Wander Local CA"
    static let rootOrganization = "Wander"
    /// Leaf CN is cosmetic — iOS matches on subjectAltName — but a readable one helps when debugging.
    static let leafCommonName = "gs-loc.apple.com"
}

// MARK: - X.509 generation (OpenSSL)

/// Builds the root CA and the leaf. Owns raw OpenSSL pointers, so it is a class with explicit
/// teardown rather than a struct — every `X509`/`EVP_PKEY` here must be freed exactly once.
final class GslocCertificateAuthority {

    enum GenError: Error, CustomStringConvertible {
        case keygenFailed
        case certAllocFailed
        case signFailed(String)
        case encodeFailed(String)
        case keychainFailed

        var description: String {
            switch self {
            case .keygenFailed: return "EC P-256 key generation failed"
            case .certAllocFailed: return "X509_new returned null"
            case let .signFailed(what): return "signing failed: \(what)"
            case let .encodeFailed(what): return "DER/PEM encode failed: \(what)"
            case .keychainFailed: return "could not persist the CA key to the keychain"
            }
        }
    }

    /// A generated certificate plus its key. `der` is what the user installs / what TLS presents.
    struct Material {
        let x509: OpaquePointer      // X509*
        let key: OpaquePointer       // EVP_PKEY*
        let der: Data
    }

    // MARK: Keys

    /// P-256. Chosen over RSA because generation is instantaneous (RSA-2048 keygen can take seconds on
    /// a phone and would stall the proxy's first connection), and ECDSA-with-SHA256 is universally
    /// accepted by iOS's trust evaluator.
    private static func generateP256Key() throws -> OpaquePointer {
        guard let ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, nil) else { throw GenError.keygenFailed }
        defer { EVP_PKEY_CTX_free(ctx) }
        guard EVP_PKEY_keygen_init(ctx) == 1 else { throw GenError.keygenFailed }
        // Signature is (ctx, keytype, optype, cmd, p1, p2) — six arguments. The convenience form
        // `EVP_PKEY_CTX_set_ec_paramgen_curve_nid` is a macro and so is invisible to Swift.
        guard EVP_PKEY_CTX_ctrl(ctx, EVP_PKEY_EC, EVP_PKEY_OP_KEYGEN,
                                EVP_PKEY_CTRL_EC_PARAMGEN_CURVE_NID,
                                NID_X9_62_prime256v1, nil) == 1 else { throw GenError.keygenFailed }
        var pkey: OpaquePointer?
        guard EVP_PKEY_keygen(ctx, &pkey) == 1, let key = pkey else { throw GenError.keygenFailed }
        return key
    }

    /// PEM round-trip, so the root key can live in the keychain as text.
    private static func keyToPEM(_ key: OpaquePointer) throws -> String {
        guard let bio = BIO_new(BIO_s_mem()) else { throw GenError.encodeFailed("BIO_new") }
        defer { BIO_free(bio) }
        guard PEM_write_bio_PrivateKey(bio, key, nil, nil, 0, nil, nil) == 1 else {
            throw GenError.encodeFailed("PEM_write_bio_PrivateKey")
        }
        var buf: UnsafeMutablePointer<CChar>?
        let len = wander_BIO_get_mem_data(bio, &buf)
        guard len > 0, let b = buf else { throw GenError.encodeFailed("BIO_get_mem_data") }
        return String(decoding: UnsafeRawBufferPointer(start: b, count: Int(len)), as: UTF8.self)
    }

    private static func keyFromPEM(_ pem: String) -> OpaquePointer? {
        let bytes = Array(pem.utf8)
        guard let bio = BIO_new_mem_buf(bytes, Int32(bytes.count)) else { return nil }
        defer { BIO_free(bio) }
        return PEM_read_bio_PrivateKey(bio, nil, nil, nil)
    }

    // MARK: Certificate assembly

    /// Add an X509v3 extension by NID. `X509V3_EXT_conf_nid` takes the OpenSSL text form, which is why
    /// the four critical rules below read as strings — e.g. "critical,keyCertSign".
    private static func addExtension(_ cert: OpaquePointer,
                                     issuer: OpaquePointer,
                                     nid: Int32,
                                     value: String) throws {
        var ctx = X509V3_CTX()
        X509V3_set_ctx(&ctx, issuer, cert, nil, nil, 0)
        guard let ext = value.withCString({ X509V3_EXT_conf_nid(nil, &ctx, nid, $0) }) else {
            throw GenError.signFailed("X509V3_EXT_conf_nid(\(nid), \(value))")
        }
        defer { X509_EXTENSION_free(ext) }
        guard X509_add_ext(cert, ext, -1) == 1 else {
            throw GenError.signFailed("X509_add_ext(\(nid))")
        }
    }

    private static func setName(_ cert: OpaquePointer, commonName: String, org: String, isSubject: Bool) {
        let name = isSubject ? X509_get_subject_name(cert) : X509_get_issuer_name(cert)
        _ = commonName.withCString {
            X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, $0, -1, -1, 0)
        }
        _ = org.withCString {
            X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, $0, -1, -1, 0)
        }
    }

    private static func toDER(_ cert: OpaquePointer) throws -> Data {
        var buf: UnsafeMutablePointer<UInt8>?
        let len = i2d_X509(cert, &buf)
        guard len > 0, let b = buf else { throw GenError.encodeFailed("i2d_X509") }
        // `OPENSSL_free` is a macro over CRYPTO_free(addr, file, line), so Swift can't see it — call the
        // underlying function. The file/line are only used by OpenSSL's leak tracker.
        defer { CRYPTO_free(b, #fileID, #line) }
        return Data(bytes: b, count: Int(len))
    }

    /// Serial numbers must be unique per issuer and unpredictable. A random 64-bit positive value is
    /// plenty here and avoids the "two certs with serial 1" collision that makes iOS cache the wrong one.
    private static func setRandomSerial(_ cert: OpaquePointer) {
        var raw = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        raw[0] &= 0x7f   // keep it positive; a negative serial is malformed
        let bn = BN_bin2bn(raw, Int32(raw.count), nil)
        defer { BN_free(bn) }
        _ = BN_to_ASN1_INTEGER(bn, X509_get_serialNumber(cert))
    }

    // MARK: Root

    /// Build (or rebuild) the root CA certificate from a key.
    ///
    /// RULE 1 LIVES HERE: `basicConstraints = critical,CA:TRUE` plus `keyUsage = critical,keyCertSign,cRLSign`.
    /// Without the critical keyUsage carrying keyCertSign, iOS accepts the profile but the certificate
    /// never appears under Certificate Trust Settings — the user has nothing to toggle, and the whole
    /// flow dead-ends with no error message anywhere.
    static func makeRoot(key: OpaquePointer) throws -> Material {
        guard let cert = X509_new() else { throw GenError.certAllocFailed }
        X509_set_version(cert, 2)              // v3
        setRandomSerial(cert)
        X509_gmtime_adj(X509_getm_notBefore(cert), -60 * 60 * 24)   // backdate a day for clock skew
        X509_gmtime_adj(X509_getm_notAfter(cert), 60 * 60 * 24 * Int(GslocCAPolicy.rootDays))
        setName(cert, commonName: GslocCAIdentity.rootCommonName, org: GslocCAIdentity.rootOrganization, isSubject: true)
        setName(cert, commonName: GslocCAIdentity.rootCommonName, org: GslocCAIdentity.rootOrganization, isSubject: false)
        X509_set_pubkey(cert, key)

        try addExtension(cert, issuer: cert, nid: NID_basic_constraints, value: "critical,CA:TRUE")
        try addExtension(cert, issuer: cert, nid: NID_key_usage, value: "critical,keyCertSign,cRLSign")
        try addExtension(cert, issuer: cert, nid: NID_subject_key_identifier, value: "hash")

        guard X509_sign(cert, key, EVP_sha256()) > 0 else {
            X509_free(cert)
            throw GenError.signFailed("root X509_sign")
        }
        return Material(x509: cert, key: key, der: try toDER(cert))
    }

    // MARK: Leaf

    /// Build the server leaf for Apple's WPS hostnames, signed by the root.
    ///
    /// RULE 2 LIVES HERE: `subjectAltName` with every hostname as a dNSName. Since iOS 13 the CommonName
    /// is ignored for hostname matching, so a CN-only certificate fails validation with no useful error.
    /// RULE 3: validity stays under Apple's 398-day ceiling for user-trusted server certs.
    static func makeLeaf(rootCert: OpaquePointer, rootKey: OpaquePointer) throws -> Material {
        let leafKey = try generateP256Key()
        guard let cert = X509_new() else {
            EVP_PKEY_free(leafKey)
            throw GenError.certAllocFailed
        }
        X509_set_version(cert, 2)
        setRandomSerial(cert)
        X509_gmtime_adj(X509_getm_notBefore(cert), -60 * 60 * 24)
        X509_gmtime_adj(X509_getm_notAfter(cert), 60 * 60 * 24 * Int(GslocCAPolicy.leafDays))
        setName(cert, commonName: GslocCAIdentity.leafCommonName, org: GslocCAIdentity.rootOrganization, isSubject: true)
        X509_set_issuer_name(cert, X509_get_subject_name(rootCert))
        X509_set_pubkey(cert, leafKey)

        let san = GslocHosts.all.map { "DNS:" + $0 }.joined(separator: ",")
        try addExtension(cert, issuer: rootCert, nid: NID_basic_constraints, value: "critical,CA:FALSE")
        try addExtension(cert, issuer: rootCert, nid: NID_key_usage, value: "critical,digitalSignature,keyEncipherment")
        try addExtension(cert, issuer: rootCert, nid: NID_ext_key_usage, value: "serverAuth")
        try addExtension(cert, issuer: rootCert, nid: NID_subject_alt_name, value: san)

        guard X509_sign(cert, rootKey, EVP_sha256()) > 0 else {
            X509_free(cert)
            EVP_PKEY_free(leafKey)
            throw GenError.signFailed("leaf X509_sign")
        }
        return Material(x509: cert, key: leafKey, der: try toDER(cert))
    }

    // MARK: Lifecycle

    /// Load the persisted root, or mint one on first use. The KEY is what persists; the certificate is
    /// rebuilt from it, which keeps the keychain item small and means a policy change (name, lifetime)
    /// takes effect without invalidating what the user already trusted... as long as the key is stable.
    static func loadOrCreateRoot() throws -> Material {
        if let pem = GslocCAStore.loadRootKeyPEM(), let key = keyFromPEM(pem) {
            return try makeRoot(key: key)
        }
        let key = try generateP256Key()
        guard GslocCAStore.saveRootKeyPEM(try keyToPEM(key)) else {
            EVP_PKEY_free(key)
            throw GenError.keychainFailed
        }
        return try makeRoot(key: key)
    }

    static func free(_ m: Material) {
        X509_free(m.x509)
        EVP_PKEY_free(m.key)
    }
}
