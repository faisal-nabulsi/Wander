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

    /// One step in the fix checklist.
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
                icon: "location.fill",
                title: L("error12.step.location_on.title",
                         fallback: "Turn Location Services ON"),
                detail: L("error12.step.location_on.detail",
                          fallback: "iPhone Settings → Privacy & Security → Location Services → ON, and set Pokémon GO → While Using the App. Location Services must be on for the injected location to reach the game.")
            ),
            Step(
                number: 2,
                icon: "arrow.clockwise",
                title: L("error12.step.refresh.title",
                         fallback: "After you teleport, refresh the fix"),
                detail: L("error12.step.refresh.detail",
                          fallback: "Toggle Location Services off for ~3 seconds, then back on (Settings → Privacy & Security → Location Services). This forces iOS to grab a fresh fix at your new spot.")
            ),
            Step(
                number: 3,
                icon: "hourglass",
                title: L("error12.step.cooldown.title",
                         fallback: "Respect the cooldown after INTERACTING"),
                detail: L("error12.step.cooldown.detail",
                          fallback: "The cooldown timer is started by actions — catching a Pokémon, spinning a stop, feeding a berry, battling, dropping in a gym — not by teleporting itself. So you can teleport freely, but wait out the cooldown before your next interaction.")
            ),
            Step(
                number: 4,
                icon: "figure.walk.motion",
                title: L("error12.step.smooth.title",
                         fallback: "Move smoothly; don't rapid-teleport"),
                detail: L("error12.step.smooth.detail",
                          fallback: "If Error 12 pops while moving, stop, wait a few seconds for the fix to settle, then continue. Avoid a flurry of tiny teleports.")
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
            .navigationTitle(L("error12.title", fallback: "Location not detected? (Error 12)"))
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
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Wander.brand)
            Text(L("error12.intro",
                   fallback: "Pokémon GO's 'Failed to detect location (12)' means the game didn't get a clean GPS fix. Wander already smooths your movement so it won't fight the game — these steps fix the rest."))
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
            Label(L("error12.cooldown.header", fallback: "Interaction cooldown by distance"),
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
                   fallback: "Community estimates, not official Niantic values."))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    LocationErrorHelpView()
}
