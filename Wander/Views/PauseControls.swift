//
//  PauseControls.swift
//  Wander
//
//  Everything the user sees for Pause: the button, the acquisition sheet, and the persistent
//  "Frozen" chip.
//
//  THE ONE RULE THIS FILE EXISTS TO ENFORCE: a user must never be unsure whether they are
//  broadcasting live or frozen. That is why the frozen state gets a PERSISTENT chip rather than a
//  toast. The existing "Spoofing active" banner is a 4.5 second flash (`flashBanner` schedules its
//  own hide), which is right for "spoofing started" and wrong for Pause — Pause's defining property
//  is that the user is deliberately NOT looking at the app.
//

import SwiftUI
import CoreLocation

// MARK: - The persistent state chip

/// ❄︎ Frozen · 12 min · ±3 m drift
///
/// Three facts, each earning its place: the STATE, HOW LONG (so a session left running overnight is
/// obvious at a glance), and the DRIFT — so the user can see the point is breathing rather than
/// dead. That last one is not decoration: `BreathingJitter` exists because "a dead point looks
/// parked-but-too-perfect" to Life360-class detectors, and the chip is the only place a user can
/// confirm it is actually working.
///
/// Tappable, and it goes to Stop. The one thing somebody needs in a hurry from a frozen state is
/// out of it.
struct FrozenChip: View {
    @ObservedObject private var pause = PauseController.shared
    @AppStorage("jitterEnabled") private var jitterEnabled = true

    @State private var showActions = false
    /// Re-renders the elapsed time once a minute. A `Timer` rather than a `TimelineView` so the
    /// chip costs nothing while it is not on screen.
    @State private var now = Date()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        if pause.isFrozen {
            chip
                .padding(.horizontal, 16)
                .padding(.top, 52)   // clears the inline nav bar, same slot as the other top banners
                .transition(.move(edge: .top).combined(with: .opacity))
                .onReceive(tick) { now = $0 }
                .confirmationDialog(
                    L("pause.chip.actions.title", fallback: "Your location is frozen"),
                    isPresented: $showActions,
                    titleVisibility: .visible
                ) {
                    Button(L("pause.chip.stop", fallback: "Stop — return to real GPS"), role: .destructive) {
                        pause.unfreeze()
                    }
                    // Its OWN key, not `action.cancel`. That key is already translated as
                    // "Cancel"/"Abbrechen"/… so a fallback of "Stay frozen" here would never be
                    // used — checked on screen, the button read "Cancel". "Cancel" is ambiguous on
                    // this dialog (cancel the freeze, or cancel the stopping?), which is the one
                    // ambiguity a frozen user cannot afford.
                    Button(L("pause.chip.stay", fallback: "Stay frozen"), role: .cancel) { }
                } message: {
                    Text(L("pause.chip.actions.body",
                           fallback: "Anyone you share location with still sees you at the spot you froze. Stopping puts you back on your real GPS."))
                }
        }
    }

    private var chip: some View {
        Button { showActions = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "snowflake")
                    .font(.caption.weight(.bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("pause.chip.title", fallback: "Frozen here — anyone sharing sees you at this spot"))
                        .font(.caption.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text(subtitle)
                        .font(.caption2)
                        .opacity(0.9)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.078, green: 0.451, blue: 0.612), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("pause.chip.a11y", fallback: "Location frozen — tap to stop and return to real GPS"))
    }

    private var subtitle: String {
        var parts: [String] = []
        if let since = pause.frozenSince {
            let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
            parts.append(minutes < 1
                         ? L("pause.chip.justnow", fallback: "just now")
                         : String(format: L("pause.chip.minutes", fallback: "%d min"), minutes))
        }
        // The drift envelope is `BreathingJitter`'s soft clamp (3 m), not a guess.
        let frozenHold = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
        parts.append((jitterEnabled && !frozenHold)
                     ? L("pause.chip.drift", fallback: "±3 m natural drift")
                     : L("pause.chip.nodrift", fallback: "no drift (perfectly still)"))
        return parts.joined(separator: " · ")
    }
}

// MARK: - The button

/// The Pause control. Reads `Pause here` → `Frozen — tap to unfreeze`.
///
/// Deliberately its own control rather than an overload of Simulate: Simulate means "go to the pin",
/// Pause means "stay exactly where you are", and one button meaning both is how somebody teleports
/// when they meant to freeze.
struct PauseButton: View {
    @ObservedObject private var pause = PauseController.shared

    var body: some View {
        // A ROW, not a button-with-a-caption-under-it. The first cut was exactly that, and on an
        // iPhone 16 Pro the caption fell below the panel's fold — the panel is a fixed-height
        // ScrollView, so the one line that explains what Pause does was invisible until you
        // scrolled, which nobody would. Title and subtitle inside one control can't be separated by
        // a fold. It also matches the "Find My / Life360 mode" row directly above it, which is the
        // same shape of thing: a labelled state, not an action on the pin.
        Button {
            pause.isFrozen ? pause.unfreeze() : pause.pause()
        } label: {
            HStack(spacing: MapModeChrome.groupSpacing) {
                Image(systemName: pause.isFrozen ? "snowflake" : Wander.Icon.pause)
                    .foregroundStyle(pause.isFrozen ? Wander.good : Wander.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.wanderDetail.weight(.semibold))
                        .foregroundStyle(.primary)
                    // The subtitle is not optional. "Pause" on its own reads as "stop doing
                    // something", which is the opposite of what this does.
                    Text(subtitle)
                        .wanderMicro()
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(MapModeChrome.innerPadding)
            .background(MapModeChrome.innerMaterial,
                        in: RoundedRectangle(cornerRadius: MapModeChrome.innerCornerRadius,
                                             style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var isBusy: Bool { pause.stage == .finding || pause.stage == .arming }

    private var title: String {
        switch pause.stage {
        case .finding: return L("pause.button.finding", fallback: "Finding you…")
        case .arming: return L("pause.button.arming", fallback: "Freezing…")
        case .frozen: return L("pause.button.frozen", fallback: "Frozen — tap to unfreeze")
        case .idle: return L("pause.button.idle", fallback: "Pause here (freeze)")
        }
    }

    private var subtitle: String {
        pause.isFrozen
            ? L("pause.button.sub.frozen", fallback: "You keep showing at this spot until you stop.")
            : L("pause.button.sub", fallback: "Keeps showing you here after you leave.")
    }
}

// MARK: - The acquisition / refusal sheet

/// What the user watches while Pause decides whether it can trust a fix, and what it says when it
/// cannot.
///
/// The progress readout is honest and self-explaining at the same time: somebody watching the
/// number fall from ±180 m to ±40 m understands exactly why they waited.
struct PauseFlowSheet: View {
    @ObservedObject private var pause = PauseController.shared
    @ObservedObject private var finder = PauseController.shared.finder

    let flow: PauseController.Flow

    /// Drives the countdown ring. 4 Hz is enough to look continuous and costs nothing over 8 s.
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 18) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            switch flow {
            case .finding: finding
            case .bestEffort(let fix): bestEffort(fix)
            case .refused(let refusal): refused(refusal)
            case .failed(let title, let message): failed(title: title, message: message)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
        .onReceive(tick) { now = $0 }
    }

    // MARK: Finding

    private var finding: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: deadlineProgress)
                    .stroke(Wander.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "location.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Wander.brand)
            }
            .frame(width: 76, height: 76)
            .padding(.top, 6)

            Text(L("pause.finding.title", fallback: "Finding you…"))
                .font(.headline)

            Text(accuracyLine)
                .font(.wanderNumeric(.subheadline, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // WHY THE USER IS WAITING AT ALL. Without this the delay reads as the app being slow.
            Text(L("pause.finding.body",
                   fallback: "Nothing has been sent to your device yet. Wander won't freeze you until it's sure where you are — a stale fix would pin you somewhere you already left."))
                .wanderMicro()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // The escape hatch NAMES its own error rather than warning generically.
            if let best = finder.best {
                Button {
                    pause.freezeAnyway(on: best)
                } label: {
                    Text(String(format: L("pause.finding.anyway", fallback: "Freeze here anyway (could be up to %@ off)"), best.errorText))
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(Wander.caution)
            }

            Button(L("action.cancel", fallback: "Cancel")) { pause.cancelFlow() }
                .font(.footnote)
                .padding(.top, 2)
        }
    }

    private var accuracyLine: String {
        guard let best = finder.best else {
            return String(format: L("pause.finding.waiting", fallback: "waiting for a fix — needs %@ or better"),
                          budgetText)
        }
        return String(format: L("pause.finding.accuracy", fallback: "%@ — waiting for %@"),
                      best.errorText, budgetText)
    }

    private var budgetText: String { "±\(Int(FreshFixFinder.acceptBudgetMeters)) m" }

    private var deadlineProgress: Double {
        guard let started = finder.startedAt else { return 0 }
        return min(1, max(0, now.timeIntervalSince(started) / FreshFixFinder.deadlineSeconds))
    }

    // MARK: Best effort

    private func bestEffort(_ fix: FreshFixFinder.Fix) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Wander.caution)
                .padding(.top, 6)

            Text(L("pause.besteffort.title", fallback: "Not sure enough to freeze you"))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(String(format: L("pause.besteffort.body",
                                  fallback: "The best fix Wander could get is %@ and %d seconds old. That could put you on the wrong street, and you won't be watching to notice."),
                        fix.errorText, Int(fix.ageSeconds.rounded())))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                pause.freezeAnyway(on: fix)
            } label: {
                Text(String(format: L("pause.besteffort.accept", fallback: "Freeze here anyway (%@)"), fix.errorText))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Wander.caution)
            .controlSize(.large)

            Button {
                pause.cancelFlow()
                pause.pause()
            } label: {
                Text(L("pause.besteffort.retry", fallback: "Move near a window and try again"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(L("action.cancel", fallback: "Cancel")) { pause.cancelFlow() }
                .font(.footnote)
        }
    }

    // MARK: Refusals

    @ViewBuilder
    private func refused(_ refusal: FreshFixFinder.Refusal) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "location.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(Wander.blocked)
                .padding(.top, 6)

            Text(refusalTitle(refusal)).font(.headline).multilineTextAlignment(.center)

            Text(refusalBody(refusal))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if refusal != .noGoodFix {
                Button {
                    AppLocationSettings.openLocationScreen(forBundleID: AppLocationSettings.BundleID.wander)
                } label: {
                    Text(L("pause.refused.settings", fallback: "Open Wander's location settings"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .controlSize(.large)
            }

            Button(L("action.close", fallback: "Close")) { pause.cancelFlow() }
                .font(.footnote)
        }
    }

    private func refusalTitle(_ refusal: FreshFixFinder.Refusal) -> String {
        switch refusal {
        case .notAuthorized:
            return L("pause.refused.auth.title", fallback: "Wander can't see where you are")
        case .reducedAccuracy:
            return L("pause.refused.precise.title", fallback: "Precise Location is off")
        case .noGoodFix:
            return L("pause.refused.nofix.title", fallback: "Couldn't find you")
        }
    }

    private func refusalBody(_ refusal: FreshFixFinder.Refusal) -> String {
        switch refusal {
        case .notAuthorized:
            return L("pause.refused.auth.body",
                     fallback: "Pause has to read your real location once, to know where to freeze you. Allow location access for Wander, then try again.")
        case .reducedAccuracy:
            // Say WHY waiting won't help — otherwise the user just taps again.
            return L("pause.refused.precise.body",
                     fallback: "With Precise Location off, iOS gives Wander a deliberately fuzzed position that can be over a kilometre out — and waiting won't improve it, because the fuzz is fixed. Turn Precise Location on for Wander, then try again.")
        case .noGoodFix:
            return L("pause.refused.nofix.body",
                     fallback: "No usable fix arrived. Move near a window or step outside for a moment, then try again — nothing was changed on your device.")
        }
    }

    // MARK: Write failure

    private func failed(title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Wander.blocked)
                .padding(.top, 6)

            Text(title).font(.headline).multilineTextAlignment(.center)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(L("action.ok", fallback: "OK")) { pause.cancelFlow() }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .controlSize(.large)
        }
    }
}
