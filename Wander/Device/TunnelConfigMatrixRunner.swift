//
//  TunnelConfigMatrixRunner.swift
//  Wander
//
//  ONE BUTTON INSTEAD OF AN EVENING. Runs every candidate tunnel configuration back to back —
//  reconnecting between rows, verifying that the configuration actually reached the interface,
//  probing the target and two controls with bounded connects — and writes a compact table plus a
//  bottom-line verdict into the app Console.
//
//  ── THE RECONNECT QUESTION, ANSWERED FIRST, BECAUSE IT DECIDES THE WHOLE DESIGN ────────────────
//  YES: changing the tunnel addresses requires a VPN reconnect. It is not a precaution, it is how the
//  code works. `PacketTunnelProvider.startTunnel(options:)` reads TunnelDeviceIP / TunnelFakeIP /
//  TunnelSubnetMask out of `options` (TunnelProv/PacketTunnelProvider.swift lines 66-73) and never
//  looks at them again; `WanderTunnel.start()` is the only thing that fills that dictionary
//  (Wander/Services/WanderTunnel.swift lines 578-586), from UserDefaults, once per start. The only
//  code that ever re-applied network settings mid-flight was the NWPathMonitor removed on
//  2026-08-05 — and removing it is why the tunnel stopped blackholing on reconnect. So: writing new
//  addresses while the tunnel is up changes NOTHING, and a probe taken afterwards measures the
//  PREVIOUS configuration while looking exactly like it measured the new one. Every tunnel row here
//  therefore stops the tunnel, starts it again, and then CHECKS THE INTERFACE before believing a
//  single number.
//
//  ── TWO MODES, AND THE DIFFERENCE IS NOT COSMETIC ───────────────────────────────────────────────
//  AUTO drives Wander's OWN tunnel: fully unattended, but it can only test OUR provider — which was
//  measured on 2026-08-05 to blackhole every address on three unrelated subnets. If AUTO comes back
//  all-NO-ANSWER, that is a fact about the provider, not about the addresses, and the report says so
//  rather than letting eight identical rows read as eight refutations.
//
//  ASSISTED drives an EXTERNAL tunnel (LocalDevVPN, StosVPN). iOS gives an app no way to read or
//  write another app's NEVPNManager configuration, so the addresses have to be typed in by hand —
//  but that is the ONLY manual part. The engine watches getifaddrs and, the moment the requested
//  address appears on a utun with the requested mask, probes and advances by itself. This is the mode
//  that answers the open question, because LocalDevVPN's tunnel is the one measured working (F3).
//  ASSISTED CHANGES NOTHING IN WANDER — it writes no setting, starts no tunnel, and needs no restore.
//
//  ── SAFETY ──────────────────────────────────────────────────────────────────────────────────────
//  Every probe bounded at 1.5 s; every row bounded; the whole run bounded. Nothing runs on the main
//  thread and nothing touches `LocationSimulationCommandQueue`, so Stop and Panic stay responsive.
//  The user's tunnel settings are captured before the first row and restored on EVERY exit path —
//  normal end, the run cap, and cancellation all fall out of the same loop into the same restore
//  block, and no row runner can return past it. On top of that the originals are written to disk
//  before the first mutation, so an app that dies mid-run cannot leave someone's tunnel pointed at
//  127.0.0.4 with no clue why: the next thing to touch the runner puts them back.
//
//  The mutation window is also kept small on purpose. A row restores the user's settings as soon as
//  the new addresses are seen ON THE INTERFACE — proof the provider has already consumed the start
//  options — rather than holding them for the length of the row. The running tunnel keeps the row's
//  addresses either way, because the provider never re-reads them.
//

import Foundation

/// Column widths for the Console table. File scope, not a member of the MainActor-isolated runner,
/// because the formatting runs on the background task that produced the rows. The Console renders in
/// a monospaced font (`AppLogRow`), so fixed widths actually line up.
private let matrixColumnWidths = (row: 3, config: 30, install: 14, target: 22, controlA: 14, controlB: 14)

/// Every bound the run promises to keep.
///
/// Kept OUTSIDE the MainActor-isolated runner deliberately: the run itself executes on a background
/// task, and constants it reads on every row should not require an actor hop (nor, under Swift 6
/// rules, be unreachable from there at all).
enum TunnelMatrixBounds {
    /// Per-probe bound, matching `TunnelEndpointSweep`. Every failure mode we care about — RST, ICMP
    /// unreachable, or silence — declares itself far inside this on a loopback or a local link.
    static let probe: Double = 1.5
    /// How long to wait for the VPN to report disconnected before giving up on a clean stop.
    static let disconnect: Double = 8
    /// How long to wait for the VPN to report connected.
    static let connect: Double = 15
    /// How long to wait AFTER `.connected` for the address to actually appear on a utun. `.connected`
    /// only means iOS started the provider; the interface is configured a beat later.
    static let install: Double = 8
    /// Whole-run cap for AUTO. A run that has burned this long has stopped being a measurement.
    static let autoRun: Double = 300
    /// Per-row cap in ASSISTED mode, so an unattended phone cannot park a task forever.
    static let assistedRow: Double = 300
}

@MainActor
final class TunnelConfigMatrixRunner: ObservableObject {

    /// ONE runner for the whole app.
    ///
    /// Not decoration: the run outlives whatever started it. A menu row in the Console has no object
    /// to own a `Task` that spends a minute reconnecting a VPN, and a `@StateObject` on a screen the
    /// user navigates away from would be torn down mid-row — leaving the tunnel pointed at a test
    /// address with nothing left alive to put it back. A single shared instance also means the
    /// Console row and the Tunnel Matrix screen can never disagree about whether a run is in flight.
    static let shared = TunnelConfigMatrixRunner()

    // MARK: - Modes and state

    enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// Drive Wander's own NEPacketTunnelProvider. Unattended.
        case auto
        /// Drive an external tunnel app (LocalDevVPN / StosVPN). The user types each row's addresses;
        /// the engine detects the change and measures it.
        case assisted
        /// The two no-tunnel rows only. Changes nothing, needs nothing, takes ~3 s.
        case directOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto:       return "Automatic (Wander's own tunnel)"
            case .assisted:   return "Assisted (LocalDevVPN / external tunnel)"
            case .directOnly: return "Direct rows only (no tunnel changes)"
            }
        }

        var logLabel: String {
            switch self {
            case .auto:       return "AUTO — Wander's own tunnel"
            case .assisted:   return "ASSISTED — external tunnel, addresses entered by hand"
            case .directOnly: return "DIRECT-ONLY — no tunnel configuration touched"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case running(rowIndex: Int, total: Int, detail: String)
        /// ASSISTED mode is parked waiting for the user to enter a row's addresses in the other app.
        case waitingForUser(rowIndex: Int, total: Int, instruction: String)
        case finished(bottomLine: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var rows: [TunnelConfigMatrixRow] = []
    /// The full report, kept so the screen can show and share exactly what went into the log.
    @Published private(set) var reportLines: [String] = []
    @Published private(set) var isRunning = false
    /// Set when a run is refused before it starts, so the reason is shown rather than swallowed.
    @Published private(set) var refusal: String?

    private var runTask: Task<Void, Never>?

    // MARK: - Crash safety
    //
    // AUTO mode holds someone else's settings for a few seconds per row. If the app dies in that
    // window the tunnel would come back pointed at, say, 127.0.0.4/30 — and the symptom (the spoof
    // silently never works again) looks nothing like the cause. So the originals go to disk BEFORE
    // the first write and are put back by whoever gets there first.

    private static let restoreRecordKey = "TunnelMatrixPendingRestore"

    /// Put back settings left behind by a run that did not finish. Safe to call at any time from the
    /// main thread; a no-op when there is nothing pending. Returns a description when it restored
    /// something, so the caller can say so out loud.
    @discardableResult
    static func restoreInterruptedRunIfNeeded() -> String? {
        let d = UserDefaults.standard
        guard let record = d.dictionary(forKey: restoreRecordKey) else { return nil }
        applyConfig(interfaceIP: record["interfaceIP"] as? String,
                    targetIP: record["targetIP"] as? String,
                    mask: record["mask"] as? String)
        d.removeObject(forKey: restoreRecordKey)
        let when = (record["at"] as? Date).map { " (from a run at \(DateFormatter.matrixClock.string(from: $0)))" } ?? ""
        let summary = "Tunnel matrix: restored your tunnel settings after an interrupted run\(when) — "
            + "\(record["interfaceIP"] as? String ?? "default") / \(record["targetIP"] as? String ?? "default") / \(record["mask"] as? String ?? "default")"
        LogManager.shared.addInfoLog(summary)
        return summary
    }

    /// Read the three keys exactly as `WanderTunnel.start()` does. nil means "not set", which is a
    /// real state (the shipping default) and must be restored as absence, not as a literal.
    private static func currentConfig() -> (interfaceIP: String?, targetIP: String?, mask: String?) {
        let d = UserDefaults.standard
        return (d.string(forKey: UserDefaults.Keys.tunnelInterfaceIP),
                d.string(forKey: UserDefaults.Keys.targetDeviceIP),
                d.string(forKey: UserDefaults.Keys.tunnelSubnetMask))
    }

    private static func applyConfig(interfaceIP: String?, targetIP: String?, mask: String?) {
        let d = UserDefaults.standard
        func write(_ value: String?, _ key: String) {
            if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        }
        write(interfaceIP, UserDefaults.Keys.tunnelInterfaceIP)
        write(targetIP, UserDefaults.Keys.targetDeviceIP)
        write(mask, UserDefaults.Keys.tunnelSubnetMask)
    }

    // MARK: - Starting and stopping

    init() {
        // If a previous run died mid-flight, the very first thing this screen does is undo it.
        Self.restoreInterruptedRunIfNeeded()
    }

    /// Why this mode cannot run right now, or nil when it can. Checked before anything is touched.
    func refusalReason(for mode: Mode) -> String? {
        if SimulationSession.shared.isActive {
            return "A location simulation is running. The DVT session is connection-scoped, so reconnecting the tunnel would kill your spoof mid-run. Stop the simulation first."
        }
        if GslocMode.enabled, mode != .directOnly {
            return "gs-loc (PoGo) mode is on, and it needs Shadowrocket to hold iOS's single VPN slot. Running the matrix would take that slot away. Turn gs-loc off first, or run the direct rows only."
        }
        if mode == .auto, !WanderTunnel.isSupported {
            return "Automatic mode drives Wander's own tunnel, and this install isn't signed with the Network Extension entitlement. Use Assisted mode with LocalDevVPN instead."
        }
        return nil
    }

    func start(mode: Mode) {
        guard !isRunning else { return }
        if let reason = refusalReason(for: mode) {
            refusal = reason
            phase = .failed(reason)
            return
        }
        refusal = nil
        rows = []
        reportLines = []
        isRunning = true
        phase = .running(rowIndex: 0, total: 0, detail: "starting")

        // DETACHED on purpose. A plain `Task {}` created here would inherit the MainActor and run the
        // blocking connects on the main thread — the exact thing this must never do.
        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.execute(mode: mode)
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    /// Fire-and-forget entry point for a menu row. Starts the run on the shared instance and returns
    /// a sentence to put in a confirmation alert — it does NOT wait for the run, because a menu tap
    /// must not block the Console for a minute. The table and the bottom line land in the Console log
    /// (and in `NetworkInterfaceDump.retain`, so opening the Console cannot wipe them).
    @discardableResult
    static func runHeadless(mode: Mode) -> String {
        let runner = TunnelConfigMatrixRunner.shared
        if runner.isRunning { return "A matrix run is already in progress — wait for it to finish." }
        if let reason = runner.refusalReason(for: mode) { return reason }
        runner.start(mode: mode)
        switch mode {
        case .auto:
            return "Running. Each row stops and restarts the tunnel, so expect roughly one minute; leave Wander in the foreground. The table and the bottom line will appear in this log when it finishes."
        case .assisted:
            return "Assisted mode needs the on-screen instructions — open Tools → Tunnel Matrix instead."
        case .directOnly:
            return "Running the two no-tunnel probes. The result appears in this log in a few seconds."
        }
    }

    /// ASSISTED mode: the user says "I've entered this row, but the address never showed up — move on".
    func skipCurrentRow() {
        skipRequested = true
    }

    /// ASSISTED mode: "I've entered it, measure now" — used when the engine's own detection cannot
    /// see the change (e.g. the external app reuses the address that is already there).
    func proceedNow() {
        proceedRequested = true
    }

    private var skipRequested = false
    private var proceedRequested = false

    // MARK: - The run

    private nonisolated func execute(mode: Mode) async {
        let startedAt = Date()
        let entriesAtStart = WiFiSubnet.allAddresses()
        // The EXACT interface state, captured now rather than reconstructed later — and produced by
        // the app's existing dump so there is still exactly one getifaddrs consumer in this codebase.
        // Taken at the START on purpose: by the time the report is written the tunnel has been
        // reconnected several times and the end state describes none of the rows.
        let interfaceDumpAtStart = NetworkInterfaceDump.report(reason: "tunnel config matrix — state at start")
        var candidates = TunnelConfigMatrix.candidates(entries: entriesAtStart)
        if mode == .directOnly {
            candidates = candidates.filter { $0.kind == .direct }
        }

        // Capture the user's settings and the tunnel's state BEFORE anything is touched.
        let original = await MainActor.run { Self.currentConfig() }
        let tunnelWasConnected = await MainActor.run {
            WanderTunnel.shared.status == .connected || WanderTunnel.shared.status == .connecting
        }
        // Recorded before anything starts, because AUTO mode WILL take iOS's single VPN slot and the
        // app it takes it from cannot be restarted from here.
        let foreignVPNAtStart = !tunnelWasConnected && WanderTunnel.foreignVPNInterfaceActive()
        let willMutate = (mode == .auto)

        if willMutate {
            // Built key by key. A nil here means "the user never set this key", which is a real state
            // and must be recorded as ABSENCE — putting an Optional.none into a UserDefaults
            // dictionary is not a property-list value and would trap on the very first row.
            let record: [String: Any] = {
                var built: [String: Any] = ["at": Date()]
                if let value = original.interfaceIP { built["interfaceIP"] = value }
                if let value = original.targetIP { built["targetIP"] = value }
                if let value = original.mask { built["mask"] = value }
                return built
            }()
            await MainActor.run { UserDefaults.standard.set(record, forKey: Self.restoreRecordKey) }
        }

        var collected: [TunnelConfigMatrixRow] = []
        var abortNote: String?

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled { abortNote = "cancelled by the user"; break }
            if Date().timeIntervalSince(startedAt) > TunnelMatrixBounds.autoRun, mode == .auto {
                abortNote = "the \(Int(TunnelMatrixBounds.autoRun))s run cap was reached"
                break
            }

            var row = TunnelConfigMatrixRow(candidate: candidate)
            let rowStarted = Date()

            if let missing = Self.missingRequirement(candidate, entries: WiFiSubnet.allAddresses()) {
                row.skippedReason = missing
                row.elapsedSeconds = 0
                collected.append(row)
                await publish(rows: collected,
                              phase: .running(rowIndex: index + 1, total: candidates.count,
                                              detail: "\(candidate.title) — skipped"))
                continue
            }

            switch candidate.kind {
            case .direct:
                await publish(rows: collected,
                              phase: .running(rowIndex: index + 1, total: candidates.count,
                                              detail: "\(candidate.title) — probing"))
                row = await runDirectRow(row)

            case .tunnel:
                switch mode {
                case .directOnly:
                    row.skippedReason = "direct-only run"
                case .auto:
                    await publish(rows: collected,
                                  phase: .running(rowIndex: index + 1, total: candidates.count,
                                                  detail: "\(candidate.title) — reconnecting the tunnel"))
                    row = await runAutoTunnelRow(row, index: index + 1, total: candidates.count,
                                                 restoreTo: original)
                case .assisted:
                    row = await runAssistedTunnelRow(row, index: index + 1, total: candidates.count)
                }
            }

            row.elapsedSeconds = Date().timeIntervalSince(rowStarted)
            collected.append(row)
            await publish(rows: collected,
                          phase: .running(rowIndex: index + 1, total: candidates.count,
                                          detail: "\(candidate.title) — done"))
        }

        // ── Restore. Runs on every exit path, including cancellation. ────────────────────────────
        var restoreNote = "nothing was changed, so nothing needed restoring"
        if willMutate, foreignVPNAtStart {
            restoreNote = "NOTE: another VPN app (LocalDevVPN / Shadowrocket / a real VPN) was holding iOS's single VPN slot when this run started, and Wander's tunnel took it. Reconnect that app yourself — nothing here can do it for you. "
        }
        if willMutate {
            await MainActor.run { Self.applyConfig(interfaceIP: original.interfaceIP,
                                                   targetIP: original.targetIP,
                                                   mask: original.mask) }
            restoreNote += "your tunnel settings were put back "
                + "(\(original.interfaceIP ?? "unset") / \(original.targetIP ?? "unset") / \(original.mask ?? "unset"))"
            if tunnelWasConnected {
                await MainActor.run { WanderTunnel.shared.start() }
                let backUp = await waitForStatus(.connected,
                                                 timeout: TunnelMatrixBounds.connect,
                                                 honorCancellation: false)
                restoreNote += backUp
                    ? " and the tunnel was reconnected with them"
                    : " but the tunnel did NOT come back up within \(Int(TunnelMatrixBounds.connect))s — reconnect it yourself"
            } else {
                await MainActor.run { WanderTunnel.shared.stop() }
                restoreNote += " and the tunnel was left disconnected, as it was before the run"
            }
            await MainActor.run { UserDefaults.standard.removeObject(forKey: Self.restoreRecordKey) }
        }

        let report = Self.report(mode: mode,
                                 rows: collected,
                                 entriesAtStart: entriesAtStart,
                                 interfaceDumpAtStart: interfaceDumpAtStart,
                                 startedAt: startedAt,
                                 abortNote: abortNote,
                                 restoreNote: restoreNote)
        let bottom = report.last(where: { $0.hasPrefix("BOTTOM LINE") }) ?? "no bottom line was produced"

        for line in report { LogManager.shared.addInfoLog(line) }
        // Same store the interface dump and the endpoint sweep use, so opening the Console — which
        // REPLACES the log buffer with what it parses off disk — cannot wipe the run you just did.
        NetworkInterfaceDump.retain(report)

        let finalRows = collected
        await MainActor.run {
            self.rows = finalRows
            self.reportLines = report
            self.isRunning = false
            self.phase = .finished(bottomLine: bottom)
        }
    }

    // MARK: - Row runners

    /// A row that changes nothing: probe the target, take both controls, record the utun state so the
    /// word "direct" is never ambiguous about whether a tunnel happened to be up at the time.
    private nonisolated func runDirectRow(_ input: TunnelConfigMatrixRow) async -> TunnelConfigMatrixRow {
        var row = input
        let entries = WiFiSubnet.allAddresses()
        row.installState = .notApplicable
        let utuns = entries.filter { $0.isUtun && $0.isIPv4 && $0.isUp }
            .map { "\($0.name) \($0.cidr ?? $0.address)" }
        row.installedOn = utuns.isEmpty ? "no utun carries IPv4" : "utun state: " + utuns.joined(separator: ", ")
        row.targetCoveredByTunnel = TunnelConfigMatrix.targetCoveredByTunnel(row.candidate.targetIP, entries: entries)
        row.lockdowndNote = "no tunnel configured — the source is whatever the kernel picks for this destination"
        row.target = EndpointProbe.probe(row.candidate.targetIP, timeoutSeconds: TunnelMatrixBounds.probe)
        row.loopbackControl = EndpointProbe.probe("127.0.0.1", timeoutSeconds: TunnelMatrixBounds.probe)
        return row
    }

    /// AUTO: write the row's addresses, bounce Wander's tunnel, wait for the interface to actually
    /// carry them, restore the user's settings, then measure.
    private nonisolated func runAutoTunnelRow(_ input: TunnelConfigMatrixRow,
                                              index: Int,
                                              total: Int,
                                              restoreTo original: (interfaceIP: String?, targetIP: String?, mask: String?)) async -> TunnelConfigMatrixRow {
        var row = input
        guard let deviceIP = row.candidate.deviceIP, let mask = row.candidate.mask else {
            row.skippedReason = "no addresses to configure"
            return row
        }

        let targetIP = row.candidate.targetIP
        await MainActor.run {
            Self.applyConfig(interfaceIP: deviceIP, targetIP: targetIP, mask: mask)
            // A pending idle-disconnect armed before the run must not fire into the middle of it.
            WanderTunnel.shared.cancelAutoDisconnect()
            WanderTunnel.shared.stop()
        }
        _ = await waitForStatus(.disconnected, timeout: TunnelMatrixBounds.disconnect)
        // The interface lingers briefly after the status flips; starting into a half-torn-down utun is
        // how a row ends up measuring the previous config.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Task.isCancelled { row.skippedReason = "cancelled"; return row }

        await MainActor.run { WanderTunnel.shared.start() }
        let connected = await waitForStatus(.connected, timeout: TunnelMatrixBounds.connect)

        await publish(rows: nil, phase: .running(rowIndex: index, total: total,
                                                 detail: "\(row.candidate.title) — waiting for the address to install"))
        let entries = await waitForInstall(deviceIP: deviceIP, mask: mask, timeout: TunnelMatrixBounds.install)

        // The provider has consumed the start options by now, so the user's settings can go back
        // immediately — the RUNNING tunnel keeps this row's addresses either way, because it never
        // re-reads them. Restoring here rather than only at the end of the run is what keeps the
        // window in which someone else's settings are on disk down to a few seconds per row.
        //
        // The values come from the caller, NOT from re-reading the on-disk crash record: a record
        // that failed to write, or that a concurrent run cleared, would read back as three nils and
        // this line would then DELETE a user's custom tunnel config while claiming to restore it.
        await MainActor.run {
            Self.applyConfig(interfaceIP: original.interfaceIP,
                             targetIP: original.targetIP,
                             mask: original.mask)
        }

        let (state, where_) = TunnelConfigMatrix.installState(deviceIP: deviceIP, mask: mask, entries: entries)
        row.installState = state
        row.installedOn = where_
        row.targetCoveredByTunnel = TunnelConfigMatrix.targetCoveredByTunnel(row.candidate.targetIP, entries: entries)
        row.lockdowndNote = TunnelConfigMatrix.lockdowndNote(sourceIP: deviceIP, entries: entries)

        if !connected, case .addressMissing = state {
            row.skippedReason = "the tunnel never reported connected and no address installed — nothing to measure"
            return row
        }

        row.target = EndpointProbe.probe(row.candidate.targetIP, timeoutSeconds: TunnelMatrixBounds.probe)
        row.loopbackControl = EndpointProbe.probe("127.0.0.1", timeoutSeconds: TunnelMatrixBounds.probe)
        row.interfaceControl = EndpointProbe.probe(deviceIP, timeoutSeconds: TunnelMatrixBounds.probe)
        return row
    }

    /// ASSISTED: tell the user what to type into the other app, then WATCH for it. Nothing in Wander
    /// is written, started or stopped.
    private nonisolated func runAssistedTunnelRow(_ input: TunnelConfigMatrixRow,
                                                  index: Int,
                                                  total: Int) async -> TunnelConfigMatrixRow {
        var row = input
        guard let deviceIP = row.candidate.deviceIP, let mask = row.candidate.mask else {
            row.skippedReason = "no addresses to configure"
            return row
        }

        let instruction = "In LocalDevVPN → Settings set Device IP \(deviceIP), Tunnel IP \(row.candidate.targetIP), Subnet mask \(mask), then Disconnect and Connect. This screen measures it the moment it appears."
        await MainActor.run {
            self.skipRequested = false
            self.proceedRequested = false
            self.phase = .waitingForUser(rowIndex: index, total: total, instruction: instruction)
        }

        let deadline = Date().addingTimeInterval(TunnelMatrixBounds.assistedRow)
        var entries = WiFiSubnet.allAddresses()
        var sawIt = false
        while Date() < deadline {
            if Task.isCancelled { row.skippedReason = "cancelled"; return row }
            let (skip, proceed) = await MainActor.run { (self.skipRequested, self.proceedRequested) }
            if skip { row.skippedReason = "skipped by the user"; return row }
            entries = WiFiSubnet.allAddresses()
            if case .installed = TunnelConfigMatrix.installState(deviceIP: deviceIP, mask: mask, entries: entries).0 {
                sawIt = true
                break
            }
            if proceed { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if !sawIt {
            let proceed = await MainActor.run { self.proceedRequested }
            if !proceed {
                row.skippedReason = "the address never appeared on a utun within \(Int(TunnelMatrixBounds.assistedRow))s"
                let (state, where_) = TunnelConfigMatrix.installState(deviceIP: deviceIP, mask: mask, entries: entries)
                row.installState = state
                row.installedOn = where_
                return row
            }
        }
        // Give the route table a moment after the address lands.
        try? await Task.sleep(nanoseconds: 500_000_000)
        entries = WiFiSubnet.allAddresses()

        let (state, where_) = TunnelConfigMatrix.installState(deviceIP: deviceIP, mask: mask, entries: entries)
        row.installState = state
        row.installedOn = where_
        row.targetCoveredByTunnel = TunnelConfigMatrix.targetCoveredByTunnel(row.candidate.targetIP, entries: entries)
        row.lockdowndNote = TunnelConfigMatrix.lockdowndNote(sourceIP: deviceIP, entries: entries)

        await publish(rows: nil, phase: .running(rowIndex: index, total: total,
                                                 detail: "\(row.candidate.title) — probing"))
        row.target = EndpointProbe.probe(row.candidate.targetIP, timeoutSeconds: TunnelMatrixBounds.probe)
        row.loopbackControl = EndpointProbe.probe("127.0.0.1", timeoutSeconds: TunnelMatrixBounds.probe)
        row.interfaceControl = EndpointProbe.probe(deviceIP, timeoutSeconds: TunnelMatrixBounds.probe)
        return row
    }

    // MARK: - Waiting

    /// Poll `WanderTunnel.status` on the main actor until it reaches `wanted` or the bound expires.
    ///
    /// `honorCancellation: false` is used on the RESTORE path and nowhere else. Cancelling a run must
    /// not also cancel putting the user's tunnel back — and it cannot simply be ignored either,
    /// because `Task.sleep` returns instantly on a cancelled task, which would turn this poll into a
    /// 15-second busy loop. So that path sleeps through a timer the task system cannot interrupt.
    private nonisolated func waitForStatus(_ wanted: WanderTunnel.Status,
                                           timeout: Double,
                                           honorCancellation: Bool = true) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if honorCancellation, Task.isCancelled { return false }
            let status = await MainActor.run { WanderTunnel.shared.status }
            if status == wanted { return true }
            // `.error` is terminal — the entitlement is missing or the config wouldn't save. Waiting
            // out the full bound on it just wastes the run.
            if status == .error { return false }
            if honorCancellation {
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else {
                await Self.uninterruptibleSleep(seconds: 0.3)
            }
        }
        return false
    }

    /// A sleep that a cancelled task still honours. Yields the thread — it does not block one.
    private nonisolated static func uninterruptibleSleep(seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    /// Poll getifaddrs until a utun carries `deviceIP` with `mask`, then return that snapshot. On
    /// expiry it returns the LAST snapshot taken, so the caller still reports what was really there
    /// rather than nothing.
    private nonisolated func waitForInstall(deviceIP: String, mask: String, timeout: Double) async -> [NetworkInterfaceAddress] {
        let deadline = Date().addingTimeInterval(timeout)
        var entries = WiFiSubnet.allAddresses()
        while Date() < deadline {
            if Task.isCancelled { return entries }
            entries = WiFiSubnet.allAddresses()
            if case .installed = TunnelConfigMatrix.installState(deviceIP: deviceIP, mask: mask, entries: entries).0 {
                // One more beat so the route lands, not just the address.
                try? await Task.sleep(nanoseconds: 400_000_000)
                return WiFiSubnet.allAddresses()
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return entries
    }

    private nonisolated func publish(rows: [TunnelConfigMatrixRow]?, phase: Phase) async {
        await MainActor.run {
            if let rows { self.rows = rows }
            self.phase = phase
        }
    }

    /// Whether a candidate's preconditions hold right now, worded for the report.
    private nonisolated static func missingRequirement(_ candidate: TunnelConfigCandidate,
                                                       entries: [NetworkInterfaceAddress]) -> String? {
        switch candidate.requirement {
        case .none:
            return nil
        case .hotspotBridge:
            let up = entries.contains { $0.name == "bridge100" && $0.isUp && $0.isIPv4 }
            return up ? nil : "Personal Hotspot's bridge100 is not up, so 172.20.10.x is not a real subnet on this phone. Turn Personal Hotspot on (and keep a client attached — iOS drops it after ~90 s with none) and re-run."
        case .wifiSubnet:
            return "no en0 Wi-Fi address to derive a /30 from"
        }
    }

    // MARK: - The report

    nonisolated static func report(mode: Mode,
                                   rows: [TunnelConfigMatrixRow],
                                   entriesAtStart: [NetworkInterfaceAddress],
                                   interfaceDumpAtStart: [String] = [],
                                   startedAt: Date,
                                   abortNote: String?,
                                   restoreNote: String) -> [String] {
        var out: [String] = []
        let elapsed = Int(Date().timeIntervalSince(startedAt))

        out.append("=== TUNNEL CONFIG MATRIX === mode: \(mode.logLabel)")
        out.append("started \(DateFormatter.matrixClock.string(from: startedAt)) · \(rows.count) row(s) · \(elapsed)s total · os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("RECONNECT: required per row — the provider reads its addresses only in startTunnel(options:), so a settings change with the tunnel up does nothing.")
        out.append(networkStateLine(entriesAtStart))
        if let abortNote { out.append("⚠️ RUN ENDED EARLY — \(abortNote). Rows below the last one were never attempted.") }

        if !interfaceDumpAtStart.isEmpty {
            out.append("")
            out.append(contentsOf: interfaceDumpAtStart)
        }

        // ── the compact table ────────────────────────────────────────────────────────────────────
        out.append("")
        out.append(headerRow())
        out.append(String(repeating: "-", count: headerRow().count))
        for (index, row) in rows.enumerated() { out.append(tableRow(index: index + 1, row: row)) }

        // ── per-row verdicts ─────────────────────────────────────────────────────────────────────
        out.append("")
        for (index, row) in rows.enumerated() {
            out.append("[\(index + 1)] \(row.candidate.title) — \(row.candidate.configDescription)")
            out.append("     \(row.verdict)")
            if let installedOn = row.installedOn { out.append("     interface: \(installedOn)") }
            if !row.lockdowndNote.isEmpty { out.append("     \(row.lockdowndNote)") }
            if let deviceIP = row.candidate.deviceIP, let mask = row.candidate.mask,
               let alignment = TunnelConfigMatrix.slashThirtyAlignment(deviceIP: deviceIP,
                                                                       targetIP: row.candidate.targetIP,
                                                                       mask: mask) {
                out.append("     ⚠️ subnet alignment: \(alignment)")
            }
            if let target = row.target { out.append("     target \(target.logLine)") }
            if let control = row.loopbackControl { out.append("     control \(control.logLine)") }
            if let control = row.interfaceControl { out.append("     control(interface) \(control.logLine)") }
            out.append("     why this row exists: \(row.candidate.rationale)")
        }

        out.append("")
        out.append("RESTORE: \(restoreNote)")
        out.append(contentsOf: bottomLines(mode: mode, rows: rows))
        out.append("=== END TUNNEL CONFIG MATRIX ===")
        return out
    }

    nonisolated private static func networkStateLine(_ entries: [NetworkInterfaceAddress]) -> String {
        func find(_ name: String) -> String {
            guard let e = entries.first(where: { $0.name == name && $0.isIPv4 && $0.isUp }) else { return "\(name) down" }
            return "\(name) \(e.cidr ?? e.address)"
        }
        let hotspot = entries.contains { $0.name == "bridge100" && $0.isUp && $0.isIPv4 }
        return "network at start: \(find("en0")) · \(find("pdp_ip0")) · hotspot bridge100 \(hotspot ? "UP" : "DOWN")"
    }


    nonisolated private static func headerRow() -> String {
        pad("#", matrixColumnWidths.row) + " " + pad("CONFIG", matrixColumnWidths.config) + " " + pad("INSTALL", matrixColumnWidths.install) + " "
            + pad("TARGET", matrixColumnWidths.target) + " " + pad("CTRL LOOPBACK", matrixColumnWidths.controlA) + " " + pad("CTRL IFACE", matrixColumnWidths.controlB) + " ms"
    }

    nonisolated private static func tableRow(index: Int, row: TunnelConfigMatrixRow) -> String {
        // The SYMBOLIC errno, not the number and not the long label. "ECONNREFUSED" is what every
        // write-up about this problem actually says, it is unambiguous, and it fits the column —
        // "ADDRESS UNAVAILABLE" did not, and a truncated verdict in the one table people read is a
        // way to be wrong quietly. The full label, the number and strerror's text are all still on
        // the per-row detail line below the table.
        func outcome(_ result: EndpointProbeResult?) -> String {
            guard let result else { return "-" }
            if result.outcome == .connected { return "CONNECTED" }
            return result.errnoValue == 0 ? result.outcome.label : result.errnoName
        }
        let install = row.skippedReason != nil ? "SKIPPED" : row.installState.label
        return pad("\(index)", matrixColumnWidths.row) + " "
            + pad(row.candidate.configDescription, matrixColumnWidths.config) + " "
            + pad(install, matrixColumnWidths.install) + " "
            + pad(outcome(row.target), matrixColumnWidths.target) + " "
            + pad(outcome(row.loopbackControl), matrixColumnWidths.controlA) + " "
            + pad(outcome(row.interfaceControl), matrixColumnWidths.controlB) + " "
            + String(Int(row.elapsedSeconds * 1000))
    }

    nonisolated private static func pad(_ s: String, _ width: Int) -> String {
        if s.count >= width { return String(s.prefix(width)) }
        return s + String(repeating: " ", count: width - s.count)
    }

    /// The sentences the run exists to produce. Written for someone deciding what to do next, not for
    /// someone who enjoys errno tables.
    nonisolated static func bottomLines(mode: Mode, rows: [TunnelConfigMatrixRow]) -> [String] {
        var out: [String] = []
        let measured = rows.filter { $0.skippedReason == nil && $0.target != nil }
        let trustworthy = measured.filter { $0.installState.isTrustworthy }
        // CONTROLS ARE EXCLUDED FROM THE ANSWER SET. 127.0.0.1 connects on this phone in 0 ms with
        // Wi-Fi off — that is exactly why it is here — and counting it would print "1 configuration
        // CONNECTED" on every single run, which is the one sentence in this report nobody may read
        // wrongly. Its result is stated separately, as a statement about the rig.
        let answerable = trustworthy.filter { !$0.candidate.isControl }
        let winners = answerable.filter { $0.targetConnected }
        let skipped = rows.filter { $0.skippedReason != nil }
        let invalid = measured.filter { !$0.installState.isTrustworthy }

        if !skipped.isEmpty {
            out.append("SKIPPED \(skipped.count) row(s): " + skipped.map { "\($0.candidate.title) (\($0.skippedReason ?? "?"))" }.joined(separator: "; "))
        }
        if !invalid.isEmpty {
            out.append("INVALID \(invalid.count) row(s) — the configuration did not install, so their errnos describe some OTHER config: "
                       + invalid.map(\.candidate.title).joined(separator: ", "))
        }

        // The daemon control decides whether the whole run is even readable.
        let daemonAnswered = measured.contains { $0.loopbackControl?.outcome == .connected || ($0.candidate.isControl && $0.targetConnected) }
        if measured.isEmpty {
            // nothing to say about the rig
        } else if daemonAnswered {
            out.append("CONTROL OK: 127.0.0.1:49152 accepted a connection during this run, so remotepairingd was alive and listening throughout. That is the rig working — it is NOT an answer to the cellular question, and it is deliberately excluded from the bottom line below.")
        } else {
            out.append("⚠️ CONTROL FAILED: 127.0.0.1:49152 did not accept a connection on ANY row. remotepairingd was not listening during this run, so every NO ANSWER below is meaningless — fix that first (reboot, or re-run after the developer tunnel has been used once) and run the matrix again.")
        }

        if !winners.isEmpty {
            out.append("BOTTOM LINE: \(winners.count) configuration(s) CONNECTED to port 49152 — "
                       + winners.map { "\($0.candidate.title) [\($0.candidate.configDescription)]" }.joined(separator: ", ")
                       + ". Use those addresses. Re-run once more to confirm it reproduces before building on it.")
            return out
        }

        let outcomes = Set(answerable.compactMap { $0.target?.outcome })
        if answerable.isEmpty {
            out.append("BOTTOM LINE: nothing was measured under a verified configuration. Read the SKIPPED/INVALID lines above — this run answered no question at all.")
            return out
        }
        if outcomes == [.noAnswer] {
            var s = "BOTTOM LINE: every verified configuration BLACKHOLED — the SYN left and nothing came back, no RST and no route error, on \(answerable.count) different address plans."
            if mode == .auto {
                s += " That is a statement about the PROVIDER, not about the addresses: an address hypothesis cannot be refuted by a tunnel that swallows every packet. Re-run in Assisted mode against LocalDevVPN's tunnel, which is the one measured working, before concluding anything about these addresses."
            } else {
                s += " The tunnel carrying these rows is delivering nothing, so the addresses remain untested."
            }
            out.append(s)
            return out
        }
        if outcomes == [.refused] {
            out.append("BOTTOM LINE: every verified configuration was REFUSED (61) — packets reached the daemon and it sent a RST on all of them. Routing is fine everywhere; this is the source-address policy, and no address in this matrix satisfies it.")
            return out
        }
        if outcomes == [.noRoute] {
            out.append("BOTTOM LINE: every verified configuration had NO ROUTE (51/65) — not one packet left the phone. Nothing here tests the daemon's policy; the routing has to work before the address question can even be asked.")
            return out
        }

        // Mixed. The comparison is the finding, so name the groups explicitly.
        func group(_ outcome: EndpointProbeOutcome) -> [String] {
            answerable.filter { $0.target?.outcome == outcome }.map(\.candidate.title)
        }
        var parts: [String] = []
        for outcome in [EndpointProbeOutcome.refused, .noRoute, .noAnswer, .addressUnavailable, .otherError] {
            let names = group(outcome)
            if !names.isEmpty { parts.append("\(outcome.label): \(names.joined(separator: ", "))") }
        }
        out.append("BOTTOM LINE: no configuration connected, and the failures DIFFER by address — " + parts.joined(separator: " · ")
                   + ". A difference between rows is the useful signal here: whatever separates the REFUSED group from the NO ROUTE group is the variable that matters.")
        return out
    }
}

extension DateFormatter {
    static let matrixClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
