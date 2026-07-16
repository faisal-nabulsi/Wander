//
//  ItineraryQueueView.swift
//  Wander
//
//  Timed Itinerary Queue (Pro). Build an ordered list of steps — each goes to a location
//  (Teleport or Route) and stays for N minutes — then tap Start to run them in order while
//  Wander is open. Shows the active step + a countdown and a Stop button; when the last
//  step's stay elapses it stops on its own.
//
//  Pro-gated (License.shared.isLicensed): free/trial users see the paywall. The built
//  itinerary is persisted (ItineraryStore → UserDefaults) so it survives a restart.
//

import SwiftUI
import CoreLocation

struct ItineraryQueueView: View {
    @StateObject private var store = ItineraryStore()
    @StateObject private var runner = ItineraryRunner()
    @ObservedObject private var license = License.shared

    @State private var showAddStep = false
    @State private var showPaywall = false
    @State private var editMode: EditMode = .inactive

    var body: some View {
        NavigationStack {
            List {
                runnerSection
                stepsSection
                keepOpenFooter
            }
            .navigationTitle(L("itinerary.title", fallback: "Itinerary"))
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addStepTapped()
                    } label: {
                        Image(systemName: Wander.Icon.add)
                    }
                    .accessibilityLabel(L("itinerary.add_step", fallback: "Add step"))
                    .disabled(runner.isRunning)
                }
                if !store.steps.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton().disabled(runner.isRunning)
                    }
                }
            }
            .sheet(isPresented: $showAddStep) {
                AddItineraryStepSheet { step in
                    store.add(step)
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(onClose: { showPaywall = false })
            }
            .onAppear { store.reload() }
        }
    }

    // MARK: - Runner section (Start / active step + countdown / Stop)

    @ViewBuilder private var runnerSection: some View {
        Section {
            if runner.isRunning {
                runningStatus
                Button(role: .destructive) {
                    runner.stop()
                } label: {
                    Label(L("itinerary.stop", fallback: "Stop"), systemImage: Wander.Icon.stop)
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    startTapped()
                } label: {
                    Label(L("itinerary.start", fallback: "Start itinerary"), systemImage: Wander.Icon.play)
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.steps.isEmpty)
            }
        } footer: {
            if !runner.canRun {
                Text(localized: "itinerary.needs_pairing",
                     fallback: "Import a pairing file in Settings to run an itinerary.")
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var runningStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let index = runner.activeIndex, index < store.steps.count {
                let step = store.steps[index]
                HStack(spacing: 8) {
                    Image(systemName: step.move.systemImage)
                        .foregroundStyle(Wander.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L("itinerary.running_step", fallback: "Step %d of %d"),
                                    index + 1, store.steps.count))
                            .font(.subheadline.weight(.semibold))
                        Text(step.name).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                switch runner.phase {
                case .moving:
                    Label(L("itinerary.phase.moving", fallback: "Going there…"), systemImage: Wander.Icon.simulate)
                        .font(.caption).foregroundStyle(.secondary)
                case .staying:
                    Label(String(format: L("itinerary.phase.staying", fallback: "Staying — %@ left"),
                                 timeString(runner.stayRemaining)),
                          systemImage: "timer")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Steps list

    @ViewBuilder private var stepsSection: some View {
        Section {
            if store.steps.isEmpty {
                Label(L("itinerary.empty", fallback: "Add steps with +, then tap Start."),
                      systemImage: "list.number")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.steps.enumerated()), id: \.element.id) { index, step in
                    stepRow(index: index, step: step)
                }
                .onDelete { store.delete($0) }
                .onMove { store.move(from: $0, to: $1) }
            }
        } header: {
            Text(localized: "itinerary.steps", fallback: "Steps")
        }
    }

    @ViewBuilder private func stepRow(index: Int, step: ItineraryStep) -> some View {
        let isActive = runner.isRunning && runner.activeIndex == index
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Wander.brand : Color.secondary.opacity(0.2))
                    .frame(width: 26, height: 26)
                Text("\(index + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isActive ? .white : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name).font(.body)
                HStack(spacing: 6) {
                    Label(step.move.title, systemImage: step.move.systemImage)
                    Text("•")
                    Label(String(format: L("itinerary.stay_mins", fallback: "%d min stay"), step.stayMinutes),
                          systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(step.coordinateText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var keepOpenFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Text(localized: "itinerary.keep_open",
                 fallback: "Runs live while Wander is open — keep the app foregrounded. iOS can't advance steps when Wander is fully closed.")
        }
    }

    // MARK: - Actions

    private func addStepTapped() {
        guard gateOrPaywall() else { return }
        showAddStep = true
    }

    private func startTapped() {
        guard gateOrPaywall() else { return }
        runner.start(steps: store.steps)
    }

    /// Returns true if Pro; otherwise shows the paywall and returns false.
    private func gateOrPaywall() -> Bool {
        if license.isLicensed { return true }
        showPaywall = true
        return false
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Add step sheet

/// Pick a location (search / coordinates / Plus Code), choose Teleport or Route, and a stay
/// duration in minutes.
private struct AddItineraryStepSheet: View {
    let onAdd: (ItineraryStep) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String = ""
    @State private var move: ItineraryMove = .teleport
    @State private var stayMinutes: Int = 5

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AddressSearchBar(placeholder: L("itinerary.search", fallback: "Search a place or coordinates")) { coord, name in
                        coordinate = coord
                        placeName = name
                    }
                    if let coordinate {
                        LabeledContent(L("itinerary.picked", fallback: "Location")) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(placeName.isEmpty ? "Location" : placeName)
                                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(localized: "itinerary.location", fallback: "Location")
                }

                Section {
                    Picker(L("itinerary.how", fallback: "How to get there"), selection: $move) {
                        ForEach(ItineraryMove.allCases) { m in
                            Label(m.title, systemImage: m.systemImage).tag(m)
                        }
                    }
                    Stepper(value: $stayMinutes, in: 0...600) {
                        Text(String(format: L("itinerary.stay_mins", fallback: "%d min stay"), stayMinutes))
                    }
                } footer: {
                    if move == .route {
                        Text(localized: "itinerary.route_hint",
                             fallback: "Route drives a realistic road path from your current spot to this location before staying.")
                    }
                }
            }
            .navigationTitle(L("itinerary.add_step", fallback: "Add step"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.cancel", fallback: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.add", fallback: "Add")) { add() }
                        .disabled(coordinate == nil)
                }
            }
        }
    }

    private func add() {
        guard let coordinate else { return }
        let name = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let step = ItineraryStep(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude) : name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            move: move,
            stayMinutes: stayMinutes
        )
        onAdd(step)
        dismiss()
    }
}
