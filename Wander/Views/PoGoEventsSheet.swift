//
//  PoGoEventsSheet.swift
//  Wander
//
//  FREE read-only overlay of current Pokémon GO raids, egg pools, and events, fetched from the
//  Worker's public /pogo/events endpoint (LeekDuck / ScrapedDuck community data). Display only —
//  we never use any coordinates from this feed; it's purely "what's live in the game right now".
//
//  Three segments:
//    • Raids  — current bosses grouped by tier, with type chips + a shiny sparkle.
//    • Eggs   — species grouped by egg distance ("2 km", "7 km", …), shiny + Adventure Sync marks.
//    • Events — current in-game events with their type/heading.
//
//  Empty and offline states are handled inline (no crash, no blank screen).
//

import SwiftUI

private enum PoGoEventsTab: String, CaseIterable, Identifiable {
    case raids, eggs, events
    var id: String { rawValue }
    var title: String {
        switch self {
        case .raids: return "Raids"
        case .eggs: return "Eggs"
        case .events: return "Events"
        }
    }
}

struct PoGoEventsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var tab: PoGoEventsTab = .raids

    @State private var raids: [PoGoRaidBoss] = []
    @State private var eggs: [PoGoEggEntry] = []
    @State private var events: [PoGoEvent] = []

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(PoGoEventsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .top])

                content
            }
            .navigationTitle("Live in PoGo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await loadAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh")
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
            ProgressView("Loading current data…")
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
                Button("Try again") { Task { await loadAll() } }
                    .buttonStyle(.bordered)
            }
            .padding()
            Spacer()
        } else {
            switch tab {
            case .raids: raidsList
            case .eggs: eggsList
            case .events: eventsList
            }
        }
    }

    // MARK: - Raids

    /// Bosses grouped by tier, tiers in a sensible order (T5 / Mega / Shadow before the rest).
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
            emptyState("No raids reported right now.", systemImage: "shield.slash")
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
            emptyState("No egg pool data right now.", systemImage: "circle.dashed")
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
                                Text(egg.name).font(.body)
                                Spacer()
                                if egg.isAdventureSync {
                                    Image(systemName: "figure.walk")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Adventure Sync egg")
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
            emptyState("No active events right now.", systemImage: "calendar")
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
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Shared

    private var shinyBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
            Text("Shiny")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.yellow)
        .accessibilityLabel("Can be shiny")
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

    /// Fetch all three feeds. A single unreachable-server failure shows the offline state; if the
    /// server responds but a feed is simply empty, we show that feed's empty state instead.
    private func loadAll() async {
        isLoading = true
        loadError = nil

        async let raidsResult = WanderPoGoEvents.fetchRaids()
        async let eggsResult = WanderPoGoEvents.fetchEggs()
        async let eventsResult = WanderPoGoEvents.fetchEvents()

        let (r, e, ev) = await (raidsResult, eggsResult, eventsResult)

        var anySuccess = false
        var firstError: String?

        switch r {
        case .success(let list): raids = list; anySuccess = true
        case .failed(let msg): firstError = firstError ?? msg
        }
        switch e {
        case .success(let list): eggs = list; anySuccess = true
        case .failed(let msg): firstError = firstError ?? msg
        }
        switch ev {
        case .success(let list): events = list; anySuccess = true
        case .failed(let msg): firstError = firstError ?? msg
        }

        // Only surface the offline/error screen when every feed failed. If at least one loaded,
        // trust the data and let per-tab empty states cover the rest.
        loadError = anySuccess ? nil : firstError
        isLoading = false
        hasLoaded = true
    }
}

#Preview {
    PoGoEventsSheet()
}
