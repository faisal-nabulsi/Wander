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

    /// Distinct id (separate from the 2h reminder) for the "cooldown cleared" local notification —
    /// fires at `cooldownEndsAt` so the user knows it's safe to catch/spin again without watching the
    /// in-app countdown. Rescheduled on each new teleport; cancelled when the cooldown is cleared
    /// early or on Stop.
    private let cooldownDoneID = "wander.cooldown.cleared"

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

    /// Watches for a real "snap-back" (the device's real reported location bouncing away from the
    /// spoofed target while spoofing). Exposed so the UI can observe `didBounceBack` and offer the
    /// gentle recovery prompt — which appears ONLY after an actual detected bounce-back.
    let snapBack = SnapBackWatcher()

    // MARK: - App-wide soft-ban cooldown
    //
    // Guidance only. We CANNOT gate Pokémon GO's in-app catch/spin/gym taps (that's server-side,
    // with no hook) — this is a persistent timer + countdown so the user knows how long to WAIT
    // before interacting after a big jump. Teleport and walk stay free. The countdown lives on
    // this shared singleton so it survives tab switches and every teleport writer feeds it.

    /// Seconds left on the current soft-ban cooldown (0 when clear). Ticked down once per second.
    @Published private(set) var cooldownRemaining: TimeInterval = 0
    /// Whether a cooldown is currently counting down. Drives the persistent countdown chip.
    @Published private(set) var cooldownActive = false
    /// Great-circle distance (km) of the jump that started the current cooldown — shown for context.
    @Published private(set) var lastJumpKm: Double = 0

    /// Wall-clock end of the current cooldown; the 1 s ticker derives `cooldownRemaining` from it so
    /// the countdown stays accurate across missed ticks (backgrounding, tab switches).
    private var cooldownEndsAt: Date?
    private var cooldownTimer: Timer?

    /// Extra padding on top of the raw curve value (guidance is a floor, not a promise), and the
    /// hard cap the PoGo curve itself already tops out at.
    private let cooldownBuffer = 1.10
    private let cooldownCapSeconds: TimeInterval = 120 * 60

    /// Record a confirmed teleport destination. Called from the Teleport tab's simulate paths.
    /// Computes the app-wide soft-ban cooldown from the previous teleport coordinate to this one
    /// using the EXISTING PoGoCooldown curve (same math, +buffer, capped), then starts/refreshes
    /// the countdown. Re-teleporting while a cooldown runs simply restarts it from the new distance.
    func noteTeleport(to coordinate: CLLocationCoordinate2D) {
        let previous = lastTeleportCoordinate
        lastTeleportCoordinate = coordinate
        teleportTick &+= 1
        applyCooldown(from: previous, to: coordinate)
        // Persist for reboot-aware recovery: if the app/tunnel dies or the phone reboots mid-session,
        // the next launch can offer a one-tap resume back to THIS target. Written on every confirmed
        // teleport so the persisted point always matches where the user last actually was.
        persistResumeTarget(coordinate)
        // (Re)arm snap-back detection against the fresh target — clears any prior bounce-back signal
        // and starts watching from THIS coordinate.
        snapBack.start(guarding: coordinate)
    }

    /// Disarm the snap-back watcher because a MOVEMENT mode (walk / auto-walk / route / itinerary)
    /// has just become the active location writer. The watcher only makes sense while guarding a
    /// STATIONARY teleport hold: during a walk the reported fix legitimately moves hundreds of metres
    /// away from the teleport target, which would false-fire `didBounceBack` — and its "Re-teleport"
    /// recovery re-asserts the stale target through `resume`, adding a SECOND writer to the serial
    /// queue mid-walk (the exact two-writer / Error-12 regression we guard against). Movement modes
    /// self-heal via their own inject loop, so they own the stream and the watcher stands down until
    /// the next stationary teleport re-arms it via `noteTeleport`.
    func movementModeDidBecomeActiveWriter() {
        snapBack.stop()
    }

    // MARK: - Reboot-aware recovery (persist + resume)
    //
    // iOS clears the spoof the moment the app/tunnel dies (or the phone reboots), snapping the device
    // back to its real location. We persist the last teleport target + a "was spoofing" flag so the
    // NEXT launch can offer a gentle one-tap resume — re-teleporting via the EXISTING simulate path
    // (which re-mounts the tunnel). Nothing here re-mounts a tunnel itself or resumes automatically.

    private enum ResumeKeys {
        static let wasSpoofing = "resume.wasSpoofing"
        static let lat = "resume.lat"
        static let lng = "resume.lng"
        static let timestamp = "resume.timestamp"
    }

    /// A saved spoof session that a fresh launch can offer to resume.
    struct ResumeTarget {
        let coordinate: CLLocationCoordinate2D
        let savedAt: Date
    }

    /// Write the current teleport target + "was spoofing" flag + timestamp so a bounce-back to the
    /// real location (app death / reboot) can be recovered on next launch.
    private func persistResumeTarget(_ coordinate: CLLocationCoordinate2D) {
        let d = UserDefaults.standard
        d.set(true, forKey: ResumeKeys.wasSpoofing)
        d.set(coordinate.latitude, forKey: ResumeKeys.lat)
        d.set(coordinate.longitude, forKey: ResumeKeys.lng)
        d.set(Date().timeIntervalSince1970, forKey: ResumeKeys.timestamp)
    }

    /// Clear the persisted resume state. Called on a clean Stop so a deliberate stop never resurfaces
    /// as a "resume?" prompt on the next launch.
    private func clearResumeTarget() {
        let d = UserDefaults.standard
        d.removeObject(forKey: ResumeKeys.wasSpoofing)
        d.removeObject(forKey: ResumeKeys.lat)
        d.removeObject(forKey: ResumeKeys.lng)
        d.removeObject(forKey: ResumeKeys.timestamp)
    }

    /// If the previous run ended WITHOUT a clean Stop (app/tunnel died or the phone rebooted
    /// mid-session), returns the target to offer resuming. `nil` when there's nothing to resume or
    /// the saved session is stale. Read once at launch by `WanderApp`.
    ///
    /// - Parameter maxAge: ignore saved sessions older than this (default 12h) so a days-old flag
    ///   doesn't nag. Advisory recovery is only useful right after an unexpected bounce-back.
    func pendingResumeTarget(maxAge: TimeInterval = 12 * 60 * 60) -> ResumeTarget? {
        let d = UserDefaults.standard
        guard d.bool(forKey: ResumeKeys.wasSpoofing) else { return nil }
        let lat = d.double(forKey: ResumeKeys.lat)
        let lng = d.double(forKey: ResumeKeys.lng)
        let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        guard CLLocationCoordinate2DIsValid(coordinate), lat != 0 || lng != 0 else { return nil }
        let savedAt = Date(timeIntervalSince1970: d.double(forKey: ResumeKeys.timestamp))
        guard Date().timeIntervalSince(savedAt) <= maxAge else {
            clearResumeTarget()
            return nil
        }
        return ResumeTarget(coordinate: coordinate, savedAt: savedAt)
    }

    /// Dismiss the launch-time resume offer without resuming — the user chose not to. Clears the
    /// persisted flag so it won't reappear next launch.
    func dismissPendingResume() {
        clearResumeTarget()
    }

    /// Re-teleport to `coordinate` via the EXISTING teleport path — posts `.teleportToRequested`,
    /// which the Map screen handles by selecting the coordinate and calling `simulate()` (that
    /// re-mounts the tunnel through the normal flow). Used for both the launch-time reboot resume and
    /// the in-session snap-back "re-teleport" tap. Deliberately reuses the normal path — it does NOT
    /// build a separate DDI remount. Also switches to the Map tab so the resume is visible.
    func resume(to coordinate: CLLocationCoordinate2D) {
        snapBack.reset()
        UserDefaults.standard.set(AppFeature.location.id, forKey: "primaryTabSelection")
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
    }

    /// Start (or refresh) the cooldown for a jump `previous -> next`. No-op'd to "clear" when the
    /// selected game doesn't use a distance cooldown (Pikmin/Ingress) or when there's no prior
    /// coordinate (the first teleport of the session).
    private func applyCooldown(from previous: CLLocationCoordinate2D?, to next: CLLocationCoordinate2D) {
        let preset = GamePreset(rawValue: UserDefaults.standard.string(forKey: "pogoGamePreset") ?? "")
            ?? .pokemonGo
        guard preset.usesTeleportCooldown, let previous else {
            clearCooldown()
            return
        }
        let km = PoGoCooldown.distanceKm(from: previous, to: next)
        // A re-assert of the SAME point (auto-reconnect / resume / snap-back re-teleport all re-post
        // the current coordinate) has ~0 distance → 0 seconds. That must NOT wipe a cooldown that's
        // still counting down from the real jump that started it. Only a genuine NEW jump (moved more
        // than ~50 m) recomputes/clears the cooldown; a near-in-place re-assert leaves it running.
        if km * 1000 < 50, cooldownActive {
            return
        }
        lastJumpKm = km
        // Reuse the existing curve verbatim; add a small buffer (guidance is a floor) and keep the
        // curve's own 120-min ceiling as a hard cap.
        let seconds = min(PoGoCooldown.seconds(forKm: km) * cooldownBuffer, cooldownCapSeconds)
        guard seconds > 0 else {
            clearCooldown()
            return
        }
        let endsAt = Date().addingTimeInterval(seconds)
        cooldownEndsAt = endsAt
        cooldownRemaining = seconds
        cooldownActive = true
        startCooldownTimer()
        // Schedule a local notification for when the cooldown clears, so the user doesn't have to
        // watch the in-app countdown. Rescheduled here on every new teleport that (re)starts a
        // cooldown; cancelled in clearCooldown() on an early clear or Stop. The natural expiry ticks
        // through clearCooldown() too, but by then this notification has already fired at endsAt —
        // removing a delivered request is a harmless no-op.
        scheduleCooldownClearedNotification(at: endsAt)
    }

    private func clearCooldown() {
        cooldownEndsAt = nil
        cooldownRemaining = 0
        cooldownActive = false
        lastJumpKm = 0
        cooldownTimer?.invalidate()
        cooldownTimer = nil
        cancelCooldownClearedNotification()
    }

    /// Schedule the "cooldown cleared" local notification to fire AT `endsAt`. Mirrors the 2h
    /// reminder's auth + scheduling; uses a distinct id so the two never collide. Best-effort: if
    /// notifications aren't granted it simply doesn't fire (the in-app countdown still shows).
    private func scheduleCooldownClearedNotification(at endsAt: Date) {
        let center = UNUserNotificationCenter.current()
        let id = cooldownDoneID
        let interval = max(1, endsAt.timeIntervalSinceNow)   // UNTimeIntervalTrigger needs > 0
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("notif.cooldown_cleared.title", fallback: "Cooldown cleared")
            content.body = L("notif.cooldown_cleared.body",
                             fallback: "Safe to catch & spin in Pokémon GO now.")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            // Replace any earlier pending one so a re-teleport reschedules cleanly.
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.add(request)
        }
    }

    private func cancelCooldownClearedNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [cooldownDoneID])
    }

    private func startCooldownTimer() {
        cooldownTimer?.invalidate()
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCooldown() }
        }
    }

    private func tickCooldown() {
        guard let endsAt = cooldownEndsAt else { return }
        let remaining = max(0, endsAt.timeIntervalSinceNow)
        cooldownRemaining = remaining
        if remaining <= 0 {
            clearCooldown()
        }
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
        // Start the tunnel heartbeat + best-effort self-heal for this session.
        TunnelHealthMonitor.shared.startMonitoring()
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
        clearResumeTarget()   // deliberate stop — never resurface as a "resume?" prompt next launch
        snapBack.stop()
        TunnelHealthMonitor.shared.stopMonitoring()
        cancelReminder()
        // A deliberate stop ends the session — cancel the pending "cooldown cleared" ping so it can't
        // fire after the user has already stopped (the in-app chip still counts down if it re-shows).
        cancelCooldownClearedNotification()
    }

    /// Global stop: clears the device location, tells every mode to reset, cancels the reminder.
    func stopAll() {
        isActive = false
        stopGeneration += 1
        clearResumeTarget()   // deliberate stop — never resurface as a "resume?" prompt next launch
        snapBack.stop()
        TunnelHealthMonitor.shared.stopMonitoring()
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
        // A deliberate global stop ends the session — cancel the pending "cooldown cleared" ping.
        cancelCooldownClearedNotification()
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
