//
//  BackgroundAudioManager.swift
//  Wander
//

import AVFoundation

/// Keeps a silent `.playback` audio session alive so iOS does not SUSPEND Wander while it is
/// backgrounded.
///
/// ⚠️ THIS IS THE LOAD-BEARING PIECE OF BACKGROUND SURVIVAL, and it is worth being blunt about why.
/// iOS suspends a backgrounded app by default, and a suspended app runs no code — worse, per Apple
/// TN2277 the system "may choose to reclaim resources out from underneath a network socket used by
/// the app", which closes the DVT connection holding the fake location. Declaring `UIBackgroundModes`
/// grants nothing on its own; the app has to actually BE doing the thing. This is the app doing it.
/// While this engine is playing, Wander's background lifetime is indefinite. While it is not, the
/// honest lifetime is roughly one `beginBackgroundTask` expiry window.
///
/// Which is why `keepAliveState` exists. Nothing used to measure whether the engine was still
/// playing, so after a session died there was no way to tell a suspension death from an FFI error —
/// the two leading causes were indistinguishable in the log. Now the transition is recorded when it
/// happens, which is the only moment it can be.
///
/// THREADING. Every piece of mutable state below — `engine`, `player`, the owner set, the recovery
/// counters — is MAIN-THREAD ONLY. The three `AVAudioSession`/`AVAudioEngine` notifications this
/// class observes are delivered on whatever thread the audio system feels like, so all three
/// handlers hop through `onMain` before touching anything. `engine` and `player` are non-atomic
/// strong properties that the rebuild path REASSIGNS; reassigning them from a notification thread
/// while the main-thread health timer reads them is an ARC race, not a theoretical one.
final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    /// Who is asking for the engine to run PERSISTENTLY (as opposed to for the duration of a lease).
    ///
    /// This was a single shared `persistentEnabled` Bool with three independent writers, and the two
    /// that matter disagree constantly: the user's "Silent Audio" setting wants it on for the whole
    /// process, while `ScheduleManager` turns it on and off as schedules arm and disarm. Because
    /// `stop()` was unconditional, a `ScheduleManager` refresh — which runs on EVERY foreground
    /// transition — switched off the engine the setting had just switched on, with the Settings
    /// toggle still reading ON. Named owners make the release local: one owner letting go can no
    /// longer speak for another owner that still wants the engine.
    enum PersistentOwner {
        /// The "Silent Audio" setting, taken at launch and by the toggle itself.
        case userSetting
        /// A schedule is armed or a schedule window is running.
        case schedule
    }

    /// What the keep-alive is actually doing. OFF and PLAYING are both "not broken" but they are not
    /// the same thing, and a diagnostic that collapses them into one Bool reports "healthy" about an
    /// engine that is switched off — see `SpoofLossReporter`.
    enum KeepAliveState: String {
        case off = "off"
        case playing = "running-and-playing"
        case broken = "running-but-BROKEN"
    }

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()

    /// The player is attached to `engine` and connected at a VALID format. False means the graph was
    /// never built (or was torn down), and in that state `player.play()` is not merely useless — it
    /// raises `required condition is false: _engine != nil`, an Objective-C exception no `try?`
    /// catches. Every playback attempt below is guarded on this.
    private var graphIsValid = false

    /// The looping silence buffer is scheduled. `AVAudioPlayerNode.isPlaying` is true after `play()`
    /// whether or not anything is scheduled, so without this an empty player reports "running and
    /// playing" while rendering nothing — iOS suspends the app anyway and the loss report says the
    /// keep-alive was fine. That is the exact lie `keepAliveState` exists to prevent.
    private var silenceScheduled = false

    private var isRunning = false
    private var persistentOwners: Set<PersistentOwner> = []
    private var activityCount = 0
    private var healthCheckTimer: Timer?

    /// THE SPOOF SESSION'S OWN LEASE, and deliberately NOT part of `activityCount` — for the same
    /// reason `BackgroundLocationManager.sessionLeaseHeld` is separate from its count.
    /// `SimulationSession.started()` runs on every teleport, not once per session, so counting there
    /// only ever climbs; and an unmatched `requestStop()` elsewhere must never be able to release a
    /// live session's keep-alive.
    ///
    /// ⚠️ READ THIS BEFORE ASSUMING THE LEASE IS WHAT RUNS THE ENGINE DURING A SPOOF. It is not, and
    /// cannot be, given the shipped defaults. `refreshRunningState()` gates EVERY reason to run on
    /// the user's `keepAliveAudio` setting, and `AppBootstrapper` takes the `.userSetting` persistent
    /// owner at launch iff that same setting is true — so `permitted` implies `.userSetting` is held,
    /// and the engine is already running before any session starts. The lease therefore does not
    /// change WHETHER the engine runs; what it buys is (a) the engine's lifetime is explicitly tied
    /// to the session rather than resting on an invariant two other files happen to maintain, and
    /// (b) `setSessionActive(true)` re-verifies the graph at the one moment it matters most, instead
    /// of trusting an `isRunning` flag that may have been true for hours over a broken graph.
    /// Making the lease override the setting was considered and rejected: a user who switched
    /// "Silent Audio" off must not get a silent audio session forced back on by starting a spoof.
    private var sessionLeaseHeld = false

    /// Last observed health, so a CHANGE can be logged once instead of every 2 s tick.
    private var lastHealthy = true

    /// Consecutive 2 s checks that found the engine broken. A cheap restart only works while the
    /// graph is still valid; past that it fails identically forever, so this is what escalates.
    private var consecutiveUnhealthyTicks = 0
    private let unhealthyTicksBeforeRebuild = 3

    /// An interruption (phone call, Siri, a non-mixable app) is in progress. An interrupted session
    /// is NOT a broken graph: iOS deactivated it and will hand it back. Without this, an ordinary
    /// incoming call stamped `lastUnhealthyAt` and logged the TN2277 suspension warning, so every
    /// call planted a false suspension marker in the very diagnostic that is supposed to tell a
    /// suspension death from a network death.
    private var isInterrupted = false

    /// Re-entrancy latch for `rebuildEngine()`. `startEngine()` touches `mainMixerNode`, which is
    /// itself a documented emitter of `AVAudioEngineConfigurationChange` — without this a rebuild
    /// can be re-entered by the notification it caused.
    private var isRebuilding = false

    /// When the last full rebuild ran. Two floors are enforced against it (see `rebuildEngine`):
    /// a long one for the automatic health escalation, and a short one that swallows the
    /// configuration-change notifications a rebuild posts about itself.
    private var lastRebuildAt: Date?

    /// Rebuilds since the last time something re-armed recovery. A rebuild that cannot fix the
    /// problem must not run forever: during a 20-minute phone call the old code did a full
    /// allocate/attach/connect/start cycle plus an error-log line every 2 seconds.
    private var rebuildAttempts = 0
    private let maxConsecutiveRebuilds = 3

    /// Floor between automatic (health-escalation) rebuilds.
    private let healthRebuildFloor: TimeInterval = 10
    /// Floor between event-driven rebuilds (route change, media reset, session start). Short, because
    /// these are real external causes — long enough only to drop a rebuild's own notifications.
    private let eventRebuildFloor: TimeInterval = 1

    /// What the keep-alive is doing right now. Read by the diagnostics that attribute a lost session.
    ///
    /// Note what `.playing` requires: a VALID graph with silence actually scheduled, an engine that
    /// is running, and a player that is playing. Anything less is `.broken`, deliberately — this
    /// value's only job is to be trustworthy in a loss report.
    var keepAliveState: KeepAliveState {
        guard isRunning else { return .off }
        guard graphIsValid, silenceScheduled, engine.isRunning, player.isPlaying else { return .broken }
        return .playing
    }

    /// When the keep-alive was last observed to be BROKEN, or nil if it has been fine. A session that
    /// died within a few seconds of this timestamp died of suspension, not of a network error — which
    /// is why `SpoofLossReporter` prints how long ago this was rather than only the state right now.
    /// The state at report time is misleading on its own: nothing runs while suspended, so by the
    /// time the report fires the health check has usually restarted the engine.
    private(set) var lastUnhealthyAt: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        // THE ROUTE-CHANGE OBSERVER, i.e. what happens the first time AirPods, CarPlay or a car
        // stereo connect. AVAudioEngine stops itself on a configuration change AND invalidates its
        // graph, so the periodic health check's cheap restart cannot fix it: the player node is
        // detached, the connection is at the old mainMixerNode format, and the looping silence buffer
        // is gone. `engine.start()` then throws forever and `player.isPlaying` never comes back true.
        // Only a full rebuild recovers, and nothing else in this file reaches one while `isRunning`
        // is already true.
        //
        // `object: nil` rather than the engine, because the engine instance is REPLACED on every
        // rebuild and a per-instance registration would have to be torn down and re-added in lockstep
        // with it. The cost of the loose filter is that we also hear our own rebuild's notifications;
        // `isRebuilding` plus the `eventRebuildFloor` is what stops that becoming a loop.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    // MARK: - Ownership

    func start(owner: PersistentOwner) {
        persistentOwners.insert(owner)
        refreshRunningState()
    }

    func stop(owner: PersistentOwner) {
        persistentOwners.remove(owner)
        refreshRunningState()
    }

    /// Take/release the SPOOF SESSION's lease. Idempotent by design — see `sessionLeaseHeld`.
    func setSessionActive(_ active: Bool) {
        guard active != sessionLeaseHeld else { return }
        sessionLeaseHeld = active
        refreshRunningState()
        guard active, isRunning else { return }
        // A spoof is starting, which is the moment the keep-alive stops being a nicety. `isRunning`
        // may have been true for hours over a graph that quietly broke (a route change while idle,
        // an interruption that never ended), and the health tick would take up to 6 s to escalate.
        // Verify now.
        rearmRecovery()
        if keepAliveState != .playing {
            rebuildEngine(trigger: "session-start", floor: eventRebuildFloor)
        }
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    /// The app came forward. Coming forward is the natural place to give up on giving up: whatever
    /// blocked recovery while we were backgrounded (a call, a route we could not open) has had its
    /// chance to end, and the user is present.
    func handleForeground() {
        guard isRunning else { return }
        rearmRecovery()
        if keepAliveState != .playing {
            attemptCheapRecovery()
        }
    }

    private func refreshRunningState() {
        // ONE GATE FOR EVERY REASON TO RUN, persistent owners included. This used to apply only to
        // the leased path, so "Silent Audio" OFF did not stop the engine for a user with an armed
        // schedule — `ScheduleManager` re-inserted `.schedule` on the next foreground and the toggle
        // read OFF while the feature stayed on. A user-facing switch labelled "Silent Audio" means
        // off when it says off.
        let permitted = UserDefaults.standard.bool(forKey: "keepAliveAudio")
        let wanted = !persistentOwners.isEmpty || sessionLeaseHeld || activityCount > 0
        let shouldRun = permitted && wanted

        guard shouldRun != isRunning else {
            if shouldRun {
                // Cheap probe only. This path is reached from `start(owner:)`/`stop(owner:)` on every
                // ScheduleManager refresh and every 4 s schedule tick, so it must NOT advance the
                // escalation counter — that counter belongs to the 2 s health timer alone, or the
                // rebuild threshold ends up driven by two unrelated clocks and fires early for users
                // who happen to have schedules armed.
                attemptCheapRecovery()
            }
            return
        }

        isRunning = shouldRun
        if shouldRun {
            rearmRecovery()
            // Deliberately not `rebuildEngine` — nothing to rate-limit on a cold start, and the floor
            // would make the very first start of the process a no-op if anything rebuilt just before.
            startEngine()
            startHealthCheck()
        } else {
            // Deliberately stopped, so "unhealthy" no longer means anything — don't leave a stale
            // false behind for the next start to log a spurious RECOVERED against.
            lastHealthy = true
            rearmRecovery()
            healthCheckTimer?.invalidate()
            healthCheckTimer = nil
            tearDownGraph()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Forget that recovery was failing. Called whenever something external changes the situation —
    /// a start, an interruption ending, a route change, a foreground — so the rebuild cap is a cap on
    /// FUTILE retries of one unchanging condition, not a permanent surrender.
    private func rearmRecovery() {
        consecutiveUnhealthyTicks = 0
        rebuildAttempts = 0
    }

    // MARK: - Engine

    /// Build the graph, then activate the session, then play — in that order and with the three
    /// failures kept apart.
    ///
    /// The order is the point. This used to allocate the engine and player and then immediately
    /// `try session.setActive(true)`, so a session another app held — a phone call, the game playing
    /// audio non-mixably — threw BEFORE `engine.attach(player)` and left a player node with no
    /// engine at all. `player.play()` on that node raises `required condition is false: _engine != nil`,
    /// an Objective-C exception that no `try?` in this file catches, and the automatic rebuild paths
    /// turned that from a rare latent state into one reachable every 2 seconds. Building the graph
    /// first means a session failure leaves a VALID graph that is merely not started, which is
    /// exactly what the cheap recovery path knows how to finish.
    private func startEngine() {
        // Stamped HERE, not in `rebuildEngine`, because this method is the thing that emits
        // configuration-change notifications about itself (`mainMixerNode`, `engine.stop()`) and it
        // is also reachable from the cold start in `refreshRunningState()`. The stamp is what lets
        // `handleConfigurationChange` tell our own noise from a real route change.
        lastRebuildAt = Date()
        tearDownGraph()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()

        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        // A degraded or absent route can hand back a zero sample rate. `engine.connect` with such a
        // format raises `IsFormatSampleRateAndChannelCountValid` (an NSException, uncatchable here),
        // and `AVAudioPCMBuffer` with a zero frame capacity returns nil — which the old code swallowed
        // silently, leaving a player with nothing scheduled reporting itself as playing.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            LogManager.shared.addErrorLog(
                "BackgroundAudioManager: unusable output format (\(format.sampleRate) Hz, \(format.channelCount) ch) — keep-alive is BROKEN until the route changes"
            )
            return
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        guard scheduleSilence(format: format) else {
            LogManager.shared.addErrorLog("BackgroundAudioManager: could not allocate the silence buffer")
            return
        }
        graphIsValid = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
        } catch {
            // Transient by design (another app holds the session). The graph above survives, so the
            // 2 s health tick's cheap path finishes the job the moment the session comes free.
            LogManager.shared.addErrorLog("BackgroundAudioManager: \(error.localizedDescription)")
            return
        }
        startPlayback()
    }

    /// Start the engine and the player, and DO NOT call `play()` on a node that cannot take it.
    private func startPlayback() {
        guard graphIsValid, silenceScheduled, player.engine != nil else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                LogManager.shared.addErrorLog("BackgroundAudioManager: engine.start — \(error.localizedDescription)")
                return
            }
        }
        // `AVAudioPlayerNode.play()` raises "player started when engine not running" if the start
        // above silently did not take. Both preconditions are checked, not assumed.
        guard engine.isRunning, player.engine != nil else { return }
        player.play()
    }

    private func tearDownGraph() {
        if player.engine != nil {
            player.stop()
        }
        engine.stop()
        graphIsValid = false
        silenceScheduled = false
    }

    @discardableResult
    private func scheduleSilence(format: AVAudioFormat) -> Bool {
        let frameCount = AVAudioFrameCount(format.sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return false
        }
        buffer.frameLength = frameCount
        // PCM buffer is zero-initialized — pure silence
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        silenceScheduled = true
        return true
    }

    // MARK: - Health

    // Runs every 2 seconds to reclaim the session if continuous game audio
    // holds it and the interruption-ended notification never fires.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.tickHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    /// THE ONLY OWNER OF THE ESCALATION COUNTER, and the only path that may trigger an automatic
    /// rebuild. Kept separate from `attemptCheapRecovery()` so the rebuild threshold is a function of
    /// elapsed time and nothing else.
    private func tickHealth() {
        guard isRunning else { return }

        if isInterrupted {
            // An interruption is not a broken graph, so this neither counts nor logs. It still tries
            // the cheap resume, and a success is how we learn the interruption is actually over —
            // `.ended` is not guaranteed to reach a backgrounded app, and a stuck flag here would
            // disable recovery for the rest of the process.
            attemptCheapRecovery()
            if keepAliveState == .playing {
                isInterrupted = false
                rearmRecovery()
                noteHealth(true)
            }
            return
        }

        if keepAliveState == .playing {
            rearmRecovery()
            noteHealth(true)
            return
        }

        // BROKEN RIGHT NOW. Record it BEFORE attempting the recovery: if this tick is the last code we
        // get to run before iOS suspends us, the fact still made it into the log. Recovering needs the
        // very runtime it is trying to preserve, so the attempt below is not guaranteed to happen.
        noteHealth(false)
        consecutiveUnhealthyTicks += 1

        // The cheap restart fixes exactly one thing: a session another app briefly took. It cannot fix
        // an INVALIDATED graph, and it fails the same way every 2 s forever when that is what
        // happened — silent permanent death of the keep-alive. A RUN of failing ticks is what
        // escalates, deliberately not a single throw: `setActive` throwing is the ordinary
        // "another app holds it" case, and rebuilding on it inverted the ladder (the rebuild reset
        // the counter, so the run threshold was never reached and a full rebuild ran every 2 s
        // instead).
        if consecutiveUnhealthyTicks >= unhealthyTicksBeforeRebuild,
           rebuildEngine(trigger: "health-escalation", floor: healthRebuildFloor) {
            return
        }
        attemptCheapRecovery()
    }

    /// Reclaim the session and resume playback. Touches no counters and logs nothing — safe to call
    /// from anywhere, as often as anyone likes.
    private func attemptCheapRecovery() {
        guard isRunning, graphIsValid, silenceScheduled else { return }
        // A no-op when nothing is wrong. This is reached from `refreshRunningState()`, which
        // `ScheduleManager` drives on every foreground AND every 4 s tick, so a healthy engine must
        // not pay an `AVAudioSession.setActive` round trip each time.
        guard keepAliveState != .playing else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Ordinary and transient: another app holds the session non-mixably. Nothing to log at
            // 2 s intervals and nothing to escalate on — `tickHealth` owns escalation.
            return
        }
        startPlayback()
    }

    /// Tear the graph down and build a new one: the player is re-attached, reconnected at the CURRENT
    /// mainMixerNode format, and the looping silence buffer re-scheduled. Returns whether it ran.
    ///
    /// BOUNDED, because a rebuild that cannot fix the cause is pure churn — a full
    /// allocate/attach/connect/start cycle and an error-log line, at whatever rate the caller ticks.
    @discardableResult
    private func rebuildEngine(trigger: String, floor: TimeInterval) -> Bool {
        guard isRunning, !isRebuilding else { return false }
        if let last = lastRebuildAt, Date().timeIntervalSince(last) < floor { return false }
        guard rebuildAttempts < maxConsecutiveRebuilds else { return false }

        isRebuilding = true
        rebuildAttempts += 1
        consecutiveUnhealthyTicks = 0
        LogManager.shared.addInfoLog("[keepalive] rebuilding silent-audio engine — \(trigger) (attempt \(rebuildAttempts)/\(maxConsecutiveRebuilds))")
        startEngine()
        isRebuilding = false

        if keepAliveState == .playing {
            rearmRecovery()
            noteHealth(true)
        }
        return true
    }

    /// Log only the TRANSITIONS. A line every 2 s would be noise; the two edges are the whole signal.
    private func noteHealth(_ healthy: Bool) {
        guard healthy != lastHealthy else { return }
        lastHealthy = healthy
        if healthy {
            LogManager.shared.addInfoLog("[keepalive] silent-audio session RECOVERED — suspension is held off again")
        } else {
            lastUnhealthyAt = Date()
            LogManager.shared.addInfoLog("[keepalive] silent-audio session STOPPED — iOS may suspend Wander and reclaim the tunnel socket (TN2277)")
        }
    }

    // MARK: - Notifications (all delivered off the main thread)

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        onMain { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // Tracked even when not running, so a `.began` that arrives around a start cannot
                // leave the flag stale in the wrong direction.
                self.isInterrupted = true
            case .ended:
                self.isInterrupted = false
                guard self.isRunning else { return }
                // Something external changed, so previous failures no longer predict anything.
                self.rearmRecovery()
                // Best-effort immediate resume; the health tick covers failures. Note this goes
                // through `startPlayback()`, which will not call `play()` on a detached node.
                self.attemptCheapRecovery()
            @unknown default:
                break
            }
        }
    }

    @objc private func handleMediaServicesReset() {
        onMain { [weak self] in
            guard let self, self.isRunning else { return }
            // Media services died and came back: every audio object we hold is invalid. This is the
            // one case where a rebuild is unambiguously correct, so it re-arms first.
            self.rearmRecovery()
            self.rebuildEngine(trigger: "media-services-reset", floor: self.eventRebuildFloor)
        }
    }

    @objc private func handleConfigurationChange() {
        // Posted on an arbitrary thread — everything below touches engine/player state that the rest
        // of this class only ever reaches from the main thread.
        onMain { [weak self] in
            guard let self, self.isRunning else { return }
            // DROP OUR OWN. `startEngine()` touches `mainMixerNode`, which instantiates and connects
            // the output node and is a documented emitter of this very notification; combined with
            // `object: nil` that is a self-sustaining rebuild loop, each iteration allocating an
            // engine, a player and a ~1 s float PCM buffer. The latch covers a synchronous post and
            // the floor covers one that arrives a beat later on the main queue.
            guard !self.isRebuilding else { return }
            if let last = self.lastRebuildAt, Date().timeIntervalSince(last) < self.eventRebuildFloor {
                return
            }
            // A genuine route change is a new cause, so it is allowed a fresh set of attempts. If it
            // was in fact ours, the floor above already dropped it.
            self.rearmRecovery()
            self.rebuildEngine(trigger: "configuration-change", floor: self.eventRebuildFloor)
        }
    }
}
