//
//  UsageStats.swift
//  Wander
//
//  Anonymous usage count: one tiny POST per app session, so we can see daily active installs
//  and how often the app is opened, split by platform, version and free/Pro.
//
//  What is sent, and nothing else:
//    { "iid": <random UUID made once per install>, "p": "ios", "v": "<version>+<build>",
//      "t": "free" | "pro" }
//
//  The install id is a fresh random UUID kept in UserDefaults, so it disappears when the app is
//  deleted. It is NEVER derived from or sent alongside the Wander account (email / Firebase uid),
//  the Apple ID, WanderDevice.id, identifierForVendor, or any advertising id.
//
//  Sent on launch and on each return to the foreground, at most once per 30 minutes per install.
//  Fire-and-forget: 5-second timeout, no retries, never blocks the UI, every failure is silent.
//  No prompt, no setting, no UI.
//

import Foundation
import UIKit

@MainActor
enum UsageStats {
    private static let endpoint = URL(string: "https://wander-payments.wanderlocation.workers.dev/metrics/session")!
    private static let installIdKey = "wander.usage.installId"
    private static let lastSentKey = "wander.usage.lastSentAt"
    private static let minInterval: TimeInterval = 30 * 60

    /// A dedicated session that keeps nothing between requests (no cookies, no cache) and gives up
    /// after 5 seconds instead of waiting for connectivity.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Record that the app is open. Call on launch and whenever the app becomes active.
    static func recordSession() {
        // A background-only wake (keep-alive, schedule, location relaunch) isn't someone using the app.
        guard UIApplication.shared.applicationState != .background else { return }

        let defaults = UserDefaults.standard
        let now = Date()
        if let last = defaults.object(forKey: lastSentKey) as? Date {
            let elapsed = now.timeIntervalSince(last)
            // A negative elapsed means the clock moved backwards; treat it as due.
            if elapsed >= 0 && elapsed < minInterval { return }
        }
        // Stamp before sending: a failed send is not retried until the next 30-minute window.
        defaults.set(now, forKey: lastSentKey)

        let payload: [String: String] = [
            "iid": installId(defaults),
            "p": "ios",
            "v": appVersion,
            "t": License.shared.isLicensed ? "pro" : "free",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// The per-install random id. Created on first use; regenerated only if the stored value is
    /// missing or malformed.
    private static func installId(_ defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: installIdKey), UUID(uuidString: stored) != nil {
            return stored
        }
        let fresh = UUID().uuidString.lowercased()   // Foundation's UUID() is a random (v4) UUID
        defaults.set(fresh, forKey: installIdKey)
        return fresh
    }

    /// Marketing version + build, e.g. "1.0+156". Kept to printable ASCII and capped at 32
    /// characters, which is exactly what the Worker accepts (anything else is rejected with a 400).
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        var ascii = String.UnicodeScalarView()
        ascii.append(contentsOf: "\(short)+\(build)".unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E })
        let version = String(String(ascii).prefix(32))
        return version.isEmpty ? "?" : version
    }
}
