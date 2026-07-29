//
//  SetupChecklistView.swift
//  Wander
//
//  A quick "are you ready to spoof?" checklist shown at the start of a session, in the order the
//  pieces actually depend on each other: Developer Mode → pairing file → tunnel → Developer Disk
//  Image. Green check / amber cross / grey "waiting" per item, with a re-check button.
//
//  The three states matter. Every row below the first blocker used to show its own red X, because
//  they ALL fail when the tunnel is down — so a user with one real problem saw four, and went off
//  changing settings that were already correct. A row whose prerequisite isn't met (or that we
//  can't probe yet) now reads as waiting, so there's exactly one thing to fix at a time.
//

import SwiftUI
import Combine

@MainActor
final class SetupChecker: ObservableObject {
    static let shared = SetupChecker()

    @Published private(set) var hasPairing = false
    @Published private(set) var mountState: MountCheckResult = .unreachable
    @Published private(set) var developerMode: DeveloperModeState = .unknown
    @Published private(set) var isChecking = false
    @Published private(set) var hasRunOnce = false

    /// Guards against overlapping probes independently of the `isChecking` spinner flag, so a
    /// silent background poll can't stack on top of an in-flight check.
    private var inFlight = false

    var reachable: Bool { mountState != .unreachable }
    // The image-mounter device count is unreliable for personalized DDIs on iOS 17+
    // (returns 0 even when mounted), so also trust positive proof: a real simulation
    // has succeeded and the tunnel is currently reachable.
    var mounted: Bool { mountState == .mounted || (reachable && DeviceReadiness.ddiProven) }
    // Developer Mode is queried directly from the device; if that query isn't available,
    // fall back to inferring it from a mounted DDI (the DDI can't mount with it off).
    var developerModeOK: Bool {
        switch developerMode {
        case .on: return true
        case .off: return false
        case .unknown: return mounted
        }
    }
    var allReady: Bool { hasPairing && mounted }

    /// Re-probe readiness. `silent` skips the spinner (used by the auto-poll so the rows update in
    /// place without flickering to a ProgressView every couple seconds).
    func check(silent: Bool = false) {
        guard !inFlight else { return }
        inFlight = true
        if !silent { isChecking = true }
        hasPairing = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
        // These reach over the tunnel and can hang when there's no VPN, so cap them with a
        // timeout — the checklist must always resolve to a red X, never spin forever.
        Task {
            let (mount, devMode) = await Self.withTimeout(
                seconds: 8,
                fallback: (MountCheckResult.unreachable, DeveloperModeState.unknown)
            ) {
                await Task.detached(priority: .userInitiated) {
                    (checkMountStatus(), checkDeveloperMode())
                }.value
            }
            self.mountState = mount
            self.developerMode = devMode
            self.inFlight = false
            if !silent { self.isChecking = false }
            self.hasRunOnce = true
        }
    }

    /// Run `operation`, but give up with `fallback` after `seconds` (the tunnel probes can
    /// block indefinitely when there's no route to the device).
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            for await first in group {
                return first ?? fallback
            }
            return fallback
        }
    }
}

/// How a checklist row reads. `.waiting` is the one that earns its keep: it means "we can't know yet /
/// your turn hasn't come", which is NOT the same as "this is wrong" — showing it as a red X is what
/// sent people toggling Developer Mode when the only real problem was a disconnected tunnel.
private enum SetupRowStatus {
    case ok, blocked, waiting

    var icon: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .blocked: return "xmark.circle.fill"
        case .waiting: return "clock"
        }
    }

    var tint: Color {
        switch self {
        case .ok: return .green
        case .blocked: return .orange
        case .waiting: return .secondary
        }
    }
}

struct SetupChecklistView: View {
    @ObservedObject var checker = SetupChecker.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairingImporter = false
    @State private var importResult: (text: String, isError: Bool)?
    @ObservedObject private var reachability = NetworkReachability.shared
    // Same key ShortcutRunner persists to — read here (rather than through ShortcutRunner.ready) so the
    // row re-renders the moment a run's x-success/x-error flips it.
    @AppStorage("shortcutsReady") private var shortcutsReady = false

    /// While the sheet is open and not everything is green, re-probe on a gentle cadence so the
    /// checklist resolves itself — the tunnel handshake and DDI mount both complete a beat AFTER
    /// LocalDevVPN connects, so a single on-appear probe races them. Guarded to a no-op once ready.
    private let pollTimer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    if GslocMode.enabled {
                        gslocNotice
                    } else {
                    // Dependency order: each row is only actionable once the one above it is green,
                    // so the FIRST non-green row is always the thing to go fix.
                    VStack(spacing: 0) {
                        row(
                            title: "Developer Mode",
                            detail: developerModeDetail,
                            status: developerModeStatus,
                            // Don't spin on a row we already know we can't answer — the spinner
                            // implies a probe that will resolve, and this one won't until the
                            // tunnel is up. But the FIRST probe hasn't answered anything yet, so
                            // keep spinning through it rather than asserting "can't check yet"
                            // above a Tunnel row that's still visibly probing.
                            checking: checker.isChecking && (developerModeStatus != .waiting || !checker.hasRunOnce),
                            // Only while waiting: the note's advice is "connect the tunnel and the row
                            // appears", which is nonsense in the .blocked state — that state is only
                            // reachable when the device ANSWERED the query, i.e. the tunnel is already
                            // up and the row is already in Settings.
                            note: developerModeStatus == .waiting ? developerModeInvisibleNote : nil
                        )
                        rowDivider
                        row(
                            title: "Pairing file",
                            detail: checker.hasPairing
                                ? "Ready."
                                : "Import it in Settings → Import pairing file.",
                            status: checker.hasPairing ? .ok : .blocked,
                            checking: false
                        )
                        rowDivider
                        row(
                            title: "Tunnel connected",
                            detail: tunnelDetail,
                            status: tunnelStatus,
                            checking: checker.isChecking,
                            note: tunnelStatus == .blocked && !shortcutsReady ? connectShortcutRecipe : nil,
                            // The one-tap connect that used to live only in gs-loc Quick Controls: runs the
                            // user's "Wander Connect VPN" shortcut (Set VPN → LocalDevVPN → Open Wander) so
                            // nobody has to leave the app and hunt for LocalDevVPN by hand.
                            action: tunnelStatus == .blocked
                                ? ("Connect LocalDevVPN", "bolt.fill", {
                                    ShortcutRunner.run(name: ShortcutRunner.vpnConnectName, successHost: "vpnconnected")
                                })
                                : nil
                        )
                        rowDivider
                        row(
                            title: "Developer Disk Image",
                            detail: ddiDetail,
                            status: ddiStatus,
                            checking: checker.isChecking && checker.reachable
                        )
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // One-tap fixes for whatever isn't ready yet.
                    if !checker.allReady {
                        VStack(spacing: 10) {
                            if !checker.hasPairing {
                                Button {
                                    showPairingImporter = true
                                } label: {
                                    Label("Import pairing file", systemImage: "doc.badge.plus")
                                        .frame(maxWidth: .infinity).frame(height: 30)
                                }
                                .buttonStyle(.borderedProminent).tint(Wander.brand).controlSize(.large)
                            }
                            if !checker.reachable {
                                Link(destination: URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!) {
                                    Label("Get the tunnel app (LocalDevVPN)", systemImage: "arrow.down.circle")
                                        .frame(maxWidth: .infinity).frame(height: 30)
                                }
                                .buttonStyle(.bordered).controlSize(.large)
                            }
                            if let m = importResult {
                                Label(m.text, systemImage: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(m.isError ? .red : .green)
                            }
                        }
                    }

                    if checker.allReady {
                        Label("You're all set — go spoof your location.", systemImage: "checkmark.seal.fill")
                            .font(.subheadline).foregroundStyle(.green)
                    }

                    Button {
                        checker.check()
                    } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity).frame(height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(checker.isChecking)
                    } // end !GslocMode.enabled
                }
                .padding()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(checker.allReady ? "Done" : "Skip") { dismiss() }
                }
            }
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
            .onAppear { kickTunnelIfNeeded(); checker.check() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { kickTunnelIfNeeded(); checker.check() }
            }
            // Re-probe the instant Wander's own tunnel handshake completes (it comes up a beat after
            // the LocalDevVPN route), so "Tunnel connected" flips green on its own — no manual Re-check.
            .onReceive(TunnelManager.shared.$isConnected) { connected in
                if connected { checker.check() }
            }
            // Backstop: keep re-checking (silently) while anything's still red, and nudge the tunnel
            // up if the pairing file is present but we're not reachable yet. Resolves the DDI's
            // "give it a moment" and self-heals if LocalDevVPN connects while Wander is foregrounded.
            .onReceive(pollTimer) { _ in
                guard !checker.allReady else { return }
                kickTunnelIfNeeded()
                checker.check(silent: true)
            }
            .fileImporter(
                isPresented: $showPairingImporter,
                allowedContentTypes: PairingFileStore.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
        }
    }

    /// If the pairing file is present but Wander's tunnel isn't up yet, (re)start it. TunnelManager
    /// guards against duplicate/parallel starts, so calling this repeatedly is safe — it lets the
    /// checklist bring the tunnel up (and then mount the DDI) on its own once LocalDevVPN is connected,
    /// instead of leaving the user staring at a red "Tunnel connected" until they tap Re-check.
    private func kickTunnelIfNeeded() {
        // In PoGo (gs-loc) mode Wander spoofs through Shadowrocket, not the dev tunnel — don't wake
        // LocalDevVPN (iOS allows only one VPN at a time, so it would fight the proxy).
        guard !GslocMode.enabled else { return }
        if checker.hasPairing && !checker.reachable {
            startTunnelInBackground(showErrorUI: false)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                importResult = ("Pairing file imported", false)
                startTunnelInBackground()
                checker.check()
            } catch {
                importResult = ("Import failed: \(error.localizedDescription)", true)
            }
        case .failure(let error):
            importResult = ("Import failed: \(error.localizedDescription)", true)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.largeTitle)
                .foregroundStyle(Wander.brand)
            Text("Before you spoof")
                .font(.title2.weight(.semibold))
            Text("Wander needs these in place for location simulation to work.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }

    /// Developer Mode is queried over the SAME connection everything else needs, so "unknown" almost
    /// always means "we couldn't ask", not "it's off". Reporting that as a failure told users to flip a
    /// switch that was already on (and cost an expert an afternoon on a real device this week), so an
    /// unanswerable check reads as waiting. A genuine .off is still an honest red X.
    private var developerModeStatus: SetupRowStatus {
        switch checker.developerMode {
        case .on: return .ok
        case .off: return .blocked
        // A mounted DDI is proof Developer Mode is on — it can't mount otherwise — so trust that
        // before falling back to "can't tell yet". (Same inference as SetupChecker.developerModeOK.)
        case .unknown: return checker.mounted ? .ok : .waiting
        }
    }

    private var developerModeDetail: String {
        switch developerModeStatus {
        case .ok: return "On."
        case .blocked: return "Turn it on: Settings → Privacy & Security → Developer Mode → on, then restart."
        case .waiting: return "Can't check yet — connect the tunnel first."
        }
    }

    /// The most-reported dead end: people open Settings → Privacy & Security and there IS no Developer
    /// Mode row, so they assume they're on the wrong iOS or the wrong screen. iOS only reveals it once a
    /// developer-signed app has asked for it — say so instead of letting them hunt.
    ///
    /// Only shown on the `.waiting` row (see the call site): once the check reports a genuine `.off`,
    /// the device has answered us over the tunnel, which means the row already exists in Settings — and
    /// telling that user to "connect the tunnel" would send them to fix something that's working.
    private var developerModeInvisibleNote: String {
        "No “Developer Mode” row in Settings → Privacy & Security? iOS only shows it after a developer-signed app has asked for it. Connect the tunnel once and it appears — then toggle it on and restart."
    }

    private var tunnelStatus: SetupRowStatus {
        if checker.reachable { return .ok }
        // Without the pairing file there's nothing to connect TO yet, so this is the next step, not a
        // second failure.
        return checker.hasPairing ? .blocked : .waiting
    }

    private var tunnelDetail: String {
        switch tunnelStatus {
        case .ok: return "Your device is reachable."
        case .waiting: return "Import your pairing file first — the tunnel needs it."
        case .blocked:
            return reachability.hasWiFi
                ? "Open LocalDevVPN and connect — on Wi-Fi it comes up on its own."
                : "No Wi-Fi detected. Open LocalDevVPN and connect; if it won't come up, turn on Airplane Mode first, then connect."
        }
    }

    /// The DDI mounts itself a beat AFTER the tunnel comes up, so while the device is unreachable this
    /// row is waiting on somebody else's problem, not reporting its own. But "waits forever" was a dead
    /// end of its own: with the tunnel and Developer Mode both green and the mount still failing (the
    /// image files never finished downloading, most often), the row sat on a clock, `allReady` stayed
    /// false, and the setup sheet re-presented every launch with nothing to act on. `.notMounted` — as
    /// opposed to `.unreachable` — means the device ANSWERED, so once we've actually probed it that's a
    /// real, reportable failure.
    private var ddiStatus: SetupRowStatus {
        if checker.mounted { return .ok }
        guard checker.hasRunOnce, checker.reachable, checker.mountState == .notMounted else { return .waiting }
        return .blocked
    }

    private var ddiDetail: String {
        switch ddiStatus {
        case .ok: return "Mounted."
        case .blocked:
            return "Your device answered, but the image isn't mounted. Wander re-downloads the image files at launch — check your internet, then force-quit Wander and reopen it to retry."
        case .waiting:
            return checker.reachable
                ? "Mounts automatically once connected — give it a moment."
                : "Mounts after the tunnel is up."
        }
    }

    /// Shown under the one-tap button until a run reports success: the button invokes the shortcut BY
    /// NAME, so a missing/renamed one is the only way it can fail, and the fix is a 3-step recipe.
    ///
    /// Caveat worth knowing: `shortcutsReady` is a single global "some Wander shortcut is installed"
    /// flag (gs-loc onboarding sets it after importing the FLUSH shortcut), not a per-shortcut one, so a
    /// gs-loc user who never made “Wander Connect VPN” sees the button without this recipe
    /// on the first tap. It self-heals — the run's x-error flips the flag back to false and the recipe
    /// appears — and a per-shortcut flag would mean changing ShortcutRunner's persisted contract.
    private var connectShortcutRecipe: String {
        "First time? The button runs a shortcut named exactly “\(ShortcutRunner.vpnConnectName)”. Make it once in Shortcuts: Set VPN → LocalDevVPN → On, then Open App → Wander."
    }

    /// Shown instead of the dev-tunnel checklist when PoGo (gs-loc) mode is on — those steps (pairing,
    /// LocalDevVPN, DDI, Developer Mode) don't apply, since gs-loc spoofs through Shadowrocket.
    private var gslocNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("setup.gsloc.title", fallback: "PoGo (gs-loc) mode is on"),
                  systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text(L("setup.gsloc.body",
                   fallback: "This checklist is for the LocalDevVPN dev tunnel, which gs-loc mode doesn't use — it spoofs through Shadowrocket instead. You don't need the pairing file, tunnel, or Developer Mode here. Set it up in Settings → Experimental → “Set up gs-loc mode,” or turn PoGo mode off there to go back to normal spoofing."))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// One checklist line. `note` is the extra "why you can't find that setting" paragraph, `action` the
    /// optional one-tap fix that belongs to this row (so the fix sits ON the problem, not in a separate
    /// pile of buttons the user has to match up).
    private func row(
        title: String,
        detail: String,
        status: SetupRowStatus,
        checking: Bool,
        note: String? = nil,
        action: (title: String, icon: String, run: () -> Void)? = nil
    ) -> some View {
        // Top-aligned: notes and the inline button make these rows tall, and a vertically centered
        // status icon drifts away from the title it describes.
        HStack(alignment: .top, spacing: 14) {
            Group {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: status.icon)
                        .foregroundStyle(status.tint)
                        .font(.title3)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
                if let action {
                    Button(action: action.run) {
                        Label(action.title, systemImage: action.icon)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Wander.brand)
                    .padding(.top, 6)
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}

#Preview {
    SetupChecklistView()
}
