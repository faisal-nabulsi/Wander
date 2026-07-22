//
//  ShadowrocketSetupView.swift
//  Wander
//
//  Guided setup for the EXPERIMENTAL PoGo (gs-loc) mode. It walks the user through installing the
//  Shadowrocket proxy, importing the Wander gs-loc module, installing + TRUSTING the MITM certificate,
//  and connecting the VPN. Most steps are best-effort deep-links with a manual tap-path fallback (iOS
//  can silently change these paths between versions, so nothing is load-bearing on the deep link).
//
//  DELIBERATE DESIGN — the certificate-trust step is NOT frictionless, on purpose. A trusted MITM root
//  CA can decrypt HTTPS device-wide (banking, mail, everything) while it's on. The friction there IS
//  the informed-consent mechanism: we state the blast radius plainly, require an explicit acknowledg
//  before revealing the button, and always show one-tap teardown. The other four steps are optimized
//  for speed; this one is optimized for comprehension.
//
//  HONEST LIMIT surfaced up-front: gs-loc only holds indoors / with weak GPS. It is NOT a full outdoor
//  spoof (real GPS overrides it). We say so before the user invests any setup effort.
//
import SwiftUI
import Network
import UIKit

// MARK: - Best-effort VPN detection

/// Lightweight "is a proxy VPN active?" hint. Shadowrocket, when connected, installs a scoped system
/// proxy — that's a more reliable signal than a bare utun interface (utun0 always exists). Used only to
/// auto-advance the "Connect VPN" step; every other step falls back to a manual gate.
@MainActor
final class ProxyVPNMonitor: ObservableObject {
    @Published var active = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wander.proxyvpn.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let vpnLike = path.availableInterfaces.contains {
                let n = $0.name
                return n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") || n.hasPrefix("tap")
            }
            let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
            let hasProxy = proxySettings?.keys.contains {
                $0.hasPrefix("HTTP") || $0.hasPrefix("SOCKS") || $0 == "__SCOPED__"
            } ?? false
            Task { @MainActor in self?.active = vpnLike && hasProxy }
        }
        monitor.start(queue: queue)
    }

    func recheck() { /* NWPathMonitor pushes updates; foregrounding re-fires the handler. */ }
    deinit { monitor.cancel() }
}

// MARK: - Wizard

struct ShadowrocketSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vpn = ProxyVPNMonitor()

    /// Manually-confirmed steps (1...4). Step 5 (VPN) auto-detects via the monitor.
    @State private var confirmed: Set<Int> = []
    /// The CA step reveals its action only after the user acknowledges what they're trusting.
    @State private var caAcknowledged = false

    private let moduleURL = "https://wander-payments.wanderlocation.workers.dev/gsloc/wander.sgmodule"
    private let appStoreURL = "itms-apps://apps.apple.com/app/id932747118"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    intro
                    step1
                    step2
                    step3
                    step4          // the informed CA-trust step
                    step5
                    teardownCard
                }
                .padding()
            }
            .navigationTitle(L("gsloc.setup.title", fallback: "PoGo gs-loc setup"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
    }

    // MARK: Intro (honest limits first)

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("gsloc.setup.intro.title", fallback: "What this does — and doesn't"),
                  systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text(L("gsloc.setup.intro.body",
                   fallback: "This routes Pokémon GO's location through a Wi-Fi-location proxy instead of the dev tunnel, so the game sees a non-simulated fix (no Error 12). It works ONLY while you're indoors or where GPS is weak — outdoors, real GPS overrides it and snaps you back. It's a sit-still tool, not a walk-around one. Setup takes about 5 minutes and involves trusting a certificate (read step 4 carefully)."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(L("gsloc.setup.intro.vpnswap",
                    fallback: "This mode replaces LocalDevVPN. iOS runs only one VPN at a time, so while you're using it, keep LocalDevVPN OFF and Shadowrocket ON. Turn PoGo mode off in Settings to switch back to normal spoofing over LocalDevVPN."),
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Steps 1-3, 5 (fast, plumbing)

    private var step1: some View {
        stepCard(
            n: 1, done: confirmed.contains(1),
            icon: "arrow.down.app.fill",
            title: L("gsloc.setup.s1.title", fallback: "Install Shadowrocket"),
            detail: L("gsloc.setup.s1.detail", fallback: "It's a paid (~$3) proxy app on the App Store. Tap below, get it, then come back."),
            primary: ("Open in App Store", appStoreURL),
            manualPath: nil,
            gate: 1
        )
    }

    private var step2: some View {
        stepCard(
            n: 2, done: confirmed.contains(2),
            icon: "square.and.arrow.down.on.square",
            title: L("gsloc.setup.s2.title", fallback: "Import the Wander module"),
            detail: L("gsloc.setup.s2.detail", fallback: "Adds the gs-loc rewrite + the Wander bridge to Shadowrocket. Tap to import; if it doesn't open Shadowrocket, use “Copy module link” and paste it in Shadowrocket → Configuration → Modules → +."),
            primary: ("Import into Shadowrocket", "shadowrocket://install?module=\(moduleURL)"),
            manualPath: nil,
            gate: 2,
            extraButton: ("Copy module link", { UIPasteboard.general.string = moduleURL })
        )
    }

    private var step3: some View {
        stepCard(
            n: 3, done: confirmed.contains(3),
            icon: "lock.shield",
            title: L("gsloc.setup.s3.title", fallback: "Turn on HTTPS Decryption + install the certificate"),
            detail: L("gsloc.setup.s3.detail", fallback: "In Shadowrocket: Configuration → tap the ⓘ → HTTPS Decryption → Certificate → Generate, then Install. iOS shows “Profile Downloaded” — open Settings and install it (this button jumps you there)."),
            primary: ("Open installed profiles", "prefs:root=General&path=ManagedConfigurationList"),
            manualPath: "Settings › General › VPN & Device Management",
            gate: 3
        )
    }

    private var step5: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(n: 5, done: vpn.active,
                       icon: "antenna.radiowaves.left.and.right",
                       title: L("gsloc.setup.s5.title", fallback: "Connect the VPN"))
            Text(L("gsloc.setup.s5.detail", fallback: "Open Shadowrocket and flip the top toggle on. Then reboot once (iOS caches your real location), turn Wi-Fi on, and check Apple Maps. This card turns green on its own when it detects the proxy."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                linkButton("Open VPN settings", url: "prefs:root=General&path=VPN")
                Spacer()
                Label(vpn.active ? L("gsloc.setup.vpn.on", fallback: "Proxy detected")
                                 : L("gsloc.setup.vpn.off", fallback: "Not detected yet"),
                      systemImage: vpn.active ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(vpn.active ? .green : .secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Step 4 — the informed CA-trust step (deliberately not frictionless)

    private var step4: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(n: 4, done: confirmed.contains(4),
                       icon: "exclamationmark.shield.fill",
                       title: L("gsloc.setup.s4.title", fallback: "Trust the certificate — read this first"))

            Text(L("gsloc.setup.s4.body",
                   fallback: "This next toggle lets the proxy read secure (HTTPS) traffic on your phone. While it's on, this certificate could in principle let traffic to ANY website — your bank, email, anything — be read on this device. Only turn it on if you set this up yourself just now, keep it on only while you're playing, and turn it off after (see “Turn it all off” below)."))
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("gsloc.setup.s4.scope",
                   fallback: "Wander's module only ever decrypts Apple's location lookup — nothing personal — but a trusted certificate is device-wide, so we're telling you the full blast radius, not just what we use."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $caAcknowledged) {
                Text(L("gsloc.setup.s4.ack", fallback: "I understand this lets HTTPS on my phone be read while it's on."))
                    .font(.caption.weight(.medium))
            }
            .tint(Wander.brand)

            if caAcknowledged {
                linkButton("Open Certificate Trust Settings",
                           url: "prefs:root=General&path=About/CERT_TRUST_SETTINGS")
                Text(L("gsloc.setup.s4.manual",
                       fallback: "Manually: Settings › General › About › Certificate Trust Settings → turn on the Shadowrocket certificate."))
                    .font(.caption2).foregroundStyle(.tertiary)
                confirmButton(4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
        )
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Teardown (easy off = a first-class action)

    private var teardownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("gsloc.setup.teardown.title", fallback: "Turn it all off"),
                  systemImage: "xmark.shield")
                .font(.subheadline.weight(.semibold))
            Text(L("gsloc.setup.teardown.body",
                   fallback: "When you're done playing: 1) Settings › General › About › Certificate Trust Settings → turn the Shadowrocket certificate OFF. 2) Settings › General › VPN & Device Management → delete the profile. 3) Disconnect the VPN in Shadowrocket. Any one of these stops all decryption; do the first when you're not actively playing."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            linkButton("Open Certificate Trust Settings",
                       url: "prefs:root=General&path=About/CERT_TRUST_SETTINGS")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Reusable pieces

    private func stepHeader(n: Int, done: Bool, icon: String, title: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.15) : Wander.brand.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(done ? .green : Wander.brand)
            }
            Text("\(n). \(title)").font(.body.weight(.semibold))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stepCard(n: Int, done: Bool, icon: String, title: String, detail: String,
                          primary: (String, String), manualPath: String?, gate: Int,
                          extraButton: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(n: n, done: done, icon: icon, title: title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            linkButton(primary.0, url: primary.1)
            if let manualPath {
                Text(manualPath).font(.caption2).foregroundStyle(.tertiary)
            }
            if let extraButton {
                Button(extraButton.0, action: extraButton.1)
                    .font(.caption.weight(.medium))
                    .tint(Wander.brand)
            }
            confirmButton(gate)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func confirmButton(_ step: Int) -> some View {
        Button {
            if confirmed.contains(step) { confirmed.remove(step) } else { confirmed.insert(step) }
        } label: {
            Label(confirmed.contains(step)
                    ? L("gsloc.setup.done", fallback: "Done ✓")
                    : L("gsloc.setup.mark", fallback: "I've done this"),
                  systemImage: confirmed.contains(step) ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(confirmed.contains(step) ? .green : Wander.brand)
        }
        .padding(.top, 2)
    }

    /// Best-effort deep link: attempt to open; the caller always shows a manual path too, so a no-op is
    /// harmless. Private `prefs:`/`shadowrocket:` schemes can change between iOS/app versions.
    private func linkButton(_ title: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { UIApplication.shared.open(u) }
        } label: {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Image(systemName: "arrow.up.right.square").font(.caption2)
            }
            .foregroundStyle(Wander.brand)
        }
    }
}

#Preview {
    ShadowrocketSetupView()
}
