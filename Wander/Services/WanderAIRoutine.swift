//
//  WanderAIRoutine.swift
//  Wander
//
//  Pro-gated "Generate a believable day (AI)" feature. Calls Wander's Worker — NOT Anthropic
//  directly. The Anthropic key lives ONLY on the Worker; this client never holds it and never
//  talks to any AI provider. We mirror EXACTLY how the app already reaches the Worker for the
//  trial/sync flows: get the signed-in user's Firebase idToken from WanderProAccount and POST
//  it (plus lat/lng and optional city/style) in a JSON body to the same Worker base URL.
//
//  Endpoint: POST <base>/ai/routine
//  Request:  { idToken, lat, lng, city?, style? }
//  Success:  { ok:true, routine:{ places:[ { label, kind, lat, lng, arrive, depart } ... ] } }
//
//  Every failure path is a typed, non-fatal outcome (never a crash / force-unwrap):
//   • 403 pro_required      → open the paywall/upsell
//   • 429 daily_limit       → friendly "hit today's AI limit" message
//   • 503 ai_not_configured → "AI features aren't switched on yet" (the current owner state)
//   • network / other       → a plain non-fatal error message
//

import Foundation
import CoreLocation

/// One stop in an AI-generated day. `arrive`/`depart` are whatever human-readable time strings
/// the Worker returned (e.g. "9:00 AM"); the app only displays them and never parses them.
struct AIRoutinePlace: Identifiable {
    let id = UUID()
    let label: String
    let kind: String?
    let coordinate: CLLocationCoordinate2D
    let arrive: String?
    let depart: String?
}

/// The distinct, user-actionable outcomes of an AI-routine request. The view switches on this;
/// there is no throwing/crashing path — every server and transport condition maps to a case.
enum AIRoutineResult {
    case success([AIRoutinePlace])
    case proRequired                    // 403 — open the paywall
    case dailyLimit(String)             // 429 — friendly limit message
    case notConfigured(String)          // 503 — AI not switched on yet
    case failed(String)                 // network / decode / other non-fatal error
}

enum WanderAIRoutine {
    /// Same Worker base the trial/license flows use. The Anthropic key is ONLY on this Worker;
    /// the client never sees it.
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// Ask the Worker to generate a believable day around `coordinate`. Auth mirrors the trial
    /// endpoints: the Firebase idToken is fetched from WanderProAccount and sent in the body.
    /// Returns a typed `AIRoutineResult` — callers never have to catch.
    @MainActor
    static func generate(at coordinate: CLLocationCoordinate2D,
                         city: String? = nil,
                         style: String? = nil) async -> AIRoutineResult {
        // Reuse the exact idToken retrieval the trial/sync features use. No sign-in → the
        // account isn't Pro anyway, so route the user to the upsell rather than erroring.
        guard let token = await WanderProAccount.shared.currentIdToken() else {
            return .proRequired
        }

        var body: [String: Any] = [
            "idToken": token,
            "lat": coordinate.latitude,
            "lng": coordinate.longitude,
        ]
        if let city, !city.isEmpty { body["city"] = city }
        if let style, !style.isEmpty { body["style"] = style }

        var first = await post(body: body)
        // A 401 means the short-lived idToken expired mid-flight — mint a fresh one and retry once,
        // mirroring the firestoreRequest 401-retry in WanderProAccount.
        if case .failed = first.result, first.status == 401,
           let fresh = await WanderProAccount.shared.refreshedIdToken() {
            body["idToken"] = fresh
            first = await post(body: body)
        }
        return first.result
    }

    /// Perform one POST and map the HTTP status → an `AIRoutineResult`. Returns the raw status
    /// too so the caller can decide whether a 401 retry is worth it.
    private static func post(body: [String: Any]) async -> (result: AIRoutineResult, status: Int) {
        guard let url = URL(string: "\(baseURL)/ai/routine"),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return (.failed("Couldn't build the AI request."), -1)
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (.failed("The AI server didn't respond. Please try again."), -1)
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

            switch http.statusCode {
            case 200:
                guard let obj, (obj["ok"] as? Bool) == true,
                      let routine = obj["routine"] as? [String: Any],
                      let rawPlaces = routine["places"] as? [[String: Any]] else {
                    return (.failed("The AI reply couldn't be read. Please try again."), 200)
                }
                let places = rawPlaces.compactMap(parsePlace)
                guard !places.isEmpty else {
                    return (.failed("The AI didn't return any stops. Try a different spot."), 200)
                }
                return (.success(places), 200)

            case 403:
                // Pro-gated on the server too — send the user to the upsell.
                return (.proRequired, 403)

            case 429:
                return (.dailyLimit(serverMessage(obj)
                    ?? "You've hit today's AI limit. Try again tomorrow."), 429)

            case 503:
                return (.notConfigured(serverMessage(obj)
                    ?? "AI features aren't switched on yet. Check back soon."), 503)

            default:
                return (.failed(serverMessage(obj)
                    ?? "The AI server had a problem (\(http.statusCode)). Please try again."),
                        http.statusCode)
            }
        } catch {
            return (.failed("Couldn't reach the AI server. Check your connection and try again."), -1)
        }
    }

    /// Turn one server place object into an `AIRoutinePlace`, skipping anything missing coords
    /// (a malformed entry is dropped, never crashes the parse).
    private static func parsePlace(_ dict: [String: Any]) -> AIRoutinePlace? {
        guard let lat = numeric(dict["lat"]), let lng = numeric(dict["lng"]) else { return nil }
        let label = (dict["label"] as? String) ?? "Stop"
        return AIRoutinePlace(
            label: label,
            kind: dict["kind"] as? String,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            arrive: dict["arrive"] as? String,
            depart: dict["depart"] as? String
        )
    }

    /// Accept a number whether the JSON encoded it as a Double, Int, or numeric String.
    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Pull a human-readable message out of a Worker error payload, if present.
    private static func serverMessage(_ obj: [String: Any]?) -> String? {
        for key in ["message", "error"] {
            if let s = obj?[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
