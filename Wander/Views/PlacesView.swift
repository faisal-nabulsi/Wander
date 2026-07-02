//
//  PlacesView.swift
//  Wander
//
//  Quick-teleport hub: recent spots, your saved places, and a set of famous
//  quick picks. Tapping any row jumps to the Teleport tab and starts simulating.
//

import SwiftUI
import CoreLocation

struct PlacesView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.location.id
    @StateObject private var store = SavedPlacesStore()

    var body: some View {
        NavigationStack {
            List {
                if !store.recents.isEmpty {
                    Section {
                        ForEach(store.recents) { place in
                            placeRow(place.name, coordText(place.coordinate), symbol: "clock.arrow.circlepath") {
                                teleport(to: place.coordinate, name: place.name)
                            }
                        }
                    } header: { Text("Recent") }
                }

                Section {
                    if store.saved.isEmpty {
                        Label("Tap the bookmark on the Teleport tab to save a spot here.",
                              systemImage: "bookmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.saved) { place in
                            placeRow(place.name, coordText(place.coordinate), symbol: "bookmark.fill") {
                                teleport(to: place.coordinate, name: place.name)
                            }
                        }
                        .onDelete { store.deleteSaved($0) }
                    }
                } header: { Text("Saved") }

                Section {
                    ForEach(QuickPlaces.all) { place in
                        placeRow(place.name, place.subtitle, symbol: place.symbol) {
                            teleport(to: place.coordinate, name: place.name)
                        }
                    }
                } header: {
                    Text("Quick picks")
                } footer: {
                    Text("Tap any place to jump there and start simulating.")
                }
            }
            .navigationTitle("Places")
            .toolbar {
                if !store.recents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { store.clearRecents() }
                    }
                }
            }
            .onAppear { store.reload() }
            .onChange(of: selection) { _, newValue in
                if newValue == AppFeature.places.id { store.reload() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .placesDidChange)) { _ in
                store.reload()
            }
        }
    }

    private func placeRow(_ name: String, _ subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: Wander.Icon.simulate)
                    .font(.caption)
                    .foregroundStyle(Wander.brand.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func coordText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    private func teleport(to coordinate: CLLocationCoordinate2D, name: String) {
        SavedPlacesStore.recordRecent(coordinate, name: name)
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        selection = AppFeature.location.id   // jump to the Teleport tab
    }
}

#Preview {
    PlacesView()
}
