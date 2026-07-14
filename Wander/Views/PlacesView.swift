//
//  PlacesView.swift
//  Wander
//
//  Quick-teleport hub: recent spots, your saved places, and a set of famous
//  quick picks. Tapping any row jumps to the Teleport tab and starts simulating.
//
//  Saved places can be organized (FREE) with a folder, tags, and notes; the
//  Saved section can be filtered and grouped by folder or tag.
//

import SwiftUI
import CoreLocation

/// How the Saved section is filtered/grouped.
private enum PlacesFilter: Equatable {
    case all
    case folder(String)
    case tag(String)
}

struct PlacesView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.location.id
    @StateObject private var store = SavedPlacesStore()

    @State private var filter: PlacesFilter = .all
    @State private var editingPlace: LocationBookmark?

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
                    } header: { Text(localized: "places.recent", fallback: "Recent") }
                }

                savedSections

                Section {
                    ForEach(QuickPlaces.all) { place in
                        placeRow(place.name, place.subtitle, symbol: place.symbol) {
                            teleport(to: place.coordinate, name: place.name)
                        }
                    }
                } header: {
                    Text(localized: "places.quick_picks", fallback: "Quick picks")
                } footer: {
                    Text(localized: "places.quick_picks_hint", fallback: "Tap any place to jump there and start simulating.")
                }
            }
            .navigationTitle(L("places.title", fallback: "Places"))
            .toolbar {
                if !allFolders.isEmpty || !allTags.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { filterMenu }
                }
                if !store.recents.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("action.clear", fallback: "Clear")) { store.clearRecents() }
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
            .sheet(item: $editingPlace) { place in
                PlaceMetadataEditor(place: place) { updated in
                    store.updateSaved(updated)
                    editingPlace = nil
                }
            }
        }
    }

    // MARK: - Saved (organized) sections

    /// Places matching the active filter.
    private var filteredSaved: [LocationBookmark] {
        switch filter {
        case .all:
            return store.saved
        case .folder(let f):
            return store.saved.filter { ($0.folder ?? "") == f }
        case .tag(let t):
            return store.saved.filter { $0.tags.contains(t) }
        }
    }

    @ViewBuilder private var savedSections: some View {
        if store.saved.isEmpty {
            Section {
                Label(L("places.saved_empty", fallback: "Tap the bookmark on the Teleport tab to save a spot here."),
                      systemImage: "bookmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Text(localized: "places.saved", fallback: "Saved") }
        } else if case .all = filter {
            // Group by folder when no specific filter is applied.
            ForEach(groupedByFolder, id: \.title) { group in
                Section {
                    savedRows(group.places)
                } header: { Text(group.title) }
            }
        } else {
            Section {
                savedRows(filteredSaved)
            } header: {
                Text(filterHeader)
            } footer: {
                if filteredSaved.isEmpty { Text(localized: "places.no_match", fallback: "No saved places match this filter.") }
            }
        }
    }

    private func savedRows(_ places: [LocationBookmark]) -> some View {
        ForEach(places) { place in
            savedRow(place)
        }
        .onDelete { offsets in deleteSaved(from: places, at: offsets) }
    }

    private func savedRow(_ place: LocationBookmark) -> some View {
        Button {
            teleport(to: place.coordinate, name: place.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .font(.body)
                    .foregroundStyle(Wander.brand)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.body).foregroundStyle(.primary)
                    Text(coordText(place.coordinate)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if !place.tags.isEmpty {
                        Text(place.tags.map { "#\($0)" }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(Wander.brand.opacity(0.85))
                    }
                    if let notes = place.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: Wander.Icon.simulate)
                    .font(.caption)
                    .foregroundStyle(Wander.brand.opacity(0.7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                editingPlace = place
            } label: {
                Label("Edit", systemImage: "tag")
            }
            .tint(Wander.brand)
        }
    }

    /// Delete honoring the currently displayed subset (offsets are into `places`).
    private func deleteSaved(from places: [LocationBookmark], at offsets: IndexSet) {
        let ids = offsets.map { places[$0].id }
        let storeOffsets = IndexSet(store.saved.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { $0.offset })
        store.deleteSaved(storeOffsets)
    }

    // MARK: - Grouping / filtering helpers

    private struct SavedGroup { let title: String; let places: [LocationBookmark] }

    /// Saved places grouped by folder, with un-foldered places last under "Ungrouped".
    private var groupedByFolder: [SavedGroup] {
        let withFolder = Dictionary(grouping: store.saved.filter { !($0.folder ?? "").isEmpty },
                                    by: { $0.folder ?? "" })
        var groups = withFolder
            .map { SavedGroup(title: $0.key, places: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let ungrouped = store.saved.filter { ($0.folder ?? "").isEmpty }
        if !ungrouped.isEmpty {
            groups.append(SavedGroup(title: groups.isEmpty ? "Saved" : "Ungrouped", places: ungrouped))
        }
        return groups
    }

    private var allFolders: [String] {
        Array(Set(store.saved.compactMap { $0.folder }).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var allTags: [String] {
        Array(Set(store.saved.flatMap { $0.tags }).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filterHeader: String {
        switch filter {
        case .all: return "Saved"
        case .folder(let f): return "Folder: \(f)"
        case .tag(let t): return "Tag: #\(t)"
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                filter = .all
            } label: {
                Label("All", systemImage: filter == .all ? "checkmark" : "")
            }
            if !allFolders.isEmpty {
                Section("Folders") {
                    ForEach(allFolders, id: \.self) { f in
                        Button {
                            filter = .folder(f)
                        } label: {
                            Label(f, systemImage: filter == .folder(f) ? "checkmark" : "folder")
                        }
                    }
                }
            }
            if !allTags.isEmpty {
                Section("Tags") {
                    ForEach(allTags, id: \.self) { t in
                        Button {
                            filter = .tag(t)
                        } label: {
                            Label("#\(t)", systemImage: filter == .tag(t) ? "checkmark" : "tag")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
    }

    // MARK: - Rows / actions

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

// MARK: - Metadata editor

/// Edit a saved place's folder, tags, and notes. Fully free organizing UI.
private struct PlaceMetadataEditor: View {
    let place: LocationBookmark
    let onSave: (LocationBookmark) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folder: String
    @State private var tagsText: String
    @State private var notes: String

    init(place: LocationBookmark, onSave: @escaping (LocationBookmark) -> Void) {
        self.place = place
        self.onSave = onSave
        _folder = State(initialValue: place.folder ?? "")
        _tagsText = State(initialValue: place.tags.joined(separator: ", "))
        _notes = State(initialValue: place.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Place", value: place.name)
                    LabeledContent("Coordinate",
                                   value: String(format: "%.4f, %.4f", place.latitude, place.longitude))
                }

                Section {
                    TextField("Folder", text: $folder)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Folder")
                } footer: {
                    Text("Group this place under a folder (leave blank for ungrouped).")
                }

                Section {
                    TextField("comma, separated, tags", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas.")
                }

                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Organize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        var updated = place
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.folder = trimmedFolder.isEmpty ? nil : trimmedFolder
        updated.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        updated.updatedAt = Date()   // stamp so this edit wins the multi-device sync merge
        onSave(updated)
    }
}

#Preview {
    PlacesView()
}
