//
//  GslocCASetupView.swift
//  Wander
//
//  Guided install of Wander's root CA — the one manual gate the in-app gs-loc engine cannot remove.
//  Every step is verified where iOS allows it, so the user is never told "you're done" on faith.
//

import SwiftUI

struct GslocCASetupView: View {
    @StateObject private var ca = GslocCAInstall()
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    trustBanner
                } header: {
                    Text("Status")
                } footer: {
                    Text("Wander checks this itself — it evaluates a real certificate against the system trust store, so the badge flips to trusted only when both steps below are genuinely done.")
                }

                Section("What this is") {
                    Text("To let Wander rewrite Apple's Wi-Fi location lookup on-device — the thing that removes the need for Shadowrocket — your iPhone has to trust a certificate Wander generates. The private key is made on THIS device and never leaves it; it is not shipped in the app, so no one who downloads Wander can impersonate anything to you.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Step 1 — install") {
                    step(1, "Tap **Download certificate**. Safari opens and says “This website is trying to download a configuration profile.” Tap **Allow**.")
                    Button {
                        ca.startServing()
                    } label: {
                        Label("Prepare certificate", systemImage: "doc.badge.gearshape")
                    }
                    if let url = ca.downloadURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Download certificate", systemImage: "safari")
                                .fontWeight(.semibold)
                        }
                    }
                    step(2, "Go to **Settings → General → VPN & Device Management** (near the top it now shows **Profile Downloaded**). Tap the Wander profile, then **Install**.")
                }

                Section("Step 2 — enable full trust") {
                    step(3, "This is the step almost everyone misses. Go to **Settings → General → About → Certificate Trust Settings**.")
                    step(4, "Under **Enable full trust for root certificates**, turn **ON** the switch for **Wander Local CA**.")
                    Text("Without this, iOS installs the certificate but never uses it, and the spoof silently does nothing.")
                        .font(.caption).foregroundStyle(.orange)
                }

                Section {
                    Button {
                        ca.refreshTrust()
                    } label: {
                        Label("Check trust", systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    if let err = ca.lastError {
                        Text(err).foregroundStyle(.orange)
                    }
                }

                Section("Removing it later") {
                    Text("To undo everything: Settings → General → VPN & Device Management → the Wander profile → Remove Profile. That deletes the certificate and the trust in one step.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Trust Wander's certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ca.stopServing(); dismiss() }
                }
            }
            .onAppear { ca.refreshTrust() }
        }
    }

    @ViewBuilder
    private var trustBanner: some View {
        switch ca.trustState {
        case .trusted:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Certificate trusted").fontWeight(.semibold)
                    Text("Both steps are done. The in-app engine can decrypt and rewrite the WPS lookup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        case .notTrusted:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Not trusted yet").fontWeight(.semibold)
                    Text("Finish both steps below, then tap Check trust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "xmark.shield.fill").foregroundStyle(.orange) }
        case .unknown:
            Label("Tap Check trust to test.", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(.init(text))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
