//
//  SetupChecklistView.swift
//  Wander
//
//  A quick "are you ready to spoof?" checklist shown at the start of a session:
//  pairing file present, tunnel/VPN reachable, Developer Disk Image mounted, and
//  Developer Mode on. Green check / amber cross per item, with a re-check button.
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

struct SetupChecklistView: View {
    @ObservedObject var checker = SetupChecker.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairingImporter = false
    @State private var importResult: (text: String, isError: Bool)?

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
                    VStack(spacing: 0) {
                        row(
                            title: "Pairing file",
                            detail: checker.hasPairing
                                ? "Ready."
                                : "Import it in Settings → Import pairing file.",
                            ok: checker.hasPairing,
                            checking: false
                        )
                        rowDivider
                        row(
                            title: "Tunnel connected",
                            detail: checker.reachable
                                ? "Your device is reachable."
                                : "Connect LocalDevVPN. On Wi-Fi it just works; no Wi-Fi? Turn on Airplane Mode first, then connect it.",
                            ok: checker.reachable,
                            checking: checker.isChecking
                        )
                        rowDivider
                        row(
                            title: "Developer Disk Image",
                            detail: checker.mounted
                                ? "Mounted."
                                : (checker.reachable ? "Mounts automatically once connected — give it a moment." : "Mounts after the tunnel is up."),
                            ok: checker.mounted,
                            checking: checker.isChecking
                        )
                        rowDivider
                        row(
                            title: "Developer Mode",
                            detail: checker.developerModeOK
                                ? "On."
                                : "Turn it on: Settings → Privacy & Security → Developer Mode → on, then restart.",
                            ok: checker.developerModeOK,
                            checking: checker.isChecking
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

    private func row(title: String, detail: String, ok: Bool, checking: Bool) -> some View {
        HStack(spacing: 14) {
            Group {
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .orange)
                        .font(.title3)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
