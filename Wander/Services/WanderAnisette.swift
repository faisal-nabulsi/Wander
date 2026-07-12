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

    static var serverURLString: String {
        UserDefaults.standard.string(forKey: defaultsKey) ?? "https://ani.sidestore.io"
    }

    /// Fetch anisette data from a v1-style anisette server (single GET → X-Apple-* headers).
    static func fetch() async throws -> ALTAnisetteData {
        guard let url = URL(string: serverURLString) else { throw WanderAnisetteError.badURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

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
        f["deviceDescription"] = json["X-MMe-Client-Info"] ?? json["X-Mme-Client-Info"] ?? "<Wander>"
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
