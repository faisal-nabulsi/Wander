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
    /// THE CELLULAR SEQUENCE. Checks Wi-Fi; with none, turns Airplane Mode ON, waits for iOS to drop the
    /// cellular interface, runs Wander's `Start Wander Tunnel` + `Teleport to Place` App Intents (both of
    /// which BLOCK until they're actually done — that's why they're intents and not `wander://` links),
    /// then turns Airplane Mode back OFF and returns here. On Wi-Fi the airplane steps are skipped
    /// entirely. Takes the coordinate as its text input, so the app passes the pin the user picked.
    ///
    /// The `Start Wander Tunnel` action inside it must have its "Cellular Mode run" toggle switched
    /// ON (see `StartTunnelIntent.cellularMode`, and step 4 of `CellularModeSetupView`). That toggle
    /// is how a run launched from ANYWHERE — the Shortcuts app, Siri, the Action Button, Control
    /// Centre, an automation — arms the stranding marker; without it only runs started from a button
    /// inside Wander could ever be recovered. A copy of the shortcut predating the toggle still works
    /// and is still covered in the common case, by inference rather than declaration — see
    /// `CellularModeRun.armForTunnelIntent`.
    static let cellularModeName = "Wander Cellular Mode"

    /// Persisted "the Wander shortcuts are installed" flag. Set optimistically after onboarding; flipped
    /// back to false whenever a run reports x-error (shortcut missing/renamed) so the UI self-heals.
    static var ready: Bool {
        get { UserDefaults.standard.bool(forKey: "shortcutsReady") }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutsReady") }
    }

    /// Same idea as `ready`, but for the Cellular Mode shortcut ALONE.
    ///
    /// Deliberately NOT folded into `ready`: that flag means "the gs-loc/flush pack is installed", and a
    /// user who set those up years ago has not thereby installed this one. Sharing the flag would show a
    /// one-tap button that lands on an x-error every time. Self-heals the same way — a run that reports
    /// `wander://cellular-missing` flips it back to false and the setup card returns.
    static var cellularModeReady: Bool {
        get { UserDefaults.standard.bool(forKey: "cellularModeShortcutReady") }
        set { UserDefaults.standard.set(newValue, forKey: "cellularModeShortcutReady") }
    }

    /// Where the Cellular Mode shortcut is published, for the one-tap install in the setup card.
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

    /// One-tap Cellular Mode: hand the shortcut the pin the user actually selected and let it do the
    /// airplane dance around Wander's own `Start Wander Tunnel` + `Teleport to Place` App Intents.
    ///
    /// The coordinate goes over as plain `"lat, lng"` because that is exactly what `TeleportIntent`
    /// already parses (`WanderLocationIntent.resolveCoordinate`), so the shortcut needs no formatting
    /// logic of its own and a hand-built copy can't get the format subtly wrong. Five decimals is ~1 m —
    /// far finer than anything downstream of this can resolve, and short enough to read in the run log.
    /// `en_US_POSIX` because a comma-decimal locale would otherwise emit "40,68922" and turn one
    /// coordinate into four numbers.
    static func runCellularMode(latitude: Double, longitude: Double) {
        let text = String(format: "%.5f, %.5f", locale: Locale(identifier: "en_US_POSIX"),
                          latitude, longitude)
        run(name: cellularModeName,
            successHost: "cellular-done",
            input: text,
            errorHost: "cellular-missing",
            onOpenFailure: {
                cellularModeReady = false
                // iOS could not even open Shortcuts, so nothing ran and nothing touched the radio.
                // Retire the stranding marker the caller armed rather than let it age into a
                // recovery banner for a run that never started.
                Task { @MainActor in CellularModeRun.shared.noteRunNeverStarted() }
            })
    }

    /// Open the Shortcuts app (onboarding step: running any shortcut once un-grays the untrusted toggle).
    static func openShortcutsApp() {
        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
    }
}
