//
//  WanderProAccount.swift
//  Wander
//
//  OPTIONAL account-based Pro unlock — the same Wander account model the website and the
//  Android app already use (Firebase Auth + a `licenses/{uid}` doc in Firestore). This is a
//  SECOND, ADDITIVE way to be Pro: effective Pro = (offline Ed25519 key valid, see License)
//  OR (this signed-in account has plan == "pro"). It never removes or weakens the offline-key
//  path — either alone unlocks.
//
//  NOTE ON NAMING: the name `WanderAccount` is already taken by the AltSign Apple-ID service
//  used for self-refresh, so this Firebase account service is `WanderProAccount` to avoid a
//  symbol collision. Gates read `License.shared.isLicensed`, which this service folds into via
//  `License.shared.refresh()` whenever `isPro` changes — so no gate needs to know this exists.
//
//  Plain URLSession REST against the Firebase REST APIs — deliberately NO Firebase SDK / SPM
//  dependency, so the Xcode project builds unchanged. Only the PUBLIC web apiKey is embedded.
//
//  Persistence: uid, email, refreshToken, the last-known isPro flag and `proVerifiedAt` (when a
//  server read last said Pro) live in the Keychain (via WanderKeychain), so account-Pro survives
//  relaunch AND delete/reinstall (iOS keeps Keychain items across app deletion).
//
//  Entitlement rule (same as the Worker, Android and desktop):
//    Pro = (plan == "pro" OR lifetime == true) AND NOT (source == "comp" AND expiresAt has passed),
//  ORed across licenses/{uid} and licenses/{lowercased email}; the email doc counts only when the
//  account's email is verified (Firestore rules refuse it otherwise).
//
//  Cache policy:
//    • Re-verified on launch and on every return to the foreground, at most once per 6 hours after
//      a read that got an answer (a read that couldn't complete is retried on a later foreground).
//    • A read that SUCCEEDS and says not-Pro (including "no such document" on every doc) drops
//      Pro at once.
//    • A read that can't complete (offline, transport error, auth hiccup) keeps the cached Pro only
//      while `proVerifiedAt` is under 7 days old. After that the app is free until a read succeeds,
//      so a revoked or expired licence can't live on forever in an offline cache.
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

@MainActor
final class WanderProAccount: ObservableObject {
    static let shared = WanderProAccount()

    // PUBLIC Firebase web config (safe to ship — never a private key).
    private static let apiKey = "AIzaSyDm9w7mIq0AinaCAj1mDGPqxpkyfkxHCEs"
    private static let projectId = "wanderspoofer"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var email: String? = nil

    /// A short human-readable status the sign-in UI can surface (mirrors WanderAccount's style).
    @Published var status: String = ""

    /// True when accounts:signInWithPassword returned an MFA challenge instead of a session
    /// (the account has TOTP 2FA enrolled). The sign-in UI observes this to present the
    /// "Two-factor code" prompt; it flips back to false once the challenge is finalized,
    /// cancelled, or a fresh sign-in attempt starts.
    @Published var mfaRequired: Bool = false

    // The in-flight TOTP challenge handed back by signInWithPassword. `mfaPendingCredential` is a
    // short-lived server credential that, together with the enrollment id and the user's current
    // 6-digit code, is redeemed at mfaSignIn:finalize for a real session. `mfaEmail` is carried so
    // the finalized session adopts the same account email the sign-in used.
    private var mfaPendingCredential: String?
    private var mfaEnrollmentId: String?
    private var mfaEmail: String?

    // In-memory session tokens. The refreshToken is long-lived and persisted; the idToken is
    // short-lived (≈1h) and re-minted from the refreshToken as needed.
    private var idToken: String?
    private var refreshToken: String?
    private var uid: String?

    /// Bumped on every sign-out (and account delete). A background refresh/entitlement task started
    /// under an old generation checks this before persisting or applying its result — so a token
    /// refresh whose network call was in flight when the user signed out can't resurrect the cleared
    /// session (re-persisting uid/refresh) or silently re-enable Pro after sign-out.
    private var sessionGeneration = 0

    /// When a server read last confirmed Pro. Mirrors the Keychain copy; nil whenever isPro is false.
    private var proVerifiedAt: Date?
    /// When an entitlement read last came back with a real answer (Pro OR not-Pro). Drives the
    /// 6-hour foreground throttle. In memory only: every cold launch re-checks anyway.
    private var lastConclusiveReadAt: Date?
    /// When the last entitlement re-check STARTED (launch, sign-in, or foreground). Only spaces out
    /// retries after a check that couldn't complete.
    private var lastVerifyAttemptAt: Date?
    /// True while a launch/foreground re-check is running, so overlapping triggers don't stack.
    private var verifyInFlight = false

    /// Foreground re-checks happen at most this often after a check that got an answer.
    private static let reverifyInterval: TimeInterval = 6 * 60 * 60
    /// After a check that could NOT complete (offline, server error), the next foreground retries,
    /// but no sooner than this — so a paying user whose offline grace ran out gets Pro back as soon
    /// as they're online, without a token request on every app switch while offline.
    private static let retryAfterFailureInterval: TimeInterval = 5 * 60
    /// How long a cached Pro survives reads that can't complete (offline / errors).
    private static let offlineGrace: TimeInterval = 7 * 24 * 60 * 60

    private enum Key {
        static let uid = "wander.account.uid"
        static let email = "wander.account.email"
        static let refresh = "wander.account.refreshToken"
        static let isPro = "wander.account.isPro"
        static let proVerifiedAt = "wander.account.proVerifiedAt"
    }

    private init() {
        restore()
    }

    // MARK: - Public state

    var isSignedIn: Bool { refreshToken != nil }

    /// The signed-in account's uid as persisted, readable WITHOUT touching `shared`.
    /// WanderDeviceActivation binds its cached device-cap verdict to it, and that class's init can
    /// run inside License's init chain, where touching `shared` here could re-enter a `static let`.
    static var persistedUID: String? {
        guard let value = WanderKeychain.string(Key.uid), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Sign in / Sign up (Identity Toolkit REST)

    /// POST accounts:signInWithPassword — verifies an existing account. On success we persist
    /// the session and immediately read the Firestore entitlement so Pro reflects right away.
    func signIn(email: String, password: String) async {
        await authenticate(endpoint: "accounts:signInWithPassword", email: email, password: password)
    }

    /// POST accounts:signUp — creates a new account (same request/response shape as sign-in).
    func signUp(email: String, password: String) async {
        await authenticate(endpoint: "accounts:signUp", email: email, password: password)
    }

    private func authenticate(endpoint: String, email rawEmail: String, password: String) async {
        let mail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mail.isEmpty, !password.isEmpty else {
            status = "Enter your email and password."
            return
        }

        // A fresh sign-in attempt supersedes any half-finished 2FA challenge.
        clearMfaChallenge()

        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/\(endpoint)?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "email": mail,
            "password": password,
            "returnSecureToken": true,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                status = "❌ \(Self.authErrorMessage(obj))"
                return
            }

            // A 2FA-enrolled account returns NO idToken; instead the response carries a
            // short-lived `mfaPendingCredential` plus an `mfaInfo` array of the enrolled
            // second factors. Detect that, stash the challenge, and let the UI collect the
            // 6-digit code (redeemed in submitMfaCode). Only the email/password path can hit
            // this — the federated web bridge finalizes 2FA inside the web page.
            if obj?["idToken"] == nil,
               let pending = obj?["mfaPendingCredential"] as? String, !pending.isEmpty,
               let mfaInfo = obj?["mfaInfo"] as? [[String: Any]],
               let enrollmentId = mfaInfo.first?["mfaEnrollmentId"] as? String, !enrollmentId.isEmpty {
                mfaPendingCredential = pending
                mfaEnrollmentId = enrollmentId
                mfaEmail = (obj?["email"] as? String) ?? mail
                status = "Enter your two-factor code."
                mfaRequired = true
                return
            }

            guard let idToken = obj?["idToken"] as? String,
                  let refreshToken = obj?["refreshToken"] as? String,
                  let localId = obj?["localId"] as? String else {
                status = "❌ Sign-in failed. Please try again."
                return
            }
            let acctEmail = (obj?["email"] as? String) ?? mail

            await adopt(idToken: idToken, refreshToken: refreshToken, email: acctEmail, uid: localId)
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    /// POST accounts:sendOobCode with requestType PASSWORD_RESET — asks Firebase to email a reset
    /// link to `email`. Reuses the same public web apiKey as sign-in. Returns true on HTTP 200 and
    /// sets a friendly confirmation in `status`; on failure it sets a readable error and returns false.
    func sendPasswordReset(email rawEmail: String) async -> Bool {
        let mail = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mail.isEmpty else {
            status = "Enter your email first."
            return false
        }

        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "requestType": "PASSWORD_RESET",
            "email": mail,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                status = "Check your inbox for a reset link."
                return true
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            status = "❌ \(Self.authErrorMessage(obj))"
            return false
        } catch {
            status = "❌ \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Two-factor (TOTP) sign-in challenge

    /// Finalize a TOTP 2FA sign-in with the user's current 6-digit authenticator code. Called only
    /// while `mfaRequired` is true (a pending challenge from signInWithPassword is stashed). POSTs
    /// to the v2 mfaSignIn:finalize endpoint; on success it hands the returned idToken/refreshToken
    /// into the SAME adopt(...) path the normal password sign-in uses, so the resulting signed-in /
    /// Pro state is identical. On INVALID_TOTP (or any other error) it sets a friendly status and
    /// KEEPS the challenge open so the user can retype the code.
    func submitMfaCode(_ rawCode: String) async {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pending = mfaPendingCredential, let enrollmentId = mfaEnrollmentId else {
            // No challenge in flight (already finalized/cancelled) — nothing to do.
            status = "❌ Your sign-in session expired. Please sign in again."
            mfaRequired = false
            return
        }
        guard !code.isEmpty else {
            status = "Enter your six-digit code."
            return
        }

        let url = URL(string: "https://identitytoolkit.googleapis.com/v2/accounts/mfaSignIn:finalize?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "mfaPendingCredential": pending,
            "mfaEnrollmentId": enrollmentId,
            "totpVerificationInfo": ["verificationCode": code],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // Keep the challenge open so the user can retry with a fresh code.
                status = "❌ \(Self.mfaErrorMessage(obj))"
                return
            }
            guard let idToken = obj?["idToken"] as? String,
                  let refreshToken = obj?["refreshToken"] as? String else {
                status = "❌ Two-factor verification failed. Please try again."
                return
            }
            // localId/email may be absent on the finalize response — fall back to the sign-in email
            // and the uid embedded in the idToken so adopt(...) still gets a real user id.
            let acctEmail = (obj?["email"] as? String) ?? mfaEmail ?? ""
            let localId = (obj?["localId"] as? String) ?? Self.uid(fromIdToken: idToken) ?? ""

            clearMfaChallenge()
            await adopt(idToken: idToken, refreshToken: refreshToken, email: acctEmail, uid: localId)
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    /// Abandon an in-flight 2FA challenge (user tapped Cancel on the code prompt). Drops the pending
    /// credential and lowers `mfaRequired` without signing in.
    func cancelMfa() {
        clearMfaChallenge()
        status = ""
    }

    /// Drop any stashed TOTP challenge and lower the `mfaRequired` flag.
    private func clearMfaChallenge() {
        mfaPendingCredential = nil
        mfaEnrollmentId = nil
        mfaEmail = nil
        if mfaRequired { mfaRequired = false }
    }

    /// Store a freshly-minted session (idToken + refreshToken + email + uid) and fold it into the
    /// signed-in / Pro state EXACTLY the way the email/password flow does. Shared by the email
    /// path and the Google web-bridge path so both yield an identical signed-in state:
    ///   persist to Keychain → read the Firestore entitlement → register this device → set status.
    private func adopt(idToken: String, refreshToken: String, email: String, uid: String) async {
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.uid = uid
        self.email = email
        persistSession()
        // A new session starts its own re-check clock (never inherits a previous account's).
        lastConclusiveReadAt = nil

        // Read entitlement now so the UI can dismiss straight into a Pro state.
        await fetchEntitlement()
        // Register THIS device against the account's 5-device cap (server-enforced). This is
        // fully fail-safe: on any error it leaves the cached state and never locks the user
        // out. Effective Pro = account plan pro AND this device registered (within the cap).
        await WanderDeviceActivation.shared.activate()
        if isPro {
            status = "✅ Signed in — Wander Pro unlocked."
        } else {
            status = "Signed in. This account isn't Pro yet."
        }
    }

    // MARK: - Continue with Google / Apple (config-free web bridge)

    /// Sign in via the website's already-working federated OAuth, no provider SDK and no new iOS
    /// OAuth client (or Apple entitlement) required. We open
    /// https://wanderspoofer.com/app-login/?provider=<provider> inside an ASWebAuthenticationSession;
    /// that page runs Firebase `signInWithRedirect` for the requested provider, then redirects to
    /// `wander-auth://callback#idToken=…&refreshToken=…&email=…&uid=…` (or `#error=…`). We parse the
    /// fragment and ADOPT the tokens through the same path the email flow uses, so the resulting
    /// signed-in / Pro state is identical — regardless of which provider was used.
    ///
    /// Apple sign-in deliberately rides this SAME web flow (Firebase `apple.com` provider) rather
    /// than native `ASAuthorizationAppleIDProvider`, which would require the "Sign in with Apple"
    /// capability/entitlement — the free-Apple-ID sideload path strips exactly that kind of
    /// entitlement, so the web bridge is the only route that survives an unsigned install.
    private static func loginURL(provider: String) -> URL {
        // Percent-encode the provider for a query VALUE (drop &, =, +, ? from urlQueryAllowed so a
        // value can never break out of the query component). Providers are simple ("google"/"apple").
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/")
        let p = provider.addingPercentEncoding(withAllowedCharacters: allowed) ?? provider
        return URL(string: "https://wanderspoofer.com/app-login/?provider=\(p)")!
    }
    private static let callbackScheme = "wander-auth"

    // Kept alive for the lifetime of the session so it isn't deallocated mid-flow.
    private var webAuthSession: ASWebAuthenticationSession?
    private let presentationContext = WebAuthPresentationContext()

    /// Continue with Apple via the web bridge (Firebase `apple.com`), no native entitlement.
    /// (Google uses the NATIVE OAuth 2.0 + PKCE flow below — see `signInWithGoogle()` — because the
    /// web `signInWithRedirect` can't complete inside an in-app browser.)
    func signInWithApple() async { await signIn(provider: "apple") }

    /// Shared federated web-bridge sign-in for any provider the /app-login/ page supports
    /// ("google", "apple", …). Opens the page for `provider`, waits for the `wander-auth://` callback,
    /// then adopts the handed-off tokens exactly like the email flow.
    private func signIn(provider: String) async {
        status = ""

        // Bridge the callback (delegate-style completion) into async/await.
        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: Self.loginURL(provider: provider),
                    callbackURLScheme: Self.callbackScheme
                ) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin))
                    }
                }
                session.presentationContextProvider = self.presentationContext
                // Non-ephemeral by necessity: signInWithRedirect stores state before bouncing to
                // Google and reads it back via getRedirectResult, which an ephemeral session would
                // wipe. Account freshness is enforced web-side instead — the /app-login/ page forces
                // Google's account chooser (prompt=select_account) and only hands off an EXPLICIT
                // sign-in (getRedirectResult), never a passively-restored session.
                session.prefersEphemeralWebBrowserSession = false
                self.webAuthSession = session
                if !session.start() {
                    continuation.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
        } catch {
            webAuthSession = nil
            // User dismissed the sheet / cancelled: stay quiet, don't nag with an error banner.
            if let asError = error as? ASWebAuthenticationSessionError,
               asError.code == .canceledLogin {
                return
            }
            status = "❌ \(error.localizedDescription)"
            return
        }
        webAuthSession = nil

        // Parse the URL fragment (after '#') for the handed-off tokens or an error.
        let params = Self.fragmentParams(callbackURL)
        if let message = params["error"], !message.isEmpty {
            status = "❌ \(message)"
            return
        }
        guard let idToken = params["idToken"], !idToken.isEmpty,
              let refreshToken = params["refreshToken"], !refreshToken.isEmpty,
              let uid = params["uid"], !uid.isEmpty else {
            status = "❌ Sign-in didn't return a usable session. Please try again."
            return
        }
        let acctEmail = params["email"] ?? ""

        // Adopt exactly like the email flow → identical signed-in + Pro state.
        await adopt(idToken: idToken, refreshToken: refreshToken, email: acctEmail, uid: uid)
    }

    /// Decode the `#a=b&c=d` fragment of the callback URL into a dictionary, percent-decoding
    /// each value (tokens are URLSearchParams-encoded on the web side).
    private static func fragmentParams(_ url: URL) -> [String: String] {
        // Read the STILL-ENCODED fragment: `.fragment` is already percent-decoded, so decoding it
        // again below (below) would corrupt any value containing %2F/%2B/%3D (refresh tokens, +emails).
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              !fragment.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first else { continue }
            let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
            let rawVal = kv.count > 1 ? String(kv[1]) : ""
            // URLSearchParams encodes spaces as '+'; restore them before percent-decoding.
            let val = rawVal.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? rawVal
            out[key] = val
        }
        return out
    }

    // MARK: - Continue with Google (NATIVE OAuth 2.0 + PKCE — no in-app-browser redirect fragility)

    /// The iOS OAuth 2.0 client id (Google Cloud → Credentials → "iOS", bundle id com.stik.stikdebug).
    /// PUBLIC by design: iOS OAuth clients carry NO secret and are hardened with PKCE, so shipping the
    /// id is safe. Its "reversed client id" is registered as a CFBundleURLScheme in Info.plist so the
    /// ASWebAuthenticationSession redirect reaches the app.
    private static let googleIOSClientID = "537670730528-0u5m7ult24ka4rfjr60eh99mu7j0raiv.apps.googleusercontent.com"

    /// The reversed-client-id custom URL scheme Google redirects back to
    /// (com.googleusercontent.apps.<id-minus-.apps.googleusercontent.com>). MUST also be listed in
    /// Info.plist's CFBundleURLSchemes or the redirect never returns to the app.
    private static var googleRedirectScheme: String {
        "com.googleusercontent.apps." +
            googleIOSClientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }
    /// Full redirect URI handed to Google (scheme + a fixed, arbitrary path). Google matches on the
    /// scheme; ASWebAuthenticationSession matches on the scheme too.
    private static var googleRedirectURI: String { "\(googleRedirectScheme):/oauth2redirect" }

    /// Continue with Google — native OAuth 2.0 Authorization Code flow with PKCE.
    ///
    /// Opens Google's consent page DIRECTLY in ASWebAuthenticationSession (not Firebase's web
    /// `signInWithRedirect`, whose cross-origin handshake can't survive an in-app browser's storage
    /// partitioning — that was the "pick account → back to chooser → never continues" loop). We get an
    /// authorization `code`, exchange it for a Google `id_token` (PKCE, no client secret), then trade
    /// that id_token for a Firebase session via accounts:signInWithIdp — landing in the SAME adopt(...)
    /// path as email sign-in, so the signed-in / Pro state is identical. 2FA accounts are handled.
    func signInWithGoogle() async {
        status = ""
        clearMfaChallenge()

        guard !Self.googleIOSClientID.hasPrefix("__"), !Self.googleIOSClientID.isEmpty else {
            status = "❌ Google sign-in isn't configured in this build."
            return
        }

        // PKCE: a random verifier + its S256 challenge, plus state/nonce for CSRF + replay safety.
        let verifier = Self.randomURLSafe(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(byteCount: 16)
        let nonce = Self.randomURLSafe(byteCount: 16)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: Self.googleIOSClientID),
            .init(name: "redirect_uri", value: Self.googleRedirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "prompt", value: "select_account"),
        ]
        guard let authURL = comps.url else { status = "❌ Couldn't start Google sign-in."; return }

        // Present Google's consent page; await the reversed-client-id redirect.
        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: Self.googleRedirectScheme
                ) { url, error in
                    if let error { cont.resume(throwing: error) }
                    else if let url { cont.resume(returning: url) }
                    else { cont.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin)) }
                }
                session.presentationContextProvider = self.presentationContext
                // Unlike signInWithRedirect this flow keeps NO state in browser storage across the
                // redirect (the code + verifier live in app memory), so an ephemeral-or-not session
                // doesn't matter for correctness; non-ephemeral just avoids re-typing the Google pw.
                session.prefersEphemeralWebBrowserSession = false
                self.webAuthSession = session
                if !session.start() { cont.resume(throwing: ASWebAuthenticationSessionError(.canceledLogin)) }
            }
        } catch {
            webAuthSession = nil
            // User dismissed the sheet / cancelled: stay quiet, don't nag with an error banner.
            if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin { return }
            status = "❌ \(error.localizedDescription)"
            return
        }
        webAuthSession = nil

        // Parse the redirect's QUERY (?code=…&state=… or ?error=…).
        let params = Self.queryParams(callbackURL)
        if let err = params["error"], !err.isEmpty {
            // access_denied = user tapped "cancel" on Google's consent → stay silent.
            status = (err == "access_denied") ? "" : "❌ Google sign-in failed (\(err))."
            return
        }
        guard params["state"] == state else {
            status = "❌ Google sign-in couldn't be verified. Please try again."
            return
        }
        guard let code = params["code"], !code.isEmpty else {
            status = "❌ Google sign-in didn't return a code. Please try again."
            return
        }

        // Exchange the code for a Google id_token (PKCE; iOS clients have no secret).
        guard let googleIdToken = await Self.exchangeCodeForIdToken(code: code, verifier: verifier) else {
            status = "❌ Couldn't complete Google sign-in. Please try again."
            return
        }

        // Trade the Google id_token for a Firebase session (or a 2FA challenge).
        await finishFirebaseSignInWithGoogle(googleIdToken: googleIdToken)
    }

    /// POST oauth2.googleapis.com/token to swap the auth code for tokens; returns the `id_token`.
    private static func exchangeCodeForIdToken(code: String, verifier: String) async -> String? {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id=\(formEncode(googleIOSClientID))",
            "code=\(formEncode(code))",
            "code_verifier=\(formEncode(verifier))",
            "grant_type=authorization_code",
            "redirect_uri=\(formEncode(googleRedirectURI))",
        ].joined(separator: "&")
        req.httpBody = form.data(using: .utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idToken = obj["id_token"] as? String, !idToken.isEmpty else {
                return nil
            }
            return idToken
        } catch {
            return nil
        }
    }

    /// POST accounts:signInWithIdp with the Google id_token → a Firebase session. Mirrors the
    /// email-path handling of a TOTP 2FA challenge, then adopt(...) exactly like every other path.
    private func finishFirebaseSignInWithGoogle(googleIdToken: String) async {
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "postBody": "id_token=\(googleIdToken)&providerId=google.com",
            "requestUri": "https://\(Self.projectId).firebaseapp.com",
            "returnSecureToken": true,
            "returnIdpCredential": true,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                status = "❌ \(Self.authErrorMessage(obj))"
                return
            }

            // A 2FA-enrolled account returns an MFA challenge instead of a session (same shape as the
            // password path). Stash it and let the UI collect the 6-digit code (redeemed in submitMfaCode).
            if obj?["idToken"] == nil,
               let pending = obj?["mfaPendingCredential"] as? String, !pending.isEmpty,
               let mfaInfo = obj?["mfaInfo"] as? [[String: Any]],
               let enrollmentId = mfaInfo.first?["mfaEnrollmentId"] as? String, !enrollmentId.isEmpty {
                mfaPendingCredential = pending
                mfaEnrollmentId = enrollmentId
                mfaEmail = obj?["email"] as? String
                status = "Enter your two-factor code."
                mfaRequired = true
                return
            }

            guard let idToken = obj?["idToken"] as? String,
                  let refreshToken = obj?["refreshToken"] as? String,
                  let localId = obj?["localId"] as? String else {
                status = "❌ Google sign-in failed. Please try again."
                return
            }
            let acctEmail = (obj?["email"] as? String) ?? ""
            await adopt(idToken: idToken, refreshToken: refreshToken, email: acctEmail, uid: localId)
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    /// Decode the `?a=b&c=d` QUERY of a redirect URL into a dictionary (values percent-decoded).
    private static func queryParams(_ url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        var out: [String: String] = [:]
        for item in items { out[item.name] = item.value ?? "" }
        return out
    }

    /// A random URL-safe (base64url, unpadded) string over `byteCount` cryptographically-secure
    /// bytes (Swift's SystemRandomNumberGenerator is a CSPRNG on Apple platforms). Backs the PKCE
    /// code_verifier, the state, and the nonce.
    private static func randomURLSafe(byteCount: Int) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    /// base64url without padding (PKCE challenge/verifier + random tokens).
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Refresh the id token (Secure Token REST)

    /// POST securetoken.googleapis.com/v1/token with grant_type=refresh_token to mint a fresh
    /// idToken from the stored refreshToken. Google may also rotate the refreshToken here.
    /// Returns true if we now hold a usable idToken.
    @discardableResult
    func refreshIfNeeded() async -> Bool {
        guard let refreshToken else { return false }
        let gen = sessionGeneration

        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=refresh_token&refresh_token=\(Self.formEncode(refreshToken))"
        req.httpBody = form.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            // If the user signed out (or the session otherwise changed) while this call was in flight,
            // discard the result — applying it would re-persist the just-cleared uid/refresh token and
            // resurrect the signed-out session. (#19)
            guard sessionGeneration == gen else { return false }
            guard let http = response as? HTTPURLResponse else { return false }

            // A 400 from securetoken means the refresh token itself is permanently dead — revoked,
            // the account was disabled, the password changed, or long inactivity. This is NOT a
            // transient hiccup (those throw or 5xx), so the cached Pro flag should no longer be
            // trusted indefinitely: sign out so the user re-authenticates, which re-reads their
            // entitlement from scratch (a still-paid user gets Pro right back). (#34)
            if http.statusCode == 400 {
                signOut()
                return false
            }
            guard http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return false   // 5xx / unparseable → transient; keep the session (Pro rides the 7-day grace).
            }
            // Secure-token responses are snake_case.
            if let newId = obj["id_token"] as? String { self.idToken = newId }
            if let newRefresh = obj["refresh_token"] as? String {
                self.refreshToken = newRefresh
            }
            if let uid = obj["user_id"] as? String { self.uid = uid }
            persistSession()
            return self.idToken != nil
        } catch {
            return false   // transport error → transient; cached Pro rides the 7-day offline grace.
        }
    }

    // MARK: - Entitlement (Firestore REST)

    /// GET licenses/{uid} and, when the account's email is verified, licenses/{lowercased email}.
    /// Any doc that grants Pro → Pro (and stamps proVerifiedAt). Every doc read SUCCEEDED and none
    /// grants Pro (a "not found" counts as a successful not-Pro answer) → Pro drops at once. Any
    /// read could not complete and none granted Pro → inconclusive: the cached Pro stays only
    /// inside the 7-day offline grace.
    func fetchEntitlement() async {
        let gen = sessionGeneration
        lastVerifyAttemptAt = Date()

        // Ensure a usable idToken. If we hold none, mint one from the refresh token.
        if idToken == nil {
            guard await refreshIfNeeded(), sessionGeneration == gen else {
                if sessionGeneration == gen { expireStaleCacheIfNeeded() }
                return
            }
        }

        let claims = idToken.flatMap { Self.claims(fromIdToken: $0) }
        let uidKey = nonEmpty(uid)
        // The email doc only counts for a VERIFIED email (Firestore rules refuse it otherwise, and
        // the Worker ignores it). If the token can't be decoded at all we still try the read and
        // let the rules decide; a refusal then counts as an inconclusive read, never a downgrade.
        let emailVerified: Bool? = claims.map { ($0["email_verified"] as? Bool) == true }
        // Prefer the token's own email: it is what the Firestore rule compares the doc id against.
        let rawEmail = nonEmpty(claims?["email"] as? String) ?? nonEmpty(email)
        let emailKey: String? = (emailVerified == false)
            ? nil
            : nonEmpty(rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())

        guard uidKey != nil || emailKey != nil else {
            // Nothing we can read (no uid and no verified email): no answer either way.
            expireStaleCacheIfNeeded()
            return
        }

        var anyReadFailed = false
        for docId in [uidKey, emailKey == uidKey ? nil : emailKey].compactMap({ $0 }) {
            let result = await readLicense(docId: docId)
            // Signed out (or re-signed-in) while the read was in flight: never apply a stale answer.
            guard sessionGeneration == gen else { return }
            switch result {
            case .pro:
                lastConclusiveReadAt = Date()
                setPro(true)
                return
            case .notPro, .notFound:
                continue
            case .failed, .unauthorized:
                anyReadFailed = true
            }
        }

        if anyReadFailed {
            expireStaleCacheIfNeeded()
        } else {
            lastConclusiveReadAt = Date()
            setPro(false)
        }
    }

    /// The outcome of reading one `licenses/{docId}` document.
    private enum LicenseRead: Equatable {
        case pro            // 200, and the doc grants Pro
        case notPro         // 200, and the doc does not grant Pro (free, expired comp, no plan…)
        case notFound       // 404: no such doc (a successful "not Pro" answer for this key)
        case unauthorized   // 401: the idToken expired
        case failed         // transport error, 403/5xx, or an unreadable body: no answer
    }

    /// Read one license doc, minting a fresh idToken and retrying ONCE if the first try 401s (the
    /// short-lived token can expire between a launch and a later foreground re-check).
    private func readLicense(docId: String) async -> LicenseRead {
        let first = await readLicenseDoc(docId: docId)
        guard first == .unauthorized else { return first }
        let gen = sessionGeneration
        guard await refreshIfNeeded(), sessionGeneration == gen else { return .failed }
        let second = await readLicenseDoc(docId: docId)
        return second == .unauthorized ? .failed : second
    }

    /// Read one Firestore document `licenses/{docId}` and classify the answer.
    private func readLicenseDoc(docId: String) async -> LicenseRead {
        guard let idToken else { return .failed }
        let path = "projects/\(Self.projectId)/databases/(default)/documents/licenses/\(Self.pathEncode(docId))"
        guard let url = URL(string: "https://firestore.googleapis.com/v1/\(path)") else { return .failed }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200: break
            case 404: return .notFound
            case 401: return .unauthorized
            default: return .failed
            }
            // Firestore document shape: { "fields": { "plan": { "stringValue": "pro" }, ... } }
            // A body that isn't JSON at all is not an answer (keep the cache under the grace rule);
            // a real document with no fields / no plan is a definitive "not Pro".
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failed
            }
            let fields = (obj["fields"] as? [String: Any]) ?? [:]
            return Self.licenseGrantsPro(fields: fields, now: Date()) ? .pro : .notPro
        } catch {
            return .failed
        }
    }

    /// The shared entitlement rule over one Firestore document's `fields`:
    ///   (plan == "pro" OR lifetime == true) AND NOT (source == "comp" AND expiresAt has passed).
    /// A comp whose expiresAt is missing or unreadable is treated as not expired.
    private static func licenseGrantsPro(fields: [String: Any], now: Date) -> Bool {
        let plan = (fields["plan"] as? [String: Any])?["stringValue"] as? String
        let lifetime = ((fields["lifetime"] as? [String: Any])?["booleanValue"] as? Bool) == true
        guard plan == "pro" || lifetime else { return false }

        let source = (fields["source"] as? [String: Any])?["stringValue"] as? String
        if source == "comp",
           let expiresAt = firestoreDate(fields["expiresAt"]),
           expiresAt <= now {
            return false
        }
        return true
    }

    /// Decode a Firestore REST value into a Date. Accepts a timestampValue (RFC 3339), a
    /// stringValue (RFC 3339 date-time or a bare YYYY-MM-DD, read as midnight UTC), or an
    /// integerValue/doubleValue of Unix seconds (milliseconds when the number is that large).
    private static func firestoreDate(_ value: Any?) -> Date? {
        guard let v = value as? [String: Any] else { return nil }
        if let s = (v["timestampValue"] as? String) ?? (v["stringValue"] as? String) {
            return parseISODate(s)
        }
        var number: Double?
        if let s = v["integerValue"] as? String { number = Double(s) }        // int64 travels as a string
        else if let n = v["integerValue"] as? NSNumber { number = n.doubleValue }
        else if let n = v["doubleValue"] as? NSNumber { number = n.doubleValue }
        guard let raw = number, raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
    }

    private static func parseISODate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Firestore emits 0, 3, 6 or 9 fractional digits; drop them so one formatter covers all.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: trimmed) { return d }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        if let d = dateOnly.date(from: trimmed) { return d }
        // A date-time with no zone: read as UTC, which is what the Worker's Date.parse does
        // (Workers run in UTC), so both sides expire the same comp at the same moment.
        let noZone = DateFormatter()
        noZone.locale = Locale(identifier: "en_US_POSIX")
        noZone.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            noZone.dateFormat = format
            if let d = noZone.date(from: trimmed) { return d }
        }
        return nil
    }

    // MARK: - Re-verification (launch + foreground) and the offline grace

    /// Call whenever the app becomes active. Applies the 7-day offline grace right away (no
    /// network needed), then re-reads the entitlement if the last read that got an answer is 6+
    /// hours old. A check that couldn't complete is retried on a later foreground (5+ min later).
    func handleForeground() {
        expireStaleCacheIfNeeded()
        guard isSignedIn, !verifyInFlight else { return }
        if Self.isRecent(lastConclusiveReadAt, within: Self.reverifyInterval) { return }
        if Self.isRecent(lastVerifyAttemptAt, within: Self.retryAfterFailureInterval) { return }
        reverify(registerDevice: false)
    }

    /// True when `date` is less than `interval` ago. A date in the future (the clock moved
    /// backwards) counts as not recent, so the check is treated as due.
    private static func isRecent(_ date: Date?, within interval: TimeInterval) -> Bool {
        guard let date else { return false }
        let elapsed = Date().timeIntervalSince(date)
        return elapsed >= 0 && elapsed < interval
    }

    /// Mint a fresh idToken, then read the entitlement. On launch this also re-registers the
    /// device, exactly as before. A token refresh that can't complete is an inconclusive read:
    /// the cached Pro survives only inside the offline grace.
    private func reverify(registerDevice: Bool) {
        guard isSignedIn, !verifyInFlight else { return }
        verifyInFlight = true
        lastVerifyAttemptAt = Date()
        // Capture the session generation so a sign-out during this async chain aborts it — a late
        // read must never re-enable Pro after the user signed out. (#19)
        let gen = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            defer { self.verifyInFlight = false }
            guard await self.refreshIfNeeded(), self.sessionGeneration == gen else {
                if self.sessionGeneration == gen { self.expireStaleCacheIfNeeded() }
                return
            }
            await self.fetchEntitlement()
            guard registerDevice, self.sessionGeneration == gen else { return }
            // Re-register this device on launch (while online). Fail-safe: never locks out.
            await WanderDeviceActivation.shared.activate()
        }
    }

    /// Drop a cached Pro that no server read has confirmed for 7 days.
    private func expireStaleCacheIfNeeded() {
        guard isPro else { return }
        if let verified = proVerifiedAt, Self.isWithinOfflineGrace(verified) { return }
        setPro(false)
    }

    private static func isWithinOfflineGrace(_ verifiedAt: Date) -> Bool {
        let age = Date().timeIntervalSince(verifiedAt)
        // A stamp more than a day in the future means the clock was wound back; don't trust it.
        return age > -24 * 60 * 60 && age < offlineGrace
    }

    // MARK: - Authenticated Firestore access (for opt-in features like place sync)

    /// The signed-in user's Firebase uid, or nil if not signed in. Sync uses this to scope
    /// its documents to `users/{uid}/savedPlaces`.
    var firebaseUID: String? { uid }

    /// The Firestore project id, so callers can build document paths against the same project
    /// this account authenticates with.
    var firestoreProjectId: String { Self.projectId }

    /// Perform an authenticated Firestore REST request, minting a fresh idToken first if needed.
    /// Returns the raw (data, HTTPURLResponse) on success, or nil on any auth/transport failure
    /// (so callers can fail-safe without crashing). `body`, when provided, is sent as JSON.
    ///
    /// This is the ONLY entry point sync uses to talk to Firestore — it reuses the same token
    /// machinery as the entitlement read and never exposes the raw token to callers.
    func firestoreRequest(method: String,
                          path: String,
                          query: String? = nil,
                          body: Data? = nil) async -> (Data, HTTPURLResponse)? {
        // Ensure we hold a usable idToken. A stale one would 401; refreshing first avoids that.
        if idToken == nil {
            guard await refreshIfNeeded() else { return nil }
        }
        guard let token = idToken else { return nil }

        var urlString = "https://firestore.googleapis.com/v1/\(path)"
        if let query, !query.isEmpty { urlString += "?\(query)" }
        guard let url = URL(string: urlString) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            // A 401 likely means the idToken expired mid-session; refresh once and retry.
            if http.statusCode == 401, await refreshIfNeeded(), let fresh = idToken {
                req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                guard let (d2, r2) = try? await URLSession.shared.data(for: req),
                      let http2 = r2 as? HTTPURLResponse else { return nil }
                return (d2, http2)
            }
            return (data, http)
        } catch {
            return nil
        }
    }

    // MARK: - Authenticated Worker access (for Pro features like AI routine)

    /// Return a usable Firebase idToken for the signed-in user, minting a fresh one from the
    /// refresh token if we don't currently hold one. Returns nil if not signed in / can't refresh.
    ///
    /// This is the ONLY way callers obtain the idToken to hand to Wander's Worker (e.g. the
    /// /ai/routine endpoint sends it in the JSON body, exactly like the trial endpoints do).
    /// It reuses the same token machinery as the entitlement read; the raw token is never cached
    /// by callers — they request a fresh one per call.
    func currentIdToken() async -> String? {
        if idToken == nil {
            guard await refreshIfNeeded() else { return nil }
        }
        return idToken
    }

    /// Mint a fresh idToken (used to retry a Worker call that came back 401 — the short-lived
    /// token likely expired mid-session). Returns the new token, or nil if the refresh failed.
    func refreshedIdToken() async -> String? {
        guard await refreshIfNeeded() else { return nil }
        return idToken
    }

    // MARK: - Sign out

    func signOut() {
        sessionGeneration &+= 1   // invalidate any in-flight background refresh/entitlement task (#19)
        clearMfaChallenge()
        idToken = nil
        refreshToken = nil
        uid = nil
        email = nil
        WanderKeychain.set(Key.uid, "")
        WanderKeychain.set(Key.email, "")
        WanderKeychain.set(Key.refresh, "")
        WanderKeychain.set(Key.isPro, "0")
        lastConclusiveReadAt = nil
        lastVerifyAttemptAt = nil
        status = "Signed out."
        // Clear this device's registration state so the next account starts fresh (effective Pro
        // already drops because the account is no longer Pro; this just tidies the device gate).
        WanderDeviceActivation.shared.reset()
        setPro(false)
    }

    // MARK: - Delete account (self-service erasure)

    /// Permanently delete this Wander account. Calls the Worker's admin-privileged
    /// `/account/delete`, which verifies the Firebase ID token, wipes the user's Firestore data
    /// (license, trial, AI usage, saved places) and deletes the Firebase Auth user — then clears all
    /// local session state (same as sign-out). Returns true once the server confirms the deletion.
    /// NOTE: this does NOT cancel an active paid subscription — the confirm dialog tells the user to
    /// cancel billing separately.
    @discardableResult
    func deleteAccount() async -> Bool {
        guard let token = await currentIdToken() else {
            status = "❌ Please sign in again, then try deleting."
            return false
        }
        status = "Deleting your account…"
        var outcome = await postWorker(path: "/account/delete", body: ["idToken": token])
        // The short-lived idToken can expire mid-flight → mint a fresh one and retry once, exactly
        // like WanderDeviceActivation / WanderAIRoutine do for the other /account Worker calls.
        if outcome.status == 401, let fresh = await refreshedIdToken() {
            outcome = await postWorker(path: "/account/delete", body: ["idToken": fresh])
        }
        guard let obj = outcome.json, (obj["ok"] as? Bool) == true else {
            status = "❌ Couldn't delete the account. Check your connection and try again."
            return false
        }
        signOut()                       // server account is gone → wipe the local session too
        status = "Your account was deleted."
        return true
    }

    /// Minimal authenticated POST to Wander's Worker (idToken travels in the JSON body, matching the
    /// existing `/account/*` contract used by WanderDeviceActivation).
    private static let workerBaseURL = "https://wander-payments.wanderlocation.workers.dev"
    private func postWorker(path: String, body: [String: Any]) async -> (json: [String: Any]?, status: Int) {
        guard let url = URL(string: "\(Self.workerBaseURL)\(path)"),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return (nil, -1) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (nil, -1) }
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any], http.statusCode)
        } catch { return (nil, -1) }
    }

    // MARK: - Restore on launch

    /// Load the cached session + Pro flag from the Keychain (synchronous, offline), then — if a
    /// session exists — kick off a background refresh + entitlement re-check. The cached isPro
    /// keeps Pro alive instantly on launch and through offline launches, but only while its
    /// last server confirmation is under 7 days old.
    func restore() {
        let cachedUid = nonEmpty(WanderKeychain.string(Key.uid))
        let cachedRefresh = nonEmpty(WanderKeychain.string(Key.refresh))
        let cachedEmail = nonEmpty(WanderKeychain.string(Key.email))
        var cachedPro = WanderKeychain.string(Key.isPro) == "1"
        var verifiedAt = Self.decodeDate(WanderKeychain.string(Key.proVerifiedAt))

        // A Pro cache written by a build that predates proVerifiedAt has no stamp. Start its 7-day
        // clock now (once), so a paying user who updates while offline isn't locked out.
        if cachedPro && verifiedAt == nil {
            let now = Date()
            verifiedAt = now
            WanderKeychain.set(Key.proVerifiedAt, Self.encodeDate(now))
        }
        // Offline grace used up: launch as free until a read succeeds. Written straight to the
        // Keychain (not via setPro) because this runs inside `init`, and setPro → License.shared
        // → WanderProAccount.shared would re-enter the singleton's initializer.
        if cachedPro, let stamp = verifiedAt, !Self.isWithinOfflineGrace(stamp) {
            cachedPro = false
            WanderKeychain.set(Key.isPro, "0")
            WanderKeychain.set(Key.proVerifiedAt, "")
        }

        uid = cachedUid
        refreshToken = cachedRefresh
        email = cachedEmail
        proVerifiedAt = cachedPro ? verifiedAt : nil
        if cachedPro { isPro = true }   // reflect cache immediately; don't publish false spuriously

        guard cachedRefresh != nil else { return }

        // Live re-check in the background (refresh token → entitlement → device registration).
        reverify(registerDevice: true)
    }

    // MARK: - Internals

    /// Single choke point for flipping Pro: publishes the flag, caches it, and asks License to
    /// recompute so the (key OR account) effective-Pro used by every gate stays in sync.
    /// `true` is only ever passed after a server read said Pro, so it also stamps proVerifiedAt.
    private func setPro(_ value: Bool) {
        if value {
            let now = Date()
            proVerifiedAt = now
            WanderKeychain.set(Key.proVerifiedAt, Self.encodeDate(now))
        } else {
            proVerifiedAt = nil
            WanderKeychain.set(Key.proVerifiedAt, "")
        }
        WanderKeychain.set(Key.isPro, value ? "1" : "0")
        if isPro != value { isPro = value }
        License.shared.refresh()
    }

    private static func encodeDate(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    private static func decodeDate(_ raw: String?) -> Date? {
        guard let raw, let seconds = Double(raw), seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func persistSession() {
        WanderKeychain.set(Key.uid, uid ?? "")
        WanderKeychain.set(Key.email, email ?? "")
        WanderKeychain.set(Key.refresh, refreshToken ?? "")
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Human-readable message for an Identity Toolkit error payload.
    private static func authErrorMessage(_ obj: [String: Any]?) -> String {
        let code = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
        switch code {
        case "EMAIL_NOT_FOUND", "INVALID_PASSWORD", "INVALID_LOGIN_CREDENTIALS":
            return "Wrong email or password."
        case "EMAIL_EXISTS":
            return "An account already exists for that email. Sign in instead."
        case "WEAK_PASSWORD : Password should be at least 6 characters":
            return "Password must be at least 6 characters."
        case "USER_DISABLED":
            return "This account has been disabled."
        case let c where c.hasPrefix("TOO_MANY_ATTEMPTS_TRY_LATER"):
            return "Too many attempts. Please try again later."
        case "":
            return "Sign-in failed. Please try again."
        default:
            return code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Human-readable message for an mfaSignIn:finalize error payload (mostly INVALID_TOTP).
    private static func mfaErrorMessage(_ obj: [String: Any]?) -> String {
        let code = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
        if code.isEmpty {
            return "Two-factor verification failed. Please try again."
        }
        if code.hasPrefix("INVALID_TOTP") {
            return "That code isn't right. Check your authenticator and try again."
        }
        if code.hasPrefix("SESSION_EXPIRED") || code.hasPrefix("MFA_PENDING_CREDENTIAL") {
            return "Your sign-in session expired. Please sign in again."
        }
        if code.hasPrefix("TOO_MANY_ATTEMPTS_TRY_LATER") {
            return "Too many attempts. Please try again later."
        }
        return code.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Extract the Firebase `user_id`/`sub` claim from an idToken's JWT payload (base64url middle
    /// segment). Used only as a fallback when mfaSignIn:finalize omits `localId`.
    private static func uid(fromIdToken token: String) -> String? {
        guard let claims = claims(fromIdToken: token) else { return nil }
        return (claims["user_id"] as? String) ?? (claims["sub"] as? String)
    }

    /// Decode an idToken's JWT payload (the base64url middle segment) into its claims. Read-only
    /// and unverified — used only to pick which license docs to read (`email_verified`, `email`);
    /// Firestore's rules still verify the token on every read.
    private static func claims(fromIdToken token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4 for Foundation's base64 decoder.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func pathEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

/// Supplies the anchor window ASWebAuthenticationSession presents its sheet from. We hand back the
/// app's active key window (falling back to any window / a fresh one) so the auth sheet always has
/// a valid presenter regardless of which scene is foregrounded.
@MainActor
private final class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        // Prefer the foreground key window; otherwise any window; otherwise a new one.
        if let keyWindow = scenes
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        if let anyWindow = scenes.flatMap({ $0.windows }).first {
            return anyWindow
        }
        return ASPresentationAnchor()
    }
}
