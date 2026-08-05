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

    /// One step of a journey: a walking segment, a stretch of driving, or a ride on a named line.
    ///
    /// The Worker now returns `steps` for EVERY travel mode (it used to be transit-only) and each
    /// step carries its OWN encoded polyline, which is what lets the map draw a Google-Maps-style
    /// multi-leg route — a walk portion in one colour, the drive in another. `coordinates` is that
    /// polyline already decoded; it is EMPTY when the server is an older build that doesn't send
    /// per-step geometry, or when the server's size guard dropped this step's polyline because the
    /// step was very short (both are reported honestly rather than faked, and the caller falls back
    /// to the whole-route polyline).
    struct RouteStep: Identifiable {
        let id = UUID()
        let mode: String          // "WALK" | "DRIVE" | "BICYCLE" | "TRANSIT"
        /// The Routes-API travel mode for this step. Same value as `mode` — kept as its own field
        /// because that is the key the Worker documents, and `mode` predates it.
        let travelMode: String
        let durationSeconds: Double
        let distanceMeters: Double
        /// This step's own geometry, decoded from its encoded polyline. Empty when unavailable.
        let coordinates: [CLLocationCoordinate2D]
        let line: String          // e.g. "51B", "Richmond" (transit steps only)
        let vehicle: String       // "BUS" | "SUBWAY" | "HEAVY_RAIL" | "TRAM" | "RAIL" | "FERRY" | …
        let headsign: String      // where the vehicle is headed
        let from: String          // boarding stop name
        let to: String            // alighting stop name
        let stops: Int
    }

    struct Route {
        let summary: String
        let distanceMeters: Double
        let durationSeconds: Double
        let points: [CLLocationCoordinate2D]
        /// Per-step breakdown for this route (alternatives carry their own). Empty when the server
        /// doesn't send steps for this mode — the caller degrades to the single `points` line.
        let steps: [RouteStep]
    }

    // MARK: - Encoded polyline

    /// Decode a Google "encoded polyline algorithm" string into coordinates.
    ///
    /// The Worker deliberately leaves per-step geometry ENCODED (decoding it server-side would
    /// multiply the payload several times over), so the decode lives here. Malformed input yields
    /// whatever decoded cleanly rather than throwing — a partially-drawn leg is recoverable, a
    /// crash in the routing path is not.
    static func decodePolyline(_ encoded: String) -> [CLLocationCoordinate2D] {
        guard !encoded.isEmpty else { return [] }
        var out: [CLLocationCoordinate2D] = []
        var lat = 0, lon = 0
        let bytes = Array(encoded.utf8)
        var i = 0
        while i < bytes.count {
            // Each value is a chunked, ASCII-offset, zig-zag encoded varint.
            func nextValue() -> Int? {
                var result = 0, shift = 0
                while i < bytes.count {
                    let b = Int(bytes[i]) - 63
                    i += 1
                    guard b >= 0 else { return nil }
                    result |= (b & 0x1F) << shift
                    shift += 5
                    if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
                    if shift > 30 { return nil }   // corrupt: bail rather than spin
                }
                return nil
            }
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            out.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return out
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
                    let steps: [RouteStep] = (r["steps"] as? [[String: Any]] ?? []).map { s in
                        // `travelMode` and `staticDuration` are the newer keys; `mode` and
                        // `durationSeconds` are the originals. Read both so this client works
                        // against a server that has NOT been updated yet.
                        let modeStr = (s["travelMode"] as? String) ?? (s["mode"] as? String) ?? "WALK"
                        let dur = (s["staticDuration"] as? NSNumber)?.doubleValue
                            ?? (s["durationSeconds"] as? NSNumber)?.doubleValue ?? 0
                        return RouteStep(mode: s["mode"] as? String ?? modeStr,
                                  travelMode: modeStr,
                                  durationSeconds: dur,
                                  distanceMeters: (s["distanceMeters"] as? NSNumber)?.doubleValue ?? 0,
                                  coordinates: decodePolyline(s["polyline"] as? String ?? ""),
                                  line: s["line"] as? String ?? "",
                                  vehicle: s["vehicle"] as? String ?? "",
                                  headsign: s["headsign"] as? String ?? "",
                                  from: s["from"] as? String ?? "",
                                  to: s["to"] as? String ?? "",
                                  stops: (s["stops"] as? NSNumber)?.intValue ?? 0)
                    }
                    return Route(summary: r["summary"] as? String ?? "",
                                 distanceMeters: (r["distanceMeters"] as? NSNumber)?.doubleValue ?? 0,
                                 durationSeconds: (r["durationSeconds"] as? NSNumber)?.doubleValue ?? 0,
                                 points: pts,
                                 steps: steps)
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
