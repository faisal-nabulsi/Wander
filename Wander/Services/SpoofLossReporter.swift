//
//  SpoofLossReporter.swift
//  Wander
//
//  ══ A DEAD SESSION MUST NEVER FAIL SILENTLY. THIS IS THE ONE PLACE THAT SAYS SO. ══
//
//  WHAT WAS WRONG. The teleport HOLD — the majority flow, and the thing running when a user puts
//  their phone in their pocket — discarded the return code of every one of its 4 s re-injects
//  (`_ = locationUpdateCode(for: target)`). So when a held session died in the background, nothing
//  raised anything: no alert, no banner, no notification. The only signal was the tunnel health chip,
//  which is a pixel on a screen the user is not looking at, and the only notification the app had for
//  this was a 2-hour reminder saying the simulation "may have paused" — up to two hours late, and
//  hedged. Walk and Route already reconcile every write and stop with a named alert; the hold did not.
//
//  WHY A LOCAL NOTIFICATION IS THE RIGHT CHANNEL AND A BANNER IS NOT. The whole failure mode is
//  "backgrounded". Any in-app UI is by definition invisible at the moment it has something to say. A
//  local notification is the only thing that reaches a user whose phone is in their pocket.
//
//  WHY IT MATTERS SO MUCH MORE ON CELLULAR. `remotepairingdeviced` marks its own listeners
//  deny-cellular, so once a session is genuinely dead on mobile data it CANNOT be rebuilt in process —
//  no retry, no backoff and no amount of trying reaches it. The recovery is an Airplane Mode cycle,
//  which is a thing only the user can do. So every second between the death and the user finding out
//  is a second they are walking around on real GPS believing they are not. That is the cost this file
//  exists to remove.
//
//  WHAT IT DOES NOT DO. It does not retry, reconnect, teleport, stop, or touch the location stream —
//  it has no writer and takes no part in the single-writer discipline (OTA 92). It reports. The
//  recovery it offers is `CellularModeSequence`, which is user-initiated, already shipped, and already
//  confirmed working on device.
//

import Foundation
import UIKit
import CoreLocation
import UserNotifications

@MainActor
final class SpoofLossReporter: ObservableObject {
    static let shared = SpoofLossReporter()

    private init() {}

    /// Which of the two opposite problems this is. They share every piece of plumbing below — the
    /// published event, the coordinate, the cellular verdict, the one-shot latch, the notification —
    /// and they differ only in what the sentence says and what the button does, which is exactly the
    /// case for one type with a discriminator rather than a second alert system.
    enum Kind {
        /// The spoof the user had is gone and the device is back on real GPS.
        case sessionLost
        /// The mirror image: the user pressed Stop, Wander stopped on its side, and the DEVICE
        /// refused the stop — so it is still reporting the simulated location. Only ever raised on
        /// cellular, where there is no second session to try the stop over.
        case stopDidNotClear
    }

    /// The single loss event the UI reacts to. Non-nil means "something about this spoof needs the
    /// user, and they have not acknowledged it yet".
    struct Loss: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        /// Where they were, so a one-tap recovery has somewhere to go back to. For a failed stop this
        /// is where the device is STUCK, which is the coordinate a recovery run has to re-establish a
        /// session at before it can clear anything.
        let target: CLLocationCoordinate2D?
        /// True when the only real fix is an Airplane Mode cycle — i.e. mobile data, no Wi-Fi.
        let needsCellularRecovery: Bool
        /// Why, in the FFI's own words. Diagnostic, shown only in the log.
        let reason: String

        static func == (a: Loss, b: Loss) -> Bool { a.id == b.id }
    }

    @Published var loss: Loss?

    private let notificationID = "wander.spoof.lost"

    /// One report per death. Without this the hold's write reconciliation and the late-write callback
    /// would both fire for the same event and the user would get two notifications for one problem.
    private var isReported = false

    /// One report per failed stop, for the same reason as `isReported`: several stop paths echo
    /// (`stopAll()` broadcasts and `ItineraryRunner` calls it again), so one Stop can enqueue more
    /// than one clear. Kept separate from `isReported` because the two events can legitimately both
    /// be outstanding — a session that died and a stop that then couldn't clear it.
    private var stopFailureReported = false

    /// A fresh session starts clean — called from `SimulationSession.started()`.
    func armForNewSession() {
        isReported = false
        stopFailureReported = false
        loss = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
    }

    /// The user has read it (or stopped). Clears the card without doing anything else.
    func acknowledge() {
        loss = nil
    }

    /// An inject landed again after a bad patch — the hold rebuilt itself.
    ///
    /// Retires the card AND re-arms the latch, so a session that dies, recovers, and dies again is
    /// reported both times. Cheap enough to call on every successful tick: it does nothing at all
    /// once there is no loss outstanding, which is the overwhelmingly common case.
    func noteRecovered() {
        guard loss != nil || isReported else { return }
        loss = nil
        isReported = false
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID])
        LogManager.shared.addInfoLog("[spoof] session RECOVERED — inject landed again")
    }

    /// Entry point for callers already on the main actor.
    ///
    /// ⚠️ USE THIS ONE WHEN YOU ARE ABOUT TO STOP THE SESSION. `report` refuses to speak unless
    /// `SimulationSession.isActive` — a teardown during a deliberate Stop is not a loss — so a caller
    /// that reports and then stops must report SYNCHRONOUSLY. Going through the `nonisolated` static
    /// below would queue the report behind the stop that clears `isActive`, and the one thing this
    /// file exists to prevent (a silent death) would happen inside the file that prevents it.
    func noteSessionLost(_ reason: String) {
        report(reason: reason)
    }

    /// Entry point for callers OFF the main actor — the FFI's late-write callback runs on the serial
    /// location queue. Hops to the main actor; the session is still active at that point, so the
    /// ordering hazard above does not apply.
    nonisolated static func noteSessionLost(_ reason: String) {
        Task { @MainActor in shared.report(reason: reason) }
    }

    /// ══ THE STOP DIDN'T TAKE, AND THE USER IS THE ONLY ONE WHO CAN FIX IT. ══
    ///
    /// Called from `clear_simulated_location()` on the serial location queue when the bounded clear
    /// came back a REAL error while cellular is the only transport. That combination is the one case
    /// where the device is very likely still simulating and Wander cannot do anything about it in
    /// process: the session that carried the stop is dead, and `remotepairingdeviced` refuses to let a
    /// replacement be born on mobile data. The recovery is an Airplane Mode cycle, which is a thing
    /// only the user can do — so the only useful action is to say so and offer Cellular Mode.
    ///
    /// ⚠️ DELIBERATELY NOT ROUTED THROUGH `report`. That function refuses to speak unless
    /// `SimulationSession.isActive`, which is precisely correct for a loss (a teardown during a
    /// deliberate Stop is not a loss) and precisely wrong here: this event only exists BECAUSE a stop
    /// happened, so `isActive` is already false by the time we know.
    nonisolated static func noteStopDidNotClear(_ reason: String) {
        Task { @MainActor in shared.reportStopDidNotClear(reason: reason) }
    }

    private func reportStopDidNotClear(reason: String) {
        guard !stopFailureReported else { return }
        stopFailureReported = true
        // ── WHERE THE DEVICE IS STUCK, AND WHY IT IS NOT `lastTeleportCoordinate`. ──────────────────
        //
        // This alert's whole value is the button on it: a Cellular Mode run that re-establishes a
        // session AT THIS COORDINATE and then clears. Get the coordinate wrong and the recovery drives
        // the device somewhere else before stopping it; get it nil and there is no button at all, just
        // an OK — while the notification we post tells the user to go and tap Cellular Mode.
        //
        // `lastTeleportCoordinate` is written by `noteTeleport`, which only the TELEPORT paths call.
        // A Joystick walk or a Route drive started without teleporting first leaves it nil, and one
        // started after an earlier teleport leaves it stale — so the mode most likely to be running
        // unattended when a stop fails was the mode this served worst. The last coordinate actually
        // WRITTEN is the same fact for a teleport and the correct one for everything else; it is
        // recorded at every writer's existing choke-point and deliberately survives the stop.
        let target = SimulationSession.lastInjectedCoordinate
            ?? SimulationSession.shared.lastTeleportCoordinate
        loss = Loss(kind: .stopDidNotClear,
                    target: target,
                    needsCellularRecovery: true,
                    reason: reason)
        LogManager.shared.addErrorLog(
            "[spoof] STOP DID NOT CLEAR (\(reason)) — the device may still be simulating")
        postStopFailureNotification()
    }

    private func postStopFailureNotification() {
        // Same channel and the same reasoning as a loss: Stop is routinely the last thing a user does
        // before putting the phone away, so the in-app alert may never be seen. iOS suppresses the
        // banner by itself while Wander is frontmost, so there is no double-notify to arrange.
        let center = UNUserNotificationCenter.current()
        let id = notificationID
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("notif.stop_failed.title", fallback: "Your device is still spoofed")
            content.body = L("notif.stop_failed.body",
                             fallback: "Wander stopped, but your device refused the stop and is still reporting the simulated location. Open Wander and tap Cellular Mode to clear it.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    private func report(reason: String) {
        // Only meaningful while the user believes they are spoofing. A teardown during a Stop is not
        // a loss, and `SimulationSession.isActive` is false by then.
        guard SimulationSession.shared.isActive, !isReported else { return }
        isReported = true

        let onCellular = NetworkReachability.isOnCellularSnapshot
        // Same reasoning as `reportStopDidNotClear`: the recovery this alert offers goes to the point
        // the user was actually at, which for a walk or a drive is the last coordinate written, not
        // whichever teleport happened to precede it.
        let target = SimulationSession.lastInjectedCoordinate
            ?? SimulationSession.shared.lastTeleportCoordinate
        loss = Loss(kind: .sessionLost, target: target, needsCellularRecovery: onCellular, reason: reason)

        let audio = BackgroundAudioManager.shared
        // THE TIMESTAMP MATTERS MORE THAN THE STATE, and the state alone would mislead. Nothing runs
        // while the app is suspended, so this report fires when we come back — by which time the 2 s
        // health check has usually restarted the engine and the state reads "running-and-playing"
        // about the moment of the death it is describing. How long ago the keep-alive was last BROKEN
        // is the discriminator: a loss within a few seconds of that died of suspension, and a loss
        // with no recent break behind it died of something on the wire.
        let brokenAgo = audio.lastUnhealthyAt.map { String(format: "%.0fs ago", Date().timeIntervalSince($0)) } ?? "never"
        LogManager.shared.addErrorLog(
            "[spoof] SESSION LOST (\(reason)) — cellular: \(onCellular), "
            // The STATE, not a Bool: a switched-off engine reports "healthy" under any two-valued
            // health flag, which is exactly the condition most worth seeing in a loss report.
            + "keep-alive audio: \(audio.keepAliveState.rawValue) (last broken: \(brokenAgo))"
        )

        // Reaches a pocketed phone. Everything else in the app cannot.
        postNotification(onCellular: onCellular)
    }

    private func postNotification(onCellular: Bool) {
        // POSTED UNCONDITIONALLY, including from the foreground, and that is deliberate. Wander
        // implements no `UNUserNotificationCenterDelegate`, so iOS suppresses the banner by itself
        // while the app is frontmost — the foreground user gets the in-app alert and nothing else,
        // with no double-notify to arrange. Gating on `applicationState` here would instead have
        // opened a real hole: foregrounded but sitting on another tab, where the Location tab's alert
        // has nothing to present from, is a state where the user learns nothing at all.
        let center = UNUserNotificationCenter.current()
        let id = notificationID
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("notif.spoof_lost.title", fallback: "Your spoof stopped")
            // DELIBERATELY DIFFERENT COPY PER TRANSPORT. Telling a cellular user to reconnect the
            // tunnel is telling them to do the one thing that cannot work.
            content.body = onCellular
                ? L("notif.spoof_lost.body.cellular",
                    fallback: "Your device is back on real GPS. On mobile data this can't be fixed in place — open Wander and tap Cellular Mode to get it back.")
                : L("notif.spoof_lost.body",
                    fallback: "Your device is back on real GPS. Open Wander to start again.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            // Immediate: this is already late by the time we know.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}
