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
import UIKit

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
    /// Reference point used to recover *short* Plus Codes (e.g. "9G8F+6X").
    /// Full Plus Codes and plain coordinates don't need it. Typically the
    /// current map center.
    var mapCenter: CLLocationCoordinate2D? = nil
    var onPick: (CLLocationCoordinate2D, String) -> Void
    /// Fires true while the field is focused OR showing results, so a host can get out of the way
    /// (e.g. hide a floating top card that would otherwise cover the results list).
    var onActiveChange: ((Bool) -> Void)? = nil

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
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focused = false
                        // This keyboard toolbar can also show while a SIBLING field is focused (e.g.
                        // the "Where do you want to go?" bar), whose focus we don't own — so resign
                        // whatever is actually first responder instead of just our own field.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }

            if let target = parsedTarget {
                Button {
                    onPick(target.coordinate, target.name)
                    query = ""
                    completer.update("")
                    focused = false
                } label: {
                    HStack {
                        Image(systemName: target.symbol).foregroundStyle(.secondary)
                        Text(String(format: "Go to  %.5f, %.5f", target.coordinate.latitude, target.coordinate.longitude))
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
        .onChange(of: focused) { _, _ in reportActive() }
        .onChange(of: completer.results.count) { _, _ in reportActive() }
        .onChange(of: query) { _, _ in reportActive() }
    }

    /// Active = the user is searching: focused, or there are results / a parsed target to show.
    private func reportActive() {
        onActiveChange?(focused || !completer.results.isEmpty || parsedTarget != nil)
    }

    private struct ResolvedTarget {
        let coordinate: CLLocationCoordinate2D
        let name: String
        let symbol: String
    }

    /// If the query is a plain "lat, lng" pair or a Plus Code, resolve it to a
    /// coordinate so the user can jump directly. Otherwise nil (fall through to
    /// the normal place search).
    private var parsedTarget: ResolvedTarget? {
        // Plus Codes first — a full code contains a '+' and OLC alphabet only,
        // so it won't collide with "lat,lng".
        if let plus = parsedPlusCode {
            return plus
        }
        if let coord = parsedCoordinate {
            return ResolvedTarget(coordinate: coord, name: "Coordinates", symbol: "scope")
        }
        return nil
    }

    /// If the query is a plain "lat, lng" pair, return it (so users can type exact coordinates).
    private var parsedCoordinate: CLLocationCoordinate2D? {
        let parts = query.split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        let nums = parts.compactMap { Double($0) }
        guard parts.count == 2, nums.count == 2,
              (-90.0...90.0).contains(nums[0]), (-180.0...180.0).contains(nums[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: nums[0], longitude: nums[1])
    }

    /// If the query is a Plus Code (full, or short recovered against the map
    /// center), resolve it to a coordinate.
    private var parsedPlusCode: ResolvedTarget? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("+"), PlusCode.isValid(trimmed.uppercased()) else { return nil }
        guard let coord = PlusCode.coordinate(from: trimmed, reference: mapCenter) else { return nil }
        return ResolvedTarget(coordinate: coord, name: "Plus Code", symbol: "plus.magnifyingglass")
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
