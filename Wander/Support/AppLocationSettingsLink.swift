//
//  AppLocationSettingsLink.swift
//  Wander
//
//  The one place Settings deep links for location permissions are built, and the one place the
//  bundle ids those links need are written down.
//
//  Two destinations get confused constantly, so they are named apart here:
//
//    • `openLocationScreen(forBundleID:)` — a SPECIFIC app's own location permission screen
//      (Always / While Using, Precise Location). This is where the "set Pokémon GO to
//      Always + Precise" advice belongs.
//    • `openLocationServicesPane()` — the SYSTEM-WIDE Location Services switch, which is what the
//      flush / off-10-seconds-on instructions are about.
//
//  IMPORTANT, so nobody writes the wrong copy next to these buttons: iOS has NO URL scheme and NO
//  Shortcuts action that TOGGLES Location Services. Opening the pane is the ceiling — Wander can
//  take you to the switch, it can never flip it for you.
//
//  The `prefs:` scheme is undocumented. Apple can drop or rename these paths in any release, and a
//  button that silently does nothing is a support ticket, so every open walks a fallback ladder:
//  the per-app screen, then the generic Location Services pane, then the documented
//  `UIApplication.openSettingsURLString` (which always resolves, to Wander's own Settings page).
//

import UIKit

enum AppLocationSettings {

    /// Bundle identifiers used ONLY for building per-app Settings deep links. Kept together so they
    /// are greppable and fixable in one edit if a vendor ever ships under a new id.
    enum BundleID {
        /// Pokémon GO (Niantic Labs). Same identifier on every App Store storefront.
        static let pokemonGo = "com.nianticlabs.pokemongo"

        /// Wander itself. Read from the bundle rather than hard-coded: sideload signers rewrite the
        /// bundle id at install time, so a literal here would be wrong on most real installs.
        static var wander: String { Bundle.main.bundleIdentifier ?? "" }
    }

    /// The system-wide Location Services pane (the global switch).
    static let locationServicesPane = "prefs:root=Privacy&path=LOCATION"

    /// Opens `bundleID`'s own Location screen. Falls back to the generic pane, then to the
    /// documented app-settings URL. Passing nil/empty goes straight to the generic pane.
    static func openLocationScreen(forBundleID bundleID: String?) {
        var ladder: [String] = []
        if let bundleID, !bundleID.isEmpty {
            // iOS accepts the app's bundle id as a sub-path of the Location Services pane.
            ladder.append("\(locationServicesPane)/\(bundleID)")
        }
        ladder.append(locationServicesPane)
        open(ladder)
    }

    /// Opens the system-wide Location Services pane. This only NAVIGATES there; nothing in the app
    /// can toggle that switch.
    static func openLocationServicesPane() {
        open([locationServicesPane])
    }

    /// Tries each candidate in order.
    ///
    /// `canOpenURL` is consulted first (the `prefs` scheme is declared in LSApplicationQueriesSchemes,
    /// so it answers honestly) but it only reports whether the SCHEME is handled — never whether the
    /// path still exists. The `open` completion handler is therefore the real authority, and a false
    /// result drops to the next rung.
    private static func open(_ candidates: [String]) {
        guard let next = candidates.first,
              let url = URL(string: next),
              UIApplication.shared.canOpenURL(url)
        else {
            descend(Array(candidates.dropFirst()))
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened { descend(Array(candidates.dropFirst())) }
        }
    }

    /// Next rung down, or the guaranteed-valid system settings URL when the ladder is exhausted.
    private static func descend(_ remaining: [String]) {
        guard remaining.isEmpty else { open(remaining); return }
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
