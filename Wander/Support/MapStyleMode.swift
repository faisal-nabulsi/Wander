//
//  MapStyleMode.swift
//  Wander
//
//  User-selectable base map imagery for the location picker. Lets the user
//  preview the terrain (satellite / hybrid) before teleporting. Persisted via
//  @AppStorage so the choice sticks across launches.
//
//  Also owns WHICH points of interest the base map is allowed to draw. That is a
//  map-honesty decision as much as a cosmetic one — see `MapPOIPreset`.
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

    /// The concrete SwiftUI `MapStyle` for this mode, with every POI Apple knows
    /// about drawn. Kept for surfaces that have no notion of context (the geofence
    /// editor); the picker map uses `mapStyle(pointsOfInterest:)` instead.
    var mapStyle: MapStyle {
        mapStyle(pointsOfInterest: .all)
    }

    /// The concrete SwiftUI `MapStyle` for this mode, drawing only `pointsOfInterest`.
    ///
    /// `showsTraffic` is passed EXPLICITLY as `false` rather than left to the default.
    /// Wander reports a location the device is not at, so any traffic overlay we drew
    /// would be real congestion for a place the user is only pretending to be — an
    /// honest-looking signal built on a fake premise. Someone reading "heavy traffic"
    /// beside their spoofed pin could reasonably believe it describes their trip. It
    /// never does. Stating it here means a future SDK flipping the default can't
    /// quietly turn it on.
    func mapStyle(pointsOfInterest: PointOfInterestCategories) -> MapStyle {
        switch self {
        case .standard:
            return .standard(
                elevation: .realistic,
                pointsOfInterest: pointsOfInterest,
                showsTraffic: false
            )
        case .satellite:
            // `.imagery` draws no labels or POIs at all, so it takes neither
            // parameter — satellite is already the "nothing but ground truth" style.
            return .imagery(elevation: .realistic)
        case .hybrid:
            return .hybrid(
                elevation: .realistic,
                pointsOfInterest: pointsOfInterest,
                showsTraffic: false
            )
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

/// Which points of interest the base map draws.
///
/// A spoofer's map is a PLANNING surface, and what you're planning changes which
/// pins are signal and which are clutter. Someone picking a Pokémon GO spot needs
/// parks, beaches and museums (that's where stops and spawns cluster); someone
/// staging a plausible evening for Find My or Life360 needs cafés, gyms and shops
/// (that's where a person plausibly is). Drawing all of both means neither user can
/// read the map, and while a route polyline or a joystick track is on screen the
/// POIs simply cover the line the user is trying to follow.
enum MapPOIPreset: String, CaseIterable, Identifiable {
    /// Follow the app's own context: the games set in PoGo (gs-loc) mode, the
    /// everyday set otherwise, and nothing at all while a route or joystick track
    /// is being drawn. The default, and the only option most people should need.
    case automatic
    /// Outdoor / landmark places: where games cluster their stops and spawns.
    case games
    /// Everyday places: where a person plausibly spends an evening.
    case everyday
    /// Draw no POIs — the bare map.
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return L("map.poi.automatic", fallback: "Places: Automatic")
        case .games:     return L("map.poi.games", fallback: "Places: Parks & landmarks")
        case .everyday:  return L("map.poi.everyday", fallback: "Places: Cafés & shops")
        case .hidden:    return L("map.poi.hidden", fallback: "Places: Hidden")
        }
    }

    var symbol: String {
        switch self {
        case .automatic: return "wand.and.stars"
        case .games:     return "tree.fill"
        case .everyday:  return "cup.and.saucer.fill"
        case .hidden:    return "eye.slash"
        }
    }

    /// Parks, water, landmarks and the indoor attractions games seed stops around.
    ///
    /// NOTE: the app still deploys to iOS 17.4, so the categories Apple added in
    /// iOS 18 (landmark, castle, hiking, …) are appended only where they exist.
    /// On 17 the set is simply a little coarser — never a build or runtime failure.
    static var gamesCategories: PointOfInterestCategories {
        var categories: [MKPointOfInterestCategory] = [
            .park, .nationalPark, .beach, .marina, .campground,
            .museum, .aquarium, .zoo, .amusementPark,
            .stadium, .library, .university, .school,
            .publicTransport
        ]
        if #available(iOS 18.0, *) {
            categories += [
                .planetarium, .landmark, .nationalMonument, .castle, .fortress,
                .hiking, .skatePark, .fairground
            ]
        }
        return .including(categories)
    }

    /// The places a believable daily routine is made of.
    static var everydayCategories: PointOfInterestCategories {
        var categories: [MKPointOfInterestCategory] = [
            .cafe, .restaurant, .bakery, .brewery, .winery, .nightlife,
            .fitnessCenter,
            .store, .foodMarket, .pharmacy, .laundry,
            .hotel, .movieTheater, .theater,
            .bank, .atm, .gasStation, .evCharger, .parking, .publicTransport
        ]
        if #available(iOS 18.0, *) {
            categories += [.spa, .beauty, .musicVenue]
        }
        return .including(categories)
    }

    /// Resolve the preset against the app's live context.
    ///
    /// - Parameters:
    ///   - gamesMode: PoGo (gs-loc) mode is on, so the games set is the right default.
    ///   - drawingPath: a route polyline or joystick track is on screen; POIs are
    ///     suppressed regardless of preset so the line stays legible. This is a
    ///     legibility rule, not a preference, which is why it overrides everything
    ///     except an explicit non-automatic choice… and not even that.
    static func categories(
        for preset: MapPOIPreset,
        gamesMode: Bool,
        drawingPath: Bool
    ) -> PointOfInterestCategories {
        // The path always wins: a polyline the user cannot see is a broken feature,
        // whereas a temporarily bare map is merely quiet.
        if drawingPath { return .excludingAll }
        switch preset {
        case .automatic: return gamesMode ? gamesCategories : everydayCategories
        case .games:     return gamesCategories
        case .everyday:  return everydayCategories
        case .hidden:    return .excludingAll
        }
    }
}
