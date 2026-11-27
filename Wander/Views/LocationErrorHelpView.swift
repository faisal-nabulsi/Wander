//
//  LocationErrorHelpView.swift
//  Wander
//
//  In-app troubleshooting for Pokémon GO's "Failed to detect location. (12)" error. The in-app
//  movement bug that caused most Error 12 is already fixed in the app; this screen walks the user
//  through the remaining EXTERNAL / user-side causes — Location Services, refreshing the fix after a
//  teleport, respecting the soft-ban cooldown after INTERACTING (not after teleporting), moving
//  smoothly, and keeping the tunnel connected. Reachable from the Pokémon GO tab and from Settings →
//  Help. Uses the shared material-card look (SetupChecklistView) and Wander.brand accent.
//

import SwiftUI

struct LocationErrorHelpView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showTunnelHelp = false

    /// One step in the fix checklist.
    private struct Step: Identifiable {
        let id = UUID()
        let number: Int
        let icon: String
        let title: String
        let detail: String
    }

    /// One entry in the error-taxonomy / "which error is it?" guide.
    private struct ErrorCase: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    /// One rung on the plain-language ban ladder.
    private struct BanRung: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private var errorCases: [ErrorCase] {
        [
            ErrorCase(
                icon: "wifi.slash",
                title: L("error12.taxonomy.err11.title",
                         fallback: "No location at all"),
                detail: L("error12.taxonomy.err11.detail",
                          fallback: "The game is getting no location stream, usually because the tunnel or connection dropped. Make sure Wander is open with the tunnel connected, reconnect it, then reopen the game.")
            ),
            ErrorCase(
                icon: "waveform.path.ecg",
                title: L("error12.taxonomy.err12.title",
                         fallback: "A bad or jumpy location"),
                detail: L("error12.taxonomy.err12.detail",
                          fallback: "The location is arriving but looks inconsistent to the game. Set the game's Location to Always + Precise; try the airplane-mode method (Airplane Mode ON, connect the tunnel, then Wi-Fi back on) for a clean fix right after a location change. If the location keeps snapping back, turn Location Services off for a full ~10 seconds, not a quick flick, and wait until Maps shows a location again after you turn it back on. Only if that still snaps back is it worth rebooting.")
            ),
            ErrorCase(
                icon: "person.badge.key",
                title: L("error12.taxonomy.auth.title",
                         fallback: "\"Unable to authenticate\" — a login problem, not a GPS one"),
                detail: L("error12.taxonomy.auth.detail",
                          fallback: "This one isn't about location. Log into the game BEFORE connecting the tunnel: sign in while you're still on your real GPS, then connect the tunnel and teleport.")
            ),
        ]
    }

    private var banRungs: [BanRung] {
        [
            BanRung(
                icon: "hourglass",
                title: L("error12.ban.softban.title",
                         fallback: "Suggested wait"),
                detail: L("error12.ban.softban.detail",
                          fallback: "A game may temporarily limit some in-game actions. Waiting is usually all you can do, and a suggested wait can't prevent it.")
            ),
            BanRung(
                icon: "1.circle",
                title: L("error12.ban.strike1.title",
                         fallback: "Warnings"),
                detail: L("error12.ban.strike1.detail",
                          fallback: "A game may show a warning or reduce rewards for a while. Play normally until it passes.")
            ),
            BanRung(
                icon: "exclamationmark.2",
                title: L("error12.ban.strike23.title",
                         fallback: "Suspensions and permanent bans"),
                detail: L("error12.ban.strike23.detail",
                          fallback: "Repeated problems can lead to temporary suspensions or a permanent ban. Wander can't prevent or reverse these.")
            ),
        ]
    }

    private var steps: [Step] {
        [
            Step(
                number: 1,
                icon: "location.fill",
                title: L("error12.step.location_on.title",
                         fallback: "Turn Location Services ON"),
                detail: L("error12.step.location_on.detail",
                          fallback: "iPhone Settings → Privacy & Security → Location Services → ON, and set the game → While Using the App. Location Services must be on for the injected location to reach the game.")
            ),
            Step(
                number: 2,
                icon: "arrow.clockwise",
                title: L("error12.step.refresh.title",
                         fallback: "After you teleport, refresh the fix"),
                detail: L("error12.step.refresh.detail",
                          fallback: "Toggle Location Services off, wait about 10 seconds, then back on (Settings → Privacy & Security → Location Services). The WAIT is what does the work — iOS holds a cached copy of your real location, and a quick flick usually isn't long enough to clear it. Then wait until Maps shows a location again before you check. Still snapping back after a couple of honest tries? Then reboot once — on iOS 26 most people don't need to.")
            ),
            Step(
                number: 3,
                icon: "hourglass",
                title: L("error12.step.cooldown.title",
                         fallback: "Wait before interacting again"),
                detail: L("error12.step.cooldown.detail",
                          fallback: "A suggested wait helps space out in-game actions after a location change. It is only a suggestion and can't prevent warnings or bans.")
            ),
            Step(
                number: 4,
                icon: "figure.walk.motion",
                title: L("error12.step.smooth.title",
                         fallback: "Move smoothly; don't rapid-teleport"),
                detail: L("error12.step.smooth.detail",
                          fallback: "If a location error appears while moving, stop, wait a few seconds for the fix to settle, then continue. Avoid a flurry of tiny location changes.")
            ),
            Step(
                number: 5,
                icon: "bolt.horizontal.circle.fill",
                title: L("error12.step.keep_running.title",
                         fallback: "Keep Wander running"),
                detail: L("error12.step.keep_running.detail",
                          fallback: "Keep the app open with the tunnel connected while you play — if the tunnel drops, the game instantly loses the fix.")
            ),
        ]
    }

    /// Community-estimated soft-ban cooldown per teleport distance. NOT official Niantic values.
    private let cooldownRows: [(distance: String, wait: String)] = [
        ("~1 km", "~30 sec"),
        ("~5 km", "~2 min"),
        ("~10 km", "~6 min"),
        ("~25 km", "~11 min"),
        ("~50 km", "~18 min"),
        ("~100 km", "~26 min"),
        ("~250 km", "~35 min"),
        ("~500 km", "~45 min"),
        ("~1000+ km", "up to ~2 hr"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header

                    // The fix checklist, as material cards.
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            stepRow(step)
                            if index < steps.count - 1 {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    cooldownCard

                    taxonomyCard

                    banLadderCard

                    tunnelHelpLink

                    Text(L("error12.footer.discord",
                           fallback: "Still stuck? Tell us in the Discord #bug-reports channel."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .padding()
            }
            .navigationTitle(L("error12.title", fallback: "Location not detected?"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showTunnelHelp) {
                TunnelConnectionHelpView()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Wander.brand)
            Text(L("error12.intro",
                   fallback: "If a game says it can't detect your location, these steps fix the most common causes: a dropped connection, a coarse real location, or Location Services being off."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
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

    // MARK: - Cooldown table card

    private var cooldownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("error12.cooldown.header", fallback: "Suggested wait by distance"),
                  systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(cooldownRows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(row.distance)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(row.wait)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Wander.brand)
                    }
                    .padding(.vertical, 8)
                    if index < cooldownRows.count - 1 {
                        Divider()
                    }
                }
            }

            Text(L("error12.cooldown.disclaimer",
                   fallback: "Community estimates, not official values. They can't prevent warnings or bans."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Error-taxonomy card ("which error is it?")

    private var taxonomyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("error12.taxonomy.header", fallback: "Which error are you seeing?"),
                  systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(spacing: 0) {
                ForEach(Array(errorCases.enumerated()), id: \.element.id) { index, item in
                    infoRow(icon: item.icon, title: item.title, detail: item.detail)
                    if index < errorCases.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Ban-ladder card (plain-language education)

    private var banLadderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("error12.ban.header", fallback: "About warnings and bans"),
                  systemImage: "stairs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(L("error12.ban.intro",
                   fallback: "Games set their own rules and can warn, limit or suspend accounts. Wander can't see inside a game and can't prevent any of this."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(banRungs.enumerated()), id: \.element.id) { index, rung in
                    infoRow(icon: rung.icon, title: rung.title, detail: rung.detail)
                    if index < banRungs.count - 1 {
                        Divider().padding(.leading, 44)
                    }
                }
            }

            Text(L("error12.ban.caveat",
                   fallback: "Odd in-game behavior is not always caused by your account. Games have bugs too."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("error12.ban.notvpn",
                   fallback: "Wander's tunnel is Apple's on-device developer tunnel — it is NOT an IP-VPN and does not change your IP address."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Link to the tunnel-connection help sheet

    private var tunnelHelpLink: some View {
        Button {
            showTunnelHelp = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Wander.brand.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "cable.connector.horizontal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Wander.brand)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("error12.tunnel_link.title", fallback: "Tunnel won't connect or keeps dropping?"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L("error12.tunnel_link.detail", fallback: "Open the tunnel-connection help."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Shared info row (icon + title + detail) for the taxonomy / ban cards

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

#Preview {
    LocationErrorHelpView()
}
