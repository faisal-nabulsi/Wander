//
//  WanderHotspots.swift
//  Wander
//
//  The LIVE curated-spot directory for the Games tab. The tab used to render a frozen list of ~18
//  spots baked into Resources/pogo.json, which is exactly the staleness problem this fixes: when a
//  park gets nerfed, the app kept recommending it until the next release shipped. The Worker now
//  serves the same list so it can be corrected server-side, with freshness metadata attached.
//
//  Endpoint (GET, public — no auth / idToken, same as the LeekDuck routes):
//    GET <base>/pogo/hotspots
//      → { ok, version, updatedAt, source, count, hotspots: [ { id, name, region, country,
//          lat, lng, kind, density, stops, gyms, status, lastVerified, ageDays, notes } ] }
//      status ∈ good | nerfed | unknown · lastVerified is an ISO date or null · ageDays int or null
//
//  Same offline contract as WanderPoGoEvents: the last SUCCESSFUL payload is cached (UserDefaults,
//  the idiom every offline-tolerant store here uses) and replayed when a later fetch fails. If we
//  have never fetched successfully, the caller keeps showing the bundled pogo.json list — a user
//  with no signal must still get spots, never an empty screen.
//
//  Refresh is throttled to a few hours: this is a hand-curated directory that moves on the order of
//  weeks, so refetching on every tab visit would only cost battery and Worker requests.
//

import Foundation

// MARK: - Freshness

/// How much we currently trust a spot. Drives the badge in the list — `nerfed` is the whole point
/// of the feature, so it must be visible rather than silently dropped (the coordinates are still
/// valid, they're just not worth the trip).
enum HotspotStatus: String {
    case good
    case nerfed
    case unknown

    /// Tolerant of a renamed/unknown value from the feed — anything we don't recognise is `unknown`,
    /// which renders as no badge at all rather than a scary one.
    init(feedValue: String?) {
        switch feedValue?.lowercased() {
        case "good":   self = .good
        case "nerfed": self = .nerfed
        default:       self = .unknown
        }
    }
}

/// One fetch of the directory plus where it came from, so the UI can say "live" vs "offline copy".
struct HotspotDirectory {
    let hotspots: [PoGoHotspot]
    /// When the directory itself was last edited server-side (the feed's `updatedAt`), if parseable.
    let updatedAt: Date?
    /// When THIS device last pulled a good payload — the age we throttle refreshes against.
    let fetchedAt: Date
    /// True when this came off disk instead of the network (offline, or simply not due a refresh).
    let fromCache: Bool
}

// MARK: - Service

enum WanderHotspots {
    /// Same Worker base as the AI + LeekDuck endpoints; this route is public (no idToken).
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// Slow-changing data — a spot doesn't get nerfed twice in an afternoon. Refetching more often
    /// than this buys nothing and costs battery, so the tab can be opened all day for one request.
    private static let refreshInterval: TimeInterval = 6 * 60 * 60

    /// The directory we can show RIGHT NOW without touching the network, so the tab never waits on
    /// a request to paint. `nil` means we've never fetched successfully → caller keeps the bundled
    /// list.
    static func cachedDirectory() -> HotspotDirectory? {
        guard let cached = HotspotCache.load() else { return nil }
        guard let parsed = parse(cached.data, fetchedAt: cached.fetchedAt, fromCache: true) else { return nil }
        return parsed
    }

    /// Refetch when the cache is older than `refreshInterval` (or `force`). Returns a directory ONLY
    /// when the caller has something new to apply; `nil` means "keep showing what you've got" —
    /// whether that's because a refresh wasn't due, or because the fetch failed and the cached (or
    /// bundled) list still stands. Never throws, never blocks the caller's UI.
    static func refreshIfNeeded(force: Bool = false) async -> HotspotDirectory? {
        if !force,
           let cached = HotspotCache.load(),
           Date().timeIntervalSince(cached.fetchedAt) < refreshInterval {
            return nil
        }

        guard let url = URL(string: "\(baseURL)/pogo/hotspots") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            let now = Date()
            guard let directory = parse(data, fetchedAt: now, fromCache: false) else { return nil }
            // Only cache a genuinely-usable payload (at least one spot parsed), so a transient empty
            // or garbage 200 can never overwrite a good cached directory — same rule as the events feed.
            HotspotCache.store(data, fetchedAt: now)
            return directory
        } catch {
            // Offline / DNS / timeout: silently keep whatever the caller is already showing.
            return nil
        }
    }

    // MARK: - Parsing (field-tolerant, mirrors WanderPoGoEvents)

    /// Decode a payload into a directory, or `nil` if nothing usable came out of it. A spot missing
    /// its name or coordinates is dropped rather than failing the whole list; every freshness field
    /// is optional, so a future server that stops sending `ageDays` just shows one less line.
    private static func parse(_ data: Data, fetchedAt: Date, fromCache: Bool) -> HotspotDirectory? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let rawArray = root["hotspots"] as? [[String: Any]] ?? root["data"] as? [[String: Any]] else {
            return nil
        }
        let spots = rawArray.compactMap(parseHotspot)
        guard !spots.isEmpty else { return nil }
        return HotspotDirectory(
            hotspots: spots,
            updatedAt: parseISODate(string(root, "updatedAt")),
            fetchedAt: fetchedAt,
            fromCache: fromCache
        )
    }

    private static func parseHotspot(_ d: [String: Any]) -> PoGoHotspot? {
        guard let name = string(d, "name"), !name.isEmpty,
              let lat = double(d, "lat"), let lng = double(d, "lng") else { return nil }
        return PoGoHotspot(
            name: name,
            // The feed calls it `region`; the bundled list calls it `area`. Accept both so a schema
            // rename doesn't blank out every subtitle.
            area: string(d, "region") ?? string(d, "area") ?? "",
            cat: category(forKind: string(d, "kind")),
            lat: lat,
            lng: lng,
            status: string(d, "status"),
            lastVerified: string(d, "lastVerified"),
            ageDays: int(d, "ageDays"),
            notes: string(d, "notes")
        )
    }

    /// Map the feed's terse `kind` onto the section headings the bundled list already uses, so the
    /// tab's sections don't rename themselves the first time a live fetch lands.
    private static func category(forKind kind: String?) -> String {
        switch kind?.lowercased() {
        case "spawn": return "Spawn hotspot"
        case "raid":  return "Raid hub"
        case "event": return "Event spot"
        default:      return "Popular spot"
        }
    }

    /// `updatedAt` / `lastVerified` arrive as plain ISO dates ("2026-07-28"), sometimes with a time
    /// component. Parsed as UTC — these are editorial dates, not local wall-clock like the events feed.
    static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let isoFormatters: [DateFormatter] = {
        let patterns = ["yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss"]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = pattern
            return f
        }
    }()

    private static func string(_ d: [String: Any], _ key: String) -> String? {
        d[key] as? String
    }

    private static func double(_ d: [String: Any], _ key: String) -> Double? {
        if let n = d[key] as? NSNumber { return n.doubleValue }
        if let s = d[key] as? String { return Double(s) }
        return nil
    }

    private static func int(_ d: [String: Any], _ key: String) -> Int? {
        if let n = d[key] as? NSNumber { return n.intValue }
        if let s = d[key] as? String { return Int(s) }
        return nil
    }
}

// MARK: - Local cache

/// Last good raw payload + when we pulled it. Same UserDefaults+Data idiom as PoGoCache; the
/// timestamp lives next to the payload because it's what the refresh throttle reads.
private enum HotspotCache {
    private static let dataKey = "pogoHotspots.cache.data"
    private static let stampKey = "pogoHotspots.cache.fetchedAt"

    static func store(_ data: Data, fetchedAt: Date) {
        UserDefaults.standard.set(data, forKey: dataKey)
        UserDefaults.standard.set(fetchedAt.timeIntervalSince1970, forKey: stampKey)
    }

    static func load() -> (data: Data, fetchedAt: Date)? {
        guard let data = UserDefaults.standard.data(forKey: dataKey) else { return nil }
        let stamp = UserDefaults.standard.double(forKey: stampKey)
        // A payload with no timestamp (or a clock that moved backwards) is treated as ancient, so
        // the next refresh runs instead of the cache pinning itself as "fresh" forever.
        let fetchedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : .distantPast
        return (data, fetchedAt)
    }
}

// MARK: - Per-spot freshness display

extension PoGoHotspot {
    /// Trust level for this spot; bundled spots (no `status` field) read as `.unknown`.
    var statusValue: HotspotStatus { HotspotStatus(feedValue: status) }

    /// True for a spot the directory says has been nerfed — still tappable (the coordinates are
    /// fine), but dimmed and flagged so nobody plans a session around it.
    var isNerfed: Bool { statusValue == .nerfed }

    /// How many days ago a human last checked this spot. Prefers the server's precomputed `ageDays`
    /// (it knows when it built the payload) and falls back to the ISO `lastVerified` date, which
    /// keeps working if a cached payload has been sitting on disk for a while.
    var verifiedAgeDays: Int? {
        if let ageDays, ageDays >= 0 { return ageDays }
        guard let date = WanderHotspots.parseISODate(lastVerified) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day
        guard let days, days >= 0 else { return nil }
        return days
    }

    /// Short freshness line ("checked today" / "checked 12 days ago"), or nil when the directory has
    /// never verified this spot — in which case we say nothing rather than implying a date we lack.
    var verifiedAgeText: String? {
        guard let days = verifiedAgeDays else { return nil }
        switch days {
        case 0:        return "checked today"
        case 1:        return "checked yesterday"
        case 2...45:   return "checked \(days) days ago"
        default:
            let months = max(1, days / 30)
            return months == 1 ? "checked a month ago" : "checked \(months) months ago"
        }
    }
}
