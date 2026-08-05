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
//  ...and to the cooldown suite's screens: the journal (what happened, plus the interactions only
//  the user can tell us about), the rulebook (what starts the timer at all) and the account picker.
//  All of it reads through CooldownJournal, which is also where the "which of the two clocks do we
//  show?" rule lives — see `displayedRemaining()`.
//

import SwiftUI
import CoreLocation

struct CooldownGuardView: View {
    @ObservedObject private var session = SimulationSession.shared
    @ObservedObject private var journal = CooldownJournal.shared

    var body: some View {
        // Not `session.cooldownActive`: with per-account timers the chip has to show the SELECTED
        // account's wait, which can outlive (or be unrelated to) the one global countdown.
        let remaining = journal.displayedRemaining()
        if remaining > 0 {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.caption)
                Text(L("cooldown.chip", fallback: "Safe to catch/spin in")
                     + " " + timeString(remaining))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                // Only worth the pixels once there's more than one account to confuse it with.
                if journal.accounts.count > 1 {
                    Text(journal.active.name)
                        .font(.caption2)
                        .lineLimit(1)
                        .opacity(0.85)
                }
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
                + " " + timeString(remaining)
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
    /// Not private: CooldownJournal computes per-account cooldowns and must use these exact numbers
    /// rather than start a third copy of them.
    static let buffer = 1.10
    static let capSeconds: TimeInterval = 120 * 60

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
        let journal = CooldownJournal.shared
        // Measure from where the SELECTED account last stood, not from the device's last teleport:
        // with per-account timers those differ the moment the user switches, and quoting a cost from
        // another account's position is the one number this row must never show. Falls back to the
        // session for anything the journal hasn't seen (its first run on an existing install).
        guard let origin = journal.active.lastCoordinate ?? session.lastTeleportCoordinate else { return nil }

        let km = PoGoCooldown.distanceKm(from: origin, to: destination)
        let seconds = min(PoGoCooldown.seconds(forKm: km) * buffer, capSeconds)

        // A running cooldown outranks everything: the chip on screen is already telling the user to
        // wait, so no row on that same screen may say "Ready now" — not even a jump next door. This
        // has to be checked BEFORE any short-hop shortcut, or the feature contradicts the very
        // guidance it exists to give.
        let remaining = journal.displayedRemaining()
        if remaining > 0 {
            // Under ~50 m `applyCooldown` treats the jump as a re-assert of the current point and
            // leaves the running cooldown untouched, so there's genuinely no added cost to quote.
            let added = (km * 1000 < 50) ? nil : seconds
            return .blocked(remaining: remaining, seconds: added)
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
    // Also the journal: on an account whose clock is running without the global one (a logged
    // interaction restarted it), the session publishes nothing and the countdown would freeze.
    @ObservedObject private var journal = CooldownJournal.shared

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

// MARK: - Journal

/// The history screen: what this account has done, what it cost, and the one place the user can tell
/// Wander about the actions it cannot see.
///
/// The manual log is not a nicety. The cooldown runs from the last INTERACTION, and Wander has no
/// hook into the game — a spun stop or a caught Pokémon is invisible to us. Without a way to record
/// them the countdown is only ever half the story, which is exactly the gap users kept reporting.
struct CooldownJournalView: View {
    @ObservedObject private var journal = CooldownJournal.shared
    @ObservedObject private var session = SimulationSession.shared

    @State private var confirmClear = false
    /// Set instead of logging straight away when a cooldown is already running — see `logSection`.
    @State private var pendingInteraction: CooldownEntry.Interaction?

    var body: some View {
        List {
            statusSection
            logSection
            historySection
        }
        .navigationTitle(L("cooldown.journal.title", fallback: "Cooldown journal"))
        .navigationBarTitleDisplayMode(.inline)
        // Belt and braces: the journal normally absorbs teleports through its observer, but if this
        // screen is opened first on a fresh install the observer may not have existed yet. Idempotent
        // by tick, so the common case is a no-op.
        .onAppear { journal.syncPendingTeleport() }
        .confirmationDialog(
            L("cooldown.journal.clear.confirm", fallback: "Clear this account's history?"),
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button(L("cooldown.journal.clear", fallback: "Clear history"), role: .destructive) {
                journal.clearHistory()
            }
            Button(L("common.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(L("cooldown.journal.clear.note",
                   fallback: "Only the list is cleared — a running timer keeps counting."))
        }
    }

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        let remaining = journal.displayedRemaining()
        Section {
            HStack(spacing: 12) {
                Image(systemName: remaining > 0 ? "hourglass" : "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(remaining > 0 ? Wander.brand : .green)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(remaining > 0
                         ? L("cooldown.journal.waiting", fallback: "Wait ") + timeString(remaining)
                         : L("cooldown.journal.clear.state", fallback: "Clear — safe to catch and spin"))
                        .font(.headline)
                        .monospacedDigit()
                    Text(journal.active.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        } header: {
            Text(L("cooldown.journal.status", fallback: "Right now"))
        }
    }

    /// Hung on this section rather than on the List, because the List already owns the "clear
    /// history" dialog and two `.confirmationDialog` modifiers at the same level fight over which one
    /// gets to present.
    private var logSection: some View {
        Section {
            ForEach(CooldownEntry.Interaction.allCases) { interaction in
                Button {
                    // These are full-width rows that fire on one tap, and a tap taken while a
                    // cooldown is running adds that cooldown's whole length back onto the clock. Ask
                    // first in exactly that case; when nothing is running the tap only writes a
                    // history row, and a dialog would be friction for nothing.
                    if journal.displayedRemaining() > 0 {
                        pendingInteraction = interaction
                    } else {
                        journal.logInteraction(interaction)
                    }
                } label: {
                    Label(interaction.title, systemImage: interaction.symbol)
                        .foregroundStyle(.primary)
                }
            }

            // The other half of the mis-tap answer: deleting the history row afterwards tidies the
            // list but leaves the restarted clock standing, so the restart itself has to be
            // reversible. Offered for the last log only, and withdrawn as soon as a real teleport or
            // an account switch makes the old clock meaningless.
            if journal.canUndoInteraction {
                Button(role: .destructive) {
                    journal.undoLastInteraction()
                } label: {
                    Label(L("cooldown.journal.undo", fallback: "Undo last log"),
                          systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text(L("cooldown.journal.log", fallback: "I just did this"))
        } footer: {
            Text(L("cooldown.journal.log.note",
                   fallback: "Wander can't see inside the game, so these are the actions only you know about. Logging one while a cooldown is running restarts the timer, because that's what the community rules say the game does. It only changes the timer shown here — Wander never stops you teleporting."))
        }
        // Only ever raised for the destructive case (a cooldown is already running), so it doesn't
        // stand between the user and the ordinary "logged it, moving on" tap.
        .confirmationDialog(
            L("cooldown.journal.restart.confirm", fallback: "Restart the timer?"),
            isPresented: Binding(get: { pendingInteraction != nil },
                                 set: { if !$0 { pendingInteraction = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = pendingInteraction {
                Button(pending.title) {
                    journal.logInteraction(pending)
                    pendingInteraction = nil
                }
            }
            Button(L("common.cancel", fallback: "Cancel"), role: .cancel) { pendingInteraction = nil }
        } message: {
            Text(String(format: L("cooldown.journal.restart.note",
                                  fallback: "A cooldown is still running (%@). On the community rules, acting now restarts it from the beginning — so logging this will restart the displayed timer. Nothing else changes: Wander still won't stop you teleporting."),
                        timeString(journal.displayedRemaining())))
        }
    }

    @ViewBuilder private var historySection: some View {
        let entries = journal.active.entries
        Section {
            if entries.isEmpty {
                Text(L("cooldown.journal.empty",
                       fallback: "Nothing logged yet. Teleports appear here on their own; use the buttons above for everything else."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    CooldownEntryRow(entry: entry)
                }
                .onDelete { journal.deleteEntries($0) }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Text(L("cooldown.journal.clear", fallback: "Clear history"))
                }
            }
        } header: {
            Text(L("cooldown.journal.history", fallback: "History"))
        } footer: {
            Text(String(format: L("cooldown.journal.retention",
                                  fallback: "Kept on this device only — the last %d entries, up to %d days."),
                        CooldownJournal.maxEntriesPerAccount, CooldownJournal.retentionDays))
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// One line of history. Reads as a sentence — what happened, when, what it cost — rather than a
/// table of fields, because the question being asked of it is always "when am I safe again?".
private struct CooldownEntryRow: View {
    let entry: CooldownEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let path {
                    Text(path)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let cost {
                    Text(cost)
                        .font(.caption2)
                        .foregroundStyle(costTint)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.kind {
        case .teleport: return "arrow.triangle.turn.up.right.diamond.fill"
        case .interaction: return entry.interaction?.symbol ?? "hand.tap.fill"
        }
    }

    /// Orange for an action taken during a running cooldown — the one row a user scanning their
    /// history actually needs to spot.
    private var tint: Color {
        entry.kind == .interaction && entry.remainingAtTime > 0 ? .orange : Wander.brand
    }

    private var title: String {
        switch entry.kind {
        case .interaction:
            return entry.interaction?.title ?? L("cooldown.journal.action", fallback: "Action")
        case .teleport:
            guard let km = entry.distanceKm else {
                return L("cooldown.journal.first", fallback: "Teleported (first spot on this account)")
            }
            return String(format: L("cooldown.journal.jumped", fallback: "Jumped %@ km"), formattedKm(km))
        }
    }

    /// "37.7749, -122.4194 → 40.7580, -73.9855". Coordinates rather than place names: the journal is
    /// written on a teleport, and reverse-geocoding every hop would mean a network call per row.
    private var path: String? {
        guard let to = entry.toCoordinate else { return nil }
        let destination = format(to)
        guard let from = entry.fromCoordinate else { return destination }
        return "\(format(from)) → \(destination)"
    }

    private var cost: String? {
        switch entry.kind {
        case .teleport:
            guard entry.cooldownSeconds > 0 else {
                return L("cooldown.journal.nocost", fallback: "No cooldown")
            }
            return CooldownPreview.shortCost(entry.cooldownSeconds)
                + " " + L("cooldown.preview.noun", fallback: "cooldown")
        case .interaction:
            guard entry.remainingAtTime > 0 else { return nil }
            return String(format: L("cooldown.journal.toosoon",
                                    fallback: "Logged with %@ still on the clock — timer restarted"),
                          timeString(entry.remainingAtTime))
        }
    }

    private var costTint: Color {
        entry.kind == .interaction && entry.remainingAtTime > 0 ? .orange : .secondary
    }

    private func format(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
    }

    private func formattedKm(_ km: Double) -> String {
        km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Rulebook

/// The reference users keep asking for: what actually starts the timer.
///
/// Two things it must get right, and both are stated on the screen itself rather than buried here:
/// teleporting doesn't start the clock (interactions do — the jump only sets the length), and none
/// of this is published by Niantic. Presenting observed rules as official would be the easiest way
/// to make this screen actively harmful.
struct CooldownRulebookView: View {
    var body: some View {
        List {
            Section {
                Text(CooldownRulebook.premise)
                    .font(.footnote)
            } header: {
                Text(L("cooldown.rulebook.premise.header", fallback: "The part people get wrong"))
            }

            ruleSection(L("cooldown.rulebook.starts", fallback: "Starts the timer"),
                        rules: CooldownRulebook.starts,
                        symbol: "exclamationmark.circle.fill",
                        tint: .orange)

            ruleSection(L("cooldown.rulebook.free", fallback: "Doesn't start the timer"),
                        rules: CooldownRulebook.doesNotStart,
                        symbol: "checkmark.circle.fill",
                        tint: .green)

            ruleSection(L("cooldown.rulebook.unclear", fallback: "Reports disagree"),
                        rules: CooldownRulebook.unclear,
                        symbol: "questionmark.circle.fill",
                        tint: .secondary,
                        footer: L("cooldown.rulebook.unclear.footer",
                                  fallback: "Nobody has pinned these down. If you care about the account, treat them as if they count."))

            Section {
                Text(CooldownRulebook.disclaimer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("cooldown.rulebook.where", fallback: "Where these rules come from"))
            }
        }
        .navigationTitle(L("cooldown.rulebook.title", fallback: "What starts the cooldown"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func ruleSection(_ title: String,
                             rules: [CooldownRulebook.Rule],
                             symbol: String,
                             tint: Color,
                             footer: String? = nil) -> some View {
        Section {
            ForEach(rules) { rule in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.footnote)
                        .foregroundStyle(tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.text)
                            .font(.subheadline)
                        if let detail = rule.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

// MARK: - Accounts

/// Naming and switching the local account labels. Deliberately not an account manager: no sign-in,
/// no credentials, nothing leaves the device. It exists because one device runs several game
/// accounts and each of them has its own cooldown to serve.
struct CooldownAccountsView: View {
    @ObservedObject private var journal = CooldownJournal.shared

    @State private var newName = ""

    var body: some View {
        List {
            Section {
                ForEach(journal.accounts) { account in
                    row(for: account)
                }
            } header: {
                Text(L("cooldown.accounts.title", fallback: "Accounts"))
            } footer: {
                Text(L("cooldown.accounts.note",
                       fallback: "Just labels — Wander never signs into anything. Each one keeps its own timer, its own last spot and its own history, and they all keep counting whether or not they're selected."))
            }

            if journal.accounts.count < CooldownJournal.maxAccounts {
                Section {
                    HStack {
                        TextField(L("cooldown.accounts.name", fallback: "Name"), text: $newName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                        Button(L("cooldown.accounts.add", fallback: "Add")) {
                            journal.addAccount(named: newName)
                            newName = ""
                        }
                        .buttonStyle(.borderless)
                        .tint(Wander.brand)
                    }
                } footer: {
                    Text(String(format: L("cooldown.accounts.limit", fallback: "Up to %d."),
                                CooldownJournal.maxAccounts))
                }
            }
        }
        .navigationTitle(L("cooldown.accounts.title", fallback: "Accounts"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for account: CooldownAccount) -> some View {
        // Rename in place: a whole edit screen for a single text field would be more app than this
        // deserves. Committing on submit (not on every keystroke) keeps us off the defaults on typing.
        HStack(spacing: 10) {
            Button {
                journal.selectAccount(account.id)
            } label: {
                Image(systemName: account.id == journal.activeAccountID
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(account.id == journal.activeAccountID ? Wander.brand : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("cooldown.accounts.select", fallback: "Select account"))

            AccountNameField(account: account)

            Spacer()

            // Each account's own countdown, so switching is an informed choice rather than a guess.
            if account.remaining > 0 {
                Text(timeString(account.remaining))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }

            if journal.accounts.count > 1 {
                Button(role: .destructive) {
                    journal.removeAccount(account.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("cooldown.accounts.remove", fallback: "Remove account"))
            }
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A rename field that keeps its own draft. Bound straight to the store it would fight the user's
/// typing, since every keystroke would re-encode and re-publish the whole account list.
private struct AccountNameField: View {
    let account: CooldownAccount

    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        TextField(L("cooldown.accounts.name", fallback: "Name"), text: $draft)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = account.name
            }
            .onSubmit { commit() }
            // Also commit when the row scrolls away or the screen closes, so a typed name isn't lost
            // by tapping Back instead of Return.
            .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != account.name else {
            draft = account.name
            return
        }
        CooldownJournal.shared.renameAccount(account.id, to: trimmed)
    }
}

#Preview {
    CooldownGuardView()
}
