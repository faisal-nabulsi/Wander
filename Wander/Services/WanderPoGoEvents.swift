//
//  WanderPoGoEvents.swift
//  Wander
//
//  Read-only community data (LeekDuck / ScrapedDuck) surfaced through Wander's Worker. This is
//  PUBLIC data — no auth, no idToken — so it's a plain URLSession GET, unlike the AI endpoints.
//  We ONLY display the returned info (raid bosses, egg pools, current events, field research,
//  Team Rocket lineups); we never use any scraped coordinates and never spoof from this data.
//
//  Endpoints (all GET, no auth):
//    GET <base>/pogo/events?type=raids    → [ { name, tier, canBeShiny, types:[{name}], combatPower{normal{min,max}}, ... } ]
//    GET <base>/pogo/events?type=eggs     → [ { name, eggType ("1 km"/"7 km"), isAdventureSync, canBeShiny, combatPower{min,max}, ... } ]
//    GET <base>/pogo/events?type=events   → [ { name, eventType, heading, start, end, ... } ]
//    GET <base>/pogo/events?type=research → [ { text ("<span>Catch 10…</span>"), rewards:[{name,canBeShiny,combatPower{min,max}}] } ]
//    GET <base>/pogo/events?type=rocket   → [ { name, title, type, firstPokemon:[…], secondPokemon:[…], thirdPokemon:[…] } ]
//
//  Every failure (offline, non-200, malformed) maps to a friendly outcome — never a crash. The
//  last SUCCESSFUL payload for each type is cached locally (UserDefaults, same idiom as the other
//  offline-tolerant stores) so a later offline fetch can degrade gracefully to the cached data.
//  Missing/renamed fields degrade gracefully (a boss with no tier still shows under "Other").
//

import Foundation

// MARK: - Models

/// A perfect-IV combat-power window ("perfect / min–max") shown next to a boss or reward.
struct PoGoCP: Equatable {
    let min: Int
    let max: Int
}

/// A current raid boss. `types` are the Pokémon's types (for the little type chips); `cp` is the
/// unboosted (level-20) perfect-IV CP window when the feed provides it.
struct PoGoRaidBoss: Identifiable {
    let id = UUID()
    let name: String
    let tier: String
    let canBeShiny: Bool
    let types: [String]
    let cp: PoGoCP?
    let imageURL: String?
}

/// A species currently hatching from eggs, grouped by `eggType` distance ("2 km", "7 km", …).
struct PoGoEggEntry: Identifiable {
    let id = UUID()
    let name: String
    let eggType: String
    let isAdventureSync: Bool
    let canBeShiny: Bool
    let cp: PoGoCP?
    let imageURL: String?
}

/// A current in-game event (spotlight hour, community day, raid day, …). `start`/`end` are parsed
/// from the feed's ISO-ish local timestamps when present, so the UI can show a local-time window.
struct PoGoEvent: Identifiable {
    let id = UUID()
    let name: String
    let eventType: String
    let heading: String?
    let start: Date?
    let end: Date?
}

/// One field-research task and the Pokémon reward(s) you can earn for completing it.
struct PoGoResearchTask: Identifiable {
    let id = UUID()
    let task: String
    let rewards: [PoGoResearchReward]
}

/// A single research reward Pokémon (+ shiny / CP if the feed provides it).
struct PoGoResearchReward: Identifiable {
    let id = UUID()
    let name: String
    let canBeShiny: Bool
    let cp: PoGoCP?
    let imageURL: String?
}

/// A Team GO Rocket lineup: a grunt (or leader/boss) and the Pokémon they can throw.
struct PoGoRocketLineup: Identifiable {
    let id = UUID()
    /// Grunt identity, e.g. "Normal-type Male Grunt", "Cliff", "Giovanni".
    let name: String
    /// e.g. "Team GO Rocket Grunt" / "Team GO Rocket Leader" / "Team GO Rocket Boss".
    let title: String?
    /// The grunt's type theme when present ("normal", "fire", …); empty for leaders/boss.
    let type: String
    /// Possible Pokémon across all three slots (deduped for a compact display).
    let pokemon: [PoGoRocketPokemon]
}

/// One possible Rocket Pokémon: shadow by nature; `isEncounter` marks a catchable reward.
struct PoGoRocketPokemon: Identifiable {
    let id = UUID()
    let name: String
    let types: [String]
    /// True when this Pokémon is the catchable encounter reward for beating the grunt.
    let isEncounter: Bool
    let canBeShiny: Bool
    let imageURL: String?
}

/// One typed outcome for a PoGo data fetch. There's no throwing path — offline/HTTP/decode all
/// collapse to `.failed`, and a healthy-but-empty feed is `.success([], fromCache: false)`.
/// When a live fetch fails but a cached payload exists, we return `.success(cached, fromCache: true)`
/// so the UI can show the last-known data with a subtle "offline" note instead of a dead error.
enum PoGoFetchResult<T> {
    case success([T], fromCache: Bool)
    case failed(String)
}

// MARK: - Service

enum WanderPoGoEvents {
    /// Same Worker base as the AI endpoints, but these routes are public (no idToken).
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    static func fetchRaids() async -> PoGoFetchResult<PoGoRaidBoss> {
        await fetch(type: "raids", parse: parseRaid)
    }

    static func fetchEggs() async -> PoGoFetchResult<PoGoEggEntry> {
        await fetch(type: "eggs", parse: parseEgg)
    }

    static func fetchEvents() async -> PoGoFetchResult<PoGoEvent> {
        await fetch(type: "events", parse: parseEvent)
    }

    static func fetchResearch() async -> PoGoFetchResult<PoGoResearchTask> {
        await fetch(type: "research", parse: parseResearch)
    }

    static func fetchRocket() async -> PoGoFetchResult<PoGoRocketLineup> {
        await fetch(type: "rocket", parse: parseRocket)
    }

    /// Shared GET + JSON-array decode with graceful offline fallback. The Worker may return a bare
    /// array or wrap it under a common key ({ ok, data:[…] } / { raids:[…] } etc.) — we accept
    /// either. On a successful parse we cache the raw payload; on failure we fall back to the last
    /// cached payload for this type when one exists.
    private static func fetch<T>(type: String,
                                 parse: @escaping ([String: Any]) -> T?) async -> PoGoFetchResult<T> {
        guard var comps = URLComponents(string: "\(baseURL)/pogo/events") else {
            return cachedFallback(type: type, parse: parse, error: "Couldn't build the request.")
        }
        comps.queryItems = [URLQueryItem(name: "type", value: type)]
        guard let url = comps.url else {
            return cachedFallback(type: type, parse: parse, error: "Couldn't build the request.")
        }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return cachedFallback(type: type, parse: parse, error: "No response. Please try again.")
            }
            guard (200...299).contains(http.statusCode) else {
                return cachedFallback(type: type, parse: parse,
                                      error: "Couldn't load \(type) (\(http.statusCode)).")
            }
            guard let rawArray = jsonArray(from: data, type: type) else {
                return cachedFallback(type: type, parse: parse,
                                      error: "The \(type) data couldn't be read.")
            }
            let items = rawArray.compactMap(parse)
            // Only cache a genuinely-usable payload (parsed at least one item), so a transient
            // empty/garbage 200 never overwrites good cached data.
            if !items.isEmpty {
                PoGoCache.store(data, type: type)
            }
            return .success(items, fromCache: false)
        } catch {
            return cachedFallback(type: type, parse: parse,
                                  error: "Couldn't reach the server. Check your connection.")
        }
    }

    /// Try the last cached payload for this type; return it as a `fromCache` success so the UI can
    /// show it with an offline note. If there's no cache, surface the original error.
    private static func cachedFallback<T>(type: String,
                                          parse: @escaping ([String: Any]) -> T?,
                                          error: String) -> PoGoFetchResult<T> {
        if let data = PoGoCache.load(type: type),
           let rawArray = jsonArray(from: data, type: type) {
            let items = rawArray.compactMap(parse)
            if !items.isEmpty {
                return .success(items, fromCache: true)
            }
        }
        return .failed(error)
    }

    /// Pull the array of dictionaries out of the response whether it's a bare array or wrapped
    /// under `data` or the type name (`raids`/`eggs`/`events`/`research`/`rocket`).
    private static func jsonArray(from data: Data, type: String) -> [[String: Any]]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] { return array }
        if let dict = object as? [String: Any] {
            for key in ["data", type, "results", "items"] {
                if let array = dict[key] as? [[String: Any]] { return array }
            }
        }
        return nil
    }

    // MARK: - Parsing (all field-tolerant)

    private static func parseRaid(_ d: [String: Any]) -> PoGoRaidBoss? {
        guard let name = string(d, "name"), !name.isEmpty else { return nil }
        return PoGoRaidBoss(
            name: name,
            tier: string(d, "tier") ?? "Other",
            canBeShiny: bool(d, "canBeShiny"),
            types: parseTypeNames(d["types"]),
            cp: parseCP(d["combatPower"]),
            imageURL: string(d, "image") ?? string(d, "imageURL") ?? string(d, "assets")
        )
    }

    private static func parseEgg(_ d: [String: Any]) -> PoGoEggEntry? {
        guard let name = string(d, "name"), !name.isEmpty else { return nil }
        return PoGoEggEntry(
            name: name,
            eggType: string(d, "eggType") ?? string(d, "egg") ?? "Unknown",
            isAdventureSync: bool(d, "isAdventureSync"),
            canBeShiny: bool(d, "canBeShiny"),
            cp: parseCP(d["combatPower"]),
            imageURL: string(d, "image") ?? string(d, "imageURL")
        )
    }

    private static func parseEvent(_ d: [String: Any]) -> PoGoEvent? {
        guard let name = string(d, "name"), !name.isEmpty else { return nil }
        return PoGoEvent(
            name: name,
            eventType: string(d, "eventType") ?? string(d, "type") ?? "Event",
            heading: string(d, "heading"),
            start: parseDate(string(d, "start")),
            end: parseDate(string(d, "end"))
        )
    }

    private static func parseResearch(_ d: [String: Any]) -> PoGoResearchTask? {
        // The task text arrives HTML-wrapped ("<span>Catch 10 Pikachu</span>"); strip tags.
        let raw = string(d, "text") ?? string(d, "task") ?? string(d, "name")
        guard let raw, !raw.isEmpty else { return nil }
        let task = stripHTML(raw)
        guard !task.isEmpty else { return nil }
        let rewards = parseRewardArray(d["rewards"])
        return PoGoResearchTask(task: task, rewards: rewards)
    }

    private static func parseRewardArray(_ value: Any?) -> [PoGoResearchReward] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.compactMap { r in
            guard let name = string(r, "name"), !name.isEmpty else { return nil }
            return PoGoResearchReward(
                name: name,
                canBeShiny: bool(r, "canBeShiny"),
                cp: parseCP(r["combatPower"]),
                imageURL: string(r, "image") ?? string(r, "imageURL")
            )
        }
    }

    private static func parseRocket(_ d: [String: Any]) -> PoGoRocketLineup? {
        guard let name = string(d, "name"), !name.isEmpty else { return nil }
        // Merge the three slots into one deduped list (by name) for a compact display.
        var seen = Set<String>()
        var pokemon: [PoGoRocketPokemon] = []
        for key in ["firstPokemon", "secondPokemon", "thirdPokemon"] {
            for p in parseRocketPokemon(d[key]) where !seen.contains(p.name) {
                seen.insert(p.name)
                pokemon.append(p)
            }
        }
        return PoGoRocketLineup(
            name: name,
            title: string(d, "title"),
            type: string(d, "type") ?? "",
            pokemon: pokemon
        )
    }

    private static func parseRocketPokemon(_ value: Any?) -> [PoGoRocketPokemon] {
        guard let arr = value as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let name = string(p, "name"), !name.isEmpty else { return nil }
            return PoGoRocketPokemon(
                name: name,
                types: parseTypeNames(p["types"]),
                isEncounter: bool(p, "isEncounter"),
                canBeShiny: bool(p, "canBeShiny"),
                imageURL: string(p, "image") ?? string(p, "imageURL")
            )
        }
    }

    /// CP can arrive as { normal:{min,max} } (raids) or a bare { min,max } (eggs/research). Prefer
    /// the unboosted `normal` window; fall back to a top-level min/max.
    private static func parseCP(_ value: Any?) -> PoGoCP? {
        guard let dict = value as? [String: Any] else { return nil }
        if let normal = dict["normal"] as? [String: Any],
           let cp = cpPair(normal) {
            return cp
        }
        return cpPair(dict)
    }

    private static func cpPair(_ d: [String: Any]) -> PoGoCP? {
        guard let lo = int(d, "min"), let hi = int(d, "max") else { return nil }
        return PoGoCP(min: lo, max: hi)
    }

    /// Types can arrive as [{name:"Fire"}], ["Fire"], or a comma string — accept all.
    private static func parseTypeNames(_ value: Any?) -> [String] {
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { string($0, "name") }
        }
        if let arr = value as? [String] {
            return arr
        }
        if let s = value as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// Parse a ScrapedDuck timestamp. These arrive as local wall-clock ISO strings without a zone
    /// ("2026-07-15T18:00:00.000"); we parse them in the device's current timezone so the UI shows
    /// a sensible local window. Falls back to a couple of tolerant formats.
    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = {
        let patterns = ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = pattern
            return f
        }
    }()

    /// Cheap HTML tag/entity strip for the research task text. Not a full parser — just enough to
    /// turn "<span>Catch 10 Pikachu</span>" into "Catch 10 Pikachu".
    private static func stripHTML(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(_ d: [String: Any], _ key: String) -> String? {
        if let s = d[key] as? String { return s }
        return nil
    }

    private static func bool(_ d: [String: Any], _ key: String) -> Bool {
        if let b = d[key] as? Bool { return b }
        if let n = d[key] as? NSNumber { return n.boolValue }
        return false
    }

    private static func int(_ d: [String: Any], _ key: String) -> Int? {
        if let n = d[key] as? NSNumber { return n.intValue }
        if let i = d[key] as? Int { return i }
        if let dbl = d[key] as? Double { return Int(dbl) }
        if let s = d[key] as? String { return Int(s) }
        return nil
    }
}

// MARK: - Local cache

/// Tiny UserDefaults-backed cache of the last successful raw payload per PoGo type, mirroring the
/// UserDefaults+JSON idiom the other offline-tolerant stores use. Keeps all five hub types working
/// offline by replaying the last-known data.
private enum PoGoCache {
    private static func key(_ type: String) -> String { "pogoEvents.cache.\(type)" }

    static func store(_ data: Data, type: String) {
        UserDefaults.standard.set(data, forKey: key(type))
    }

    static func load(type: String) -> Data? {
        UserDefaults.standard.data(forKey: key(type))
    }
}
