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
//  ══ WHAT USED TO BE STEP 4, AND WHY IT IS GONE ══
//
//  This card used to end with "Add the two Wander actions": open the imported shortcut in the
//  Shortcuts editor, search for `Start Wander Tunnel`, add it, search for `Teleport to Place`, add it,
//  set its Place field to Shortcut Input, delete two comments. Roughly a dozen taps in an editor most
//  people have never opened, and the step that quietly ended most setups.
//
//  It existed because those two actions were App Intents, and an App Intent action serialises the
//  target app's bundle id and team id — values that are different for every install, so no downloadable
//  file could contain them. The fix was not a cleverer file. It was to stop needing one: Wander
//  conducts the sequence itself now (`CellularModeSequence`) and the shortcut is reduced to the single
//  thing an app is not allowed to do — flip the switch. That file is built entirely from Shortcuts'
//  own actions, so it carries no identity, imports ready to run, and has nothing left to edit.
//
//  Setup is now: open Shortcuts once, allow untrusted shortcuts, add the file. Nothing in an editor.
//
//  THE FALLBACK IS STILL HERE ON PURPOSE. A .shortcut file has to be SIGNED to import (iOS 15+), and
//  if a published copy is ever unsigned, stale or unreachable the import simply refuses. So the old
//  all-in-one shortcut and its hand-add instructions stay one disclosure away, and `ShortcutRunner`
//  still runs whichever of the two the user actually has.
//

import SwiftUI
import UIKit

struct CellularModeSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showFallback = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(localized: "cellular.setup.intro",
                         fallback: "On mobile data with no Wi-Fi, iOS won't let the tunnel connect — but it stops checking once it's up. Cellular Mode turns Airplane Mode on just long enough to connect and set your location, then turns it back off. Your spoof holds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // Says the shape of the job before the numbered steps, because "three taps, nothing to
                // edit" is the actual news here and it should not be something you infer from the
                // absence of a fourth step.
                Section {
                    Label(L("cellular.setup.shape",
                            fallback: "Three steps, then you're done. Nothing to edit in the Shortcuts app — the shortcut you add does one thing, and Wander drives the rest itself."),
                          systemImage: "checkmark.seal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // HONEST NUMBER, not a comfortable one. The run is a 4 s settle, up to 12 s in
                // `WanderTunnel.ensureStarted()`, up to ~12 s in the teleport, plus the second
                // Shortcuts hop — roughly half a minute at worst, not the "few seconds" this used to
                // promise. Someone waiting on a call notices.
                Section {
                    Label(L("cellular.setup.cost",
                            fallback: "You'll see Shortcuts flash twice, and calls and data are off for up to about 30 seconds — usually less — while Wander connects and sets your location."),
                          systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(localized: "cellular.setup.cost.header", fallback: "What you'll see")
                }

                // The failure this feature actually has, named where the user meets the feature.
                Section {
                    Label(L("cellular.setup.interrupted",
                            fallback: "If you force-quit or cancel mid-run, Airplane Mode can be left on. Wander tells you and shows you how to switch it back off — you're never stuck without an explanation."),
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
                       fallback: "Tap below, then tap Add Shortcut. Make sure it is named EXACTLY “\(ShortcutRunner.airplaneName)” — Wander finds it by name. That's the whole thing; there is nothing inside it to fill in."),
                     button: (L("cellular.setup.step3.button", fallback: "Add “\(ShortcutRunner.airplaneName)”"),
                              { openURLString(ShortcutRunner.airplaneInstallURL) }))

                Section {
                    Button {
                        ShortcutRunner.airplaneReady = true
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

                fallbackSection
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

    // MARK: - Fallback
    //
    // COLLAPSED, NOT DELETED. Importing a .shortcut can fail for reasons that have nothing to do with
    // the user — an unsigned or stale published file is refused outright by iOS — and when it does,
    // the old all-in-one shortcut is still a working route. It costs a dozen taps in the Shortcuts
    // editor, which is exactly why it is no longer the main path, and exactly why it must not vanish.

    @ViewBuilder
    private var fallbackSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showFallback) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized: "cellular.setup.fallback.detail",
                         fallback: "There is an older shortcut that does the whole sequence by itself. It works, but you have to add two Wander actions to it by hand, because an action that calls an app stores that app's ID — and your copy of Wander is signed with your own Apple ID, so no downloaded file can know it in advance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(L("cellular.setup.fallback.add",
                             fallback: "Add “\(ShortcutRunner.cellularModeName)” instead")) {
                        openURLString(ShortcutRunner.cellularModeInstallURL)
                    }
                    .font(.subheadline.weight(.semibold))

                    actionToAdd("Start Wander Tunnel",
                                L("cellular.setup.fallback.a",
                                  fallback: "Open it, find the first “ADD THE WANDER ACTION HERE” comment, tap +, search “Start Wander Tunnel”, add it, delete the comment."))
                    actionToAdd("Teleport to Place",
                                L("cellular.setup.fallback.b",
                                  fallback: "Same for the second comment: search “Teleport to Place”, add it, tap its Place field and choose Shortcut Input — that's how Wander hands it the pin you picked."))

                    Button(L("cellular.setup.fallback.done",
                             fallback: "I've added the old one — enable one-tap")) {
                        ShortcutRunner.cellularModeReady = true
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
                }
                .padding(.top, 4)
            } label: {
                Text(localized: "cellular.setup.fallback.title",
                     fallback: "If it won't import")
                    .font(.subheadline.weight(.semibold))
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
