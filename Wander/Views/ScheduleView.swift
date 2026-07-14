//
//  ScheduleView.swift
//  Wander
//
//  SCHEDULING UI ("be at a place during set hours"). Create / list / delete schedules; each is
//  a location + start time + end time (+ optional repeat weekdays). Armed schedules auto-START
//  spoofing at the start time and auto-STOP (revert to real GPS) at the end time, driven by
//  ScheduleManager while Wander stays alive (foreground or the audio+location keep-alive).
//
//  HONEST LIMIT is stated in the UI: scheduling runs while Wander stays open in the background;
//  if you FORCE-QUIT the app it can't auto-start (a local notification reminds you instead).
//

import SwiftUI
import CoreLocation

struct ScheduleView: View {
    @StateObject private var store = ScheduleStore()
    @ObservedObject private var manager = ScheduleManager.shared

    @State private var showAdd = false
    @State private var nextFire: Date?

    // Refresh the "next fire" line every minute while on screen.
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                schedulesSection
                keepOpenFooter
            }
            .navigationTitle(L("schedule.title", fallback: "Schedule"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: Wander.Icon.add)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddScheduleSheet { schedule in
                    store.add(schedule)
                    recomputeNextFire()
                }
            }
            .onAppear {
                store.reload()
                recomputeNextFire()
            }
            .onReceive(ticker) { _ in recomputeNextFire() }
        }
    }

    // MARK: - Status (active window / next fire)

    @ViewBuilder private var statusSection: some View {
        Section {
            if let id = manager.activeScheduleID,
               let active = store.schedules.first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    Image(systemName: "location.fill.viewfinder")
                        .foregroundStyle(Wander.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: L("schedule.active_now", fallback: "Active now: %@"), active.name))
                            .font(.subheadline.weight(.semibold))
                        Text(active.timeRangeText)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else if let nextFire {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge")
                        .foregroundStyle(Wander.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localized: "schedule.next_fire", fallback: "Next start")
                            .font(.subheadline.weight(.semibold))
                        Text(nextFire.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else {
                Label(L("schedule.none_armed", fallback: "No armed schedules."),
                      systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !hasPairing {
                Text(localized: "schedule.needs_pairing",
                     fallback: "Import a pairing file in Settings so schedules can auto-start spoofing.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Schedules list

    @ViewBuilder private var schedulesSection: some View {
        Section {
            if store.schedules.isEmpty {
                Label(L("schedule.empty", fallback: "Add a schedule with +, then arm it."),
                      systemImage: "calendar.badge.plus")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.schedules) { schedule in
                    scheduleRow(schedule)
                }
                .onDelete {
                    store.delete($0)
                    recomputeNextFire()
                }
            }
        } header: {
            Text(localized: "schedule.list_header", fallback: "Schedules")
        }
    }

    @ViewBuilder private func scheduleRow(_ schedule: Schedule) -> some View {
        let isActive = manager.activeScheduleID == schedule.id
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Wander.brand : Color.secondary.opacity(0.2))
                    .frame(width: 30, height: 30)
                Image(systemName: isActive ? "location.fill" : "mappin")
                    .font(.caption)
                    .foregroundStyle(isActive ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.name).font(.body)
                HStack(spacing: 6) {
                    Label(schedule.timeRangeText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(schedule.weekdaysText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Arm/disarm toggle — the source of truth for whether this participates.
            Toggle("", isOn: Binding(
                get: { schedule.isArmed },
                set: { armed in
                    store.setArmed(armed, id: schedule.id)
                    recomputeNextFire()
                }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var keepOpenFooter: some View {
        Section {
            EmptyView()
        } footer: {
            Text(localized: "schedule.keep_open",
                 fallback: "Scheduling runs while Wander stays open in the background (it keeps a silent audio + location session alive). If you FORCE-QUIT Wander it can't auto-start — a notification will remind you to reopen it.")
        }
    }

    // MARK: - Helpers

    private var hasPairing: Bool {
        let url = PairingFileStore.prepareURL()
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func recomputeNextFire() {
        nextFire = manager.nextFireDate()
    }
}

// MARK: - Add schedule sheet

/// Create a schedule: pick a location (search / coordinates / current), set start + end times,
/// and choose repeat weekdays.
private struct AddScheduleSheet: View {
    let onAdd: (Schedule) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var currentLocation = CurrentLocation()

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var placeName: String = ""
    @State private var startDate: Date = Self.defaultStart
    @State private var endDate: Date = Self.defaultEnd
    @State private var selectedWeekdays: Set<Int> = []

    static var defaultStart: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }
    static var defaultEnd: Date {
        Calendar.current.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                locationSection
                timeSection
                weekdaySection
            }
            .navigationTitle(L("schedule.add_title", fallback: "New schedule"))
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

    @ViewBuilder private var locationSection: some View {
        Section {
            AddressSearchBar(placeholder: L("schedule.search", fallback: "Search a place or coordinates")) { coord, name in
                coordinate = coord
                placeName = name
            }
            Button {
                useCurrentLocation()
            } label: {
                Label(L("schedule.use_current", fallback: "Use current location"),
                      systemImage: "location")
            }
            if let coordinate {
                LabeledContent(L("schedule.picked", fallback: "Location")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(placeName.isEmpty ? L("schedule.location", fallback: "Location") : placeName)
                        Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(localized: "schedule.location", fallback: "Location")
        }
    }

    @ViewBuilder private var timeSection: some View {
        Section {
            DatePicker(L("schedule.start_time", fallback: "Start time"),
                       selection: $startDate, displayedComponents: .hourAndMinute)
            DatePicker(L("schedule.end_time", fallback: "End time"),
                       selection: $endDate, displayedComponents: .hourAndMinute)
        } header: {
            Text(localized: "schedule.hours", fallback: "Hours")
        } footer: {
            if minutes(from: endDate) <= minutes(from: startDate) {
                Text(localized: "schedule.overnight_hint",
                     fallback: "End is at or before start, so this window runs overnight into the next day.")
            }
        }
    }

    @ViewBuilder private var weekdaySection: some View {
        Section {
            let ordered = orderedWeekdays()
            HStack(spacing: 8) {
                ForEach(ordered, id: \.self) { day in
                    let isOn = selectedWeekdays.contains(day.rawValue)
                    Button {
                        toggle(day.rawValue)
                    } label: {
                        Text(day.shortSymbol.prefix(2))
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(isOn ? Wander.brand : Color.secondary.opacity(0.15))
                            .foregroundStyle(isOn ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text(localized: "schedule.repeat", fallback: "Repeat")
        } footer: {
            Text(selectedWeekdays.isEmpty
                 ? L("schedule.repeat_daily", fallback: "No days selected — runs every day.")
                 : L("schedule.repeat_selected", fallback: "Runs only on the selected days."))
        }
    }

    // MARK: - Actions

    private func toggle(_ weekday: Int) {
        if selectedWeekdays.contains(weekday) {
            selectedWeekdays.remove(weekday)
        } else {
            selectedWeekdays.insert(weekday)
        }
    }

    private func useCurrentLocation() {
        currentLocation.request()
        if let c = currentLocation.coordinate {
            coordinate = c
            placeName = L("schedule.current_location", fallback: "Current location")
        }
    }

    private func add() {
        guard let coordinate else { return }
        let name = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let schedule = Schedule(
            name: name.isEmpty ? coordinateText(coordinate) : name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            startMinutes: minutes(from: startDate),
            endMinutes: minutes(from: endDate),
            weekdays: selectedWeekdays.sorted(),
            isArmed: true
        )
        onAdd(schedule)
        dismiss()
    }

    // MARK: - Helpers

    private func minutes(from date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func coordinateText(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.4f, %.4f", c.latitude, c.longitude)
    }

    /// Weekdays ordered by the current locale's first weekday (e.g. Mon-first vs Sun-first).
    private func orderedWeekdays() -> [Weekday] {
        let first = Calendar.current.firstWeekday  // 1...7
        return (0..<7).compactMap { offset in
            Weekday(rawValue: (first - 1 + offset) % 7 + 1)
        }
    }
}
