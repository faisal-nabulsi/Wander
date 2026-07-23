//
//  GslocControlView.swift
//  Wander
//
//  One-click controls for the gs-loc (PoGo) workflow, so the fiddly recurring actions — connect the
//  proxy, swap the VPN, jump to the Location Services toggle, reset — are a single tap inside the app
//  instead of a dig through Settings and other apps. Plus AutomationsView: import the Wander Shortcuts
//  and set up the personal automations. None of this crosses the hard iOS walls (the Location Services
//  toggle and reboot stay manual); it just puts you one tap from each.
//

import SwiftUI
import UIKit

private func openURLString(_ s: String) {
    if let u = URL(string: s) { UIApplication.shared.open(u) }
}

/// Compact one-tap control card. Drop into the PoGo List when GslocMode.enabled.
struct GslocQuickControlsCard: View {
    @ObservedObject private var tunnel = WanderTunnel.shared
    @State private var showAutomations = false

    var body: some View {
        Section {
            controlRow(icon: "antenna.radiowaves.left.and.right",
                       tint: .green,
                       title: "Spoof mode — connect Shadowrocket",
                       subtitle: "Switches the active VPN to the gs-loc proxy.") {
                openURLString("shadowrocket://connect")
            }
            controlRow(icon: "arrow.triangle.2.circlepath",
                       tint: Wander.brand,
                       title: "Update mode — Wander tunnel",
                       subtitle: "For installing app updates. \(tunnel.status.title).") {
                WanderTunnel.shared.start()
            }
            controlRow(icon: "location.fill.viewfinder",
                       tint: .orange,
                       title: "Open Location Services",
                       subtitle: "Toggle off ~3s on after a teleport.") {
                openURLString("prefs:root=Privacy&path=LOCATION")
            }
            controlRow(icon: "arrow.uturn.backward",
                       tint: .secondary,
                       title: "Reset to real location",
                       subtitle: "Stop spoofing — pass your real location through.") {
                GslocMode.reset()
            }
            Button { showAutomations = true } label: {
                Label("Shortcuts & automations", systemImage: "square.stack.3d.up.fill")
            }
        } header: {
            Text("Quick controls")
        } footer: {
            Text("One tap each. The Location Services toggle stays manual — iOS reserves it — so this jumps you straight to it.")
        }
        .sheet(isPresented: $showAutomations) { AutomationsView() }
    }

    @ViewBuilder
    private func controlRow(icon: String, tint: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Full sheet: import the Wander Shortcuts + set up personal automations + the VPN-swap recipes.
struct AutomationsView: View {
    @Environment(\.dismiss) private var dismiss

    private let base = "https://wanderspoofer.com/downloads/shortcuts/"
    private struct Shortcut: Identifiable {
        let id = UUID(); let name: String; let file: String; let blurb: String
    }
    private let shortcuts: [Shortcut] = [
        .init(name: "Teleport", file: "wander-reteleport.shortcut", blurb: "Type a lat/lng, teleport there."),
        .init(name: "Teleport to preset", file: "wander-teleport-presets.shortcut", blurb: "Pick a saved spot from a menu."),
        .init(name: "Flush snap", file: "wander-flush.shortcut", blurb: "Clear a stuck fix (Wi-Fi off/on)."),
        .init(name: "Reset to real", file: "wander-reset.shortcut", blurb: "Stop spoofing."),
        .init(name: "Open Location Services", file: "wander-open-location-services.shortcut", blurb: "Jump to the LS toggle pane."),
        .init(name: "Connect proxy", file: "wander-connect.shortcut", blurb: "Connect Shadowrocket + routing."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Import these into Apple's Shortcuts app to run the gs-loc steps from your widget, Back Tap, or an NFC tag. First turn on Settings › Shortcuts › Allow Untrusted Shortcuts (it appears after you've run any one shortcut once).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Get the shortcuts") {
                    ForEach(shortcuts) { s in
                        Button {
                            openURLString(base + s.file)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wander: \(s.name)").font(.subheadline.weight(.semibold))
                                    Text(s.blurb).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.down").foregroundStyle(Wander.brand)
                            }
                        }
                    }
                }
                Section("Switch VPN (build once in Shortcuts)") {
                    recipe(title: "Wander: Spoof mode",
                           steps: ["Set VPN → On → pick Shadowrocket", "Open App → Wander"])
                    recipe(title: "Wander: Update mode",
                           steps: ["Set VPN → On → pick your Wander/LocalDev tunnel"])
                    Text("Set VPN points at YOUR named config, so these can't ship as files — build them once. iOS runs one VPN at a time, so turning one on drops the other.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Auto-run on a trigger (Shortcuts › Automation)") {
                    recipe(title: "When Pokémon GO opens → Connect proxy",
                           steps: ["New Automation → App → Pokémon GO → Is Opened", "Run: Wander: Connect proxy", "Run Immediately, uncheck Notify When Run"])
                    recipe(title: "Back Tap → Teleport",
                           steps: ["Settings › Accessibility › Touch › Back Tap", "Double Tap → run Wander: Teleport to preset"])
                    recipe(title: "NFC tag → Connect proxy",
                           steps: ["New Automation → NFC → scan a tag", "Run: Wander: Connect proxy"])
                }
            }
            .navigationTitle("Shortcuts & Automations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func recipe(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
