//
//  AddressSearchBar.swift
//  Wander
//
//  Reusable search field: type an address or place, pick a result, get a coordinate.
//  Used by Walk mode (set start) and Route mode (add waypoint).
//

import SwiftUI
import MapKit
import CoreLocation

@MainActor
final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            completer.queryFragment = ""
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results
        Task { @MainActor in self.results = r }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct AddressSearchBar: View {
    var placeholder: String = "Search address or place"
    var onPick: (CLLocationCoordinate2D, String) -> Void

    @StateObject private var completer = AddressSearchCompleter()
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in completer.update(newValue) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        completer.update("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }

            if let coord = parsedCoordinate {
                Button {
                    onPick(coord, "Coordinates")
                    query = ""
                    completer.update("")
                    focused = false
                } label: {
                    HStack {
                        Image(systemName: "scope").foregroundStyle(.secondary)
                        Text(String(format: "Go to  %.5f, %.5f", coord.latitude, coord.longitude))
                            .font(.subheadline)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !completer.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(completer.results.prefix(6), id: \.self) { result in
                        Button { resolve(result) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.subheadline).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// If the query is a plain "lat, lng" pair, return it (so users can type exact coordinates).
    private var parsedCoordinate: CLLocationCoordinate2D? {
        let parts = query.split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        let nums = parts.compactMap { Double($0) }
        guard parts.count == 2, nums.count == 2,
              (-90.0...90.0).contains(nums[0]), (-180.0...180.0).contains(nums[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: nums[0], longitude: nums[1])
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            Task { @MainActor in onPick(coordinate, completion.title) }
        }
        query = ""
        completer.update("")
        focused = false
    }
}
