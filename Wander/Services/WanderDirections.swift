//
//  WanderDirections.swift
//  Wander
//
//  Client for the Worker's /directions endpoint (Google Routes API, Pro-gated + daily-capped
//  server-side). Route mode uses this for the routing Apple's MKDirections can't do: real cycling,
//  combined public transit, and avoid-highways/tolls. Basic Drive/Walk still use Apple (free) —
//  see RouteModeView.computeRoute. The Google key never touches the client; it lives only as a
//  Worker secret. Auth mirrors WanderAIRoutine (Firebase idToken in the body, one 401 retry).
//

import Foundation
import CoreLocation

enum WanderDirections {
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    struct Route {
        let summary: String
        let distanceMeters: Double
        let durationSeconds: Double
        let points: [CLLocationCoordinate2D]
    }

    enum Outcome {
        case success([Route])
        case noRoute
        case proRequired
        case failed(String)
    }

    /// `mode`: "driving" | "walking" | "bicycling" | "transit".
    @MainActor
    static func fetch(origin: CLLocationCoordinate2D,
                      destination: CLLocationCoordinate2D,
                      waypoints: [CLLocationCoordinate2D] = [],
                      mode: String,
                      avoidHighways: Bool = false,
                      avoidTolls: Bool = false,
                      alternatives: Bool = false) async -> Outcome {
        guard NetworkReachability.shared.isOnline else {
            return .failed("You're offline — connect to use cycling/transit routing.")
        }
        guard let token = await WanderProAccount.shared.currentIdToken() else { return .proRequired }

        func body(_ t: String) -> [String: Any] {
            [
                "idToken": t,
                "origin": ["lat": origin.latitude, "lng": origin.longitude],
                "destination": ["lat": destination.latitude, "lng": destination.longitude],
                "waypoints": waypoints.map { ["lat": $0.latitude, "lng": $0.longitude] },
                "mode": mode,
                "avoidHighways": avoidHighways,
                "avoidTolls": avoidTolls,
                "alternatives": alternatives,
            ]
        }

        var (outcome, status) = await post(body(token))
        if case .failed = outcome, status == 401, let fresh = await WanderProAccount.shared.refreshedIdToken() {
            (outcome, status) = await post(body(fresh))
        }
        return outcome
    }

    @MainActor
    private static func post(_ body: [String: Any]) async -> (Outcome, Int) {
        guard let url = URL(string: "\(baseURL)/directions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return (.failed("Couldn't build the routing request."), -1)
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]

            if obj?["ok"] as? Bool == true, let rawRoutes = obj?["routes"] as? [[String: Any]] {
                let routes: [Route] = rawRoutes.map { r in
                    let pts = (r["points"] as? [[Double]] ?? []).compactMap { p -> CLLocationCoordinate2D? in
                        p.count == 2 ? CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) : nil
                    }
                    return Route(summary: r["summary"] as? String ?? "",
                                 distanceMeters: (r["distanceMeters"] as? NSNumber)?.doubleValue ?? 0,
                                 durationSeconds: (r["durationSeconds"] as? NSNumber)?.doubleValue ?? 0,
                                 points: pts)
                }
                return (.success(routes), status)
            }

            switch obj?["error"] as? String ?? "" {
            case "pro_required":                return (.proRequired, status)
            case "no_route":                    return (.noRoute, status)
            case "daily_limit":                 return (.failed("You've hit today's routing limit — try again tomorrow, or use Drive/Walk."), status)
            case "directions_not_configured":   return (.failed("Advanced routing isn't available yet."), status)
            case let e where !e.isEmpty:        return (.failed(e.replacingOccurrences(of: "_", with: " ").capitalized), status)
            default:                            return (.failed("Routing failed. Please try again."), status)
            }
        } catch {
            return (.failed(error.localizedDescription), -1)
        }
    }
}
