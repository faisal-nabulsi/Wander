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

    /// Persisted "the Wander shortcuts are installed" flag. Set optimistically after onboarding; flipped
    /// back to false whenever a run reports x-error (shortcut missing/renamed) so the UI self-heals.
    static var ready: Bool {
        get { UserDefaults.standard.bool(forKey: "shortcutsReady") }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutsReady") }
    }

    /// Is the Shortcuts app even present? Needs `shortcuts` in LSApplicationQueriesSchemes to answer true.
    static var shortcutsAppInstalled: Bool {
        URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Run a named shortcut, returning to wander://<successHost> on success. `input` is passed as the
    /// shortcut's text input when present (e.g. a coordinate for a parametric router).
    static func run(name: String, successHost: String, input: String? = nil) {
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
        items.append(URLQueryItem(name: "x-error", value: "wander://shortcut-missing"))
        items.append(URLQueryItem(name: "x-cancel", value: "wander://cancel"))
        c.queryItems = items
        guard let url = c.url else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            // If iOS couldn't even open Shortcuts (not installed), treat as not-ready.
            if !ok { ready = false }
        }
    }

    /// Open the Shortcuts app (onboarding step: running any shortcut once un-grays the untrusted toggle).
    static func openShortcutsApp() {
        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
    }
}
