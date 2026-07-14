//
//  GeofenceListView.swift
//  Wander
//
//  Manage geofence triggers: the list of saved geofences with add/delete/toggle,
//  plus an honest explainer about which authorization is granted (Always fires in
//  the background; When-In-Use only fires while Wander is open).
//

import SwiftUI
import CoreLocation

struct GeofenceListView: View {
    @ObservedObject private var manager = GeofenceManager.shared
    @State private var showEditor = false

    var body: some View {
        List {
            authorizationSection

            if manager.geofences.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localized: "geofence.empty.title", fallback: "No geofences yet")
                            .font(.headline)
                        Text(localized: "geofence.empty.body",
                             fallback: "Add a geofence to auto-stop spoofing and return to real GPS when you actually arrive somewhere — like home.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(manager.geofences) { geofence in
                        GeofenceRow(geofence: geofence)
                    }
                    .onDelete { manager.delete(at: $0) }
                } header: {
                    Text(localized: "geofence.section.your", fallback: "Your geofences")
                } footer: {
                    Text(String(
                        format: L("geofence.cap.footer",
                                  fallback: "iOS monitors up to 20 geofences at once. %d of 20 active."),
                        manager.enabledGeofences.count
                    ))
                }
            }
        }
        .navigationTitle(L("geofence.title", fallback: "Geofences"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(manager.remainingCapacity == 0)
                .accessibilityLabel(L("geofence.add", fallback: "Add geofence"))
            }
        }
        .sheet(isPresented: $showEditor) {
            GeofenceEditorView()
        }
        .onAppear {
            manager.refreshMonitoring()
        }
    }

    @ViewBuilder private var authorizationSection: some View {
        Section {
            switch manager.authorizationStatus {
            case .authorizedAlways:
                Label(L("geofence.auth.always",
                        fallback: "Always allowed — geofences fire even when Wander is closed."),
                      systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .authorizedWhenInUse:
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("geofence.auth.wheninuse",
                            fallback: "While-in-use only — geofences fire only while Wander is open and active."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("geofence.auth.upgrade", fallback: "Allow Always for background triggers")) {
                        manager.requestAlwaysAuthorization()
                    }
                    .font(.caption.weight(.semibold))
                }
            case .denied, .restricted:
                Label(L("geofence.auth.denied",
                        fallback: "Location access is off. Enable it in Settings so geofences can fire."),
                      systemImage: "location.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            default:
                Button(L("geofence.auth.request", fallback: "Allow location access")) {
                    manager.requestAlwaysAuthorization()
                }
                .font(.caption.weight(.semibold))
            }
        } footer: {
            Text(localized: "geofence.auth.footer",
                 fallback: "Geofences use iOS region monitoring. Background triggers require Always authorization; with While-in-use, a geofence only fires when Wander is foreground.")
        }
    }
}

/// One row in the geofences list: name, what it does, and an on/off toggle.
private struct GeofenceRow: View {
    let geofence: Geofence
    @ObservedObject private var manager = GeofenceManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(geofence.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(geofence.name)
                    .font(.body.weight(.medium))
                Text("\(geofence.trigger.title) · \(Int(geofence.radius)) m · \(geofence.action.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { geofence.isEnabled },
                set: { manager.setEnabled($0, for: geofence) }
            ))
            .labelsHidden()
            // Don't let a disabled geofence be re-enabled past the region cap.
            .disabled(!geofence.isEnabled && manager.remainingCapacity == 0)
        }
        .padding(.vertical, 2)
    }
}
