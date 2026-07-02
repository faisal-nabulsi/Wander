//
//  SimulationSession.swift
//  Wander
//
//  Shared control for an active location simulation:
//   - a single "stop everything" path used by the global Stop button and each mode
//   - optional repeating reminder (iOS pauses background apps after ~2h)
//

import Foundation
import UserNotifications

extension Notification.Name {
    static let stopSimulationRequested = Notification.Name("wander.stopSimulationRequested")
}

@MainActor
final class SimulationSession {
    static let shared = SimulationSession()

    private let reminderID = "wander.reminder.2h"
    private let reminderInterval: TimeInterval = 2 * 60 * 60   // 2 hours

    private(set) var isActive = false

    /// Call when a mode begins simulating.
    func started() {
        isActive = true
        BackgroundLocationManager.shared.requestStart()
        scheduleReminderIfEnabled()
    }

    /// Global stop: clears the device location, tells every mode to reset, cancels the reminder.
    func stopAll() {
        isActive = false
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
