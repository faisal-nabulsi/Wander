//
//  SavedPlaces.swift
//  Wander
//
//  Backing store for the Places tab: the user's saved spots (shared with the
//  Teleport screen's bookmarks), a lightweight "recent teleports" list, and a
//  set of famous quick-pick locations so the screen is useful out of the box.
//

import Foundation
import CoreLocation

extension Notification.Name {
    /// Posted with userInfo ["lat": Double, "lng": Double] to ask the Teleport
    /// screen to jump to — and start simulating — a coordinate.
    static let teleportToRequested = Notification.Name("wander.teleportToRequested")

    /// Posted whenever the saved-places or recents store changes, so any live
    /// view (Places tab, Teleport bookmarks) can reload from the shared store.
    static let placesDidChange = Notification.Name("wander.placesDidChange")
}

/// A famous location shown on the Places screen out of the box.
struct QuickPlace: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let symbol: String
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum QuickPlaces {
    static let all: [QuickPlace] = [
        .init(name: "Eiffel Tower", subtitle: "Paris, France", symbol: "sparkles", latitude: 48.8584, longitude: 2.2945),
        .init(name: "Times Square", subtitle: "New York, USA", symbol: "building.2.fill", latitude: 40.7580, longitude: -73.9855),
        .init(name: "Big Ben", subtitle: "London, UK", symbol: "clock.fill", latitude: 51.5007, longitude: -0.1246),
        .init(name: "Shibuya Crossing", subtitle: "Tokyo, Japan", symbol: "figure.walk", latitude: 35.6595, longitude: 139.7004),
        .init(name: "Sydney Opera House", subtitle: "Sydney, Australia", symbol: "music.note.house.fill", latitude: -33.8568, longitude: 151.2153),
        .init(name: "Golden Gate Bridge", subtitle: "San Francisco, USA", symbol: "road.lanes", latitude: 37.8199, longitude: -122.4783),
        .init(name: "Colosseum", subtitle: "Rome, Italy", symbol: "building.columns.fill", latitude: 41.8902, longitude: 12.4922),
        .init(name: "Burj Khalifa", subtitle: "Dubai, UAE", symbol: "building.fill", latitude: 25.1972, longitude: 55.2744),
    ]
}

/// Loads/saves the user's places from the same store the Teleport screen uses
/// (`locationBookmarks`), plus a capped recents list (`recentPlaces`).
@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published var saved: [LocationBookmark] = []
    @Published var recents: [LocationBookmark] = []

    private let savedKey = "locationBookmarks"
    private static let recentsKey = "recentPlaces"

    func reload() {
        saved = Self.decode(key: savedKey)
        recents = Self.decode(key: Self.recentsKey)
    }

    func deleteSaved(_ offsets: IndexSet) {
        saved.remove(atOffsets: offsets)
        persistSaved()
    }

    /// Replace a saved place in-place (used when editing its folder/tags/notes) and persist.
    func updateSaved(_ bookmark: LocationBookmark) {
        guard let idx = saved.firstIndex(where: { $0.id == bookmark.id }) else { return }
        saved[idx] = bookmark
        persistSaved()
    }

    private func persistSaved() {
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
        NotificationCenter.default.post(name: .placesDidChange, object: nil)
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    /// The recent teleports, most-recent first (for read-only use such as GPX export).
    static func exportRecents() -> [LocationBookmark] {
        decode(key: recentsKey)
    }

    private static func decode(key: String) -> [LocationBookmark] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return [] }
        return decoded
    }

    /// Records a recent teleport (most-recent first, de-duplicated, capped at 12).
    static func recordRecent(_ coordinate: CLLocationCoordinate2D, name: String) {
        var list = decode(key: recentsKey)
        list.removeAll {
            abs($0.latitude - coordinate.latitude) < 0.0001 &&
            abs($0.longitude - coordinate.longitude) < 0.0001
        }
        list.insert(LocationBookmark(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude), at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
        NotificationCenter.default.post(name: .placesDidChange, object: nil)
    }
}
