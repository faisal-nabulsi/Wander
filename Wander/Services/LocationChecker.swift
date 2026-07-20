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

    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// A CLLocationManager is authoritative for BOTH the authorization status and the
    /// accuracy authorization (Precise on/off) — both readable from a sandboxed app.
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    /// Distance beyond which we treat the real-network city and the spoofed city as a real
    /// mismatch worth surfacing. Conservative on purpose (a neighbouring town shouldn't nag).
    private let mismatchThresholdKm: Double = 150

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
    // reading, the reverse-geocode of the spoofed point, and the 150 km threshold all interact. It's
    // deliberately conservative + advisory so a false positive costs nothing, but the exact
    // wording/threshold should be validated against a couple of real VPN/no-VPN runs on-device.

    /// Fetch the real-network city (Worker `/ip-geo`) and compare it to the spoofed point's city.
    /// Returns a mismatch warning only when both cities resolve AND they're far apart. Fail-safe:
    /// any missing piece (offline, geocoder miss, malformed response) returns nil (no warning).
    private func ipGpsMismatchWarning(spoofedTarget: CLLocationCoordinate2D) async -> LocationWarning? {
        guard let realGeo = await fetchRealNetworkGeo() else { return nil }

        // Prefer a coordinate-distance gate (robust to differing city-name spellings/localizations),
        // falling back to city-name inequality only when the real geo lacks coordinates.
        if let realLat = realGeo.latitude, let realLng = realGeo.longitude {
            let real = CLLocationCoordinate2D(latitude: realLat, longitude: realLng)
            let km = PoGoCooldown.distanceKm(from: real, to: spoofedTarget)
            guard km >= mismatchThresholdKm else { return nil }
        } else if realGeo.city == nil {
            return nil
        }

        let spoofedCity = await reverseGeocodeCity(spoofedTarget)
        let realCity = realGeo.city
            ?? realGeo.region
            ?? realGeo.country
            ?? L("preflight.ipgps.your_area", fallback: "your area")
        let shownSpoofedCity = spoofedCity
            ?? L("preflight.ipgps.the_target", fallback: "the target")

        // If we somehow resolved the SAME city name despite the distance gate, don't nag.
        if let spoofedCity, spoofedCity.caseInsensitiveCompare(realCity) == .orderedSame {
            return nil
        }

        return LocationWarning(kind: .ipGpsMismatch(realCity: realCity, spoofedCity: shownSpoofedCity))
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
