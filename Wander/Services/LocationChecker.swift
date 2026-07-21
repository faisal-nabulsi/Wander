//
//  LocationChecker.swift
//  Wander
//
//  Pre-flight COHERENCE CHECKS — advisory warnings that surface the two highest-yield
//  "Failed to detect location (12)" causes plus one detection vector, BEFORE the user
//  teleports. Everything here is guidance only: nothing blocks a spoof, and every check
//  is fail-safe (a check that can't run just omits its warning).
//
//  Live, on-device checks:
//   1. Location authorization — Location Services off / not authorized for Wander. iOS needs a
//      real fix to seed from; with authorization off, a teleport reads as an impossible cold jump
//      and PoGo throws Error 12.
//   2. Reduced accuracy (Precise Location OFF) — the same failure mode: a coarse, jittery real fix
//      fights the injected precise fix. Readable from a sandboxed app via `accuracyAuthorization`.
//   3. IP↔GPS city mismatch (best-effort, async) — the app's network still egresses from the REAL
//      city while GPS claims another. This is the detection vector: anti-cheat correlates the two.
//      Advisory only; suggests a VPN in the spoofed region.
//
//  DROPPED — Find My detection: a sandboxed iOS app CANNOT read Find My state (no API, no
//  entitlement). Not attempted here on purpose.
//

import Foundation
import CoreLocation

/// One advisory pre-flight warning. Advisory only — never blocks a spoof.
struct LocationWarning: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Location Services off, or Wander not authorized. Deep-links to the app's Settings page.
        case locationAuthorization
        /// Precise Location is OFF (reduced accuracy). Deep-links to the app's Settings page.
        case reducedAccuracy
        /// The real network egress city differs a lot from the spoofed target's city.
        case ipGpsMismatch(realCity: String, spoofedCity: String)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .locationAuthorization: return "locationAuthorization"
        case .reducedAccuracy: return "reducedAccuracy"
        case .ipGpsMismatch: return "ipGpsMismatch"
        }
    }

    /// Short headline for the pre-flight row.
    var title: String {
        switch kind {
        case .locationAuthorization:
            return L("preflight.auth.title", fallback: "Location Services is off for Wander")
        case .reducedAccuracy:
            return L("preflight.precise.title", fallback: "Precise Location is off")
        case .ipGpsMismatch:
            return L("preflight.ipgps.title", fallback: "Your network still looks local")
        }
    }

    /// One-line explanation + guidance.
    var message: String {
        switch kind {
        case .locationAuthorization:
            return L("preflight.auth.body",
                     fallback: "iOS needs a real fix to seed from — with location off, a teleport can read as an impossible jump and trigger Error 12. Turn Location Services on for Wander.")
        case .reducedAccuracy:
            return L("preflight.precise.body",
                     fallback: "A coarse real fix fights the injected precise fix and can trip Error 12. Turn Precise Location on for Wander.")
        case .ipGpsMismatch(let realCity, let spoofedCity):
            let template = L("preflight.ipgps.body",
                             fallback: "Your network still looks like %@ while GPS says %@. Consider a VPN in that region so the two agree.")
            return String(format: template, realCity, spoofedCity)
        }
    }

    /// SF Symbol for the row.
    var symbol: String {
        switch kind {
        case .locationAuthorization: return "location.slash"
        case .reducedAccuracy: return "scope"
        case .ipGpsMismatch: return "network"
        }
    }

    /// Whether a one-tap "Open Settings" affordance applies (the on-device toggles do; the
    /// IP↔GPS hint is informational — the fix is a VPN, not an app setting).
    var opensSettings: Bool {
        switch kind {
        case .locationAuthorization, .reducedAccuracy: return true
        case .ipGpsMismatch: return false
        }
    }

    /// The spoofed city name for the IP↔GPS mismatch case, so the VPN affordance can name the
    /// region to connect to (e.g. "connect to a server in <spoofed city>"). `nil` for other kinds.
    var spoofedCity: String? {
        switch kind {
        case .ipGpsMismatch(_, let spoofedCity): return spoofedCity
        default: return nil
        }
    }
}

/// Real-network geolocation returned by the Worker's `/ip-geo` endpoint (derived from the
/// request's egress IP — i.e. where the app's traffic actually comes from).
private struct IPGeo: Decodable {
    let city: String?
    let region: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let timezone: String?
}

/// Runs the coherence checks and publishes the resulting advisory warnings for the pre-flight card.
/// All checks are fail-safe; nothing here ever blocks a teleport.
@MainActor
final class LocationChecker: ObservableObject {
    /// Current advisory warnings, most recently refreshed. Empty == everything looks coherent.
    @Published private(set) var warnings: [LocationWarning] = []

    /// The VPN we point the user at from the IP↔GPS mismatch card. Single swappable constant so the
    /// owner can drop in an affiliate link without touching the UI.
    // TODO(owner): replace with your affiliate link
    static let recommendedVPNURL = URL(string: "https://surfshark.com/")!

    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// A CLLocationManager is authoritative for BOTH the authorization status and the
    /// accuracy authorization (Precise on/off) — both readable from a sandboxed app.
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    /// Distance beyond which we treat the real-network city and the spoofed city as a real
    /// mismatch worth surfacing. Deliberately LARGE: the `/ip-geo` reading is coarse Cloudflare
    /// IP-geo, which for many carriers/CGNAT egresses resolves to a POP hundreds of km from the
    /// user's actual location. At 150 km an honest, un-spoofing user on such a carrier got falsely
    /// nagged. Widened to ~500 km and paired with a required city-NAME mismatch below so the warning
    /// only fires on a genuine, high-confidence mismatch (CF geo is treated as low-confidence).
    private let mismatchThresholdKm: Double = 500

    /// Re-run all checks for a given spoofed target. Synchronous on-device checks land first (so the
    /// card populates instantly); the IP↔GPS check folds in asynchronously when/if it resolves.
    ///
    /// - Parameter spoofedTarget: the coordinate the user is about to teleport to (for the IP↔GPS
    ///   comparison). Pass `nil` to run only the device-authorization/accuracy checks.
    func refresh(spoofedTarget: CLLocationCoordinate2D?) {
        // 1 + 2: instant, on-device.
        warnings = deviceWarnings()

        // 3: best-effort, async, non-blocking. Any failure (offline, geocoder miss, unauthorized
        // network) simply omits the mismatch warning — never surfaces a false alarm.
        guard let spoofedTarget else { return }
        Task { [weak self] in
            guard let self else { return }
            if let mismatch = await self.ipGpsMismatchWarning(spoofedTarget: spoofedTarget) {
                // Re-read device warnings in case authorization changed while the network call ran.
                self.warnings = self.deviceWarnings() + [mismatch]
            }
        }
    }

    /// The two instant, on-device checks (authorization + precise accuracy).
    private func deviceWarnings() -> [LocationWarning] {
        var result: [LocationWarning] = []

        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Authorized — now check accuracy. Reduced accuracy (Precise OFF) is the second-highest
            // Error-12 cause, so only warn about it when we're actually authorized to read it.
            if manager.accuracyAuthorization == .reducedAccuracy {
                result.append(LocationWarning(kind: .reducedAccuracy))
            }
        case .notDetermined, .denied, .restricted:
            result.append(LocationWarning(kind: .locationAuthorization))
        @unknown default:
            result.append(LocationWarning(kind: .locationAuthorization))
        }

        return result
    }

    // MARK: - IP↔GPS mismatch (VERIFY-FIRST on device)
    //
    // This is the part to sanity-check on a real device before leaning on it: the /ip-geo egress
    // reading, the reverse-geocode of BOTH points, and the ~500 km threshold all interact. It's
    // deliberately conservative + advisory so a false positive costs nothing; the warning now
    // requires BOTH a large distance AND a differing city name (CF geo is low-confidence) so an
    // honest user on a carrier with a distant IP-geo POP is never falsely nagged.

    /// Fetch the real-network city (Worker `/ip-geo`) and compare it to the spoofed point's city.
    /// Returns a mismatch warning only on a GENUINE, HIGH-CONFIDENCE mismatch: BOTH the coarse CF
    /// IP-geo point is far (~500 km+) from the spoofed target AND the two city NAMES actually differ.
    /// Requiring both keeps an honest user — whose carrier egresses from a distant CF POP that
    /// happens to be 150+ km away — from being falsely nagged. Fail-safe: any missing piece (offline,
    /// geocoder miss, malformed response) returns nil (no warning). CF geo is low-confidence, so we
    /// never fire on distance alone.
    private func ipGpsMismatchWarning(spoofedTarget: CLLocationCoordinate2D) async -> LocationWarning? {
        guard let realGeo = await fetchRealNetworkGeo() else { return nil }

        // Distance gate: require the coarse CF IP-geo point to be far from the spoofed target. If the
        // real geo lacks coordinates we can't measure distance → don't nag (low-confidence, bail).
        guard let realLat = realGeo.latitude, let realLng = realGeo.longitude else { return nil }
        let real = CLLocationCoordinate2D(latitude: realLat, longitude: realLng)
        let km = PoGoCooldown.distanceKm(from: real, to: spoofedTarget)
        guard km >= mismatchThresholdKm else { return nil }

        // City-NAME gate: reverse-geocode BOTH the CF IP-geo point and the spoofed target, and require
        // their localities to actually differ. This is the confidence check — a distant CF POP that
        // still resolves to the same city name as the target is not a real mismatch, so we stay quiet.
        // If either name is unresolvable we can't confirm the mismatch → don't nag.
        let resolvedIPCity: String?
        if let city = realGeo.city {
            resolvedIPCity = city
        } else {
            resolvedIPCity = await reverseGeocodeCity(real)
        }
        guard let ipCity = resolvedIPCity,
              let spoofedCity = await reverseGeocodeCity(spoofedTarget) else {
            return nil
        }
        guard ipCity.caseInsensitiveCompare(spoofedCity) != .orderedSame else { return nil }

        return LocationWarning(kind: .ipGpsMismatch(realCity: ipCity, spoofedCity: spoofedCity))
    }

    private func fetchRealNetworkGeo() async -> IPGeo? {
        guard let url = URL(string: "\(Self.baseURL)/ip-geo") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(IPGeo.self, from: data)
        } catch {
            return nil   // offline / blocked / malformed → omit the check
        }
    }

    private func reverseGeocodeCity(_ coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks = try? await geocoder.reverseGeocodeLocation(location)
        guard let place = placemarks?.first else { return nil }
        return place.locality ?? place.subAdministrativeArea ?? place.administrativeArea ?? place.country
    }
}
