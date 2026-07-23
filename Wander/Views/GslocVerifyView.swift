//
//  GslocVerifyView.swift
//  Wander
//
//  "Are you ACTUALLY spoofed?" self-check for gs-loc (PoGo) mode. gs-loc is fiddly — the fix only lands
//  after Location Services is toggled off/on and Shadowrocket is connected, and until now the only way to
//  know it worked was to eyeball Apple Maps. This reads Wander's OWN Core Location fix and compares it to
//  the coordinate Wander is pushing. Because Wander's location goes through the SAME gs-loc pipeline
//  Pokémon GO reads, a match means the spoof is landing end-to-end. A mismatch means it isn't yet — and
//  the auth state lets us tell "Location off for Wander" apart from "spoof not taking, toggle LS."
//
//  Read-only: it never injects or changes location, it only asks iOS where it thinks the phone is.
//

import SwiftUI
import CoreLocation
import UIKit

@MainActor
final class GslocVerifier: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum CheckState: Equatable {
        case idle
        case checking
        case verified(distanceMeters: Double)
        case wrongLocation(distanceMeters: Double)
        case noTarget
        case denied
        case failed
    }

    @Published private(set) var state: CheckState = .idle

    private let manager = CLLocationManager()
    private var timeoutTask: Task<Void, Never>?
    /// Within this many meters of the pushed target we treat the spoof as confirmed. Generous next to
    /// gs-loc's ~25–39 m accuracy, but far tighter than the kilometre-scale gap to the user's REAL spot.
    private let matchThresholdMeters: Double = 500

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest   // same as Pokémon GO
    }

    /// Read the phone's own fix and compare it to what Wander is pushing.
    func check() {
        guard GslocMode.currentTargetSnapshot != nil else { state = .noTarget; return }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            state = .denied
            return
        case .notDetermined:
            // Ask, then let the auth callback fire the actual request once granted.
            state = .checking
            manager.requestWhenInUseAuthorization()
            startTimeout()
            return
        default:
            break
        }
        state = .checking
        manager.requestLocation()
        startTimeout()
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.state == .checking { self.state = .failed }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.state == .checking else { return }
            switch manager.authorizationStatus {
            case .denied, .restricted:
                self.state = .denied
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.timeoutTask?.cancel()
            guard let t = GslocMode.currentTargetSnapshot else { self.state = .noTarget; return }
            let target = CLLocation(latitude: t.lat, longitude: t.lng)
            let d = loc.distance(from: target)
            self.state = d <= self.matchThresholdMeters
                ? .verified(distanceMeters: d)
                : .wrongLocation(distanceMeters: d)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.timeoutTask?.cancel()
            if self.state == .checking { self.state = .failed }
        }
    }
}

/// A List-section card that verifies the gs-loc spoof is actually landing. Drop it into any List; it owns
/// its own verifier. Only meaningful while `GslocMode.enabled`, so gate it at the call site.
struct GslocVerifyCard: View {
    @StateObject private var verifier = GslocVerifier()
    @Environment(\.scenePhase) private var scenePhase
    // Set by the "Warm start" button before it opens Shadowrocket; when we return to the foreground we
    // auto-run the spoof check once, so warm start is genuinely one tap ("connect → back → verified").
    @AppStorage("gslocAutoVerify") private var autoVerifyArmed = false

    var body: some View {
        Section {
            statusRow

            Button {
                verifier.check()
            } label: {
                Label(verifier.state == .checking ? "Checking…" : "Check my spoof",
                      systemImage: "arrow.clockwise")
            }
            .disabled(verifier.state == .checking)

            if needsLocationServicesButton {
                Button {
                    if let u = URL(string: "prefs:root=Privacy&path=LOCATION") { UIApplication.shared.open(u) }
                } label: {
                    Label("Open Location Services", systemImage: "gear")
                }
            }
        } header: {
            Text("Spoof check")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && autoVerifyArmed {
                autoVerifyArmed = false
                verifier.check()
            }
        }
    }

    private var needsLocationServicesButton: Bool {
        switch verifier.state {
        case .wrongLocation, .denied: return true
        default: return false
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch verifier.state {
        case .idle:
            content(icon: "checkmark.shield", tint: .secondary,
                    title: "Verify your spoof",
                    message: "After you teleport and toggle Location Services, tap below to confirm iOS is actually reporting your spoofed spot — the same fix Pokémon GO reads.")
        case .checking:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking your location…").font(.subheadline)
            }
        case .verified(let d):
            content(icon: "checkmark.seal.fill", tint: .green,
                    title: "Spoofed — you're at your target",
                    message: "iOS is reporting your spoofed location (within \(Int(d.rounded())) m). Pokémon GO reads the same fix.")
        case .wrongLocation(let d):
            content(icon: "exclamationmark.triangle.fill", tint: .orange,
                    title: "Not spoofed yet",
                    message: "iOS is still reporting a spot \(distanceLabel(d)) from your target. Toggle Location Services off, wait ~3 s, back on — and make sure Shadowrocket is connected.")
        case .noTarget:
            content(icon: "location.slash", tint: .secondary,
                    title: "No target set",
                    message: "Teleport in Wander first, then verify.")
        case .denied:
            content(icon: "location.slash.fill", tint: .orange,
                    title: "Location is off for Wander",
                    message: "Wander needs Location access to read what iOS reports. Turn it on for Wander, then check again.")
        case .failed:
            content(icon: "questionmark.circle", tint: .secondary,
                    title: "Couldn't get a fix",
                    message: "No location came back. Make sure Location Services is on for Wander and try again.")
        }
    }

    @ViewBuilder
    private func content(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func distanceLabel(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters.rounded())) m"
    }
}
