//
//  WanderLicenseServer.swift
//  Wander
//
//  Talks to the license Worker for "bind-on-first-redeem" codes. The app sends the code the
//  buyer pasted PLUS this device's persistent ID (WanderDevice.id) — the buyer never has to
//  find or send a device ID. The Worker binds the code to the first device that redeems it
//  and returns a signed, device-bound license token the app then verifies + stores offline.
//

import Foundation

enum WanderLicenseServer {
    struct ServerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// POST {code, device} to <baseURL>/redeem and return the signed license token.
    static func redeem(code: String, baseURL: String) async throws -> String {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/redeem") else {
            throw ServerError(message: "The license server URL is invalid.")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "device": WanderDevice.id,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ServerError(message: (obj?["error"] as? String) ?? "License server error (\(http.statusCode)).")
        }
        guard let token = obj?["token"] as? String, !token.isEmpty else {
            throw ServerError(message: "The license server didn't return a key.")
        }
        return token
    }
}

/// Routes a pasted key: a full Ed25519 token (contains ".") verifies offline; a short server
/// code is redeemed through the Worker (which binds it to this device). Returns nil on
/// success, or a user-facing error message.
@MainActor
enum LicenseRedeemer {
    static func redeem(_ raw: String) async -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return "Enter your license key." }

        // Offline token (device-bound or lifetime) — verify against the embedded key.
        if code.contains(".") {
            return License.shared.redeem(code) ? nil : "That key isn't valid (or it's for another device)."
        }

        // Short server code → bind-on-first-redeem via the Worker.
        let base = RemoteGate.shared.licenseServerURL
        guard !base.isEmpty else {
            return "This code needs the license server, which isn't set up yet."
        }
        do {
            let token = try await WanderLicenseServer.redeem(code: code, baseURL: base)
            return License.shared.redeem(token) ? nil : "The server returned a key this device can't use."
        } catch {
            return error.localizedDescription
        }
    }
}
