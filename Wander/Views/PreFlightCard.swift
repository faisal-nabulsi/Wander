//
//  PreFlightCard.swift
//  Wander
//
//  Pre-flight COHERENCE CHECKS surfaced as a small advisory section. Reads LocationChecker's
//  warnings and renders one row each, with a one-tap "Open Settings" deep-link for the on-device
//  fixes (Location Services / Precise Location). Advisory only — nothing here blocks a spoof.
//
//  Designed to drop into a `List` (it renders `Section`s), so it composes cleanly inside
//  PoGoModeView's form. When there are no warnings it renders a quiet "looks coherent" note so the
//  user gets positive confirmation the pre-flight passed.
//

import SwiftUI
import CoreLocation

struct PreFlightCard: View {
    /// The spoofed target to check against (drives the IP↔GPS comparison). `nil` runs only the
    /// device-authorization/accuracy checks.
    let spoofedTarget: CLLocationCoordinate2D?

    @StateObject private var checker = LocationChecker()

    var body: some View {
        Group {
            if checker.warnings.isEmpty {
                Section {
                    Label(L("preflight.ok", fallback: "Pre-flight looks coherent"),
                          systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                } header: {
                    Text(L("preflight.header", fallback: "Pre-flight checks"))
                }
            } else {
                Section {
                    ForEach(checker.warnings) { warning in
                        warningRow(warning)
                    }
                } header: {
                    Text(L("preflight.header", fallback: "Pre-flight checks"))
                } footer: {
                    Text(L("preflight.footer",
                           fallback: "Advisory only — these never block a teleport. They flag the most common causes of Error 12 and one detection vector."))
                }
            }
        }
        .onAppear { checker.refresh(spoofedTarget: spoofedTarget) }
        .onChange(of: coordinateKey) { _, _ in checker.refresh(spoofedTarget: spoofedTarget) }
    }

    /// Stable key so a changed target re-runs the checks (CLLocationCoordinate2D isn't Equatable).
    private var coordinateKey: String {
        guard let spoofedTarget else { return "none" }
        return String(format: "%.4f,%.4f", spoofedTarget.latitude, spoofedTarget.longitude)
    }

    @ViewBuilder
    private func warningRow(_ warning: LocationWarning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(warning.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: warning.symbol)
                    .foregroundStyle(.orange)
            }

            Text(warning.message)
                .font(.caption)
                .foregroundStyle(.secondary)

            if warning.opensSettings {
                Button {
                    openAppSettings()
                } label: {
                    Label(L("preflight.open_settings", fallback: "Open Settings"),
                          systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(Wander.brand)
            }
        }
        .padding(.vertical, 2)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    List {
        PreFlightCard(spoofedTarget: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.69))
    }
}
