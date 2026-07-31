//
//  ProxySetupView.swift
//  Wander
//
//  Guided setup for the EXPERIMENTAL PoGo (gs-loc) mode. Generalized from the old Shadowrocket-only wizard:
//  a picker at the top lets the user run the SAME flow through whichever supported proxy app they own
//  (Shadowrocket, Loon, Quantumult X, Stash). The selected app (see ProxyApp) drives the import URL, the
//  App Store link, and the app-specific certificate/HTTPS-decryption path text; Shadowrocket stays the
//  default/recommended. It walks the user through installing the proxy, importing the Wander gs-loc rewrite,
//  installing + TRUSTING the MITM certificate, and connecting the VPN. Most steps are best-effort deep-links
//  with a manual tap-path fallback (iOS/apps can silently change these paths, so nothing is load-bearing on
//  the deep link).
//
//  DELIBERATE DESIGN — the certificate-trust step is NOT frictionless, on purpose. A trusted MITM root CA
//  can decrypt HTTPS device-wide (banking, mail, everything) while it's on. The friction there IS the
//  informed-consent mechanism: we state the blast radius plainly, require an explicit acknowledgment before
//  revealing the button, and always show one-tap teardown. The other steps are optimized for speed; this
//  one is optimized for comprehension.
//
//  HONEST LIMIT surfaced up-front: gs-loc only holds indoors / with weak GPS. It is NOT a full outdoor
//  spoof (real GPS overrides it). We say so before the user invests any setup effort.
//
//  At the end (and on the CA-trust step) a "Check my setup" button runs the Spoof Doctor (SpoofDoctorView),
//  so a user who skipped the trust toggle or mis-set routing finds out immediately, with the exact fix.
//
import SwiftUI
import Network
import UIKit

// MARK: - Best-effort VPN detection

/// Lightweight "is a proxy VPN active?" hint. A connected proxy app installs a scoped system proxy —
/// that's a more reliable signal than a bare utun interface (utun0 always exists). Used only to
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

struct ProxySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vpn = ProxyVPNMonitor()

    /// The selected proxy app drives every parameterized step. Persisted so the Spoof Doctor can tailor its
    /// Rung-1 advice to the same app the user set up here.
    @AppStorage("gslocProxyApp") private var appRaw = ProxyApp.recommended.rawValue
    private var app: ProxyApp { ProxyApp(rawValue: appRaw) ?? .recommended }

    /// Manually-confirmed steps (1...4). Step 5 (VPN) auto-detects via the monitor.
    @State private var confirmed: Set<Int> = []
    /// The CA step reveals its action only after the user acknowledges what they're trusting.
    @State private var caAcknowledged = false
    /// Seed the passthrough exactly once, on the first detected proxy connect — re-firing on every reconnect
    /// would clobber an active teleport back to the real location.
    @State private var seededPassthrough = false
    /// Presents the Spoof Doctor diagnostic.
    @State private var showDoctor = false

    private let caStepID = "caStep"

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 16) {
                        intro
                        appPicker            // choose which proxy app to set up
                        if app.supportsConfigAccelerator {
                            betaConfigCard   // Shadowrocket-only one-import accelerator for steps 2–3
                        }
                        step1
                        step2
                        step3
                        step4                // the informed CA-trust step
                            .id(caStepID)
                        step5
                        doctorCard           // "Check my setup" at the end of the wizard
                        usageSection         // how to spoof / re-teleport / reset, once set up
                        teardownCard
                    }
                    .padding()
                }
                .scrollContentBackground(.hidden)
                .background(Color.blue.opacity(0.07).ignoresSafeArea())
                // When the CA-trust cause fires in the Doctor, route back to step 4 (the CA-trust step)
                // rather than into iOS Settings — the step is where the toggle is explained.
                .sheet(isPresented: $showDoctor) {
                    SpoofDoctorView(onFixCertificateTrust: {
                        withAnimation { scroll.scrollTo(caStepID, anchor: .top) }
                    })
                }
            }
            .navigationTitle("PoGo gs-loc setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // When the proxy comes up, seed the store to passthrough so you land on your REAL location
            // instead of the module's default (which the rewriter falls back to on an empty store). This is
            // the reliable trigger — firing only on the Settings toggle misses the common case where the
            // proxy isn't connected yet at toggle time.
            .onChange(of: vpn.active) { _, active in
                if active && !seededPassthrough {
                    seededPassthrough = true
                    GslocMode.reset()
                }
            }
        }
    }

    // MARK: Proxy-app picker

    private var appPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Which proxy app do you use?", systemImage: "app.badge.checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text("Pick the proxy app you own — the steps below adjust to it. Don't have one? Shadowrocket is the recommended, field-tested choice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Proxy app", selection: $appRaw) {
                ForEach(ProxyApp.allCases) { proxyApp in
                    Text(proxyApp.isRecommended ? "\(proxyApp.title) (recommended)" : proxyApp.title)
                        .tag(proxyApp.rawValue)
                }
            }
            .pickerStyle(.menu)
            .tint(Wander.brand)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Beta one-import accelerator (Shadowrocket only)

    // A .sgmodule can only carry the scripts + which hosts to decrypt — the user still hand-flips "HTTPS
    // Decryption ON" (step 3). A full CONFIG can carry "[MITM] enable = true", so importing it does steps
    // 2–3 in one shot. It does NOT bundle a certificate (that would put one shared private key in a public
    // file), so step 4's generate-and-trust stays. Marked beta: config import replaces the active config,
    // and whether a URL-imported config honors the inline decryption toggle is still being field-tested.
    @ViewBuilder
    private var betaConfigCard: some View {
        if let configURL = app.configURL, let configDeepLink = app.configDeepLink() {
            VStack(alignment: .leading, spacing: 10) {
                Label("Faster setup (beta): one import", systemImage: "bolt.badge.clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Wander.brand)
                Text("Instead of steps 2–3, import a single Wander config that already has the rewrite AND HTTPS Decryption switched on. You still do step 1 (install \(app.title)), step 4 (generate + trust the certificate), and step 5 (connect) — the config can't trust the certificate for you. If the spoof doesn't work after importing, re-import the config (a partial or stale import fails silently) or tap “Check my setup” below — you shouldn't need to reinstall \(app.title). Best if you use \(app.title) only for Wander — importing a full config replaces your active one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    linkButton("Import Wander config", url: configDeepLink)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = configURL
                    } label: {
                        Label("Copy config link", systemImage: "doc.on.doc").font(.caption)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    // MARK: Intro (honest limits first)

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What this does — and doesn't", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text("This routes Pokémon GO's location through a Wi-Fi-location proxy instead of the dev tunnel, so the game sees a non-simulated fix (no Error 12 — or the related Error 11, the same transient location cross-check that flashes up then reverts; the same fixes clear both). It works ONLY while you're indoors or where GPS is weak — outdoors, real GPS overrides it and snaps you back. It's a sit-still tool, not a walk-around one. Setup takes about 5 minutes and involves trusting a certificate (read step 4 carefully).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("This mode replaces LocalDevVPN. iOS runs only one VPN at a time, so while you're using it, keep LocalDevVPN OFF and your proxy app ON. Turn PoGo mode off in Settings to switch back to normal spoofing over LocalDevVPN.",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Steps

    private var step1: some View {
        stepCard(
            n: 1, done: confirmed.contains(1),
            icon: "arrow.down.app.fill",
            title: "Install \(app.title)",
            detail: "\(app.title) is a paid proxy app on the App Store. Tap below, get it, then come back.",
            primary: ("Open in App Store", app.appStoreURL),
            manualPath: nil,
            gate: 1
        )
    }

    private var step2: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(n: 2, done: confirmed.contains(2),
                       icon: "square.and.arrow.down.on.square",
                       title: "Import the Wander \(app.moduleNoun)")
            Text("Adds the gs-loc rewrite + the Wander bridge to \(app.title). Tap to import; if it doesn't open \(app.title), use “Copy link” and paste it in. \(app.importManualPath)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let deepLink = app.importDeepLink() {
                linkButton("Import into \(app.title)", url: deepLink)
            }
            Button("Copy \(app.moduleNoun) link") {
                UIPasteboard.general.string = app.importURL
            }
            .font(.caption.weight(.medium))
            .tint(Wander.brand)
            confirmButton(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var step3: some View {
        stepCard(
            n: 3, done: confirmed.contains(3),
            icon: "lock.shield",
            title: "Turn on HTTPS Decryption + install the certificate",
            detail: "\(app.httpsDecryptionHint) This button jumps you to installed profiles in Settings.",
            primary: ("Open installed profiles", "prefs:root=General&path=ManagedConfigurationList"),
            manualPath: "Settings › General › VPN & Device Management",
            gate: 3,
            callout: "In Settings › General › VPN & Device Management, tap the CONFIGURATION PROFILE for \(app.title) — NOT the VPN entry with the same name. Installing the profile is what adds the certificate; tapping the VPN row does nothing here."
        )
    }

    private var step5: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepHeader(n: 5, done: vpn.active,
                       icon: "antenna.radiowaves.left.and.right",
                       title: "Connect the VPN")
            Text("Open \(app.title) and flip the top toggle on. Then reboot once (iOS caches your real location), turn Wi-Fi on, and check Apple Maps. This card turns green on its own when it detects the proxy.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                linkButton("Open VPN settings", url: "prefs:root=General&path=VPN")
                Spacer()
                Label(vpn.active ? "Proxy detected" : "Not detected yet",
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
                       title: "Trust the certificate — read this first")

            Text("This next toggle lets the proxy read secure (HTTPS) traffic on your phone. While it's on, this certificate could in principle let traffic to ANY website — your bank, email, anything — be read on this device. Only turn it on if you set this up yourself just now, keep it on only while you're playing, and turn it off after (see “Turn it all off” below).")
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Wander's rewrite only ever decrypts Apple's location lookup — nothing personal — but a trusted certificate is device-wide, so we're telling you the full blast radius, not just what we use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $caAcknowledged) {
                Text("I understand this lets HTTPS on my phone be read while it's on.")
                    .font(.caption.weight(.medium))
            }
            .tint(Wander.brand)

            if caAcknowledged {
                linkButton("Open Certificate Trust Settings",
                           url: "prefs:root=General&path=About/CERT_TRUST_SETTINGS")
                Text("Manually: \(app.caTrustHint)")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                confirmButton(4)
                // Verify right here — a user who skipped the trust toggle finds out immediately instead of
                // discovering it only in-game.
                Button {
                    showDoctor = true
                } label: {
                    Label("Verify — check my setup", systemImage: "stethoscope")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Wander.brand)
                }
                .padding(.top, 2)
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

    // MARK: Spoof Doctor entry (end of wizard)

    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Did it work?", systemImage: "stethoscope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
            Text("Runs two quick checks — is your proxy intercepting, and is the location actually spoofed — and tells you the exact thing to fix if not.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showDoctor = true
            } label: {
                Label("Check my setup", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Wander.brand)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Teardown (easy off = a first-class action)

    private var teardownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn it all off", systemImage: "xmark.shield")
                .font(.subheadline.weight(.semibold))
            Text("When you're done playing: 1) Settings › General › About › Certificate Trust Settings → turn the \(app.certificateName) certificate OFF. 2) Settings › General › VPN & Device Management → delete the profile. 3) Disconnect the VPN in \(app.title). Any one of these stops all decryption; do the first when you're not actively playing.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            linkButton("Open Certificate Trust Settings",
                       url: "prefs:root=General&path=About/CERT_TRUST_SETTINGS")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: How to spoof (usage flow, after setup)

    private var usageSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill.viewfinder").foregroundStyle(Wander.brand)
                Text("How to spoof, once you're set up")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.top, 6)

            howToCard(
                icon: "1.circle.fill",
                title: "First spoof (once each session)",
                steps: [
                    "Keep Wi-Fi on. Turn Location Services OFF.",
                    "Reboot your iPhone.",
                    "Open \(app.title) and connect it (VPN icon shows).",
                    "Open Wander and teleport to your spot.",
                    "Turn Location Services back ON.",
                    "Check Apple Maps — you're at the spot. Then open Pokémon GO.",
                ],
                note: "The reboot clears iOS's cached real location, so the first fresh look lands on your spot."
            )

            howToCard(
                icon: "2.circle.fill",
                title: "Teleport again (no reboot)",
                steps: [
                    "Teleport in Wander to the new spot.",
                    "Toggle Location Services OFF, then ON.",
                    "It jumps to the new spot. Repeat for each hop.",
                ],
                note: "No reboot per teleport — the Location Services toggle is the quick flush. If a spot sticks, redo the First-spoof reboot once."
            )

            howToCard(
                icon: "arrow.uturn.backward.circle.fill",
                title: "Reset to your REAL location",
                steps: [
                    "Turn OFF PoGo (gs-loc) mode in Settings → Experimental — this tells the spoof to stop.",
                    "Toggle Location Services OFF, then ON.",
                    "You're back on your real location. If it lingers, disconnect \(app.title) too, then toggle Location Services again.",
                ],
                note: "Same idea in reverse: stop the spoof first, then force a fresh look so iOS grabs your real spot."
            )
        }
    }

    private func howToCard(icon: String, title: String, steps: [String], note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(Wander.brand).frame(width: 28)
                Text(title).font(.body.weight(.semibold))
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").font(.caption.weight(.bold)).foregroundStyle(Wander.brand)
                        Text(s).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            linkButton("Open Location Services", url: "prefs:root=Privacy&path=LOCATION")
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
                          extraButton: (String, () -> Void)? = nil, callout: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stepHeader(n: n, done: done, icon: icon, title: title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let callout {
                Label {
                    Text(callout).font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
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
            Label(confirmed.contains(step) ? "Done ✓" : "I've done this",
                  systemImage: confirmed.contains(step) ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(confirmed.contains(step) ? .green : Wander.brand)
        }
        .padding(.top, 2)
    }

    /// Best-effort deep link: attempt to open; the caller always shows a manual path too, so a no-op is
    /// harmless. Private `prefs:`/proxy-app schemes can change between iOS/app versions.
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
    ProxySetupView()
}
