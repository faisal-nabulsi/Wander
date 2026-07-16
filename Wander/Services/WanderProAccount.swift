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

    /// Continue with Google via the web bridge.
    func signInWithGoogle() async { await signIn(provider: "google") }

    /// Continue with Apple via the SAME web bridge (Firebase `apple.com`), no native entitlement.
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
