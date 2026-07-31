//
//  SpoofDoctorView.swift
//  Wander
//
//  The UI for SpoofDoctor — a one-tap "Check my setup" diagnostic that runs the two-rung ladder and shows
//  the EXACT fix for a failing gs-loc setup, with the right jump-to-Settings button attached to each cause.
//  Presented as a sheet from the PoGo screen, from the end of the setup wizard, and from the wizard's
//  CA-trust step (so a user who skipped the trust toggle finds out immediately).
//
//  The Doctor tailors its Rung-1 advice to whichever proxy app the user picked in the wizard (persisted in
//  @AppStorage), so the "isn't intercepting" fix speaks the right app's vocabulary.
//

import SwiftUI
import UIKit

struct SpoofDoctorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var doctor = SpoofDoctor()

    /// Which proxy app the setup wizard last selected — tailors Rung-1 fix text. Defaults to recommended.
    @AppStorage("gslocProxyApp") private var proxyAppRaw = ProxyApp.recommended.rawValue
    private var proxyApp: ProxyApp { ProxyApp(rawValue: proxyAppRaw) ?? .recommended }

    /// When presented from the wizard's CA-trust step, this jumps back there instead of opening iOS Settings
    /// directly — so the fix lands the user on the step they skipped. nil elsewhere.
    var onFixCertificateTrust: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    intro
                    resultCard
                    runButton
                }
                .padding()
            }
            .navigationTitle("Check my setup")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { doctor.run() }
            .onDisappear { doctor.reset() }
        }
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Spoof Doctor", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text("Two quick checks: first that your proxy is intercepting at all, then that the location is actually spoofed. You'll get the exact thing to fix.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Run button

    private var runButton: some View {
        Button {
            doctor.run()
        } label: {
            Label(doctor.isRunning ? "Checking…" : "Run the check again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity).frame(height: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(Wander.brand)
        .disabled(doctor.isRunning)
    }

    // MARK: Result

    @ViewBuilder
    private var resultCard: some View {
        switch doctor.stage {
        case .idle, .probing:
            progress("Checking whether your proxy is intercepting…")
        case .checkingLocation:
            progress("Proxy is intercepting. Checking your location…")

        case .notIntercepting:
            // Rung 1 failed: rules aren't firing. Plain-HTTP probe needs no CA trust, so this is purely a
            // routing / connection problem — surface the app-specific fix + a jump to VPN settings. A stale
            // or truncated import is a common cause here, so offer a one-tap re-import before the (heavier)
            // reinstall fallback.
            causeCard(
                tint: .orange,
                icon: "bolt.slash.fill",
                title: "Your proxy isn't intercepting",
                message: "The proxy's rules aren't firing yet. \(proxyApp.interceptionFixHint) Also make sure you're not on LocalDevVPN at the same time — iOS runs one VPN at a time, so it would steal the tunnel from \(proxyApp.title).",
                actions: [
                    reimportConfigAction,
                    .init(title: "Open VPN settings", icon: "network", url: "prefs:root=General&path=VPN")
                ],
                footnote: "Still not working? Fully quit and reinstall your proxy app, then re-import."
            )

        case .working(let d):
            causeCard(
                tint: .green,
                icon: "checkmark.seal.fill",
                title: "Everything's working",
                message: "Your proxy is intercepting and iOS is reporting your spoofed spot (within \(meters(d))). Pokémon GO reads the same fix.",
                actions: []
            )

        case .httpsNotLanding(let d):
            // Rung 1 passed but Rung 2 mismatched: rules fire, but the decrypted rewrite isn't taking. The
            // two live causes, each with its own fix.
            VStack(spacing: 12) {
                causeCard(
                    tint: .orange,
                    icon: "lock.trianglebadge.exclamationmark",
                    title: "Spoof isn't landing yet",
                    message: "Your proxy is intercepting, but iOS still reports a spot \(meters(d)) from your target. Two things cause this — check both:",
                    actions: []
                )
                subCause(
                    icon: "checkmark.shield",
                    title: "1. Certificate not trusted",
                    message: "The rewrite only works over HTTPS once the \(proxyApp.certificateName) certificate is trusted. \(proxyApp.caTrustHint)",
                    action: certificateTrustAction
                )
                subCause(
                    icon: "wifi.slash",
                    title: "2. Real GPS override / stale cache",
                    message: "A strong real GPS fix (or a cached location) can override the network fix. Turn Wi-Fi OFF in Settings (not just disconnect it), and reboot to flush the location cache (iOS 26+).",
                    action: .init(title: "Open Wi-Fi settings", icon: "wifi", url: "prefs:root=WIFI")
                )
            }

        case .noTarget:
            causeCard(
                tint: .secondary,
                icon: "location.slash",
                title: "No target set yet",
                message: "Teleport in Wander first, then run the check.",
                actions: []
            )

        case .locationDenied:
            causeCard(
                tint: .orange,
                icon: "location.slash.fill",
                title: "Location is off for Wander",
                message: "Wander needs Location access to read what iOS reports. Turn it on for Wander, then run the check again.",
                actions: [
                    .init(title: "Open Location Services", icon: "gear", url: "prefs:root=Privacy&path=LOCATION")
                ]
            )

        case .locationUnavailable:
            causeCard(
                tint: .secondary,
                icon: "questionmark.circle",
                title: "Couldn't get a fix",
                message: "No location came back. Make sure Location Services is on for Wander and try again.",
                actions: [
                    .init(title: "Open Location Services", icon: "gear", url: "prefs:root=Privacy&path=LOCATION")
                ]
            )
        }
    }

    /// One-tap re-import of the selected proxy app's Wander rewrite — the same deep-link/paste path the
    /// setup wizard uses. A stale or truncated config is a common "isn't intercepting" cause, and re-importing
    /// fixes it without the 30-minute reinstall detour. When the app has no reliable import deep link
    /// (e.g. Quantumult X), fall back to copying the link so the user can paste it into its resource list.
    private var reimportConfigAction: DoctorAction {
        if let deepLink = proxyApp.importDeepLink() {
            return .init(title: "Re-import config", icon: "square.and.arrow.down.on.square", url: deepLink)
        }
        return .init(title: "Copy config link", icon: "doc.on.doc") {
            UIPasteboard.general.string = proxyApp.importURL
        }
    }

    /// The CA-trust fix routes back to the wizard step when the Doctor was opened from there; otherwise it
    /// jumps straight to iOS's Certificate Trust Settings.
    private var certificateTrustAction: DoctorAction {
        if onFixCertificateTrust != nil {
            return .init(title: "Go to the certificate step", icon: "arrow.uturn.backward") {
                dismiss()
                onFixCertificateTrust?()
            }
        }
        return .init(title: "Open Certificate Trust Settings", icon: "checkmark.shield",
                     url: "prefs:root=General&path=About/CERT_TRUST_SETTINGS")
    }

    // MARK: Pieces

    private func progress(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func causeCard(tint: Color, icon: String, title: String, message: String,
                           actions: [DoctorAction], footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(actions) { action in
                actionButton(action)
            }
            if let footnote {
                Text(footnote).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func subCause(icon: String, title: String, message: String, action: DoctorAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(Wander.brand).frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.caption.weight(.semibold))
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actionButton(action)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .background(Color.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func actionButton(_ action: DoctorAction) -> some View {
        Button {
            if let run = action.run {
                run()
            } else if let urlString = action.url, let u = URL(string: urlString) {
                UIApplication.shared.open(u)
            }
        } label: {
            Label(action.title, systemImage: action.icon)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(Wander.brand)
    }

    private func meters(_ d: Double) -> String {
        d >= 1000 ? String(format: "%.1f km", d / 1000) : "\(Int(d.rounded())) m"
    }
}

/// A single fix button on a Doctor result: either opens a Settings URL or runs a closure (e.g. route back
/// to the wizard step).
private struct DoctorAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    var url: String?
    var run: (() -> Void)?

    init(title: String, icon: String, url: String) {
        self.title = title; self.icon = icon; self.url = url; self.run = nil
    }
    init(title: String, icon: String, run: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.url = nil; self.run = run
    }
}

#Preview {
    SpoofDoctorView()
}
