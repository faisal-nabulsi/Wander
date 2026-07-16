//
//  AppFeature.swift
//  Wander
//

import SwiftUI

enum AppFeature: String, CaseIterable, Identifiable {
    case home
    case scripts
    case tools
    case console
    case deviceInfo = "deviceinfo"
    case profiles
    case processes
    case location
    case walk
    case route
    case itinerary
    case schedule
    case pogo
    case places
    case settings
    case more

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .home:
            return "Apps"
        case .scripts:
            return "Scripts"
        case .tools:
            return "Tools"
        case .console:
            return "Console"
        case .deviceInfo:
            return "Device Info"
        case .profiles:
            return "App Expiry"
        case .processes:
            return "Processes"
        case .location:
            return L("tab.teleport", fallback: "Teleport")
        case .walk:
            return L("tab.joystick", fallback: "Joystick")
        case .route:
            return L("tab.route", fallback: "Route")
        case .itinerary:
            return L("tab.itinerary", fallback: "Itinerary")
        case .schedule:
            return L("tab.schedule", fallback: "Schedule")
        case .pogo:
            return L("tab.pogo", fallback: "PoGo")
        case .places:
            return L("tab.places", fallback: "Places")
        case .settings:
            return L("tab.settings", fallback: "Settings")
        case .more:
            return L("tab.more", fallback: "More")
        }
    }

    var detail: String {
        switch self {
        case .home:
            return "Manage installed apps"
        case .scripts:
            return "Manage and run JS scripts"
        case .tools:
            return "Access additional tools"
        case .console:
            return "Live device logs"
        case .deviceInfo:
            return "View detailed device metadata"
        case .profiles:
            return "Check app expiration dates"
        case .processes:
            return "Inspect running apps"
        case .location:
            return "Simulate GPS location"
        case .walk:
            return "Move with a joystick"
        case .route:
            return "Drive a set path"
        case .itinerary:
            return "Timed schedule of stops (Pro)"
        case .schedule:
            return "Be at a place during set hours"
        case .pogo:
            return "Pokémon GO hotspots & cooldown"
        case .places:
            return "Saved & recent spots"
        case .settings:
            return "Configure Wander"
        case .more:
            return "Places, planning, tools & settings"
        }
    }

    var toolTitle: String {
        switch self {
        case .location:
            return "Location Simulation"
        default:
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "square.grid.2x2"
        case .scripts:
            return "scroll"
        case .tools:
            return "wrench.and.screwdriver"
        case .console:
            return "terminal"
        case .deviceInfo:
            return "iphone.and.arrow.forward"
        case .profiles:
            return "calendar.badge.clock"
        case .processes:
            return "rectangle.stack.person.crop"
        case .location:
            return Wander.Icon.teleport
        case .walk:
            return Wander.Icon.joystick
        case .route:
            return Wander.Icon.route
        case .itinerary:
            return "calendar.day.timeline.left"
        case .schedule:
            return "calendar.badge.clock"
        case .pogo:
            return "gamecontroller.fill"
        case .places:
            return "star.fill"
        case .settings:
            return Wander.Icon.settings
        case .more:
            return "ellipsis.circle"
        }
    }

    @ViewBuilder
    var destination: some View {
        switch self {
        case .home:
            HomeView()
        case .scripts:
            ScriptListView()
        case .tools:
            ToolsView()
        case .console:
            ConsoleLogsView()
        case .deviceInfo:
            DeviceInfoView()
        case .profiles:
            ProfileView()
        case .processes:
            ProcessInspectorView()
        case .location:
            LocationSimulationView()
        case .walk:
            WalkModeView()
        case .route:
            RouteModeView()
        case .itinerary:
            ItineraryQueueView()
        case .schedule:
            ScheduleView()
        case .pogo:
            PoGoModeView()
        case .places:
            PlacesView()
        case .settings:
            SettingsView()
        case .more:
            MoreView()
        }
    }
}

extension AppFeature {
    static let mainTabs: [AppFeature] = [.location, .walk, .route, .pogo, .more]
    static let toolList: [AppFeature] = [.schedule, .itinerary, .scripts, .console, .deviceInfo, .profiles, .processes, .location]
}
