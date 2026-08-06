//
//  CellularModeSetupView.swift
//  Wander
//
//  Onboarding for CELLULAR MODE: the one-tap sequence that gets a spoof set on mobile data with no
//  Wi-Fi.
//
//  THE BEHAVIOUR IT AUTOMATES (confirmed on device, build 139). lockdownd refuses the developer-tunnel
//  connection while the device has cellular and NO Wi-Fi *at connect time*, and it does NOT re-evaluate
//  an already-established session. So: Airplane Mode ON → connect + set the location → Airplane Mode
//  OFF, and the spoof HOLDS with cellular back on. The toggle is needed for the moment the connection
//  is made and for nothing else.
//
//  WHY IT'S A SHORTCUT AND NOT A BUTTON. iOS gives an app no API for Airplane Mode — Shortcuts is the
//  only thing on the system that can toggle it. Wander can *run* a shortcut by name
//  (`shortcuts://x-callback-url/run-shortcut`), which is what makes it one tap; it cannot flip the
//  radio itself, and nothing here flips anything until the user taps.
//
//  WHY SETUP ISN'T A SINGLE IMPORT. The sequence has to WAIT for Wander's tunnel and teleport to
//  actually finish before the radio comes back, so those two steps are App Intents (a `wander://` link
//  would return instantly and the shortcut would guess a delay). An App Intent action carries the
//  target app's bundle id, and Wander's is unique to whoever signed it (`com.stik.stikdebug.<TeamID>`
//  — see WanderSigner) — so those two actions CANNOT be shipped pre-filled in a downloadable file.
//  They're two picks in the Shortcuts editor, done once. Same wall as the pack's existing
//  "add Open App → Wander yourself" step; documented rather than hidden.
//

import SwiftUI
import UIKit

struct CellularModeSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(localized: "cellular.setup.intro",
                         fallback: "On mobile data with no Wi-Fi, iOS won't let the tunnel connect — but it stops checking once it's up. Cellular Mode turns Airplane Mode on just long enough to connect and set your location, then turns it back off. Your spoof holds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // HONEST NUMBER, not a comfortable one. The run is a 4 s settle, up to 12 s in
                // `WanderTunnel.ensureStarted()`, up to ~12 s in the teleport, plus the shortcut's
                // own trailing step — roughly half a minute at worst, not the "few seconds" this
                // used to promise. Someone waiting on a call notices.
                Section {
                    Label(L("cellular.setup.cost",
                            fallback: "You'll see Shortcuts open for a moment, then calls and data are off for up to about 30 seconds — usually less — before you land back in Wander."),
                          systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.cost.header", fallback: "What you'll see")
                }

                // The failure this feature actually has, named where the user meets the feature.
                Section {
                    Label(L("cellular.setup.interrupted",
                            fallback: "If you force-quit or cancel mid-run, Airplane Mode can be left on. Wander notices and shows you how to switch it back off — you're never stuck without an explanation."),
                          systemImage: "airplane")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.interrupted.header", fallback: "If it's interrupted")
                }

                step(1,
                     L("cellular.setup.step1.title", fallback: "Open Shortcuts once"),
                     L("cellular.setup.step1.detail",
                       fallback: "iOS greys out the next toggle until you've run any shortcut at least once — so just open the app."),
                     button: (L("cellular.setup.step1.button", fallback: "Open Shortcuts"),
                              { ShortcutRunner.openShortcutsApp() }))

                step(2,
                     L("cellular.setup.step2.title", fallback: "Allow Untrusted Shortcuts"),
                     L("cellular.setup.step2.detail",
                       fallback: "Settings → Apps → Shortcuts → Advanced → Allow Untrusted Shortcuts (needs your passcode). This lets you add a shortcut that isn't from Apple's gallery."),
                     button: (L("cellular.setup.step2.button", fallback: "Open Settings"),
                              { openSettingsShortcuts() }))

                step(3,
                     L("cellular.setup.step3.title", fallback: "Add the shortcut, name it exactly"),
                     L("cellular.setup.step3.detail",
                       fallback: "Import it, then make sure it is named EXACTLY “\(ShortcutRunner.cellularModeName)” — the button finds it by name, so the name has to match."),
                     button: (L("cellular.setup.step3.button", fallback: "Add “\(ShortcutRunner.cellularModeName)”"),
                              { openURLString(ShortcutRunner.cellularModeInstallURL) }))

                // THE ONE STEP THAT CANNOT BE SHIPPED IN THE FILE. Kept as its own numbered step rather
                // than buried in a footnote, because a user who skips it gets a shortcut that toggles
                // the radio and does nothing else — the worst possible failure for this feature.
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("4. " + L("cellular.setup.step4.title",
                                       fallback: "Add the two Wander actions"))
                            .font(.subheadline.weight(.semibold))
                        Text(localized: "cellular.setup.step4.detail",
                             fallback: "Open the imported shortcut. Where it says ADD THE WANDER ACTION HERE, add these two, in this order — and leave the Wait, Set Airplane Mode Off and Open URLs below them exactly where they are, so they run whatever happens:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // The toggle is not cosmetic and not optional-in-spirit: it is how a run
                        // started from the Shortcuts app, Siri, the Action Button or an automation
                        // tells Wander that the radio is off right now, which is the only reason
                        // Wander can notice an interrupted run and offer the recovery banner. It has
                        // to be a switch the user flips rather than something the app assumes,
                        // because this same action is a normal thing to run on Wi-Fi. See
                        // `StartTunnelIntent.cellularMode`.
                        actionToAdd("Start Wander Tunnel",
                                    L("cellular.setup.step4.a",
                                      fallback: "Search “Start Wander Tunnel” and tap it, then switch ON its “Cellular Mode run” option (tap Show More if you don't see it). That's what lets Wander notice if the run is interrupted and offer to put your signal back."))
                        actionToAdd("Teleport to Place",
                                    L("cellular.setup.step4.b",
                                      fallback: "Search “Teleport to Place”, tap it, then tap its Place field and choose Shortcut Input — that's how Wander hands it the pin you picked."))
                        Text(localized: "cellular.setup.step4.why",
                             fallback: "Wander can't pre-fill these: your copy is signed with your own Apple ID, so it has a bundle ID no downloaded file can know in advance.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }

                Section {
                    Button {
                        ShortcutRunner.cellularModeReady = true
                        dismiss()
                    } label: {
                        Label(L("cellular.setup.done", fallback: "I've added it — enable one-tap"),
                              systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                } footer: {
                    Text(localized: "cellular.setup.footer",
                         fallback: "If the button later asks you to set up again, the shortcut was renamed or deleted — re-add it. Nothing here toggles Airplane Mode on its own; it only ever runs when you tap.")
                }
            }
            .navigationTitle(L("cellular.setup.title", fallback: "Cellular Mode setup"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.close", fallback: "Close")) { dismiss() }
                }
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func actionToAdd(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.caption)
                .foregroundStyle(Wander.brand)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
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

    private func openURLString(_ s: String) {
        if let u = URL(string: s) { UIApplication.shared.open(u) }
    }

    private func openSettingsShortcuts() {
        // Best-effort deep link to the Shortcuts settings pane; fall back to the system Settings root.
        if let u = URL(string: "App-Prefs:root=SHORTCUTS"), UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else if let u = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(u)
        }
    }
}

#Preview {
    CellularModeSetupView()
}
