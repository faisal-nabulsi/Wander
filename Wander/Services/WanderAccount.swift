//
//  WanderAccount.swift
//  Wander
//
//  On-device Apple-ID sign-in via AltSign — the auth half of self-refresh (auth → cert →
//  sign). Credentials + the last session token are persisted in the Keychain so a sign-in
//  survives closing the app (and a self-refresh).
//
//  "Signed in" means *credentials are saved* — a synchronous, offline check. The live Apple
//  session (account/session objects) is established lazily via `ensureAuthenticated()` only
//  when self-refresh needs it, so the signed-in UI never depends on a network round-trip.
//

import Foundation
import AltSign
import SwiftUI

@MainActor
final class WanderAccount: ObservableObject {
    static let shared = WanderAccount()

    @Published var status: String = ""
    @Published private(set) var isSignedIn = false
    @Published var awaiting2FA = false

    /// Which on-screen context owns the 2FA prompt. Set by whoever STARTS a sign-in, before the
    /// prompt is raised, so exactly ONE `.alert` binds true. Several `.alert(isPresented:)` on the
    /// same Bool (we had three — root, Settings, login) make SwiftUI present then instantly dismiss
    /// the alert — the vanishing 2FA prompt — and can crash. This token guarantees one live presenter.
    enum TwoFactorPresenter { case system, settings, login }
    @Published var twoFactorPresenter: TwoFactorPresenter = .system

    private(set) var account: ALTAccount?
    private(set) var session: ALTAppleAPISession?

    private var codeContinuations: [CheckedContinuation<String?, Never>] = []

    /// How long an *automatic* (non-user-initiated) refresh waits for a 2FA code before it
    /// gives up. Keeps a launch-time auto-refresh from hanging the app in a 2FA prompt the
    /// user never sees or acts on. Interactive sign-in never times out.
    static let auto2FATimeout: TimeInterval = 180   // 3 minutes

    private static let nameKey = "wander.appleid.name"

    private init() {
        // Signed-in state is purely "do we have saved credentials" — no network, no waiting.
        if WanderCredentialStore.loadCredentials() != nil {
            isSignedIn = true
            let name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
            status = name.isEmpty ? "Apple ID — signed in ✓" : "✅ Signed in as \(name)"
        }
    }

    // MARK: - Interactive sign-in

    /// Authenticate with a (free) Apple ID. Handles 2FA by surfacing `awaiting2FA` to the UI
    /// and resuming once `submitTwoFactorCode(_:)` is called. Persists on success.
    func signIn(appleID: String, password: String) async {
        let email = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            status = "Enter your Apple ID and password."
            return
        }

        status = "Fetching anisette…"
        do {
            let (acct, sess) = try await performAuthenticate(email: email, password: password, allowInteractive2FA: true)
            adopt(account: acct, session: sess, email: email, password: password)
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    // MARK: - Restore on launch (offline)

    /// Restore the signed-in *display* state from the Keychain. No network — just reflects
    /// whether credentials are stored. The live session is re-established later on demand.
    func restoreSession() {
        if WanderCredentialStore.loadCredentials() != nil {
            isSignedIn = true
            let name = UserDefaults.standard.string(forKey: Self.nameKey) ?? ""
            if status.isEmpty { status = name.isEmpty ? "Apple ID — signed in ✓" : "✅ Signed in as \(name)" }
        } else {
            isSignedIn = false
        }
    }

    // MARK: - Ensure a live session (used by self-refresh)

    /// Guarantee a usable `(account, session)` for signing, re-authenticating if needed:
    /// reuse the live session → reuse a cached token (no prompt) → password re-auth (+ 2FA).
    /// Throws `SignError.notSignedIn` if no credentials are stored.
    ///
    /// `interactive` distinguishes a user-tapped refresh from an automatic launch-time one:
    /// - `true`  (default): 2FA blocks indefinitely on the in-app prompt — the user is here.
    /// - `false` (auto refresh): 2FA is still offered, but times out after `auto2FATimeout`
    ///   (throwing `SignError.twoFactorTimedOut`) so the app can never hang unattended in an
    ///   auth prompt. A hard auth failure (bad/expired credentials) throws `SignError.sessionExpired`.
    func ensureAuthenticated(interactive: Bool = true) async throws -> (ALTAccount, ALTAppleAPISession) {
        if let account, let session { return (account, session) }

        guard let creds = WanderCredentialStore.loadCredentials() else {
            throw SignError.notSignedIn
        }

        // Cached token first — zero prompts while Apple still honors it.
        if let cache = WanderCredentialStore.loadSessionCache(),
           await adoptCachedSession(email: creds.email, dsid: cache.dsid, authToken: cache.authToken),
           let account, let session {
            return (account, session)
        }

        // Token gone/expired → full re-auth. 2FA is interactive; in auto mode it's bounded
        // by a timeout so an unattended launch can't wedge on the prompt forever.
        WanderCredentialStore.clearSessionCache()
        do {
            let (acct, sess) = try await performAuthenticate(
                email: creds.email, password: creds.password,
                allowInteractive2FA: true, twoFactorTimeout: interactive ? nil : Self.auto2FATimeout)
            adopt(account: acct, session: sess, email: creds.email, password: creds.password)
            return (acct, sess)
        } catch let e as SignError {
            throw e   // already classified (e.g. twoFactorTimedOut)
        } catch {
            // Cached token AND password re-auth both failed → the saved session is no longer
            // usable. Surface a clear "re-sign-in" signal instead of a generic error.
            throw SignError.sessionExpired
        }
    }

    // MARK: - Sign out

    func signOut() {
        // Resume any pending 2FA continuation so it doesn't leak.
        submitTwoFactorCode(nil)
        account = nil
        session = nil
        isSignedIn = false
        awaiting2FA = false
        WanderCredentialStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        status = "Signed out."
    }

    // MARK: - 2FA plumbing

    /// Surface the 2FA prompt and await the entered code. When `timeout` is non-nil (an
    /// automatic refresh), auto-cancel after that interval — resolving the continuation with
    /// nil and clearing the prompt — so the app never hangs waiting on an absent user.
    private func requestTwoFactorCode(timeout: TimeInterval?) async -> String? {
        // AltSign can invoke the verification handler more than once for a single sign-in (a retry,
        // or it fires again before the first prompt resolves). We keep a LIST of pending continuations
        // and show ONE prompt; when the user submits, every pending caller gets the same code. The old
        // single-slot version OVERWROTE the pending continuation → dropped it unresumed → a hard
        // "leaked its continuation" crash (for some accounts) or the prompt vanishing before the code
        // could be entered (for others). Same root bug, two faces.
        let code = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.codeContinuations.append(continuation)
            self.awaiting2FA = true
            if let timeout {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    // Auto-refresh only: bound the wait so the app can't hang. A delivered code has
                    // already emptied the list, so this becomes a no-op.
                    if !self.codeContinuations.isEmpty { self.submitTwoFactorCode(nil) }
                }
            }
        }
        return code
    }

    /// Called by the UI with the entered 6-digit code (or nil to cancel).
    func submitTwoFactorCode(_ code: String?) {
        awaiting2FA = false
        let pending = codeContinuations
        codeContinuations = []
        for continuation in pending { continuation.resume(returning: code) }
    }

    /// A per-context binding for the 2FA alert: true only when a code is awaited AND this context is
    /// the designated presenter, so only one `.alert` is ever live at a time.
    func twoFactorPrompt(for presenter: TwoFactorPresenter) -> Binding<Bool> {
        Binding(
            get: { self.awaiting2FA && self.twoFactorPresenter == presenter },
            set: { presented in
                // The buttons resume the continuation + clear the flag; this only guards an
                // unexpected dismissal so a dropped prompt never leaks its continuation.
                if !presented && self.awaiting2FA { self.submitTwoFactorCode(nil) }
            }
        )
    }

    // MARK: - Internals

    private func adopt(account acct: ALTAccount, session sess: ALTAppleAPISession, email: String, password: String) {
        account = acct
        session = sess
        isSignedIn = true
        let who = acct.name.isEmpty ? acct.appleID : acct.name
        status = "✅ Signed in as \(who)"
        UserDefaults.standard.set(who, forKey: Self.nameKey)
        WanderCredentialStore.saveCredentials(email: email, password: password)
        WanderCredentialStore.saveSessionCache(dsid: sess.dsid, authToken: sess.authToken)
        // A fresh, working session clears any "your session expired — sign in again" notice.
        SelfRefreshService.shared.clearReSignInNotice()
    }

    /// One `authenticate` call. `allowInteractive2FA == false` passes a nil verificationHandler,
    /// so AltSign fails fast with `.requiresTwoFactorAuthentication` instead of blocking.
    /// `twoFactorTimeout` (auto refresh only) bounds the in-app 2FA prompt; if it elapses the
    /// code comes back nil and this throws `SignError.twoFactorTimedOut`.
    private func performAuthenticate(email: String, password: String, allowInteractive2FA: Bool, twoFactorTimeout: TimeInterval? = nil) async throws -> (ALTAccount, ALTAppleAPISession) {
        let anisette = try await WanderAnisette.fetch()
        if allowInteractive2FA { status = "Contacting Apple…" }

        // Set true if the 2FA prompt was shown but returned no code (user cancelled or the
        // auto-refresh timeout fired) — lets us report a precise timeout rather than a
        // generic Apple error when authenticate() subsequently fails.
        var twoFactorAbandoned = false

        let verificationHandler: ((@escaping (String?) -> Void) -> Void)? = allowInteractive2FA
            ? { [weak self] codeCompletion in
                Task { @MainActor in
                    let code = await self?.requestTwoFactorCode(timeout: twoFactorTimeout)
                    if code == nil { twoFactorAbandoned = true }
                    codeCompletion(code)
                }
              }
            : nil

        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.sharedAPI.authenticate(
                appleID: email,
                password: password,
                anisetteData: anisette,
                verificationHandler: verificationHandler,
                completionHandler: { [weak self] account, session, error in
                    // If Apple's auth finished while we were still waiting on the user's 2FA code,
                    // drain that pending continuation so it can't hang the flow (or later leak + crash).
                    Task { @MainActor in
                        if !(self?.codeContinuations.isEmpty ?? true) { self?.submitTwoFactorCode(nil) }
                    }
                    if let account, let session {
                        continuation.resume(returning: (account, session))
                    } else if twoFactorTimeout != nil && twoFactorAbandoned {
                        continuation.resume(throwing: SignError.twoFactorTimedOut)
                    } else {
                        continuation.resume(throwing: error ?? NSError(
                            domain: "Wander", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unknown sign-in error"]))
                    }
                }
            )
        }
    }

    /// Validate a cached token with one cheap authenticated call (listTeams). The request is
    /// gated only by the session, so a minimal reconstructed account is enough. Adopts the
    /// session and returns true if it still works.
    private func adoptCachedSession(email: String, dsid: String, authToken: String) async -> Bool {
        do {
            let anisette = try await WanderAnisette.fetch()
            let sess = ALTAppleAPISession(dsid: dsid, authToken: authToken, anisetteData: anisette)
            let acct = ALTAccount()
            acct.appleID = email
            acct.identifier = dsid

            let valid: Bool = try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.sharedAPI.fetchTeams(for: acct, session: sess) { teams, error in
                    if teams != nil {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: "Wander", code: -2))
                    }
                }
            }
            guard valid else { return false }

            account = acct
            session = sess
            isSignedIn = true
            return true
        } catch {
            return false
        }
    }
}
