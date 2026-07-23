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
    @AppStorage("shortcutsReady") private var shortcutsReady = false
    @State private var showAutomations = false
    @State private var showOnboarding = false

    var body: some View {
        Section {
            // Shortcut-powered one-tap action: the app fires a Shortcut to cycle Wi-Fi — the one gs-loc
            // step Wander's sandbox can't do itself. Briefly shows Shortcuts, then returns. Gated on install.
            // (Warm-start / VPN-swap shortcuts are documented recipes in the Automations sheet until the
            // on-device VPN-swap test clears — see AutomationsView.)
            shortcutRow(icon: "wifi", title: "Flush snap",
                        subtitle: "Cycles Wi-Fi to clear a stuck fix — replaces the manual Location Services toggle on re-teleports.",
                        name: ShortcutRunner.flushName, success: "flushed")

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
        .sheet(isPresented: $showOnboarding) { ShortcutsOnboardingView() }
    }

    /// A one-tap button backed by an imported Shortcut. Shows an "install" affordance until set up, and
    /// self-heals: ShortcutRunner flips `shortcutsReady` back to false if the run reports x-error.
    @ViewBuilder
    private func shortcutRow(icon: String, title: String, subtitle: String, name: String, success: String) -> some View {
        Button {
            if shortcutsReady {
                ShortcutRunner.run(name: name, successHost: success)
            } else {
                showOnboarding = true
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: shortcutsReady ? icon : "square.and.arrow.down")
                    .foregroundStyle(shortcutsReady ? .blue : .orange)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortcutsReady ? title : "\(title) — set up")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(shortcutsReady ? subtitle : "Tap to install the one-tap Wander shortcut (once).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
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

/// One-time setup so the in-app "Flush snap" button (and future shortcut buttons) can invoke a Shortcut
/// by name. iOS gates untrusted-shortcut import behind a toggle that itself is grayed until the user has
/// run any shortcut once — so the order below is fixed.
struct ShortcutsOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("shortcutsReady") private var shortcutsReady = false
    private let flushURL = "https://wanderspoofer.com/downloads/shortcuts/wander-flush.shortcut"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("This lets a Wander button do something iOS won't let the app do directly — cycle Wi-Fi to flush a stuck fix. Tapping the button briefly opens Shortcuts, runs it, and returns here. Set it up once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                step(1, "Open Shortcuts once",
                     "iOS grays out the next toggle until you've run any shortcut at least once — so just open the app.",
                     button: ("Open Shortcuts", { ShortcutRunner.openShortcutsApp() }))
                step(2, "Allow Untrusted Shortcuts",
                     "Settings → Apps → Shortcuts → Advanced → Allow Untrusted Shortcuts (needs your passcode). This lets you add a shortcut that isn't from Apple's own gallery.",
                     button: ("Open Settings", { openSettingsShortcuts() }))
                step(3, "Add the shortcut, name it exactly",
                     "Import it, then rename it EXACTLY “\(ShortcutRunner.flushName)” — the button finds it by name, so the name must match.",
                     button: ("Add “\(ShortcutRunner.flushName)”", { openURLString(flushURL) }))
                Section {
                    Button {
                        shortcutsReady = true
                        dismiss()
                    } label: {
                        Label("I've added it — enable one-tap", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    Text("If a one-tap button later says “set up” again, the shortcut was renamed or deleted — just re-add it. The brief Shortcuts flash when it runs is an iOS limitation and can't be removed for a button-triggered run.")
                }
            }
            .navigationTitle("One-tap setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func openSettingsShortcuts() {
        // Best-effort deep link to the Shortcuts settings pane; fall back to the system Settings root.
        if let u = URL(string: "App-Prefs:root=SHORTCUTS"), UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else if let u = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(u)
        }
    }

    @ViewBuilder
    private func step(_ n: Int, _ title: String, _ detail: String, button: (String, () -> Void)) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(n). \(title)").font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button.0, action: button.1)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
            }
        }
    }
}
