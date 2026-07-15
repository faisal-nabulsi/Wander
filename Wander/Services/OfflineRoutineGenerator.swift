//
//  OfflineRoutineGenerator.swift
//  Wander
//
//  On-device fallback + cache for the Pro "believable day (AI)" feature. When the device is
//  offline (or the Worker call throws / times out), the app can't reach the Worker whose
//  Anthropic key lives SERVER-SIDE ONLY — this file never sees or embeds any secret and never
//  talks to any AI provider. Instead it produces a plausible weekday around a center coordinate
//  entirely on-device, in the EXACT shape the Worker returns (`[AIRoutinePlace]`), so the
//  existing routine UI slots in unchanged.
//
//  Two pieces live here:
//   • OfflineRoutineGenerator — a pure, network-free generator (Home → commute → work → gym →
//     errand → home) with small time/dwell jitter and pseudo-random bearings/distances.
//   • RoutineCacheStore — persists the last few REAL server routines to UserDefaults so the
//     offline path can PREFER a genuine past routine over a freshly-generated generic one.
//
//  Generic labels (Home/Office/Gym) are fine offline — the point is a believable movement
//  pattern, not real place names (which would need the network we don't have).
//

import Foundation
import CoreLocation

// MARK: - Offline generator

/// Pure, network-free generator that returns a believable weekday around a center coordinate.
/// Output is the same `[AIRoutinePlace]` shape the Worker returns so the routine sheet, replay,
/// and save paths all work unchanged.
enum OfflineRoutineGenerator {
    /// Build a believable day anchored at `center`. `style` is accepted for API parity with the
    /// Worker call but only lightly influences the day offline (we can't run a language model
    /// on-device); an empty/nil style yields the default balanced day.
    ///
    /// `namedPlaces` are the user's OWN saved spots. When supplied, the day is anchored on them
    /// via a simple name heuristic (see `roleFor`) so even the offline day uses REAL places —
    /// "home"/"house"/"apt"/"dorm" → the home/overnight anchor, "work"/"office"/"job" → the
    /// weekday work anchor, "school"/"college"/… → the daytime anchor, "gym"/"fitness" → the gym
    /// anchor, and anything else becomes an extra errand/social stop in order. Any role with no
    /// matching saved place falls back to the existing synthetic offset below.
    ///
    /// Layout (fallbacks): Home at `center`; Office 2–8 km away on a pseudo-random bearing; Gym
    /// 1–3 km away; plus a Cafe on the commute and an evening Errand. Distances/bearings and the
    /// small time/dwell jitter are seeded from the coordinate so the same spot yields a stable day
    /// (feels intentional, not random on every tap) while different spots differ.
    static func generate(at center: CLLocationCoordinate2D, style: String? = nil,
                         namedPlaces: [NamedPlace] = []) -> [AIRoutinePlace] {
        var rng = SeededGenerator(seed: seed(for: center, style: style))

        // Sort the user's saved spots into day roles by name. The first match for each single-slot
        // role wins; everything unmatched becomes an extra errand/social stop, in the user's order.
        var homePlace: NamedPlace?
        var workPlace: NamedPlace?
        var schoolPlace: NamedPlace?
        var gymPlace: NamedPlace?
        var extraStops: [NamedPlace] = []
        for np in namedPlaces {
            switch roleFor(np.name) {
            case .home:   if homePlace == nil { homePlace = np } else { extraStops.append(np) }
            case .work:   if workPlace == nil { workPlace = np } else { extraStops.append(np) }
            case .school: if schoolPlace == nil { schoolPlace = np } else { extraStops.append(np) }
            case .gym:    if gymPlace == nil { gymPlace = np } else { extraStops.append(np) }
            case .other:  extraStops.append(np)
            }
        }

        // Anchor points around Home. Bearings are spread so Office/Gym/Cafe don't stack up.
        let officeBearing = Double.random(in: 0..<360, using: &rng)
        let officeKm = Double.random(in: 2...8, using: &rng)
        let gymBearing = (officeBearing + Double.random(in: 90...180, using: &rng)).truncatingRemainder(dividingBy: 360)
        let gymKm = Double.random(in: 1...3, using: &rng)
        // Cafe sits roughly on the way to the office (a short hop along the commute bearing).
        let cafeBearing = (officeBearing + Double.random(in: -25...25, using: &rng)).truncatingRemainder(dividingBy: 360)
        let cafeKm = min(officeKm * Double.random(in: 0.4...0.7, using: &rng), officeKm - 0.3)
        // Errand is its own little detour from home in the evening.
        let errandBearing = Double.random(in: 0..<360, using: &rng)
        let errandKm = Double.random(in: 0.8...2.5, using: &rng)

        // Home anchors the whole day: prefer the user's saved home, else the requested center.
        let home = homePlace.map(coord(of:)) ?? center
        let cafe = offset(from: home, km: cafeKm, bearingDegrees: cafeBearing)
        // Prefer the user's saved work/school as the daytime anchor; fall back to a synthetic
        // office. A school takes priority over work for the daytime slot when both exist.
        let daytimePlace = workPlace ?? schoolPlace
        let office = daytimePlace.map(coord(of:)) ?? offset(from: home, km: officeKm, bearingDegrees: officeBearing)
        let gym = gymPlace.map(coord(of:)) ?? offset(from: office, km: gymKm, bearingDegrees: gymBearing)
        let errand = offset(from: home, km: errandKm, bearingDegrees: errandBearing)

        // Labels/kinds follow the real saved place when we anchored on one, else the generic copy.
        let homeLabel = homePlace?.name ?? L("routine.home", fallback: "Home")
        // A saved school (with no saved work) makes the daytime anchor a school; otherwise it's work.
        let anchoredSchool = (workPlace == nil && schoolPlace != nil)
        let daytimeLabel = daytimePlace?.name
            ?? (anchoredSchool ? L("routine.school", fallback: "School")
                               : L("routine.office", fallback: "Office"))
        let daytimeKind = anchoredSchool ? "school" : "work"
        let gymLabel = gymPlace?.name ?? L("routine.gym", fallback: "Gym")

        // Minutes of jitter so start/end times aren't robotically identical each run.
        let wakeJitter = Int.random(in: -20...20, using: &rng)
        let commuteJitter = Int.random(in: -10...15, using: &rng)
        let gymJitter = Int.random(in: -15...25, using: &rng)

        // A weekday, in wall-clock minutes past midnight, with dwell built into arrive/depart.
        var places: [AIRoutinePlace] = [
            place(label: homeLabel, kind: "home",
                  coord: home,
                  arriveMin: nil,                                  // already home overnight
                  departMin: 8 * 60 + 5 + wakeJitter),            // leaves ~8:05 AM
            place(label: L("routine.cafe", fallback: "Morning Coffee"), kind: "cafe",
                  coord: cafe,
                  arriveMin: 8 * 60 + 20 + commuteJitter,
                  departMin: 8 * 60 + 40 + commuteJitter),
            place(label: daytimeLabel, kind: daytimeKind,
                  coord: office,
                  arriveMin: 9 * 60 + commuteJitter,               // ~9:00 AM
                  departMin: 17 * 60 + commuteJitter),             // ~5:00 PM
            place(label: gymLabel, kind: "gym",
                  coord: gym,
                  arriveMin: 17 * 60 + 30 + gymJitter,
                  departMin: 18 * 60 + 45 + gymJitter),
        ]

        // Evening errand/social stops: prefer the user's leftover saved spots (in order),
        // otherwise the single synthetic errand. Each gets a ~30 min visit, chained in time.
        var errandArrive = 19 * 60 + 10 + gymJitter
        if extraStops.isEmpty {
            places.append(place(label: L("routine.errand", fallback: "Errand"), kind: "shop",
                                coord: errand,
                                arriveMin: errandArrive,
                                departMin: errandArrive + 30))
        } else {
            // Cap the number of evening stops so the day stays believable (not a 12-stop marathon).
            for np in extraStops.prefix(3) {
                places.append(place(label: np.name, kind: "shop",
                                    coord: coord(of: np),
                                    arriveMin: errandArrive,
                                    departMin: errandArrive + 30))
                errandArrive += 45   // ~30 min visit + ~15 min hop to the next
            }
        }

        // Back home for the evening, after the last evening stop.
        places.append(place(label: homeLabel, kind: "home",
                            coord: home,
                            arriveMin: max(20 * 60 + gymJitter, errandArrive + 20),
                            departMin: nil))
        return places
    }

    // MARK: Named-place roles

    /// The day-role a saved place maps to, from its name (per the shared contract heuristic).
    private enum PlaceRole { case home, work, school, gym, other }

    /// Classify a saved place by simple name keywords. Order matters only in that each keyword
    /// group is checked independently; the first single-slot match in the user's list wins upstream.
    private static func roleFor(_ name: String) -> PlaceRole {
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { n.contains($0) } }
        if has(["home", "house", "apt", "dorm"]) { return .home }
        if has(["work", "office", "job"]) { return .work }
        if has(["school", "college", "class", "campus", "uni"]) { return .school }
        if has(["gym", "fitness"]) { return .gym }
        return .other
    }

    /// A saved place's coordinate.
    private static func coord(of np: NamedPlace) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: np.lat, longitude: np.lng)
    }

    // MARK: Place construction

    /// Build one `AIRoutinePlace`, formatting the optional arrive/depart minutes into the same
    /// human-readable clock strings the Worker returns (e.g. "9:00 AM"). The UI never parses
    /// these — it only displays them — so matching the format keeps the sheet identical.
    private static func place(label: String, kind: String,
                              coord: CLLocationCoordinate2D,
                              arriveMin: Int?, departMin: Int?) -> AIRoutinePlace {
        AIRoutinePlace(
            label: label,
            kind: kind,
            coordinate: coord,
            arrive: arriveMin.map(clockString),
            depart: departMin.map(clockString)
        )
    }

    /// Minutes-past-midnight → "h:mm AM/PM", matching the Worker's arrive/depart strings.
    private static func clockString(_ minutesPastMidnight: Int) -> String {
        let wrapped = ((minutesPastMidnight % 1440) + 1440) % 1440
        let hour24 = wrapped / 60
        let minute = wrapped % 60
        let isPM = hour24 >= 12
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return String(format: "%d:%02d %@", hour12, minute, isPM ? "PM" : "AM")
    }

    // MARK: Geometry (km → degrees, per the feature spec)

    /// Move `km` from `origin` along a compass `bearingDegrees` (0 = North, 90 = East).
    /// Uses the flat-earth km→deg approximation from the spec — good enough for a few km:
    ///   dLat = km / 111.0 ; dLng = km / (111.0 * cos(lat)).
    private static func offset(from origin: CLLocationCoordinate2D,
                               km: Double, bearingDegrees: Double) -> CLLocationCoordinate2D {
        let bearing = bearingDegrees * .pi / 180
        let north = km * cos(bearing)   // km along latitude
        let east = km * sin(bearing)    // km along longitude
        let dLat = north / 111.0
        let cosLat = cos(origin.latitude * .pi / 180)
        // Guard the poles: cos(lat) → 0 makes dLng blow up; clamp the denominator.
        let dLng = east / (111.0 * max(abs(cosLat), 0.01))
        return CLLocationCoordinate2D(latitude: origin.latitude + dLat,
                                      longitude: origin.longitude + dLng)
    }

    // MARK: Seeding

    /// A stable 64-bit seed from the coordinate (quantized so nearby taps share a day) plus the
    /// style text, so the same place+style yields the same believable day across launches.
    private static func seed(for center: CLLocationCoordinate2D, style: String?) -> UInt64 {
        // Quantize to ~100 m so tiny pan jitter doesn't reshuffle the whole day.
        let latKey = Int64((center.latitude * 1000).rounded())
        let lngKey = Int64((center.longitude * 1000).rounded())
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        func mix(_ value: UInt64) {
            hash ^= value
            hash = hash &* 1099511628211
        }
        mix(UInt64(bitPattern: latKey))
        mix(UInt64(bitPattern: lngKey))
        for byte in (style ?? "").utf8 { mix(UInt64(byte)) }
        return hash == 0 ? 0x9E3779B97F4A7C15 : hash
    }
}

// Note: the deterministic RNG used above is `SeededGenerator` (a `RandomNumberGenerator`
// conformer defined in FlightPlannerView.swift) — reused here so the offline day is reproducible
// from its seed without a second copy of the same tiny RNG.

// MARK: - Cache of real server routines

/// One cached real routine: the stops plus the coordinate/style it was generated for and when.
/// Codable because `AIRoutinePlace` (with its `CLLocationCoordinate2D`) isn't, so we mirror the
/// fields into a plain struct for persistence and rehydrate on load.
private struct CachedRoutine: Codable {
    struct Stop: Codable {
        var label: String
        var kind: String?
        var lat: Double
        var lng: Double
        var arrive: String?
        var depart: String?
    }
    var lat: Double
    var lng: Double
    var style: String?
    var savedAt: Double            // unixtime seconds
    var stops: [Stop]

    var places: [AIRoutinePlace] {
        stops.map {
            AIRoutinePlace(label: $0.label, kind: $0.kind,
                           coordinate: CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng),
                           arrive: $0.arrive, depart: $0.depart)
        }
    }
}

/// Persists the last few REAL (server-generated) routines so the offline fallback can hand back
/// a genuine past day instead of a generic on-device one. Small, self-contained, and mirrors the
/// UserDefaults + JSON pattern the other stores (SavedRoutes/SavedPlaces) use.
enum RoutineCacheStore {
    private static let key = "aiRoutineCache"
    private static let maxEntries = 5

    /// Save a successful SERVER routine. Newest first, capped at `maxEntries`. Called only on the
    /// online success path — generated offline days are never cached (we don't want generic days
    /// masquerading as real AI ones next time).
    static func save(_ places: [AIRoutinePlace],
                     at center: CLLocationCoordinate2D,
                     style: String?) {
        guard !places.isEmpty else { return }
        let entry = CachedRoutine(
            lat: center.latitude,
            lng: center.longitude,
            style: (style?.isEmpty ?? true) ? nil : style,
            savedAt: Date().timeIntervalSince1970,
            stops: places.map {
                CachedRoutine.Stop(label: $0.label, kind: $0.kind,
                                   lat: $0.coordinate.latitude, lng: $0.coordinate.longitude,
                                   arrive: $0.arrive, depart: $0.depart)
            }
        )
        var all = loadEntries()
        all.insert(entry, at: 0)
        if all.count > maxEntries { all = Array(all.prefix(maxEntries)) }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// True when at least one real routine is cached — lets the UI decide whether to surface a
    /// "recent routines" affordance.
    static var hasCached: Bool { !loadEntries().isEmpty }

    /// All cached routines (newest first) as ready-to-display places, for a "recent" list.
    static func recent() -> [[AIRoutinePlace]] {
        loadEntries().map { $0.places }
    }

    /// Best cached routine for the offline fallback: prefer the most recent one whose center is
    /// reasonably near the requested `center` (so a cached day for another city isn't reused far
    /// away); otherwise fall back to the plain most-recent cached routine. Returns nil when the
    /// cache is empty so the caller can drop to the generator.
    static func best(near center: CLLocationCoordinate2D, maxKm: Double = 60) -> [AIRoutinePlace]? {
        let entries = loadEntries()
        guard !entries.isEmpty else { return nil }
        let nearby = entries.first { approxKm(from: center, toLat: $0.lat, lng: $0.lng) <= maxKm }
        return (nearby ?? entries.first)?.places
    }

    // MARK: Internals

    private static func loadEntries() -> [CachedRoutine] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CachedRoutine].self, from: data) else { return [] }
        return decoded
    }

    /// Cheap flat-earth distance (km) — only used to rank cached routines by proximity.
    private static func approxKm(from center: CLLocationCoordinate2D, toLat lat: Double, lng: Double) -> Double {
        let dLat = (lat - center.latitude) * 111.0
        let cosLat = cos(center.latitude * .pi / 180)
        let dLng = (lng - center.longitude) * 111.0 * max(abs(cosLat), 0.01)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }
}
