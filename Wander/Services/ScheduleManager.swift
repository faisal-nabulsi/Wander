//
//  ScheduleManager.swift
//  Wander
//
//  In-app scheduler for SCHEDULING ("be at a place during set hours"). Drives the auto
//  START / STOP of location spoofing at each schedule's start/end times.
//
//  HOW IT STAYS ALIVE (the app CAN run backgrounded):
//   - Whenever at least one schedule is ARMED, we turn on the existing BackgroundAudioManager
//     keep-alive (start()). Wander already declares UIBackgroundModes audio+location, so this
//     silent-audio session keeps the process running in the background until the scheduled time.
//   - We re-evaluate on a periodic in-app tick (Timer that runs while the app is alive) AND on
//     every foreground transition, so drift/suspension is corrected the moment we run again.
//   - When no schedules remain armed we stop the keep-alive.
//
//  FIRING:
//   - At a schedule's start time (once we cross into its active window) we begin spoofing at the
//     saved location via the SAME low-level path as MapSelectionView / ItineraryRunner
//     (simulate_location on LocationSimulationCommandQueue + SimulationSession.started()).
//   - We keep resending while inside the window so the spoof survives iOS re-checks.
//   - At the end time (we leave the window) we STOP via SimulationSession.shared.stopAll()
//     (reverts to real GPS).
//
//  BACKSTOP + HONEST LIMIT:
//   - We ALSO schedule a local notification at each start time. Scheduling only auto-runs while
//     Wander is alive (foreground or the background keep-alive). If the user FORCE-QUITS Wander,
//     iOS can't auto-start it — the notification reminds them to reopen. We do NOT claim it works
//     from a force-quit.
//
//  This is ADDITIVE and reuses the existing simulate + stop paths; it never touches
//  trial/license/injection.
//

import Foundation
import CoreLocation
import UserNotifications

@MainActor
final class ScheduleManager: ObservableObject {
    static let shared = ScheduleManager()

    /// The schedule we are currently spoofing for (nil when no window is active).
    @Published private(set) var activeScheduleID: UUID?

    /// The store is the source of truth; we read it on each evaluation.
    private let store = ScheduleStore()

    /// In-app tick: re-evaluates windows and resends the active location while alive.
    private var tickTimer: Timer?
    /// How often to re-evaluate + resend while inside a window (also survives iOS re-checks).
    private let tickInterval: TimeInterval = 4

    /// Notification identifier prefix for per-schedule start reminders.
    private static let notifPrefix = "wander.schedule.start."

    /// Guards against stopping a simulation we didn't start (e.g. a manual teleport running).
    private var didStartActiveSpoof = false

    private var stopObserver: NSObjectProtocol?
    private var changeObserver: NSObjectProtocol?

    private init() {
        // Honor global stop / panic: if the user stops everything, drop our active window so our
        // next tick doesn't revive the spoof they just killed. It will re-arm at the next window.
        stopObserver = NotificationCenter.default.addObserver(
            forName: .stopSimulationRequested, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleExternalStop() }
        }
        // React to add/delete/arm changes: re-arm keep-alive + notifications + re-evaluate.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .schedulesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.store.reload()
                self?.refresh()
            }
        }
    }

    // MARK: - Lifecycle

    /// Call once on app start (from AppBootstrapper). Loads schedules, arms keep-alive if any are
    /// armed, schedules notifications, and evaluates the current window.
    func startup() {
        store.reload()
        refresh()
    }

    /// Re-evaluate everything: keep-alive on/off, (re)schedule start notifications, and evaluate
    /// the active window. Safe to call as often as you like (foreground, tick, store change).
    func refresh() {
        updateKeepAlive()
        rescheduleStartNotifications()
        evaluate()
    }

    /// Call whenever the app becomes active (foreground). Corrects any window we missed while
    /// suspended and restarts the tick.
    func handleForeground() {
        store.reload()
        refresh()
        startTickIfNeeded()
    }

    // MARK: - Keep-alive

    private var hasArmedSchedules: Bool { store.schedules.contains { $0.isArmed } }

    private func updateKeepAlive() {
        if hasArmedSchedules {
            BackgroundAudioManager.shared.start()
            startTickIfNeeded()
        } else {
            // No armed schedules: only stop the keep-alive if WE own it (no active window running).
            if activeScheduleID == nil {
                BackgroundAudioManager.shared.stop()
                stopTick()
            }
        }
    }

    private func startTickIfNeeded() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func onTick() {
        evaluate()
        // While a window is active, keep resending so the spoof holds across iOS re-checks.
        if let id = activeScheduleID,
           didStartActiveSpoof,
           let schedule = store.schedules.first(where: { $0.id == id }) {
            resend(schedule.coordinate)
        }
    }

    // MARK: - Window evaluation

    /// The schedule (if any) that should be ACTIVE at `date` — armed, on today's weekday, and
    /// inside its start…end window. If several overlap, the earliest-created that matches wins
    /// (schedules are stored newest-first, so we take the last match for determinism).
    private func activeSchedule(at date: Date) -> Schedule? {
        store.schedules.last { $0.isArmed && Self.isInWindow($0, at: date) }
    }

    /// Core state machine: START when we enter a window, STOP when we leave it.
    private func evaluate() {
        let now = Date()
        let target = activeSchedule(at: now)

        if let target {
            if activeScheduleID != target.id {
                // Entering a new window (or switching windows): (re)start spoofing here.
                start(target)
            }
        } else if activeScheduleID != nil {
            // We were in a window and now we're not: stop.
            stopActive()
        }
        // Keep-alive may need to drop if the last armed schedule just ended and none remain.
        if target == nil { updateKeepAlive() }
    }

    // MARK: - Start / Stop

    private func start(_ schedule: Schedule) {
        guard let path = pairingFilePath() else {
            // Can't simulate without a pairing file — leave the window inactive; the start
            // notification still fires as the backstop.
            return
        }
        activeScheduleID = schedule.id
        didStartActiveSpoof = true
        BackgroundAudioManager.shared.start()
        startTickIfNeeded()
        resend(schedule.coordinate, path: path)
        SimulationSession.shared.started()
        LogManager.shared.addInfoLog("Schedule '\(schedule.name)' started (auto-spoof).")
    }

    /// Stop the currently active window and revert to real GPS.
    private func stopActive() {
        let wasStarted = didStartActiveSpoof
        activeScheduleID = nil
        didStartActiveSpoof = false
        if wasStarted {
            SimulationSession.shared.stopAll()
        }
        updateKeepAlive()
    }

    /// A global stop/panic happened elsewhere — forget our active window so we don't revive it.
    private func handleExternalStop() {
        activeScheduleID = nil
        didStartActiveSpoof = false
        // Don't stop the keep-alive here if schedules remain armed for future windows.
        updateKeepAlive()
    }

    /// Send one location update on the shared command queue (same path as ItineraryRunner /
    /// MapSelectionView), honoring the user's jitter preference.
    private func resend(_ coordinate: CLLocationCoordinate2D, path: String? = nil) {
        guard let path = path ?? pairingFilePath() else { return }
        // "Hold perfectly still" disables jitter; "Approximate location" shifts by a stable
        // per-session offset. Both no-op when their toggles are off.
        let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
        let jittered = (!frozen && UserDefaults.standard.bool(forKey: "jitterEnabled"))
            ? LocationJitter.apply(coordinate)
            : coordinate
        let target = CoarseLocation.apply(jittered)
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, target.latitude, target.longitude, path)
        }
    }

    // MARK: - Local notifications (backstop)

    /// Remove and re-add a start-time notification for each armed schedule, so if Wander is
    /// force-quit the user is still reminded when a window opens.
    private func rescheduleStartNotifications() {
        let center = UNUserNotificationCenter.current()
        // Clear all our previous schedule notifications first.
        center.getPendingNotificationRequests { requests in
            let ids = requests.map { $0.identifier }.filter { $0.hasPrefix(Self.notifPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }

        let armed = store.schedules.filter { $0.isArmed }
        guard !armed.isEmpty else { return }

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for schedule in armed {
                Self.addStartNotification(for: schedule, center: center)
            }
        }
    }

    private static func addStartNotification(for schedule: Schedule, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Wander"
        content.body = String(
            format: L("schedule.notif.body",
                      fallback: "Time to be at %@. Open Wander if it isn't running so it can start automatically."),
            schedule.name
        )
        content.sound = .default

        var comps = DateComponents()
        comps.hour = (schedule.startMinutes / 60) % 24
        comps.minute = schedule.startMinutes % 60

        // Repeating daily notifications require a weekday component per day. For "every day" a
        // single time-based repeating trigger suffices; for specific weekdays, one per weekday.
        if schedule.repeatsDaily {
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            let req = UNNotificationRequest(identifier: Self.notifPrefix + schedule.id.uuidString,
                                            content: content, trigger: trigger)
            center.add(req)
        } else {
            for weekday in schedule.weekdays {
                var wComps = comps
                wComps.weekday = weekday
                let trigger = UNCalendarNotificationTrigger(dateMatching: wComps, repeats: true)
                let id = "\(Self.notifPrefix)\(schedule.id.uuidString).\(weekday)"
                let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                center.add(req)
            }
        }
    }

    // MARK: - Next fire (for the UI)

    /// The next Date any armed schedule will START (auto-spoof), or nil if none are armed.
    /// Looks up to 8 days ahead so weekly schedules always resolve.
    func nextFireDate(from date: Date = Date()) -> Date? {
        let armed = store.schedules.filter { $0.isArmed }
        guard !armed.isEmpty else { return nil }

        let cal = Calendar.current
        var best: Date?
        for dayOffset in 0...8 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: date) else { continue }
            let weekday = cal.component(.weekday, from: day)
            for schedule in armed where schedule.runsOn(weekday: weekday) {
                var comps = cal.dateComponents([.year, .month, .day], from: day)
                comps.hour = (schedule.startMinutes / 60) % 24
                comps.minute = schedule.startMinutes % 60
                comps.second = 0
                guard let fire = cal.date(from: comps), fire > date else { continue }
                if best == nil || fire < best! { best = fire }
            }
            if best != nil { break }  // earliest day with a match wins
        }
        return best
    }

    // MARK: - Helpers

    /// True if `date` falls inside the schedule's start…end window, handling midnight-crossing.
    static func isInWindow(_ schedule: Schedule, at date: Date) -> Bool {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: date)
        let minutes = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        let start = schedule.startMinutes
        let end = schedule.endMinutes

        if schedule.crossesMidnight {
            // Window wraps past midnight, e.g. 22:00 → 06:00.
            if minutes >= start {
                // Evening portion: belongs to today's weekday.
                return schedule.runsOn(weekday: weekday)
            } else if minutes < end {
                // Early-morning portion: belongs to the PREVIOUS day's weekday assignment.
                let prevWeekday = (weekday - 2 + 7) % 7 + 1
                return schedule.runsOn(weekday: prevWeekday)
            }
            return false
        } else {
            guard schedule.runsOn(weekday: weekday) else { return false }
            return minutes >= start && minutes < end
        }
    }

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }
}
