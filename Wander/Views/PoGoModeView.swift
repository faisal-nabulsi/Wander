//
//  PoGoModeView.swift
//  Wander
//
//  "Pokémon GO Mode": curated high-activity hotspots and premade walk/spin
//  routes, each with a one-tap Teleport that reuses the same location-sim
//  mechanism as the Teleport tab. After each teleport it shows a live PoGo
//  soft-ban cooldown — the great-circle distance from the previous spoofed
//  coordinate mapped to the standard cooldown curve — so you know how long to
//  wait before catching or spinning.
//
//  Data comes from the bundled Resources/pogo.json (shared with wander-desktop).
//

import SwiftUI
import CoreLocation

// MARK: - Data model

/// A single curated point of interest.
struct PoGoHotspot: Codable, Identifiable {
    let name: String
    let area: String
    let cat: String
    let lat: Double
    let lng: Double

    var id: String { "\(name)|\(lat),\(lng)" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// A premade path. `points` is an array of `[lat, lng]` pairs.
struct PoGoRoute: Codable, Identifiable {
    let name: String
    let area: String
    let cat: String
    let speed_mps: Double
    let points: [[Double]]

    var id: String { "\(name)|\(area)" }

    /// First point of the route (its start / teleport target).
    var start: CLLocationCoordinate2D? {
        guard let first = points.first, first.count >= 2 else { return nil }
        return CLLocationCoordinate2D(latitude: first[0], longitude: first[1])
    }
}

private struct PoGoData: Codable {
    let hotspots: [PoGoHotspot]
    let routes: [PoGoRoute]
}

// MARK: - Cooldown math

enum PoGoCooldown {
    /// Standard PoGo soft-ban curve: distance in km -> cooldown in minutes.
    /// Matches the wander-desktop table exactly. Linear interpolation between points.
    private static let table: [(km: Double, minutes: Double)] = [
        (0, 0), (1, 0.5), (5, 2), (10, 6), (25, 9), (30, 11), (65, 22),
        (81, 25), (100, 35), (250, 45), (500, 60), (750, 75), (1000, 85),
        (1500, 100), (2000, 120)
    ]

    /// Great-circle distance between two coordinates, in kilometers (haversine).
    static func distanceKm(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let earthRadiusKm = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadiusKm * c
    }

    /// Map a distance (km) to a cooldown (seconds) using the soft-ban curve.
    static func seconds(forKm km: Double) -> TimeInterval {
        minutes(forKm: km) * 60
    }

    /// Map a distance (km) to a cooldown in minutes (linear interpolation, clamped).
    static func minutes(forKm km: Double) -> Double {
        guard km > 0 else { return 0 }
        if let last = table.last, km >= last.km { return last.minutes }
        for i in 1..<table.count {
            let lower = table[i - 1]
            let upper = table[i]
            if km <= upper.km {
                let span = upper.km - lower.km
                guard span > 0 else { return upper.minutes }
                let t = (km - lower.km) / span
                return lower.minutes + t * (upper.minutes - lower.minutes)
            }
        }
        return table.last?.minutes ?? 0
    }
}

// MARK: - View

struct PoGoModeView: View {
    @State private var hotspots: [PoGoHotspot] = []
    @State private var routes: [PoGoRoute] = []
    @State private var loadError: String?

    // Cooldown tracking.
    @State private var lastCoordinate: CLLocationCoordinate2D?
    @State private var cooldownEndsAt: Date?
    @State private var lastJumpKm: Double = 0
    @State private var now: Date = Date()

    // Feedback.
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // When ON, teleports are blocked (not just warned) while a cooldown is active.
    @AppStorage("pogoBlockUntilCooldownEnds") private var blockUntilCooldownEnds = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var pairingFileURL: URL { PairingFileStore.prepareURL() }
    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFileURL.path)
    }

    /// Hotspots grouped by category, in a stable order.
    private var hotspotsByCategory: [(category: String, spots: [PoGoHotspot])] {
        let grouped = Dictionary(grouping: hotspots, by: { $0.cat })
        return grouped
            .map { (category: $0.key, spots: $0.value) }
            .sorted { $0.category < $1.category }
    }

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                cooldownSection

                Section {
                    Toggle(isOn: $blockUntilCooldownEnds) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Block until cooldown ends")
                            Text("Prevent teleporting while a cooldown is active, instead of just warning.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Wander.brand)
                } header: {
                    Text("Cooldown safety")
                }

                if !pairingExists {
                    Section {
                        Label("Import a pairing file in Settings, then teleport to catch on the go.",
                              systemImage: "doc.badge.gearshape")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(hotspotsByCategory, id: \.category) { group in
                    Section {
                        ForEach(group.spots) { spot in
                            hotspotRow(spot)
                        }
                    } header: {
                        Text(group.category)
                    }
                }

                if !routes.isEmpty {
                    Section {
                        ForEach(routes) { route in
                            routeRow(route)
                        }
                    } header: {
                        Text("Premade routes")
                    } footer: {
                        Text("Teleports to the route's start point. Use the Route tab to play a full path.")
                    }
                }
            }
            .navigationTitle("PoGo Mode")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadData)
            .onReceive(ticker) { date in
                // Only drive the countdown while a cooldown is pending.
                if cooldownEndsAt != nil { now = date }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: Cooldown UI

    private var remainingSeconds: TimeInterval {
        guard let cooldownEndsAt else { return 0 }
        return max(0, cooldownEndsAt.timeIntervalSince(now))
    }

    @ViewBuilder private var cooldownSection: some View {
        if let cooldownEndsAt {
            let remaining = remainingSeconds
            Section {
                HStack(spacing: 12) {
                    Image(systemName: remaining > 0 ? "hourglass" : "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(remaining > 0 ? Wander.brand : .green)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        if remaining > 0 {
                            Text("Cooldown \(timeString(remaining))")
                                .font(.headline)
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text("Wait before catching / spinning")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Cooldown cleared")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Safe to catch and spin")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if lastJumpKm > 0 {
                        Text("\(formattedKm(lastJumpKm)) km")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("PoGo cooldown")
            }
            .id(cooldownEndsAt)   // reset the row when a new cooldown starts
        }
    }

    // MARK: Rows

    private func hotspotRow(_ spot: PoGoHotspot) -> some View {
        Button {
            teleport(to: spot.coordinate, label: spot.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.name).font(.body).foregroundStyle(.primary)
                    Text(spot.area).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Teleport", systemImage: Wander.Icon.simulate)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pairingExists ? Wander.brand : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!pairingExists)
    }

    private func routeRow(_ route: PoGoRoute) -> some View {
        Button {
            if let start = route.start {
                teleport(to: start, label: "\(route.name) (start)")
            } else {
                present(title: "Empty Route", message: "This route has no points.")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.title3)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name).font(.body).foregroundStyle(.primary)
                    Text("\(route.area) • \(route.points.count) pts • \(formattedSpeed(route.speed_mps)) m/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Teleport", systemImage: Wander.Icon.simulate)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pairingExists ? Wander.brand : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!pairingExists)
    }

    // MARK: Teleport (mirrors the Teleport tab mechanism)

    private func teleport(to coordinate: CLLocationCoordinate2D, label: String) {
        guard pairingExists else {
            present(title: "Pairing File Required",
                    message: "Import a pairing file in Settings before teleporting.")
            return
        }

        // Optional hard block: if enabled, refuse to teleport while a cooldown
        // is still counting down (rather than only warning).
        if blockUntilCooldownEnds {
            // Keep `now` fresh so the check is accurate even if the ticker is idle.
            now = Date()
            let remaining = remainingSeconds
            if remaining > 0 {
                present(
                    title: "Cooldown Active",
                    message: "Wait \(timeString(remaining)) before teleporting again. Turn off \"Block until cooldown ends\" to override."
                )
                return
            }
        }

        // Compute the PoGo cooldown from the previous spoofed coordinate.
        let previous = lastCoordinate
        let path = pairingFileURL.path

        SavedPlacesStore.recordRecent(coordinate, name: label)

        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                path
            )
            DispatchQueue.main.async {
                if code == 0 {
                    SimulationSession.shared.started()   // starts BackgroundLocationManager + banner
                    applyCooldown(from: previous, to: coordinate)
                    lastCoordinate = coordinate
                } else {
                    present(
                        title: "Teleport Failed",
                        message: "Could not simulate location (error \(code)). Make sure the device is connected and the DDI is mounted."
                    )
                }
            }
        }
    }

    private func applyCooldown(from previous: CLLocationCoordinate2D?, to next: CLLocationCoordinate2D) {
        guard let previous else {
            // First teleport of the session: no prior coordinate, so no cooldown.
            lastJumpKm = 0
            cooldownEndsAt = nil
            return
        }
        let km = PoGoCooldown.distanceKm(from: previous, to: next)
        lastJumpKm = km
        let seconds = PoGoCooldown.seconds(forKm: km)
        now = Date()
        if seconds > 0 {
            cooldownEndsAt = Date().addingTimeInterval(seconds)
        } else {
            cooldownEndsAt = nil
        }
    }

    // MARK: Loading

    private func loadData() {
        guard hotspots.isEmpty && routes.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "pogo", withExtension: "json") else {
            loadError = "pogo.json not found in the app bundle."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PoGoData.self, from: data)
            hotspots = decoded.hotspots
            routes = decoded.routes
            loadError = nil
        } catch {
            loadError = "Could not load PoGo data: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private func present(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func formattedKm(_ km: Double) -> String {
        km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func formattedSpeed(_ mps: Double) -> String {
        String(format: "%.1f", mps)
    }
}

#Preview {
    PoGoModeView()
}
