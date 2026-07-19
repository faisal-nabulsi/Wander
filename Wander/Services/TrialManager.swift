//
//  TrialManager.swift
//  Wander
//
//  Free trial with UTC-based resets: 1 teleport PER DAY (refills at UTC midnight), 15 minutes of
//  joystick PER MONTH, and 3 routes PER MONTH (both refill on the 1st, UTC). Counters live in the
//  Keychain (via WanderKeychain) so deleting + reinstalling Wander does NOT reset the trial —
//  iOS preserves Keychain items across app deletion. Alongside the counters we store a UTC day key
//  (yyyy-MM-dd) for teleports and a UTC month key (yyyy-MM) for joystick/routes; on every read we
//  lazily reset a bucket whose stored key has gone stale, so canUse()/remaining()/isExhausted()
//  always reflect the current UTC day/month. Each mode charges its own bucket at the point it
//  starts simulating; when a bucket is empty and there's no license, that mode is blocked behind
//  the paywall. A valid License lifts all limits.
//

import Foundation

enum SimMode {
    case teleport, joystick, route
}

@MainActor
final class TrialManager: ObservableObject {
    static let shared = TrialManager()

    static let maxTeleports = 1              // per UTC day
    static let maxJoystickSeconds = 15 * 60  // 15 minutes per UTC month
    static let maxRoutes = 3                 // per UTC month

    @Published private(set) var teleportsUsed: Int
    @Published private(set) var joystickSecondsUsed: Int
    @Published private(set) var routesUsed: Int

    // The UTC period each bucket's counter belongs to. When these go stale (a new UTC day for
    // teleports, a new UTC month for joystick/routes) the matching counter resets to 0.
    private var teleportDayKey: String
    private var monthKey: String

    private enum Key {
        static let teleports = "wander.trial.teleports"
        static let joystick = "wander.trial.joystickSeconds"
        static let routes = "wander.trial.routes"
        static let teleportDay = "wander.trial.teleportDay"   // yyyy-MM-dd (UTC)
        static let month = "wander.trial.month"               // yyyy-MM (UTC)
    }

    // Formatters fixed to UTC so day/month boundaries follow UTC midnight regardless of timezone.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM"
        return f
    }()

    private static func currentDayKey(_ now: Date = Date()) -> String { dayFormatter.string(from: now) }
    private static func currentMonthKey(_ now: Date = Date()) -> String { monthFormatter.string(from: now) }

    private init() {
        teleportsUsed = WanderKeychain.int(Key.teleports)
        joystickSecondsUsed = WanderKeychain.int(Key.joystick)
        routesUsed = WanderKeychain.int(Key.routes)
        teleportDayKey = WanderKeychain.string(Key.teleportDay) ?? ""
        monthKey = WanderKeychain.string(Key.month) ?? ""
        normalize()
    }

    /// Lazily roll each bucket over to the current UTC period. Teleports reset every UTC day;
    /// joystick + routes reset every UTC month. Called on init and before every read so all
    /// getters reflect the current day/month. Only writes to the Keychain when something changed.
    private func normalize() {
        // Reset ONLY when the period advances FORWARD. yyyy-MM-dd / yyyy-MM are lexically sortable, so
        // string `>` is chronological; using `>` (not `!=`) treats the stored key as a high-water mark
        // and blocks the "set the clock back to farm free resets" abuse — a rewound clock yields
        // today <= the stored key, so no reset. (A forward jump still resets but is self-penalizing:
        // the key advances to the future, so no further resets happen until real time catches up.)
        let today = Self.currentDayKey()
        if today > teleportDayKey {
            teleportDayKey = today
            teleportsUsed = 0
            WanderKeychain.set(Key.teleportDay, today)
            WanderKeychain.setInt(Key.teleports, 0)
        }

        let thisMonth = Self.currentMonthKey()
        if thisMonth > monthKey {
            monthKey = thisMonth
            joystickSecondsUsed = 0
            routesUsed = 0
            WanderKeychain.set(Key.month, thisMonth)
            WanderKeychain.setInt(Key.joystick, 0)
            WanderKeychain.setInt(Key.routes, 0)
        }
    }

    /// Force a staleness check + reset. Views can call this (e.g. on appear) so a day/month that
    /// rolled over while the app was idle is reflected immediately.
    func refresh() { normalize() }

    var teleportsRemaining: Int {
        normalize()
        return max(Self.maxTeleports - teleportsUsed, 0)
    }
    var joystickSecondsRemaining: Int {
        normalize()
        return max(Self.maxJoystickSeconds - joystickSecondsUsed, 0)
    }
    var routesRemaining: Int {
        normalize()
        return max(Self.maxRoutes - routesUsed, 0)
    }

    func remaining(_ mode: SimMode) -> Int {
        switch mode {
        case .teleport: return teleportsRemaining
        case .joystick: return joystickSecondsRemaining
        case .route: return routesRemaining
        }
    }

    /// Whether this mode may still run on the free trial (ignores license — callers OR this
    /// with License.isLicensed).
    func canUse(_ mode: SimMode) -> Bool { remaining(mode) > 0 }

    /// True only when today's daily teleport AND this month's joystick + routes are all used up.
    var isExhausted: Bool {
        normalize()
        return teleportsRemaining == 0 && joystickSecondsRemaining == 0 && routesRemaining == 0
    }

    func chargeTeleport() {
        normalize()
        teleportsUsed += 1
        WanderKeychain.setInt(Key.teleports, teleportsUsed)
    }

    func chargeRoute() {
        normalize()
        routesUsed += 1
        WanderKeychain.setInt(Key.routes, routesUsed)
    }

    func addJoystickSeconds(_ seconds: Int) {
        guard seconds > 0 else { return }
        normalize()
        joystickSecondsUsed += seconds
        WanderKeychain.setInt(Key.joystick, joystickSecondsUsed)
    }
}
