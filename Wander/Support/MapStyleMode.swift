//
//  MapStyleMode.swift
//  Wander
//
//  User-selectable base map imagery for the location picker. Lets the user
//  preview the terrain (satellite / hybrid) before teleporting. Persisted via
//  @AppStorage so the choice sticks across launches.
//

import SwiftUI
import MapKit

/// The base imagery the map renders. Backed by a raw String so it round-trips
/// cleanly through @AppStorage.
enum MapStyleMode: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    /// The concrete SwiftUI `MapStyle` for this mode.
    var mapStyle: MapStyle {
        switch self {
        case .standard:
            return .standard(elevation: .realistic)
        case .satellite:
            return .imagery(elevation: .realistic)
        case .hybrid:
            return .hybrid(elevation: .realistic)
        }
    }

    /// SF Symbol shown on the switcher button for this mode.
    var symbol: String {
        switch self {
        case .standard: return "map.fill"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "map"
        }
    }

    /// Human-readable label for the picker menu.
    var label: String {
        switch self {
        case .standard: return L("map.style.standard", fallback: "Standard")
        case .satellite: return L("map.style.satellite", fallback: "Satellite")
        case .hybrid: return L("map.style.hybrid", fallback: "Hybrid")
        }
    }
}
