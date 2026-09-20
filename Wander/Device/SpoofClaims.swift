//
//  SpoofClaims.swift
//  Wander
//
//  THE CLAIMS THIS PRODUCT IS BUILT ON, ENCODED SO THE DEVICE CAN CHECK THEM.
//
//  Wander's entire architecture — two engines, gs-loc for anti-cheat games, the dev tunnel for
//  everything else — rests on a handful of factual claims about what iOS reports under each engine.
//  Every one of them was measured at some point, but only ever recorded as prose. That has already
//  caused real damage twice: a research pass "corrected" a claim that had in fact been measured, and
//  the correction had to be reverted after re-testing.
//
//  So each claim below carries its EXPECTED outcome as code. Capturing evidence under a claim marks it
//  PASS or FAIL automatically — no interpretation, no remembering. A claim that has never been checked
//  on THIS device and THIS iOS version says so honestly rather than presenting itself as established.
//

import Foundation

enum ClaimOutcome: String, Codable {
    case pass
    case fail
    /// The reading could not decide it — usually the OS supplied no sourceInformation, or the engine
    /// state recorded with the capture doesn't match what the claim is about.
    case inconclusive
}

struct SpoofClaim: Identifiable {
    let id: String
    /// Stated as a falsifiable sentence, not a vibe.
    let statement: String
    /// What breaks if it is wrong. This is why the claim is worth a test at all.
    let stakes: String
    /// Exact device setup for a valid reading.
    let setup: [String]
    /// Decide the outcome from a captured record.
    let evaluate: (ExperimentRecord) -> ClaimOutcome

    /// Suggested label so captures file themselves under the right claim.
    var captureLabel: String { "claim:" + id }
}

enum SpoofClaims {

    /// Guard used by several claims: the capture must have been taken with the engine the claim is
    /// about, or the reading says nothing. Silently scoring a mismatched capture is how a log starts
    /// lying.
    private static func requireEngine(_ r: ExperimentRecord, gsloc: Bool) -> Bool {
        r.gslocModeEnabled == gsloc
    }

    /// ⚠️ THE FALSE-PASS GUARD. Added 2026-08-10 after a real one got through.
    ///
    /// A gs-loc capture was scored PASS purely because "gs-loc mode is ON and the flag is FALSE" — but
    /// Shadowrocket was not connected, so nothing was intercepting and the reading was the user's REAL
    /// location. The flag was FALSE because the fix was genuine, not because gs-loc produced a clean
    /// fake. A checker that a no-op can satisfy is worse than no checker, because it manufactures
    /// confidence.
    ///
    /// gs-loc CANNOT work without a proxy app holding iOS's VPN slot, so no foreign VPN means the
    /// capture is inconclusive by construction — no interpretation required.
    ///
    /// ⚠️ AND THAT IS STILL NOT ENOUGH — second false pass, 2026-08-10. With Shadowrocket genuinely
    /// connected, four captures were logged whose coordinates sat ~47 m from the user's real baseline:
    /// the difference between a GPS-derived and a Wi-Fi-derived fix AT THE SAME DESK, not a spoof. The
    /// flag read FALSE because the location was REAL. "The proxy app is running" says nothing about
    /// whether the rewrite fired.
    ///
    /// The only honest test is whether the reported location actually LANDED ON THE PUSHED TARGET. A
    /// spoof that does not move the fix is a no-op, and a no-op must never score PASS.
    private static func gslocPlausiblyActive(_ r: ExperimentRecord) -> Bool {
        guard r.foreignVPNActive else { return false }
        return spoofActuallyLanded(r)
    }

    /// True only when Wander was pushing a target AND Core Location is reporting near it. 150 m is
    /// deliberately generous — a WPS centroid is tens of metres wide — while still being far tighter
    /// than any real teleport distance.
    private static func spoofActuallyLanded(_ r: ExperimentRecord) -> Bool {
        guard let d = r.distanceFromTargetMeters else { return false }
        return d <= 150
    }

    /// Same problem on the tunnel side: if the DVT endpoint was unreachable, no injection happened and
    /// whatever was captured is the real location wearing the wrong label.
    private static func dvtPlausiblyActive(_ r: ExperimentRecord) -> Bool {
        r.tunnelEndpointReachable && spoofActuallyLanded(r)
    }

    static let all: [SpoofClaim] = [

        SpoofClaim(
            id: "real-gps-flag-false",
            statement: "With NO spoof running, isSimulatedBySoftware reads FALSE.",
            stakes: "The control. If this fails, the instrument itself is broken and every other reading in this log is worthless — check this first.",
            setup: [
                "Stop any spoof. No teleport, no route, no joystick.",
                "PoGo mode (gs-loc) OFF. LocalDevVPN may be on or off.",
                "Go outside or near a window so a real GPS fix exists.",
            ],
            evaluate: { r in
                guard let f = r.isSimulatedBySoftware else { return .inconclusive }
                return f == false ? .pass : .fail
            }
        ),

        SpoofClaim(
            id: "dvt-flag-true",
            statement: "A dev-tunnel (DVT) spoof sets isSimulatedBySoftware = TRUE.",
            stakes: "This is the whole reason gs-loc exists. If DVT actually reads FALSE, the two-engine split is unnecessary and PoGo could use the tunnel — with smooth movement.",
            setup: [
                "PoGo mode (gs-loc) OFF.",
                "LocalDevVPN ON (or Wander's own tunnel).",
                "Teleport anywhere and let it settle.",
            ],
            evaluate: { r in
                guard requireEngine(r, gsloc: false), dvtPlausiblyActive(r) else { return .inconclusive }
                guard let f = r.isSimulatedBySoftware else { return .inconclusive }
                return f == true ? .pass : .fail
            }
        ),

        SpoofClaim(
            id: "dvt-altitude-tell",
            statement: "A DVT spoof reports altitude 0.0 and a NEGATIVE verticalAccuracy — values a real GNSS fix never produces.",
            stakes: "A second, independent tell beyond the flag. DtSimulateLocation carries only lat/lng, so iOS backfills these. If any app checks them, DVT is detectable even if the flag were clean.",
            setup: [
                "Same as the DVT flag claim — gs-loc OFF, tunnel ON, teleport.",
                "Capture while the spoof is actively holding.",
            ],
            evaluate: { r in
                guard requireEngine(r, gsloc: false), dvtPlausiblyActive(r) else { return .inconclusive }
                return (r.altitude == 0 && r.verticalAccuracy < 0) ? .pass : .fail
            }
        ),

        SpoofClaim(
            id: "gsloc-flag-false",
            statement: "A gs-loc spoof leaves isSimulatedBySoftware = FALSE.",
            stakes: "The product's core differentiator and the reason PoGo works at all. If this ever flips, gs-loc stops being worth its setup cost and the PoGo path is dead.",
            setup: [
                "PoGo mode (gs-loc) ON, Shadowrocket connected, certificate trusted.",
                "Teleport, then do the refresh (Location Services off ~10s, on).",
                "Confirm Apple Maps shows the fake location BEFORE capturing.",
            ],
            evaluate: { r in
                guard requireEngine(r, gsloc: true), gslocPlausiblyActive(r) else { return .inconclusive }
                guard let f = r.isSimulatedBySoftware else { return .inconclusive }
                return f == false ? .pass : .fail
            }
        ),

        SpoofClaim(
            id: "gsloc-fields-natural",
            statement: "A gs-loc spoof reports a NON-ZERO altitude and a POSITIVE verticalAccuracy — locationd fills every field naturally.",
            stakes: "This is why gs-loc has no wire-level tell: the fix is computed by locationd's own pipeline from poisoned inputs, so it looks like any other network fix. If these come back 0/-1, gs-loc has the same fingerprint as DVT and one of its two advantages is imaginary.",
            setup: [
                "Same as the gs-loc flag claim.",
                "Capture while Maps still shows the fake location.",
            ],
            evaluate: { r in
                guard requireEngine(r, gsloc: true), gslocPlausiblyActive(r) else { return .inconclusive }
                return (r.altitude != 0 && r.verticalAccuracy > 0) ? .pass : .fail
            }
        ),

        SpoofClaim(
            id: "inapp-proxy-honored",
            statement: "locationd routes its WPS lookup through an in-app Wi-Fi HTTP proxy — no Network Extension, no entitlement.",
            stakes: "The whole in-app gs-loc engine rests on this. If it is false, Shadowrocket can never be removed and the TLS build is wasted effort. Captured 2026-08-08, but by a green banner rather than a record — this makes it re-readable.",
            setup: [
                "Settings → EXPERIMENTAL → Proxy probe → Start proxy.",
                "Settings → Wi-Fi → ⓘ → Configure Proxy → Manual, 127.0.0.1, port 8888, Authentication OFF, Save.",
                "Open Apple Maps and tap the location arrow; wait 10–20s.",
                "Return to the probe — it files this claim itself when a gs-loc lookup arrives.",
                "AFTERWARDS set Configure Proxy back to Off, or Wi-Fi stays broken.",
            ],
            evaluate: { r in
                // Filed by the probe, which only captures when a WPS host actually connected. The proxy
                // must have been running or the record is about something else entirely.
                r.proxyProbeRunning ? .pass : .inconclusive
            }
        ),

        SpoofClaim(
            id: "coherence-vs-flag",
            statement: "Pokémon GO rejects a spoof because of the FLAG, not because GPS disagrees with Apple's network location.",
            stakes: "THE open question. Every past test changed both at once. If it is coherence rather than the flag, DVT movement works whenever gs-loc holds the network location steady — joystick and routes in PoGo.",
            setup: [
                "1. gs-loc ON + Shadowrocket: teleport, refresh, confirm Maps shows the fake spot.",
                "2. Shadowrocket OFF, LocalDevVPN ON. Do NOT re-teleport — the network fix stays cached.",
                "3. PoGo mode OFF, then teleport with the tunnel to the SAME area.",
                "4. Capture here, then open Pokémon GO and record whether it works.",
            ],
            evaluate: { r in
                // Only the human can score this one: the capture proves the FLAG state, but whether the
                // game accepted it is observed in the game, so it is recorded in the note rather than
                // inferred. Marking it pass/fail from the reading alone would be fabrication.
                guard r.isSimulatedBySoftware != nil else { return .inconclusive }
                return .inconclusive
            }
        ),
    ]

    static func claim(id: String) -> SpoofClaim? { all.first { $0.id == id } }

    /// Best-known outcome for a claim, from the most recent capture filed under it.
    static func latestOutcome(for claim: SpoofClaim, in records: [ExperimentRecord]) -> (ClaimOutcome, Date)? {
        guard let rec = records.first(where: { $0.label == claim.captureLabel }) else { return nil }
        return (claim.evaluate(rec), rec.timestamp)
    }
}
