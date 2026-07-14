//
//  Schedule.swift
//  Wander
//
//  Model + persistence for SCHEDULING ("be at a place during set hours"). A schedule is a
//  location plus a daily start time and end time (+ optional repeat weekdays). When ARMED,
//  the in-app ScheduleManager auto-STARTs spoofing at the location at the start time and
//  auto-STOPs (reverts to real GPS) at the end time.
//
//  Persisted as Codable in UserDefaults so schedules survive a restart. Times are stored as
//  minutes-since-midnight (local) so they're timezone-portable and trivially comparable.
//
//  HONEST LIMIT (see ScheduleManager): this fires only while Wander is alive (foreground or
//  the app's audio+location keep-alive running in the background). If the user FORCE-QUITS
//  Wander, iOS can't auto-start it — a local notification reminds them instead. We never fake
//  full background scheduling.
//

import Foundation
import CoreLocation

/// A single day of the week, Sunday=1 … Saturday=7 to match `Calendar`'s `weekday` component.
enum Weekday: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    var id: Int { rawValue }

    /// Localized very-short symbol (e.g. "Mon"), taken from the current locale's calendar so it
    /// matches the user's language automatically.
    var shortSymbol: String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let idx = rawValue - 1
        return (idx >= 0 && idx < symbols.count) ? symbols[idx] : "\(rawValue)"
    }
}

/// A scheduled "be here during these hours" entry.
///
/// `startMinutes`/`endMinutes` are minutes-since-local-midnight. When `endMinutes <=
/// startMinutes` the window is treated as crossing midnight (e.g. 22:00 → 06:00).
/// `weekdays` empty means "every day".
struct Schedule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var startMinutes: Int
    var endMinutes: Int
    /// Days this schedule runs on. Empty = every day.
    var weekdays: [Int]
    /// Whether this schedule is currently ARMED (participates in auto start/stop).
    var isArmed: Bool

    init(id: UUID = UUID(),
         name: String,
         latitude: Double,
         longitude: Double,
         startMinutes: Int,
         endMinutes: Int,
         weekdays: [Int] = [],
         isArmed: Bool = true) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.weekdays = weekdays
        self.isArmed = isArmed
    }

    // Tolerant decode so schedules written by any build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        startMinutes = try c.decode(Int.self, forKey: .startMinutes)
        endMinutes = try c.decode(Int.self, forKey: .endMinutes)
        weekdays = try c.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        isArmed = try c.decodeIfPresent(Bool.self, forKey: .isArmed) ?? true
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// True when this schedule runs on all seven days (or has no weekday restriction).
    var repeatsDaily: Bool { weekdays.isEmpty || weekdays.count >= 7 }

    var weekdaySet: Set<Int> { Set(weekdays) }

    /// Whether the window wraps past midnight (end at/before start).
    var crossesMidnight: Bool { endMinutes <= startMinutes }

    var coordinateText: String { String(format: "%.4f, %.4f", latitude, longitude) }

    /// "9:00 AM – 5:00 PM" using the current locale.
    var timeRangeText: String {
        Self.formatMinutes(startMinutes) + " – " + Self.formatMinutes(endMinutes)
    }

    /// "Every day", or e.g. "Mon, Tue, Fri".
    var weekdaysText: String {
        if repeatsDaily { return L("schedule.every_day", fallback: "Every day") }
        return weekdays
            .sorted()
            .compactMap { Weekday(rawValue: $0)?.shortSymbol }
            .joined(separator: ", ")
    }

    /// Format minutes-since-midnight into a locale-aware short time string ("9:30 AM").
    static func formatMinutes(_ minutes: Int) -> String {
        var comps = DateComponents()
        comps.hour = (minutes / 60) % 24
        comps.minute = minutes % 60
        let date = Calendar.current.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    /// Whether the given date's weekday is one this schedule runs on.
    func runsOn(weekday: Int) -> Bool {
        repeatsDaily || weekdaySet.contains(weekday)
    }
}

/// Loads/saves the user's schedules (`wander.schedules` in UserDefaults) and keeps them
/// published so the builder UI stays in sync.
@MainActor
final class ScheduleStore: ObservableObject {
    static let storeKey = "wander.schedules"

    @Published var schedules: [Schedule] = []

    init() { reload() }

    func reload() {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let decoded = try? JSONDecoder().decode([Schedule].self, from: data) else {
            schedules = []
            return
        }
        schedules = decoded
    }

    func add(_ schedule: Schedule) {
        schedules.insert(schedule, at: 0)
        persist()
    }

    func delete(_ offsets: IndexSet) {
        schedules.remove(atOffsets: offsets)
        persist()
    }

    func delete(id: UUID) {
        schedules.removeAll { $0.id == id }
        persist()
    }

    func setArmed(_ armed: Bool, id: UUID) {
        guard let idx = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[idx].isArmed = armed
        persist()
    }

    func persist() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
        NotificationCenter.default.post(name: .schedulesDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted whenever the schedule store changes, so the manager can re-arm/re-evaluate.
    static let schedulesDidChange = Notification.Name("wander.schedulesDidChange")
}
