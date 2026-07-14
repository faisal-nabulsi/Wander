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
}

// MARK: - Service

@MainActor
final class LocationInfoService: ObservableObject {
    /// The decoded weather / timezone snapshot, or nil until a location is set.
    @Published private(set) var info: LocationInfo?
    /// Drives the ticking clock; updated by the timer roughly every 10s.
    @Published private(set) var now: Date = Date()

    private var fetchTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var lastCoordinate: CLLocationCoordinate2D?

    /// Ignore repeat refreshes for essentially the same spot (~11 m).
    private let coordinateEpsilon = 0.0001

    deinit {
        clockTimer?.invalidate()
    }

    /// Fetch weather + timezone for a location. Debounces identical coordinates,
    /// runs the network off the main actor, and publishes on the main actor.
    /// Fails silently on any error.
    func refresh(lat: Double, lng: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)

        if let last = lastCoordinate,
           abs(last.latitude - lat) < coordinateEpsilon,
           abs(last.longitude - lng) < coordinateEpsilon,
           info != nil {
            return
        }
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
        info = nil
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

    var body: some View {
        if let info = service.info {
            VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
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

            if info.deviceTimeZoneMismatch {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text(L(
                        "locationinfo.tz_mismatch",
                        fallback: "Your device time zone doesn't match this location — some apps compare the two."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
