//
//  PoGoEventsSheet.swift
//  Wander
//
//  FREE read-only overlay of current Pokémon GO raids, egg pools, events, field research and
//  Team Rocket lineups, fetched from the Worker's public /pogo/events endpoint (LeekDuck /
//  ScrapedDuck community data). Display only — we never use any coordinates from this feed; it's
//  purely "what CAN raid / hatch / spawn right now".
//
//  Five segments (the "PoGo Hub"):
//    • Raids    — current bosses grouped by tier, with type chips, a CP window + a shiny sparkle.
//    • Eggs     — species grouped by egg distance ("2 km", "7 km", …), CP + shiny marks.
//    • Events   — current/upcoming events with type/heading and a local-time start/end window.
//    • Research — field-research tasks → reward Pokémon (+ shiny / CP).
//    • Rocket   — Team GO Rocket grunt lineups → possible Pokémon (shadow, encounter, shiny).
//
//  Each type is fetched on demand and its last successful payload is cached, so an offline refresh
//  degrades gracefully to the last-known data with a subtle "offline" note instead of a dead error.
//  Empty and offline states are handled inline (no crash, no blank screen).
//

import SwiftUI

private enum PoGoEventsTab: String, CaseIterable, Identifiable {
    case raids, eggs, events, research, rocket
    var id: String { rawValue }
    var title: String {
        switch self {
        case .raids:    return L("pogo.hub.tab.raids", fallback: "Raids")
        case .eggs:     return L("pogo.hub.tab.eggs", fallback: "Eggs")
        case .events:   return L("pogo.hub.tab.events", fallback: "Events")
        case .research: return L("pogo.hub.tab.research", fallback: "Research")
        case .rocket:   return L("pogo.hub.tab.rocket", fallback: "Rocket")
        }
    }
}

struct PoGoEventsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var tab: PoGoEventsTab = .raids

    @State private var raids: [PoGoRaidBoss] = []
    @State private var eggs: [PoGoEggEntry] = []
    @State private var events: [PoGoEvent] = []
    @State private var research: [PoGoResearchTask] = []
    @State private var rocket: [PoGoRocketLineup] = []

    // True when EVERY loaded feed came from the local cache (offline), so we can show one note.
    @State private var isOffline = false

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L("pogo.hub.view", fallback: "View"), selection: $tab) {
                    ForEach(PoGoEventsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                if isOffline && loadError == nil {
                    offlineNote
                }

                content
            }
            .navigationTitle(L("pogo.hub.title", fallback: "PoGo Hub"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done", fallback: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await loadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel(L("pogo.hub.refresh", fallback: "Refresh"))
                }
            }
            .task {
                // Load once when the sheet first appears; the refresh button re-fetches.
                if !hasLoaded { await loadAll() }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isLoading {
            Spacer()
            ProgressView(L("pogo.hub.loading", fallback: "Loading current data…"))
                .font(.footnote)
            Spacer()
        } else if let loadError {
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L("pogo.hub.tryAgain", fallback: "Try again")) { Task { await loadAll() } }
                    .buttonStyle(.bordered)
            }
            .padding()
            Spacer()
        } else {
            switch tab {
            case .raids:    raidsList
            case .eggs:     eggsList
            case .events:   eventsList
            case .research: researchList
            case .rocket:   rocketList
            }
        }
    }

    /// Subtle banner shown when the visible data all came from the local cache (offline).
    private var offlineNote: some View {
        Label(L("pogo.hub.offline", fallback: "Offline — showing last saved data"),
              systemImage: "wifi.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 6)
    }

    // MARK: - Raids

    /// Bosses grouped by tier, tiers in a sensible order (Mega / T5 / Shadow before the rest).
    private var raidsByTier: [(tier: String, bosses: [PoGoRaidBoss])] {
        let grouped = Dictionary(grouping: raids, by: { $0.tier })
        return grouped
            .map { (tier: $0.key, bosses: $0.value) }
            .sorted { tierRank($0.tier) < tierRank($1.tier) }
    }

    /// Lower rank sorts first. Best-effort ordering over free-form tier strings.
    private func tierRank(_ tier: String) -> Int {
        let t = tier.lowercased()
        if t.contains("mega") { return 0 }
        if t.contains("5") || t.contains("legendary") { return 1 }
        if t.contains("shadow") { return 2 }
        if t.contains("4") { return 3 }
        if t.contains("3") { return 4 }
        if t.contains("2") { return 5 }
        if t.contains("1") { return 6 }
        return 9
    }

    @ViewBuilder private var raidsList: some View {
        if raids.isEmpty {
            emptyState(L("pogo.hub.empty.raids", fallback: "No raids reported right now."),
                       systemImage: "shield.slash")
        } else {
            List {
                ForEach(raidsByTier, id: \.tier) { group in
                    Section(group.tier) {
                        ForEach(group.bosses) { boss in
                            HStack(spacing: 12) {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.title3)
                                    .foregroundStyle(Wander.brand)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(boss.name).font(.body)
                                    if !boss.types.isEmpty {
                                        Text(boss.types.joined(separator: " • "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let cp = boss.cp {
                                        Text(cpLine(cp))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if boss.canBeShiny { shinyBadge }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Eggs

    /// Species grouped by egg distance, distances ordered numerically ("2 km" before "7 km").
    private var eggsByDistance: [(distance: String, entries: [PoGoEggEntry])] {
        let grouped = Dictionary(grouping: eggs, by: { $0.eggType })
        return grouped
            .map { (distance: $0.key, entries: $0.value) }
            .sorted { distanceRank($0.distance) < distanceRank($1.distance) }
    }

    private func distanceRank(_ eggType: String) -> Double {
        let digits = eggType.filter { $0.isNumber || $0 == "." }
        return Double(digits) ?? 999
    }

    @ViewBuilder private var eggsList: some View {
        if eggs.isEmpty {
            emptyState(L("pogo.hub.empty.eggs", fallback: "No egg pool data right now."),
                       systemImage: "circle.dashed")
        } else {
            List {
                ForEach(eggsByDistance, id: \.distance) { group in
                    Section(group.distance) {
                        ForEach(group.entries) { egg in
                            HStack(spacing: 12) {
                                Image(systemName: "circle.dashed.inset.filled")
                                    .font(.title3)
                                    .foregroundStyle(Wander.brand)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(egg.name).font(.body)
                                    if let cp = egg.cp {
                                        Text(cpLine(cp))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if egg.isAdventureSync {
                                    Image(systemName: "figure.walk")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel(L("pogo.hub.adventureSync",
                                                              fallback: "Adventure Sync egg"))
                                }
                                if egg.canBeShiny { shinyBadge }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Events

    @ViewBuilder private var eventsList: some View {
        if events.isEmpty {
            emptyState(L("pogo.hub.empty.events", fallback: "No active events right now."),
                       systemImage: "calendar")
        } else {
            List {
                ForEach(events) { event in
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.title3)
                            .foregroundStyle(Wander.brand)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.name).font(.body)
                            let subtitle = event.heading ?? event.eventType
                            if !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let window = eventWindow(event) {
                                Text(window)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Research

    @ViewBuilder private var researchList: some View {
        if research.isEmpty {
            emptyState(L("pogo.hub.empty.research", fallback: "No field research right now."),
                       systemImage: "magnifyingglass")
        } else {
            List {
                ForEach(research) { task in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.clipboard")
                                .font(.title3)
                                .foregroundStyle(Wander.brand)
                                .frame(width: 28)
                            Text(task.task)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if task.rewards.isEmpty {
                            Text(L("pogo.hub.research.noReward", fallback: "Reward varies"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 40)
                        } else {
                            ForEach(task.rewards) { reward in
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.turn.down.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(reward.name).font(.subheadline)
                                    if let cp = reward.cp {
                                        Text(cpLine(cp))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if reward.canBeShiny { shinyBadge }
                                }
                                .padding(.leading, 40)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Rocket

    @ViewBuilder private var rocketList: some View {
        if rocket.isEmpty {
            emptyState(L("pogo.hub.empty.rocket", fallback: "No Rocket lineup data right now."),
                       systemImage: "person.fill.questionmark")
        } else {
            List {
                ForEach(rocket) { lineup in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.fill.badge.minus")
                                .font(.title3)
                                .foregroundStyle(Wander.brand)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(lineup.name).font(.body)
                                let subtitle = rocketSubtitle(lineup)
                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(lineup.pokemon) { mon in
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(mon.name).font(.subheadline)
                                if !mon.types.isEmpty {
                                    Text(mon.types.joined(separator: " • "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if mon.isEncounter {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel(L("pogo.hub.rocket.encounter",
                                                              fallback: "Catchable encounter"))
                                }
                                if mon.canBeShiny { shinyBadge }
                            }
                            .padding(.leading, 40)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// "Shadow • normal-type" style subtitle for a Rocket lineup (type omitted when blank).
    private func rocketSubtitle(_ lineup: PoGoRocketLineup) -> String {
        var parts: [String] = [L("pogo.hub.rocket.shadow", fallback: "Shadow")]
        if let title = lineup.title, !title.isEmpty {
            parts.append(title)
        } else if !lineup.type.isEmpty {
            parts.append(String(format: L("pogo.hub.rocket.typeTheme", fallback: "%@-type"),
                                lineup.type.capitalized))
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - Shared

    private var shinyBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
            Text(L("pogo.hub.shiny", fallback: "Shiny"))
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.yellow)
        .accessibilityLabel(L("pogo.hub.canBeShiny", fallback: "Can be shiny"))
    }

    /// "CP 493–536" style line for a perfect-IV window (single value when min == max).
    private func cpLine(_ cp: PoGoCP) -> String {
        if cp.min == cp.max {
            return String(format: L("pogo.hub.cp.single", fallback: "CP %d"), cp.min)
        }
        return String(format: L("pogo.hub.cp.range", fallback: "CP %d–%d"), cp.min, cp.max)
    }

    /// Local-time window for an event. Uses a short relative-ish "Jul 15, 6:00 PM → 7:00 PM" form,
    /// collapsing the end date when it's the same day.
    private func eventWindow(_ event: PoGoEvent) -> String? {
        let df = DateFormatter()
        df.locale = .current
        df.timeZone = .current
        df.dateFormat = nil
        df.dateStyle = .medium
        df.timeStyle = .short

        switch (event.start, event.end) {
        case let (start?, end?):
            let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
            let startStr = df.string(from: start)
            if sameDay {
                let tf = DateFormatter()
                tf.locale = .current
                tf.timeZone = .current
                tf.timeStyle = .short
                tf.dateStyle = .none
                return "\(startStr) → \(tf.string(from: end))"
            }
            return "\(startStr) → \(df.string(from: end))"
        case let (start?, nil):
            return String(format: L("pogo.hub.event.starts", fallback: "Starts %@"),
                          df.string(from: start))
        case let (nil, end?):
            return String(format: L("pogo.hub.event.ends", fallback: "Ends %@"),
                          df.string(from: end))
        default:
            return nil
        }
    }

    @ViewBuilder private func emptyState(_ message: String, systemImage: String) -> some View {
        VStack {
            Spacer()
            Label(message, systemImage: systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    /// Fetch all five feeds. A single unreachable-server failure with NO cache shows the offline
    /// state; if the server responds (or a cache exists) but a feed is simply empty, we show that
    /// feed's empty state instead. `isOffline` is set only when every loaded feed came from cache.
    private func loadAll() async {
        isLoading = true
        loadError = nil

        async let raidsResult = WanderPoGoEvents.fetchRaids()
        async let eggsResult = WanderPoGoEvents.fetchEggs()
        async let eventsResult = WanderPoGoEvents.fetchEvents()
        async let researchResult = WanderPoGoEvents.fetchResearch()
        async let rocketResult = WanderPoGoEvents.fetchRocket()

        let (r, e, ev, rs, rk) = await (raidsResult, eggsResult, eventsResult, researchResult, rocketResult)

        var anySuccess = false
        var anyLive = false
        var firstError: String?

        func apply<T>(_ result: PoGoFetchResult<T>, into assign: (([T]) -> Void)) {
            switch result {
            case .success(let list, let fromCache):
                assign(list)
                anySuccess = true
                if !fromCache { anyLive = true }
            case .failed(let msg):
                firstError = firstError ?? msg
            }
        }

        apply(r) { raids = $0 }
        apply(e) { eggs = $0 }
        apply(ev) { events = $0 }
        apply(rs) { research = $0 }
        apply(rk) { rocket = $0 }

        // Only surface the offline/error screen when every feed failed AND nothing was cached. If
        // at least one loaded, trust the data and let per-tab empty states cover the rest.
        loadError = anySuccess ? nil : firstError
        // Offline note when we have data but none of it came live this round.
        isOffline = anySuccess && !anyLive
        isLoading = false
        hasLoaded = true
    }
}

#Preview {
    PoGoEventsSheet()
}
