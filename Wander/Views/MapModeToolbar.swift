//
//  MapModeToolbar.swift
//  Wander
//
//  THE ONE navigation-bar toolbar for the three map tabs (Teleport, Joystick, Route).
//
//  WHY THIS FILE EXISTS AT ALL — read before adding, removing or "just tweaking" a button.
//
//  Teleport used to hang five buttons off its navigation bar while Joystick and Route hung none,
//  so the top of the app changed shape depending on which map mode you were on. Those five were
//  then deleted outright, which fixed the uneven tops but re-buried two features people actually
//  want in one tap — saved Places and Offline maps — behind More. Both of those were real
//  complaints, and this file is the answer to both at once: ONE definition, applied identically to
//  all three tabs, so promoting a feature can never again make one tab taller or busier than its
//  neighbours. Three copies of a toolbar is exactly how the chrome diverged the first time.
//
//  THE SHAPE, and why it is this shape:
//
//    leading   Places        — the single most-used buried destination. It is the reason the old
//                              "Bookmarks" button existed; it now opens the REAL screen (search,
//                              folders, tags, sharing) instead of a smaller second copy of it.
//    trailing  Offline maps  — the other thing nobody should have to dig through More for.
//    trailing  …             — everything else map-relevant that lives in More: Geofences,
//                              Schedule, Timeline, plus the current tab's file actions.
//
//  THREE VISIBLE ITEMS IS THE BUDGET. An inline bar is ~44pt with a centred title; five glyphs
//  squeezed that title out last time, which is why the long tail lives in a `Menu` instead of
//  getting its own glyph. If you want to add something up here, add it to the menu.
//
//  WHAT MUST NOT GO IN HERE: a shortcut to the Route tab. Route is a permanent bottom tab — a
//  toolbar button to it is a second, hidden copy of navigation the app already has, and it is the
//  specific redundancy this design was asked to drop. Same test for anything else: if it is
//  already one tap away from the tab bar, it does not belong up here.
//
//  DESTINATIONS ARE NOT FORKED. Every screen below is the SAME view the More hub presents (see
//  `MoreRoute.destination` in MoreView.swift) — same type, same modal chrome, no second copy.
//
//  HEIGHT: adding toolbar ITEMS does not change the bar's height, so `MapModeChrome.topChrome`
//  and the crosshair derived from it are unaffected. Switching a tab to a large title (or adding
//  a `.searchable` field up here) WOULD change it — don't.
//

import SwiftUI

// MARK: - Destinations

/// The More-hub screens the map toolbar can open.
///
/// A deliberately small mirror of the cases in `MoreRoute` (which is file-private to MoreView) —
/// it presents the identical view types, so there is one implementation of each screen and this
/// enum is only a menu of them. If a destination's presentation changes in `MoreRoute`, change it
/// here too; nothing will fail to compile if you forget, and the two would quietly drift.
private enum MapToolbarDestination: String, Identifiable, CaseIterable {
    case places, offlineMaps, geofences, schedule, timeline

    var id: String { rawValue }

    /// The order the overflow menu lists them in. `places` and `offlineMaps` are absent because
    /// they are the two that earned a glyph of their own.
    static let overflow: [MapToolbarDestination] = [.geofences, .schedule, .timeline]

    var title: String {
        switch self {
        case .places:      return L("tab.places", fallback: "Places")
        case .offlineMaps: return L("more.offline_maps", fallback: "Offline maps")
        case .geofences:   return L("more.geofences", fallback: "Geofences")
        case .schedule:    return L("tab.schedule", fallback: "Schedule")
        case .timeline:    return L("timeline.title", fallback: "Timeline")
        }
    }

    var icon: String {
        switch self {
        case .places:      return Wander.Icon.places
        case .offlineMaps: return Wander.Icon.offlineMaps
        case .geofences:   return Wander.Icon.geofence
        case .schedule:    return Wander.Icon.schedule
        case .timeline:    return Wander.Icon.timeline
        }
    }

    /// Presented as a sheet, exactly as the More hub presents them: each screen brings its own
    /// navigation chrome, so a sheet avoids the nested-stack "lost back button" problem and
    /// swipe-down dismisses.
    @ViewBuilder var destination: some View {
        switch self {
        case .places:      PlacesView()
        case .offlineMaps: OfflineMapsSheet()
        case .geofences:   NavigationStack { GeofenceListView() }
        case .schedule:    ScheduleView()
        // ⚠️ Same cross-task dependency MoreView carries: `SpoofTimelineView` lives in
        // Wander/Views/TimelineView.swift. If that file is ever dropped, delete the `.timeline`
        // case here and in `overflow` above and nothing else needs to change.
        case .timeline:    NavigationStack { SpoofTimelineView() }
        }
    }
}

// MARK: - Per-tab file actions

/// The file actions the CURRENT tab can offer, handed in by that tab because only it knows what
/// "the current thing" is — the pin on Teleport, the waypoints on Route.
///
/// Both are optional on purpose. A tab with nothing to import into, or nothing to write out, omits
/// the menu item entirely rather than showing one that is permanently greyed or, worse, silently
/// does nothing. A dead row is a bug report waiting to happen.
struct MapModeFileActions {
    /// Open this tab's coordinate/route file importer. Nil ⇒ this tab has nowhere to put a file.
    var importCoordinates: (() -> Void)?
    /// Write this tab's current subject out as GPX. Nil ⇒ this tab has no subject to write.
    var exportGPX: (() -> Void)?

    init(importCoordinates: (() -> Void)? = nil, exportGPX: (() -> Void)? = nil) {
        self.importCoordinates = importCoordinates
        self.exportGPX = exportGPX
    }

    /// No file actions at all (Joystick: it has no pin and no route of its own — it moves whatever
    /// is already live).
    static let none = MapModeFileActions()

    var isEmpty: Bool { importCoordinates == nil && exportGPX == nil }
}

// MARK: - The toolbar

private struct MapModeToolbarModifier: ViewModifier {
    let files: MapModeFileActions

    @State private var destination: MapToolbarDestination?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    button(for: .places)
                }
                // Declared before the menu, so it renders to the LEFT of it.
                ToolbarItem(placement: .topBarTrailing) {
                    button(for: .offlineMaps)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(MapToolbarDestination.overflow) { item in
                            Button { open(item) } label: {
                                Label(item.title, systemImage: item.icon)
                            }
                        }
                        if !files.isEmpty {
                            // A separate section, because these act on what's on screen right now
                            // while everything above navigates somewhere else.
                            Section {
                                if let importCoordinates = files.importCoordinates {
                                    Button { perform(importCoordinates) } label: {
                                        Label(L("map.toolbar.import", fallback: "Import coordinates"),
                                              systemImage: Wander.Icon.importFile)
                                    }
                                }
                                if let exportGPX = files.exportGPX {
                                    Button { perform(exportGPX) } label: {
                                        Label(L("map.toolbar.export", fallback: "Export GPX"),
                                              systemImage: Wander.Icon.export)
                                    }
                                }
                            }
                        }
                    } label: {
                        // The glyph is the whole control, so it needs a spoken name of its own —
                        // VoiceOver reads "ellipsis.circle" otherwise.
                        Label(L("map.toolbar.more", fallback: "More"), systemImage: Wander.Icon.overflow)
                    }
                    .accessibilityLabel(L("map.toolbar.more", fallback: "More"))
                }
            }
            .sheet(item: $destination) { $0.destination }
    }

    private func button(for item: MapToolbarDestination) -> some View {
        Button { open(item) } label: {
            Label(item.title, systemImage: item.icon)
        }
        .accessibilityLabel(item.title)
    }

    private func open(_ item: MapToolbarDestination) {
        perform { destination = item }
    }

    /// One place every item in this bar runs through, so the two behaviours below can't drift
    /// between the bar buttons and the menu rows.
    ///
    /// The haptic is fired imperatively (not via `.wanderFeedback(on:)`) so DISMISSING a sheet —
    /// which also changes `destination` — stays silent. Same reasoning, and the same feel, as
    /// `MoreView.open(_:)`.
    ///
    /// The one-runloop hop is for the menu rows: `Menu` is still tearing its own presentation down
    /// when the button's action runs, and a sheet or file picker put up in that same turn can be
    /// swallowed — the tap then looks like it did nothing, which is the worst possible failure for
    /// a shortcut whose whole job is being faster than digging through More. The bar buttons don't
    /// strictly need it, but they share the path so the two can't behave differently.
    private func perform(_ action: @escaping () -> Void) {
        WanderFeedback.selection.play()
        DispatchQueue.main.async(execute: action)
    }
}

extension View {
    /// The shared map-tab navigation bar: Places, Offline maps, and a "…" holding Geofences,
    /// Schedule, Timeline and this tab's file actions.
    ///
    /// Apply it to the content INSIDE each map tab's `NavigationStack`, right after
    /// `.navigationBarTitleDisplayMode(.inline)`. All three tabs must call it — that is the entire
    /// point of it being one function.
    func mapModeToolbar(files: MapModeFileActions = .none) -> some View {
        modifier(MapModeToolbarModifier(files: files))
    }
}
