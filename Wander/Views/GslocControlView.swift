//
//  GslocControlView.swift
//  Wander
//
//  One-click controls for the gs-loc (PoGo) workflow, so the fiddly recurring actions — connect the
//  proxy, swap the VPN, jump to the Location Services toggle, reset — are a single tap inside the app
//  instead of a dig through Settings and other apps. Plus AutomationsView: import the Wander Shortcuts
//  and set up the personal automations. None of this crosses the hard iOS walls (the Location Services
//  toggle stays manual, and so does the rare reboot); it just puts you one tap from each.
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
                       title: "Connect Shadowrocket (PoGo / games)",
                       subtitle: "The proxy for Pokémon GO + other anti-cheat games (Monster Hunter Now, etc.) — nothing else. Runs a shortcut, connects, and bounces back here to check your spoof.") {
                autoVerifyArmed = true
                ShortcutRunner.run(name: ShortcutRunner.shadowrocketConnectName, successHost: "vpnconnected")
            }
            controlRow(icon: "scope",
                       tint: Wander.brand,
                       title: "Re-teleport to last spot",
                       subtitle: GslocMode.currentTargetSnapshot == nil
                            ? "Teleport once first, then re-assert it here."
                            : "Re-push your current spot — then flush with Location Services (every new spot needs it).") {
                if let t = GslocMode.currentTargetSnapshot {
                    GslocMode.push(latitude: t.lat, longitude: t.lng)
                    // Logged HERE rather than by `simulate_location_logged`, because this is the one
                    // write in the app that never touches `simulate_location` at all — it hands the
                    // coordinate straight to the gs-loc rewriter. Without this line a PoGo session
                    // driven from these controls would leave no trace in the spoof timeline.
                    // Fire-and-forget, like every other call into the recorder.
                    //
                    // `accepted` reads the LAST KNOWN push outcome rather than the `true` this used to
                    // hardcode: the push above is asynchronous, so its own result isn't known yet, but a
                    // proxy that was unreachable a moment ago is the honest thing to record.
                    SpoofTimelineRecorder.record(latitude: t.lat, longitude: t.lng,
                                                 source: .gsloc,
                                                 accepted: GslocMode.lastPushOutcome.looksAccepted)
                }
            }
            // GENERIC on purpose: this is the system-wide Location Services switch, not any one
            // app's permission. It only takes you to the switch — iOS gives no app (and no Shortcut)
            // a way to flip it, so the copy must never suggest Wander does the toggling.
            controlRow(icon: "location.fill.viewfinder",
                       tint: .orange,
                       title: "Flush — toggle Location Services",
                       subtitle: "Takes you to the switch; you flip it. Off a full ~10s — not a quick flick — then back on. That's the step that makes a teleport take.") {
                AppLocationSettings.openLocationServicesPane()
            }
            // APP-SPECIFIC: the "Always + Precise" advice is about Pokémon GO's own permission, so
            // this lands on the game's location screen instead of the system-wide list.
            controlRow(icon: "gamecontroller.fill",
                       tint: Wander.brand,
                       title: "Pokémon GO location — Always + Precise",
                       subtitle: "Opens the game's own location screen. Set Always and turn Precise Location ON — a coarse fix fights the spoofed one and is a common Error 12 cause.") {
                AppLocationSettings.openLocationScreen(forBundleID: AppLocationSettings.BundleID.pokemonGo)
            }
            controlRow(icon: "arrow.triangle.2.circlepath",
                       tint: Wander.brand,
                       title: "Update mode — Wander tunnel",
                       subtitle: "Own tunnel (needs a signing cert that keeps the VPN entitlement). \(tunnel.status.title).") {
                WanderTunnel.shared.start()
            }
            controlRow(icon: "arrow.left.arrow.right",
                       tint: Wander.brand,
                       title: "Connect LocalDevVPN (default tunnel)",
                       subtitle: "Your everyday tunnel — for Find My, Life360, and everything that ISN'T a game (and to install app updates). Runs a shortcut, connects, returns here. Set both shortcuts up once in Shortcuts & automations.") {
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
            Text("All one tap. The Location Services flip is the only manual step — iOS reserves that switch — so “Flush” jumps you straight to it. You need it after EVERY new spot, not just the first: gs-loc changes the answer to a location query iOS makes on its own schedule, and the flush is what makes it ask again. For a hands-free push, bind the Teleport shortcut to Back Tap (see Shortcuts & automations); the flush still has to be you.")
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
        .init(name: "Reset to real", file: "wander-reset.shortcut", blurb: "Stop spoofing."),
        .init(name: "Open Location Services", file: "wander-open-location-services.shortcut", blurb: "Jump to the LS toggle pane."),
        .init(name: "Connect proxy", file: "wander-connect.shortcut", blurb: "Connect Shadowrocket + routing."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(localized: "shortcuts.import.intro",
                         fallback: "Import these into Apple's Shortcuts app to run the gs-loc steps from your widget, Back Tap, or an NFC tag. First turn on Settings › Apps › Shortcuts › Private Sharing (older iOS calls it Allow Untrusted Shortcuts, under Advanced). If that row isn't there, run any shortcut once and go back — iOS hides it until you have.")
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
                Section("Switch VPN (build these two once)") {
                    recipe(title: "⭐ “Wander Connect Shadowrocket” (PoGo / games only)",
                           steps: ["New shortcut, name it EXACTLY: Wander Connect Shadowrocket",
                                   "Set VPN → On → pick Shadowrocket",
                                   "Open App → Wander"])
                    recipe(title: "⭐ “Wander Connect VPN” (default tunnel — everything else)",
                           steps: ["New shortcut, name it EXACTLY: Wander Connect VPN",
                                   "Set VPN → On → pick LocalDevVPN",
                                   "Open App → Wander"])
                    Text("The two “Connect …” buttons in Quick Controls invoke these BY NAME, so the names must match exactly. Shadowrocket is ONLY for Pokémon GO + other anti-cheat games (Monster Hunter Now) — nothing else; LocalDevVPN is your default tunnel for Find My, Life360, everything else, and app updates. iOS runs one VPN at a time, so turning one on drops the other.")
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
