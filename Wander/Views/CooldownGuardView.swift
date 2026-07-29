//
//  CooldownGuardView.swift
//  Wander
//
//  A compact, persistent "safe to catch/spin" countdown chip. After a big teleport,
//  Niantic games apply a distance-based soft-ban cooldown: catching/spinning during it
//  can wipe rewards. We can't gate PoGo's in-app taps (server-side, no hook), so this is
//  pure GUIDANCE — a live MM:SS timer, visible across every tab, that tells the user how
//  long to WAIT before interacting. Teleporting and walking stay free.
//
//  Reads the single source of truth on SimulationSession (fed by the existing PoGoCooldown
//  curve on every confirmed teleport). Hidden the moment the cooldown clears.
//
//  Also home to the PRE-teleport side of the same guidance (CooldownPreview + its row label):
//  the chip answers "how long must I wait now?", the preview answers "what would that jump
//  cost me?" before the user commits. Same curve, same numbers — just read forwards.
//

import SwiftUI
import CoreLocation

struct CooldownGuardView: View {
    @ObservedObject private var session = SimulationSession.shared

    var body: some View {
        if session.cooldownActive {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.caption)
                Text(L("cooldown.chip", fallback: "Safe to catch/spin in")
                     + " " + timeString(session.cooldownRemaining))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Wander.brand, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .allowsHitTesting(false)
            .accessibilityLabel(
                L("cooldown.chip.a11y",
                  fallback: "Soft-ban cooldown — wait before catching or spinning")
                + " " + timeString(session.cooldownRemaining)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Pre-teleport preview

/// What a CANDIDATE jump would cost, worked out before the user commits to it.
///
/// Users kept asking for the price up front ("is this spot going to cost me two hours?"), which
/// the post-teleport countdown can only answer once it's too late. This runs the exact same
/// numbers forwards: current spoofed coordinate -> candidate, through the existing PoGoCooldown
/// curve, with the same padding and ceiling `SimulationSession.applyCooldown` applies. So the
/// "≈2h" a row promises is the timer the user will actually get.
///
/// INFORMATIONAL ONLY — nothing here ever blocks or clamps a teleport. Same standing rule as the
/// "Speed guardrail (optional)" nudge: guardrails inform, the user decides.
enum CooldownPreview {
    /// Duplicated from `SimulationSession.applyCooldown` (they're private there) so the preview and
    /// the live countdown can never disagree. If those constants ever move, move these with them.
    private static let buffer = 1.10
    private static let capSeconds: TimeInterval = 120 * 60

    /// A cooldown shorter than this is over before the countdown chip could even render one tick of
    /// it (the chip shows MM:SS, so it would read 00:00), which is the only honest definition of "no
    /// wait" — `applyCooldown` starts a real timer, chip and local notification included, for ANY
    /// non-zero value, so anything above this must be reported as a cost, however small.
    private static let noWaitSeconds: TimeInterval = 1

    /// How a candidate destination reads right now.
    enum Status: Equatable {
        /// Nothing is running and the jump is too short to start anything. The ONLY case that may
        /// read "Ready now".
        case ready
        /// The jump would start a cooldown of `seconds`.
        case cost(seconds: TimeInterval)
        /// A cooldown is ALREADY running, so jumping now is exactly the mistake the timer exists to
        /// prevent. `remaining` is the live countdown; `seconds` is what this jump would add on top,
        /// or nil when the hop is short enough to add nothing (there is still a wait to serve — it
        /// just isn't this destination's fault, so we don't pin a cost on it).
        case blocked(remaining: TimeInterval, seconds: TimeInterval?)

        /// Rows use this to dim themselves, so "what can I safely jump to right now?" is a glance,
        /// not arithmetic. Dimming only — the row stays fully tappable.
        var isBlocked: Bool {
            if case .blocked = self { return true }
            return false
        }
    }

    /// The status for `destination`, or nil when we simply can't say — no prior teleport to measure
    /// from (nothing has been spoofed yet), or a game preset that has no distance cooldown at all
    /// (Pikmin/Ingress). nil means "render nothing", never "no cooldown".
    ///
    /// The preset is read from UserDefaults rather than @AppStorage because this is also called from
    /// non-PoGo screens (Places), mirroring how `SimulationSession.applyCooldown` reads it.
    @MainActor
    static func status(for destination: CLLocationCoordinate2D) -> Status? {
        let preset = GamePreset(rawValue: UserDefaults.standard.string(forKey: "pogoGamePreset") ?? "")
            ?? .pokemonGo
        guard preset.usesTeleportCooldown else { return nil }

        let session = SimulationSession.shared
        guard let origin = session.lastTeleportCoordinate else { return nil }

        let km = PoGoCooldown.distanceKm(from: origin, to: destination)
        let seconds = min(PoGoCooldown.seconds(forKm: km) * buffer, capSeconds)

        // A running cooldown outranks everything: the chip on screen is already telling the user to
        // wait, so no row on that same screen may say "Ready now" — not even a jump next door. This
        // has to be checked BEFORE any short-hop shortcut, or the feature contradicts the very
        // guidance it exists to give.
        if session.cooldownActive, session.cooldownRemaining > 0 {
            // Under ~50 m `applyCooldown` treats the jump as a re-assert of the current point and
            // leaves the running cooldown untouched, so there's genuinely no added cost to quote.
            let added = (km * 1000 < 50) ? nil : seconds
            return .blocked(remaining: session.cooldownRemaining, seconds: added)
        }

        guard seconds >= Self.noWaitSeconds else { return .ready }
        return .cost(seconds: seconds)
    }

    /// "<1m" / "≈12m" / "≈2h" / "≈1h 25m" — the cost alone, no verb. Callers add the noun.
    ///
    /// The sub-minute case earns its own string rather than rounding: on this curve a 1 km hop is
    /// 33 s and a 2 km hop is 58 s, and both start a visible countdown, so "≈0m" (or worse, "Ready
    /// now") would promise a free jump the user is about to watch tick down.
    static func shortCost(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return L("cooldown.preview.under1m", fallback: "<1m") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "≈\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "≈\(hours)h" : "≈\(hours)h \(rest)m"
    }
}

/// The one-line row annotation for a candidate destination: "Ready now", "≈2h cooldown", or —
/// while a cooldown is still counting down — "Wait 04:21 · ≈2h" ("Wait 04:21" alone for a hop that
/// adds nothing to the wait already running).
///
/// Renders nothing at all when there's nothing useful to say, so it can be dropped into any row
/// without reserving space or introducing a new component. Observes the shared session so the
/// countdown in the blocked case stays live.
struct CooldownPreviewLabel: View {
    let destination: CLLocationCoordinate2D

    @ObservedObject private var session = SimulationSession.shared

    var body: some View {
        if let status = CooldownPreview.status(for: destination) {
            switch status {
            case .ready:
                label(L("cooldown.preview.ready", fallback: "Ready now"), tint: .green)
            case .cost(let seconds):
                label(CooldownPreview.shortCost(seconds)
                      + " " + L("cooldown.preview.noun", fallback: "cooldown"),
                      tint: .secondary)
            case .blocked(let remaining, let seconds):
                // No cost suffix when this hop adds nothing — "Wait 04:21 · ≈0m" would read as if the
                // destination were charging the user for a wait it didn't cause.
                label(L("cooldown.preview.wait", fallback: "Wait")
                      + " " + timeString(remaining)
                      + (seconds.map { " · " + CooldownPreview.shortCost($0) } ?? ""),
                      tint: .orange)
            }
        }
    }

    private func label(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    /// Same MM:SS shape as the countdown chip above, so the two never look like different clocks.
    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    CooldownGuardView()
}
