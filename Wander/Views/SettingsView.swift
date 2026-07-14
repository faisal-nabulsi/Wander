//  SettingsView.swift
//  Wander
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let localDevVPN = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let githubRepo = URL(string: "https://github.com/faisal-nabulsi/Wander")!
    static let discordInvite = URL(string: "https://discord.gg/gfHdsRXUVA")!
    static let vpn = URL(string: "https://wanderspoofer.com/vpn/")!
}

struct SettingsView: View {
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("useMph") private var useMph = false
    @AppStorage("jitterEnabled") private var jitterEnabled = false
    @AppStorage("jitterRadius") private var jitterRadius = 1.5
    @AppStorage(SavedPlacesSync.enabledKey) private var syncPlacesEnabled = false
    @StateObject private var tunnel = WanderTunnel.shared

    @State private var isShowingPairingFilePicker = false
    @State private var pairingImportResult: (text: String, isError: Bool)?
    @State private var showSetupCheck = false
    @State private var showLogin = false
    @State private var twoFactorCode = ""
    @ObservedObject private var trial = TrialManager.shared
    @ObservedObject private var license = License.shared
    @State private var showPaywall = false
    @ObservedObject private var updater = WanderUpdater.shared
    @ObservedObject private var wanderAccount = WanderAccount.shared
    @ObservedObject private var selfRefresh = SelfRefreshService.shared
    @ObservedObject private var proAccount = WanderProAccount.shared
    @State private var showProSignIn = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image("WanderLogo")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                            VStack(spacing: 2) {
                                Text("Wander").font(.title2.weight(.semibold))
                                Text("Your location, anywhere").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section {
                    if license.isLicensed {
                        Label("Wander Pro — active", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        if let expiry = license.expiry {
                            Text("Renews/expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        trialRow("Teleports", trial.teleportsUsed, TrialManager.maxTeleports)
                        trialRow("Joystick", trial.joystickSecondsUsed / 60, TrialManager.maxJoystickSeconds / 60, unit: " min")
                        trialRow("Routes", trial.routesUsed, TrialManager.maxRoutes)
                        Button {
                            showPaywall = true
                        } label: {
                            Label("Get Wander Pro", systemImage: "sparkles")
                        }
                    }
                } header: {
                    Text("Wander Pro")
                } footer: {
                    Text(license.isLicensed
                         ? "Thanks for supporting Wander — all limits are lifted."
                         : "Free trial: 5 teleports, 30 minutes of joystick, and 3 routes. Unlock unlimited use with a license.")
                }

                syncSection

                Section {
                    if selfRefresh.needsReSignIn {
                        Label("Apple sign-in expired — sign in again so Wander can keep refreshing.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                    Button {
                        showLogin = true
                    } label: {
                        Label(wanderAccount.isSignedIn ? "Apple ID — signed in ✓" : "Sign in to Apple ID", systemImage: "person.badge.key")
                    }
                    if !wanderAccount.status.isEmpty {
                        Text(wanderAccount.status)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if wanderAccount.isSignedIn {
                        Button(role: .destructive) {
                            wanderAccount.signOut()
                        } label: {
                            Label("Sign out of Apple ID", systemImage: "person.badge.minus")
                        }
                    }
                    Button {
                        Task { await selfRefresh.refresh() }
                    } label: {
                        Label("Run self-refresh (sign + install)", systemImage: "checkmark.seal")
                    }
                    .disabled(selfRefresh.isRefreshing)
                    if let s = selfRefresh.status {
                        Text(s)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Self-refresh")
                } footer: {
                    Text("Signs Wander with your Apple ID and reinstalls it over the tunnel — resets the 7-day clock with no computer. Your Apple ID stays signed in (stored securely in the Keychain); Apple may occasionally ask for a 2FA code again. The app closes itself when the refresh installs — just reopen it.")
                }

                Section {
                    HStack {
                        Text("Current version")
                        Spacer()
                        Text("\(updater.currentVersion) (\(updater.currentBuild))")
                            .foregroundStyle(.secondary)
                    }
                    if let m = updater.available {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(updater.needsUserAction ? "Update ready — tap to install"
                                                          : "Update available — v\(m.version)",
                                  systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(Wander.brand)
                                .font(updater.needsUserAction ? .body.weight(.semibold) : .body)
                            if let notes = m.notes, !notes.isEmpty {
                                Text(notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            runUpdate()
                        } label: {
                            Label(updater.needsUserAction ? "Install update now" : "Download & install update",
                                  systemImage: "square.and.arrow.down")
                        }
                        .disabled(updater.isBusy)
                    } else {
                        Button {
                            Task { await updater.check() }
                        } label: {
                            Label("Check for updates", systemImage: "arrow.clockwise")
                        }
                        .disabled(updater.isBusy)
                    }
                    if !updater.status.isEmpty {
                        Text(updater.status)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } header: {
                    Text("Software Update")
                } footer: {
                    Text("Wander updates itself over the tunnel using your Apple ID — no computer. You'll need to be signed in (above) and connected. The app relaunches when the update installs.")
                }

                Section {
                    HStack {
                        Image(systemName: tunnel.status == .connected ? "checkmark.shield.fill" : "shield.slash")
                            .foregroundStyle(tunnel.status == .connected ? Color.green : Color.secondary)
                        Text(tunnel.status.title)
                        Spacer()
                        Button(tunnel.status == .connected || tunnel.status == .connecting ? "Disconnect" : "Connect") {
                            tunnel.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Wander.brand)
                    }
                    Button {
                        showSetupCheck = true
                    } label: {
                        Label("Setup checklist", systemImage: "checklist")
                    }
                } header: {
                    Text("Wander Tunnel")
                } footer: {
                    if let e = tunnel.lastError {
                        Text("Couldn't start the built-in tunnel (\(e)).\n\niOS restricts VPNs to paid Apple accounts, so on a free install this can't activate — use the LocalDevVPN app instead. No Wi-Fi? Turn on Airplane Mode, then connect LocalDevVPN.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Built-in on-device tunnel. iOS restricts VPNs to paid Apple accounts, so on a free install use the LocalDevVPN app instead — on Wi-Fi, or on cellular by turning on Airplane Mode first, then connecting it.")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        SimulationSession.shared.stopAll()
                    } label: {
                        Label("Stop simulating location", systemImage: "stop.circle")
                    }

                    HStack {
                        Label("Speed units", systemImage: "speedometer")
                        Spacer()
                        Picker("Speed units", selection: $useMph) {
                            Text("km/h").tag(false)
                            Text("mph").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }

                    Toggle(isOn: $jitterEnabled) {
                        Label("Simulated jitter (natural drift)", systemImage: "dot.radiowaves.left.and.right")
                    }
                    if jitterEnabled {
                        HStack {
                            Text("Drift").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $jitterRadius, in: 0.5...5, step: 0.5)
                            Text(String(format: "%.1f m", jitterRadius))
                                .font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                } header: {
                    Text("Location")
                }

                Section {
                    Toggle(isOn: $reminderEnabled) {
                        Label("Remind me if it may have paused", systemImage: "bell.badge")
                    }
                    .onChange(of: reminderEnabled) { _, isOn in
                        if isOn {
                            SimulationSession.shared.scheduleReminderIfEnabled()
                        } else {
                            SimulationSession.shared.cancelReminder()
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("iOS pauses a simulation after about 2 hours in the background. When this is on, Wander reminds you to reopen it — but only while you're actively simulating a location.")
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Plays inaudible audio so iOS keeps the app running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled { BackgroundAudioManager.shared.start() }
                        else { BackgroundAudioManager.shared.stop() }
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location")
                            Text("Uses low-accuracy location to stay alive when an activity needs it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                } header: {
                    Text("Keep simulation alive")
                }

                vpnSection

                Section {
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label("Download LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("Help")
                } footer: {
                    Text("The tunnel connects Wander to your device. Use the LocalDevVPN app — on Wi-Fi, or without Wi-Fi by turning on Airplane Mode first, then connecting LocalDevVPN.")
                }

                Section {
                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label("Import pairing file", systemImage: "doc.badge.plus")
                    }
                    if let msg = pairingImportResult {
                        Label(msg.text, systemImage: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(msg.isError ? .red : .green)
                    }
                } footer: {
                    Text("Only needed if pairing didn't set up automatically — import this device's pairing file by hand.")
                }

                Section {
                    Link(destination: SettingsLinks.githubRepo) {
                        Label("⭐ Star Wander on GitHub", systemImage: "star.fill")
                    }
                    Link(destination: SettingsLinks.discordInvite) {
                        Label("💬 Join our Discord", systemImage: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255))
                    }
                } header: {
                    Text("Community")
                } footer: {
                    Text("Wander is open source. Star the repo on GitHub to help others find it, and join our Discord to share tips and get help.")
                }

                Section {
                    Text(versionFooter)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePairingImport(result)
        }
        .sheet(isPresented: $showSetupCheck) {
            SetupChecklistView()
        }
        .sheet(isPresented: $showLogin) {
            WanderLoginView()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(onClose: { showPaywall = false })
        }
        .sheet(isPresented: $showProSignIn) {
            WanderAccountSignInView(onSuccess: {
                showProSignIn = false
                // Signed in + Pro → if the toggle is on, kick an immediate first sync.
                SavedPlacesSync.shared.syncIfEnabled()
            })
        }
        .alert("Two-Factor Code", isPresented: $wanderAccount.awaiting2FA) {
            TextField("6-digit code", text: $twoFactorCode)
                .keyboardType(.numberPad)
            Button("Submit") {
                wanderAccount.submitTwoFactorCode(twoFactorCode.trimmingCharacters(in: .whitespaces))
                twoFactorCode = ""
            }
            Button("Cancel", role: .cancel) {
                wanderAccount.submitTwoFactorCode(nil)
                twoFactorCode = ""
            }
        } message: {
            Text("Enter the 6-digit code Apple sent to your trusted device. No popup? Get it from Settings → your name → Sign-In & Security → Get Verification Code.")
        }
    }

    // MARK: - Multi-device sync (Pro, opt-in)

    @ViewBuilder private var syncSection: some View {
        Section {
            if !license.isLicensed {
                // Free / unlicensed: the toggle is locked and routes to the paywall.
                Button {
                    showPaywall = true
                } label: {
                    HStack {
                        Label("Sync places across devices", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    }
                }
            } else {
                Toggle(isOn: $syncPlacesEnabled) {
                    Label("Sync places across devices", systemImage: "arrow.triangle.2.circlepath")
                }
                .onChange(of: syncPlacesEnabled) { _, isOn in
                    if isOn { SavedPlacesSync.shared.syncIfEnabled() }
                }
                .tint(Wander.brand)

                if syncPlacesEnabled {
                    if proAccount.isSignedIn {
                        Label("Signed in as \(proAccount.email ?? "your Wander account")",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        // Pro via offline key but no Wander account: sync needs a signed-in
                        // account to know WHERE to store. Prompt to sign in.
                        Label("Sign in to your Wander account to start syncing.",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button {
                            showProSignIn = true
                        } label: {
                            Label("Sign in to Wander account", systemImage: "person.badge.key")
                        }
                    }
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(license.isLicensed
                 ? "When on, your saved places are mirrored to your Wander account and merged across your devices. Places are only ever added — nothing is deleted from any device. Off by default."
                 : "Wander Pro syncs your saved places across all your devices. Places are only ever added, never deleted.")
        }
    }

    // MARK: - Match your IP (VPN) — free info card

    private var vpnSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Match your IP", systemImage: "network.badge.shield.half.filled")
                    .font(.body.weight(.semibold))
                Text("Some dating and Pokémon GO-style apps compare your IP address against your GPS location. A VPN in the same region keeps them consistent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link(destination: SettingsLinks.vpn) {
                    Label("Get a matching VPN", systemImage: "arrow.up.right.square")
                }
                .font(.callout.weight(.medium))
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Match your IP")
        }
    }

    private func runUpdate() {
        Task {
            guard wanderAccount.isSignedIn else {
                updater.status = "Sign in to your Apple ID first (above)."
                return
            }
            do {
                try await updater.installUpdate()
            } catch {
                updater.status = "❌ \((error as NSError).localizedDescription)"
            }
        }
    }

    private func trialRow(_ label: String, _ used: Int, _ maximum: Int, unit: String = "") -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(min(used, maximum))/\(maximum)\(unit)")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func handlePairingImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try PairingFileStore.importFromPicker(url)
                pairingImportResult = ("Imported successfully", false)
                startTunnelInBackground()
            } catch {
                pairingImportResult = ("Import failed: \(error.localizedDescription)", true)
            }
        case .failure(let error):
            pairingImportResult = ("Import failed: \(error.localizedDescription)", true)
        }
    }

    private var versionFooter: String {
        "Version \(appVersion) • iOS \(UIDevice.current.systemVersion)"
    }
}
