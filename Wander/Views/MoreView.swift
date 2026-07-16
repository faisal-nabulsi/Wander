//
//  MoreView.swift
//  Wander
//
//  The "More" tab — a real, organized hub that REPLACES iOS's auto-generated 2-row overflow.
//  Each secondary FEATURE screen has exactly ONE home here (config stays in Settings, advanced /
//  diagnostic screens stay under Tools), so nothing double-shows. Geofences lives here (a feature
//  screen), not in Settings.
//
//  Each row opens its screen as a sheet. Every destination brings its OWN navigation chrome, so
//  presenting them modally avoids the nested-stack "lost back button" problem; swipe-down dismisses.
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
                    row(.geofences)
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
    case places, schedule, itinerary, geofences, offlineMaps, tools, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .places:      return L("tab.places", fallback: "Places")
        case .schedule:    return L("tab.schedule", fallback: "Schedule")
        case .itinerary:   return L("tab.itinerary", fallback: "Itinerary")
        case .geofences:   return L("more.geofences", fallback: "Geofences")
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
        case .geofences:   return "Resume real GPS when you actually arrive"
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
        case .geofences:   return "mappin.and.ellipse"
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
        case .geofences:   NavigationStack { GeofenceListView() }
        case .offlineMaps: OfflineMapsSheet()
        case .tools:       ToolsView()
        case .settings:    SettingsView()
        }
    }
}
