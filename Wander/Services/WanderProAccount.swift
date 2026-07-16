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
//  Persistence: uid, email, refreshToken, and the last-known isPro flag live in the Keychain
//  (via WanderKeychain), so account-Pro survives relaunch AND delete/reinstall (iOS keeps
//  Keychain items across app deletion). On a network error we KEEP the cached isPro — we never
//  downgrade a paying user because their Wi-Fi dropped; only an explicit non-pro read clears it.
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

    private enum Key {
        static let uid = "wander.account.uid"
        static let email = "wander.account.email"
        static let refresh = "wander.account.refreshToken"
        static let isPro = "wander.account.isPro"
    }

    private init() {
        restore()
    }

    // MARK: - Public state

    var isSignedIn: Bool { refreshToken != nil }

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

        let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(Self.apiKey)")!
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "grant_type=refresh_token&refresh_token=\(Self.formEncode(refreshToken))"
        req.httpBody = form.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return false
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
            return false
        }
    }

    // MARK: - Entitlement (Firestore REST)

    /// GET licenses/{uid}; if that isn't Pro, fall back to licenses/{lowercased-email}. Sets
    /// isPro only on a definitive read. On a network/transport error we KEEP the cached isPro
    /// (never downgrade a paid user offline) — only an explicit non-pro document clears it.
    func fetchEntitlement() async {
        // Ensure a usable idToken. If we hold none, mint one from the refresh token; a read with
        // a stale token would just 401 (inconclusive) and preserve the cache, but refreshing
        // first avoids that round-trip. Bail if we can't get a token at all (not signed in).
        if idToken == nil {
            guard await refreshIfNeeded() else { return }
        }

        // Primary lookup by uid.
        if let uid, let result = await readLicenseDoc(docId: uid) {
            if result {
                setPro(true)
                return
            }
            // Doc existed but wasn't pro — try the email-keyed doc before concluding non-pro.
            if let email = email?.lowercased(), let byEmail = await readLicenseDoc(docId: email) {
                setPro(byEmail)
                return
            }
            // No email fallback available / not found → the uid doc is authoritative: not pro.
            setPro(false)
            return
        }

        // No uid doc (missing, or the read errored). Try the email-keyed doc.
        if let email = email?.lowercased(), let byEmail = await readLicenseDoc(docId: email) {
            setPro(byEmail)
            return
        }
        // Everything we tried was inconclusive (network error / no docs). Leave cached isPro as-is.
    }

    /// Read one Firestore document `licenses/{docId}`.
    /// - Returns `true`/`false` when the document is readable (plan == "pro" or not),
    ///   or `nil` when the read was inconclusive (404 not-found, auth, or transport error) so
    ///   the caller can fall back / preserve the cache.
    private func readLicenseDoc(docId: String) async -> Bool? {
        guard let idToken else { return nil }
        let path = "projects/\(Self.projectId)/databases/(default)/documents/licenses/\(Self.pathEncode(docId))"
        guard let url = URL(string: "https://firestore.googleapis.com/v1/\(path)") else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                // 404 = no such license doc (a real "not this key"); anything else is a
                // transport/auth hiccup. Either way this specific doc didn't confirm Pro; return
                // nil so the caller can try the fallback / keep the cache rather than downgrade.
                return nil
            }
            // Firestore document shape: { "fields": { "plan": { "stringValue": "pro" }, ... } }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fields = obj["fields"] as? [String: Any],
                  let plan = fields["plan"] as? [String: Any],
                  let planValue = plan["stringValue"] as? String else {
                // Document exists but has no readable plan field → treat as not pro.
                return false
            }
            return planValue == "pro"
        } catch {
            return nil
        }
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
        clearMfaChallenge()
        idToken = nil
        refreshToken = nil
        uid = nil
        email = nil
        WanderKeychain.set(Key.uid, "")
        WanderKeychain.set(Key.email, "")
        WanderKeychain.set(Key.refresh, "")
        WanderKeychain.set(Key.isPro, "0")
        status = "Signed out."
        // Clear this device's registration state so the next account starts fresh (effective Pro
        // already drops because the account is no longer Pro; this just tidies the device gate).
        WanderDeviceActivation.shared.reset()
        setPro(false)
    }

    // MARK: - Restore on launch

    /// Load the cached session + Pro flag from the Keychain (synchronous, offline), then — if a
    /// session exists — kick off a background refresh + entitlement re-check. The cached isPro
    /// keeps Pro alive instantly on launch and through offline launches.
    func restore() {
        let cachedUid = nonEmpty(WanderKeychain.string(Key.uid))
        let cachedRefresh = nonEmpty(WanderKeychain.string(Key.refresh))
        let cachedEmail = nonEmpty(WanderKeychain.string(Key.email))
        let cachedPro = WanderKeychain.string(Key.isPro) == "1"

        uid = cachedUid
        refreshToken = cachedRefresh
        email = cachedEmail
        if cachedPro { isPro = true }   // reflect cache immediately; don't publish false spuriously

        guard cachedRefresh != nil else { return }

        // Live re-check in the background; failures preserve the cached state.
        Task { [weak self] in
            guard let self else { return }
            if await self.refreshIfNeeded() {
                await self.fetchEntitlement()
                // Re-register this device on launch (while online). Fail-safe: never locks out.
                await WanderDeviceActivation.shared.activate()
            }
        }
    }

    // MARK: - Internals

    /// Single choke point for flipping Pro: publishes the flag, caches it, and asks License to
    /// recompute so the (key OR account) effective-Pro used by every gate stays in sync.
    private func setPro(_ value: Bool) {
        WanderKeychain.set(Key.isPro, value ? "1" : "0")
        if isPro != value { isPro = value }
        License.shared.refresh()
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
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4 for Foundation's base64 decoder.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return (claims["user_id"] as? String) ?? (claims["sub"] as? String)
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
