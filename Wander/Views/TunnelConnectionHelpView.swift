//
//  TunnelConnectionHelpView.swift
//  Wander
//
//  In-app troubleshooting for the developer tunnel (LocalDevVPN) not connecting or dropping. The
//  tunnel is Apple's on-device developer tunnel — NOT an IP-VPN — and it's what carries the injected
//  location to the device. If it won't come up or keeps dropping, the game stops getting a fix. This
//  screen walks the user through the common connection fixes: keep Wander foregrounded, connect on
//  Wi-Fi (or the airplane-mode-first trick without Wi-Fi), free up memory, and a clean reconnect.
//  Reachable from Settings → Help. Uses the shared material-card look and Wander.brand accent.
//

import SwiftUI

struct TunnelConnectionHelpView: View {
    @Environment(\.dismiss) private var dismiss

    /// One step in the connection-fix checklist.
    private struct Step: Identifiable {
        let id = UUID()
        let number: Int
        let icon: String
        let title: String
        let detail: String
    }

    private var steps: [Step] {
        [
            Step(
                number: 1,
                icon: "app.badge.checkmark",
                title: L("tunnel.step.foreground.title",
                         fallback: "Keep Wander in the foreground"),
                detail: L("tunnel.step.foreground.detail",
                          fallback: "The tunnel needs Wander open and on screen while it connects. If you swipe Wander away or lock the phone before it's up, the connection can fail. Open Wander first, then connect.")
            ),
            Step(
                number: 2,
                icon: "wifi",
                title: L("tunnel.step.wifi.title",
                         fallback: "Connect on Wi-Fi"),
                detail: L("tunnel.step.wifi.detail",
                          fallback: "The tunnel is most reliable over Wi-Fi. Join a Wi-Fi network, then open LocalDevVPN and connect. If it connects on Wi-Fi, you can usually stay connected after switching Wi-Fi off.")
            ),
            Step(
                number: 3,
                icon: "airplane",
                title: L("tunnel.step.airplane.title",
                         fallback: "No Wi-Fi? Use the airplane-mode-first trick"),
                detail: L("tunnel.step.airplane.detail",
                          fallback: "Turn Airplane Mode ON, then open LocalDevVPN and connect the tunnel, then turn Wi-Fi back on. This brings the tunnel up cleanly without a Wi-Fi network to start.")
            ),
            Step(
                number: 4,
                icon: "memorychip",
                title: L("tunnel.step.memory.title",
                         fallback: "Free up memory if it keeps dropping"),
                detail: L("tunnel.step.memory.detail",
                          fallback: "Low memory or too many apps in the background can make iOS drop the tunnel. Close some background apps (and Pokémon GO if it's a heavy session), then reconnect.")
            ),
            Step(
                number: 5,
                icon: "arrow.clockwise",
                title: L("tunnel.step.reconnect.title",
                         fallback: "Clean reconnect"),
                detail: L("tunnel.step.reconnect.detail",
                          fallback: "If the tunnel is stuck, disconnect it in LocalDevVPN, make sure Wander is open, then connect again. If it still won't come up, reopen LocalDevVPN and Wander and try the steps above in order.")
            ),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    downloadCard

                    // The connection-fix checklist, as material cards.
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            stepRow(step)
                            if index < steps.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    notVPNCard

                    Text(L("tunnel.footer.discord",
                           fallback: "Still can't connect? Tell us in the Discord #bug-reports channel."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding()
            }
            .navigationTitle(L("tunnel.title", fallback: "Tunnel won't connect?"))
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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector.horizontal")
                .font(.largeTitle)
                .foregroundStyle(Wander.brand)
            Text(L("tunnel.intro",
                   fallback: "The tunnel is what carries Wander's location to your device. If LocalDevVPN won't connect or keeps dropping, the game loses its fix. These steps get it connected and keep it up."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Download prompt

    /// Explicit "install it first" prompt — the steps below assume LocalDevVPN is already installed, so
    /// a new user who lands here needs the App Store link before anything else.
    private var downloadCard: some View {
        Link(destination: URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.title2)
                    .foregroundStyle(Wander.brand)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("tunnel.download.title", fallback: "Don't have LocalDevVPN yet?"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L("tunnel.download.detail",
                           fallback: "It's a free app on the App Store — install it first, then follow the steps below to connect the tunnel."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step row

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Wander.brand.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: step.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Wander.brand)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(step.number). \(step.title)")
                    .font(.body.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    // MARK: - "Not an IP-VPN" clarification card

    private var notVPNCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("tunnel.notvpn.header", fallback: "What this tunnel is"),
                  systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(L("tunnel.notvpn.body",
                   fallback: "This is Apple's on-device developer tunnel — not an IP-VPN. It doesn't change your IP address, route your web traffic, or hide anything on the network. It only carries Wander's location to your device on this phone."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    TunnelConnectionHelpView()
}
