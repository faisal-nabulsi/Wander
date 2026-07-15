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
//  KEEP the last cached {pro, registered} — we NEVER lock out a paying user because their Wi-Fi
//  dropped. The ONLY response that withholds Pro on this device is an explicit
//  `atLimit == true && registered == false` (a genuine "you're over 5 devices, this one isn't
//  one of them"). A Pro user already registered — or under the cap — is never blocked.
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
        /// AND offline launches, exactly like WanderProAccount's cached isPro.
        static let registered = "wander.device.registered"
    }

    private init() {
        // Reflect the cached registration immediately so an offline launch keeps Pro without a
        // round-trip. We only ever cache a POSITIVE registration; absence means "unknown", which
        // the fail-safe treats as "don't withhold" (see License.deviceUnlockAllowed).
        registered = WanderKeychain.string(Key.registered) == "1"
    }

    // MARK: - The single, computed device gate used by License

    /// Whether the device cap ALLOWS account-Pro to unlock on THIS device.
    ///
    /// FAIL-SAFE: this returns `false` ONLY when we have a definitive "over the limit and this
    /// device is not one of the 5" signal (`atLimit && !registered`). In every other state —
    /// registered, under the cap, or simply UNKNOWN because we're offline / the call failed —
    /// it returns `true`, so a paying user is never locked out by a network hiccup.
    var allowsAccountPro: Bool {
        !(atLimit && !registered)
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
        // Offline → don't burn a doomed round-trip and, crucially, don't clear the cache. The
        // cached `registered` keeps this device Pro through airplane mode exactly like the cached
        // account isPro does.
        guard NetworkReachability.shared.isOnline else { return }

        // Not signed in → the account can't be Pro anyway; nothing to activate. Leave cache as-is.
        guard let token = await WanderProAccount.shared.currentIdToken() else { return }

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
            // Transport error, non-200, or unreadable body → FAIL-SAFE: keep the cached state.
            return
        }

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
    func reset() {
        setRegistered(false)
        atLimit = false
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

    /// Publish + cache the registration flag, and ask License to recompute effective Pro. We cache
    /// only the boolean so an offline launch reflects the last known registration.
    private func setRegistered(_ value: Bool) {
        WanderKeychain.set(Key.registered, value ? "1" : "0")
        if registered != value { registered = value }
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
