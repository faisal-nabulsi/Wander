//
//  SelfRefreshService.swift
//  Wander
//
//  Shared self-refresh routine: copy the OWN installed bundle, re-sign it with the
//  user's Apple ID (AltSign), and reinstall it over the tunnel — resetting the 7-day
//  free-sideload clock with no computer. Used by both the manual Settings button and
//  the automatic near-expiry launch hook, so the logic lives in one place.
//
//  "Signature expiry" here is the SIDELOAD signing expiry (the 7-day free clock), read
//  from the installed app's own provisioning profile (`ExpirationDate`) — NOT the Pro
//  license expiry.
//

import Foundation

@MainActor
final class SelfRefreshService: ObservableObject {
    static let shared = SelfRefreshService()

    /// Human-readable progress/result of the last (or current) refresh. Mirrors the old
    /// `selfRefreshStatus` local the Settings button used to own.
    @Published var status: String?
    /// True while a refresh is in flight — guards against re-entrancy (manual + auto).
    @Published private(set) var isRefreshing = false

    private init() {}

    /// The base bundle id both self-refresh and OTA sign against. The resigned bundle id
    /// is `<base>.<teamID>`, so `Bundle.main.bundleIdentifier` at runtime is either this
    /// (a fresh dev build) or that prefixed with a team id (after a self-refresh).
    private static let baseBundleID = "com.stik.stikdebug"

    // MARK: - Self-refresh (shared)

    /// Run the full self-refresh: copy our own bundle → strip the inert appex → re-sign
    /// with the Apple ID → install over the tunnel. Publishes progress to `status`.
    /// No-ops (with a status message) when not signed in, and is guarded against
    /// concurrent runs so the manual button and the auto hook can't collide.
    func refresh() async {
        guard !isRefreshing else { return }
        guard WanderAccount.shared.isSignedIn else {
            status = "Sign in to Apple ID first (button above)."
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        var lastStep = "starting"
        status = "Starting…"

        let workDir = URL.documentsDirectory.appendingPathComponent("refresh-work", isDirectory: true)
        let srcApp = workDir.appendingPathComponent("Wander.app")
        do {
            // Copy our OWN installed bundle into a writable work dir — true self-refresh,
            // no external file needed.
            status = "Copying app bundle…"
            try? FileManager.default.removeItem(at: workDir)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: srcApp)
            // Strip the inert TunnelProv.appex (paid-only NE) → simple single-app sign.
            try? FileManager.default.removeItem(at: srcApp.appendingPathComponent("PlugIns"))

            let bundleID = try await WanderAccount.shared.resignAppBundle(
                at: srcApp,
                baseBundleID: Self.baseBundleID,
                progress: { [weak self] s in lastStep = s; self?.status = s }
            )
            lastStep = "installing"
            status = "Installing signed app over the tunnel…"
            try await Task.detached(priority: .userInitiated) {
                try JITEnableContext.shared.stageAndUpgradeAppBundle(atLocalPath: srcApp.path, bundleID: bundleID)
            }.value
            status = "✅ Self-refresh complete — signed + installed as \(bundleID)"
        } catch {
            let ns = error as NSError
            status = "❌ [\(lastStep)] \(ns.localizedDescription) · \(ns.domain) #\(ns.code)"
        }
    }

    // MARK: - Sideload signature expiry

    /// The installed app's own sideload-signature expiry, read from its provisioning
    /// profile's `ExpirationDate`. Returns nil if it can't be determined (no tunnel,
    /// no matching profile, decode failure) — callers must treat nil as "unknown, skip".
    ///
    /// Matches the profile whose `application-identifier` corresponds to THIS app's
    /// bundle id. After a self-refresh the installed id is `<base>.<teamID>`; a profile's
    /// application-identifier is `<teamID>.<bundleID>`, so we match by suffix on the
    /// runtime bundle id and fall back to the base id.
    func signatureExpiry() async -> Date? {
        let ownBundleID = Bundle.main.bundleIdentifier ?? Self.baseBundleID
        let candidates: Set<String> = [ownBundleID, Self.baseBundleID]

        let profiles: [Profile]
        do {
            let datas = try await Task.detached(priority: .utility) {
                try JITEnableContext.shared.fetchAllProfiles()
            }.value
            profiles = datas.map { Profile(data: $0) }
        } catch {
            return nil
        }

        let matching = profiles.filter { profile in
            guard profile.decodeError == nil else { return false }
            let entitlements = profile.plistDict?["Entitlements"] as? [String: Any]
            let appIdentifier = (entitlements?["application-identifier"] as? String) ?? profile.appId
            // application-identifier is `<teamID>.<bundleID>`; match its bundle-id suffix.
            return candidates.contains { appIdentifier.hasSuffix($0) }
        }

        // Newest (furthest-out) expiry for our app — that's the signature currently in force.
        return matching.compactMap { $0.expirationDate }.max()
    }

    // MARK: - Automatic near-expiry refresh (launch hook)

    /// Number of days-until-expiry at or below which an automatic refresh fires. Aligned
    /// with the App Expiry screen's orange band (`2...3` days) — 2 days of runway left.
    static let autoRefreshThresholdDays = 2

    /// Called once on app launch. Automatically runs a self-refresh ONLY when the app's
    /// sideload signature is near expiry AND the Apple ID is signed in AND we aren't
    /// already refreshing. Silently skips otherwise — never prompts a loop, never crashes.
    func autoRefreshIfNearExpiry() async {
        // Cheap gates first — no tunnel/profile work unless these hold.
        guard WanderAccount.shared.isSignedIn else { return }
        guard !isRefreshing else { return }

        guard let expiry = await signatureExpiry() else { return }  // unknown → skip

        let daysLeft = expiry.numberOfCalendarDays(since: Date())
        // Only near expiry (including already-past, negative days). Not every launch.
        guard daysLeft <= Self.autoRefreshThresholdDays else { return }

        // Re-check after the async profile fetch — a manual refresh may have started.
        guard !isRefreshing, WanderAccount.shared.isSignedIn else { return }

        status = "Auto-refreshing — signature expires soon…"
        await refresh()
    }
}
