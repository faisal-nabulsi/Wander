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
    ///
    /// There is deliberately NO Wi-Fi flush here. A "cycle Wi-Fi off and on" shortcut shipped for
    /// months as the gs-loc snap fix; it is not one. The fix for a snapped fix is the Location
    /// Services toggle, which no shortcut can perform — iOS 26.5 ships eighteen `*.set` toggle
    /// actions and Location Services is not among them, so the pane can only be opened, not flipped.
    ///
    /// "Set VPN → LocalDevVPN → Connect → Open App Wander" — connects the DEFAULT tunnel (used for
    /// everything except games, and to install updates) from an in-app tap, then auto-returns.
    static let vpnConnectName = "Wander Connect VPN"
    /// "Set VPN → Shadowrocket → Connect → Open App Wander" — connects the PoGo/games proxy and bounces
    /// back to Wander (unlike shadowrocket://connect, which strands you in Shadowrocket).
    static let shadowrocketConnectName = "Wander Connect Shadowrocket"

    /// THE ONLY SHORTCUT CELLULAR MODE NEEDS, AND THE ONLY NAME ANY OF US SAYS FOR IT. One job: flip
    /// Airplane Mode. Input "on" turns it on and waits ~4 s for the radio to settle; ANYTHING else —
    /// including a hand-run with no input — turns it off, which is the safe default for an empty
    /// variable.
    ///
    /// WHY THE NAME CHANGED. This file used to be published as "Wander Airplane" while the feature was
    /// called Cellular Mode everywhere in the app, so the button, the setup card and the Shortcuts
    /// library each said something different. The feature keeps its name; the file takes it.
    ///
    /// WHY IT IS THIS SMALL. Everything else in the old sequence (tunnel up, teleport) was an App
    /// Intent action purely so the Shortcut could WAIT for it, and an App Intent action serialises the
    /// target app's bundle id + team id — values that differ for every install, which is why those two
    /// actions could never be shipped pre-filled and had to be added by hand in the editor. Wander
    /// conducts the sequence itself now (`CellularModeSequence`), so this file contains only
    /// `is.workflow.actions.*` built-ins, carries no app identity, and imports ready to run under every
    /// signature. See `CellularModeSequence` for the full argument.
    static let cellularModeName = "Wander Cellular Mode"

    /// Persisted "the Wander shortcuts are installed" flag. Set optimistically after onboarding; flipped
    /// back to false whenever a run reports x-error (shortcut missing/renamed) so the UI self-heals.
    static var ready: Bool {
        get { UserDefaults.standard.bool(forKey: "shortcutsReady") }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutsReady") }
    }

    // MARK: - The one flag Cellular Mode is allowed to trust
    //
    // ⚠️ THIS IS A PROOF OF IDENTITY, NOT A "the user says it's installed" FLAG, AND THE DIFFERENCE IS
    // WHAT KEEPS SOMEBODY'S PHONE ON THE NETWORK. Read this before weakening it.
    //
    // Wander runs shortcuts BY NAME and cannot see inside one. The name "Wander Cellular Mode" used to
    // belong to a DIFFERENT file — the old all-in-one, where the Shortcut was the conductor. If that
    // older file is still in somebody's library when this app asks for the name, iOS may hand our
    // request to it, and it will ignore our input entirely and run its own sequence: Airplane Mode on,
    // then Wander's two App Intents, then Airplane Mode off. Its restore step is real (it is
    // unconditional, on every path), but `StartTunnelIntent.openAppWhenRun` foregrounds Wander in the
    // middle of that run, and a suspended Shortcuts run that never reaches its last actions leaves the
    // radio off. That is the one outcome this whole feature exists to prevent.
    //
    // Wander cannot tell the two files apart by asking iOS, so the file tells us itself: the shipped
    // one-action file's last step opens `wander://airplane-ok`, and the legacy file's last step opens
    // `wander://cellular-done`. Those two are disjoint, so whichever arrives names the file that ran.
    //
    // THE PROOF MUST COME FROM INSIDE THE FILE. It deliberately does NOT come from the x-success
    // callback (`wander://open`), because Shortcuts fires x-success for whatever it ran — including the
    // legacy file — so routing identity through x-success would forge it.

    /// "A shortcut we invoked BY NAME answered with `wander://airplane-ok`, so the name resolves to the
    /// one-action file." The only thing that may arm Cellular Mode.
    ///
    /// Set exclusively by `CellularModeSequence`, and only for a run Wander itself started — a hand-run
    /// from the Shortcuts app proves the file exists but says nothing about what it is CALLED, which is
    /// the only question this flag answers. Cleared whenever a run contradicts it.
    static var cellularModeVerified: Bool {
        get { UserDefaults.standard.bool(forKey: "cellularModeShortcutVerified") }
        set { UserDefaults.standard.set(newValue, forKey: "cellularModeShortcutVerified") }
    }

    // MARK: - Retiring the old flags
    //
    // The three keys below are gone, and NONE of them may be migrated into `cellularModeVerified`.
    // `wanderAirplaneShortcutReady` was set by a user tapping "I've added it" — an intention, not
    // evidence — and everyone who has it true is holding the PREVIOUS file, which does not emit
    // `airplane-ok` and therefore is not the thing the new flag asserts. `wanderAirplaneShortcutMissing`
    // was sticky and only ever routed to the legacy shortcut, which no longer exists to route to;
    // leaving it set would dead-end the button. Removing them all means everybody re-verifies once,
    // which is exactly what a rename should cost.

    /// One-time cleanup of the pre-rename Cellular Mode flags. Called from `AppBootstrapper`.
    static func migrateCellularModeFlags() {
        let d = UserDefaults.standard
        for key in ["wanderAirplaneShortcutReady", "wanderAirplaneShortcutMissing",
                    "cellularModeShortcutReady"] where d.object(forKey: key) != nil {
            d.removeObject(forKey: key)
        }
    }

    // MARK: - Install URLs
    //
    // PUBLISHED UNDER THE DISPLAY NAME, AND THE SPACES ARE LOAD-BEARING. A `.shortcut` file carries no
    // name of its own: its authenticated header holds only a certificate chain, and the payload's
    // single entry is always called `Shortcut.wflow`. So iOS has exactly one thing to name an import
    // after — the downloaded file's name, minus the extension. Every one of these used to be published
    // kebab-cased, so every user who followed our own instructions got a shortcut called
    // "wander-airplane", which is NOT a name any of the calls below ask for, and was then quietly
    // required to rename it by hand before anything worked.
    //
    // The filename is not part of the signed bytes, so publishing under the display name needs no
    // re-signing. GitHub Pages serves this tree raw (`.nojekyll`) and sends no `Content-Disposition`,
    // so Safari names the download from the last path component, percent-decoded — `Wander%20Airplane`
    // lands in Files as "Wander Cellular Mode.shortcut" and imports as "Wander Cellular Mode".
    //
    // WRITE THEM PRE-ENCODED. These strings are handed to `URL(string:)`, which returns nil on a raw
    // space — the button would silently do nothing. The kebab paths stay live as copies (not
    // redirects) so already-shipped builds and pasted links keep resolving.
    //
    // ALL FOUR PUBLISHED PATHS NOW SERVE THE SAME ONE-ACTION FILE — the two spellings of this name and
    // the two spellings of the old "Wander Airplane" name. That is deliberate rather than tidy: a user
    // on a build shipped before this rename follows a link to `Wander%20Airplane.shortcut`, and what
    // they must not get is the old all-in-one file. Serving the safe file everywhere means every stale
    // link in every shipped build lands on something that cannot strand anyone.

    /// Where the one-action Cellular Mode shortcut is published, for the one-tap install in the setup
    /// card. Published under the DISPLAY name so the import is already called the name we run.
    static let cellularModeInstallURL =
        "https://wanderspoofer.com/downloads/shortcuts/Wander%20Cellular%20Mode.shortcut"

    // MARK: - Name fallback
    //
    // Publishing under the display name fixes everyone who imports from now on. It does nothing for a
    // shortcut already sitting in somebody's library under the old kebab name — including the owner's,
    // and including anyone who renamed it to something else and gave up. Those users are fixed here
    // instead: when Shortcuts reports x-error ("nothing in this library is called that"), try the
    // filename spelling once before believing the shortcut is missing.

    /// The filename spelling of a display name: "Wander Cellular Mode" → "wander-cellular-mode".
    ///
    /// Shortcuts matches names EXACTLY — it normalises neither case nor punctuation — so a fallback
    /// has to try a second literal string rather than ask for a looser comparison.
    ///
    /// ⚠️ FOR CELLULAR MODE THIS SECOND STRING IS ALSO THE OLD ALL-IN-ONE FILE'S PUBLISHED FILENAME, so
    /// the retry is a second door onto the same collision the display name has. It is safe for exactly
    /// one reason: the retry does not decide anything. Whichever file answers still has to identify
    /// itself (`wander://airplane-ok` vs `wander://cellular-done`) before `CellularModeSequence` will
    /// build a tunnel or arm the feature. Do not add a code path that treats a successful retry as
    /// proof on its own.
    static func filenameSpelling(of name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The one run that is currently eligible for a name-fallback retry.
    ///
    /// A single slot rather than a table, because iOS foregrounds Shortcuts to run ONE shortcut at a
    /// time — there is never a second run in flight — and a fresh `run()` overwrites it. It is
    /// consumed on read, so the retry can fire at most once per run: a second x-error finds the slot
    /// empty, falls through to the caller's not-installed handling, and the setup card comes back.
    private static var pendingFallback: (errorHost: String, alternate: String, successHost: String,
                                         input: String?, onOpenFailure: (() -> Void)?)?

    /// Re-run the last shortcut under its filename spelling, after Shortcuts reported x-error.
    ///
    /// Returns false when there is nothing to retry — no pending run, a different error host, or the
    /// retry already happened — which is the caller's signal to clear its installed flag for real.
    @discardableResult
    static func retryUnderFilenameSpelling(errorHost: String) -> Bool {
        guard let p = pendingFallback, p.errorHost == errorHost else { return false }
        pendingFallback = nil
        run(name: p.alternate, successHost: p.successHost, input: p.input,
            errorHost: p.errorHost, onOpenFailure: p.onOpenFailure, allowNameFallback: false)
        return true
    }

    /// Is the Shortcuts app even present? Needs `shortcuts` in LSApplicationQueriesSchemes to answer true.
    static var shortcutsAppInstalled: Bool {
        URL(string: "shortcuts://").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    /// Run a named shortcut, returning to wander://<successHost> on success. `input` is passed as the
    /// shortcut's text input when present (e.g. a coordinate for a parametric router).
    ///
    /// `errorHost` exists because the x-error callback is what keeps an "installed" flag honest, and
    /// Cellular Mode keeps its own (see `cellularModeVerified`). Defaulting it to the original host
    /// leaves every existing caller byte-for-byte unchanged.
    ///
    /// `onOpenFailure` covers the same need for the "iOS couldn't open Shortcuts at all" path: the old
    /// code cleared `ready` unconditionally there, which would have been the WRONG flag for a Cellular
    /// Mode run. Nil keeps the original behaviour exactly.
    ///
    /// `allowNameFallback` arms the one-shot kebab retry described above. It is false for a run that
    /// IS the retry (so a miss can't loop), and false for `runAirplane`, whose retry has to be
    /// sequenced by `CellularModeSequence` rather than fired blind — see there.
    static func run(name: String, successHost: String, input: String? = nil,
                    errorHost: String = "shortcut-missing",
                    onOpenFailure: (() -> Void)? = nil,
                    allowNameFallback: Bool = true) {
        let alternate = filenameSpelling(of: name)
        pendingFallback = (allowNameFallback && alternate != name)
            ? (errorHost, alternate, successHost, input, onOpenFailure)
            : nil
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
    /// THE SUCCESS CALLBACK IS NOT THE PROOF. It stays `wander://open`, a documented no-op in the app's
    /// link table ("opening the app is the whole effect"), because Shortcuts fires x-success for
    /// whatever it ran — the right file, the wrong file, any file. What advances the sequence is the
    /// `wander://airplane-ok` that the shipped file opens ITSELF as its last action, plus Wander's own
    /// look at the radio. Do not move the identity proof onto x-success; that would forge it.
    ///
    /// The error callback lands on `wander://airplane-missing`, which `MainTabView` hands to
    /// `CellularModeSequence.retryLegUnderFilenameSpelling()`. It deliberately does NOT go through the
    /// generic `pendingFallback` path: a blind re-fire would race the sequence's own lifecycle, which
    /// starts an 8-second radio poll the moment Wander comes back on screen. The sequence knows which
    /// leg is in flight and has to abandon that poll before handing off again.
    ///
    /// If the retry also misses, the sequence finds the radio unchanged and says so — with the setup
    /// card attached, so a second failure is never silent.
    static func runAirplane(on: Bool, name: String = cellularModeName,
                            onOpenFailure: @escaping () -> Void) {
        run(name: name,
            successHost: "open",
            input: on ? "on" : "off",
            errorHost: "airplane-missing",
            onOpenFailure: onOpenFailure,
            allowNameFallback: false)
    }

    /// Open the Shortcuts app. Onboarding step 1, and it is load-bearing: iOS HIDES the Private Sharing
    /// row (older iOS: Allow Untrusted Shortcuts) until Shortcuts has run at least one shortcut, so a
    /// user who skips this goes looking for a setting that is not on screen.
    static func openShortcutsApp() {
        if let u = URL(string: "shortcuts://") { UIApplication.shared.open(u) }
    }
}
