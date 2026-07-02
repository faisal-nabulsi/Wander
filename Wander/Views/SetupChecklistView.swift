//
//  SetupChecklistView.swift
//  Wander
//
//  A quick "are you ready to spoof?" checklist shown at the start of a session:
//  pairing file present, tunnel/VPN reachable, Developer Disk Image mounted, and
//  Developer Mode on. Green check / amber cross per item, with a re-check button.
//

import SwiftUI

@MainActor
final class SetupChecker: ObservableObject {
    static let shared = SetupChecker()

    @Published private(set) var hasPairing = false
    @Published private(set) var mountState: MountCheckResult = .unreachable
    @Published private(set) var isChecking = false
    @Published private(set) var hasRunOnce = false

    var reachable: Bool { mountState != .unreachable }
    var mounted: Bool { mountState == .mounted }
    var allReady: Bool { hasPairing && mounted }

    func check() {
        isChecking = true
        hasPairing = FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
        // getMountedDeviceCount() reaches over the tunnel — run it off the main actor.
        Task.detached(priority: .userInitiated) {
            let result = checkMountStatus()
            await MainActor.run {
                self.mountState = result
                self.isChecking = false
                self.hasRunOnce = true
            }
        }
    }
}

struct SetupChecklistView: View {
    @ObservedObject var checker = SetupChecker.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairingImporter = false
    @State private var importResult: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

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
                                : "Open LocalDevVPN (or the Wander Tunnel) and connect.",
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
                            detail: checker.mounted
                                ? "On."
                                : "Settings → Privacy & Security → Developer Mode → on, then restart.",
                            ok: checker.mounted,          // if the DDI is mounted, Developer Mode is on
                            checking: false
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
            .onAppear { if !checker.hasRunOnce { checker.check() } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { checker.check() }
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
