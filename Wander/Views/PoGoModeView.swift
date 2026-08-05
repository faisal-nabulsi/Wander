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
//  Spots come from the LIVE directory (WanderHotspots → Worker /pogo/hotspots), which carries
//  freshness metadata so a nerfed spot can be flagged without shipping a build. The bundled
//  Resources/pogo.json (shared with wander-desktop) stays in the binary as the seed/fallback: it
//  paints instantly on launch and is what an offline user — or a user whose first fetch has never
//  succeeded — keeps seeing. Routes, game extras and community links are bundled-only.
//

import SwiftUI
import CoreLocation

// MARK: - Data model

/// A single curated point of interest.
///
/// The freshness fields (`status` / `lastVerified` / `ageDays` / `notes`) only come from the live
/// directory, so they're optional: the bundled pogo.json has none of them and must keep decoding
/// unchanged. A spot with no status simply shows no badge (see HotspotStatus in WanderHotspots).
struct PoGoHotspot: Codable, Identifiable {
    let name: String
    let area: String
    let cat: String
    let lat: Double
    let lng: Double
    /// "good" | "nerfed" | "unknown" — see `statusValue`.
    let status: String?
    /// ISO date the spot was last checked by a human, if ever.
    let lastVerified: String?
    /// Server-computed age of `lastVerified` in days.
    let ageDays: Int?
    /// Optional editorial note ("stops removed in the 2026 sweep").
    let notes: String?

    init(name: String,
         area: String,
         cat: String,
         lat: Double,
         lng: Double,
         status: String? = nil,
         lastVerified: String? = nil,
         ageDays: Int? = nil,
         notes: String? = nil) {
        self.name = name
        self.area = area
        self.cat = cat
        self.lat = lat
        self.lng = lng
        self.status = status
        self.lastVerified = lastVerified
        self.ageDays = ageDays
        self.notes = notes
    }

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
    // The live directory once it's landed (network or disk cache). nil = we're showing the bundled
    // seed, which is also what an offline first run keeps showing forever — never an empty list.
    @State private var directory: HotspotDirectory?
    @State private var didLoadBundle = false

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

    // Spoof Doctor diagnostic sheet (gs-loc mode only): the two-rung "check my setup" ladder.
    @State private var showSpoofDoctor = false

    // Long-haul advisory: after a very big jump (>1500 km) many players stay logged OUT of the game
    // for ~8h to avoid a strike. Shown once per such jump — dismissing hides it until the NEXT
    // long-haul teleport (tracked by teleportTick so a fresh big jump re-surfaces it).
    private static let longHaulKm: Double = 1500
    @State private var dismissedLongHaulTick: Int = -1

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
    // History + per-account clocks. The journal is the one that knows WHOSE cooldown is running, so
    // every countdown on this screen is read through it rather than straight off the session.
    @ObservedObject private var journal = CooldownJournal.shared

    private var pairingFileURL: URL { PairingFileStore.prepareURL() }
    private var pairingExists: Bool {
        // gs-loc mode injects through the proxy, not the dev tunnel — no pairing file needed, so don't
        // block teleport (the FFI short-circuits to the proxy before the pairing path is used).
        FileManager.default.fileExists(atPath: pairingFileURL.path) || GslocMode.enabled
    }

    /// Hotspots grouped by category, in a stable order. Nerfed spots sink to the bottom of their
    /// group (filter-append, so the surviving order stays exactly as the directory listed it) —
    /// they're still tappable, just not what you see first.
    private var hotspotsByCategory: [(category: String, spots: [PoGoHotspot])] {
        let grouped = Dictionary(grouping: hotspots, by: { $0.cat })
        return grouped
            .map { (category: $0.key, spots: demoteNerfed($0.value)) }
            .sorted { $0.category < $1.category }
    }

    /// Curated spots for a NON-PoGo game: the shared popular play areas (PoGo-only category badges
    /// genericized to "Popular spot") plus that game's flavored extras. Freshness carries over —
    /// a nerfed park is a worse Pikmin walk too.
    private var sharedDisplaySpots: [PoGoHotspot] {
        let shared = hotspots.map {
            PoGoHotspot(name: $0.name, area: $0.area, cat: "Popular spot", lat: $0.lat, lng: $0.lng,
                        status: $0.status, lastVerified: $0.lastVerified,
                        ageDays: $0.ageDays, notes: $0.notes)
        }
        return demoteNerfed(shared) + (gameExtras[gamePreset.title] ?? [])
    }

    private func demoteNerfed(_ spots: [PoGoHotspot]) -> [PoGoHotspot] {
        spots.filter { !$0.isNerfed } + spots.filter { $0.isNerfed }
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
                    Label {
                        Text("This tab spoofs anti-cheat games (Pokémon GO, Monster Hunter Now…) through gs-loc / Shadowrocket. For Find My, Life360, or anything else, use the Location tab — the regular tunnel is smoother, moves in real time, and works everywhere.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "gamecontroller").foregroundStyle(Wander.brand)
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

                // Pre-flight coherence checks: the two highest-yield Error-12 causes (Location
                // Services off / Precise off) plus the IP↔GPS detection vector. Checked against the
                // last teleport target so the IP↔GPS hint reflects where the user actually is spoofing.
                PreFlightCard(spoofedTarget: session.lastTeleportCoordinate)

                // gs-loc mode only: "are you ACTUALLY spoofed?" — reads Wander's own Core Location fix and
                // compares it to the pushed target, so the user gets a green/amber answer instead of
                // eyeballing Apple Maps. Meaningless on the dev-tunnel path, so gate on GslocMode.enabled.
                if GslocMode.enabled {
                    GslocVerifyCard()

                    // Full two-rung diagnostic (Spoof Doctor): first proves the proxy is intercepting at
                    // all (plain-HTTP probe, no CA needed), then that the location is actually spoofed —
                    // and reports the exact fix. Broader than the verify card above, which only does rung 2.
                    Section {
                        Button {
                            showSpoofDoctor = true
                        } label: {
                            Label("Check my setup", systemImage: "stethoscope")
                        }
                    } footer: {
                        Text("Not working? This runs both checks — proxy interception and the spoof itself — and tells you exactly what to fix.")
                    }

                    GslocQuickControlsCard()
                }

                cooldownSection

                cooldownSuiteSection

                longHaulSection

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
                    } footer: {
                        // Explains the new per-row annotation, which is otherwise easy to miss —
                        // and states plainly that it only informs, so nobody expects it to stop them.
                        Text("Spots below show what a jump there would cost (\"≈2h cooldown\") measured from where you are now. While a cooldown runs, spots you'd be jumping too soon are dimmed. It's a heads-up only — you can still tap any of them.")
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
                    let groups = hotspotsByCategory
                    ForEach(groups, id: \.category) { group in
                        Section {
                            ForEach(group.spots) { spot in
                                hotspotRow(spot)
                            }
                        } header: {
                            Text(group.category)
                        } footer: {
                            // Where this list came from + how fresh it is — stated once, under the
                            // last group, so it reads as a note about the whole directory.
                            if group.category == groups.last?.category {
                                Text(directoryNote)
                            }
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
                        Text("Popular public spots that work for any location game. Tap to preview, then Teleport.\n\(directoryNote)")
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
            // Refresh off the main path: the list is already on screen from the bundled seed (or the
            // cached directory) before this task even starts, so a slow/dead network costs nothing.
            .task { await refreshDirectory() }
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
            .sheet(isPresented: $showSpoofDoctor) {
                SpoofDoctorView()
            }
        }
    }

    // MARK: Cooldown UI

    /// Seconds left on the cooldown that applies to the SELECTED account: the app-wide one from
    /// SimulationSession, or this account's own clock if that's longer (see displayedRemaining()).
    ///
    /// DISPLAY ONLY. It folds in hand-logged interactions, so it must never reach the opt-in teleport
    /// block below — that one reads `session.cooldownRemaining`, the clock Wander observed itself.
    private var remainingSeconds: TimeInterval { journal.displayedRemaining() }

    @ViewBuilder private var cooldownSection: some View {
        // `session.cooldownActive` is kept in the condition so the "cleared" state still shows for the
        // moment the global timer hits zero, exactly as it did before per-account clocks existed.
        if session.cooldownActive || remainingSeconds > 0 {
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
                    if session.lastJumpKm > 0 {
                        Text("\(formattedKm(session.lastJumpKm)) km")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                // Name the account once there's more than one, so a countdown can never be read as
                // belonging to whichever account the user happens to be playing.
                Text(journal.accounts.count > 1
                     ? "\(gamePreset.shortTitle) cooldown · \(journal.active.name)"
                     : "\(gamePreset.shortTitle) cooldown")
            }
        }
    }

    // MARK: Cooldown suite (journal / rulebook / accounts)

    /// The three screens the countdown alone couldn't cover: what already happened, what starts the
    /// timer in the first place, and which account is being timed. All informational — nothing here
    /// stops a teleport, and the account picker only changes which clock is on screen.
    ///
    /// Hidden for the presets with no distance cooldown (Pikmin/Ingress), where a soft-ban journal
    /// and a Pokémon GO rulebook would just be noise — their mechanics are covered by `mechanicNote`.
    @ViewBuilder private var cooldownSuiteSection: some View {
        if gamePreset.usesTeleportCooldown {
            Section {
                if journal.accounts.count > 1 {
                    Picker(L("cooldown.accounts.active", fallback: "Account"),
                           selection: Binding(get: { journal.activeAccountID },
                                              set: { journal.selectAccount($0) })) {
                        ForEach(journal.accounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                }

                NavigationLink {
                    CooldownJournalView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(L("cooldown.journal.title", fallback: "Cooldown journal"),
                              systemImage: "list.bullet.rectangle")
                        Text(journalSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    CooldownRulebookView()
                } label: {
                    Label(L("cooldown.rulebook.title", fallback: "What starts the cooldown"),
                          systemImage: "book")
                }

                NavigationLink {
                    CooldownAccountsView()
                } label: {
                    HStack {
                        Label(L("cooldown.accounts.title", fallback: "Accounts"),
                              systemImage: "person.2")
                        Spacer()
                        Text(journal.active.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L("cooldown.suite.header", fallback: "Cooldown tools"))
            } footer: {
                Text(L("cooldown.suite.footer",
                       fallback: "Teleports are logged for you. Spins, catches and raids aren't — Wander can't see inside the game — so log those yourself in the journal to keep the timer honest."))
            }
        }
    }

    /// The one useful thing to say about the journal from the outside: how much is in it, and what
    /// the last thing that happened was.
    private var journalSubtitle: String {
        guard let last = journal.active.entries.first else {
            return L("cooldown.suite.empty", fallback: "Nothing logged yet")
        }
        let count = journal.active.entries.count
        return String(format: L("cooldown.suite.subtitle", fallback: "%d logged · last %@"),
                      count, last.date.formatted(date: .omitted, time: .shortened))
    }

    // MARK: Long-haul advisory

    /// Whether the most recent teleport was a long haul we haven't dismissed the advisory for yet.
    private var showLongHaul: Bool {
        gamePreset.usesTeleportCooldown
            && session.lastJumpKm > Self.longHaulKm
            && dismissedLongHaulTick != session.teleportTick
    }

    /// One-time advisory after a very big jump: community guidance (NOT a guarantee) to stay logged
    /// out of the game for ~8h after a long teleport. Dismissible; re-surfaces on the next long haul.
    @ViewBuilder private var longHaulSection: some View {
        if showLongHaul {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "airplane.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 28)
                        Text(String(
                            format: L("advisory.longhaul.body",
                                      fallback: "Big jump (%@ km) — many players stay logged OUT of the game for ~8 hours after a long teleport to avoid a strike. Community guidance, not a guarantee."),
                            formattedKm(session.lastJumpKm)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(L("advisory.longhaul.dismiss", fallback: "Got it")) {
                        dismissedLongHaulTick = session.teleportTick
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .tint(Wander.brand)
                }
                .padding(.vertical, 2)
            } header: {
                Text(L("advisory.longhaul.header", fallback: "Long-haul jump"))
            }
        }
    }

    // MARK: Destination annotations (informational)

    /// Dim, don't disable. Same standing rule as the "Speed guardrail (optional)" nudge below:
    /// a destination that's still inside the running cooldown fades back, but stays fully tappable.
    private static let blockedRowOpacity: Double = 0.55

    /// Same rule for a spot the directory has marked nerfed: fade it back (with a "Nerfed" flag on
    /// the row), but let anyone who still wants it tap it — the coordinates are perfectly valid.
    private static let nerfedRowOpacity: Double = 0.5

    /// The shared sub-line every teleport-target row gets: what this jump would cost on the soft-ban
    /// curve, and what time it is at the destination. Both halves render nothing when they have
    /// nothing to say (no prior teleport, a preset with no cooldown, an unresolved time zone), so a
    /// first-run list looks exactly as it did before.
    @ViewBuilder private func destinationAnnotations(_ coordinate: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 6) {
            CooldownPreviewLabel(destination: coordinate)
            DestinationLocalTimeLabel(coordinate: coordinate)
        }
    }

    private func isCooldownBlocked(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CooldownPreview.status(for: coordinate)?.isBlocked == true
    }

    // MARK: Rows

    private func hotspotRow(_ spot: PoGoHotspot) -> some View {
        Button {
            teleport(to: spot.coordinate, label: spot.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title3)
                    .foregroundStyle(spot.isNerfed ? Color.secondary : Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.name).font(.body).foregroundStyle(.primary)
                    Text(spot.area).font(.caption).foregroundStyle(.secondary)
                    freshnessLine(spot)
                    destinationAnnotations(spot.coordinate)
                }
                Spacer()
                Label("Preview", systemImage: "map")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pairingExists ? Wander.brand : .secondary)
            }
            .contentShape(Rectangle())
            // Two independent reasons to fade a row (too-soon jump, nerfed spot); take the dimmer
            // of the two rather than stacking them into an unreadable row.
            .opacity(rowOpacity(spot))
        }
        .buttonStyle(.plain)
        .disabled(!pairingExists)
    }

    private func rowOpacity(_ spot: PoGoHotspot) -> Double {
        let cooldown = isCooldownBlocked(spot.coordinate) ? Self.blockedRowOpacity : 1
        return min(cooldown, spot.isNerfed ? Self.nerfedRowOpacity : 1)
    }

    /// The freshness signals from the live directory: trust status and how long ago a human last
    /// checked the spot. Renders nothing for a plain unverified spot (every bundled one, and any
    /// live spot the directory hasn't rated), so the offline list looks exactly as it always did.
    @ViewBuilder private func freshnessLine(_ spot: PoGoHotspot) -> some View {
        let age = spot.verifiedAgeText
        if spot.statusValue != .unknown || age != nil {
            HStack(spacing: 6) {
                switch spot.statusValue {
                case .nerfed:
                    // The entire point of the directory: say it out loud rather than quietly
                    // leaving a dud park in the list looking as good as the rest.
                    Label("Nerfed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                case .good:
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                case .unknown:
                    EmptyView()
                }
                if let age {
                    Text(age)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if spot.isNerfed, let notes = spot.notes, !notes.isEmpty {
                    Text("• \(notes)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
                    // A route is entered by teleporting to its start, so it carries the same jump
                    // cost (and the same local time) as a hotspot at that point.
                    if let start = route.start {
                        destinationAnnotations(start)
                    }
                }
                Spacer()
                Label("Preview", systemImage: "map")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pairingExists ? Wander.brand : .secondary)
            }
            .contentShape(Rectangle())
            .opacity(route.start.map { isCooldownBlocked($0) } == true ? Self.blockedRowOpacity : 1)
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
        //
        // DELIBERATELY the session's clock, not `remainingSeconds` / `journal.displayedRemaining()`.
        // This is the one place in the cooldown suite that can refuse an action, so it may only ever
        // be driven by cooldowns Wander OBSERVED itself. The journal's remainder also contains
        // hand-typed, unverifiable numbers — one tap on "Caught something" restarts the account clock
        // — and a journal entry must never be able to talk the app out of a teleport. The journal's
        // per-account state is persisted while `SimulationSession.lastTeleportCoordinate` is not, so
        // wiring this to the journal would additionally block the first jump after every relaunch,
        // which the session (having no origin to measure from) charges nothing for.
        if blockUntilCooldownEnds, session.cooldownActive, session.cooldownRemaining > 0 {
            present(
                title: "Cooldown Active",
                message: "Wait \(timeString(session.cooldownRemaining)) before teleporting again. Turn off \"Block until cooldown ends\" to override."
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

    /// Bundled seed first (synchronous, tiny, always present), then the last cached copy of the live
    /// directory if we have one. Both are instant — the network never gates the first paint.
    private func loadData() {
        // Tracked with an explicit flag rather than "is the list empty?": the live directory can land
        // first and fill `hotspots`, which used to make this bail and leave routes/extras/links empty.
        guard !didLoadBundle else { return }
        didLoadBundle = true
        guard let url = Bundle.main.url(forResource: "pogo", withExtension: "json") else {
            loadError = "pogo.json not found in the app bundle."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(PoGoData.self, from: data)
            // Seed the spots ONLY while we have nothing better — if the live directory beat us here,
            // the bundled copy is the older list and must not clobber it.
            if directory == nil {
                hotspots = decoded.hotspots
            }
            routes = decoded.routes
            gameExtras = decoded.gameExtras ?? [:]
            communityLinks = decoded.communityLinks ?? [:]
            loadError = nil
        } catch {
            loadError = "Could not load PoGo data: \(error.localizedDescription)"
        }

        if let cached = WanderHotspots.cachedDirectory() {
            apply(cached)
        }
    }

    /// Background refresh, throttled inside the service to a few hours. A nil result means "nothing
    /// new" — not due, or offline — and we simply keep whatever list is already on screen.
    private func refreshDirectory() async {
        if let fresh = await WanderHotspots.refreshIfNeeded() {
            apply(fresh)
        }
    }

    private func apply(_ directory: HotspotDirectory) {
        self.directory = directory
        hotspots = directory.hotspots
    }

    /// One honest line about where the spots came from. Says "built-in" when we're on the bundled
    /// seed so a user who's never been online doesn't read a stale list as freshly verified.
    private var directoryNote: String {
        guard let directory else {
            return "Built-in spots. They'll update from Wander's live directory next time you're online."
        }
        var note = "From Wander's live spot directory"
        if let updatedAt = directory.updatedAt {
            note += ", updated \(Self.directoryDateFormatter.string(from: updatedAt))"
        }
        note += "."
        if directory.fromCache {
            note += " Showing your last downloaded copy."
        }
        return note
    }

    private static let directoryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        // The feed's updatedAt is a bare editorial date parsed as UTC — render it in UTC too, or a
        // user west of Greenwich sees it shifted a day earlier than what the directory actually says.
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

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
