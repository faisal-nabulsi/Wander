//
//  CooldownJournal.swift
//  Wander
//
//  The history + per-account side of the soft-ban cooldown that SimulationSession already runs.
//
//  Three things live here, all of them INFORMATIONAL — nothing in this file blocks, clamps or
//  refuses a teleport, exactly like the countdown chip it feeds.
//
//  That is a constraint on the CALLERS too, and the reason `displayedRemaining()` is named for what
//  it's for. Part of this clock is hand-typed (see `logInteraction`) and none of it is verifiable, so
//  it may drive labels, chips and dimming and nothing else. PoGo mode's opt-in "Block until cooldown
//  ends" — the single place in the app that can refuse a teleport — deliberately reads
//  `SimulationSession.cooldownRemaining` instead: only a cooldown Wander OBSERVED may stop an action.
//
//  The three things:
//
//   1. A journal. Every confirmed teleport is logged (when, from, to, how far, what cooldown it
//      cost) plus the interactions Wander CANNOT observe — spinning a stop, catching something —
//      which the user logs by hand. Those matter because on the community model the wait is
//      measured from your last INTERACTION, and Wander has no hook into the game to see them.
//
//   2. Per-account state. Multi-accounting is the norm for this audience and each account carries
//      its own clock: its own last-teleport point, its own countdown, its own history. Switching
//      accounts only changes which one we're LOOKING at — every other account's end date is a
//      stored wall-clock Date that keeps running whether or not it's on screen.
//
//   3. The "which clock do we show?" answer, since there are now two: SimulationSession's global
//      one (one device, one spoof, no idea which account you're playing) and this per-account one.
//
//  It deliberately owns NO cooldown maths of its own: distances go through PoGoCooldown and the
//  padding/ceiling come from CooldownPreview, which are the same numbers SimulationSession.applyCooldown
//  uses. A second curve that disagreed with the chip would be worse than no journal at all.
//
//  SimulationSession is not modified by any of this — the journal observes `teleportTick` from the
//  outside and keeps its own books.
//

import Foundation
import CoreLocation
import Combine

// MARK: - Entries

/// One thing that happened on the cooldown clock: a jump Wander watched, or an in-game action the
/// user told us about.
///
/// Codable for UserDefaults persistence. Coordinates are stored as plain lat/lng doubles (there's no
/// Codable CLLocationCoordinate2D) and every field added after v1 must decode with a default, or an
/// existing user's history silently disappears on upgrade.
struct CooldownEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// A confirmed teleport, logged automatically.
        case teleport
        /// An in-game action the user logged by hand.
        case interaction
    }

    /// The actions worth logging by hand. These are the ones the community model treats as starting
    /// (or restarting) the clock — see CooldownRulebook for the full list and the caveats.
    enum Interaction: String, Codable, CaseIterable, Identifiable {
        case spin
        case catchPokemon
        case raidOrGym
        case feedGymBerry
        case trade
        case gift

        var id: String { rawValue }

        var title: String {
            switch self {
            case .spin:         return L("cooldown.act.spin", fallback: "Spun a stop / gym")
            case .catchPokemon: return L("cooldown.act.catch", fallback: "Caught something")
            case .raidOrGym:    return L("cooldown.act.raid", fallback: "Raid or gym battle")
            case .feedGymBerry: return L("cooldown.act.berry", fallback: "Fed a berry in a gym")
            case .trade:        return L("cooldown.act.trade", fallback: "Traded")
            case .gift:         return L("cooldown.act.gift", fallback: "Sent / opened a gift")
            }
        }

        var symbol: String {
            switch self {
            case .spin:         return "circle.hexagongrid.fill"
            case .catchPokemon: return "hand.raised.fill"
            case .raidOrGym:    return "shield.lefthalf.filled"
            case .feedGymBerry: return "leaf.fill"
            case .trade:        return "arrow.left.arrow.right"
            case .gift:         return "gift.fill"
            }
        }
    }

    var id: UUID = UUID()
    var date: Date
    var kind: Kind
    /// Set only on `.interaction` rows.
    var interaction: Interaction?

    /// Where the jump started (nil on the very first teleport an account ever makes — there's
    /// nothing to measure from — and on interactions, which don't move anywhere).
    var fromLat: Double?
    var fromLng: Double?
    var toLat: Double?
    var toLng: Double?
    /// Great-circle distance of the jump, km. nil when there was no origin to measure from.
    var distanceKm: Double?
    /// The cooldown this event produced, in seconds. 0 for interactions (an interaction has no
    /// distance of its own, so it can't produce a duration — it can only restart one, below).
    var cooldownSeconds: TimeInterval = 0
    /// How much was still on the clock the moment this happened. The interesting field on an
    /// interaction row: a non-zero value means the user acted DURING a cooldown, which is precisely
    /// the mistake the timer exists to prevent, and is worth showing back to them.
    var remainingAtTime: TimeInterval = 0

    var fromCoordinate: CLLocationCoordinate2D? {
        guard let fromLat, let fromLng else { return nil }
        return CLLocationCoordinate2D(latitude: fromLat, longitude: fromLng)
    }

    var toCoordinate: CLLocationCoordinate2D? {
        guard let toLat, let toLng else { return nil }
        return CLLocationCoordinate2D(latitude: toLat, longitude: toLng)
    }
}

// MARK: - Accounts

/// A local label for one of the user's game accounts, plus everything that account's clock needs.
///
/// There are no credentials here and there never will be: Wander doesn't sign into anything, so an
/// "account" is a name the user typed and a bucket to keep that account's cooldown state in.
struct CooldownAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var entries: [CooldownEntry] = []

    /// Wall-clock end of THIS account's cooldown (nil = clear). Stored as a Date rather than a
    /// remaining-seconds number so an account that isn't selected — and therefore isn't being
    /// ticked by anything — still has an honest countdown the moment you switch back to it.
    var cooldownEndsAt: Date?
    /// Full length of the cooldown currently running, kept so a mid-cooldown interaction can restart
    /// it at its original duration instead of guessing a new one.
    var cooldownSeconds: TimeInterval = 0

    /// Where this account was last teleported to — the origin the NEXT jump is measured from. This
    /// is why per-account timers aren't cosmetic: account A's last point is usually nowhere near
    /// account B's, so the same tap costs them different waits.
    var lastLat: Double?
    var lastLng: Double?

    var lastCoordinate: CLLocationCoordinate2D? {
        guard let lastLat, let lastLng else { return nil }
        return CLLocationCoordinate2D(latitude: lastLat, longitude: lastLng)
    }

    /// Seconds left on this account's own clock, right now.
    var remaining: TimeInterval {
        guard let cooldownEndsAt else { return 0 }
        return max(0, cooldownEndsAt.timeIntervalSinceNow)
    }
}

// MARK: - Store

@MainActor
final class CooldownJournal: ObservableObject {
    static let shared = CooldownJournal()

    /// Named accounts, always at least one. The cap is a UI decision, not a technical one: past a
    /// handful of names a picker stops being a picker, and this is meant to stay a label switcher
    /// rather than grow into an account manager.
    static let maxAccounts = 6

    /// How much history we keep per account. Both limits apply (whichever bites first): the count cap
    /// keeps a heavy multi-jump day from growing the defaults blob without bound, and the age cap
    /// stops a light user's list from showing months-old entries nobody will ever scroll to.
    static let maxEntriesPerAccount = 200
    static let retentionDays = 30

    /// A jump shorter than this is the same re-assert `SimulationSession.applyCooldown` deliberately
    /// ignores (re-pressing Simulate on the pin you're already standing on). Logging those would fill
    /// the journal with 12-metre "teleports" that never cost anything.
    private static let minLoggableMeters: Double = 50

    @Published private(set) var accounts: [CooldownAccount]
    @Published private(set) var activeAccountID: UUID

    /// Ticked once a second while the active account's own clock is running, purely so views that
    /// read `remaining` re-render. SimulationSession publishes its own countdown, but this journal's
    /// clock can outlive it (a mid-cooldown interaction restarts ours, not theirs), and nothing else
    /// would tell SwiftUI to redraw.
    @Published private(set) var clockTick = Date()

    /// Which account the cooldown currently running on SimulationSession belongs to. Needed because
    /// there is exactly ONE global timer for a device that may be playing several accounts: after a
    /// switch, that timer is somebody else's and must not be shown as this account's wait.
    /// nil means "unattributed" (nothing logged yet) and is treated as belonging to whoever is
    /// selected — the safe default, since it can only ever err towards showing a real global timer.
    private var globalCooldownOwnerID: UUID?

    /// Last `SimulationSession.teleportTick` we absorbed. In-memory only: the tick resets to 0 on
    /// launch, so a persisted value would make the first teleport of a session look already-logged.
    private var lastSeenTeleportTick: Int

    /// The tick whose cooldown this journal has computed per-account itself. nil until we absorb a
    /// teleport — deliberately NOT persisted, so a fresh launch always falls back to trusting the
    /// global timer (see `displayedRemaining`). An install that lands mid-cooldown has no per-account
    /// figure to fall back on, and hiding the restored global one would be the worst possible answer.
    private var mirroredTick: Int?

    /// True while the last logged interaction can still be taken back. Published so the journal
    /// screen can offer the undo without polling for it.
    @Published private(set) var canUndoInteraction = false

    /// Enough to put a clock back exactly as it was before the last logged interaction.
    ///
    /// In memory only, and only ever one deep: this is a "that tap was a mistake" affordance for the
    /// seconds after the tap, not a history feature. A stale one restored after a relaunch would be
    /// reinstating a clock that real teleports have since overwritten.
    private struct InteractionUndo {
        let accountID: UUID
        let entryID: UUID
        let previousEndsAt: Date?
        let previousSeconds: TimeInterval
    }

    private var pendingUndo: InteractionUndo?

    private var clockTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private static let storeKey = "cooldown.journal.v1"

    private init() {
        let stored = Self.load()
        accounts = stored.accounts
        activeAccountID = stored.activeAccountID
        globalCooldownOwnerID = stored.globalCooldownOwnerID
        lastSeenTeleportTick = SimulationSession.shared.teleportTick

        pruneAll()

        // Watch teleports from the OUTSIDE rather than having SimulationSession call us: that file is
        // on the untouchable spoof path, and an observer costs it nothing.
        //
        // The Task hop is load-bearing. @Published fires on willSet, i.e. BEFORE `noteTeleport` has
        // finished setting `lastTeleportCoordinate` and starting the cooldown, so reading the session
        // synchronously here would log the previous jump's numbers. Hopping to a fresh main-actor turn
        // means we read the session only once it has finished writing itself.
        SimulationSession.shared.$teleportTick
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncPendingTeleport() }
            }
            .store(in: &cancellables)

        startClockIfNeeded()
    }

    // MARK: Active account

    var active: CooldownAccount {
        accounts.first { $0.id == activeAccountID } ?? accounts[0]
    }

    /// Switch which account we're looking at. Deliberately does NOTHING to any account's stored
    /// `cooldownEndsAt` — the whole point of per-account timers is that the one you just walked away
    /// from keeps counting.
    func selectAccount(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }), id != activeAccountID else { return }
        activeAccountID = id
        clearUndo()
        persist()
        startClockIfNeeded()
    }

    func addAccount(named name: String) {
        guard accounts.count < Self.maxAccounts else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = CooldownAccount(name: trimmed.isEmpty ? defaultAccountName() : trimmed)
        accounts.append(account)
        persist()
    }

    func renameAccount(_ id: UUID, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        accounts[index].name = trimmed
        persist()
    }

    /// Remove an account and its history. Refuses to remove the last one — with zero accounts there'd
    /// be nowhere to log the next teleport, and the picker would have nothing to select.
    func removeAccount(_ id: UUID) {
        guard accounts.count > 1, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: index)
        if activeAccountID == id { activeAccountID = accounts[0].id }
        if globalCooldownOwnerID == id { globalCooldownOwnerID = nil }
        if pendingUndo?.accountID == id { clearUndo() }
        persist()
        startClockIfNeeded()
    }

    private func defaultAccountName() -> String {
        String(format: L("cooldown.account.default", fallback: "Account %d"), accounts.count + 1)
    }

    // MARK: Which clock to show

    /// Seconds left on the SELECTED account's own clock.
    var activeRemaining: TimeInterval { active.remaining }

    /// The number the UI should actually put on screen, reconciling the two clocks that now exist.
    ///
    /// The default is the LONGER of the two, because guidance here is a floor: where they disagree
    /// for a reason we can't account for, showing the shorter one is the answer that gets someone
    /// soft-banned. The global timer drops out of the comparison in exactly two cases:
    ///
    ///  - it belongs to another account. Account A's two-hour wait shown on account B, which never
    ///    left the neighbourhood, isn't caution — it's a wrong number.
    ///  - we already computed this very teleport ourselves. The global figure is measured from
    ///    wherever the DEVICE last was, which after an account switch is another account's spot; our
    ///    per-account figure is measured from where THIS account actually stood, so it's simply the
    ///    better number, not a more optimistic one.
    ///
    /// Anything else — including the first launch after installing this feature mid-cooldown — falls
    /// through to the max, which is the safe direction to be wrong in.
    func displayedRemaining() -> TimeInterval {
        let session = SimulationSession.shared
        let ownedByAnotherAccount = globalCooldownOwnerID != nil && globalCooldownOwnerID != activeAccountID
        let alreadyMirrored = mirroredTick == session.teleportTick
        let globalCounts = !ownedByAnotherAccount && !alreadyMirrored && session.cooldownActive
        return max(activeRemaining, globalCounts ? session.cooldownRemaining : 0)
    }

    // MARK: Logging

    /// Absorb a teleport that SimulationSession has just confirmed. Idempotent by tick, so it's safe
    /// to call from a view's `onAppear` as well as from the observer — whichever gets there first
    /// logs it, the other returns immediately.
    func syncPendingTeleport() {
        let session = SimulationSession.shared
        let tick = session.teleportTick
        guard tick != lastSeenTeleportTick else { return }
        lastSeenTeleportTick = tick
        guard let destination = session.lastTeleportCoordinate else { return }

        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        let origin = accounts[index].lastCoordinate
        // Read the leftover from THIS account's stored clock, not `displayedRemaining()`: by the time
        // we run, SimulationSession has already replaced its countdown with the new jump's, so the
        // global figure is no longer "what was left before this teleport".
        let remainingBefore = accounts[index].remaining

        // This teleport is now the global timer's owner: whatever SimulationSession is counting down
        // was started by this account's jump, and we're about to compute our own per-account figure
        // for the same jump.
        globalCooldownOwnerID = activeAccountID
        mirroredTick = tick
        // A real jump has just rewritten this account's clock, so the interaction undo no longer has
        // anything coherent to restore.
        clearUndo()

        var km: Double?
        var seconds: TimeInterval = 0
        if let origin {
            let distance = PoGoCooldown.distanceKm(from: origin, to: destination)
            km = distance

            // Same re-assert rule as applyCooldown: a near-in-place push is not a move. Record the
            // (unchanged) point and leave both the running cooldown and the history alone.
            if distance * 1000 < Self.minLoggableMeters {
                accounts[index].lastLat = destination.latitude
                accounts[index].lastLng = destination.longitude
                persist()
                return
            }

            if Self.presetUsesCooldown {
                seconds = min(PoGoCooldown.seconds(forKm: distance) * CooldownPreview.buffer,
                              CooldownPreview.capSeconds)
            }
        }

        accounts[index].lastLat = destination.latitude
        accounts[index].lastLng = destination.longitude
        if seconds > 0 {
            accounts[index].cooldownEndsAt = Date().addingTimeInterval(seconds)
            accounts[index].cooldownSeconds = seconds
        } else {
            // Mirrors clearCooldown(): no measurable jump (or a game preset with no distance
            // cooldown) leaves nothing to wait for.
            accounts[index].cooldownEndsAt = nil
            accounts[index].cooldownSeconds = 0
        }

        let entry = CooldownEntry(
            date: Date(),
            kind: .teleport,
            fromLat: origin?.latitude,
            fromLng: origin?.longitude,
            toLat: destination.latitude,
            toLng: destination.longitude,
            distanceKm: km,
            cooldownSeconds: seconds,
            remainingAtTime: remainingBefore
        )
        insert(entry, at: index)
        startClockIfNeeded()
    }

    /// Log an in-game action Wander can't see.
    ///
    /// An interaction carries no distance, so it can't invent a cooldown length of its own — that
    /// only arrives with the next jump. What it DOES do, on the community model, is re-anchor the
    /// clock: acting while a cooldown is still running restarts that cooldown from now, at its
    /// original length. So this restarts a running timer and otherwise just records the action.
    ///
    /// It changes a DISPLAYED timer and nothing else. The number this moves is hand-typed and
    /// unverifiable, so no caller may let it refuse a teleport — see the file header. A single tap
    /// gets it wrong often enough that the last one is always undoable (`undoLastInteraction`).
    func logInteraction(_ interaction: CooldownEntry.Interaction) {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        // Before reading `cooldownSeconds`: a clock that ran out on its own leaves that field behind,
        // and restarting at an expired jump's length is how a 4-minute wait becomes a 2-hour one.
        // No persist() needed here — `insert` below writes the store on every path out of this method.
        expireElapsedClocks()

        let remainingBefore = displayedRemaining()
        let coordinate = accounts[index].lastCoordinate ?? SimulationSession.shared.lastTeleportCoordinate
        let previousEndsAt = accounts[index].cooldownEndsAt
        let previousSeconds = accounts[index].cooldownSeconds

        if accounts[index].remaining > 0 {
            // This account's own clock is running, so `cooldownSeconds` is that clock's length —
            // restart at it. (Guarded on the account's own remainder, not the displayed one: the
            // displayed figure can be the GLOBAL clock's, which says nothing about how long THIS
            // account's stored length was measured for.)
            let length = accounts[index].cooldownSeconds > 0
                ? accounts[index].cooldownSeconds
                : accounts[index].remaining
            accounts[index].cooldownEndsAt = Date().addingTimeInterval(length)
            accounts[index].cooldownSeconds = length
        } else if remainingBefore > 0 {
            // Only the global clock is running (a fresh launch, or an account that hasn't jumped
            // yet). Its remainder is the only duration we know about, so it becomes this account's —
            // the alternative is quietly losing the wait on restart.
            accounts[index].cooldownEndsAt = Date().addingTimeInterval(remainingBefore)
            accounts[index].cooldownSeconds = remainingBefore
        }

        let entry = CooldownEntry(
            date: Date(),
            kind: .interaction,
            interaction: interaction,
            toLat: coordinate?.latitude,
            toLng: coordinate?.longitude,
            remainingAtTime: remainingBefore
        )
        pendingUndo = InteractionUndo(accountID: accounts[index].id,
                                      entryID: entry.id,
                                      previousEndsAt: previousEndsAt,
                                      previousSeconds: previousSeconds)
        canUndoInteraction = true
        insert(entry, at: index)
        startClockIfNeeded()
    }

    /// Take back the last logged interaction — the entry AND the clock it restarted.
    ///
    /// These are six full-width rows that fire on one tap and can add up to two hours to a displayed
    /// wait, and deleting the history row afterwards only tidies the list. Without this, a mis-tap is
    /// unfixable except by waiting it out or teleporting again, so the restart has to be reversible.
    func undoLastInteraction() {
        guard let undo = pendingUndo,
              let index = accounts.firstIndex(where: { $0.id == undo.accountID }) else { return }
        accounts[index].entries.removeAll { $0.id == undo.entryID }
        accounts[index].cooldownEndsAt = undo.previousEndsAt
        accounts[index].cooldownSeconds = undo.previousSeconds
        clearUndo()
        persist()
        startClockIfNeeded()
    }

    /// Forget the offer. Anything that moves a clock for a REAL reason (a confirmed teleport, a
    /// switch to another account) invalidates it: undoing then would restore a clock that no longer
    /// describes anything.
    private func clearUndo() {
        pendingUndo = nil
        canUndoInteraction = false
    }

    func deleteEntries(_ offsets: IndexSet) {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        accounts[index].entries.remove(atOffsets: offsets)
        persist()
    }

    /// Clears the SELECTED account's history only. The running timer survives on purpose: tidying a
    /// list is not the same as claiming the wait is over.
    func clearHistory() {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        accounts[index].entries.removeAll()
        persist()
    }

    /// Newest first, then pruned — so the cap always throws away the OLDEST entries.
    private func insert(_ entry: CooldownEntry, at index: Int) {
        accounts[index].entries.insert(entry, at: 0)
        prune(&accounts[index])
        persist()
    }

    // MARK: Pruning + persistence

    /// Launch-time sweep. Only writes when something actually aged out — a launch that changes
    /// nothing shouldn't re-encode the whole store.
    private func pruneAll() {
        var changed = expireElapsedClocks()
        for index in accounts.indices {
            let before = accounts[index].entries.count
            prune(&accounts[index])
            if accounts[index].entries.count != before { changed = true }
        }
        if changed { persist() }
    }

    /// Retire per-account clocks that have run out.
    ///
    /// `cooldownEndsAt` needs no help — `remaining` already reads 0 past it. `cooldownSeconds` does:
    /// it's a RESTART LENGTH, nothing ticks it, and it outlives the clock it described. Left behind,
    /// an interaction logged long after a 900 km jump would restart at that jump's two hours instead
    /// of at whatever is actually running. Returns whether anything changed so callers can decide
    /// about persisting rather than re-encoding the store on every tick.
    @discardableResult
    private func expireElapsedClocks() -> Bool {
        var changed = false
        for index in accounts.indices
        where accounts[index].cooldownEndsAt != nil && accounts[index].remaining <= 0 {
            accounts[index].cooldownEndsAt = nil
            accounts[index].cooldownSeconds = 0
            changed = true
        }
        return changed
    }

    private func prune(_ account: inout CooldownAccount) {
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        account.entries = account.entries.filter { $0.date >= cutoff }
        if account.entries.count > Self.maxEntriesPerAccount {
            account.entries = Array(account.entries.prefix(Self.maxEntriesPerAccount))
        }
    }

    /// Everything persisted, in one blob. One key keeps accounts and their histories atomically in
    /// sync — a half-written switch (new active id, old accounts) would attribute entries to the
    /// wrong account after a crash.
    private struct Stored: Codable {
        var accounts: [CooldownAccount]
        var activeAccountID: UUID
        var globalCooldownOwnerID: UUID?
    }

    private func persist() {
        let stored = Stored(accounts: accounts,
                            activeAccountID: activeAccountID,
                            globalCooldownOwnerID: globalCooldownOwnerID)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }

    private static func load() -> Stored {
        let fallback = CooldownAccount(name: L("cooldown.account.first", fallback: "Main"))
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              !stored.accounts.isEmpty else {
            return Stored(accounts: [fallback], activeAccountID: fallback.id, globalCooldownOwnerID: nil)
        }
        // A stored active id that no longer matches any account (hand-edited defaults, a failed
        // migration) would make `active` fall back on every read — pin it to a real account instead.
        if !stored.accounts.contains(where: { $0.id == stored.activeAccountID }) {
            return Stored(accounts: stored.accounts,
                          activeAccountID: stored.accounts[0].id,
                          globalCooldownOwnerID: stored.globalCooldownOwnerID)
        }
        return stored
    }

    // MARK: Clock

    /// Run a 1 s ticker while ANY account has its own clock running — not just the selected one.
    ///
    /// The accounts screen exists precisely to compare accounts, and it renders every account's
    /// countdown; gating the ticker on the selected account froze all the other rows at whatever
    /// value they held when the list last redrew. When no per-account clock is running at all, the
    /// only countdown on screen is SimulationSession's, whose own published tick already drives the
    /// UI — a second timer there would just be redundant wakeups.
    private func startClockIfNeeded() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard accounts.contains(where: { $0.remaining > 0 }) else { return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        clockTick = Date()
        // Retire lengths as their clocks run out, so a later interaction can't restart at one of
        // them. Only persists on the tick where something actually expired.
        if expireElapsedClocks() { persist() }
        if !accounts.contains(where: { $0.remaining > 0 }) {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    /// The selected game preset, read the same way `SimulationSession.applyCooldown` and
    /// `CooldownPreview.status` read it (UserDefaults, not @AppStorage) since the journal is written
    /// to from non-PoGo screens too.
    private static var presetUsesCooldown: Bool {
        let preset = GamePreset(rawValue: UserDefaults.standard.string(forKey: "pogoGamePreset") ?? "")
            ?? .pokemonGo
        return preset.usesTeleportCooldown
    }
}

// MARK: - Rulebook content

/// What does and doesn't start the cooldown, as the community has worked it out.
///
/// Kept as data next to the journal (rather than inline in the view) because the honesty caveats
/// travel with it: these rules are OBSERVED — Niantic has never published a cooldown table — and the
/// "unclear" tier exists so we don't launder a disputed rule into a confident one.
enum CooldownRulebook {
    struct Rule: Identifiable {
        let id = UUID()
        let text: String
        /// The bit players most often get wrong, spelled out. nil when the line speaks for itself.
        let detail: String?

        init(_ text: String, detail: String? = nil) {
            self.text = text
            self.detail = detail
        }
    }

    /// The headline correction: people blame the teleport, then wait out a timer while doing the one
    /// thing that restarts it.
    static let premise = L(
        "cooldown.rulebook.premise",
        fallback: "Teleporting does not start the timer — interacting does. A jump only decides how LONG the wait is; the clock runs from your last in-game action. Move as much as you like, then wait before you touch anything."
    )

    static let starts: [Rule] = [
        Rule(L("cooldown.rule.spin", fallback: "Spinning a PokéStop or gym photo disc")),
        Rule(L("cooldown.rule.catch", fallback: "Catching a Pokémon"),
             detail: L("cooldown.rule.catch.detail", fallback: "Counts even if it flees or breaks out.")),
        Rule(L("cooldown.rule.raid", fallback: "Raid battles, gym battles, and placing a Pokémon in a gym")),
        Rule(L("cooldown.rule.berry", fallback: "Feeding a berry to a Pokémon defending a gym"),
             detail: L("cooldown.rule.berry.detail", fallback: "This is a map interaction — different from feeding your buddy, below.")),
        Rule(L("cooldown.rule.trade", fallback: "Trading with another trainer")),
        Rule(L("cooldown.rule.during", fallback: "Doing any of the above while a cooldown is already running"),
             detail: L("cooldown.rule.during.detail", fallback: "Widely reported to restart the wait from zero. Wander restarts your timer when you log one of these too.")),
    ]

    static let doesNotStart: [Rule] = [
        Rule(L("cooldown.rule.teleport", fallback: "Teleporting, walking, or running a route"),
             detail: L("cooldown.rule.teleport.detail", fallback: "Moving is free. It's what you do when you arrive that costs you.")),
        Rule(L("cooldown.rule.buddy", fallback: "Feeding your buddy, or swapping buddies")),
        Rule(L("cooldown.rule.store", fallback: "The web store, and buying items in the in-game shop")),
        Rule(L("cooldown.rule.collection", fallback: "Evolving, powering up, transferring, and renaming")),
        Rule(L("cooldown.rule.eggs", fallback: "Hatching eggs and using incubators")),
        Rule(L("cooldown.rule.items", fallback: "Incense, lucky eggs, star pieces, and lure modules")),
        Rule(L("cooldown.rule.browse", fallback: "Browsing — Pokédex, journal, nearby, your storage")),
    ]

    static let unclear: [Rule] = [
        Rule(L("cooldown.rule.gift", fallback: "Sending and opening gifts"),
             detail: L("cooldown.rule.gift.detail", fallback: "Gifts come from stops, and reports split on whether they count. Treat them as if they do.")),
        Rule(L("cooldown.rule.snapshot", fallback: "Snapshots of wild Pokémon")),
        Rule(L("cooldown.rule.research", fallback: "Claiming field research rewards"),
             detail: L("cooldown.rule.research.detail", fallback: "The reward itself looks free; the stop spin that gave you the task is not.")),
    ]

    /// Printed at the top of the rulebook, and worth repeating anywhere these rules are quoted.
    static let disclaimer = L(
        "cooldown.rulebook.disclaimer",
        fallback: "Niantic has never published any of this. Every rule below is community-observed — worked out by players comparing notes, and liable to change without warning when the game does. Wander shows it as guidance, never as a guarantee, and never stops you doing anything."
    )
}
