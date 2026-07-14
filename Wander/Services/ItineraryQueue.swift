//
//  ItineraryQueue.swift
//  Wander
//
//  Model + persistence for the Timed Itinerary Queue (Pro). An itinerary is an ordered
//  list of steps; each step goes to a location (teleport OR route/realistic drive) and
//  then STAYS there for N minutes before the runner advances to the next step.
//
//  The built itinerary is persisted (Codable in UserDefaults) so it survives a restart.
//  The RUNNER only runs while Wander is open — iOS can't fire a step when the app is fully
//  closed, and we don't fake background scheduling (see ItineraryRunner).
//

import Foundation
import CoreLocation

/// How the runner gets to a step's location.
enum ItineraryMove: String, Codable, CaseIterable, Identifiable {
    case teleport   // jump instantly to the coordinate
    case route      // drive a realistic road route to the coordinate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teleport: return L("itinerary.move.teleport", fallback: "Teleport")
        case .route:    return L("itinerary.move.route", fallback: "Route")
        }
    }

    var systemImage: String {
        switch self {
        case .teleport: return Wander.Icon.teleport
        case .route:    return Wander.Icon.route
        }
    }
}

/// One step: go to `coordinate` (via `move`), then stay for `stayMinutes` minutes.
struct ItineraryStep: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var move: ItineraryMove
    /// How long to remain at this location before advancing, in minutes.
    var stayMinutes: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Stay duration in seconds (clamped to a sane minimum of 1s so a 0-minute step still ticks).
    var stayDuration: TimeInterval {
        TimeInterval(max(stayMinutes, 0)) * 60
    }

    var coordinateText: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

/// Loads/saves the user's itinerary (`wander.itineraryQueue` in UserDefaults) and keeps it
/// published so the builder UI stays in sync.
@MainActor
final class ItineraryStore: ObservableObject {
    static let storeKey = "wander.itineraryQueue"

    @Published var steps: [ItineraryStep] = []

    init() { reload() }

    func reload() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([ItineraryStep].self, from: data) else {
            steps = []
            return
        }
        steps = decoded
    }

    func add(_ step: ItineraryStep) {
        steps.append(step)
        persist()
    }

    func delete(_ offsets: IndexSet) {
        steps.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        steps.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func clear() {
        steps.removeAll()
        persist()
    }

    func persist() {
        if let data = try? JSONEncoder().encode(steps) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }
}
