//
//  OfflineGeocoder.swift
//  Wander
//
//  On-device, ZERO-network gazetteer for natural-language teleport ("take me to Times Square").
//  When the device is offline the Worker /ai/place call can't run, so we resolve the query against
//  a bundled place list instead. A teleport is a one-shot action, so a single linear scan per query
//  is fine; the file (~1.6 MB) is parsed once, lazily, and cached for the process lifetime.
//
//  Data file: offline_places.tsv (bundled). Tab-separated, one entry per line:
//      name \t lat \t lng \t subtitle \t aliases
//  ~34k lines, importance-sorted: ~62 world landmarks first, then ~34k cities by population DESC.
//  So an earlier line is a better match. 'aliases' is a ';'-separated list of already-lowercased,
//  ASCII-folded alternate names (may be empty).
//
//  Data attribution: this place data is derived from GeoNames (https://www.geonames.org),
//  licensed under CC BY 4.0. The user-visible credit lives in Settings → Community
//  ("Offline place data © GeoNames (CC BY 4.0)"). Keep both in sync.
//

import Foundation
import CoreLocation

/// A namespaced, singleton-backed offline place resolver. Everything is `static` — there is no
/// per-instance state — and the parsed table is loaded lazily the first time `resolve` is called.
enum OfflineGeocoder {

    /// One parsed gazetteer row. `key` is the folded primary name (the row's main match key);
    /// `aliases` are the already-folded alternate names. Coordinate + display name/subtitle are
    /// kept verbatim so a hit returns the pretty original name, not the folded key.
    private struct Entry {
        let name: String                 // original display name, e.g. "São Paulo"
        let coordinate: CLLocationCoordinate2D
        let subtitle: String             // e.g. "Paris, France" or a country code like "CN"
        let key: String                  // fold(name)
        let aliases: [String]            // already folded in the data file
    }

    /// Lazily-parsed, process-lifetime cache of the whole gazetteer. Loaded once on first access.
    /// If the file is missing/unreadable this is an empty array and every `resolve` returns nil
    /// (the caller then surfaces a friendly "couldn't find it offline" message — never a crash).
    private static let entries: [Entry] = loadEntries()

    /// Leading filler phrases we strip before matching, longest-first so "teleport me to " wins
    /// over "teleport to ". All lowercased; the query is lowercased before this runs.
    private static let fillerPrefixes: [String] = [
        "teleport me to ",
        "teleport to ",
        "take me to ",
        "navigate to ",
        "bring me to ",
        "go to ",
        "show me ",
        "find ",
    ]

    // MARK: - Public API

    /// Resolve a natural-language query to a place, entirely on-device. Returns the resolved
    /// display name, coordinate, and subtitle — or nil if nothing matched.
    ///
    /// Matching (see the shared spec):
    ///   T3 exact  — a key == normalizedQuery
    ///   T2 prefix — a key startsWith normalizedQuery ("tok" → Tokyo)
    ///   T1 contains — normalizedQuery startsWith a key (extra words, "eiffel tower paris")
    ///                 OR a key contains normalizedQuery
    /// Higher tier wins; within a tier the earlier line wins (file is importance-sorted).
    static func resolve(_ query: String) -> (name: String, coordinate: CLLocationCoordinate2D, subtitle: String)? {
        guard let normalized = normalize(query) else { return nil }

        let list = entries
        guard !list.isEmpty else { return nil }

        // Track the best hit by (tier, line index). Higher tier wins; ties broken by earliest line.
        var bestTier = 0
        var bestIndex = -1

        for (index, entry) in list.enumerated() {
            let tier = tierFor(entry: entry, query: normalized)
            if tier > bestTier {
                bestTier = tier
                bestIndex = index
                if bestTier == 3 {
                    // T3 exact on the earliest possible line is unbeatable — nothing later can
                    // outrank an exact match found at a smaller line index. Stop scanning.
                    break
                }
            }
        }

        guard bestIndex >= 0 else { return nil }
        let hit = list[bestIndex]
        return (name: hit.name, coordinate: hit.coordinate, subtitle: hit.subtitle)
    }

    // MARK: - Matching

    /// The best tier this entry achieves for `query` (0 = no match). Keys are the folded name plus
    /// every (already-folded) alias.
    private static func tierFor(entry: Entry, query: String) -> Int {
        var best = 0
        // Primary key first, then aliases. Any key reaching T3 is the max, so we can early-out.
        if let t = matchTier(key: entry.key, query: query) {
            best = max(best, t)
            if best == 3 { return 3 }
        }
        for alias in entry.aliases {
            if let t = matchTier(key: alias, query: query) {
                best = max(best, t)
                if best == 3 { return 3 }
            }
        }
        return best
    }

    /// Tier for a single key against the normalized query, or nil for no match.
    private static func matchTier(key: String, query: String) -> Int? {
        if key.isEmpty { return nil }
        if key == query { return 3 }                 // T3 exact
        if key.hasPrefix(query) { return 2 }         // T2 prefix: "tok" → "tokyo"
        // T1 contains: query has extra words ("eiffel tower paris" starts with the key "eiffel
        // tower"), OR the key contains the query as a substring.
        if query.hasPrefix(key) || key.contains(query) { return 1 }
        return nil
    }

    // MARK: - Normalization

    /// Normalize the raw query per the shared spec: lowercase; accent-fold to ASCII; strip a
    /// leading filler phrase; strip a single leading "the "; collapse internal whitespace; trim.
    /// Returns nil if the cleaned query is shorter than 2 characters.
    private static func normalize(_ query: String) -> String? {
        var s = fold(query)

        // Collapse internal whitespace runs to a single space and trim FIRST, so a double
        // space inside a filler phrase ("take me  to X") can't defeat the prefix match below.
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
             .joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip one leading filler phrase (longest match wins via the ordered list).
        for prefix in fillerPrefixes where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }

        // Strip a single leading "the ".
        if s.hasPrefix("the ") {
            s = String(s.dropFirst(4))
        }

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= 2 ? s : nil
    }

    /// fold(): lowercase + strip diacritics (accent-fold to ASCII). Matches how the data file's
    /// aliases were pre-folded, so query keys and data keys are comparable.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
         .lowercased()
    }

    // MARK: - Loading

    /// Parse the bundled TSV into `Entry` rows. Best-effort: a missing file or a malformed line
    /// is skipped (never a crash). Called once, lazily, from the `entries` static initializer.
    private static func loadEntries() -> [Entry] {
        guard let url = Bundle.main.url(forResource: "offline_places", withExtension: "tsv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var result: [Entry] = []
        result.reserveCapacity(34_100)

        // Split on newlines; tolerate a trailing blank line.
        raw.enumerateLines { line, _ in
            if line.isEmpty { return }
            // Exactly 5 tab-separated fields: name, lat, lng, subtitle, aliases.
            let cols = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard cols.count >= 3,
                  let lat = Double(cols[1]),
                  let lng = Double(cols[2]) else { return }

            let name = String(cols[0])
            let subtitle = cols.count > 3 ? String(cols[3]) : ""
            let aliasField = cols.count > 4 ? String(cols[4]) : ""
            let aliases: [String] = aliasField.isEmpty
                ? []
                : aliasField.split(separator: ";").map(String.init).filter { !$0.isEmpty }

            result.append(Entry(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                subtitle: subtitle,
                key: fold(name),
                aliases: aliases
            ))
        }
        return result
    }
}
