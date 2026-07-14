//
//  SavedRoutes.swift
//  Wander
//
//  Backing store for the Pro "Save-loop builder": named user routes, each a
//  captured array of waypoint coordinates. Persisted to UserDefaults exactly
//  like SavedPlacesStore. Saving/running these is gated behind Pro in the UI —
//  this store itself is a plain persistence layer and enforces no gating.
//

import Foundation
import CoreLocation

extension Notification.Name {
    /// Posted whenever the saved-routes store changes, so any live view can reload.
    static let savedRoutesDidChange = Notification.Name("wander.savedRoutesDidChange")
}

/// A user-saved route: a name plus an ordered list of waypoint coordinates.
struct SavedRoute: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    /// Ordered waypoints as `[latitude, longitude]` pairs (mirrors pogo.json's format).
    var points: [[Double]]

    init(id: UUID = UUID(), name: String, points: [[Double]]) {
        self.id = id
        self.name = name
        self.points = points
    }

    init(id: UUID = UUID(), name: String, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.name = name
        self.points = coordinates.map { [$0.latitude, $0.longitude] }
    }

    /// Waypoints as coordinates, skipping any malformed pairs.
    var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    var pointCount: Int { coordinates.count }
}

/// Loads/saves the user's named routes (`savedRoutes` in UserDefaults).
@MainActor
final class SavedRoutesStore: ObservableObject {
    @Published var routes: [SavedRoute] = []

    private let key = "savedRoutes"

    init() { reload() }

    func reload() {
        routes = Self.decode(key: key)
    }

    /// Add a new named route (most-recent first) and persist.
    func add(name: String, coordinates: [CLLocationCoordinate2D]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Route \(routes.count + 1)" : trimmed
        routes.insert(SavedRoute(name: finalName, coordinates: coordinates), at: 0)
        persist()
    }

    func delete(_ offsets: IndexSet) {
        routes.remove(atOffsets: offsets)
        persist()
    }

    func delete(id: UUID) {
        routes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(routes) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .savedRoutesDidChange, object: nil)
    }

    private static func decode(key: String) -> [SavedRoute] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return [] }
        return decoded
    }
}
