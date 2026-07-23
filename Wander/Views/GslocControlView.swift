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
    @AppStorage("gslocAutoVerify") private var autoVerifyArmed = false
    @State private var showAutomations = false

    var body: some View {
        Section {
            // All native — no external shortcut, no Shortcuts-app flash. The Wi-Fi-flush shortcut was
            // dropped: device-tested, cycling Wi-Fi does NOT move the fix (nor does Airplane mode) — only
            // the Location Services toggle does, and iOS lets no app flip that. So the flush is the one
            // manual step; everything else here is a real one-tap in-app action.
            controlRow(icon: "bolt.fill",
                       tint: .green,
                       title: "Warm start — connect Shadowrocket",
                       subtitle: "Connects the gs-loc proxy, then checks your spoof when you come back.") {
                autoVerifyArmed = true
                openURLString("shadowrocket://connect")
            }
            controlRow(icon: "scope",
                       tint: Wander.brand,
                       title: "Re-teleport to last spot",
                       subtitle: GslocMode.currentTargetSnapshot == nil
                            ? "Teleport once first, then re-assert it here."
                            : "Re-push your current spot — then flush with Location Services.") {
                if let t = GslocMode.currentTargetSnapshot {
                    GslocMode.push(latitude: t.lat, longitude: t.lng)
                }
            }
            controlRow(icon: "location.fill.viewfinder",
                       tint: .orange,
                       title: "Flush — toggle Location Services",
                       subtitle: "The one step that makes a teleport take. Off ~3s, then back on.") {
                openURLString("prefs:root=Privacy&path=LOCATION")
            }
            controlRow(icon: "arrow.triangle.2.circlepath",
                       tint: Wander.brand,
                       title: "Update mode — Wander tunnel",
                       subtitle: "Own tunnel (needs a signing cert that keeps the VPN entitlement). \(tunnel.status.title).") {
                WanderTunnel.shared.start()
            }
            controlRow(icon: "arrow.left.arrow.right",
                       tint: .green,
                       title: "Connect LocalDevVPN",
                       subtitle: "Free-sideload update swap: runs a shortcut that flips your VPN to LocalDevVPN, then bounces back here. Set it up once in Shortcuts & automations.") {
                ShortcutRunner.run(name: ShortcutRunner.vpnConnectName, successHost: "vpnconnected")
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
            Text("All one tap. The Location Services flip is the only manual step — iOS reserves that switch — so “Flush” jumps you straight to it. For a hands-free teleport, bind the Teleport shortcut to Back Tap (see Shortcuts & automations).")
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
        .init(name: "Wi-Fi cycle", file: "wander-flush.shortcut", blurb: "Cycles Wi-Fi. Note: a fresh teleport needs the LS toggle, not this."),
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
                    recipe(title: "⭐ “Wander Connect VPN” — the in-app button runs this",
                           steps: ["New shortcut, name it EXACTLY: Wander Connect VPN",
                                   "Set VPN → On → pick LocalDevVPN",
                                   "Open App → Wander",
                                   "Now the “Connect LocalDevVPN” button in Quick Controls runs it for you"])
                    recipe(title: "Wander: Spoof mode",
                           steps: ["Set VPN → On → pick Shadowrocket", "Open App → Wander"])
                    Text("The in-app “Connect LocalDevVPN” button invokes the first shortcut BY NAME (so the name must match exactly). Set VPN points at YOUR named config, so it can't ship as a file — build it once. iOS runs one VPN at a time, so turning one on drops the other.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    Text("The PUSH works from a shortcut (device-tested — it fires straight through the tunnel). So bind the Teleport shortcut to a gesture and you push your spot hands-free, with NO Shortcuts flash, because you press it yourself. You still flip Location Services after — that's the one step iOS won't let any app or shortcut do.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { openURLString(base + "wander-teleport-presets.shortcut") } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("1. Install the Teleport shortcut").font(.subheadline.weight(.semibold))
                                Text("Pushes a saved spot through the tunnel — no typing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.down").foregroundStyle(Wander.brand)
                        }
                    }
                    recipe(title: "⭐ 2a. Back Tap (best — every iPhone)",
                           steps: ["Settings › Accessibility › Touch › Back Tap › Double Tap", "Pick the Teleport shortcut", "Double-tap the back = silent push, then flip Location Services"])
                    recipe(title: "2b. Home Screen widget (most button-like)",
                           steps: ["Long-press Home Screen › add the Shortcuts widget", "Point it at the Teleport shortcut"])
                    recipe(title: "2c. Action Button (iPhone 15 Pro / 16)",
                           steps: ["Settings › Action Button › swipe to Shortcut", "Pick the Teleport shortcut"])
                } header: {
                    Text("⚡ Hands-free teleport (Back Tap)")
                } footer: {
                    Text("Device-tested truth: cycling Wi-Fi (or Airplane mode) does NOT move the fix — only the Location Services toggle does, and no shortcut can flip it. So a gesture makes the PUSH hands-free; the flush stays a manual LS toggle.")
                }
                Section("Other automations") {
                    recipe(title: "Back Tap → Teleport",
                           steps: ["Settings › Accessibility › Touch › Back Tap", "Double Tap → run Wander: Teleport to preset"])
                    recipe(title: "When Pokémon GO opens → Connect proxy",
                           steps: ["New Automation → App → Pokémon GO → Is Opened", "Run: Wander: Connect proxy", "Run Immediately, uncheck Notify When Run"])
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
                    Text("If a one-tap button later says “set up” again, the shortcut was renamed or deleted — just re-add it. Want it SILENT? Bind this same shortcut to a Back Tap (Settings › Accessibility › Touch › Back Tap) — a gesture-run has no Shortcuts flash. See “⚡ Silent flush” in Shortcuts & automations.")
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
