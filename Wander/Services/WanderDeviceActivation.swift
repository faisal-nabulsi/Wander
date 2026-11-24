//
//  WanderDeviceActivation.swift
//  Wander
//
//  DEVICE CAP (max 5 devices per Pro account, ENFORCED SERVER-SIDE). This is the iOS half of
//  the shared contract used by iOS + Android. Firestore stays client-read-only; ONLY Wander's
//  Worker (with an admin token) writes the `devices` map on `licenses/{uid}`, so the cap can't
//  be bypassed by a patched client.
//
//  Flow: on sign-in and on app launch WHILE ONLINE, POST /account/activate with this install's
//  stable deviceId (WanderDevice.id — a Keychain UUID that survives reinstall), the platform
//  ("ios"), and a friendly device name (the hardware model). The Worker replies with whether
//  THIS device is registered, whether the account is at the 5-device limit, and the full device
//  list. EFFECTIVE PRO on this device = (account plan is pro) AND (this device is registered).
//
//  FAIL-SAFE (critical): if the activate call FAILS (offline / timeout / transport error) we
//  KEEP the last cached verdict — we NEVER lock out a paying user because their Wi-Fi dropped.
//  The ONLY response that withholds Pro on this device is an explicit
//  `atLimit == true && registered == false` (a genuine "you're over 5 devices, this one isn't
//  one of them"). A Pro user already registered — or under the cap — is never blocked.
//
//  THE VERDICT IS PERSISTED (Keychain, per account uid). It used to be memory-only for `atLimit`,
//  so every relaunch started at "not at limit" and a 6th device that simply blocked the Worker's
//  host stayed Pro forever: the denial existed only until the next launch. Now the last answer the
//  Worker gave for THIS account on THIS device is what applies while the Worker can't be reached —
//  a denial stays a denial, a registration stays a registration. With NO stored answer (the Worker
//  has never replied for this account here) we still allow, and re-ask on every launch and every
//  foreground until it does. The verdict survives sign-out and reinstall on purpose: either would
//  otherwise be a one-tap way to forget a denial.
//
//  This mirrors EXACTLY how the app already reaches the Worker for the AI/trial flows
//  (WanderAIRoutine): base URL, Firebase idToken fetched from WanderProAccount + sent in the
//  JSON body, and a single 401 retry after minting a fresh token.
//

import Foundation
import UIKit

/// One device row as returned by the Worker's `devices` array.
struct WanderDeviceInfo: Identifiable, Equatable {
    let deviceId: String
    let platform: String
    let name: String
    /// Server-provided last-seen. May be a unix-seconds number or an ISO string; we keep the raw
    /// value and format it best-effort for display (never parsed for logic).
    let lastSeen: Double?

    var id: String { deviceId }

    /// True when this row is THE device the app is currently running on.
    var isThisDevice: Bool { deviceId == WanderDevice.id }

    /// A friendly relative last-seen string, or nil if the server didn't send one.
    var lastSeenText: String? {
        guard let lastSeen, lastSeen > 0 else { return nil }
        let date = Date(timeIntervalSince1970: lastSeen)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    /// A friendly platform label for display.
    var platformLabel: String {
        switch platform.lowercased() {
        case "ios":     return "iPhone / iPad"
        case "android": return "Android"
        case "mac":     return "Mac"
        case "windows": return "Windows"
        default:        return platform.capitalized
        }
    }
}

@MainActor
final class WanderDeviceActivation: ObservableObject {
    static let shared = WanderDeviceActivation()

    /// Same Worker base the AI/trial/pricing flows use.
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"
    private static let deviceLimit = 5

    /// Whether THIS device is registered against the account's device map. This is the value
    /// License folds into effective Pro. It starts from the cache so offline launches keep Pro.
    @Published private(set) var registered: Bool = false

    /// True only when the server said the account is already at its 5-device cap. Combined with
    /// `!registered`, this is the SOLE condition that withholds Pro on this device.
    @Published private(set) var atLimit: Bool = false

    /// The full device list from the last successful activate/remove (for the Manage Devices UI).
    @Published private(set) var devices: [WanderDeviceInfo] = []

    /// The account's device cap (echoed by the server; defaults to the contract's 5).
    @Published private(set) var limit: Int = WanderDeviceActivation.deviceLimit

    /// Set true while an activate/remove request is in flight (drives the Manage Devices spinner).
    @Published private(set) var isWorking: Bool = false

    private enum Key {
        /// Cached "this device is registered" flag — kept in the Keychain so it survives relaunch
        /// AND offline launches, exactly like WanderProAccount's cached isPro. Superseded by the
        /// per-account verdict below whenever one exists; still written so an older build reads
        /// something sensible.
        static let registered = "wander.device.registered"
        /// The last successful server verdict for one account: "<registered 0/1>|<atLimit 0/1>",
        /// stored under this prefix + the account uid. One item per account, so signing into a
        /// second (even free) account can't overwrite the first account's denial.
        static let verdictPrefix = "wander.device.capVerdict."
    }

    private init() {
        // Reflect the cached registration immediately so an offline launch keeps Pro without a
        // round-trip. Absence means "unknown", which the fail-safe treats as "don't withhold".
        registered = WanderKeychain.string(Key.registered) == "1"
        // Then the persisted verdict for the signed-in account, if the Worker has ever answered for
        // it — including `atLimit`, which used to reset to false on every launch. Deliberately no
        // `License.shared.refresh()` here: this init can run inside License's own init.
        applyStoredVerdict()
    }

    // MARK: - The single, computed device gate used by License

    /// Whether the device cap ALLOWS account-Pro to unlock on THIS device.
    ///
    /// FAIL-SAFE: this returns `false` ONLY when we have a definitive "over the limit and this
    /// device is not one of the 5" signal (`atLimit && !registered`) — from this session's reply or,
    /// when the Worker can't be reached, from the last reply persisted for this account. In every
    /// other state — registered, under the cap, or UNKNOWN because the Worker has never answered for
    /// this account here — it returns `true`, so a paying user is never locked out by a network
    /// hiccup or a Worker outage.
    var allowsAccountPro: Bool {
        !(atLimit && !registered)
    }

    // MARK: - Persisted verdict

    /// The persisted verdict for the signed-in account, or nil when there is no account or the
    /// Worker has never answered for it on this device.
    private static func storedVerdict() -> (registered: Bool, atLimit: Bool)? {
        guard let uid = WanderProAccount.persistedUID,
              let raw = WanderKeychain.string(Key.verdictPrefix + uid) else { return nil }
        let parts = raw.split(separator: "|")
        guard parts.count == 2 else { return nil }
        return (parts[0] == "1", parts[1] == "1")
    }

    /// Persist the current in-memory verdict for the signed-in account. No account ⇒ nothing to
    /// bind it to, so nothing is written (sign-out takes this path).
    private func persistVerdict() {
        guard let uid = WanderProAccount.persistedUID else { return }
        WanderKeychain.set(Key.verdictPrefix + uid, "\(registered ? 1 : 0)|\(atLimit ? 1 : 0)")
    }

    /// Load the persisted verdict for the signed-in account into the published state. Returns
    /// whether anything changed, so callers outside init can ask License to recompute.
    @discardableResult
    private func applyStoredVerdict() -> Bool {
        guard let verdict = Self.storedVerdict() else { return false }
        let changed = verdict.registered != registered || verdict.atLimit != atLimit
        if registered != verdict.registered { registered = verdict.registered }
        if atLimit != verdict.atLimit { atLimit = verdict.atLimit }
        return changed
    }

    /// Foreground hook (WanderApp, next to WanderProAccount's). While the account is Pro and this
    /// device has NO verdict for it yet — the fail-open window — or the verdict is a denial, ask the
    /// Worker again: the first is how the fail-open window closes as soon as the Worker is reachable,
    /// the second picks up a slot freed on another device without a relaunch. A confirmed
    /// registration needs nothing here; every launch re-registers anyway.
    func handleForeground() {
        guard !isWorking, WanderProAccount.shared.isPro else { return }
        guard Self.storedVerdict() == nil || !allowsAccountPro else { return }
        Task { await activate() }
    }

    // MARK: - The friendly device name sent to the server

    /// A human-friendly name for this device: the marketing-ish model (UIDevice.model gives
    /// "iPhone"/"iPad"; we append the hardware identifier so multiple iPhones are distinguishable).
    static var friendlyDeviceName: String {
        let base = UIDevice.current.model            // "iPhone" / "iPad"
        let hardware = hardwareIdentifier()          // e.g. "iPhone15,2"
        // Prefer the user-set device name when available (e.g. "Faisal's iPhone"), but iOS 16+
        // returns a generic "iPhone" for UIDevice.name without entitlement, so fall back to model.
        let userName = UIDevice.current.name
        let candidate = (userName.isEmpty || userName == base) ? "\(base) (\(hardware))" : userName
        return String(candidate.prefix(40))
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    // MARK: - Activate (called on sign-in and app launch while online)

    /// POST /account/activate. Registers/refreshes THIS device against the account and updates
    /// `registered` / `atLimit` / `devices`. No-ops when not signed in or offline (both leave the
    /// cached state — and therefore effective Pro — untouched, per the fail-safe).
    ///
    /// Non-throwing: every failure path leaves the cache intact and returns quietly.
    func activate() async {
        // Start from the last verdict for whichever account is signed in NOW — after a sign-in (or a
        // sign-out/sign-in of the same account) this is what applies if the call below fails.
        if applyStoredVerdict() { License.shared.refresh() }

        // Offline → don't burn a doomed round-trip and, crucially, don't clear the cache. The
        // cached verdict keeps this device Pro through airplane mode exactly like the cached
        // account isPro does.
        guard NetworkReachability.shared.isOnline else { return }

        // Not signed in → the account can't be Pro anyway; nothing to activate. Leave cache as-is.
        guard let token = await WanderProAccount.shared.currentIdToken() else { return }
        // The account this request speaks for. A reply that lands after the user switched accounts
        // must not be filed as the new account's verdict.
        let requestUID = WanderProAccount.persistedUID

        var body: [String: Any] = [
            "idToken": token,
            "deviceId": WanderDevice.id,
            "platform": "ios",
            "deviceName": Self.friendlyDeviceName,
        ]

        isWorking = true
        defer { isWorking = false }

        var outcome = await post(path: "/account/activate", body: body)
        // A 401 means the short-lived idToken expired mid-flight — mint a fresh one and retry once,
        // mirroring WanderAIRoutine / firestoreRequest.
        if outcome.status == 401, let fresh = await WanderProAccount.shared.refreshedIdToken() {
            body["idToken"] = fresh
            outcome = await post(path: "/account/activate", body: body)
        }

        guard let obj = outcome.json, (obj["ok"] as? Bool) == true else {
            // Transport error, non-200, or unreadable body → FAIL-SAFE: keep the cached verdict
            // (or, with none stored, keep allowing — handleForeground asks again next time).
            return
        }
        guard WanderProAccount.persistedUID == requestUID else { return }

        applyActivateResponse(obj)
    }

    // MARK: - Remove a device (from the Manage Devices screen)

    /// POST /account/devices/remove for `deviceId`, then refresh the device list. After removing
    /// a device the caller should re-run `activate()` to claim the freed slot for THIS device.
    /// Returns true on a successful server round-trip.
    @discardableResult
    func removeDevice(_ deviceId: String) async -> Bool {
        guard NetworkReachability.shared.isOnline else { return false }
        guard let token = await WanderProAccount.shared.currentIdToken() else { return false }

        var body: [String: Any] = ["idToken": token, "deviceId": deviceId]

        isWorking = true
        defer { isWorking = false }

        var outcome = await post(path: "/account/devices/remove", body: body)
        if outcome.status == 401, let fresh = await WanderProAccount.shared.refreshedIdToken() {
            body["idToken"] = fresh
            outcome = await post(path: "/account/devices/remove", body: body)
        }

        guard let obj = outcome.json, (obj["ok"] as? Bool) == true else { return false }

        // The remove response carries the updated list; refresh the UI from it.
        if let list = obj["devices"] as? [[String: Any]] {
            devices = Self.parseDevices(list)
        }
        // If we removed THIS device, we're no longer registered — reflect that immediately.
        if deviceId == WanderDevice.id {
            setRegistered(false)
        }
        return true
    }

    /// Convenience used by the Manage Devices screen: remove a device, then immediately try to
    /// claim the freed slot for this device. Returns true if this device ends up registered.
    @discardableResult
    func removeThenReactivate(_ deviceId: String) async -> Bool {
        let removed = await removeDevice(deviceId)
        guard removed else { return false }
        // Don't try to re-register the very device we just removed.
        if deviceId != WanderDevice.id {
            await activate()
        }
        return registered
    }

    // MARK: - Sign-out hook

    /// Clear per-device registration state on sign-out so a different account starting fresh
    /// doesn't inherit a stale "registered" flag. (Effective Pro already drops because the account
    /// is no longer Pro; this just keeps the device state tidy.)
    ///
    /// In-memory only for the verdict: the persisted one stays filed under its account (sign-out has
    /// already cleared the uid, so `persistVerdict` writes nothing) and is restored if that account
    /// signs in again. Deleting it here would make sign-out → block the Worker → sign back in a
    /// way to erase a denial.
    func reset() {
        atLimit = false
        setRegistered(false)
        devices = []
    }

    // MARK: - Internals

    private func applyActivateResponse(_ obj: [String: Any]) {
        let pro = (obj["pro"] as? Bool) ?? false
        if !pro {
            // Account isn't Pro → device registration is irrelevant. Don't withhold anything;
            // effective Pro is already false via the account plan. Clear at-limit so a later
            // upgrade path isn't stuck showing "Manage Devices".
            atLimit = false
            // Don't force-clear `registered` here — an account that briefly reads non-pro (e.g. a
            // propagation lag) shouldn't flip the device gate; the account plan already gates Pro.
            return
        }

        let isRegistered = (obj["registered"] as? Bool) ?? false
        let isAtLimit = (obj["atLimit"] as? Bool) ?? false
        if let lim = obj["limit"] as? Int, lim > 0 { limit = lim }
        if let list = obj["devices"] as? [[String: Any]] {
            devices = Self.parseDevices(list)
        }

        atLimit = isAtLimit
        setRegistered(isRegistered)
    }

    /// Publish + cache the registration flag (and, with it, the whole verdict for the signed-in
    /// account), and ask License to recompute effective Pro.
    private func setRegistered(_ value: Bool) {
        WanderKeychain.set(Key.registered, value ? "1" : "0")
        if registered != value { registered = value }
        persistVerdict()
        License.shared.refresh()
    }

    private static func parseDevices(_ list: [[String: Any]]) -> [WanderDeviceInfo] {
        list.compactMap { row in
            guard let deviceId = row["deviceId"] as? String, !deviceId.isEmpty else { return nil }
            let platform = (row["platform"] as? String) ?? "ios"
            let name = (row["name"] as? String) ?? "Device"
            let lastSeen: Double?
            if let d = row["lastSeen"] as? Double { lastSeen = d }
            else if let i = row["lastSeen"] as? Int { lastSeen = Double(i) }
            else { lastSeen = nil }
            return WanderDeviceInfo(deviceId: deviceId, platform: platform, name: name, lastSeen: lastSeen)
        }
    }

    /// Perform one POST and return the parsed JSON (if any) plus the HTTP status. A transport
    /// failure returns status -1 with nil json so the caller falls through to the fail-safe.
    private func post(path: String, body: [String: Any]) async -> (json: [String: Any]?, status: Int) {
        guard let url = URL(string: "\(Self.baseURL)\(path)"),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return (nil, -1)
        }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (nil, -1) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (json, http.statusCode)
        } catch {
            return (nil, -1)
        }
    }
}
