//
//  LocationInfoService.swift
//  Wander
//
//  Live "local time + weather" for the currently spoofed / selected location.
//  Fetches current conditions from Open-Meteo (free, no API key), derives the
//  destination's wall-clock time from its UTC offset, and ticks a lightweight
//  timer so the clock stays current while the card is on screen.
//
//  Fails silently: any network / decode error just leaves the last good info
//  in place (or nothing), so the map UI is never blocked by weather.
//

import Foundation
import CoreLocation
import SwiftUI
import Combine

// MARK: - Open-Meteo response

private struct OpenMeteoResponse: Decodable {
    let timezone: String?
    let utcOffsetSeconds: Int
    let current: Current

    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int
        let windSpeed10m: Double

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m"
        }
    }

    enum CodingKeys: String, CodingKey {
        case timezone
        case utcOffsetSeconds = "utc_offset_seconds"
        case current
    }
}

// MARK: - Weather code -> symbol/label (WMO)

private struct WeatherDescription {
    let symbol: String   // SF Symbol name
    let label: String
}

private func weatherDescription(for code: Int) -> WeatherDescription {
    switch code {
    case 0:
        return WeatherDescription(symbol: "sun.max.fill", label: "Clear")
    case 1, 2:
        return WeatherDescription(symbol: "cloud.sun.fill", label: "Partly cloudy")
    case 3:
        return WeatherDescription(symbol: "cloud.fill", label: "Overcast")
    case 45, 48:
        return WeatherDescription(symbol: "cloud.fog.fill", label: "Fog")
    case 51, 53, 55, 56, 57:
        return WeatherDescription(symbol: "cloud.drizzle.fill", label: "Drizzle")
    case 61, 63, 65, 66, 67:
        return WeatherDescription(symbol: "cloud.rain.fill", label: "Rain")
    case 71, 73, 75, 77:
        return WeatherDescription(symbol: "cloud.snow.fill", label: "Snow")
    case 80, 81, 82:
        return WeatherDescription(symbol: "cloud.heavyrain.fill", label: "Showers")
    case 85, 86:
        return WeatherDescription(symbol: "cloud.snow.fill", label: "Snow showers")
    case 95:
        return WeatherDescription(symbol: "cloud.bolt.fill", label: "Thunderstorm")
    case 96, 99:
        return WeatherDescription(symbol: "cloud.bolt.rain.fill", label: "Thunderstorm & hail")
    default:
        return WeatherDescription(symbol: "cloud.fill", label: "—")
    }
}

// MARK: - Published snapshot

/// A decoded, display-ready snapshot for one location. `Equatable` so the
/// SwiftUI card only redraws when something actually changed.
struct LocationInfo: Equatable {
    let timeZoneName: String
    let utcOffsetSeconds: Int
    let temperatureCelsius: Double
    let windSpeedKmh: Double
    let weatherSymbol: String
    let weatherLabel: String

    /// e.g. "3:45 PM" for the destination's wall-clock time at `date`.
    func localTimeString(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        // Build a fixed-offset zone from the destination's UTC offset so the
        // formatted components reflect the *remote* wall clock, not the phone's.
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .current
        return formatter.string(from: date)
    }

    /// A short timezone label, e.g. "Europe/Paris".
    var timeZoneDisplay: String {
        timeZoneName.isEmpty ? "GMT" : timeZoneName
    }

    var temperatureString: String {
        let celsius = temperatureCelsius.rounded()
        let fahrenheit = (temperatureCelsius * 9 / 5 + 32).rounded()
        return "\(Int(celsius))°C / \(Int(fahrenheit))°F"
    }

    var windString: String {
        "\(Int(windSpeedKmh.rounded())) km/h"
    }

    /// True when this location's UTC offset differs from the device's current
    /// time-zone offset by more than ~1 hour. Purely informational: Wander can't
    /// change the device time zone, but some apps compare the two.
    var deviceTimeZoneMismatch: Bool {
        let deviceOffset = TimeZone.current.secondsFromGMT()
        return abs(utcOffsetSeconds - deviceOffset) > 3600
    }

    /// A human-friendly label for the *device's* current time zone, e.g.
    /// "Los Angeles (PDT)". Used in the mismatch advisory so the user can see at
    /// a glance what their phone still reports.
    var deviceTimeZoneDisplay: String {
        let zone = TimeZone.current
        let city = zone.identifier
            .split(separator: "/").last
            .map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier
        let abbrev = zone.abbreviation() ?? ""
        return abbrev.isEmpty ? city : "\(city) (\(abbrev))"
    }
}

// MARK: - Where you are, in words

/// A short human label for one coordinate: what a person would SAY if you asked
/// them where the pin is. `title` is the headline ("Mission District, San
/// Francisco"); `detail` is an optional finer line (a street, or a named park)
/// that is only ever additive — a caller that shows just the title is always
/// correct.
///
/// `isApproximate` is true when the label came from the bundled offline gazetteer
/// instead of Apple's geocoder. That answer is the NEAREST KNOWN PLACE, which can
/// be several kilometres away, so anything showing it must read as "near X" and
/// never as a street-accurate address. `title` already carries that wording; the
/// flag exists so a caller can style it (dimmer, an "approx." badge) and so the
/// store knows the entry is worth upgrading once the geocoder answers again.
struct PlaceLabel: Equatable {
    let title: String
    let detail: String?
    let isApproximate: Bool

    /// One-line form: "Mission District, San Francisco · Castro St".
    var display: String {
        guard let detail, !detail.isEmpty else { return title }
        return "\(title) · \(detail)"
    }
}

/// Reverse geocoding for the whole app: coordinate in, human words out.
///
/// Why this is a shared, heavily-gated singleton and not a `CLGeocoder` call at
/// the call site: `CLGeocoder` is a per-PROCESS, server-side rate-limited
/// resource. It answers a short burst and then rejects *everything* for a while —
/// so an ungated caller doesn't just fail itself, it takes the budget away from
/// Places, the destination clocks and the search header too. Everything here is
/// therefore built to spend as few requests as possible:
///
///   * one lookup per ~110 m cell, cached for the life of the process;
///   * misses cached exactly like hits, so an unnameable spot asks once;
///   * one request in flight at a time, with a gap between them;
///   * a run of failures pauses the geocoder entirely for five minutes;
///   * while paused (or offline) the answer comes from the bundled gazetteer.
///
/// It never blocks: `label(for:)` is a pure dictionary read that returns nil until
/// an answer exists, and callers are expected to keep showing raw coordinates
/// until it does. That is the deliberate degradation — a spoofer's status chip
/// showing a stale or invented place name is worse than one showing numbers, and
/// a spinner where the location should be reads as "the spoof is broken".
@MainActor
final class PlaceLabelService: ObservableObject {
    static let shared = PlaceLabelService()

    /// Resolved labels keyed by coordinate cell. `@Published` so any view holding
    /// the service redraws the moment an answer lands.
    @Published private(set) var labels: [String: PlaceLabel] = [:]

    /// Cells the geocoder answered for with nothing usable (mid-ocean, Antarctica).
    /// A property of the point, so we remember it and never ask again.
    private var misses: Set<String> = []
    /// Insertion order of decided cells, so the cache stays bounded for a user who
    /// pans a lot.
    private var order: [String] = []
    private var queue: [(key: String, coordinate: CLLocationCoordinate2D)] = []
    private var draining = false
    /// Consecutive thrown geocoder errors. A run means "the rate limiter is on",
    /// not "these coordinates have no name".
    private var failureStreak = 0
    private var pausedUntil: Date?

    private let geocoder = CLGeocoder()

    private static let maxEntries = 96
    private static let maxQueued = 16
    private static let requestSpacing: TimeInterval = 0.5
    private static let pauseAfterFailures: TimeInterval = 5 * 60

    private init() {}

    // MARK: Reading (pure — safe to call from a view body)

    /// ~110 m buckets. Coarse enough that a walking spoof doesn't re-ask every
    /// step, fine enough that two ends of a neighbourhood don't collapse into one
    /// answer.
    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    /// The label for this coordinate, or nil if we don't know it yet. PURE: it
    /// starts no work and mutates nothing, so it is safe inside a view body.
    /// Call `resolve(_:)` from `.onAppear` / `.onChange` to start the lookup.
    func label(for coordinate: CLLocationCoordinate2D) -> PlaceLabel? {
        labels[Self.key(for: coordinate)]
    }

    /// The coordinate rendered the way the app already renders it. This is the
    /// fallback every caller degrades to — never a spinner, never a guess.
    static func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    /// Words if we have them, coordinates if we don't. The one-line adoption path.
    func displayText(for coordinate: CLLocationCoordinate2D) -> String {
        label(for: coordinate)?.display ?? Self.coordinateText(coordinate)
    }

    // MARK: Resolving (fire-and-forget)

    /// Ask for a label. Returns immediately; the answer arrives later through
    /// `labels`. Cheap and idempotent, so calling it on every location update is
    /// fine — repeats inside the same cell are dropped by a dictionary lookup.
    func resolve(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let key = Self.key(for: coordinate)

        // A miss is final, even if a coarse offline label is still on screen for this
        // cell: the geocoder has already told us there is nothing better here.
        if misses.contains(key) { return }

        if let existing = labels[key] {
            // Only one reason to re-ask about a cell we've answered: the answer is
            // the coarse offline one and the geocoder is available again, so we can
            // upgrade "near Berkeley" to the real street.
            guard existing.isApproximate, canUseGeocoder else { return }
        }

        guard !queue.contains(where: { $0.key == key }) else { return }
        guard queue.count < Self.maxQueued else { return }
        queue.append((key, coordinate))
        drain()
    }

    /// Convenience for the many call sites that hold lat/lng doubles.
    func resolve(lat: Double, lng: Double) {
        resolve(CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    /// True when Apple's geocoder is worth trying at all right now.
    private var canUseGeocoder: Bool {
        if let pausedUntil, pausedUntil > Date() { return false }
        return NetworkReachability.hasInternetSnapshot
    }

    /// Serial drain: one request at a time with a gap between them, detached from
    /// whatever view update queued it so nothing here can stall a frame.
    private func drain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            defer { draining = false }
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let usedNetwork = await resolveOne(key: next.key, coordinate: next.coordinate)
                if usedNetwork {
                    try? await Task.sleep(nanoseconds: UInt64(Self.requestSpacing * 1_000_000_000))
                }
            }
        }
    }

    /// Resolve one cell. Returns true if it spent a CLGeocoder request (so the
    /// caller paces itself); an offline-gazetteer answer costs nothing and needs
    /// no gap.
    @discardableResult
    private func resolveOne(key: String, coordinate: CLLocationCoordinate2D) async -> Bool {
        if canUseGeocoder {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                // It answered: the rate limiter is clearly not on us.
                failureStreak = 0
                if let placemark = placemarks.first,
                   let label = Self.label(from: placemark) {
                    record(key, label: label)
                } else {
                    // Answered with nothing nameable — that IS a property of the
                    // point (open ocean), so remember it instead of re-asking.
                    record(key, label: nil)
                }
                return true
            } catch {
                // A THROWN error says nothing about this coordinate — it's the rate
                // limiter or a dropped connection. Never blacklist the key; back off
                // and fall through to the offline answer below.
                failureStreak += 1
                if failureStreak >= 3 {
                    pausedUntil = Date().addingTimeInterval(Self.pauseAfterFailures)
                }
                await resolveOffline(key: key, coordinate: coordinate)
                return true
            }
        }

        await resolveOffline(key: key, coordinate: coordinate)
        return false
    }

    /// Offline / rate-limited fallback: nearest entry in the bundled gazetteer, via
    /// `OfflineGeocoder`'s single shared table (the same rows natural-language teleport
    /// searches — one parse, one copy in memory).
    ///
    /// Runs off the main actor: the first call may parse the 3.5 MB bundled file, and the scan
    /// is linear over ~77k rows. Only the two strings we display cross back.
    private func resolveOffline(key: String, coordinate: CLLocationCoordinate2D) async {
        // Passed as plain doubles rather than the coordinate struct so nothing non-Sendable
        // crosses the actor hop.
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        let nearest = await Task.detached(priority: .utility) { () -> (name: String, subtitle: String)? in
            let point = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            guard let hit = OfflineGeocoder.nearest(to: point) else { return nil }
            return (hit.name, hit.subtitle)
        }.value

        guard let nearest else {
            // Nothing within range (open ocean, deep desert). Deliberately NOT
            // recorded as a miss: the online geocoder may well have a name for it,
            // and this cell should stay eligible for the next attempt.
            return
        }

        // "Near" is load-bearing, and the wording is built HERE rather than in the
        // background scan: `L()` reads the app's language bundle, which is main-actor
        // state, and this string is the one the user reads.
        let label = PlaceLabel(
            title: String(format: L("place.label.near", fallback: "Near %@"), nearest.name),
            detail: nearest.subtitle.isEmpty ? nil : nearest.subtitle,
            isApproximate: true
        )
        record(key, label: label, cacheable: false)
    }

    /// Commit a decision for `key` — a label, or nil meaning "there is no name
    /// here, stop asking" — and evict the oldest decisions past the cap.
    ///
    /// `cacheable: false` marks a result that may be replaced later (the coarse
    /// offline answer), so it doesn't consume a "decided" slot twice on upgrade.
    private func record(_ key: String, label: PlaceLabel?, cacheable: Bool = true) {
        let alreadyDecided = labels[key] != nil || misses.contains(key)
        if let label {
            labels[key] = label
            misses.remove(key)
        } else if cacheable {
            misses.insert(key)
            // Keep a coarse offline answer if we already have one — "near Reykjavík"
            // beats nothing for a pin the online geocoder has no name for. Anything
            // more precise is dropped, because a miss means we can no longer stand
            // behind it.
            if labels[key]?.isApproximate != true {
                labels.removeValue(forKey: key)
            }
        }
        guard !alreadyDecided else { return }
        order.append(key)
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            labels.removeValue(forKey: oldest)
            misses.remove(oldest)
        }
    }

    // MARK: Placemark -> words

    /// Turn a CLPlacemark into the shortest phrase that still identifies the spot.
    /// Returns nil when the placemark carries nothing a person would recognise,
    /// which the caller records as a miss rather than showing an empty chip.
    static func label(from placemark: CLPlacemark) -> PlaceLabel? {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        let neighbourhood = clean(placemark.subLocality)
        let city = clean(placemark.locality)
        let region = clean(placemark.administrativeArea)
        let country = clean(placemark.country)
        let interest = placemark.areasOfInterest?.compactMap(clean).first
        let street = clean(placemark.thoroughfare)
        let number = clean(placemark.subThoroughfare)
        let water = clean(placemark.inlandWater) ?? clean(placemark.ocean)

        // Most specific pairing a person would actually say, in order.
        let title: String
        if let neighbourhood, let city, neighbourhood != city {
            title = "\(neighbourhood), \(city)"
        } else if let city, let region, city != region {
            title = "\(city), \(region)"
        } else if let city {
            title = city
        } else if let neighbourhood {
            title = neighbourhood
        } else if let interest {
            title = interest
        } else if let water {
            // An honest answer for a pin dropped at sea — and a useful warning that
            // the chosen spot is water, not a street.
            title = water
        } else if let region, let country, region != country {
            title = "\(region), \(country)"
        } else if let region {
            title = region
        } else if let country {
            title = country
        } else {
            return nil
        }

        // The finer line: the street (with a number when there is one), otherwise a
        // named landmark the title didn't already use.
        var detail: String?
        if let street {
            detail = number.map { "\($0) \(street)" } ?? street
        } else if let interest, interest != title {
            detail = interest
        }

        return PlaceLabel(title: title, detail: detail, isApproximate: false)
    }
}

// MARK: - Service

@MainActor
final class LocationInfoService: ObservableObject {
    /// The decoded weather / timezone snapshot, or nil until a location is set.
    @Published private(set) var info: LocationInfo?
    /// Drives the ticking clock; updated by the timer roughly every 10s.
    @Published private(set) var now: Date = Date()
    /// The human label for the location this service is currently describing, or
    /// nil while it is unknown (the caller keeps showing coordinates). Mirrors
    /// `PlaceLabelService.shared` so a screen that already holds this service
    /// doesn't have to observe a second object.
    @Published private(set) var placeLabel: PlaceLabel?

    private var fetchTask: Task<Void, Never>?
    private var clockTimer: Timer?
    /// The anchor the weather debounce measures against: the last coordinate we actually
    /// FETCHED for, never simply the last one we were told about. Rebasing it on every call
    /// would let a run of sub-epsilon steps travel any distance without ever tripping the
    /// threshold, so a per-tick caller (walk / route playback) would never refresh.
    private var lastCoordinate: CLLocationCoordinate2D?
    /// The coordinate we are currently DESCRIBING. Separate from the debounce anchor because
    /// the label follows the pin immediately even when the weather fetch is debounced away.
    private var labelCoordinate: CLLocationCoordinate2D?
    private var labelSubscription: AnyCancellable?

    /// Ignore repeat refreshes for essentially the same spot (~11 m).
    private let coordinateEpsilon = 0.0001

    init() {
        // Republish the shared store's answer for whichever coordinate we're on.
        // DispatchQueue, not RunLoop: RunLoop.main only delivers in the default mode, so a
        // label resolved while the user is mid-scroll would sit queued until the gesture
        // ended and then pop in. This lands on the next main-queue turn regardless.
        labelSubscription = PlaceLabelService.shared.$labels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] labels in
                guard let self, let coordinate = self.labelCoordinate else { return }
                let label = labels[PlaceLabelService.key(for: coordinate)]
                if self.placeLabel != label { self.placeLabel = label }
            }
    }

    deinit {
        clockTimer?.invalidate()
    }

    /// Fetch weather + timezone for a location. Debounces identical coordinates,
    /// runs the network off the main actor, and publishes on the main actor.
    /// Fails silently on any error.
    func refresh(lat: Double, lng: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)

        // Words for this spot. Deliberately ahead of the weather debounce below: the label is
        // what the UI leads with, it's cached per ~110 m cell inside the shared store, and a
        // repeat call for a known cell costs one dictionary lookup.
        labelCoordinate = coordinate
        placeLabel = PlaceLabelService.shared.label(for: coordinate)
        PlaceLabelService.shared.resolve(coordinate)

        if let last = lastCoordinate,
           abs(last.latitude - lat) < coordinateEpsilon,
           abs(last.longitude - lng) < coordinateEpsilon,
           info != nil {
            return
        }

        // Only now, past the gate: the anchor tracks the last coordinate we FETCHED for, so a
        // long walk taken in sub-epsilon steps still crosses the threshold and refreshes.
        lastCoordinate = coordinate

        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            guard let response = await Self.fetch(lat: lat, lng: lng) else { return }
            guard !Task.isCancelled else { return }

            let description = weatherDescription(for: response.current.weatherCode)
            let snapshot = LocationInfo(
                timeZoneName: response.timezone ?? "",
                utcOffsetSeconds: response.utcOffsetSeconds,
                temperatureCelsius: response.current.temperature2m,
                windSpeedKmh: response.current.windSpeed10m,
                weatherSymbol: description.symbol,
                weatherLabel: description.label
            )

            await MainActor.run {
                guard let self else { return }
                self.info = snapshot
                self.now = Date()
                self.startClock()
            }
        }
    }

    /// Clear the card (e.g. when a simulation is stopped).
    func clear() {
        fetchTask?.cancel()
        fetchTask = nil
        clockTimer?.invalidate()
        clockTimer = nil
        lastCoordinate = nil
        labelCoordinate = nil
        info = nil
        placeLabel = nil
    }

    // MARK: - Clock

    private func startClock() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    /// Fetch just the current WMO weather code for a location, off the main
    /// actor. Used by weather-aware route pacing to pick a speed multiplier once
    /// at route start. Returns `nil` on any error so the caller can no-op.
    nonisolated static func fetchWeatherCode(lat: Double, lng: Double) async -> Int? {
        await fetch(lat: lat, lng: lng)?.current.weatherCode
    }

    // MARK: - Networking (off the main actor)

    private nonisolated static func fetch(lat: Double, lng: Double) async -> OpenMeteoResponse? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lng)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let url = components?.url else { return nil }

        // Bounded timeout so a dropped connection can't leave the fetch hanging on the default
        // 60s — the card just stays hidden and we quietly try again on the next location change.
        let request = URLRequest(url: url, timeoutInterval: 15)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return nil
            }
            return try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            return nil   // fail silently
        }
    }
}

// MARK: - Card view

/// A compact "local time + weather" card for the destination. Hidden until a
/// location has been resolved. Matches the app's floating-card design language.
struct LocationInfoCard: View {
    @ObservedObject var service: LocationInfoService

    /// The user dismissed the time-zone advisory once — don't nag again this session.
    @State private var tzAdvisoryDismissed = false
    /// Reveals the (collapsed by default) IP / VPN alignment tip.
    @State private var showIPTip = false
    @Environment(\.openURL) private var openURL

    /// Wander's VPN / IP-matching guide (parity with the desktop "Match your IP" card).
    private let vpnGuideURL = URL(string: "https://wanderspoofer.com/vpn/")

    var body: some View {
        if let info = service.info {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    // Where this is, in words. Absent until the geocoder answers —
                    // the row simply isn't there rather than showing a spinner, and
                    // the coordinate stays visible elsewhere in the UI throughout.
                    if let place = service.placeLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "mappin.and.ellipse")
                                .foregroundStyle(Wander.brand)
                            Text(place.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if let detail = place.detail {
                                Text("· \(detail)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(Wander.brand)
                        Text(info.localTimeString(at: service.now))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        Text("· \(info.timeZoneDisplay)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: info.weatherSymbol)
                            .foregroundStyle(Wander.brand)
                            .symbolRenderingMode(.multicolor)
                        Text(info.weatherLabel)
                            .font(.caption)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.temperatureString)
                            .font(.caption.monospacedDigit())
                        Image(systemName: "wind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(info.windString)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            // Calm, dismissible time-zone advisory (not an error). Names the
            // device's current zone so the user knows exactly what to change.
            if info.deviceTimeZoneMismatch && !tzAdvisoryDismissed {
                Divider().padding(.vertical, 2)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(
                            format: L(
                                "locationinfo.tz_advisory",
                                fallback: "Your device's time zone still reads %@. Some apps compare it to your GPS — consider matching it in Settings › General › Date & Time."
                            ),
                            info.deviceTimeZoneDisplay
                        ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { tzAdvisoryDismissed = true }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("locationinfo.tz_advisory.dismiss", fallback: "Dismiss time zone tip"))
                }
            }

            // IP / VPN alignment tip — parity with the desktop "Match your IP"
            // card. Collapsed by default so it never nags; one tap reveals it.
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation { showIPTip.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.caption)
                            .foregroundStyle(Wander.brand)
                        Text(L("locationinfo.ip_tip.title", fallback: "Match your IP & time zone"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: showIPTip ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showIPTip {
                    Text(L(
                        "locationinfo.ip_tip.body",
                        fallback: "For the most believable location, your IP address and time zone should match your spoofed GPS. Some apps cross-check them. A VPN set to the destination region keeps them aligned."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let vpnGuideURL {
                        Button {
                            openURL(vpnGuideURL)
                        } label: {
                            HStack(spacing: 4) {
                                Text(L("locationinfo.ip_tip.link", fallback: "How IP matching works"))
                                Image(systemName: "arrow.up.right.square")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Wander.brand)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
