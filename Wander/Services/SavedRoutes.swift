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
///
/// A route is either a *builder* route (a handful of waypoints the app routes between
/// with MKDirections) or a *recorded* route (a dense trail of REAL GPS fixes captured
/// while the user physically moved). A recorded route additionally carries a
/// `timestamps` array — the wall-clock time (seconds since 1970) of each point — so
/// replay can preserve the real pace instead of re-routing.
struct SavedRoute: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    /// Ordered waypoints as `[latitude, longitude]` pairs (mirrors pogo.json's format).
    var points: [[Double]]
    /// Per-point capture times (unixtime seconds) for recorded routes. `nil`/empty for
    /// builder routes. When present it parallels `points` one-for-one so replay can
    /// reproduce the recorded timing.
    var timestamps: [Double]? = nil
    /// Last-modified time — drives multi-device sync conflict resolution (newest wins). `nil` on
    /// routes saved before sync existed; those are treated as oldest and stamped on first push.
    var updatedAt: Date? = nil

    init(id: UUID = UUID(), name: String, points: [[Double]], timestamps: [Double]? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.points = points
        self.timestamps = timestamps
        self.updatedAt = updatedAt
    }

    init(id: UUID = UUID(), name: String, coordinates: [CLLocationCoordinate2D], timestamps: [Double]? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.points = coordinates.map { [$0.latitude, $0.longitude] }
        self.timestamps = timestamps
        self.updatedAt = updatedAt
    }

    // Custom decode so routes saved by older builds (no `timestamps`/`updatedAt` key) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        points = try c.decode([[Double]].self, forKey: .points)
        timestamps = try c.decodeIfPresent([Double].self, forKey: .timestamps)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// Stable cross-device identity for the sync merge: lowercased name + point count + first/last
    /// coordinate (rounded ~5 decimals). Two devices that saved "the same" route collapse to one row.
    /// MUST stay byte-identical to the Android/desktop key or sync silently transfers nothing.
    var routeSyncKey: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func r(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }
        let first = points.first ?? [0, 0]
        let last = points.last ?? [0, 0]
        let lat0 = first.count > 0 ? r(first[0]) : 0, lng0 = first.count > 1 ? r(first[1]) : 0
        let latN = last.count > 0 ? r(last[0]) : 0, lngN = last.count > 1 ? r(last[1]) : 0
        return String(format: "%@|%d|%.5f|%.5f|%.5f|%.5f", n, points.count, lat0, lng0, latN, lngN)
    }

    /// Waypoints as coordinates, skipping any malformed pairs.
    var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
        }
    }

    var pointCount: Int { coordinates.count }

    /// True when this is a captured real-GPS route with usable per-point timing.
    var isRecorded: Bool {
        guard let timestamps else { return false }
        return timestamps.count == points.count && points.count >= 2
    }
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
        routes.insert(SavedRoute(name: finalName, coordinates: coordinates, updatedAt: Date()), at: 0)
        persist()
    }

    /// Add a recorded real-GPS route: captured coordinates plus their per-point capture
    /// times (unixtime seconds), so replay can preserve the real pace. Persisted into the
    /// same store as builder routes.
    func addRecorded(name: String, coordinates: [CLLocationCoordinate2D], timestamps: [Double]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Recording \(routes.count + 1)" : trimmed
        routes.insert(SavedRoute(name: finalName, coordinates: coordinates, timestamps: timestamps, updatedAt: Date()), at: 0)
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
