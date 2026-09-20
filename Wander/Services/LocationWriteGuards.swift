//
//  LocationWriteGuards.swift
//  Wander
//
//  The two invariants that stand between "disconnect the tunnel once nothing is spoofing" and the
//  regression this app has already shipped twice (build 84's probe-triggered cleanup, build 124's
//  orphaned sessions):
//
//    1. NOTHING MAY STOP THE TUNNEL WHILE LOCATION WORK IS IN FLIGHT OR AN FFI SESSION HANDLE IS
//       OPEN.  `LocationSessionActivity` answers that question from ACTUAL write/clear history
//       rather than from `SimulationSession.isActive`, which is a much weaker signal (see below).
//    2. ANY WRITER THAT IS ABOUT TO TOUCH THE DEVICE CANCELS A PENDING DISCONNECT FIRST, BEFORE THE
//       FFI IS ENQUEUED.  `LocationSimulationCommandQueue.submit` is the one choke point that makes
//       that structural instead of a rule nine call sites have to remember.
//
//  WHY NOT `SimulationSession.isActive`. It is set true only in each mode's SUCCESS handler, AFTER
//  the FFI returns — so during a teleport it reads FALSE for the entire duration of a DVT rebuild,
//  and that rebuild has no timeout. It is also set false by `markStopped()` without broadcasting
//  `.stopSimulationRequested`, so other writers can still be injecting while it reads false. It is
//  kept as an ADDITIONAL guard everywhere it was used; it is no longer the last line of defence.
//

import Foundation

// MARK: - Is anything actually writing / is a session handle open?

/// Tracks whether the app can still be holding an open location-simulation session, and whether any
/// location FFI work is in flight, WITHOUT reading `SimulationSession.isActive`.
///
/// HOW "IS A HANDLE OPEN?" IS ANSWERED. The definitive flag is `LocationSimulationState.liveTarget`
/// inside `IdeviceFFIBridge.swift`, which is `private` to that file (and that file is owned by
/// another change right now), so it cannot be read from here. The equivalent is derived from two
/// public facts about that same state machine:
///
///   * `TunnelInjectStatus` records EVERY call to `simulate_location` — success or failure, from
///     every mode — with a timestamp. An inject is the only thing that can OPEN a session.
///   * `clear_simulated_location()` USUALLY gives up its session — freed by `cleanup()` on the
///     ordinary paths, and merely DROPPED (references released without freeing, because a detached
///     FFI thread may still hold them) on the stalled one. `noteSessionClosed()` is called at each of
///     its call sites, on the location queue, immediately after it returns.
///
///     ⚠️ IT IS NO LONGER UNCONDITIONAL, and `noteSessionClosed()` checks rather than assumes. Two
///     paths KEEP the session on purpose: `clearDeferred` (a write is still out on the FFI thread, so
///     the clear is OWED and will ride this same handle the moment it comes back) and the first
///     `clearFailed` (an FFI error is not proof the channel is dead, and on cellular no replacement
///     session could ever be born, so the handle is kept for one retry). Recording a close on those
///     would tell the tunnel auto-disconnect that nothing holds a session, and it would pull the
///     transport out from under the handle that is about to carry the user's stop.
///
/// So "a handle may be open" is exactly "an inject was recorded after the last clear returned".
/// Evaluated ON the serial `LocationSimulationCommandQueue`, that is a causal ordering test, not a
/// time window: every earlier inject and clear has already run and recorded by the time we look.
/// (It is not a CLOCK test either — the two sides are compared by identity, not by which stamp is
/// larger. See `_lastWriteAtSessionClose`.)
///
/// THIS IS WHAT MAKES `SimulationSession.markStopped()` SAFE TO ARM FROM. That stop does not
/// broadcast, so the movement modes keep injecting through it; those injects push the recorded last
/// write past the stop's clear, this reads "may be open", and the tunnel stays up. Weakening the
/// test below would re-open the hole that arm was blocked on.
///
/// FAILS SAFE IN ONE DIRECTION ONLY. Every uncertainty (an inject that failed, a late write outcome,
/// a gs-loc push, no clear ever seen) reports "may be open", i.e. "leave the tunnel up". Leaving a
/// tunnel connected costs the user a VPN slot; tearing it down under a live session costs them their
/// spoof.
///
/// ⚠️ ONE DEPENDENCY WORTH KNOWING. `TunnelHealthMonitor.startMonitoring()` calls
/// `TunnelInjectStatus.reset()`, which nils those timestamps. That is only ever reached from
/// `SimulationSession.started()`, which calls `WanderTunnel.cancelAutoDisconnect()` BEFORE it — and
/// every write cancels too (see `submit` below) — so no pending disconnect can survive to read the
/// wiped history. If `reset()` ever gains another caller, re-check that ordering.
enum LocationSessionActivity {
    private static let lock = NSLock()
    private static var _inFlight = 0

    /// The inject timestamp that was the most recent one at the moment the last clear returned — NOT
    /// the time of that clear.
    ///
    /// WHY NOT THE TIME. The old form of this recorded `Date()` at close and asked "was the last
    /// inject at or after it?". Both sides are wall-clock — the inject side is stamped inside
    /// `TunnelInjectStatus.record`, which this file cannot change — and wall-clock time can step
    /// BACKWARD (NTP correction, the user changing the clock, a timezone-adjacent settings write).
    /// One backward step and an inject that genuinely happened after the clear compares as earlier,
    /// which flips the answer to "no handle open" — the UNSAFE side, i.e. stop the tunnel under a
    /// live session.
    ///
    /// Storing the VALUE instead turns the ordering test into an equality test: "has any new inject
    /// been recorded since the last clear returned?". Two Dates are equal or they are not, and no
    /// clock adjustment can make a fresh inject's stamp equal to the one we filed at close (they are
    /// distinct FFI calls, serialized on the location queue, milliseconds apart). Correct on a
    /// steady clock, and on a stepped one it fails toward "leave the tunnel up".
    private static var _lastWriteAtSessionClose: Date?

    /// A location command has been handed to the serial queue but has not finished. Counted from
    /// ENQUEUE (not from the block starting) so work still waiting its turn counts as in flight.
    static func beginWrite() {
        lock.lock(); _inFlight += 1; lock.unlock()
    }

    static func endWrite() {
        lock.lock(); _inFlight = max(0, _inFlight - 1); lock.unlock()
    }

    /// True while any location command is queued or running.
    static var isWriteInFlight: Bool {
        lock.lock(); defer { lock.unlock() }
        return _inFlight > 0
    }

    /// Call IMMEDIATELY after `clear_simulated_location()` returns, on the location queue.
    ///
    /// It used to be safe to assume that meant the handle was gone. It is not any more — see the
    /// second bullet in this file's header — so the assumption is now a CHECK. `isSessionHeld` is the
    /// read-only window onto the same `liveTarget` the FFI state machine sets and clears with the
    /// session, so this asks the definitive fact rather than inferring it.
    static func noteSessionClosed() {
        guard !LocationSessionProbeState.isSessionHeld else {
            // A deliberate keep: the clear is owed, or is one retry away. Nothing closed.
            return
        }
        // Read on the location queue, where every inject that preceded this clear has already
        // recorded itself — so this is "the newest inject the closed session could have been".
        // Taken BEFORE our lock: it acquires `TunnelInjectStatus`'s, and nesting two locks is worth
        // avoiding even when (as here) nothing takes them in the other order.
        let writeAtClose = Self.lastRecordedWrite
        lock.lock(); _lastWriteAtSessionClose = writeAtClose; lock.unlock()
    }

    /// Newest recorded inject of either outcome, or nil if nothing has ever injected in this process.
    private static var lastRecordedWrite: Date? {
        let snapshot = TunnelInjectStatus.snapshot
        return [snapshot.lastSuccessAt, snapshot.lastFailureAt].compactMap { $0 }.max()
    }

    /// True unless we can PROVE no location-simulation session handle is open.
    ///
    /// Read this on `LocationSimulationCommandQueue.shared` so the comparison is against a settled
    /// state: on that queue, every previously enqueued inject and clear has already recorded itself.
    static var mayHoldOpenSession: Bool {
        // Nothing has ever injected in this process, so there is nothing to hold. (Handles cannot
        // outlive the process — they die with it, which is the whole reason a spoof does too.)
        guard let lastWrite = lastRecordedWrite else { return false }
        lock.lock(); let writeAtClose = _lastWriteAtSessionClose; lock.unlock()
        // An inject with no clear ever recorded behind it (or a clear that ran before anything had
        // ever injected): assume the handle is still open.
        guard let writeAtClose else { return true }
        // Unchanged ⇒ no inject since that clear returned ⇒ nothing can be holding a handle. Any
        // other value means a NEW inject landed after it. No clock comparison — see the field.
        return lastWrite != writeAtClose
    }
}

// MARK: - The one enqueue choke point for location writes

extension LocationSimulationCommandQueue {
    /// Enqueue one location-simulation command on the serial queue.
    ///
    /// Identical to `shared.async { … }` apart from two pieces of bookkeeping that have to happen in
    /// this order, which is why every writer goes through here instead:
    ///
    ///   1. CANCEL A PENDING TUNNEL AUTO-DISCONNECT FIRST, SYNCHRONOUSLY, BEFORE THE WORK IS
    ///      ENQUEUED. This is what makes "the grace timer fired while a teleport's DVT rebuild was
    ///      in flight" impossible rather than unlikely: the cancellation token is bumped before the
    ///      FFI is even queued, so a disconnect already counting down (or already draining the queue
    ///      on its way to firing) is dead by the time this command runs. Cancelling on every write —
    ///      not just on the "start" paths — is deliberate: a writer is a writer, and there is no
    ///      list of start paths to keep in sync.
    ///   2. Count the command as in flight until its block returns, so the disconnect's fire-time
    ///      guard can see queued work rather than inferring idleness.
    ///
    /// Thread-safe from any queue: `cancelAutoDisconnect()` is lock-guarded.
    ///
    /// USE `submitClear` INSTEAD FOR A CLEAR — see below.
    static func submit(_ work: @escaping () -> Void) {
        WanderTunnel.shared.cancelAutoDisconnect()
        submitClear(work)
    }

    /// Enqueue a command that CLOSES a session rather than opening one — i.e. a clear.
    ///
    /// Identical to `submit` except that it does NOT cancel a pending auto-disconnect, and that
    /// difference is load-bearing rather than cosmetic. A stop schedules the disconnect and enqueues
    /// a clear; several stop paths then echo (`stopAll()` broadcasts, `ItineraryRunner` hears it and
    /// calls `stopAll()` again), and each echo enqueues another clear. If a clear cancelled, the
    /// echo of a stop would disarm the disconnect that stop had just scheduled — the feature would
    /// work or not depending on which mode happened to be running.
    ///
    /// A clear still counts as in-flight work, so the disconnect can never land between a clear
    /// being queued and the FFI having finished with it.
    static func submitClear(_ work: @escaping () -> Void) {
        LocationSessionActivity.beginWrite()
        shared.async {
            defer { LocationSessionActivity.endWrite() }
            work()
        }
    }
}

// MARK: - Bring our own tunnel up before a start path writes

/// The "make sure Wander's own tunnel is up before this mode starts writing" gate.
///
/// Exists because the auto-disconnect can legitimately drop the tunnel between sessions, and only
/// two paths in the app ever brought it back (`MapSelectionView.performSimulate` and
/// `TunnelHealthMonitor`'s reconnect). Every other start path wrote straight into a tunnel that may
/// no longer be there — the joystick, the route drive, an itinerary, a scheduled window.
///
/// Costs NOTHING for the default install: when the user hasn't opted into Wander's own tunnel (or
/// gs-loc owns the VPN slot) `body` runs synchronously, with no task, no await and no suspension —
/// byte-for-byte the previous behaviour.
enum TunnelStartGate {
    /// True only when Wander is the one responsible for the tunnel. Mirrors the first two guards
    /// inside `WanderTunnel.ensureStarted()`, so this can never ask for a start that would be
    /// vetoed anyway.
    static var isNeeded: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel) && !GslocMode.enabled
    }

    /// Run `body` once our tunnel is up (or immediately, when we don't own one).
    ///
    /// `ensureStarted()` keeps all of its own guards — a foreign VPN, gs-loc, an already-reachable
    /// loopback each veto the start — and its result is deliberately ignored: a mode that couldn't
    /// get a tunnel still runs and still surfaces its own error, exactly as it did before.
    ///
    /// ⚠️ A STOP DURING THE BRING-UP WINS. `ensureStarted()` can take up to 12 seconds, and without
    /// the epoch check below a global Stop or Panic landing inside that window would stand every mode
    /// down and THEN have `body` start one anyway — beginning a run the user just cancelled, and
    /// re-claiming the transport they just asked to release. `SimulationSession.stopGeneration` is
    /// bumped by both `markStopped()` and `stopAll()`, so comparing it across the await is the same
    /// signal every other cancellation path in the app already uses.
    ///
    /// The check is skipped entirely on the synchronous path — with no suspension there is no window
    /// for a stop to land in, and reading the epoch there would only add a way to be wrong.
    ///
    /// `cleanup` runs on BOTH outcomes and always before `body`. It exists because callers latch a
    /// "start in progress" flag before handing off here (see `WalkModeView.isStarting`) and clear it
    /// on the far side; if that reset lived in `body` it would be skipped on a stand-down and the
    /// flag would stick true forever, permanently wedging that mode's Start button. Anything that
    /// must happen whether or not the start proceeds belongs in `cleanup`, not `body`.
    @MainActor
    static func then(cleanup: (@MainActor () -> Void)? = nil,
                     _ body: @escaping @MainActor () -> Void) {
        guard isNeeded else { cleanup?(); body(); return }
        let stopEpoch = SimulationSession.shared.stopGeneration
        Task { @MainActor in
            await WanderTunnel.shared.ensureStarted()
            cleanup?()
            guard SimulationSession.shared.stopGeneration == stopEpoch else { return }
            body()
        }
    }
}
