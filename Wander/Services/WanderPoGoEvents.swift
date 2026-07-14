//
//  WanderPoGoEvents.swift
//  Wander
//
//  Read-only community data (LeekDuck / ScrapedDuck) surfaced through Wander's Worker. This is
//  PUBLIC data — no auth, no idToken — so it's a plain URLSession GET, unlike the AI endpoints.
//  We ONLY display the returned info (raid bosses, egg pools, current events); we never use any
//  scraped coordinates and never spoof from this data.
//
//  Endpoints (all GET, no auth):
//    GET <base>/pogo/events?type=raids  → [ { name, tier, canBeShiny, types:[{name}], ... } ]
//    GET <base>/pogo/events?type=eggs   → [ { name, eggType ("1 km"/"7 km"), isAdventureSync, canBeShiny, ... } ]
//    GET <base>/pogo/events?type=events → [ { name, eventType, heading, ... } ]
//
//  Every failure (offline, non-200, malformed) maps to a friendly empty/error outcome — never a
//  crash. Missing/renamed fields degrade gracefully (a boss with no tier still shows under "Other").
//

import Foundation

// MARK: - Models

/// A current raid boss. `types` are the Pokémon's types (for the little type chips).
struct PoGoRaidBoss: Identifiable {
    let id = UUID()
    let name: String
    let tier: String
    let canBeShiny: Bool
    let types: [String]
    let imageURL: String?
}

/// A species currently hatching from eggs, grouped by `eggType` distance ("2 km", "7 km", …).
struct PoGoEggEntry: Identifiable {
    let id = UUID()
    let name: String
    let eggType: String
    let isAdventureSync: Bool
    let canBeShiny: Bool
    let imageURL: String?
}

/// A current in-game event (spotlight hour, community day, raid day, …).
struct PoGoEvent: Identifiable {
    let id = UUID()
    let name: String
    let eventType: String
    let heading: String?
}

/// One typed outcome for a PoGo data fetch. There's no throwing path — offline/HTTP/decode all
/// collapse to `.failed`, and a healthy-but-empty feed is `.success([])`.
enum PoGoFetchResult<T> {
    case success([T])
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

    /// Shared GET + JSON-array decode. The Worker may return a bare array or wrap it under a
    /// common key ({ ok, data:[…] } / { raids:[…] } etc.) — we accept either.
    private static func fetch<T>(type: String,
                                 parse: @escaping ([String: Any]) -> T?) async -> PoGoFetchResult<T> {
        guard var comps = URLComponents(string: "\(baseURL)/pogo/events") else {
            return .failed("Couldn't build the request.")
        }
        comps.queryItems = [URLQueryItem(name: "type", value: type)]
        guard let url = comps.url else {
            return .failed("Couldn't build the request.")
        }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("No response. Please try again.")
            }
            guard (200...299).contains(http.statusCode) else {
                return .failed("Couldn't load \(type) (\(http.statusCode)).")
            }
            guard let rawArray = jsonArray(from: data, type: type) else {
                return .failed("The \(type) data couldn't be read.")
            }
            let items = rawArray.compactMap(parse)
            return .success(items)
        } catch {
            return .failed("Couldn't reach the server. Check your connection.")
        }
    }

    /// Pull the array of dictionaries out of the response whether it's a bare array or wrapped
    /// under `data` or the type name (`raids`/`eggs`/`events`).
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
            imageURL: string(d, "image") ?? string(d, "imageURL")
        )
    }

    private static func parseEvent(_ d: [String: Any]) -> PoGoEvent? {
        guard let name = string(d, "name"), !name.isEmpty else { return nil }
        return PoGoEvent(
            name: name,
            eventType: string(d, "eventType") ?? string(d, "type") ?? "Event",
            heading: string(d, "heading")
        )
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

    private static func string(_ d: [String: Any], _ key: String) -> String? {
        if let s = d[key] as? String { return s }
        return nil
    }

    private static func bool(_ d: [String: Any], _ key: String) -> Bool {
        if let b = d[key] as? Bool { return b }
        if let n = d[key] as? NSNumber { return n.boolValue }
        return false
    }
}
