//
//  GeofenceManager.swift
//  Wander
//
//  Geofence triggers: let the user pin a real-world location + radius so Wander
//  automatically stops spoofing (reverts to real GPS, same path as the panic
//  button) the moment they *really* arrive at — or leave — that spot.
//
//  Engine: CLLocationManager region monitoring. Each enabled geofence becomes a
//  CLCircularRegion registered via startMonitoring(for:). When the OS reports a
//  boundary crossing (didEnterRegion / didExitRegion) that matches the geofence's
//  configured trigger, we run SimulationSession.shared.stopAll() and post a local
//  notification.
//
//  Region monitoring fires in the background only with Always authorization. With
//  only When-In-Use it still fires while the app is foreground/active — the UI is
//  honest about that. iOS caps a single app at 20 monitored regions; we register
//  at most that many enabled geofences.
//

import Foundation
import CoreLocation
import UserNotifications

/// When a geofence should fire relative to the boundary.
enum GeofenceTrigger: String, Codable, CaseIterable, Identifiable {
    case arrival     // didEnterRegion — you REALLY got there
    case departure   // didExitRegion — you REALLY left

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrival:   return L("geofence.trigger.arrival", fallback: "On arrival")
        case .departure: return L("geofence.trigger.departure", fallback: "On departure")
        }
    }
}

/// What Wander does when a geofence fires. v1 ships a single action, kept as an
/// enum so future actions (e.g. "start a route") slot in without a data migration.
enum GeofenceAction: String, Codable, CaseIterable, Identifiable {
    case stopSpoofing   // revert to real GPS (same as panic)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stopSpoofing: return L("geofence.action.stop", fallback: "Stop spoofing (real GPS)")
        }
    }
}

/// A single user-defined geofence. Codable for UserDefaults persistence; optional
/// fields decode with defaults so records written by older builds keep loading.
struct Geofence: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double          // meters
    var trigger: GeofenceTrigger
    var action: GeofenceAction
    var isEnabled: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: UUID = UUID(),
         name: String,
         latitude: Double,
         longitude: Double,
         radius: Double,
         trigger: GeofenceTrigger = .arrival,
         action: GeofenceAction = .stopSpoofing,
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, radius, trigger, action, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 150
        trigger = try c.decodeIfPresent(GeofenceTrigger.self, forKey: .trigger) ?? .arrival
        action = try c.decodeIfPresent(GeofenceAction.self, forKey: .action) ?? .stopSpoofing
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// Owns the list of geofences and the CLLocationManager that monitors them.
///
/// This is the single source of truth for both persistence (UserDefaults) and the
/// live region registration. The UI observes `geofences`; every mutation re-syncs
/// the monitored regions so what iOS is watching always matches what's enabled.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {
    static let shared = GeofenceManager()

    /// iOS monitors at most 20 regions per app.
    static let maxMonitoredRegions = 20
    /// CLCircularRegion clamps radius to the device maximum; keep a sane floor/ceiling for the UI.
    static let minRadius: Double = 50
    static let maxRadius: Double = 5_000

    private static let storeKey = "wander.geofences"
    private static let regionPrefix = "wander.geofence."

    @Published private(set) var geofences: [Geofence] = []

    private let manager = CLLocationManager()

    /// Current authorization, surfaced so the UI can explain background behavior honestly.
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([Geofence].self, from: data) else {
            geofences = []
            return
        }
        geofences = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(geofences) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    // MARK: Public API

    /// How many more enabled geofences can be monitored before hitting iOS's cap.
    var remainingCapacity: Int {
        max(0, Self.maxMonitoredRegions - enabledGeofences.count)
    }

    var enabledGeofences: [Geofence] {
        geofences.filter { $0.isEnabled }
    }

    /// Add a geofence, persist, and (if enabled) begin monitoring it.
    func add(_ geofence: Geofence) {
        geofences.append(geofence)
        persist()
        syncMonitoredRegions()
    }

    func delete(at offsets: IndexSet) {
        geofences.remove(atOffsets: offsets)
        persist()
        syncMonitoredRegions()
    }

    func delete(_ geofence: Geofence) {
        geofences.removeAll { $0.id == geofence.id }
        persist()
        syncMonitoredRegions()
    }

    /// Flip a geofence on/off without deleting it, then re-sync monitoring.
    func setEnabled(_ enabled: Bool, for geofence: Geofence) {
        guard let idx = geofences.firstIndex(where: { $0.id == geofence.id }) else { return }
        geofences[idx].isEnabled = enabled
        persist()
        syncMonitoredRegions()
    }

    /// Ask for Always authorization (needed for background firing). If the user
    /// previously granted only When-In-Use, iOS shows the "upgrade to Always"
    /// prompt; if fully denied, this is a no-op and the UI already explains it.
    func requestAlwaysAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Re-register monitored regions to match the currently enabled geofences.
    /// Idempotent: safe to call on launch, on any mutation, and on auth changes.
    func refreshMonitoring() {
        syncMonitoredRegions()
    }

    // MARK: Region syncing

    private func syncMonitoredRegions() {
        // Region monitoring is unavailable on some hardware/simulators — bail cleanly.
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        // Clear only the regions we own (prefix-namespaced) so we never disturb
        // regions another part of the app might register in the future.
        for region in manager.monitoredRegions where region.identifier.hasPrefix(Self.regionPrefix) {
            manager.stopMonitoring(for: region)
        }

        // Register enabled geofences, honoring iOS's 20-region cap.
        for geofence in enabledGeofences.prefix(Self.maxMonitoredRegions) {
            let clampedRadius = min(geofence.radius, manager.maximumRegionMonitoringDistance)
            let region = CLCircularRegion(
                center: geofence.coordinate,
                radius: clampedRadius,
                identifier: Self.regionPrefix + geofence.id.uuidString
            )
            region.notifyOnEntry = (geofence.trigger == .arrival)
            region.notifyOnExit = (geofence.trigger == .departure)
            manager.startMonitoring(for: region)
        }
    }

    // MARK: Firing

    private func geofence(forRegionIdentifier identifier: String) -> Geofence? {
        guard identifier.hasPrefix(Self.regionPrefix) else { return nil }
        let idString = String(identifier.dropFirst(Self.regionPrefix.count))
        guard let id = UUID(uuidString: idString) else { return nil }
        return geofences.first { $0.id == id }
    }

    /// Run the geofence's action. v1: stop all spoofing (revert to real GPS), then
    /// notify. Mirrors the panic path so it's a harmless clear even if nothing is
    /// currently simulating.
    private func fire(_ geofence: Geofence) {
        switch geofence.action {
        case .stopSpoofing:
            SimulationSession.shared.stopAll()
        }
        LogManager.shared.addInfoLog("Geofence fired: \(geofence.name) (\(geofence.trigger.rawValue))")
        postArrivalNotification(for: geofence)
    }

    private func postArrivalNotification(for geofence: Geofence) {
        let center = UNUserNotificationCenter.current()
        let name = geofence.name
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wander"
            let bodyFormat = L("geofence.notification.body", fallback: "Back on real GPS — you arrived at %@")
            content.body = String(format: bodyFormat, name)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "wander.geofence.fire.\(geofence.id.uuidString).\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil   // deliver immediately
            )
            center.add(request)
        }
    }
}

extension GeofenceManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            // Re-sync so a fresh Always/When-In-Use grant actually starts monitoring.
            self.syncMonitoredRegions()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            guard let geofence = self.geofence(forRegionIdentifier: region.identifier),
                  geofence.trigger == .arrival else { return }
            self.fire(geofence)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            guard let geofence = self.geofence(forRegionIdentifier: region.identifier),
                  geofence.trigger == .departure else { return }
            self.fire(geofence)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // Registration can fail (e.g. over the region cap). Nothing actionable at
        // runtime — the UI already limits the user to the cap.
    }
}
