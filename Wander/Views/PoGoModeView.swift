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

/// A community-tool link for a non-PoGo game (spawns/portals rotate → link out to live data).
struct CommunityLink: Codable {
    let label: String
    let url: String
}

private struct PoGoData: Codable {
    let hotspots: [PoGoHotspot]
    let routes: [PoGoRoute]
    let gameExtras: [String: [PoGoHotspot]]?
    let communityLinks: [String: CommunityLink]?
}

// MARK: - Game presets (free, additive)

/// Location-based games this mode can be framed around. Purely changes labels;
/// the cooldown model stays the same soft-ban curve (PoGoCooldown) for all of them.
enum GamePreset: String, CaseIterable, Identifiable {
    case pokemonGo
    case monsterHunterNow
    case pikminBloom
    case ingress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pokemonGo: return "Pokémon GO"
        case .monsterHunterNow: return "Monster Hunter Now"
        case .pikminBloom: return "Pikmin Bloom"
        case .ingress: return "Ingress"
        }
    }

    /// Short label used in the nav bar / cooldown section header.
    var shortTitle: String {
        switch self {
        case .pokemonGo: return "PoGo"
        case .monsterHunterNow: return "MH Now"
        case .pikminBloom: return "Pikmin"
        case .ingress: return "Ingress"
        }
    }

    /// Whether a big teleport triggers a distance-based soft-ban cooldown for this game.
    /// Pokémon GO and Monster Hunter Now share the same Niantic soft-ban curve; Pikmin Bloom
    /// is step-based (no teleport cooldown) and Ingress uses a real-time speed lock instead.
    var usesTeleportCooldown: Bool {
        switch self {
        case .pokemonGo, .monsterHunterNow: return true
        case .pikminBloom, .ingress: return false
        }
    }

    /// Community-cited max "safe" in-app travel speed before movement/spawns get throttled.
    var maxSafeSpeedKmh: Int {
        switch self {
        case .pokemonGo: return 35          // ~35 km/h before the "driving" state throttles distance
        case .monsterHunterNow: return 16   // aggressive speed lock (~10–20 km/h, community-cited)
        case .pikminBloom: return 8         // step/route based — keep to a realistic walk
        case .ingress: return 60            // ~60 km/h speed lock (15-min ripple)
        }
    }

    /// Game-specific guidance shown in the PoGo tab (replaces the cooldown chart for the
    /// games that don't use one). Grounded in community sources; kept honest about uncertainty.
    var mechanicNote: String {
        switch self {
        case .pokemonGo:
            return "Soft-ban cooldown applies: after a big jump, wait out the timer before catching or spinning. Keep in-app speed under ~35 km/h so distance still counts."
        case .monsterHunterNow:
            return "Uses the same soft-ban cooldown as Pokémon GO (shown below). Its speed lock is stricter, though — stay under ~16 km/h or monsters hide and gathering fails."
        case .pikminBloom:
            return "Step-based, not teleport-based — there's no soft-ban cooldown. Steps come from the pedometer (not GPS), so pace a realistic walk (a Route at ~8 km/h) and avoid implausible daily step counts."
        case .ingress:
            return "No distance cooldown — instead there's a ~60 km/h speed lock (actions fail if you move faster) and a ~5-minute per-portal hack cooldown. Keep effective speed under ~60 km/h between actions."
        }
    }
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
    // Per-game flavored extras + live-community links (keyed by GamePreset.title). Shared spots
    // work for every game; these add game-specific spots + a link out to live data.
    @State private var gameExtras: [String: [PoGoHotspot]] = [:]
    @State private var communityLinks: [String: CommunityLink] = [:]
    @State private var loadError: String?

    // Cooldown is now owned by SimulationSession (single source of truth, app-wide + persistent).
    // This view just reads/renders session.cooldownActive / cooldownRemaining / lastJumpKm.

    // Feedback.
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    // PoGo Hub overlay: raids / eggs / events / research / rocket (free, read-only community
    // data from the Worker).
    @State private var showEventsSheet = false

    // "Failed to detect location (12)" troubleshooting sheet — the affected users are right here in
    // the Pokémon GO tab, so surface the fix checklist one tap away.
    @State private var showLocationHelp = false

    // When ON, teleports are blocked (not just warned) while a cooldown is active.
    @AppStorage("pogoBlockUntilCooldownEnds") private var blockUntilCooldownEnds = false
    // Optional per-game speed nudge (OFF by default) — warns on the Joystick, never clamps. See WalkModeView.
    @AppStorage("gameSpeedWarn") private var gameSpeedWarn = false

    // Selected location-based game (free preset). Only changes labels; cooldown curve is shared.
    @AppStorage("pogoGamePreset") private var gamePresetRaw = GamePreset.pokemonGo.rawValue
    private var gamePreset: GamePreset { GamePreset(rawValue: gamePresetRaw) ?? .pokemonGo }

    // Tapping a spot now PREVIEWS it on the Teleport tab (unified with saved Places) instead of
    // teleporting in place; `primaryTab` switches tabs. `session.teleportTick` lets us start the
    // cooldown when the user actually confirms the teleport there.
    @AppStorage("primaryTabSelection") private var primaryTab = AppFeature.location.id
    @ObservedObject private var session = SimulationSession.shared

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

    /// Curated spots for a NON-PoGo game: the shared popular play areas (PoGo-only category badges
    /// genericized to "Popular spot") plus that game's flavored extras.
    private var sharedDisplaySpots: [PoGoHotspot] {
        let shared = hotspots.map {
            PoGoHotspot(name: $0.name, area: $0.area, cat: "Popular spot", lat: $0.lat, lng: $0.lng)
        }
        return shared + (gameExtras[gamePreset.title] ?? [])
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

                Section {
                    Picker("Game", selection: $gamePresetRaw) {
                        ForEach(GamePreset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                } header: {
                    Text("Game")
                } footer: {
                    Text(gamePreset.mechanicNote)
                }

                cooldownSection

                if gamePreset.usesTeleportCooldown {
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
                }

                Section {
                    Toggle(isOn: $gameSpeedWarn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Warn if I exceed the safe speed")
                            Text("A nudge on the Joystick if your speed goes over \(gamePreset.shortTitle)'s ~\(gamePreset.maxSafeSpeedKmh) km/h — never forced.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(Wander.brand)
                } header: {
                    Text("Speed guardrail (optional)")
                }

                if !pairingExists {
                    Section {
                        Label("Import a pairing file in Settings, then teleport to catch on the go.",
                              systemImage: "doc.badge.gearshape")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // The curated spots double as a SHARED "popular play areas" list for every game
                // (these Niantic-style games are played in the same public spaces). Pokémon GO keeps
                // its category badges (Spawn/Raid/Event) + the Hub; other games get the shared list
                // plus a few flavored extras and a link to their live community tool.
                if gamePreset == .pokemonGo {
                    ForEach(hotspotsByCategory, id: \.category) { group in
                        Section {
                            ForEach(group.spots) { spot in
                                hotspotRow(spot)
                            }
                        } header: {
                            Text(group.category)
                        }
                    }
                } else {
                    Section {
                        ForEach(sharedDisplaySpots) { spot in
                            hotspotRow(spot)
                        }
                    } header: {
                        Text("Popular play areas")
                    } footer: {
                        Text("Popular public spots that work for any location game. Tap to preview, then Teleport.")
                    }

                    if let link = communityLinks[gamePreset.title], let url = URL(string: link.url) {
                        Section {
                            Link(destination: url) {
                                Label(link.label, systemImage: "arrow.up.right.square")
                            }
                        } footer: {
                            Text("Live spawns/portals for \(gamePreset.shortTitle) rotate — the community keeps the up-to-date spots.")
                        }
                    }
                }

                // Premade walk/spin routes — good for every game.
                if !routes.isEmpty {
                    Section {
                        ForEach(routes) { route in
                            routeRow(route)
                        }
                    } header: {
                        Text("Premade routes")
                    } footer: {
                        Text("Previews the route's start point on the map. Use the Route tab to play a full path.")
                    }
                }
            }
            .navigationTitle("\(gamePreset.shortTitle) Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Error 12 troubleshooting — the fix checklist for "Failed to detect location (12)".
                // Kept for every game preset since the Niantic soft-ban/fix rules apply broadly.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showLocationHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel(L("error12.open",
                                          fallback: "Location not detected? (Error 12) — troubleshooting"))
                }

                // The events hub is LeekDuck/ScrapedDuck data — Pokémon GO ONLY. Hide the calendar
                // for the other game presets, where it would just show irrelevant PoGo raids/eggs.
                if gamePreset == .pokemonGo {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showEventsSheet = true
                        } label: {
                            Image(systemName: "calendar.badge.clock")
                        }
                        .accessibilityLabel(L("pogo.hub.open",
                                              fallback: "PoGo Hub: raids, eggs, events, research & rocket"))
                    }
                }
            }
            .onAppear(perform: loadData)
            // The cooldown itself (compute on teleport + 1 s countdown) is driven by
            // SimulationSession now — this view just observes the published state below.
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showEventsSheet) {
                PoGoEventsSheet()
            }
            .sheet(isPresented: $showLocationHelp) {
                LocationErrorHelpView()
            }
        }
    }

    // MARK: Cooldown UI

    /// Seconds left on the shared app-wide cooldown (single source of truth: SimulationSession).
    private var remainingSeconds: TimeInterval { session.cooldownRemaining }

    @ViewBuilder private var cooldownSection: some View {
        if session.cooldownActive {
            let remaining = session.cooldownRemaining
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
                    if session.lastJumpKm > 0 {
                        Text("\(formattedKm(session.lastJumpKm)) km")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("\(gamePreset.shortTitle) cooldown")
            }
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
                Label("Preview", systemImage: "map")
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
                Label("Preview", systemImage: "map")
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
        // is still counting down (rather than only warning). Reads the shared session cooldown.
        if blockUntilCooldownEnds, session.cooldownActive, remainingSeconds > 0 {
            present(
                title: "Cooldown Active",
                message: "Wait \(timeString(remainingSeconds)) before teleporting again. Turn off \"Block until cooldown ends\" to override."
            )
            return
        }

        // Preview, don't teleport: jump to the Teleport tab and center + pin this spot. The user
        // presses Simulate there to actually move — matching how a tapped saved Place behaves. The
        // cooldown then starts on that confirm — SimulationSession.noteTeleport computes it app-wide.
        NotificationCenter.default.post(
            name: .previewLocationRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        primaryTab = AppFeature.location.id
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
            gameExtras = decoded.gameExtras ?? [:]
            communityLinks = decoded.communityLinks ?? [:]
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
