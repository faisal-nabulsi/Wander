//
//  WanderBackup.swift
//  Wander
//
//  Backup / Restore (FREE). Exports ALL of the user's saved data to a single JSON file
//  via the share/save sheet, and restores it back.
//
//  What's included:
//   • Favorites / bookmarks (with folders, tags, notes)  — UserDefaults "locationBookmarks"
//   • Saved routes AND recorded routes (recorded ones carry timestamps) — "savedRoutes"
//   • Teleport history (recents)                          — UserDefaults "recentPlaces"
//
//  DATA SAFETY (critical):
//   • Import MERGES additively — it NEVER wipes existing data.
//   • Re-importing the same file DEDUPES instead of duplicating (stable per-record keys).
//   • A malformed / partial file fails gracefully with a message and leaves existing data
//     UNTOUCHED (we decode + validate the whole envelope before writing anything).
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The versioned envelope written to / read from the backup JSON file.
struct WanderBackupEnvelope: Codable {
    /// Marker so we can recognise our own files and reject unrelated JSON.
    var format: String = WanderBackup.formatMarker
    var version: Int = 1
    var exportedAt: Date = Date()

    var bookmarks: [LocationBookmark] = []
    var savedRoutes: [SavedRoute] = []
    var recents: [LocationBookmark] = []

    init(format: String = WanderBackup.formatMarker,
         version: Int = 1,
         exportedAt: Date = Date(),
         bookmarks: [LocationBookmark] = [],
         savedRoutes: [SavedRoute] = [],
         recents: [LocationBookmark] = []) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.bookmarks = bookmarks
        self.savedRoutes = savedRoutes
        self.recents = recents
    }

    // Lenient decode: `format` is required (so we can reject non-Wander files), but a backup
    // that omits a whole section (an older or partial export) still restores what it does
    // contain rather than failing outright. A section present but *malformed* still throws.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        bookmarks = try c.decodeIfPresent([LocationBookmark].self, forKey: .bookmarks) ?? []
        savedRoutes = try c.decodeIfPresent([SavedRoute].self, forKey: .savedRoutes) ?? []
        recents = try c.decodeIfPresent([LocationBookmark].self, forKey: .recents) ?? []
    }
}

/// Result of a restore, for user-facing feedback.
struct WanderRestoreSummary {
    var bookmarksAdded = 0
    var routesAdded = 0
    var recentsAdded = 0

    var totalAdded: Int { bookmarksAdded + routesAdded + recentsAdded }
}

enum WanderBackupError: LocalizedError {
    case unreadable
    case notWanderBackup
    case corrupt

    var errorDescription: String? {
        switch self {
        case .unreadable:      return "Couldn't read the selected file."
        case .notWanderBackup: return "That file isn't a Wander backup."
        case .corrupt:         return "That backup file is damaged or incomplete. Your existing data was left untouched."
        }
    }
}

enum WanderBackup {
    static let formatMarker = "wander.backup"

    // UserDefaults keys — kept identical to the stores that own each list.
    private static let bookmarksKey = "locationBookmarks"
    private static let savedRoutesKey = "savedRoutes"
    private static let recentsKey = "recentPlaces"

    // MARK: - Export

    /// Gather EVERYTHING the user has saved into one envelope.
    static func makeEnvelope() -> WanderBackupEnvelope {
        WanderBackupEnvelope(
            bookmarks: decode([LocationBookmark].self, key: bookmarksKey) ?? [],
            savedRoutes: decode([SavedRoute].self, key: savedRoutesKey) ?? [],
            recents: decode([LocationBookmark].self, key: recentsKey) ?? []
        )
    }

    /// Encode the current backup as pretty-printed JSON data.
    static func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(makeEnvelope())
    }

    /// A stable, human-friendly filename for the export sheet.
    static func suggestedFileName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "Wander-Backup-\(df.string(from: Date())).json"
    }

    // MARK: - Import (additive merge + dedupe)

    /// Decode + validate an envelope from raw file data. Throws (leaving nothing written)
    /// if the data isn't JSON, isn't a Wander backup, or is structurally corrupt.
    static func decodeEnvelope(_ data: Data) throws -> WanderBackupEnvelope {
        guard !data.isEmpty else { throw WanderBackupError.unreadable }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let envelope: WanderBackupEnvelope
        do {
            envelope = try decoder.decode(WanderBackupEnvelope.self, from: data)
        } catch {
            // Distinguish "valid JSON but not our shape / not a backup" from garbage so we
            // can give a precise message. Either way: nothing is written.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (obj["format"] as? String) != formatMarker {
                    throw WanderBackupError.notWanderBackup
                }
            }
            throw WanderBackupError.corrupt
        }

        guard envelope.format == formatMarker else { throw WanderBackupError.notWanderBackup }
        return envelope
    }

    /// Restore an envelope by MERGING additively into existing data. Existing records are
    /// never removed; incoming records that already exist (by stable key) are skipped so a
    /// re-import of the same file adds nothing. Returns a count of what was actually added.
    ///
    /// This writes each list only after computing its full merged result, so a mid-way
    /// failure can't leave data half-written (and decode/validation already happened).
    @MainActor
    @discardableResult
    static func restore(_ envelope: WanderBackupEnvelope) -> WanderRestoreSummary {
        var summary = WanderRestoreSummary()

        // 1) Bookmarks — dedupe by LocationBookmark.syncKey (name + rounded coords).
        do {
            var existing = decode([LocationBookmark].self, key: bookmarksKey) ?? []
            var seen = Set(existing.map { $0.syncKey })
            for incoming in envelope.bookmarks where !seen.contains(incoming.syncKey) {
                existing.append(incoming)
                seen.insert(incoming.syncKey)
                summary.bookmarksAdded += 1
            }
            if summary.bookmarksAdded > 0 { write(existing, key: bookmarksKey) }
        }

        // 2) Saved + recorded routes — dedupe by a content signature.
        do {
            var existing = decode([SavedRoute].self, key: savedRoutesKey) ?? []
            var seen = Set(existing.map(routeDedupeKey))
            for incoming in envelope.savedRoutes where !seen.contains(routeDedupeKey(incoming)) {
                existing.append(incoming)
                seen.insert(routeDedupeKey(incoming))
                summary.routesAdded += 1
            }
            if summary.routesAdded > 0 { write(existing, key: savedRoutesKey) }
        }

        // 3) Teleport history — dedupe by syncKey; keep newest-first ordering and the 12 cap
        //    the recents store enforces. New records go to the FRONT (most-recent) so they
        //    survive the cap rather than being trimmed off the tail.
        do {
            let existing = decode([LocationBookmark].self, key: recentsKey) ?? []
            var seen = Set(existing.map { $0.syncKey })
            var toPrepend: [LocationBookmark] = []
            for incoming in envelope.recents where !seen.contains(incoming.syncKey) {
                toPrepend.append(incoming)
                seen.insert(incoming.syncKey)
                summary.recentsAdded += 1
            }
            if summary.recentsAdded > 0 {
                var merged = toPrepend + existing
                if merged.count > 12 { merged = Array(merged.prefix(12)) }
                write(merged, key: recentsKey)
            }
        }

        // Notify live views to reload from the shared store.
        if summary.bookmarksAdded > 0 || summary.recentsAdded > 0 {
            NotificationCenter.default.post(name: .placesDidChange, object: nil)
        }
        if summary.routesAdded > 0 {
            NotificationCenter.default.post(name: .savedRoutesDidChange, object: nil)
        }

        return summary
    }

    /// Stable identity for a saved route so a re-import doesn't duplicate it: the trimmed,
    /// lowercased name plus a coarse signature of its points (count + rounded endpoints).
    /// Independent of `id`, so the same route exported twice collapses to one.
    private static func routeDedupeKey(_ route: SavedRoute) -> String {
        let n = route.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let coords = route.coordinates
        func r(_ v: Double) -> Double { (v * 100_000).rounded() / 100_000 }
        let first = coords.first.map { "\(r($0.latitude)),\(r($0.longitude))" } ?? "-"
        let last = coords.last.map { "\(r($0.latitude)),\(r($0.longitude))" } ?? "-"
        return "\(n)|\(coords.count)|\(first)|\(last)|\(route.isRecorded ? "rec" : "wpt")"
    }

    // MARK: - UserDefaults helpers

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// A document wrapping the backup JSON, for SwiftUI's `.fileExporter`.
struct WanderBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
