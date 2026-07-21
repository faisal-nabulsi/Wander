//
//  LocationDiagnosticView.swift
//  Wander
//
//  DIAGNOSTIC (Experimental, read-only). Shows the EXACT CLLocation fields iOS delivers to apps
//  while a spoof is active — the same fields Pokémon GO reads. Purpose: empirically identify what
//  trips "Failed to detect location (12)" on iOS 26.4+. Our injection is lat/lng-only over the dev
//  tunnel, so iOS backfills altitude/verticalAccuracy/speed/course with sentinel defaults
//  (documented as altitude=0.0, verticalAccuracy=-1.0, horizontalAccuracy=5.0, speed=-1, course=-1).
//  This screen shows whether that degenerate signature is actually present on THIS device — the one
//  in-constraint test nobody in the field has run. It changes NOTHING; it only subscribes to
//  CLLocationManager and displays what any app would receive.
//

import SwiftUI
import CoreLocation
import UIKit

@MainActor
final class LocationDiagnostic: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Reading {
        let lat, lng: Double
        let altitude, ellipsoidalAltitude: Double
        let horizontalAccuracy, verticalAccuracy: Double
        let speed, speedAccuracy: Double
        let course, courseAccuracy: Double
        let ageSeconds: Double
        let isSimulatedBySoftware: String
        let isProducedByAccessory: String
    }

    @Published var reading: Reading?
    @Published var updates = 0
    @Published var authStatus: CLAuthorizationStatus = .notDetermined
    @Published var accuracyAuth: CLAccuracyAuthorization = .fullAccuracy

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest   // same as Pokémon GO
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        authStatus = manager.authorizationStatus
        accuracyAuth = manager.accuracyAuthorization
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authStatus = manager.authorizationStatus
            self.accuracyAuth = manager.accuracyAuthorization
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        var simulated = "nil"
        var accessory = "nil"
        if let src = loc.sourceInformation {
            simulated = src.isSimulatedBySoftware ? "true" : "false"
            accessory = src.isProducedByAccessory ? "true" : "false"
        }
        let r = Reading(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            altitude: loc.altitude,
            ellipsoidalAltitude: loc.ellipsoidalAltitude,
            horizontalAccuracy: loc.horizontalAccuracy,
            verticalAccuracy: loc.verticalAccuracy,
            speed: loc.speed,
            speedAccuracy: loc.speedAccuracy,
            course: loc.course,
            courseAccuracy: loc.courseAccuracy,
            ageSeconds: -loc.timestamp.timeIntervalSinceNow,
            isSimulatedBySoftware: simulated,
            isProducedByAccessory: accessory
        )
        Task { @MainActor in
            self.reading = r
            self.updates += 1
        }
    }
}

struct LocationDiagnosticView: View {
    @StateObject private var diag = LocationDiagnostic()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Start a spoof FIRST (teleport, then also try joystick), then read these. This is the exact location iOS hands every app — including Pokémon GO. Read-only; it changes nothing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let r = diag.reading {
                    Section("What Pokémon GO receives") {
                        row("Latitude", String(format: "%.6f", r.lat))
                        row("Longitude", String(format: "%.6f", r.lng))
                        row("Altitude", String(format: "%.2f m", r.altitude), flagged: r.altitude == 0)
                        row("Ellipsoidal alt", String(format: "%.2f m", r.ellipsoidalAltitude))
                        row("Horizontal acc", String(format: "%.1f m", r.horizontalAccuracy), flagged: r.horizontalAccuracy < 0)
                        row("Vertical acc", String(format: "%.1f m", r.verticalAccuracy), flagged: r.verticalAccuracy <= 0)
                        row("Speed", String(format: "%.2f m/s", r.speed), flagged: r.speed < 0)
                        row("Speed acc", String(format: "%.2f", r.speedAccuracy), flagged: r.speedAccuracy < 0)
                        row("Course", String(format: "%.1f°", r.course), flagged: r.course < 0)
                        row("Course acc", String(format: "%.1f", r.courseAccuracy), flagged: r.courseAccuracy < 0)
                        row("Fix age", String(format: "%.1f s", r.ageSeconds))
                        row("isSimulatedBySoftware", r.isSimulatedBySoftware, flagged: r.isSimulatedBySoftware == "true")
                        row("isProducedByAccessory", r.isProducedByAccessory)
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = clipboardDump(r)
                            copied = true
                        } label: {
                            Label(copied ? "Copied — paste it to Faisal" : "Copy all fields", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        }
                    } footer: {
                        Text("Updates: \(diag.updates) · Auth: \(authString) · Accuracy: \(accuracyString)\nA ⚠️ marks a sentinel/degenerate value — a candidate spoof-detection tell. Read it once on a static teleport and once while moving with the joystick, and copy both.")
                    }
                } else {
                    Section {
                        Label("Waiting for a fix… make sure a spoof is active and Location Services is ON for Wander.", systemImage: "location.magnifyingglass")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Location Diagnostic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { diag.start() }
            .onDisappear { diag.stop() }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String, flagged: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(flagged ? Color.orange : Color.primary)
            if flagged {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var authString: String {
        switch diag.authStatus {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not set"
        @unknown default: return "?"
        }
    }

    private var accuracyString: String {
        diag.accuracyAuth == .fullAccuracy ? "Precise" : "Reduced"
    }

    private func clipboardDump(_ r: LocationDiagnostic.Reading) -> String {
        """
        Wander location diagnostic
        lat=\(r.lat) lng=\(r.lng)
        altitude=\(r.altitude)  ellipsoidalAltitude=\(r.ellipsoidalAltitude)
        horizontalAccuracy=\(r.horizontalAccuracy)  verticalAccuracy=\(r.verticalAccuracy)
        speed=\(r.speed)  speedAccuracy=\(r.speedAccuracy)
        course=\(r.course)  courseAccuracy=\(r.courseAccuracy)
        fixAge=\(r.ageSeconds)s
        isSimulatedBySoftware=\(r.isSimulatedBySoftware)  isProducedByAccessory=\(r.isProducedByAccessory)
        auth=\(authString) accuracy=\(accuracyString) updates=\(diag.updates)
        """
    }
}
