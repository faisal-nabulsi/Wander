//
//  PlacesView.swift
//  Wander
//
//  Quick-teleport hub: recent spots, your saved places, and a set of famous
//  quick picks. Tapping any row jumps to the Teleport tab and starts simulating.
//
//  Saved places can be organized (FREE) with a folder, tags, and notes; the
//  Saved section can be filtered and grouped by folder or tag.
//
//  Also home to DestinationClock — the shared "what time is it THERE?" cache used by every
//  teleport-target row in the app (Places here, hotspots/routes in PoGo Mode). It lives with
//  the rows that introduced it, the same way PoGoCooldown lives in PoGoModeView.swift.
//

import SwiftUI
import CoreLocation
import UIKit   // UIPasteboard — for pasting a share link someone sent you

// MARK: - Destination local time

/// Resolves (and caches) the wall-clock time at a teleport target.
///
/// Spoofers hop time zones to chase events, so "3:42 AM local" next to a spot answers the question
/// they actually have before they jump. There's no offline time-zone database in the app — the only
/// per-coordinate zone source is CLGeocoder, which is ASYNC and aggressively rate-limited, so this
/// class exists purely to keep a scrolling list from ever touching it more than it must:
///
///  - results are cached by rounded coordinate (~1 km, far finer than any time-zone boundary) and
///    persisted, so a place resolves once ever rather than once per launch;
///  - lookups are queued and drained one at a time with a gap between them, so scrolling a list of
///    forty hotspots never fires forty simultaneous requests;
///  - a row that hasn't resolved yet renders NOTHING. No spinner, no placeholder, and above all no
///    guessed-from-longitude time — a wrong clock is worse than no clock for someone timing a raid.
@MainActor
final class DestinationClock: ObservableObject {
    static let shared = DestinationClock()

    /// Republished when the minute rolls over or a lookup lands. Rows read the formatted string, but
    /// they subscribe through this, which is what makes a resolved row appear without a refresh.
    @Published private(set) var now = Date()

    /// Resolved zones, keyed by rounded coordinate. Seeded from disk on init.
    private var zones: [String: TimeZone] = [:]
    /// Keys the geocoder ANSWERED for but had no time zone for — never retried this session, so one
    /// genuinely unresolvable coordinate can't re-enter the queue on every redraw and starve the good
    /// ones. Errors (rate limit, no network) never land here; see `resolve`.
    private var missing: Set<String> = []
    private var queue: [(key: String, coordinate: CLLocationCoordinate2D)] = []
    private var draining = false
    /// Consecutive geocoder failures. CLGeocoder answers a burst then rejects EVERYTHING for a while,
    /// so a run of failures means "stop asking", not "these places have no time zone".
    private var failureStreak = 0
    private var pausedUntil: Date?

    private let geocoder = CLGeocoder()
    private var clockTimer: Timer?

    /// One reusable formatter: building a DateFormatter per row per redraw is genuinely expensive.
    ///
    /// The locale is the DEVICE's, not a fixed one: this string is read by a human, so someone on
    /// 24-hour time must see "15:42" and someone running Wander in another language must see their
    /// own AM/PM marker. `setLocalizedDateFormatFromTemplate` asks for "hour + minute" and lets the
    /// locale decide the shape; the per-call `timeZone` assignment below is unaffected.
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let cacheKey = "destinationClock.zones"
    /// Gap between geocoder calls, and the cool-off after a burst of failures.
    private static let requestSpacing: TimeInterval = 0.4
    private static let pauseAfterFailures: TimeInterval = 5 * 60
    /// Ceiling on queued lookups. Only visible rows ask, but a fast scroll through a long list can
    /// still pile up requests we'd finish long after the user moved on.
    private static let maxQueued = 32

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String] ?? [:]
        zones = stored.compactMapValues { TimeZone(identifier: $0) }
    }

    deinit {
        clockTimer?.invalidate()
    }

    /// The destination's local time, e.g. "3:42 AM local" — or nil if we don't know it yet, in which
    /// case the lookup is queued and the row will fill itself in when the answer arrives.
    func localTime(for coordinate: CLLocationCoordinate2D) -> String? {
        let key = Self.key(for: coordinate)
        guard let zone = zones[key] else {
            enqueue(key: key, coordinate: coordinate)
            return nil
        }
        startClock()
        formatter.timeZone = zone
        return String(format: L("destination.localtime", fallback: "%@ local"),
                      formatter.string(from: now))
    }

    // MARK: Lookup queue

    /// ~1 km buckets. Coarse enough that neighbouring saved places share one lookup, fine enough that
    /// two spots either side of a time-zone border never collapse into the same answer.
    private static func key(for c: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    private func enqueue(key: String, coordinate: CLLocationCoordinate2D) {
        guard !missing.contains(key), !queue.contains(where: { $0.key == key }) else { return }
        if let pausedUntil, pausedUntil > Date() { return }
        guard queue.count < Self.maxQueued else { return }
        queue.append((key, coordinate))
        drain()
    }

    /// Serial drain: one request at a time with a gap between them. Runs detached from the view
    /// update that queued it, so nothing here can ever stall a scroll.
    private func drain() {
        guard !draining else { return }
        draining = true
        Task { @MainActor in
            defer { draining = false }
            while !queue.isEmpty {
                if let pausedUntil, pausedUntil > Date() {
                    queue.removeAll()
                    return
                }
                let next = queue.removeFirst()
                await resolve(key: next.key, coordinate: next.coordinate)
                try? await Task.sleep(nanoseconds: UInt64(Self.requestSpacing * 1_000_000_000))
            }
        }
    }

    private func resolve(key: String, coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await geocoder.reverseGeocodeLocation(location)
        } catch {
            // A THROWN error says nothing about this coordinate — it's the rate limiter or a dropped
            // connection. Deliberately NOT blacklisted: the coordinates unlucky enough to be first
            // through a rate limit are exactly the ones that would then stay blank for the life of
            // the process. The key stays eligible and the pause below does the backing off, so they
            // resolve on the next scroll once the geocoder is answering again.
            failureStreak += 1
            if failureStreak >= 3 {
                pausedUntil = Date().addingTimeInterval(Self.pauseAfterFailures)
                queue.removeAll()
            }
            return
        }
        // Answered, but with no time zone (mid-ocean, Antarctica). That IS a property of the point,
        // so this is the one case worth remembering — retrying it would burn rate-limit budget the
        // resolvable rows need. The streak resets either way: the geocoder is clearly talking to us.
        failureStreak = 0
        guard let zone = placemarks.first?.timeZone else {
            missing.insert(key)
            return
        }
        zones[key] = zone
        persist()
        startClock()
        now = Date()   // republish so the rows waiting on this key draw their clock
    }

    private func persist() {
        UserDefaults.standard.set(zones.mapValues { $0.identifier }, forKey: Self.cacheKey)
    }

    /// Half-minute tick so a displayed "h:mm" is never more than ~30 s stale. Added in `.common` mode
    /// so it keeps ticking while a list is being scrolled.
    private func startClock() {
        guard clockTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }
}

/// The row annotation for Feature B. Renders nothing until the zone is known, so it can sit in any
/// row without reserving space or flashing a placeholder.
struct DestinationLocalTimeLabel: View {
    let coordinate: CLLocationCoordinate2D

    @ObservedObject private var clock = DestinationClock.shared

    var body: some View {
        if let text = clock.localTime(for: coordinate) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// How the Saved section is filtered/grouped.
private enum PlacesFilter: Equatable {
    case all
    case folder(String)
    case tag(String)
}

struct PlacesView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.location.id
    // Places is presented as a SHEET from the More tab, so switching the tab underneath isn't
    // enough — we must dismiss this sheet too, or it stays on top covering the map.
    @Environment(\.dismiss) private var dismiss
    // Used to hand a PASTED share link back to the app's own deep-link handler (see importFromClipboard).
    @Environment(\.openURL) private var openURL
    @StateObject private var store = SavedPlacesStore()
    // Observed so the cooldown annotations below re-evaluate as the shared countdown ticks and as
    // each confirmed teleport moves the point every candidate jump is measured from.
    @ObservedObject private var session = SimulationSession.shared

    @State private var filter: PlacesFilter = .all
    @State private var editingPlace: LocationBookmark?
    @State private var showGlobe = false
    @State private var searchText = ""
    /// Why a pasted share link couldn't be read — shown verbatim from the decoder.
    @State private var importError: String?

    /// True while the user is typing a search query.
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                // While searching, focus purely on matching saved places — hide recents/quick picks.
                if !isSearching && !store.recents.isEmpty {
                    Section {
                        ForEach(store.recents) { place in
                            placeRow(place.name, coordText(place.coordinate),
                                     symbol: "clock.arrow.circlepath",
                                     coordinate: place.coordinate) {
                                teleport(to: place.coordinate, name: place.name)
                            }
                        }
                    } header: { Text(localized: "places.recent", fallback: "Recent") }
                }

                savedSections

                if !isSearching {
                    Section {
                        ForEach(QuickPlaces.all) { place in
                            placeRow(place.name, place.subtitle, symbol: place.symbol,
                                     coordinate: place.coordinate) {
                                teleport(to: place.coordinate, name: place.name)
                            }
                        }
                    } header: {
                        Text(localized: "places.quick_picks", fallback: "Quick picks")
                    } footer: {
                        Text(localized: "places.quick_picks_hint", fallback: "Tap any place to jump there and start simulating.")
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: L("places.search", fallback: "Search saved places"))
            .navigationTitle(L("places.title", fallback: "Places"))
            .toolbar {
                if !allFolders.isEmpty || !allTags.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { filterMenu }
                }
                ToolbarItem(placement: .topBarLeading) {
                    // Paste a link someone sent you. Lives next to the saved places because that's
                    // where an imported spot lands, and it's the screen people are on when a friend
                    // drops a link in chat.
                    Button {
                        importFromClipboard()
                    } label: {
                        Label(L("share.paste_link", fallback: "Paste share link"), systemImage: "arrow.down.doc")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // 3D globe (FREE): tap-to-teleport on a spinning globe.
                    Button {
                        showGlobe = true
                    } label: {
                        Label(L("globe.title", fallback: "Globe"), systemImage: "globe")
                    }
                }
                if !store.recents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("action.clear", fallback: "Clear")) { store.clearRecents() }
                    }
                }
            }
            // Full-screen (not a sheet): the sheet's swipe-down-to-dismiss fought the globe's
            // drag-to-rotate, so a downward drag dismissed instead of spinning. Full-screen has no
            // drag-dismiss — the globe owns every gesture; the "Done" button is the way out.
            .fullScreenCover(isPresented: $showGlobe) {
                GlobeSheet()
            }
            .onAppear { store.reload() }
            .onChange(of: selection) { _, newValue in
                if newValue == AppFeature.places.id { store.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .placesDidChange)) { _ in
                store.reload()
            }
            .sheet(item: $editingPlace) { place in
                PlaceMetadataEditor(place: place) { updated in
                    store.updateSaved(updated)
                    editingPlace = nil
                }
            }
            .alert(L("share.import.failed", fallback: "Can't read that link"),
                   isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button(L("action.ok", fallback: "OK"), role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: - Saved (organized) sections

    /// Saved places matching the free-text search (name, notes, folder, or tags),
    /// case- and diacritic-insensitive. Empty query = all saved places.
    private var searchedSaved: [LocationBookmark] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.saved }
        func has(_ s: String?) -> Bool {
            guard let s, !s.isEmpty else { return false }
            return s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return store.saved.filter { place in
            has(place.name) || has(place.notes) || has(place.folder) || place.tags.contains { has($0) }
        }
    }

    /// Places matching the active filter (search narrows within the folder/tag filter).
    private var filteredSaved: [LocationBookmark] {
        switch filter {
        case .all:
            return searchedSaved
        case .folder(let f):
            return searchedSaved.filter { ($0.folder ?? "") == f }
        case .tag(let t):
            return searchedSaved.filter { $0.tags.contains(t) }
        }
    }

    @ViewBuilder private var savedSections: some View {
        if store.saved.isEmpty {
            Section {
                Label(L("places.saved_empty", fallback: "Tap the bookmark on the Teleport tab to save a spot here."),
                      systemImage: "bookmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Text(localized: "places.saved", fallback: "Saved") }
        } else if case .all = filter {
            if isSearching && searchedSaved.isEmpty {
                Section {
                    Text(localized: "places.no_match", fallback: "No saved places match your search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text(localized: "places.saved", fallback: "Saved") }
            } else {
                // Group by folder when no specific filter is applied. Enumerated so the share hint
                // below lands once, under the last group, instead of after every folder.
                ForEach(Array(groupedByFolder.enumerated()), id: \.element.title) { index, group in
                    Section {
                        savedRows(group.places)
                    } header: {
                        Text(group.title)
                    } footer: {
                        if index == groupedByFolder.count - 1 { shareRecipientHint }
                    }
                }
            }
        } else {
            Section {
                savedRows(filteredSaved)
            } header: {
                Text(filterHeader)
            } footer: {
                if filteredSaved.isEmpty {
                    Text(localized: "places.no_match", fallback: "No saved places match this filter.")
                } else {
                    shareRecipientHint
                }
            }
        }
    }

    /// Sharing is only half a feature if the recipient can't open what arrives. The link opens Wander
    /// directly for anyone who has it installed, but the reliable route — and the only one that works
    /// at all until wanderspoofer.com/go exists — is pasting it, so say so next to the Share actions.
    private var shareRecipientHint: Text {
        Text(localized: "share.recipient_hint",
             fallback: "Swipe or long-press a saved place to share it. Whoever gets the link opens it here with Paste share link.")
    }

    private func savedRows(_ places: [LocationBookmark]) -> some View {
        ForEach(places) { place in
            savedRow(place)
        }
        .onDelete { offsets in deleteSaved(from: places, at: offsets) }
    }

    private func savedRow(_ place: LocationBookmark) -> some View {
        Button {
            teleport(to: place.coordinate, name: place.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .font(.body)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.body).foregroundStyle(.primary)
                    Text(coordText(place.coordinate)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    destinationAnnotations(place.coordinate)
                    if !place.tags.isEmpty {
                        Text(place.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(Wander.brand.opacity(0.85))
                    }
                    if let notes = place.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: Wander.Icon.simulate)
                    .font(.caption)
                    .foregroundStyle(Wander.brand.opacity(0.7))
            }
            .contentShape(Rectangle())
            .opacity(isCooldownBlocked(place.coordinate) ? Self.blockedRowOpacity : 1)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                editingPlace = place
            } label: {
                Label("Edit", systemImage: "tag")
            }
            .tint(Wander.brand)

            shareLink(for: place)
                .tint(.green)
        }
        // Also on long-press: a swipe action is invisible until you try it, and sharing a spot is
        // the thing people came here to do.
        .contextMenu { shareLink(for: place) }
    }

    /// The share control for a saved place. Hands over the WEB form — that's the one that survives
    /// being pasted into Discord and still opens the app for anyone who has it installed.
    @ViewBuilder private func shareLink(for place: LocationBookmark) -> some View {
        if let url = WanderShareLink.webURL(forSpot: place.coordinate, name: place.name) {
            ShareLink(item: url) {
                Label(L("share.share_spot", fallback: "Share spot"), systemImage: "square.and.arrow.up")
            }
        }
    }

    /// Read a share link out of the clipboard and hand it to the app's OWN deep-link handler by
    /// re-opening it as `wander://share…`. That reuses the one preview-and-confirm path in
    /// MainTabView instead of building a second one here — a pasted link and a tapped link then
    /// cannot diverge in what they validate or what they ask the user. Validation happens here
    /// first, so a bad paste reports why immediately instead of bouncing through the OS.
    ///
    /// The DECODED payload travels via `WanderShareLink.handoffURL(for:)` rather than inside the URL:
    /// a route link can be tens of kilobytes and `openURL` is not the place to move that much data.
    private func importFromClipboard() {
        // `hasStrings` answers "is there text on the clipboard?" WITHOUT reading it, so it doesn't
        // trip the iOS 16 "Allow Paste?" prompt. That's the only way to tell a genuinely empty
        // clipboard from a user who tapped Don't Allow — `.string` hands back nil for both, and
        // telling someone their clipboard is empty when it isn't sends them looking for the wrong
        // problem.
        guard UIPasteboard.general.hasStrings else {
            importError = L("share.import.empty_clipboard",
                            fallback: "Your clipboard doesn't have any text on it. Copy the whole share link first — it starts with https://wanderspoofer.com/go?")
            return
        }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importError = L("share.import.paste_denied",
                            fallback: "Wander didn't get access to what you copied. Tap Paste share link again and choose Allow Paste.")
            return
        }
        let handoff: URL
        do {
            handoff = WanderShareLink.handoffURL(for: try WanderShareLink.payload(fromPastedText: text))
        } catch {
            importError = error.localizedDescription
            return
        }
        // Places is usually presented as a sheet, and the import preview belongs to the root view
        // underneath it — so close this first, then open. The small delay lets the dismissal finish;
        // presenting into a view that's still animating away silently drops the dialog.
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            openURL(handoff)
        }
    }

    /// Delete honoring the currently displayed subset (offsets are into `places`).
    private func deleteSaved(from places: [LocationBookmark], at offsets: IndexSet) {
        let ids = offsets.map { places[$0].id }
        let storeOffsets = IndexSet(store.saved.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { $0.offset })
        store.deleteSaved(storeOffsets)
    }

    // MARK: - Grouping / filtering helpers

    private struct SavedGroup { let title: String; let places: [LocationBookmark] }

    /// Saved places grouped by folder, with un-foldered places last under "Ungrouped".
    /// Respects the active search query.
    private var groupedByFolder: [SavedGroup] {
        let base = searchedSaved
        let withFolder = Dictionary(grouping: base.filter { !($0.folder ?? "").isEmpty },
                                    by: { $0.folder ?? "" })
        var groups = withFolder
            .map { SavedGroup(title: $0.key, places: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let ungrouped = base.filter { ($0.folder ?? "").isEmpty }
        if !ungrouped.isEmpty {
            groups.append(SavedGroup(title: groups.isEmpty ? "Saved" : "Ungrouped", places: ungrouped))
        }
        return groups
    }

    private var allFolders: [String] {
        Array(Set(store.saved.compactMap { $0.folder }).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var allTags: [String] {
        Array(Set(store.saved.flatMap { $0.tags }).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filterHeader: String {
        switch filter {
        case .all: return "Saved"
        case .folder(let f): return "Folder: \(f)"
        case .tag(let t): return "Tag: #\(t)"
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filter = .all
            } label: {
                Label("All", systemImage: filter == .all ? "checkmark" : "")
            }
            if !allFolders.isEmpty {
                Section("Folders") {
                    ForEach(allFolders, id: \.self) { f in
                        Button {
                            filter = .folder(f)
                        } label: {
                            Label(f, systemImage: filter == .folder(f) ? "checkmark" : "folder")
                        }
                    }
                }
            }
            if !allTags.isEmpty {
                Section("Tags") {
                    ForEach(allTags, id: \.self) { t in
                        Button {
                            filter = .tag(t)
                        } label: {
                            Label("#\(t)", systemImage: filter == .tag(t) ? "checkmark" : "tag")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    // MARK: - Rows / actions

    private func placeRow(_ name: String, _ subtitle: String, symbol: String,
                          coordinate: CLLocationCoordinate2D,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    destinationAnnotations(coordinate)
                }
                Spacer()
                Image(systemName: Wander.Icon.simulate)
                    .font(.caption)
                    .foregroundStyle(Wander.brand.opacity(0.7))
            }
            .contentShape(Rectangle())
            .opacity(isCooldownBlocked(coordinate) ? Self.blockedRowOpacity : 1)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Destination annotations (informational)

    /// Dim, don't disable. The owner's standing rule is that guardrails inform and never enforce, so
    /// a "you're still on cooldown" row stays fully tappable — it just stops competing for the eye.
    private static let blockedRowOpacity: Double = 0.55

    /// Places is a general teleport hub, not a PoGo screen, so the soft-ban annotation would be pure
    /// noise for someone spoofing Find My. Show it only when the app already knows the user is in the
    /// anti-cheat flow: gs-loc mode is on (games-only path), or a cooldown is literally running.
    private var showsCooldownPreview: Bool {
        GslocMode.enabled || session.cooldownActive
    }

    /// The shared sub-line for a teleport-target row: what the jump would cost, and what time it is
    /// there. Both halves self-hide, so a row with nothing to say looks exactly as it did before.
    @ViewBuilder private func destinationAnnotations(_ coordinate: CLLocationCoordinate2D) -> some View {
        HStack(spacing: 6) {
            if showsCooldownPreview {
                CooldownPreviewLabel(destination: coordinate)
            }
            DestinationLocalTimeLabel(coordinate: coordinate)
        }
    }

    private func isCooldownBlocked(_ coordinate: CLLocationCoordinate2D) -> Bool {
        showsCooldownPreview && CooldownPreview.status(for: coordinate)?.isBlocked == true
    }

    private func coordText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    private func teleport(to coordinate: CLLocationCoordinate2D, name: String) {
        // Preview, don't teleport: jump to the Teleport tab and center + pin the spot. The user
        // presses Simulate there to actually move (which records the recent). This makes a tapped
        // Place behave the same as a tapped PoGo hotspot — select → preview → explicit Teleport.
        NotificationCenter.default.post(
            name: .previewLocationRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        selection = AppFeature.location.id   // switch the underlying tab to the map (Teleport)
        dismiss()                            // close the Places sheet so the map is actually revealed
    }
}

// MARK: - Metadata editor

/// Edit a saved place's folder, tags, and notes. Fully free organizing UI.
private struct PlaceMetadataEditor: View {
    let place: LocationBookmark
    let onSave: (LocationBookmark) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder: String
    @State private var tagsText: String
    @State private var notes: String

    init(place: LocationBookmark, onSave: @escaping (LocationBookmark) -> Void) {
        self.place = place
        self.onSave = onSave
        _folder = State(initialValue: place.folder ?? "")
        _tagsText = State(initialValue: place.tags.joined(separator: ", "))
        _notes = State(initialValue: place.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Place", value: place.name)
                    LabeledContent("Coordinate",
                                   value: String(format: "%.4f, %.4f", place.latitude, place.longitude))
                }

                Section {
                    TextField("Folder", text: $folder)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Group this place under a folder (leave blank for ungrouped).")
                }

                Section {
                    TextField("comma, separated, tags", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Organize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = place
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.folder = trimmedFolder.isEmpty ? nil : trimmedFolder
        updated.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        updated.updatedAt = Date()   // stamp so this edit wins the multi-device sync merge
        onSave(updated)
    }
}

#Preview {
    PlacesView()
}
