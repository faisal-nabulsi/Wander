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
    // Attribution for the bundled offline place gazetteer used by natural-language teleport
    // (OfflineGeocoder). The data is derived from GeoNames and is licensed under CC BY 4.0,
    // which requires a user-visible credit — surfaced in the Community section below.
    static let geonamesLicense = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
}

struct SettingsView: View {
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("useMph") private var useMph = false
    @AppStorage(MotionRealism.key) private var realisticMotion = true
    @AppStorage("jitterEnabled") private var jitterEnabled = true
    @AppStorage("jitterRadius") private var jitterRadius = 1.5
    @AppStorage("smoothLongJumps") private var smoothLongJumps = false
    @AppStorage("panicButtonEnabled") private var panicButtonEnabled = true
    @AppStorage(LocationPrivacyKeys.frozenHold) private var frozenHold = false
    @AppStorage(LocationPrivacyKeys.approximateLocation) private var approximateLocation = false
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(SavedPlacesSync.enabledKey) private var syncPlacesEnabled = false
    @AppStorage(SavedRoutesSync.enabledKey) private var syncRoutesEnabled = false
    @StateObject private var tunnel = WanderTunnel.shared
    @ObservedObject private var simSession = SimulationSession.shared
    @ObservedObject private var tunnelHealth = TunnelHealthMonitor.shared

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
    @ObservedObject private var deviceActivation = WanderDeviceActivation.shared
    @ObservedObject private var adventureSync = AdventureSyncManager.shared
    @State private var showProSignIn = false
    @State private var showManageDevices = false
    @State private var showLocationHelp = false
    @State private var showTunnelHelp = false
    @State private var showStabilizerBeta = false
    @State private var showLocationDiagnostic = false
    @AppStorage("gsloc_mode_enabled") private var gslocModeEnabled = false
    @State private var showGslocSetup = false
    @State private var showGslocAutomations = false
    @State private var showTunnelIP = false
    @State private var loopbackTunnelTest = (UserDefaults.standard.string(forKey: UserDefaults.Keys.targetDeviceIP) == "127.0.0.1")
    @EnvironmentObject private var localization: LocalizationManager

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var tunnelHealthColor: Color {
        switch tunnelHealth.state {
        case .connected: return .green
        case .unstable: return .orange
        case .disconnected: return .red
        }
    }

    private var tunnelHealthText: String {
        if tunnelHealth.isReconnecting {
            return L("tunnel.chip.reconnecting", fallback: "Tunnel: reconnecting…")
        }
        switch tunnelHealth.state {
        case .connected: return L("tunnel.chip.connected", fallback: "Tunnel: connected")
        case .unstable: return L("tunnel.chip.unstable", fallback: "Tunnel: unstable")
        case .disconnected: return L("tunnel.chip.disconnected", fallback: "Tunnel: disconnected")
        }
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
                                Text(localized: "settings.tagline", fallback: "Your location, anywhere").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section {
                    if license.isLicensed {
                        Label(L("settings.pro.active", fallback: "Wander Pro — active"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        if let expiry = license.expiry {
                            Text("Renews/expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        // A Pro account can manage the devices it's signed into (5-device cap).
                        if proAccount.isPro {
                            manageDevicesRow
                        }
                    } else {
                        // Pro account, but THIS device is over the 5-device cap → not unlocked
                        // here. Point the user straight at Manage Devices to free a slot.
                        if proAccount.isPro && deviceActivation.atLimit && !deviceActivation.registered {
                            Label("This device isn't unlocked — your Pro account is at its \(deviceActivation.limit)-device limit.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                            manageDevicesRow
                        }
                        trialRow(L("settings.trial.teleports_today", fallback: "Teleports today"), trial.teleportsUsed, TrialManager.maxTeleports)
                        trialRow(L("settings.trial.joystick", fallback: "Joystick"), trial.joystickSecondsUsed / 60, TrialManager.maxJoystickSeconds / 60, unit: " min")
                        trialRow(L("settings.trial.routes", fallback: "Routes"), trial.routesUsed, TrialManager.maxRoutes)
                        Button {
                            showPaywall = true
                        } label: {
                            Label(L("settings.pro.get", fallback: "Get Wander Pro"), systemImage: "sparkles")
                        }
                    }
                } header: {
                    Text(localized: "settings.pro.header", fallback: "Wander Pro")
                } footer: {
                    Text(license.isLicensed
                         ? L("settings.pro.footer_active", fallback: "Thanks for supporting Wander — all limits are lifted.")
                         : L("settings.pro.footer_free", fallback: "Free trial: 1 teleport a day, plus 15 minutes of joystick and 3 routes a month. Unlock unlimited use with a license."))
                }

                languageSection

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
                        wanderAccount.twoFactorPresenter = .settings   // Settings owns the 2FA prompt here
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
                        Text(localized: "settings.update.current_version", fallback: "Current version")
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
                            Label(L("settings.update.check", fallback: "Check for updates"), systemImage: "arrow.clockwise")
                        }
                        .disabled(updater.isBusy)
                    }
                    if !updater.status.isEmpty {
                        Text(updater.status)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } header: {
                    Text(localized: "settings.update.header", fallback: "Software Update")
                } footer: {
                    Text("Wander updates itself over the tunnel using your Apple ID — no computer. You'll need to be signed in (above) and connected. The app relaunches when the update installs.")
                }

                Section {
                    HStack {
                        Image(systemName: tunnel.status == .connected ? "checkmark.shield.fill" : "shield.slash")
                            .foregroundStyle(tunnel.status == .connected ? Color.green : Color.secondary)
                        Text(tunnel.status.title)
                        Spacer()
                        Button(tunnel.status == .connected || tunnel.status == .connecting
                               ? L("action.disconnect", fallback: "Disconnect")
                               : L("action.connect", fallback: "Connect")) {
                            tunnel.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Wander.brand)
                    }
                    Button {
                        showSetupCheck = true
                    } label: {
                        Label(L("settings.tunnel.checklist", fallback: "Setup checklist"), systemImage: "checklist")
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(localized: "settings.tunnel.header", fallback: "Wander Tunnel")
                        wipBadge
                    }
                } footer: {
                    if let e = tunnel.lastError {
                        Text("Couldn't start the built-in tunnel (\(e)).\n\niOS restricts VPNs to paid Apple accounts, so on a free install this can't activate — use the LocalDevVPN app instead. No Wi-Fi? Turn on Airplane Mode, then connect LocalDevVPN.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Built-in on-device tunnel. iOS restricts VPNs to paid Apple accounts, so on a free install use the LocalDevVPN app instead — on Wi-Fi, or on cellular by turning on Airplane Mode first, then connecting it.")
                    }
                }

                // TUNNEL STABILITY — a live heartbeat while spoofing, plus the honest low-memory
                // caveat. A dropped tunnel is the #1 support symptom; this explains what the chip
                // means and what actually helps (nothing can stop iOS from reclaiming it).
                Section {
                    if simSession.isActive {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(tunnelHealthColor)
                                .frame(width: 10, height: 10)
                            Text(tunnelHealthText)
                            Spacer()
                            if tunnelHealth.isReconnecting {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if !tunnelHealth.state.isHealthy {
                            Button(role: .destructive) {
                                SimulationSession.shared.stopAll()
                            } label: {
                                Label(L("tunnel.action.stop", fallback: "Stop — return to real GPS"),
                                      systemImage: "stop.circle")
                            }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundStyle(.secondary)
                            Text(localized: "tunnel.stability.idle",
                                 fallback: "Not spoofing — the heartbeat shows while a simulation is running.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(localized: "tunnel.stability.header", fallback: "Tunnel stability")
                } footer: {
                    Text(localized: "tunnel.stability.footer",
                         fallback: "Wander watches the connection it injects location through and, if it drops, tries to reconnect on its own — best-effort only, since iOS can close the tunnel when memory runs low or the app is backgrounded (nothing can prevent that). Low memory can drop it, so close background apps for a steadier spoof.")
                }

                // SAFETY — the panic button + the manual stop, grouped so the revert-to-real-GPS
                // controls live together instead of being buried in the Location catch-all.
                Section {
                    Button(role: .destructive) {
                        SimulationSession.shared.stopAll()
                    } label: {
                        Label(L("settings.location.stop", fallback: "Stop simulating location"), systemImage: "stop.circle")
                    }

                    Toggle(isOn: $panicButtonEnabled) {
                        Label(L("settings.safety.panic", fallback: "Show panic button"), systemImage: "exclamationmark.octagon")
                    }
                    .tint(Wander.brand)
                } header: {
                    Text(localized: "settings.safety.header", fallback: "Safety")
                } footer: {
                    Text(localized: "settings.safety.panic.footer",
                         fallback: "The floating red button on the map instantly reverts to your real GPS from anywhere. Turn it off to hide it — you can still stop above.")
                }

                Section {
                    HStack {
                        Label(L("settings.location.speed_units", fallback: "Speed units"), systemImage: "speedometer")
                        Spacer()
                        Picker("Speed units", selection: $useMph) {
                            Text("km/h").tag(false)
                            Text("mph").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                } header: {
                    Text(localized: "settings.location.header", fallback: "Location")
                }

                // REALISM & PRIVACY — the movement-believability toggles, split out of the old
                // catch-all Location section so they read as one coherent group.
                Section {
                    Toggle(isOn: $realisticMotion) {
                        Label(L("settings.motion.realistic", fallback: "Realistic motion"), systemImage: "figure.walk.motion")
                    }
                    if realisticMotion {
                        Text(localized: "settings.motion.realistic.on.footer",
                             fallback: "While you're moving (joystick or a route), your pace varies and your path curves slightly instead of a dead-straight line at a constant speed — the tell-tale sign of a spoofed track. Best-in-class anti-detection, no root needed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(localized: "settings.motion.realistic.off.footer",
                             fallback: "Off — movement is perfectly straight and constant-speed. Faster to aim, but easier for apps to flag as simulated.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Toggle(isOn: $jitterEnabled) {
                        Label(L("settings.location.jitter", fallback: "Natural drift"), systemImage: "dot.radiowaves.left.and.right")
                    }
                    if jitterEnabled {
                        HStack {
                            Text(localized: "settings.location.drift", fallback: "Drift").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $jitterRadius, in: 0.5...5, step: 0.5)
                            Text(String(format: "%.1f m", jitterRadius))
                                .font(.caption).monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    } else {
                        Text(localized: "settings.location.jitter.off.footer",
                             fallback: "Off — your spot is held perfectly still. On adds a subtle natural drift, like a real GPS reading.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Toggle(isOn: $smoothLongJumps) {
                        Label(L("settings.location.smooth_jumps", fallback: "Smooth long jumps"), systemImage: "arrow.up.right.circle")
                    }
                    if smoothLongJumps {
                        Text(localized: "settings.location.smooth_jumps.footer",
                             fallback: "A big teleport glides to the new spot over a few seconds instead of jumping instantly, so apps that flag an impossible jump (dating apps, Life360) see a fast but continuous move. Short jumps stay instant.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Toggle(isOn: $approximateLocation) {
                        Label(L("settings.location.coarse", fallback: "Approximate location"), systemImage: "location.circle")
                    }
                    if approximateLocation {
                        Text(localized: "settings.location.coarse.footer",
                             fallback: "Privacy: reports a spot within about 3–5 km of your target so you share a neighborhood, not the exact place. The offset stays the same for the whole session.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text(localized: "settings.realism.header", fallback: "Realism & privacy")
                }
                .onAppear {
                    // The old "Hold perfectly still" toggle was just the inverse of jitter;
                    // migrate anyone who had it on to jitter-off (still) and retire the flag,
                    // so the single Natural-drift toggle now fully controls stillness.
                    if frozenHold { jitterEnabled = false; frozenHold = false }
                }

                // Life360 / Find My — one preset that bundles the anti-detection settings so a
                // shared location stays believable (never frozen, no impossible teleport jump).
                Section {
                    Toggle(isOn: Binding(
                        get: { jitterEnabled && smoothLongJumps },
                        set: { on in
                            jitterEnabled = on
                            smoothLongJumps = on
                            if on && jitterRadius < 1.5 { jitterRadius = 1.5 }
                        }
                    )) {
                        Label(L("settings.sharing.mode", fallback: "Life360 / Find My mode"),
                              systemImage: "person.2.wave.2")
                    }
                    .tint(Wander.brand)
                } header: {
                    Text(localized: "settings.sharing.header", fallback: "Location-sharing apps")
                } footer: {
                    Text(localized: "settings.sharing.footer",
                         fallback: "Anti-detection for Life360, Find My and iMessage: your spot drifts naturally (never a frozen fake) and a teleport glides smoothly instead of an impossible jump, so your shared location stays believable. Turns on Natural drift + Smooth long jumps together.")
                }

                Section {
                    HStack {
                        Label(L("settings.appearance.title", fallback: "Appearance"), systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Picker("Appearance", selection: $appearanceRaw) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 200)
                    }
                } header: {
                    Text(localized: "settings.appearance.header", fallback: "Appearance")
                }

                Section {
                    Toggle(isOn: $reminderEnabled) {
                        Label(L("settings.reminders.toggle", fallback: "Remind me if it may have paused"), systemImage: "bell.badge")
                    }
                    .onChange(of: reminderEnabled) { _, isOn in
                        if isOn {
                            SimulationSession.shared.scheduleReminderIfEnabled()
                        } else {
                            SimulationSession.shared.cancelReminder()
                        }
                    }
                } header: {
                    Text(localized: "settings.reminders.header", fallback: "Reminders")
                } footer: {
                    Text("iOS pauses a simulation after about 2 hours in the background. When this is on, Wander reminds you to reopen it — but only while you're actively simulating a location.")
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(localized: "settings.keepalive.audio", fallback: "Silent Audio")
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
                            Text(localized: "settings.keepalive.background_location", fallback: "Background Location")
                            Text("Uses low-accuracy location to stay alive when an activity needs it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                } header: {
                    Text(localized: "settings.keepalive.header", fallback: "Keep simulation alive")
                }

                Section {
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label(L("settings.help.download_vpn", fallback: "Download LocalDevVPN"), systemImage: "arrow.down.circle")
                    }
                    Button {
                        showLocationHelp = true
                    } label: {
                        Label(L("settings.help.error12", fallback: "Location not detected? (Error 12)"),
                              systemImage: "questionmark.circle")
                    }
                    Button {
                        showTunnelHelp = true
                    } label: {
                        Label(L("settings.help.tunnel", fallback: "Tunnel won't connect?"),
                              systemImage: "cable.connector.horizontal")
                    }
                } header: {
                    Text(localized: "settings.help.header", fallback: "Help")
                } footer: {
                    Text("The tunnel connects Wander to your device. Use the LocalDevVPN app — on Wi-Fi, or without Wi-Fi by turning on Airplane Mode first, then connecting LocalDevVPN.")
                }

                // EXPERIMENTAL — opt-in, off-by-default beta features. Nothing here changes anything
                // unless the user opens the screen and acts.
                Section {
                    Button {
                        showStabilizerBeta = true
                    } label: {
                        HStack {
                            Label(L("settings.experimental.stabilizer",
                                    fallback: "Long-distance stabilizer (Beta)"),
                                  systemImage: "point.3.connected.trianglepath.dotted")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)

                    Button {
                        showLocationDiagnostic = true
                    } label: {
                        HStack {
                            Label(L("settings.experimental.diagnostic",
                                    fallback: "Location diagnostic"),
                                  systemImage: "scope")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)

                    Toggle(isOn: $gslocModeEnabled) {
                        Label(L("settings.experimental.gsloc",
                                fallback: "PoGo / anti-cheat games mode (gs-loc)"),
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .onChange(of: gslocModeEnabled) { _, newValue in
                        GslocMode.enabled = newValue
                        // Turning it on: tell the proxy to pass the real location through, so you start
                        // at your true spot instead of the module's default (Apple Park) until you teleport.
                        if newValue {
                            GslocMode.reset()
                        } else if updater.status.localizedCaseInsensitiveContains("PoGo")
                                    || updater.status.localizedCaseInsensitiveContains("Shadowrocket") {
                            // Clear the now-stale "turn off PoGo/Shadowrocket to update" message the moment
                            // the user does exactly that, so the update prompt stops looking broken.
                            updater.status = ""
                        }
                    }

                    Button {
                        showGslocSetup = true
                    } label: {
                        HStack {
                            Label(L("settings.experimental.gsloc.setup",
                                    fallback: "Set up gs-loc mode (Shadowrocket)"),
                                  systemImage: "wand.and.stars")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)

                    Button {
                        showGslocAutomations = true
                    } label: {
                        HStack {
                            Label(L("settings.experimental.gsloc.automations",
                                    fallback: "Shortcuts & automations"),
                                  systemImage: "square.stack.3d.up.fill")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)

                    Toggle(isOn: $loopbackTunnelTest) {
                        Label(L("settings.experimental.loopback",
                                fallback: "Loopback tunnel test (no LocalDevVPN)"),
                              systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                    .onChange(of: loopbackTunnelTest) { _, on in
                        // Lead B experiment: point the dev tunnel at 127.0.0.1 instead of LocalDevVPN's
                        // 10.7.0.1. If Wander (both ends of the tunnel in one process) can RemotePair to
                        // its own loopback with LocalDevVPN OFF, we could drop the helper entirely.
                        if on {
                            UserDefaults.standard.set("127.0.0.1", forKey: UserDefaults.Keys.targetDeviceIP)
                        } else {
                            UserDefaults.standard.removeObject(forKey: UserDefaults.Keys.targetDeviceIP)
                        }
                    }

                    Button {
                        showTunnelIP = true
                    } label: {
                        HStack {
                            Label(L("settings.experimental.tunnelip",
                                    fallback: "Tunnel IP (fix for iOS 26.4+)"),
                                  systemImage: "network")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .tint(.primary)
                } header: {
                    Text(localized: "settings.experimental.header", fallback: "Experimental")
                } footer: {
                    Text(localized: "settings.experimental.footer",
                         fallback: "Opt-in beta features. Off by default — nothing installs or changes until you open one and choose to turn it on.\n\nPoGo mode (gs-loc): routes teleports to a Wi-Fi-location proxy (Shadowrocket) instead of the dev tunnel, so Pokémon GO sees a non-simulated fix. It replaces LocalDevVPN — iOS allows only ONE VPN at a time, so in this mode turn LocalDevVPN OFF and Shadowrocket ON. Turn this toggle off to go back to normal spoofing over LocalDevVPN. Requires the proxy + trusted MITM certificate; only holds indoors / with weak GPS.\n\nLoopback tunnel test: an experiment to see if Wander can run the tunnel WITHOUT LocalDevVPN. To test: turn OFF LocalDevVPN, enable this, reopen Wander, and try a teleport. If it works, the tunnel came up on its own (report back!). If teleport fails with a tunnel error, turn this off and reconnect LocalDevVPN — it just means iOS needs the external loopback.\n\nTunnel IP: only needed on iOS 26.4 or later, where Apple started dropping the tunnel's default address (10.7.0.1). If your tunnel stopped connecting after updating, open this, tap Detect, and set the same two IPs here and in LocalDevVPN. Leave it alone on iOS 26.3 and earlier.")
                }

                Section {
                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label(L("settings.pairing.import", fallback: "Import pairing file"), systemImage: "doc.badge.plus")
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
                    Text(versionFooter)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("settings.title", fallback: "Settings"))
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
                SavedRoutesSync.shared.syncIfEnabled()
            })
        }
        .sheet(isPresented: $showManageDevices) {
            ManageDevicesView(overLimitContext: deviceActivation.atLimit && !deviceActivation.registered)
        }
        .sheet(isPresented: $showLocationHelp) {
            LocationErrorHelpView()
        }
        .sheet(isPresented: $showTunnelHelp) {
            TunnelConnectionHelpView()
        }
        .sheet(isPresented: $showStabilizerBeta) {
            StabilizerBetaView()
        }
        .sheet(isPresented: $showGslocAutomations) {
            AutomationsView()
        }
        .sheet(isPresented: $showGslocSetup) {
            ShadowrocketSetupView()
        }
        .sheet(isPresented: $showTunnelIP) {
            TunnelIPSettingsView()
        }
        .sheet(isPresented: $showLocationDiagnostic) {
            LocationDiagnosticView()
        }
        .alert("Two-Factor Code", isPresented: wanderAccount.twoFactorPrompt(for: .settings)) {
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
        .onDisappear {
            // Hand the 2FA prompt back to the root when Settings closes, so a later auto/update
            // re-sign isn't orphaned with a stale .settings owner (which would show no prompt).
            if wanderAccount.twoFactorPresenter == .settings { wanderAccount.twoFactorPresenter = .system }
        }
    }

    // MARK: - Language (free, in-app switcher)

    private var languageSection: some View {
        Section {
            Picker(selection: $localization.currentLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            } label: {
                Label(L("settings.language", fallback: "Language"), systemImage: "globe")
            }
            .pickerStyle(.navigationLink)
        } footer: {
            Text(localized: "settings.language_footer",
                 fallback: "Choose the language Wander uses. The app updates immediately — no restart needed.")
        }
    }

    // MARK: - Manage devices (Pro, 5-device cap)

    private var manageDevicesRow: some View {
        Button {
            showManageDevices = true
        } label: {
            HStack {
                Label("Manage devices", systemImage: "iphone.and.arrow.forward")
                Spacer()
                Text("\(max(deviceActivation.devices.count, 0))/\(deviceActivation.limit)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .tint(.primary)
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

                Toggle(isOn: $syncRoutesEnabled) {
                    Label("Sync routes across devices", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .onChange(of: syncRoutesEnabled) { _, isOn in
                    if isOn { SavedRoutesSync.shared.syncIfEnabled() }
                }
                .tint(Wander.brand)

                if syncPlacesEnabled || syncRoutesEnabled {
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
                 ? "When on, your saved places and routes are mirrored to your Wander account and merged across your devices — only ever added, nothing deleted from any device. Off by default."
                 : "Wander Pro syncs your saved places and routes across all your devices. They're only ever added, never deleted.")
        }
    }

    // MARK: - Adventure Sync (Pro) — mirror simulated walking into Apple Health

    /// Writes step + walking-distance samples into Apple Health that MIRROR the
    /// app's simulated movement, so fitness-reading games (Pokémon GO Adventure
    /// Sync, Pikmin Bloom, …) can credit the spoofed walk. Pro-gated like the other
    /// power features; default OFF; permission-gated; honest best-effort labelling.
    /// Small "work in progress" pill for section headers (Tunnel, Adventure Sync).
    private var wipBadge: some View {
        Text(verbatim: "WIP")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
    }

    private func runUpdate() {
        Task {
            guard wanderAccount.isSignedIn else {
                updater.status = "Sign in to your Apple ID first (above)."
                return
            }
            // Route any 2FA prompt to THIS sheet's alert (line ~645). Without this the presenter stays
            // on `.system` (the root screen behind the Settings sheet), so a required 2FA code prompt
            // never appears and the sign-in step hangs forever ("signing into Apple, then nothing").
            // Mirrors the self-refresh button above.
            wanderAccount.twoFactorPresenter = .settings
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
