//
//  FlightPlannerView.swift
//  Wander
//
//  FREE, no-API flight planner. Pick a DEPARTURE and an ARRIVAL airport from the
//  bundled dataset (searchable by IATA code / name), optionally enter a time range
//  to generate plausible flights between them, then "Fly it" — which hands the two
//  airport coordinates back to Route mode as the PLANE-mode endpoints and starts the
//  existing great-circle plane playback (~850 km/h). No altitude on iOS (as noted).
//

import SwiftUI
import CoreLocation

/// One airport row from the bundled `airports.json` dataset. Keys are terse to keep
/// the file small: i=IATA, n=name, c=country, y=lat, x=lon, L=1 (large/major).
struct Airport: Decodable, Identifiable, Hashable {
    let iata: String
    let name: String
    let country: String
    let lat: Double
    let lon: Double

    var id: String { iata }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Compact "CODE — Name (Country)" label used in the pickers.
    var displayLabel: String { "\(iata) — \(name)" }

    enum CodingKeys: String, CodingKey {
        case iata = "i"
        case name = "n"
        case country = "c"
        case lat = "y"
        case lon = "x"
    }
}

/// Loads and searches the bundled airport dataset. The full list is parsed once and
/// cached; searches filter by IATA code (prefix-weighted) or name substring.
enum AirportDataset {
    /// Parsed once, lazily, from the app bundle. Empty if the resource is missing.
    static let all: [Airport] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let airports = try? JSONDecoder().decode([Airport].self, from: data) else {
            return []
        }
        return airports
    }()

    /// Rank matches so an exact/prefix IATA code beats a name substring hit. Capped so
    /// the results list stays snappy while typing.
    static func search(_ query: String, limit: Int = 40) -> [Airport] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !q.isEmpty else { return Array(all.prefix(limit)) }

        var scored: [(Airport, Int)] = []
        for airport in all {
            let code = airport.iata.uppercased()
            let name = airport.name.uppercased()
            let country = airport.country.uppercased()
            var score = Int.max
            if code == q { score = 0 }
            else if code.hasPrefix(q) { score = 1 }
            else if name.hasPrefix(q) { score = 2 }
            else if name.contains(q) { score = 3 }
            else if country == q { score = 4 }
            if score != Int.max { scored.append((airport, score)) }
        }
        return scored
            .sorted { lhs, rhs in
                lhs.1 != rhs.1 ? lhs.1 < rhs.1 : lhs.0.name < rhs.0.name
            }
            .prefix(limit)
            .map(\.0)
    }
}

/// A generated, plausible flight between two airports for a chosen time range.
struct GeneratedFlight: Identifiable, Hashable {
    let id = UUID()
    let flightNumber: String
    let departure: Date
    let arrival: Date

    func timeLabel(_ formatter: DateFormatter) -> String {
        "\(formatter.string(from: departure)) → \(formatter.string(from: arrival))"
    }
}

enum FlightMath {
    /// Cruise speed the PLANE mode flies at, in km/h — kept in sync with Route mode's
    /// plane cruise (~850 km/h) so the generated ETA matches the actual playback pace.
    static let cruiseKmh: Double = 850

    /// Great-circle distance in kilometers between two airports.
    static func distanceKm(_ a: Airport, _ b: Airport) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon)) / 1000
    }

    /// Plausible block time: great-circle distance ÷ ~850 km/h cruise, plus ~30 min
    /// of taxi/climb/descent overhead.
    static func duration(_ a: Airport, _ b: Airport) -> TimeInterval {
        let hours = distanceKm(a, b) / cruiseKmh
        return hours * 3600 + 30 * 60
    }
}

/// Generates a believable set of flights between `from` and `to` spread across a time
/// window. Departure times are jittered across the range; each flight gets a believable
/// number (a 2-letter carrier code + 3–4 digits) and a duration derived from distance.
enum FlightGenerator {
    private static let carriers = ["WN", "AA", "DL", "UA", "BA", "LH", "AF", "EK", "QR", "SQ", "KL", "IB", "TK", "JL", "NH"]

    static func flights(from: Airport, to: Airport, start: Date, end: Date) -> [GeneratedFlight] {
        let window = max(end.timeIntervalSince(start), 0)
        let duration = FlightMath.duration(from, to)

        // Roughly one departure every ~90 minutes across the window, clamped to a sane
        // range so a tiny window still yields one flight and a huge one doesn't explode.
        let count = min(max(Int(window / (90 * 60)) + 1, 1), 12)

        // Seed the RNG from the route + window so the same query is stable across a
        // re-open (feels like a real timetable, not a fresh shuffle each tap).
        var seed = UInt64(bitPattern: Int64(from.iata.hashValue ^ to.iata.hashValue))
        seed = seed &+ UInt64(bitPattern: Int64(start.timeIntervalSince1970.rounded()))
        var rng = SeededGenerator(seed: seed == 0 ? 0x9E3779B97F4A7C15 : seed)

        var flights: [GeneratedFlight] = []
        let slot = count > 1 ? window / Double(count) : window
        for i in 0..<count {
            // Spread departures evenly, then jitter within the slot for realism.
            let base = Double(i) * slot
            let jitter = slot > 0 ? Double.random(in: 0...(slot * 0.6), using: &rng) : 0
            let departure = start.addingTimeInterval(min(base + jitter, window))
            let carrier = carriers[Int.random(in: 0..<carriers.count, using: &rng)]
            let digits = Int.random(in: 100...9_999, using: &rng)
            let number = "\(carrier)\(digits)"
            flights.append(GeneratedFlight(
                flightNumber: number,
                departure: departure,
                arrival: departure.addingTimeInterval(duration)
            ))
        }
        return flights.sorted { $0.departure < $1.departure }
    }
}

/// Tiny deterministic RNG so a given route+time produces a stable timetable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}

/// The Flight Planner sheet. Purely picks two airport endpoints (and optionally a
/// generated flight); on "Fly it" it calls `onFly(departure, arrival)` and dismisses,
/// letting Route mode wire them into the existing PLANE-mode playback.
struct FlightPlannerView: View {
    @Environment(\.dismiss) private var dismiss

    /// Handed the chosen departure + arrival airports. Route mode turns these into the
    /// two PLANE-mode waypoints and starts the great-circle flight.
    let onFly: (Airport, Airport) -> Void

    @State private var departure: Airport?
    @State private var arrival: Airport?

    @State private var useTimeRange = false
    @State private var rangeStart = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var rangeEnd = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date()) ?? Date().addingTimeInterval(12 * 3600)

    @State private var generatedFlights: [GeneratedFlight] = []
    @State private var selectedFlight: GeneratedFlight?

    @State private var editingField: FlightField?

    private enum FlightField: Identifiable {
        case departure, arrival
        var id: Int { hashValue }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var canFly: Bool {
        guard let departure, let arrival else { return false }
        return departure.iata != arrival.iata
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    airportRow(
                        title: L("flight.departure", fallback: "Departure"),
                        icon: "airplane.departure",
                        tint: .green,
                        airport: departure,
                        field: .departure
                    )
                    airportRow(
                        title: L("flight.arrival", fallback: "Arrival"),
                        icon: "airplane.arrival",
                        tint: .red,
                        airport: arrival,
                        field: .arrival
                    )
                    if let departure, let arrival, departure.iata != arrival.iata {
                        HStack {
                            Image(systemName: "ruler")
                                .foregroundStyle(.secondary)
                            Text(routeSummary(departure, arrival))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(localized: "flight.airports.header", fallback: "Airports")
                }

                Section {
                    Toggle(isOn: $useTimeRange) {
                        Label(L("flight.time_range", fallback: "Time range"), systemImage: "clock")
                    }
                    .tint(Wander.brand)
                    .onChange(of: useTimeRange) { _, _ in regenerate() }

                    if useTimeRange {
                        DatePicker(
                            L("flight.earliest", fallback: "Earliest departure"),
                            selection: $rangeStart,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: rangeStart) { _, _ in regenerate() }

                        DatePicker(
                            L("flight.latest", fallback: "Latest departure"),
                            selection: $rangeEnd,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: rangeEnd) { _, _ in regenerate() }
                    }
                } header: {
                    Text(localized: "flight.schedule.header", fallback: "Schedule")
                } footer: {
                    Text(localized: "flight.schedule.footer",
                         fallback: "Optional. Generate plausible flights across a window and pick one — or leave off to fly directly.")
                }

                if useTimeRange, !generatedFlights.isEmpty {
                    Section {
                        ForEach(generatedFlights) { flight in
                            Button {
                                selectedFlight = flight
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "airplane")
                                        .foregroundStyle(Wander.brand)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(flight.flightNumber)
                                            .font(.body.monospaced())
                                            .foregroundStyle(.primary)
                                        Text(flight.timeLabel(Self.timeFormatter))
                                            .font(.caption).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedFlight?.id == flight.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Wander.brand)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(String(format: L("flight.flights_count", fallback: "%d flights"), generatedFlights.count))
                    }
                }
            }
            .navigationTitle(L("flight.title", fallback: "Flight Planner"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.cancel", fallback: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let departure, let arrival { onFly(departure, arrival) }
                        dismiss()
                    } label: {
                        Label(L("flight.fly_it", fallback: "Fly it"), systemImage: "airplane")
                    }
                    .disabled(!canFly)
                }
            }
            .sheet(item: $editingField) { field in
                AirportPickerSheet(
                    title: field == .departure
                        ? L("flight.pick_departure", fallback: "Pick Departure")
                        : L("flight.pick_arrival", fallback: "Pick Arrival")
                ) { picked in
                    switch field {
                    case .departure: departure = picked
                    case .arrival: arrival = picked
                    }
                    editingField = nil
                    regenerate()
                }
            }
        }
    }

    @ViewBuilder
    private func airportRow(title: String, icon: String, tint: Color, airport: Airport?, field: FlightField) -> some View {
        Button {
            editingField = field
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    if let airport {
                        Text(airport.displayLabel)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    } else {
                        Text(L("flight.tap_to_pick", fallback: "Tap to pick an airport"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func routeSummary(_ a: Airport, _ b: Airport) -> String {
        let km = Int(FlightMath.distanceKm(a, b).rounded())
        let minutes = Int((FlightMath.duration(a, b) / 60).rounded())
        let h = minutes / 60
        let m = minutes % 60
        let durationText = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return String(format: L("flight.route_summary", fallback: "%d km • ~%@"), km, durationText)
    }

    private func regenerate() {
        selectedFlight = nil
        guard useTimeRange, let departure, let arrival, departure.iata != arrival.iata else {
            generatedFlights = []
            return
        }
        // If the end is earlier than the start, treat it as spanning past midnight so the
        // window is always positive.
        var end = rangeEnd
        if end <= rangeStart { end = rangeStart.addingTimeInterval(3600) }
        generatedFlights = FlightGenerator.flights(from: departure, to: arrival, start: rangeStart, end: end)
    }
}

/// A searchable list of airports (by IATA code / name). Picking a row hands it back.
private struct AirportPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (Airport) -> Void

    @State private var query = ""

    private var results: [Airport] {
        AirportDataset.search(query)
    }

    var body: some View {
        NavigationStack {
            List(results) { airport in
                Button {
                    onPick(airport)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text(airport.iata)
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(Wander.brand)
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(airport.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                            Text(airport.country).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: L("flight.search_prompt", fallback: "IATA code or name"))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.cancel", fallback: "Cancel")) { dismiss() }
                }
            }
            .overlay {
                if AirportDataset.all.isEmpty {
                    ContentUnavailableView(
                        L("flight.no_data", fallback: "Airport data unavailable"),
                        systemImage: "airplane.circle",
                        description: Text(L("flight.no_data.detail", fallback: "The bundled airport list could not be loaded."))
                    )
                }
            }
        }
    }
}
