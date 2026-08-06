//
//  ShortcutRunner.swift
//  Wander
//
//  Fires an iOS Shortcut FROM inside Wander so an in-app button can do OS-level things Wander's own
//  sandbox can't (Set Wi-Fi off/on for a location-cache flush, Set VPN, etc.). The pattern:
//
//    in-app button → open("shortcuts://x-callback-url/run-shortcut?name=<NAME>&x-success=wander://<verb>…")
//      → iOS FOREGROUNDS Shortcuts (~1s flash — unavoidable for a URL-invoked run), runs <NAME>
//      → the shortcut does the OS action → x-success brings us back to wander://<verb>
//
//  Honest limits (verified): the Shortcuts foreground flash cannot be suppressed for a URL-invoked run;
//  the no-flash path is a "Run Immediately" Personal Automation, which fires on a trigger, not a call.
//  There is NO per-run confirmation for an imported/trusted shortcut. Invocation is BY NAME, so the
//  user's shortcut must be named exactly (see onboarding). x-error self-heals the installed flag.
//

import UIKit

enum ShortcutRunner {
    /// Exact names the user's imported shortcuts must have (invocation is by name).
    static let flushName = "Wander Flush"
    static let warmStartName = "Wander Warm Start"
    /// "Set VPN → LocalDevVPN → Connect → Open App Wander" — connects the DEFAULT tunnel (used for
    /// everything except games, and to install updates) from an in-app tap, then auto-returns.
    static let vpnConnectName = "Wander Connect VPN"
    /// "Set VPN → Shadowrocket → Connect → Open App Wander" — connects the PoGo/games proxy and bounces
    /// back to Wander (unlike shadowrocket://connect, which strands you in Shadowrocket).
    static let shadowrocketConnectName = "Wander Connect Shadowrocket"
    /// THE ONLY SHORTCUT CELLULAR MODE NEEDS. One job: flip Airplane Mode. Input "on" turns it on and
    /// waits ~4 s for the radio to settle; ANYTHING else — including a hand-run with no input — turns
    /// it off, which is the safe default for an empty variable.
    ///
    /// WHY IT IS THIS SMALL. Everything else in the old sequence (tunnel up, teleport) was an App
    /// Intent action purely so the Shortcut could WAIT for it, and an App Intent action serialises the
    /// target app's bundle id + team id — values that differ for every install, which is why those two
    /// actions could never be shipped pre-filled and had to be added by hand in the editor. Wander
    /// conducts the sequence itself now (`CellularModeSequence`), so this file contains only
    /// `is.workflow.actions.*` built-ins, carries no app identity, and imports ready to run under every
    /// signature. See `CellularModeSequence` for the full argument.
    static let airplaneName = "Wander Airplane"

    /// THE OLD ALL-IN-ONE SEQUENCE. Kept, not deleted, as the documented fallback: someone who set it
    /// up before still has it, and it is what the setup card points at if the new one won't install.
    /// Requires the two hand-added Wander actions (see `CellularModeSetupView`'s fallback section).
    static let cellularModeName = "Wander Cellular Mode"

    /// Persisted "the Wander shortcuts are installed" flag. Set optimistically after onboarding; flipped
    /// back to false whenever a run reports x-error (shortcut missing/renamed) so the UI self-heals.
    static var ready: Bool {
        get { UserDefaults.standard.bool(forKey: "shortcutsReady") }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutsReady") }
    }

    /// "The one-action `Wander Airplane` shortcut is installed." Its own flag, for the same reason
    /// `cellularModeReady` has one: installing the gs-loc/flush pack says nothing about this file
    /// existing, and a shared flag would offer a one-tap button that fails every time.
    ///
    /// Self-heals like the rest: `CellularModeSequence` clears it when a run proves Airplane Mode never
    /// switched on, which is what "the shortcut is missing or renamed" looks like from Wander's side.
    static var airplaneReady: Bool {
        get { UserDefaults.standard.bool(forKey: "wanderAirplaneShortcutReady") }
        set { UserDefaults.standard.set(newValue, forKey: "wanderAirplaneShortcutReady") }
    }

    /// Same idea as `ready`, but for the LEGACY all-in-one Cellular Mode shortcut.
    ///
    /// Deliberately NOT folded into `ready`: that flag means "the gs-loc/flush pack is installed", and a
    /// user who set those up years ago has not thereby installed this one. Sharing the flag would show a
    /// one-tap button that lands on an x-error every time. Self-heals the same way — a run that reports
    /// `wander://cellular-missing` flips it back to false and the setup card returns.
    static var cellularModeReady: Bool {
        get { UserDefaults.standard.bool(forKey: "cellularModeShortcutReady") }
        set { UserDefaults.standard.set(newValue, forKey: "cellularModeShortcutReady") }
    }

    /// Either shortcut will do, so the button says "Simulate" rather than "Set up" for both. New
    /// installs get the one-tap file; people who already did the editor work keep working.
    static var cellularModeUsable: Bool { airplaneReady || cellularModeReady }

    /// Where the one-action Airplane shortcut is published, for the one-tap install in the setup card.
    static let airplaneInstallURL =
        "https://wanderspoofer.com/downloads/shortcuts/wander-airplane.shortcut"

    /// Where the LEGACY all-in-one shortcut is published, kept for the fallback path.
    static let cellularModeInstallURL =
        "https://wanderspoofer.com/downloads/shortcuts/wander-cellular-mode.shortcut"

    /// Is the Shortcuts app even present? Needs `shortcuts` in LSApplicationQueriesSchemes to answer true.
    static var shortcutsAppInstalled: Bool {
        URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Run a named shortcut, returning to wander://<successHost> on success. `input` is passed as the
    /// shortcut's text input when present (e.g. a coordinate for a parametric router).
    ///
    /// `errorHost` exists because the x-error callback is what keeps an "installed" flag honest, and
    /// there is now more than one such flag (see `cellularModeReady`). Defaulting it to the original
    /// host leaves every existing caller byte-for-byte unchanged.
    ///
    /// `onOpenFailure` covers the same need for the "iOS couldn't open Shortcuts at all" path: the old
    /// code cleared `ready` unconditionally there, which would have been the WRONG flag for a Cellular
    /// Mode run. Nil keeps the original behaviour exactly.
    static func run(name: String, successHost: String, input: String? = nil,
                    errorHost: String = "shortcut-missing",
                    onOpenFailure: (() -> Void)? = nil) {
        var c = URLComponents()
        c.scheme = "shortcuts"
        c.host = "x-callback-url"
        c.path = "/run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        // Callback hosts here have no ?/& so URLComponents' encoding of the whole value is safe.
        items.append(URLQueryItem(name: "x-success", value: "wander://\(successHost)"))
        items.append(URLQueryItem(name: "x-error", value: "wander://\(errorHost)"))
        items.append(URLQueryItem(name: "x-cancel", value: "wander://cancel"))
        c.queryItems = items
        guard let url = c.url else {
            // Same outcome as "iOS couldn't open Shortcuts", and it needs the same handling: nothing
            // ran, so a caller that armed state for this run (Cellular Mode arms a stranding marker
            // BEFORE the hand-off, on purpose) must be told to retire it. Falling out of here with a
            // bare `return` left that marker to age into a recovery banner for a run that never
            // launched.
            if let onOpenFailure { onOpenFailure() } else { ready = false }
            return
        }
        UIApplication.shared.open(url, options: [:]) { ok in
            // If iOS couldn't even open Shortcuts (not installed), treat as not-ready.
            guard !ok else { return }
            if let onOpenFailure { onOpenFailure() } else { ready = false }
        }
    }

    /// Flip Airplane Mode, and nothing else. One leg of a `CellularModeSequence` run.
    ///
    /// The success callback is `wander://open`, which is already a documented no-op in the app's link
    /// table ("opening the app is the whole effect") — deliberately, because the SEQUENCE is what
    /// advances on the return, not the link. Wander watches its own foreground transition and then
    /// checks the actual network path, so a leg that silently did nothing is caught by looking at the
    /// radio rather than by trusting a callback.
    ///
    /// The error callback goes to a host nothing handles for the same reason: an x-error still brings
    /// Wander forward, and `CellularModeSequence` will find the radio unchanged and say so with a
    /// sentence about the actual problem. There is nothing useful for a URL case to add.
    static func runAirplane(on: Bool, onOpenFailure: @escaping () -> Void) {
        run(name: airplaneName,
            successHost: "open",
            input: on ? "on" : "off",
            errorHost: "airplane-missing",
            onOpenFailure: onOpenFailure)
    }

    /// One-tap Cellular Mode.
    ///
    /// Routes to whichever shortcut the user actually has, so a single call site serves both. New
    /// installs take the one-action `Wander Airplane` file and let `CellularModeSequence` conduct;
    /// anyone who already did the Shortcuts-editor work for the old all-in-one file keeps using it,
    /// unchanged, rather than being told to set up again.
    ///
    /// The legacy path's coordinate goes over as plain `"lat, lng"` because that is exactly what
    /// `TeleportIntent` already parses (`WanderLocationIntent.resolveCoordinate`), so the shortcut needs
    /// no formatting logic of its own and a hand-built copy can't get the format subtly wrong. Five
    /// decimals is ~1 m — far finer than anything downstream of this can resolve, and short enough to
    /// read in the run log. `en_US_POSIX` because a comma-decimal locale would otherwise emit
    /// "40,68922" and turn one coordinate into four numbers.
    @MainActor
    static func runCellularMode(latitude: Double, longitude: Double) {
        if airplaneReady {
            CellularModeSequence.shared.start(latitude: latitude, longitude: longitude)
            return
        }
        let text = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                          latitude, longitude)
        run(name: cellularModeName,
            successHost: "cellular-done",
            input: text,
            errorHost: "cellular-missing",
            onOpenFailure: { cellularModeReady = false })
    }

    /// Open the Shortcuts app (onboarding step: running any shortcut once un-grays the untrusted toggle).
    static func openShortcutsApp() {
        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
    }
}
