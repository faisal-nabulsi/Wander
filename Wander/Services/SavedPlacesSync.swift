//
//  SavedPlacesSync.swift
//  Wander
//
//  OPT-IN, PRO-ONLY multi-device sync for saved places. Mirrors the user's saved places
//  (the `locationBookmarks` UserDefaults store the Places tab + Teleport bookmarks share) to
//  Firestore at `users/{uid}/savedPlaces`, using the SAME Firebase account (WanderProAccount)
//  that already backs Pro entitlement — no new dependency, no second sign-in.
//
//  DATA-SAFETY CONTRACT (a bug here wipes users' saved places, so this is non-negotiable):
//   • Sync is PRO-ONLY and OPT-IN. The `syncPlacesEnabled` toggle is OFF by default. When it is
//     off — or the user is not Pro, or not signed into a Wander account — this class does nothing
//     and the app behaves exactly as it does today (local-only).
//   • Merge is an ADDITIVE UNION keyed by `LocationBookmark.syncKey` (lowercased name + coords
//     rounded to ~5 decimals). We pull remote, union with local, write the union back locally,
//     and push local-only / locally-newer items up. Every place that existed on either side
//     survives.
//   • We NEVER delete a local place because it is absent remotely, and NEVER delete a remote
//     place because it is absent locally. Deletions do NOT propagate in this version (safest).
//   • On the same key, the newer `updatedAt` wins the metadata — but a conflict NEVER drops a
//     place; both keys are always represented in the result.
//   • FAIL-SAFE: any Firestore / network / auth / decode error leaves local data untouched, with
//     no crash and no user-visible breakage. A failed pull aborts the whole run before we write
//     anything, so a transient outage can never shrink the local store.
//

import Foundation

@MainActor
final class SavedPlacesSync: ObservableObject {
    static let shared = SavedPlacesSync()

    /// UserDefaults key the whole app uses for the saved-places store (Places tab + bookmarks).
    private let savedKey = "locationBookmarks"
    /// The opt-in toggle. Default OFF (absent → false). Read as source of truth; the Settings
    /// toggle binds to the same @AppStorage key.
    static let enabledKey = "syncPlacesEnabled"

    /// Guards against the write-back re-triggering our own `.placesDidChange` observer into an
    /// infinite sync loop: while we persist the merged union we suppress the next self-triggered run.
    private var isApplyingMerge = false
    /// Serialize runs so a launch sync and a change-triggered sync don't interleave writes.
    private var isSyncing = false

    private var account: WanderProAccount { WanderProAccount.shared }

    private init() {
        // Any saved-places change (from either write path — SavedPlacesStore or the Teleport
        // bookmarks editor) nudges a push. Cheap no-op when sync is disabled / not Pro.
        NotificationCenter.default.addObserver(
            forName: .placesDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.syncIfEnabled() }
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// True only when sync can actually run: opted in, Pro, and signed into a Wander account.
    var canSync: Bool {
        isEnabled && License.shared.isLicensed && account.isSignedIn && account.firebaseUID != nil
    }

    /// Kick a sync if all preconditions hold. Safe to call liberally (launch, toggle-on, on
    /// every local change) — it self-gates and no-ops otherwise.
    func syncIfEnabled() {
        guard canSync, !isSyncing, !isApplyingMerge else { return }
        Task { await self.sync() }
    }

    /// One full reconcile: pull remote → additive union with local → write union locally → push
    /// local-only / locally-newer up. Any failure aborts WITHOUT mutating local data.
    func sync() async {
        guard canSync, !isSyncing else { return }
        guard let uid = account.firebaseUID else { return }
        isSyncing = true
        defer { isSyncing = false }

        let local = loadLocal()

        // 1) PULL remote. A nil result = inconclusive (network/auth/decode error) → abort now,
        //    before touching anything, so a transient failure can never shrink the local store.
        guard let remote = await pullRemote(uid: uid) else { return }

        // 2) UNION by syncKey. Newest updatedAt wins per key; every key on either side survives.
        let (merged, localOnlyOrNewer) = Self.union(local: local, remote: remote)

        // 3) WRITE the union back locally so remote-only places show up on this device. Only
        //    write when it actually changed, and suppress the resulting change notification from
        //    re-entering sync.
        // Defence in depth: never let a write-back shrink the store or drop a local place, no
        // matter what union returns. If it somehow would, skip the local write — local data is
        // untouched and we've still pushed everything up, so nothing is lost.
        let mergedKeys = Set(merged.map { $0.syncKey })
        let coversAllLocal = merged.count >= local.count && local.allSatisfy { mergedKeys.contains($0.syncKey) }
        if coversAllLocal && !Self.sameContents(merged, local) {
            applyMergeLocally(merged)
        }

        // 4) PUSH local-only / locally-newer places up. Best-effort per item; a failed push just
        //    means we retry next time — it never affects local data.
        for place in localOnlyOrNewer {
            await pushOne(uid: uid, place: place)
        }
    }

    // MARK: - Merge

    /// Additive union of two lists keyed by `syncKey`.
    /// - Returns `merged`: one record per key (newest `updatedAt` wins the metadata), containing
    ///   every key present in either list.
    /// - Returns `toPush`: the records whose local version should be written remotely — keys only
    ///   present locally, plus keys where the local copy is strictly newer than remote.
    static func union(local: [LocationBookmark],
                      remote: [LocationBookmark]) -> (merged: [LocationBookmark], toPush: [LocationBookmark]) {
        var remoteByKey: [String: LocationBookmark] = [:]
        for r in remote { remoteByKey[r.syncKey] = r }   // last wins if remote has dupes

        var merged: [LocationBookmark] = []
        var toPush: [LocationBookmark] = []
        var localKeys = Set<String>()
        var reconciledKeys = Set<String>()   // keys already reconciled against remote / pushed once

        // Keep EVERY local place — never collapse two records that happen to share a syncKey
        // (name + rounded coords). Dropping one here was a silent data-loss bug: opting in on a
        // device that had e.g. two pins with the same auto-name could delete one on the first sync.
        // `merged` is therefore always a SUPERSET of local, so a write-back can never shrink it.
        for l in local {
            let key = l.syncKey
            localKeys.insert(key)
            if reconciledKeys.contains(key) {
                merged.append(l)                 // a further local record with the same key → keep it, don't re-push
                continue
            }
            reconciledKeys.insert(key)
            if let r = remoteByKey[key] {
                // Same place on both sides → newest updatedAt wins; a missing date is oldest.
                if newer(l, than: r) {
                    merged.append(l)
                    toPush.append(l)             // local is newer → push our copy up
                } else {
                    merged.append(r)             // remote metadata newer → adopt it (same place)
                }
            } else {
                merged.append(l)
                toPush.append(l)                 // local-only → keep it and push it up
            }
        }
        // Add remote-only places (keys never seen locally) so they appear on this device.
        for r in remote where !localKeys.contains(r.syncKey) {
            merged.append(r)
        }
        return (merged, toPush)
    }

    /// `a` is newer than `b`. A nil `updatedAt` is treated as the distant past, so any dated
    /// record beats an undated (legacy) one, and two undated records tie (a does NOT win → we
    /// keep the remote copy, avoiding a pointless push).
    private static func newer(_ a: LocationBookmark, than b: LocationBookmark) -> Bool {
        let da = a.updatedAt ?? .distantPast
        let db = b.updatedAt ?? .distantPast
        return da > db
    }

    /// Order-insensitive content equality on the fields we sync, so we skip a needless local write.
    private static func sameContents(_ x: [LocationBookmark], _ y: [LocationBookmark]) -> Bool {
        guard x.count == y.count else { return false }
        func fingerprint(_ list: [LocationBookmark]) -> Set<String> {
            Set(list.map {
                "\($0.syncKey)|\($0.folder ?? "")|\($0.tags.sorted().joined(separator: ","))|\($0.notes ?? "")"
            })
        }
        return fingerprint(x) == fingerprint(y)
    }

    // MARK: - Local store

    private func loadLocal() -> [LocationBookmark] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return [] }
        return decoded
    }

    /// Persist the merged union locally and tell the UI to reload — WITHOUT letting the resulting
    /// `.placesDidChange` re-enter sync (the isApplyingMerge guard is cleared on the next runloop
    /// turn, after the notification has been delivered).
    private func applyMergeLocally(_ merged: [LocationBookmark]) {
        guard let data = try? JSONEncoder().encode(merged) else { return }
        isApplyingMerge = true
        UserDefaults.standard.set(data, forKey: savedKey)
        NotificationCenter.default.post(name: .placesDidChange, object: nil)
        // Clear the guard after the synchronous observers above have run.
        DispatchQueue.main.async { [weak self] in self?.isApplyingMerge = false }
    }

    // MARK: - Firestore REST (via WanderProAccount's authenticated request)

    private func collectionPath(uid: String) -> String {
        "projects/\(account.firestoreProjectId)/databases/(default)/documents/users/\(uid)/savedPlaces"
    }

    /// Deterministic, path-safe Firestore document id derived from the stable syncKey, so the same
    /// place always maps to the same document (idempotent pushes; no duplicates).
    private func docId(for place: LocationBookmark) -> String {
        Self.stableDocId(place.syncKey)
    }

    static func stableDocId(_ key: String) -> String {
        // FNV-1a 64-bit hash → hex. Deterministic across devices and process runs (unlike
        // Swift's Hasher, which is per-process seeded), and always a valid Firestore doc id.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "wp_%016llx", hash)
    }

    /// Pull all remote places. Returns nil on ANY failure (so the caller aborts without touching
    /// local data); returns [] only when the collection genuinely has no documents.
    private func pullRemote(uid: String) async -> [LocationBookmark]? {
        var results: [LocationBookmark] = []
        var pageToken: String? = nil
        repeat {
            var query = "pageSize=300"
            if let pageToken { query += "&pageToken=\(pageToken)" }
            guard let (data, http) = await account.firestoreRequest(
                method: "GET", path: collectionPath(uid: uid), query: query
            ) else { return nil }

            // 200 with docs, or 200/404 with an empty collection. Firestore returns 200 and an
            // empty body for an empty collection; a 404 here (collection missing) is also "empty",
            // not an error. Any other status is inconclusive → abort.
            if http.statusCode == 404 { return results }
            guard http.statusCode == 200 else { return nil }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            if let documents = obj["documents"] as? [[String: Any]] {
                for doc in documents {
                    if let place = Self.decodePlace(doc) { results.append(place) }
                }
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil

        return results
    }

    /// Write one place to `users/{uid}/savedPlaces/{docId}` (idempotent PATCH = create-or-replace).
    /// Best-effort: failures are swallowed so a bad push never surfaces or blocks anything.
    private func pushOne(uid: String, place: LocationBookmark) async {
        let path = "\(collectionPath(uid: uid))/\(docId(for: place))"
        guard let body = Self.encodePlace(place) else { return }
        _ = await account.firestoreRequest(method: "PATCH", path: path, body: body)
    }

    // MARK: - Firestore document <-> LocationBookmark

    /// Encode a place into a Firestore REST document body ({ "fields": { ... } }).
    private static func encodePlace(_ p: LocationBookmark) -> Data? {
        var fields: [String: Any] = [
            "id": ["stringValue": p.id.uuidString],
            "name": ["stringValue": p.name],
            "latitude": ["doubleValue": p.latitude],
            "longitude": ["doubleValue": p.longitude],
        ]
        if let folder = p.folder { fields["folder"] = ["stringValue": folder] }
        if !p.tags.isEmpty {
            fields["tags"] = ["arrayValue": ["values": p.tags.map { ["stringValue": $0] }]]
        }
        if let notes = p.notes { fields["notes"] = ["stringValue": notes] }
        let iso = ISO8601DateFormatter()
        let date = p.updatedAt ?? Date()
        fields["updatedAt"] = ["timestampValue": iso.string(from: date)]
        return try? JSONSerialization.data(withJSONObject: ["fields": fields])
    }

    /// Decode a Firestore REST document into a LocationBookmark. Returns nil if it lacks the
    /// required name/lat/lng (a malformed or foreign doc is skipped, never crashes the pull).
    private static func decodePlace(_ doc: [String: Any]) -> LocationBookmark? {
        guard let fields = doc["fields"] as? [String: Any] else { return nil }
        func string(_ key: String) -> String? { (fields[key] as? [String: Any])?["stringValue"] as? String }
        func double(_ key: String) -> Double? {
            guard let f = fields[key] as? [String: Any] else { return nil }
            if let d = f["doubleValue"] as? Double { return d }
            if let i = f["integerValue"] as? String { return Double(i) }
            if let n = f["doubleValue"] as? NSNumber { return n.doubleValue }
            return nil
        }
        guard let name = string("name"),
              let lat = double("latitude"),
              let lng = double("longitude") else { return nil }

        let id = string("id").flatMap { UUID(uuidString: $0) } ?? UUID()
        let folder = string("folder")
        let notes = string("notes")
        var tags: [String] = []
        if let arr = (fields["tags"] as? [String: Any])?["arrayValue"] as? [String: Any],
           let values = arr["values"] as? [[String: Any]] {
            tags = values.compactMap { $0["stringValue"] as? String }
        }
        var updatedAt: Date? = nil
        if let ts = (fields["updatedAt"] as? [String: Any])?["timestampValue"] as? String {
            updatedAt = ISO8601DateFormatter().date(from: ts)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: ts)
        }
        return LocationBookmark(id: id, name: name, latitude: lat, longitude: lng,
                                folder: folder, tags: tags, notes: notes, updatedAt: updatedAt)
    }
}

private extension ISO8601DateFormatter {
    /// Firestore timestamps come back with fractional seconds; a second parser handles those.
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
