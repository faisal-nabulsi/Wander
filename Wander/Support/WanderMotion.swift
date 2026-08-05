//
//  WanderMotion.swift
//  Wander
//
//  The motion + feedback half of the design language (WanderStyle.swift owns colour and type).
//
//  WHY THIS FILE EXISTS: across ~23k lines of view code the app had 14 `.animation` calls, zero
//  `symbolEffect`, zero `contentTransition` and zero `sensoryFeedback` — so every state change
//  (tunnel connects, speed changes, a spoof goes live) landed as a hard cut with no confirmation
//  that anything happened. That reads as a hobby tool. The fix is NOT more animation; it is a
//  tiny, opinionated vocabulary that every screen reaches for, so motion is consistent and
//  nobody has to invent a spring at the call site.
//
//  THE TASTE RULE: springs here are quick and confident (0.22–0.35s, low bounce). Wander is a
//  utility people use mid-walk — motion should confirm, never delay. If an animation reads as
//  "bouncy" or you notice it finishing, it is wrong for this app.
//
//  Everything is additive. Nothing here is required for correctness; it is the polish layer.
//

import SwiftUI

// MARK: - Standard springs

/// The app's entire animation vocabulary. Four curves, deliberately. If a screen needs a fifth,
/// that's a signal the interaction is wrong, not that the vocabulary is short.
enum WanderMotion {

    /// The default. Control state, toggles, chips, colour changes, anything that should feel
    /// instant but not jarring. Use this unless you have a reason not to.
    static let quick = Animation.spring(response: 0.26, dampingFraction: 0.9)

    /// Layout: a card appearing, a row inserting, a sheet's content reflowing. Slightly longer
    /// so the eye can follow geometry, still under a third of a second.
    static let layout = Animation.spring(response: 0.34, dampingFraction: 0.86)

    /// A deliberate "that landed" accent — the primary action succeeded, the spoof went live.
    /// The only curve with visible overshoot, and it is small on purpose. Use sparingly; if
    /// everything pops, nothing does.
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.68)

    /// Numbers, meters, progress. Slightly damped and non-bouncy because an overshooting number
    /// briefly displays a value that is *wrong*.
    static let tick = Animation.spring(response: 0.24, dampingFraction: 1.0)

    /// How long one pass of the skeleton shimmer takes. Deliberately a DURATION and not an
    /// `Animation`: the shimmer is driven by `TimelineView(.animation)` (see `WanderShimmer` in
    /// WanderStyle.swift), not by `withAnimation`. A `repeatForever` animation started from
    /// `onAppear` against `@State` dies silently the second time a view appears — the state is
    /// already sitting at its target, so nothing changes and the skeleton renders as a flat,
    /// static bar. Any container that re-appears (a tab switch, a lazy stack scrolling a row
    /// back into view) hits that. Time-driven has no state to go stale.
    static let shimmerPeriod: TimeInterval = 1.15
}

// MARK: - Haptic vocabulary

/// Named feedback moments, so call sites say what HAPPENED rather than picking a waveform.
/// Thin mapping over SwiftUI's `SensoryFeedback` (declarative, trigger-driven) and, for
/// imperative code paths, over the existing `Haptics` enum in Support/Haptics.swift.
enum WanderFeedback {
    /// A value the user is scrubbing/stepping changed. The lightest tap we have.
    case light
    /// The user moved between discrete options (segment, picker, mode switch).
    case selection
    /// A thing the user asked for completed: spoof applied, route saved, tunnel connected.
    case success
    /// Degraded but usable — reconnecting, weak accuracy, approaching a limit.
    case warning
    /// The action failed or is blocked. Distinct from `warning` so users learn the difference.
    case failure

    var sensory: SensoryFeedback {
        switch self {
        case .light:     return .impact(weight: .light)
        case .selection: return .selection
        case .success:   return .success
        case .warning:   return .warning
        case .failure:   return .error
        }
    }

    /// Fire immediately from non-SwiftUI / imperative code (a completion handler, a service
    /// callback). Prefer the `.wanderFeedback(_:on:)` modifier inside views — it respects the
    /// system's feedback settings and won't double-fire on re-render.
    @MainActor func play() {
        switch self {
        case .light:     Haptics.light()
        case .selection: Haptics.selection()
        case .success:   Haptics.success()
        case .warning:   Haptics.warning()
        case .failure:   Haptics.failure()
        }
    }
}

// MARK: - View API
//
// Five ideas, one line each. That is the whole surface area — if applying polish takes more than
// one line, screens won't do it, which is exactly how the app ended up with zero of these calls.
//
// SF Symbol motion is deliberately split in two, because SwiftUI's `symbolEffect` is two
// different APIs wearing one name: a DISCRETE effect fires once per change and takes a `value:`,
// an INDEFINITE effect runs for as long as a condition holds and takes an `isActive:`. Mixing
// them (a discrete effect with `options: .repeating`) starts a throb that nothing ever stops.
// So: `wanderSymbolAccent(on:)` = something just changed. `wanderSymbolActive(_:)` = something
// is happening right now.

extension View {

    /// Numbers should TICK, not cut. Wraps `contentTransition(.numericText())` plus the
    /// non-overshooting `WanderMotion.tick` so a digit rolls to its new value.
    /// Apply to the `Text` showing the number, passing the underlying value:
    /// `Text(speedLabel).wanderTick(speed)`
    func wanderTick<V: Equatable>(_ value: V) -> some View {
        self
            .contentTransition(.numericText())
            .animation(WanderMotion.tick, value: value)
    }

    /// Give an SF Symbol a one-shot nudge when `value` changes, so a status icon flipping colour
    /// also flips with a little life. One bounce per change and then it is over — there is no
    /// repeating variant here on purpose (see the note above the extension). For "this is
    /// happening right now", use `wanderSymbolActive(_:)`.
    func wanderSymbolAccent<V: Equatable>(on value: V) -> some View {
        self.symbolEffect(.bounce, options: .speed(1.5), value: value)
    }

    /// A continuous throb while `active` is true — the honest signal for "working on it" on an
    /// icon that is already on screen, instead of swapping in a bare ProgressView. The throb
    /// stops the moment `active` goes false, which is the whole reason this is a separate call.
    func wanderSymbolActive(_ active: Bool) -> some View {
        self.symbolEffect(.pulse, isActive: active)
    }

    /// One call to make a state change carry a haptic. Fires whenever `value` changes.
    /// `chip.wanderFeedback(.success, on: isConnected)`
    ///
    /// ONLY the call site should reach for this, never a reusable component: a component cannot
    /// know whether a change was user-initiated, and Wander has background monitors (tunnel
    /// health, licence refresh) whose state flaps on a timer. A shared view that buzzed on every
    /// change would vibrate the phone in the user's pocket mid-walk.
    func wanderFeedback<V: Equatable>(_ kind: WanderFeedback, on value: V) -> some View {
        self.sensoryFeedback(kind.sensory, trigger: value)
    }

    /// Same, but silent unless `enabled`. For components that CAN carry feedback but must be
    /// asked to — the caller owning the state is the only one who knows the change came from a
    /// tap rather than from a poll.
    func wanderFeedback<V: Equatable>(_ kind: WanderFeedback, on value: V, enabled: Bool) -> some View {
        self.sensoryFeedback(trigger: value) { _, _ in enabled ? kind.sensory : nil }
    }

    /// Animate this view with the app's standard curve for a given value. Exists so screens stop
    /// writing bespoke `.easeInOut(duration: 0.2)` one-offs.
    func wanderAnimation<V: Equatable>(_ animation: Animation = WanderMotion.quick, on value: V) -> some View {
        self.animation(animation, value: value)
    }
}
