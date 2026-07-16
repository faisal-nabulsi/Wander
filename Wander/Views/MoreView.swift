//
//  MoreView.swift
//  Wander
//
//  The "More" tab — a real, organized hub that REPLACES iOS's auto-generated 2-row overflow.
//  That overflow appeared only because the bottom bar had 6 items (> the 5-tab limit): iOS
//  shoved the last two (Places, Settings) into a bare system list and left the rest of the
//  screen blank. Now the bar has 5 real tabs and this authored hub surfaces the secondary
//  feature screens, grouped so the space reads as intentional.
//
//  Each screen has EXACTLY ONE home to avoid redundancy: config lives in Settings, advanced /
//  diagnostic screens live under Tools, and everyday feature screens live here. So Geofences and
//  Manage-Devices (which have Settings homes) and App-expiry / dev tools (under Tools) are NOT
//  duplicated as rows here.
//
//  Each row opens its screen as a sheet. Every destination here brings its OWN navigation
//  chrome (their own NavigationStack), so presenting them modally avoids the nested-stack
//  "lost back button" problem a NavigationLink drill-down would cause; swipe-down dismisses.
//

import SwiftUI

struct MoreView: View {
    @State private var route: MoreRoute?

    var body: some View {
        NavigationStack {
            List {
                Section(L("more.section.spots", fallback: "Spots & planning")) {
                    row(.places)
                    row(.schedule)
                    row(.itinerary)
                }
                Section(L("more.section.maps", fallback: "Maps & tools")) {
                    row(.offlineMaps)
                    row(.tools)
                }
                Section {
                    row(.settings)
                }
            }
            .navigationTitle(L("tab.more", fallback: "More"))
        }
        .sheet(item: $route) { $0.destination }
    }

    private func row(_ route: MoreRoute) -> some View {
        Button {
            self.route = route
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title).foregroundStyle(.primary)
                    Text(route.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: route.icon)
            }
        }
    }
}

/// The secondary screens reachable from More, presented as sheets.
private enum MoreRoute: String, Identifiable {
    case places, schedule, itinerary, offlineMaps, tools, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .places:      return L("tab.places", fallback: "Places")
        case .schedule:    return L("tab.schedule", fallback: "Schedule")
        case .itinerary:   return L("tab.itinerary", fallback: "Itinerary")
        case .offlineMaps: return L("more.offline_maps", fallback: "Offline maps")
        case .tools:       return L("more.tools", fallback: "Tools")
        case .settings:    return L("tab.settings", fallback: "Settings")
        }
    }

    var subtitle: String {
        switch self {
        case .places:      return "Saved & recent spots"
        case .schedule:    return "Be at a place during set hours"
        case .itinerary:   return "Timed schedule of stops (Pro)"
        case .offlineMaps: return "Download regions for offline use"
        case .tools:       return "Device info, app expiry & developer tools"
        case .settings:    return "Configure Wander"
        }
    }

    var icon: String {
        switch self {
        case .places:      return "star.fill"
        case .schedule:    return "calendar.badge.clock"
        case .itinerary:   return "calendar.day.timeline.left"
        case .offlineMaps: return "square.and.arrow.down.on.square"
        case .tools:       return "wrench.and.screwdriver"
        case .settings:    return "gearshape.fill"
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .places:      PlacesView()
        case .schedule:    ScheduleView()
        case .itinerary:   ItineraryQueueView()
        case .offlineMaps: OfflineMapsSheet()
        case .tools:       ToolsView()
        case .settings:    SettingsView()
        }
    }
}
