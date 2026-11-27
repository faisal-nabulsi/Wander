//
//  WanderUpdater.swift
//  Wander
//
//  In-app OTA updates over the self-refresh pipeline. The app checks a small manifest
//  (update.json) you publish; if a newer build exists it downloads that version's UNSIGNED
//  .ipa, re-signs it with the user's Apple ID (AltSign, same as self-refresh), and installs
//  it over the tunnel — so everyone on an old version updates themselves, no computer.
//
//  Requirements to install mirror self-refresh: signed in to an Apple ID + tunnel connected.
//
//  INTEGRITY (2026-10-12): the manifest is Ed25519-signed by tools/sign-ota-manifest.py with a key
//  that lives OFF GitHub, and carries the IPA's SHA-256 + byte size. `check()` ignores any manifest
//  that doesn't verify against the public key compiled in below, and `installUpdate()` refuses an
//  IPA whose size/hash/CFBundleVersion don't match the signed values — BEFORE unzipping or re-signing.
//  Write access to the repo or release assets alone can no longer push code to every device.
//

import Foundation
import AltSign
import CryptoKit

@MainActor
final class WanderUpdater: ObservableObject {
    static let shared = WanderUpdater()

    /// Plain `Decodable` with the default JSONDecoder: unknown keys are ignored, so builds that
    /// predate the integrity fields decode a signed manifest fine (and keep updating), and these
    /// optional fields mean an old/unsigned manifest still decodes here — it just fails verification.
    struct Manifest: Decodable {
        let build: Int
        let version: String
        let payloadURL: String
        /// Display-only release notes. NOT covered by the signature — never let it drive behavior.
        let notes: String?
        /// Lowercase hex SHA-256 of the IPA at `payloadURL` (signed).
        let sha256: String?
        /// Byte size of that IPA (signed).
        let size: Int?
        /// Base64 Ed25519 signature over `OTAIntegrity.canonicalMessage(...)`.
        let sig: String?
    }

    @Published private(set) var available: Manifest?
    /// The last manifest fetched by `check()`, regardless of whether it's newer than this build.
    /// When its `build` equals the installed build, its `notes` drive the "What's New" card.
    @Published private(set) var latestManifest: Manifest?
    @Published private(set) var isBusy = false
    @Published var status: String = ""

    /// Set when an update is available but couldn't be auto-installed unattended (needs a
    /// signed-in Apple ID / connected tunnel, or the silent attempt hit something that needs
    /// the user). Drives an in-app "Update ready — tap to install" prompt; the manual Settings
    /// button stays as the fallback action. Cleared once an install succeeds.
    @Published private(set) var needsUserAction = false

    /// Guards auto-install to at most once per launch, so a failed/declined attempt can't loop.
    private var didAutoInstallThisLaunch = false

    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/faisal-nabulsi/Wander/main/update.json")!

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Release notes for the CURRENTLY INSTALLED build — i.e. the fetched manifest is for this
    /// build (you're on the latest). Drives the "What's New" card. Nil while an update is still
    /// pending (that's the "Update ready" banner's job) or the manifest hasn't loaded.
    var currentBuildNotes: String? {
        guard let m = latestManifest, m.build == currentBuild,
              let n = m.notes, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return n
    }

    /// "v1.0 (56)" — shown under the What's New title.
    var currentBuildVersionLabel: String { "v\(currentVersion) (\(currentBuild))" }

    /// Fetch the manifest; record whether a newer build than this one is published.
    /// Only a manifest whose signature verifies is ever recorded — an unsigned or tampered one is
    /// treated exactly like "no manifest" (no update offered, no What's New notes taken from it).
    func check() async {
        var req = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return   // no manifest / offline == no update
        }
        do {
            _ = try OTAIntegrity.verify(m)
        } catch {
            LogManager.shared.addErrorLog("[updater] Ignoring update.json (build \(m.build)): \(error.localizedDescription)")
            return
        }
        latestManifest = m
        available = (m.build > currentBuild) ? m : nil
    }

    /// Download the new version's IPA, re-sign it with the user's Apple ID, and self-install
    /// it over the tunnel. The app is killed + replaced by the new build (same as self-refresh).
    ///
    /// `interactive` is forwarded to auth: the manual Settings button (default `true`) waits on
    /// a 2FA prompt indefinitely; the launch auto-install passes `false` so 2FA can't hang.
    func installUpdate(interactive: Bool = true) async throws {
        guard let m = available else { throw UpdateError.step("No update available.") }
        // Re-verify here too (not just in check()), so nothing that ever sets `available` can route
        // around the signature. This also enforces an https payloadURL.
        let signed: OTAIntegrity.SignedPayload
        do {
            signed = try OTAIntegrity.verify(m)
        } catch {
            rejectUpdate("update.json for build \(m.build) failed verification: \(error.localizedDescription)")
            throw UpdateError.integrity("This update failed Wander's security check, so it won't be installed. (\(error.localizedDescription))")
        }
        let url = signed.url

        // A proxy VPN (Shadowrocket, for PoGo gs-loc mode) breaks the update two ways: it intercepts the
        // connection to Apple's sign-in servers (→ "Couldn't reach Apple" deep in signing) AND it holds
        // the single iOS VPN slot, so LocalDevVPN can't be up for the install. Refuse early with clear
        // guidance instead of failing cryptically mid-update.
        if GslocMode.enabled || Self.proxyVPNActive() {
            throw UpdateError.step("Turn off Shadowrocket / Games mode (Wi-Fi positioning) before updating. Updates need a clean connection to Apple and LocalDevVPN — a proxy VPN blocks both. Disconnect Shadowrocket, turn off gs-loc mode in Settings → Experimental, turn off its certificate in Certificate Trust Settings, connect LocalDevVPN, then update.")
        }

        // Fail fast with a SPECIFIC reason if Apple's servers are unreachable, instead of a cryptic
        // "Couldn't reach Apple" deep in signing after a pointless download. Catches Wi-Fi off, a DNS/
        // DoH configuration profile blocking apple.com (GitHub still resolves, so the download works but
        // Apple auth doesn't), or a proxy in the path.
        if !(await Self.canReachApple()) {
            throw UpdateError.step("Can't reach Apple's servers. Check, in order: 1) Wi-Fi is on with working internet (try loading apple.com in Safari); 2) ONLY LocalDevVPN is connected — no Shadowrocket; 3) remove any DNS or configuration profile that reroutes DNS (Settings → General → VPN & Device Management → delete any DNS / \"Stabilizer\" / leftover proxy profile), then reboot. Then try the update again.")
        }

        isBusy = true
        defer { isBusy = false }

        let work = URL.documentsDirectory.appendingPathComponent("update-work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        status = "Downloading v\(m.version)…"
        // Bounded download: the default URLSession has NO resource timeout, so a stall on a slow or
        // data-limited tunnel could hang the update forever with the banner stuck on "Downloading…"
        // and isBusy pinned true. Cap the whole transfer so it fails cleanly instead.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        let (tmp, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError.step("Download failed (HTTP \(http.statusCode)).")
        }
        // Free-space guard: the IPA has to be unzipped + re-signed, which needs headroom. Bail early
        // with an actionable message rather than filling the disk mid-install.
        if let free = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < 300_000_000 {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError.step("Not enough free space to install the update. Free up some storage and try again.")
        }
        let ipa = work.appendingPathComponent("update.ipa")
        try? FileManager.default.removeItem(at: ipa)
        try FileManager.default.moveItem(at: tmp, to: ipa)

        // INTEGRITY GATE: the bytes must be exactly what the signed manifest names — size first
        // (cheap), then SHA-256 — BEFORE anything is unzipped, re-signed or installed. On a mismatch
        // the download is deleted. (A benign cause: the IPA was re-uploaded but the new update.json
        // isn't pushed yet; the next launch's check() picks up the matching manifest.)
        status = "Verifying download…"
        let digest: OTAIntegrity.FileDigest
        do {
            digest = try await Task.detached(priority: .userInitiated) { try OTAIntegrity.fileDigest(at: ipa) }.value
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw UpdateError.step("Couldn't read the downloaded update to verify it (\(error.localizedDescription)). Try again.")
        }
        guard digest.size == signed.size, digest.sha256Hex == signed.sha256Hex else {
            try? FileManager.default.removeItem(at: work)
            rejectUpdate("downloaded IPA for build \(signed.build) does not match the signed manifest "
                         + "(size \(digest.size) vs \(signed.size), sha256 \(digest.sha256Hex) vs \(signed.sha256Hex))")
            throw UpdateError.integrity("The downloaded update didn't match its signed checksum, so it was deleted and NOT installed. Try again later.")
        }

        status = "Unpacking…"
        let appURL: URL
        do {
            appURL = try FileManager.default.unzipAppBundle(at: ipa, toDirectory: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        // The signed build number must be the build actually inside the IPA — otherwise a validly
        // signed manifest could be paired with a different (e.g. older) build's payload.
        let infoPlist = (try? Data(contentsOf: appURL.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let bundleBuild = (infoPlist?["CFBundleVersion"] as? String).flatMap { Int($0) }
        guard bundleBuild == signed.build else {
            try? FileManager.default.removeItem(at: work)
            rejectUpdate("IPA CFBundleVersion \(bundleBuild.map { "\($0)" } ?? "missing") != signed build \(signed.build)")
            throw UpdateError.integrity("The downloaded update's build number didn't match its signed manifest, so it was deleted and NOT installed.")
        }
        // Strip the inert TunnelProv.appex (paid-only NE) → simple single-app sign.
        try? FileManager.default.removeItem(at: appURL.appendingPathComponent("PlugIns"))

        status = "Signing with your Apple ID…"
        let bundleID = try await WanderAccount.shared.resignAppBundle(
            at: appURL,
            baseBundleID: "com.stik.stikdebug",
            interactive: interactive,
            progress: { [weak self] s in self?.status = s }
        )

        // The signing team is baked into the bundle ID (com.stik.stikdebug.<teamID>). If the re-signed
        // bundle ID doesn't match the RUNNING app's, the Apple ID signed into Wander isn't the one that
        // installed it — so this "upgrade" would install a SEPARATE app and the running build would stay
        // put (the classic "keeps bouncing back to Update ready"). Stop here with a clear, actionable
        // error instead of installing a phantom second copy.
        if let installed = Bundle.main.bundleIdentifier, installed != bundleID {
            throw UpdateError.appleIDMismatch
        }

        status = "Installing update over the tunnel…"
        // The install talks to the device's developer services OVER the tunnel — which need the DDI
        // mounted. That only happens after a successful location simulation, so a user who just opened
        // the app to update (no teleport yet) — OR a momentarily-stale tunnel — gets a raw
        // "Connection reset by peer". Retry once for a transient reset, then give actionable guidance.
        var installError: Error?
        for attempt in 1...2 {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try JITEnableContext.shared.stageAndUpgradeAppBundle(atLocalPath: appURL.path, bundleID: bundleID)
                }.value
                installError = nil
                break
            } catch {
                installError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            }
        }
        if let error = installError {
            let desc = (error as NSError).localizedDescription.lowercased()
            let looksLikeConnection = ["connection reset", "socket", "econnreset", "connection refused",
                                       "couldn't connect", "could not connect", "not connect",
                                       "timed out", "broken pipe", "connection closed"]
                .contains { desc.contains($0) }
            if looksLikeConnection {
                throw UpdateError.step("Couldn't reach your iPhone to install. 1) Make sure LocalDevVPN is connected. 2) Open the map and drop a pin / tap Simulate once — that wakes your device's developer image, which the updater needs. Then tap Install update again.")
            }
            throw error
        }
        status = "✅ Update installed — Wander will relaunch."
        needsUserAction = false
    }

    // MARK: - Auto-install (launch hook)

    /// Called once on launch after `check()`. When a newer build is published, install it
    /// automatically over the SAME pipeline the Settings button uses — no tap required.
    ///
    /// Fires at most once per launch (`didAutoInstallThisLaunch`) and only when an update is
    /// actually available; the build-number check in `check()` prevents re-installing the
    /// same build in a loop. If the prerequisites for an unattended install aren't met (not
    /// signed in, tunnel not connected) or the silent attempt needs the user (2FA timeout,
    /// expired session) / an unavailable resource, it falls back to a prominent in-app
    /// "Update ready — tap to install" prompt instead of doing nothing. The manual Settings
    /// button remains as the fallback either way.
    func autoInstallIfAvailable() async {
        guard !didAutoInstallThisLaunch else { return }
        guard available != nil else { return }        // build check already ruled out no-op updates
        guard !isBusy else { return }

        // Never silently kill + replace the app mid-spoof — surface the tap prompt instead.
        guard !SimulationSession.shared.isActive else {
            promptUserToInstall("Update ready — tap to install.")
            return
        }
        // Prerequisites for an unattended install mirror self-refresh: signed in + tunnel up. If
        // they aren't ready yet (the tunnel is usually still connecting right after launch), DON'T
        // consume the one-shot guard — surface the prompt and let a later call (once the tunnel
        // connects — see MainTabView) actually perform the silent install.
        guard WanderAccount.shared.isSignedIn else {
            promptUserToInstall("Update ready — sign in to your Apple ID, then tap to install.")
            return
        }
        guard WanderTunnel.shared.status == .connected else {
            promptUserToInstall("Update ready — tap to install (finishing tunnel connection…).")
            return
        }

        didAutoInstallThisLaunch = true   // only now do we actually attempt — so early bails can retry
        status = "Updating Wander…"
        do {
            // Reuse the exact manual install path — no duplicated logic. Auth runs in
            // non-interactive mode so a 2FA prompt can't hang the launch; if it needs the
            // user we fall through to the prompt below.
            try await installUpdate(interactive: false)
        } catch WanderAccount.SignError.twoFactorTimedOut {
            promptUserToInstall("Update ready — tap to install (Apple needs a 2FA code).")
        } catch WanderAccount.SignError.sessionExpired, WanderAccount.SignError.notSignedIn {
            promptUserToInstall("Update ready — sign in to your Apple ID again, then tap to install.")
        } catch UpdateError.appleIDMismatch {
            // Don't let this fail silently back to a bare "Update ready" — this one can't be fixed by
            // retrying. Point the user at the full explanation in Settings → Install update.
            promptUserToInstall("Update can't install — wrong Apple ID. Open Settings → Install update to fix it.")
            status = UpdateError.appleIDMismatch.errorDescription ?? ""
        } catch UpdateError.integrity(let reason) {
            // A payload that failed verification is NOT offered as "tap to install" — rejectUpdate()
            // already withdrew it. Just record why.
            status = reason
        } catch {
            // Any other failure (transient network/tunnel/Apple hiccup, unavailable resource):
            // surface the prompt so the update is one tap away rather than silently lost.
            promptUserToInstall("Update ready — tap to install.")
            status = "Auto-update didn't finish (\((error as NSError).localizedDescription)). Tap to install."
        }
    }

    /// Flip on the in-app "Update ready — tap to install" prompt with a short reason.
    private func promptUserToInstall(_ reason: String) {
        needsUserAction = true
        status = reason
    }

    /// An update failed an integrity check: log it and withdraw the offer for this launch, so the
    /// app doesn't keep prompting the user to install something that can't be verified. The next
    /// launch's `check()` starts fresh (e.g. once a matching manifest is pushed).
    private func rejectUpdate(_ reason: String) {
        LogManager.shared.addErrorLog("[updater] REJECTED update: \(reason)")
        available = nil
        needsUserAction = false
    }

    /// True when a proxy VPN (e.g. Shadowrocket) is active — it installs a scoped system proxy while
    /// connected. LocalDevVPN is a loopback tunnel and does NOT register a proxy, so this cleanly
    /// distinguishes "a proxy is intercepting traffic" from the normal update tunnel.
    private static func proxyVPNActive() -> Bool {
        guard let s = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        // Detect an ACTUALLY-ENABLED HTTP/HTTPS/SOCKS/PAC proxy (Shadowrocket, for gs-loc mode). The old
        // test — "any key starts with HTTP/SOCKS, or __SCOPED__ exists" — was a catch-22 BUG: iOS adds a
        // __SCOPED__ entry (and HTTP*/SOCKS* keys) for ANY active VPN, so it flagged LocalDevVPN — the very
        // tunnel the update installs over — and made every in-app update impossible. Check the *Enable
        // flags being ON instead, top-level and inside each per-interface scope.
        func proxyEnabled(_ d: [String: Any]) -> Bool {
            for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable"] {
                if let v = d[key] as? Int, v != 0 { return true }
                if let v = d[key] as? Bool, v { return true }
            }
            return false
        }
        if proxyEnabled(s) { return true }
        if let scoped = s["__SCOPED__"] as? [String: Any] {
            for value in scoped.values where (value as? [String: Any]).map(proxyEnabled) == true { return true }
        }
        return false
    }

    /// Quick reachability probe to Apple. Returns false ONLY on a transport/DNS failure (URLError) —
    /// any HTTP response (even an error status) means Apple is reachable. Lenient on purpose so a weird
    /// non-transport error never false-blocks a valid update.
    private static func canReachApple() async -> Bool {
        guard let url = URL(string: "https://appleid.apple.com") else { return true }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "HEAD"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        do {
            _ = try await URLSession(configuration: cfg).data(for: req)
            return true
        } catch {
            return !(error is URLError)
        }
    }

    enum UpdateError: LocalizedError {
        case step(String)
        /// The manifest signature, payload size/hash, or bundle build number didn't verify.
        case integrity(String)
        case appleIDMismatch
        var errorDescription: String? {
            switch self {
            case .step(let s): return s
            case .integrity(let s): return s
            case .appleIDMismatch:
                return "This update can't install because the Apple ID signed into Wander isn't the one "
                    + "used to install the app. The signing team is part of the app's identity, so the "
                    + "update would install as a SEPARATE app instead of replacing this one — which is why "
                    + "it keeps bouncing back to \"Update ready.\"\n\nFix it one of two ways:\n"
                    + "1) Delete Wander and reinstall it from the installer signed into THIS Apple ID, or\n"
                    + "2) Sign in here with the Apple ID you originally installed Wander with.\n\n"
                    + "After that, updates will install normally."
            }
        }
    }
}

// MARK: - OTA integrity (signature + payload digest)

/// Verifies `update.json` and the IPA it names. Deliberately NOT actor-isolated (no UI state) so
/// the hashing can run off the main thread. The signer is tools/sign-ota-manifest.py — keep
/// `canonicalMessage` byte-identical to its `canonical_message`.
enum OTAIntegrity {
    /// Ed25519 public key (base64 of the raw 32 bytes) for OTA manifests. The private half is
    /// ~/.config/wander-secrets/wander-ota-signing.key on the publishing Mac — never in git/GitHub.
    /// Rotation: publish one last update signed with the OLD key whose build embeds the NEW public
    /// key. If the private key is LOST, installed apps can only move to a new key by a manual
    /// reinstall (they will refuse every OTA signed with anything else).
    static let otaSigningPublicKeyB64 = "yXb2MqKkDs7yu0SSFyBLwOxw+iRut8HEA5FMOIR1FRI="

    /// Domain/version tag: the first line of every signed message.
    static let signatureDomain = "wander-ota-v1"

    /// What a verified manifest vouches for.
    struct SignedPayload: Sendable {
        let build: Int
        let sha256Hex: String
        let size: Int
        let url: URL
    }

    struct FileDigest: Sendable {
        let sha256Hex: String
        let size: Int
    }

    enum Failure: LocalizedError {
        case unsigned
        case malformed(String)
        case badSignature
        var errorDescription: String? {
            switch self {
            case .unsigned: return "manifest is not signed (missing sha256/size/sig)"
            case .malformed(let why): return "manifest is malformed: \(why)"
            case .badSignature: return "manifest signature is invalid"
            }
        }
    }

    /// The exact bytes that are signed: UTF-8, fields joined by "\n", NO trailing newline.
    /// build and size are plain base-10 integers; sha256 is 64 lowercase hex chars.
    static func canonicalMessage(build: Int, version: String, sha256Hex: String, size: Int, payloadURL: String) -> Data {
        let fields = [signatureDomain, String(build), version, sha256Hex, String(size), payloadURL]
        return Data(fields.joined(separator: "\n").utf8)
    }

    /// Throws unless the manifest is complete, well-formed, names an https payload, and its
    /// signature verifies against `otaSigningPublicKeyB64`.
    static func verify(_ m: WanderUpdater.Manifest) throws -> SignedPayload {
        guard let sha = m.sha256, let size = m.size, let sigB64 = m.sig else { throw Failure.unsigned }
        guard sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Failure.malformed("sha256 must be 64 lowercase hex characters")
        }
        guard m.build > 0, size > 0 else { throw Failure.malformed("build and size must be positive") }
        // A newline inside a field would make the "\n"-joined message ambiguous.
        guard !m.version.contains(where: \.isNewline), !m.payloadURL.contains(where: \.isNewline) else {
            throw Failure.malformed("version/payloadURL contain a newline")
        }
        guard let url = URL(string: m.payloadURL), url.scheme?.lowercased() == "https", url.host != nil else {
            throw Failure.malformed("payloadURL must be an https URL")
        }
        guard let keyData = Data(base64Encoded: otaSigningPublicKeyB64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature = Data(base64Encoded: sigB64),
              publicKey.isValidSignature(signature, for: canonicalMessage(build: m.build, version: m.version,
                                                                          sha256Hex: sha, size: size,
                                                                          payloadURL: m.payloadURL))
        else { throw Failure.badSignature }
        return SignedPayload(build: m.build, sha256Hex: sha, size: size, url: url)
    }

    /// Streaming SHA-256 + byte count of a file (1 MB chunks — no need to hold the IPA in memory).
    static func fileDigest(at url: URL) throws -> FileDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 1 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += chunk.count
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FileDigest(sha256Hex: hex, size: total)
    }
}
