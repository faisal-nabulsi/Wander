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

@MainActor
final class WanderAccount: ObservableObject {
    static let shared = WanderAccount()

    @Published var status: String = ""
    @Published private(set) var isSignedIn = false
    @Published var awaiting2FA = false

    private(set) var account: ALTAccount?
    private(set) var session: ALTAppleAPISession?

    private var codeContinuation: CheckedContinuation<String?, Never>?

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
    /// reuse the live session → reuse a cached token (no prompt) → silent password re-auth →
    /// interactive password + 2FA. Throws `SignError.notSignedIn` if no credentials are stored.
    func ensureAuthenticated() async throws -> (ALTAccount, ALTAppleAPISession) {
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

        // Token gone/expired → full re-auth (interactive 2FA allowed since this is user-initiated).
        WanderCredentialStore.clearSessionCache()
        let (acct, sess) = try await performAuthenticate(email: creds.email, password: creds.password, allowInteractive2FA: true)
        adopt(account: acct, session: sess, email: creds.email, password: creds.password)
        return (acct, sess)
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

    private func requestTwoFactorCode() async -> String? {
        await withCheckedContinuation { continuation in
            self.codeContinuation = continuation
            self.awaiting2FA = true
        }
    }

    /// Called by the UI with the entered 6-digit code (or nil to cancel).
    func submitTwoFactorCode(_ code: String?) {
        awaiting2FA = false
        let continuation = codeContinuation
        codeContinuation = nil
        continuation?.resume(returning: code)
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
    }

    /// One `authenticate` call. `allowInteractive2FA == false` passes a nil verificationHandler,
    /// so AltSign fails fast with `.requiresTwoFactorAuthentication` instead of blocking.
    private func performAuthenticate(email: String, password: String, allowInteractive2FA: Bool) async throws -> (ALTAccount, ALTAppleAPISession) {
        let anisette = try await WanderAnisette.fetch()
        if allowInteractive2FA { status = "Contacting Apple…" }

        let verificationHandler: ((@escaping (String?) -> Void) -> Void)? = allowInteractive2FA
            ? { [weak self] codeCompletion in
                Task { @MainActor in
                    let code = await self?.requestTwoFactorCode()
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
                completionHandler: { account, session, error in
                    if let account, let session {
                        continuation.resume(returning: (account, session))
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
