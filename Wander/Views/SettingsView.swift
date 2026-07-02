//  SettingsView.swift
//  Wander
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let localDevVPN = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
}

struct SettingsView: View {
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("reminderEnabled") private var reminderEnabled = false
    @AppStorage("useMph") private var useMph = false
    @AppStorage("jitterEnabled") private var jitterEnabled = false
    @AppStorage("jitterRadius") private var jitterRadius = 1.5
    @StateObject private var tunnel = WanderTunnel.shared

    @State private var isShowingPairingFilePicker = false
    @State private var pairingImportResult: (text: String, isError: Bool)?
    @State private var showSetupCheck = false

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
                        Text("Couldn't start the built-in tunnel (\(e)).\n\nThe built-in tunnel needs a paid Apple Developer account (Apple restricts Network Extensions on free accounts). On a free account, use the LocalDevVPN app instead — it works the same way.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Built-in on-device tunnel — replaces LocalDevVPN. Requires a paid Apple Developer account to activate; on a free account, use the LocalDevVPN app.")
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

                Section {
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label("Download LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                } header: {
                    Text("Help")
                } footer: {
                    Text("The tunnel connects Wander to your device. On a free Apple ID, use the free LocalDevVPN app.")
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
