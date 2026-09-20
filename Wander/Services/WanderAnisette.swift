//
//  WanderAnisette.swift
//  Wander
//
//  Fetches "anisette" data — Apple's machine-identity headers required for Apple-ID
//  authentication. This is the v1 style: a single GET to an anisette server returns the
//  X-Apple-* headers, which we map into ALTAnisetteData. (v3/ADI provisioning is a later
//  hardening step.)
//

import Foundation
import AltSign

enum WanderAnisetteError: LocalizedError {
    case badURL
    case badResponse(Int)
    case notJSON
    case missingFields

    var errorDescription: String? {
        switch self {
        case .badURL: return "The anisette server URL is invalid."
        case .badResponse(let code): return "Anisette server returned HTTP \(code)."
        case .notJSON: return "Anisette server response wasn't the expected JSON."
        case .missingFields: return "Anisette server didn't return all required fields (it may be a v3-only server — try a different anisette URL)."
        }
    }
}

enum WanderAnisette {
    static let defaultsKey = "wander.anisetteURL"

    /// Known-good v1-compatible anisette servers (verified reachable + full field set 2026-07-22).
    /// A SINGLE hard-coded server is a single point of failure — when it goes down (as ani.sidestore.io
    /// did), every Apple-ID sign-in fails, which cascades into "can't self-refresh / can't update." We
    /// try each in order and take the first that returns valid anisette. A user override is tried FIRST.
    static let fallbackServers = [
        "https://ani.846969.xyz",
        "https://ani.npeg.us",
        "https://ani.sidestore.io",   // kept last in case it recovers
    ]

    /// The user's manually-set override, if any (Settings → advanced). Empty string == unset.
    static var overrideURL: String {
        get { (UserDefaults.standard.string(forKey: defaultsKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: defaultsKey) }
    }

    /// Servers to try, in order: the user override first (if set), then the built-in fallbacks.
    static var candidates: [String] {
        var list: [String] = []
        if !overrideURL.isEmpty { list.append(overrideURL) }
        for s in fallbackServers where !list.contains(s) { list.append(s) }
        return list
    }

    /// A client_info string Apple's GrandSlam edge accepts, used when a server gives us nothing
    /// usable. Same value upstream (nab138/isideload, branch `apple-codesign-quick`) pins.
    static let knownGoodClientInfo =
        "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    /// Around 2026-09-10 Apple's GrandSlam edge began answering POSTs to /grandslam/GsService2
    /// with a 190-byte HTML 503 — BEFORE any credential check — whenever X-MMe-Client-Info names
    /// `com.apple.dt.Xcode`. Every public anisette server still hands out that blocked string, so
    /// failing over to another server does NOT help; we have to rewrite it ourselves.
    ///
    /// Verified by A/B against gsa.apple.com: the block keys on the app-identifier token alone.
    ///   `<Mac15,7> ... (com.apple.dt.Xcode/3594.4.19)`  -> 503
    ///   `<MacBookPro13,2> ... (com.apple.akd/1.0)`      -> 200
    /// So swap ONLY that token and keep whatever device/OS the server declared, which stays
    /// consistent with the machineID/OTP issued alongside it. A string that is already clean is
    /// passed through untouched, so this keeps working if a server later serves a different
    /// (non-blocked) description.
    static func sanitizedClientInfo(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return knownGoodClientInfo }
        guard raw.contains("com.apple.dt.Xcode") else { return raw }
        guard let open = raw.range(of: "(com.apple.dt.Xcode"),
              let close = raw[open.upperBound...].firstIndex(of: ")") else {
            return knownGoodClientInfo   // unrecognised shape -> known-good constant
        }
        return raw.replacingCharacters(in: open.lowerBound...close, with: "(com.apple.akd/1.0)")
    }

    /// Fetch anisette, trying each candidate server until one succeeds. This is what makes sign-in
    /// resilient to any single server going down. Throws the LAST error if every server fails.
    static func fetch() async throws -> ALTAnisetteData {
        var lastError: Error = WanderAnisetteError.badURL
        for server in candidates {
            do { return try await fetch(from: server) }
            catch { lastError = error }   // that server failed → try the next
        }
        throw lastError
    }

    /// Fetch anisette data from ONE v1-style anisette server (single GET → X-Apple-* headers).
    private static func fetch(from serverURLString: String) async throws -> ALTAnisetteData {
        guard let url = URL(string: serverURLString) else { throw WanderAnisetteError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15   // shorter per-server so we fail over quickly to the next

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WanderAnisetteError.badResponse(http.statusCode)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw WanderAnisetteError.notJSON
        }

        // Map the server's Apple headers into ALTAnisetteData's expected json keys.
        var f: [String: String] = ["deviceSerialNumber": "0"]
        f["machineID"] = json["X-Apple-I-MD-M"]
        f["oneTimePassword"] = json["X-Apple-I-MD"]
        f["routingInfo"] = json["X-Apple-I-MD-RINFO"] ?? "0"
        f["deviceDescription"] = sanitizedClientInfo(json["X-MMe-Client-Info"] ?? json["X-Mme-Client-Info"])
        f["localUserID"] = json["X-Apple-I-MD-LU"]
        f["deviceUniqueIdentifier"] = json["X-Mme-Device-Id"]
        f["date"] = json["X-Apple-I-Client-Time"] ?? ISO8601DateFormatter().string(from: Date())
        f["locale"] = json["X-Apple-Locale"] ?? Locale.current.identifier
        f["timeZone"] = json["X-Apple-I-TimeZone"] ?? TimeZone.current.abbreviation() ?? "UTC"

        guard let anisette = ALTAnisetteData(json: f) else {
            throw WanderAnisetteError.missingFields
        }
        return anisette
    }
}
