//
//  SimulationSession.swift
//  Wander
//
//  Shared control for an active location simulation:
//   - a single "stop everything" path used by the global Stop button and each mode
//   - optional repeating reminder (iOS pauses background apps after ~2h)
//

import Foundation
import CoreLocation
import UserNotifications

extension Notification.Name {
    static let stopSimulationRequested = Notification.Name("wander.stopSimulationRequested")
    /// Ask the Map tab to (re)arm its 4 s warm-hold resend at a SPECIFIC coordinate. Posted when a
    /// joystick / auto-walk session parks somewhere, so the hold that keeps the fix alive re-seeds
    /// at the point the user actually stopped on — never the stale pre-walk teleport coordinate,
    /// whose re-injection mid-walk is what rubber-bands the location and trips PoGo's Error 12.
    static let holdLocationRequested = Notification.Name("wander.holdLocationRequested")
}

@MainActor
final class SimulationSession: ObservableObject {
    static let shared = SimulationSession()

    private let reminderID = "wander.reminder.2h"
    private let reminderInterval: TimeInterval = 2 * 60 * 60   // 2 hours

    /// Whether a location simulation is currently running. Drives the "keep Wander open"
    /// banner: iOS 18+ clears the spoof the moment the app/tunnel dies, so the user must
    /// keep Wander foregrounded.
    @Published private(set) var isActive = false

    /// Bumped on every Stop/Panic. A teleport in flight captures this before its FFI runs and, in its
    /// success handler, skips re-arming the hold loop if the value changed — so a stop that lands
    /// mid-teleport can't be silently undone by the completing teleport re-freezing the location.
    private(set) var stopGeneration = 0

    /// A monotonically-increasing tick that changes on every CONFIRMED teleport, plus the
    /// destination coordinate of that teleport. PoGo mode observes `teleportTick` (Equatable,
    /// unlike a raw coordinate) to drive its soft-ban cooldown — so the cooldown now reflects
    /// EVERY teleport (a PoGo hotspot, the Places list, or the map), not just PoGo-tab taps.
    @Published private(set) var teleportTick: Int = 0
    private(set) var lastTeleportCoordinate: CLLocationCoordinate2D?

    /// Record a confirmed teleport destination. Called from the Teleport tab's simulate paths.
    func noteTeleport(to coordinate: CLLocationCoordinate2D) {
        lastTeleportCoordinate = coordinate
        teleportTick &+= 1
    }

    /// Set to `true` for one run-loop tick when spoofing starts while on cellular, to ask the
    /// UI (MainTabView) to present the one-time "spoofing on cellular" coaching alert. The UI
    /// resets it to `false` on dismiss. Advisory only — never blocks spoofing.
    @Published var showCellularTip = false

    /// Process-lifetime latch: once the cellular coaching tip has been shown this app session,
    /// we never show it again until the app is relaunched. Deliberately NOT persisted to
    /// UserDefaults — we want the reminder to reappear on the next launch if the user is still
    /// on cellular, but never nag more than once within a single session.
    private var didShowCellularTip = false

    /// Call when a mode begins simulating.
    func started() {
        isActive = true
        BackgroundLocationManager.shared.requestStart()
        scheduleReminderIfEnabled()
        maybeShowCellularTip()
    }

    /// Show the cellular coaching tip at most once per app session, and only when the active
    /// internet path is cellular (not Wi-Fi). See `NetworkReachability.isOnCellular` for the
    /// VPN/tunnel reliability caveat: we key off cellular-vs-Wi-Fi, not "is a VPN present",
    /// because Wander's own required tunnel is indistinguishable from a privacy VPN.
    private func maybeShowCellularTip() {
        guard !didShowCellularTip, NetworkReachability.isOnCellularSnapshot else { return }
        didShowCellularTip = true
        showCellularTip = true
    }

    /// Call when a single mode stops only itself (e.g. Teleport's Clear). The global Stop
    /// button uses stopAll(), which additionally broadcasts to every mode.
    func markStopped() {
        isActive = false
        stopGeneration += 1
        cancelReminder()
    }

    /// Global stop: clears the device location, tells every mode to reset, cancels the reminder.
    func stopAll() {
        isActive = false
        stopGeneration += 1
        // Suppress any already-queued resend SYNCHRONOUSLY (before the async clear below) so a
        // stray hold re-injection can't run after the clear and re-freeze the fake location — the
        // notification handler that stops the resend timer may land a beat later.
        LocationSimulationCommandQueue.suppressResends = true
        NotificationCenter.default.post(name: .stopSimulationRequested, object: nil)
        LocationSimulationCommandQueue.shared.async {
            _ = clear_simulated_location()
            DispatchQueue.main.async {
                BackgroundLocationManager.shared.requestStop()
            }
        }
        cancelReminder()
    }

    /// Re-arm the 2h timer (called when the app becomes active so it only fires after real inactivity).
    func rescheduleIfActive() {
        if isActive { scheduleReminderIfEnabled() }
    }

    func scheduleReminderIfEnabled() {
        // Only ever remind while a simulation is actually active — never otherwise.
        guard isActive, UserDefaults.standard.bool(forKey: "reminderEnabled") else {
            cancelReminder()
            return
        }
        let center = UNUserNotificationCenter.current()
        let id = reminderID
        let interval = reminderInterval
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Wander"
            content.body = "Your simulated location may have paused. Open Wander to keep it active."
            content.sound = .default
            // A single timer (not repeating): it's re-armed each time the app becomes
            // active while simulating, so it fires only after ~2h of real inactivity.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.add(request)
        }
    }

    func cancelReminder() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminderID])
    }
}
