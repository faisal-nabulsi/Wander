//
//  GeofenceEditorView.swift
//  Wander
//
//  Set up a geofence: pick a real location (current real GPS or a map tap), a
//  radius, a trigger (arrival / departure), and an action (v1: stop spoofing).
//

import SwiftUI
import MapKit
import CoreLocation

struct GeofenceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = GeofenceManager.shared
    @StateObject private var currentLocation = CurrentLocation()
    @AppStorage("mapStyleMode") private var mapStyleModeRaw = MapStyleMode.standard.rawValue

    @State private var name: String = ""
    @State private var radius: Double = 150
    @State private var trigger: GeofenceTrigger = .arrival
    @State private var action: GeofenceAction = .stopSpoofing

    // The map recenters to wherever the crosshair sits; the pinned coordinate is
    // read from the visible center at save time (map-tap == pan the crosshair).
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleCenter: CLLocationCoordinate2D?

    private var mapStyleMode: MapStyleMode {
        MapStyleMode(rawValue: mapStyleModeRaw) ?? .standard
    }

    private var selectedCoordinate: CLLocationCoordinate2D? {
        visibleCenter ?? currentLocation.coordinate
    }

    private var canSave: Bool {
        selectedCoordinate != nil &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack {
                        MapReader { _ in
                            Map(position: $position) {
                                if let coordinate = selectedCoordinate {
                                    MapCircle(center: coordinate, radius: radius)
                                        .foregroundStyle(Color.accentColor.opacity(0.18))
                                        .stroke(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .mapStyle(mapStyleMode.mapStyle)
                            .onMapCameraChange(frequency: .continuous) { context in
                                visibleCenter = context.region.center
                            }
                        }
                        MapCrosshair()
                            .allowsHitTesting(false)
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())

                    Button {
                        currentLocation.request()
                        if let c = currentLocation.coordinate {
                            recenter(on: c)
                        }
                    } label: {
                        Label(L("geofence.use_current", fallback: "Use my current real location"),
                              systemImage: "location.fill")
                    }
                } header: {
                    Text(localized: "geofence.pick.header", fallback: "Location")
                } footer: {
                    Text(localized: "geofence.pick.footer",
                         fallback: "Pan the map so the crosshair sits on the real place, or use your current location.")
                }

                Section {
                    TextField(L("geofence.name.placeholder", fallback: "Name (e.g. Home)"), text: $name)
                        .textInputAutocapitalization(.words)

                    VStack(alignment: .leading) {
                        HStack {
                            Text(localized: "geofence.radius", fallback: "Radius")
                            Spacer()
                            Text("\(Int(radius)) m")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $radius,
                               in: GeofenceManager.minRadius...GeofenceManager.maxRadius,
                               step: 10)
                    }
                } header: {
                    Text(localized: "geofence.details.header", fallback: "Details")
                }

                Section {
                    Picker(L("geofence.trigger", fallback: "Trigger"), selection: $trigger) {
                        ForEach(GeofenceTrigger.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }
                    Picker(L("geofence.action", fallback: "Action"), selection: $action) {
                        ForEach(GeofenceAction.allCases) { a in
                            Text(a.title).tag(a)
                        }
                    }
                } header: {
                    Text(localized: "geofence.behavior.header", fallback: "When it fires")
                } footer: {
                    Text(localized: "geofence.behavior.footer",
                         fallback: "Wander reverts to your real GPS (same as the panic button) and notifies you.")
                }
            }
            .navigationTitle(L("geofence.new.title", fallback: "New Geofence"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.cancel", fallback: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.save", fallback: "Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                currentLocation.request()
                // Nudge Always authorization up front so background triggers work.
                manager.requestAlwaysAuthorization()
            }
            .onChange(of: currentLocation.coordinate.map(CoordinateBox.init)) { _, boxed in
                // First real fix: center the map on the user if they haven't panned yet.
                if visibleCenter == nil, let c = boxed?.coordinate {
                    recenter(on: c)
                }
            }
        }
    }

    private func recenter(on coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 800,
            longitudinalMeters: 800
        ))
        visibleCenter = coordinate
    }

    private func save() {
        guard let coordinate = selectedCoordinate else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let geofence = Geofence(
            name: trimmed.isEmpty ? L("geofence.default_name", fallback: "Geofence") : trimmed,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radius: radius,
            trigger: trigger,
            action: action,
            isEnabled: true
        )
        manager.add(geofence)
        dismiss()
    }
}

/// Equatable wrapper so `.onChange` can observe a CLLocationCoordinate2D (which
/// isn't Equatable itself).
private struct CoordinateBox: Equatable {
    let latitude: Double
    let longitude: Double
    init(_ c: CLLocationCoordinate2D) {
        latitude = c.latitude
        longitude = c.longitude
    }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
