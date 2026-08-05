//
//  TimelineView.swift
//  Wander
//
//  The reading half of the spoof timeline: where the user pretended to be, day by day.
//
//  The question this screen answers is not "what did I do?" — it's "does this hold together?".
//  A spoofed location is a story told to other software, and the one thing Wander could never do
//  until now was let the person telling it read it back. So the emphasis is on the shape of a day:
//  where the location SAT (dwells, numbered on the map and in the list) and how it MOVED between
//  those places (distance, average and peak speed, and an honest marker wherever a leg was a
//  jump-cut rather than travel).
//
//  Everything here is derived. The screen owns no maths: `SpoofTimelineRollup.segments` is a pure
//  function over the day's fixes, and this file only decides how to draw its output.
//
//  DESIGN: no second visual language. The map is the app's existing `Map` + `MapPolyline` idiom with
//  the shared `MapStyleMode`; the page is a `List` of `Section`s, as CooldownJournalView and the
//  settings screens are; the type comes from the `Font.wander*` scale and the colour from
//  `Wander.brand` / `.good` / `.caution` / `.inactive`. Nothing bespoke.
//
//  PRIVACY: this is the user's own record of coordinates WANDER ITSELF wrote. It never leaves the
//  device, nothing in this feature syncs, and the wipe deletes the files rather than hiding rows —
//  all three of which the screen says out loud rather than expecting to be trusted.
//
//  NAMING: the type is `SpoofTimelineView`, not `TimelineView`, even though the file is
//  TimelineView.swift. SwiftUI already ships a `TimelineView` (the clock-driven container), and
//  WanderStyle's shimmer uses it — a same-module type of that name shadows it app-wide and breaks
//  that file with an error nowhere near the cause. The `Spoof` prefix also matches the model side
//  (`SpoofTimeline`, `SpoofFix`, `SpoofSegment`), so the pairing reads correctly anyway.
//

import SwiftUI
import MapKit
import CoreLocation

struct SpoofTimelineView: View {
    @ObservedObject private var timeline = SpoofTimeline.shared

    @AppStorage("mapStyleMode") private var mapStyleModeRaw = MapStyleMode.standard.rawValue
    @AppStorage("useMph") private var useMph = false

    /// Day key ("YYYY-MM-DD") currently on screen. nil until the index lands.
    @State private var selectedDay: String?
    @State private var fixes: [SpoofFix] = []
    @State private var segments: [SpoofSegment] = []
    @State private var isLoadingDay = false
    @State private var camera: MapCameraPosition = .automatic
    /// Tapping a row focuses that segment: the map flies to it and the row's line thickens.
    @State private var focusedSegmentID: String?

    @State private var confirmWipeAll = false
    @State private var confirmWipeDay = false

    private var mapStyleMode: MapStyleMode { MapStyleMode(rawValue: mapStyleModeRaw) ?? .standard }

    /// The fixes that describe somewhere the user's location CLAIMED to be. `.priming` rows — the
    /// device's REAL position, pushed as an opening fix by the first-fix-is-real guardrail — are
    /// excluded everywhere, because drawn into the path they read as a 2 a.m. road trip that never
    /// happened. They're counted in the footer instead, so the record still admits they exist.
    private var storyFixes: [SpoofFix] { fixes.filter { $0.src.isPartOfStory } }
    private var primingCount: Int { fixes.count - storyFixes.count }

    var body: some View {
        List {
            if timeline.days.isEmpty {
                // Gated on the load, NOT on emptiness alone. `days` starts empty and the index is read
                // on a utility queue, so branching on `isEmpty` by itself flashed "No timeline yet" on
                // every open — including for a user with a month of history, who is told for one frame
                // that the record they came to read does not exist. That is the worst possible lie for
                // this particular screen to tell.
                if timeline.isLoadingIndex {
                    loadingSection
                } else {
                    emptySection
                }
            } else {
                daySection
                mapSection
                summarySection
                segmentSections
                privacySection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L("timeline.title", fallback: "Timeline"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .onAppear {
            timeline.refresh()
            if selectedDay == nil { selectedDay = timeline.days.first?.day }
        }
        .onChange(of: timeline.days) { _, days in
            // Follow the newest day on first load, and don't strand the view on a day that a wipe
            // (or the 30-day retention sweep) has just removed.
            if selectedDay == nil || !days.contains(where: { $0.day == selectedDay }) {
                selectedDay = days.first?.day
            }
        }
        .onChange(of: selectedDay) { _, _ in loadSelectedDay() }
        .task { loadSelectedDay() }
        .confirmationDialog(
            L("timeline.wipe.all.confirm", fallback: "Delete your whole timeline?"),
            isPresented: $confirmWipeAll,
            titleVisibility: .visible
        ) {
            Button(L("timeline.wipe.all", fallback: "Delete everything"), role: .destructive) {
                timeline.wipeEverything {
                    fixes = []
                    segments = []
                    selectedDay = nil
                }
            }
            Button(L("common.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "timeline.wipe.all.note",
                 fallback: "Every day is erased from this device. The files are deleted, not hidden — there is no copy anywhere else, so this cannot be undone.")
        }
        .confirmationDialog(
            L("timeline.wipe.day.confirm", fallback: "Delete this day?"),
            isPresented: $confirmWipeDay,
            titleVisibility: .visible
        ) {
            if let day = selectedDay {
                Button(L("timeline.wipe.day", fallback: "Delete this day"), role: .destructive) {
                    timeline.wipeDay(day) {
                        fixes = []
                        segments = []
                    }
                }
            }
            Button(L("common.cancel", fallback: "Cancel"), role: .cancel) {}
        } message: {
            Text(localized: "timeline.wipe.day.note",
                 fallback: "This day's file is deleted from the device. Other days are left alone.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: Binding(get: { timeline.isRecordingEnabled },
                                     set: { timeline.isRecordingEnabled = $0 })) {
                    Label(L("timeline.recording", fallback: "Keep a timeline"),
                          systemImage: "record.circle")
                }
                if selectedDay != nil && !fixes.isEmpty {
                    Divider()
                    Button(role: .destructive) { confirmWipeDay = true } label: {
                        Label(L("timeline.wipe.day", fallback: "Delete this day"),
                              systemImage: "calendar.badge.minus")
                    }
                }
                if !timeline.days.isEmpty {
                    Button(role: .destructive) { confirmWipeAll = true } label: {
                        Label(L("timeline.wipe.all", fallback: "Delete everything"),
                              systemImage: Wander.Icon.clear)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text(localized: "timeline.menu.a11y", fallback: "Timeline options"))
        }
    }

    // MARK: - Loading / empty

    /// Shown only while the index is being read off disk. Deliberately says nothing about whether
    /// there IS history — that is the question still being answered.
    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().tint(Wander.brand)
                Text(localized: "timeline.loading", fallback: "Reading your timeline…")
                    .wanderDetail()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
        }
    }

    private var emptySection: some View {
        Section {
            WanderEmptyState(
                title: L("timeline.empty.title", fallback: "No timeline yet"),
                icon: "clock.arrow.circlepath",
                message: timeline.isRecordingEnabled
                    ? L("timeline.empty.message",
                        fallback: "Once you spoof a location, Wander keeps a private record of it here — where you appeared to be, how long you stayed, and how you got between places. Nothing leaves this device.")
                    : L("timeline.empty.off",
                        fallback: "Keeping a timeline is switched off, so nothing is being recorded. Turn it back on from the menu above.")
            )
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Day scrubber

    private var daySection: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Oldest on the left, newest on the right: the direction time runs, and the
                        // end the scrubber parks at.
                        ForEach(timeline.days.reversed()) { day in
                            dayChip(day)
                                .id(day.day)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    if let day = selectedDay { proxy.scrollTo(day, anchor: .trailing) }
                }
                .onChange(of: selectedDay) { _, day in
                    guard let day else { return }
                    withAnimation(WanderMotion.quick) { proxy.scrollTo(day, anchor: .center) }
                }
            }
            // One haptic per day change, on the container that OWNS `selectedDay`. Per-chip
            // `.wanderFeedback(on: isSelected)` fired twice for every switch — the outgoing chip going
            // true→false and the incoming one false→true — which is a double buzz for a single tap.
            // WanderMotion's own note says only the call site owning the state should reach for this.
            .wanderFeedback(.selection, on: selectedDay)
            .listRowInsets(EdgeInsets())
        } header: {
            Text(localized: "timeline.days", fallback: "Day")
        }
    }

    private func dayChip(_ day: SpoofTimelineDay) -> some View {
        let isSelected = day.day == selectedDay
        return Button {
            selectedDay = day.day
        } label: {
            VStack(spacing: 2) {
                Text(dayTitle(day))
                    .font(.wanderNumeric(.subheadline, weight: isSelected ? .bold : .semibold))
                Text("\(day.storyFixCount)")
                    .font(.wanderMicro)
                    .opacity(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Wander.brand : Wander.hairline, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(dayAccessibilityTitle(day)))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func dayTitle(_ day: SpoofTimelineDay) -> String {
        guard let date = day.date else { return day.day }
        if Calendar.current.isDateInToday(date) { return L("timeline.today", fallback: "Today") }
        if Calendar.current.isDateInYesterday(date) { return L("timeline.yesterday", fallback: "Yesterday") }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func dayAccessibilityTitle(_ day: SpoofTimelineDay) -> String {
        let count = String(format: L("timeline.day.count", fallback: "%d recorded points"),
                           day.storyFixCount)
        return "\(dayTitle(day)), \(count)"
    }

    // MARK: - Map

    private var mapSection: some View {
        Section {
            ZStack {
                Map(position: $camera) {
                    pathContent
                    dwellPins
                }
                .mapStyle(mapStyleMode.mapStyle)
                .disabled(isLoadingDay)

                if isLoadingDay {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay { ProgressView().tint(Wander.brand) }
                } else if storyFixes.isEmpty {
                    Rectangle()
                        .fill(.thinMaterial)
                        .overlay {
                            Text(localized: "timeline.day.empty",
                                 fallback: "Nothing recorded on this day.")
                                .wanderDetail()
                        }
                }
            }
            .frame(height: 260)
            .listRowInsets(EdgeInsets())
            .accessibilityLabel(Text(localized: "timeline.map.a11y",
                                     fallback: "Map of this day's spoofed path"))
        }
    }

    /// The path, drawn casing-then-fill exactly as the route map does it, so it reads on satellite
    /// imagery as well as on the standard style.
    @MapContentBuilder private var pathContent: some MapContent {
        ForEach(segments.filter { $0.kind == .move && $0.coordinates.count > 1 }) { segment in
            MapPolyline(coordinates: segment.coordinates)
                .stroke(Color.black.opacity(0.28), style: Self.lineStyle(7))
        }
        ForEach(segments.filter { $0.kind == .move && $0.coordinates.count > 1 }) { segment in
            MapPolyline(coordinates: segment.coordinates)
                .stroke(segment.id == focusedSegmentID ? Wander.caution : Wander.brand,
                        style: Self.lineStyle(segment.id == focusedSegmentID ? 6 : 4))
        }
    }

    @MapContentBuilder private var dwellPins: some MapContent {
        ForEach(segments.filter { $0.kind == .dwell }) { segment in
            Annotation("", coordinate: segment.centroid, anchor: .center) {
                DwellPin(number: segment.dwellNumber ?? 0,
                         isFocused: segment.id == focusedSegmentID)
            }
            .annotationTitles(.hidden)
        }
    }

    private static func lineStyle(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            HStack(alignment: .top, spacing: 0) {
                metric(value: "\(dwellCount)",
                       label: L("timeline.summary.stops", fallback: "Stops"))
                Divider().frame(height: 34)
                metric(value: SpoofTimelineFormat.distance(totalDistance, useMiles: useMph),
                       label: L("timeline.summary.distance", fallback: "Distance"))
                Divider().frame(height: 34)
                metric(value: SpoofTimelineFormat.duration(coveredDuration),
                       label: L("timeline.summary.span", fallback: "Covered"))
            }
            .padding(.vertical, 4)
        } header: {
            Text(localized: "timeline.summary", fallback: "This day")
        } footer: {
            if primingCount > 0 {
                Text(String(format: L("timeline.summary.priming",
                                      fallback: "%d real-GPS priming push(es) recorded and left out of the path — they're how a session opens, not somewhere you went."),
                            primingCount))
            }
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.wanderNumeric(.title3))
            Text(label).wanderMicro()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value)"))
    }

    private var dwellCount: Int { segments.reduce(0) { $0 + ($1.kind == .dwell ? 1 : 0) } }
    private var totalDistance: Double { segments.reduce(0) { $0 + $1.distanceMeters } }
    /// Time the timeline can actually account for — the sum of the segments — rather than
    /// first-to-last, which would silently count hours the app wasn't running as "covered".
    private var coveredDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    // MARK: - Segments

    @ViewBuilder private var segmentSections: some View {
        if segments.isEmpty && !isLoadingDay && !storyFixes.isEmpty {
            Section {
                Text(localized: "timeline.segments.none",
                     fallback: "Too few points on this day to tell a story yet.")
                    .wanderDetail()
            }
        }
        ForEach(DayPart.allCases) { part in
            let inPart = segments.filter { DayPart(for: $0.start) == part }
            if !inPart.isEmpty {
                Section {
                    ForEach(inPart) { segment in
                        SegmentRow(segment: segment,
                                   useMph: useMph,
                                   label: segment.kind == .dwell
                                        ? timeline.label(for: segment.centroid) : nil,
                                   isFocused: segment.id == focusedSegmentID)
                            .contentShape(Rectangle())
                            .onTapGesture { focus(segment) }
                    }
                } header: {
                    Text(part.title)
                }
            }
        }
    }

    private func focus(_ segment: SpoofSegment) {
        focusedSegmentID = focusedSegmentID == segment.id ? nil : segment.id
        guard focusedSegmentID != nil else {
            withAnimation(WanderMotion.layout) { camera = cameraForWholeDay() }
            return
        }
        withAnimation(WanderMotion.layout) {
            camera = .region(region(for: segment.coordinates,
                                    minimumSpan: segment.kind == .dwell ? 0.004 : 0.01))
        }
    }

    // MARK: - Loading

    private func loadSelectedDay() {
        guard let day = selectedDay else {
            fixes = []
            segments = []
            return
        }
        isLoadingDay = true
        focusedSegmentID = nil
        timeline.fixes(for: day) { loaded in
            // A slow read for a day the user has already scrubbed past must not overwrite the one
            // they're looking at now.
            guard selectedDay == day else { return }
            fixes = loaded
            segments = SpoofTimelineRollup.segments(from: loaded)
            isLoadingDay = false
            camera = cameraForWholeDay()
            // Lazily geocode only the dwells that exist, only once per ~110 m cell, and only for the
            // day on screen — the geocoder is a shared, rate-limited budget.
            for segment in segments where segment.kind == .dwell {
                timeline.requestLabel(for: segment.centroid)
            }
        }
    }

    private func cameraForWholeDay() -> MapCameraPosition {
        let coords = storyFixes.map(\.coordinate)
        guard !coords.isEmpty else { return .automatic }
        return .region(region(for: coords, minimumSpan: 0.006))
    }

    /// A region containing every point, padded so the path isn't flush against the frame. Written
    /// out rather than using `MKMapRect` union because a day can legitimately contain one point, for
    /// which a zero-size rect is not a usable camera.
    private func region(for coords: [CLLocationCoordinate2D],
                        minimumSpan: Double) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLng + maxLng) / 2)
        // Capped at just under a hemisphere: a day with a teleport across the world would otherwise
        // ask MapKit for a span it silently refuses.
        let span = MKCoordinateSpan(
            latitudeDelta: min(max((maxLat - minLat) * 1.4, minimumSpan), 140),
            longitudeDelta: min(max((maxLng - minLng) * 1.4, minimumSpan), 140)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            Label {
                Text(localized: "timeline.privacy",
                     fallback: "This is your own record of the coordinates Wander wrote, kept in this app's storage on this device. It is never uploaded, never synced, and never shared. Deleting it deletes the files.")
                    .font(.wanderDetail)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "iphone.and.arrow.forward.inward")
                    .foregroundStyle(Wander.good)
            }
            Button(role: .destructive) { confirmWipeAll = true } label: {
                Label(L("timeline.wipe.all", fallback: "Delete everything"),
                      systemImage: Wander.Icon.clear)
            }
        } header: {
            Text(localized: "timeline.privacy.header", fallback: "Stored on this device")
        } footer: {
            Text(String(format: L("timeline.retention",
                                  fallback: "Kept for up to %d days, and at most %d points per day — oldest first out."),
                        SpoofTimelineRecorder.retentionDays,
                        SpoofTimelineRecorder.maxFixesPerDay))
        }
    }
}

// MARK: - Day parts

/// Sectioning for the list. Clock time is what a person checking their own story reasons in
/// ("was I still out at 11?"), so the sections are named parts of the day rather than segment types.
private enum DayPart: String, CaseIterable, Identifiable {
    case night, morning, afternoon, evening

    var id: String { rawValue }

    init(for date: Date) {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12:  self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default:      self = .night
        }
    }

    var title: String {
        switch self {
        case .night:     return L("timeline.part.night", fallback: "Night")
        case .morning:   return L("timeline.part.morning", fallback: "Morning")
        case .afternoon: return L("timeline.part.afternoon", fallback: "Afternoon")
        case .evening:   return L("timeline.part.evening", fallback: "Evening")
        }
    }

    /// Chronological within a 24-hour day, so the sections read top to bottom in time order.
    static var allCases: [DayPart] { [.night, .morning, .afternoon, .evening] }
}

// MARK: - Pins and rows

/// A numbered dwell marker. The number is the whole point: it ties a pin on the map to a row in the
/// list without either of them having to repeat the other's text.
private struct DwellPin: View {
    let number: Int
    let isFocused: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isFocused ? Wander.caution : Wander.brand)
                .frame(width: isFocused ? 32 : 26, height: isFocused ? 32 : 26)
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: isFocused ? 32 : 26, height: isFocused ? 32 : 26)
            Text("\(number)")
                .font(.wanderNumeric(.caption, weight: .bold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .wanderAnimation(WanderMotion.quick, on: isFocused)
        .accessibilityLabel(Text(String(format: L("timeline.pin.a11y", fallback: "Stop %d"), number)))
    }
}

/// One segment, read as a sentence rather than a table: what happened, when, and the one or two
/// numbers that make it checkable.
private struct SegmentRow: View {
    let segment: SpoofSegment
    let useMph: Bool
    /// Cached reverse-geocoded place words for a dwell, or nil while it's still coordinates.
    let label: String?
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            marker
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.wanderLabel)
                    .lineLimit(2)
                Text("\(segment.timeRangeText) · \(segment.durationText)")
                    .wanderMicro()
                if segment.kind == .move {
                    Text(moveDetail)
                        .wanderMicro()
                        .monospacedDigit()
                }
                if segment.containsJump {
                    // Said plainly rather than hidden, because an average speed that spans a
                    // teleport is not a speed anyone travelled at, and a reader checking their own
                    // story deserves to know which number is which.
                    Label(L("timeline.jump", fallback: "Includes a jump — not continuous travel"),
                          systemImage: "arrow.turn.up.right")
                        .font(.wanderMicro)
                        .foregroundStyle(Wander.caution)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        if segment.kind == .dwell {
            DwellPin(number: segment.dwellNumber ?? 0, isFocused: isFocused)
                .frame(width: 32)
        } else {
            Image(systemName: segment.sources.first?.symbol ?? "arrow.right")
                .font(.body)
                .foregroundStyle(isFocused ? Wander.caution : Wander.inactive)
                .frame(width: 32)
        }
    }

    private var title: String {
        switch segment.kind {
        case .dwell:
            return label ?? PlaceLabelService.coordinateText(segment.centroid)
        case .move:
            let names = segment.sources.map(\.title).joined(separator: " + ")
            return names.isEmpty ? L("timeline.move", fallback: "Moved") : names
        }
    }

    private var moveDetail: String {
        let distance = SpoofTimelineFormat.distance(segment.distanceMeters, useMiles: useMph)
        let average = SpoofTimelineFormat.speed(segment.averageSpeedMps, useMph: useMph)
        let peak = SpoofTimelineFormat.speed(segment.peakSpeedMps, useMph: useMph)
        return String(format: L("timeline.move.detail", fallback: "%@ · avg %@ · peak %@"),
                      distance, average, peak)
    }
}
