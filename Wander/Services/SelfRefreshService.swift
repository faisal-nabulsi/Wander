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
import UserNotifications

@MainActor
final class SelfRefreshService: ObservableObject {
    static let shared = SelfRefreshService()

    /// Human-readable progress/result of the last (or current) refresh. Mirrors the old
    /// `selfRefreshStatus` local the Settings button used to own.
    @Published var status: String?
    /// True while a refresh is in flight — guards against re-entrancy (manual + auto).
    @Published private(set) var isRefreshing = false
    /// Set when an auto-refresh couldn't authenticate at all (cached token + password re-auth
    /// both failed). Drives a visible "sign in again" banner in the UI; cleared on a successful
    /// sign-in/refresh. Distinct from a transient tunnel/2FA hiccup, which just retries silently.
    @Published private(set) var needsReSignIn = false

    /// Persisted "an automatic refresh was cut short (tunnel down, 2FA not entered, transient
    /// error) — try again next launch" flag. `autoRefreshIfNearExpiry` runs even if not-yet
    /// near threshold isn't the gate when this is set, so a missed window still gets retried.
    private static let retryFlagKey = "wander.selfRefresh.retryNextLaunch"
    private var retryNextLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.retryFlagKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.retryFlagKey) }
    }

    /// Notification id for the "re-sign-in needed" local notification, so we can de-dupe it.
    private static let reSignInNoticeID = "wander.selfRefresh.reSignIn"

    private init() {}

    /// The base bundle id both self-refresh and OTA sign against. The resigned bundle id
    /// is `<base>.<teamID>`, so `Bundle.main.bundleIdentifier` at runtime is either this
    /// (a fresh dev build) or that prefixed with a team id (after a self-refresh).
    private static let baseBundleID = "com.stik.stikdebug"

    // MARK: - Self-refresh (shared)

    /// Outcome of a `refresh()` run, so the automatic caller can decide whether to arm a
    /// retry, surface a re-sign-in notice, or do nothing. The manual button ignores it.
    enum RefreshResult {
        case success
        case skippedNotSignedIn
        case skippedBusy
        /// Session couldn't be authenticated at all (token + password both failed).
        case authExpired
        /// 2FA prompt timed out during an auto refresh — user wasn't there to enter it.
        case twoFactorTimedOut
        /// Anything else (tunnel/network down, transient Apple error). `retryable`.
        case failed
    }

    /// Run the full self-refresh: copy our own bundle → strip the inert appex → re-sign
    /// with the Apple ID → install over the tunnel. Publishes progress to `status`.
    /// No-ops (with a status message) when not signed in, and is guarded against
    /// concurrent runs so the manual button and the auto hook can't collide.
    ///
    /// `interactive` is forwarded to auth: a user-tapped refresh (default) waits on 2FA
    /// indefinitely; an automatic one times the 2FA prompt out so it can't hang the launch.
    @discardableResult
    func refresh(interactive: Bool = true) async -> RefreshResult {
        guard !isRefreshing else { return .skippedBusy }
        guard WanderAccount.shared.isSignedIn else {
            status = "Sign in to Apple ID first (button above)."
            return .skippedNotSignedIn
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
                interactive: interactive,
                progress: { [weak self] s in lastStep = s; self?.status = s }
            )
            lastStep = "installing"
            status = "Installing signed app over the tunnel…"
            try await Task.detached(priority: .userInitiated) {
                try JITEnableContext.shared.stageAndUpgradeAppBundle(atLocalPath: srcApp.path, bundleID: bundleID)
            }.value
            status = "✅ Self-refresh complete — signed + installed as \(bundleID)"
            // A good sign-in clears any lingering "re-sign-in" state.
            needsReSignIn = false
            return .success
        } catch WanderAccount.SignError.sessionExpired {
            status = "❌ Apple sign-in expired — sign in again to keep Wander updating."
            return .authExpired
        } catch WanderAccount.SignError.twoFactorTimedOut {
            status = "Refresh paused — 2FA code wasn't entered. Will retry on next launch."
            return .twoFactorTimedOut
        } catch {
            let ns = error as NSError
            status = "❌ [\(lastStep)] \(ns.localizedDescription) · \(ns.domain) #\(ns.code)"
            return .failed
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

    /// Called once on app launch. Automatically runs a self-refresh when the app's sideload
    /// signature is near expiry (or a previous auto-refresh asked to retry) AND the Apple ID
    /// is signed in AND we aren't already refreshing. Never prompts a loop, never crashes, and
    /// — crucially — never fails silently: every abnormal exit either arms a next-launch retry
    /// or surfaces a visible notice.
    func autoRefreshIfNearExpiry() async {
        // Cheap gates first — no tunnel/profile work unless these hold.
        guard WanderAccount.shared.isSignedIn else { return }
        guard !isRefreshing else { return }

        let hadPendingRetry = retryNextLaunch

        let expiry = await signatureExpiry()   // nil == couldn't read (tunnel/profile/decode)

        if let expiry {
            let daysLeft = expiry.numberOfCalendarDays(since: Date())
            // Run when near expiry (including already-past, negative days) OR a retry is pending.
            guard daysLeft <= Self.autoRefreshThresholdDays || hadPendingRetry else { return }
        } else {
            // Gap (b) — tunnel/network down: we can't even read the expiry. If a refresh was
            // already due (a retry was pending), keep it armed for next launch and say so,
            // instead of silently one-shot-failing. If nothing was pending, just skip quietly.
            if hadPendingRetry {
                retryNextLaunch = true
                status = "Auto-refresh deferred — tunnel unavailable. Will retry on next launch."
            }
            return
        }

        // Re-check after the async profile fetch — a manual refresh may have started.
        guard !isRefreshing, WanderAccount.shared.isSignedIn else { return }

        status = "Auto-refreshing — signature expires soon…"
        let result = await refresh(interactive: false)

        switch result {
        case .success:
            // Clean — nothing to retry, no notice needed.
            retryNextLaunch = false
        case .authExpired:
            // Gap (c) — token + password both failed. Don't retry blindly (it'll just fail
            // the same way); make the need to re-sign-in loudly visible instead.
            retryNextLaunch = false
            surfaceReSignInNotice()
        case .twoFactorTimedOut, .failed:
            // Gap (a) + transient failures — recoverable on a later launch. Arm the retry.
            retryNextLaunch = true
        case .skippedBusy, .skippedNotSignedIn:
            break
        }
    }

    // MARK: - Session-expired notice (gap c)

    /// Make a stalled auto-refresh's need to re-sign-in impossible to miss: flip an in-app
    /// banner flag (surfaced in Settings) AND post a local notification, so the user sees it
    /// whether or not the app is foregrounded. No-ops the notification if it can't authorize.
    private func surfaceReSignInNotice() {
        needsReSignIn = true

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wander — sign in again"
            content.body = "Your Apple ID session expired, so Wander can't refresh its signature. Open Wander and sign in again to keep it running."
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: Self.reSignInNoticeID, content: content, trigger: nil)
            center.removePendingNotificationRequests(withIdentifiers: [Self.reSignInNoticeID])
            center.add(request)
        }
    }

    /// Clear the re-sign-in banner (call after a successful interactive sign-in).
    func clearReSignInNotice() {
        needsReSignIn = false
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.reSignInNoticeID])
    }
}
