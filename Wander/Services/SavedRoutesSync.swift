//
//  SavedRoutesSync.swift
//  Wander
//
//  OPT-IN, PRO-ONLY multi-device sync for saved ROUTES (builder + recorded). Mirrors the
//  `savedRoutes` UserDefaults store to Firestore at `users/{uid}/savedRoutes`, using the SAME
//  Firebase account (WanderProAccount) that backs Pro entitlement + Places sync — no new sign-in.
//
//  Same DATA-SAFETY CONTRACT as SavedPlacesSync (a bug here wipes users' routes):
//   • PRO-ONLY + OPT-IN (`syncRoutesEnabled`, default OFF). Off / not-Pro / not-signed-in ⇒ no-op.
//   • Additive UNION keyed by `SavedRoute.routeSyncKey`; newest `updatedAt` wins per key; a route on
//     either side ALWAYS survives; deletions never propagate.
//   • FAIL-SAFE: a failed pull aborts before any local write, so a transient outage can't shrink the
//     local store.
//
//  Firestore schema — MUST stay byte-identical to Android/desktop or sync silently transfers
//  nothing: users/{uid}/savedRoutes/{wr_<fnv1a-64 hex of routeSyncKey>}
//    id: string · name: string · pts: [double] FLAT [lat,lng,lat,lng,…] · times: [double] unix secs
//    · pointCount: integer · updatedAt: timestamp (readers also accept integer epoch-millis).
//

import Foundation
import CoreLocation

@MainActor
final class SavedRoutesSync: ObservableObject {
    static let shared = SavedRoutesSync()

    private let savedKey = "savedRoutes"
    static let enabledKey = "syncRoutesEnabled"

    /// Max points synced per route — keeps a dense recorded route under Firestore's 1 MB document
    /// cap. Longer routes still sync, truncated to this many points (both `pts` and `times`).
    private static let maxSyncPoints = 5000

    private var isApplyingMerge = false
    private var isSyncing = false
    private var account: WanderProAccount { WanderProAccount.shared }

    private init() {
        NotificationCenter.default.addObserver(
            forName: .savedRoutesDidChange, object: nil, queue: .main
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

    /// Kick a sync if all preconditions hold. Safe to call liberally — self-gates and no-ops.
    func syncIfEnabled() {
        guard canSync, !isSyncing, !isApplyingMerge else { return }
        Task { await self.sync() }
    }

    /// Pull remote → additive union with local → write union locally → push local-only / newer up.
    /// Any failure aborts WITHOUT mutating local data.
    func sync() async {
        guard canSync, !isSyncing else { return }
        guard let uid = account.firebaseUID else { return }
        isSyncing = true
        defer { isSyncing = false }

        let local = loadLocal()
        guard let remote = await pullRemote(uid: uid) else { return }   // nil ⇒ abort, don't touch local

        let (merged, localOnlyOrNewer) = Self.union(local: local, remote: remote)

        // Defence in depth: never let a write-back shrink the store or drop a local route.
        let mergedKeys = Set(merged.map { $0.routeSyncKey })
        let coversAllLocal = merged.count >= local.count && local.allSatisfy { mergedKeys.contains($0.routeSyncKey) }
        if coversAllLocal && !Self.sameContents(merged, local) {
            applyMergeLocally(merged)
        }
        for route in localOnlyOrNewer {
            await pushOne(uid: uid, route: route)
        }
    }

    // MARK: - Merge (additive union by routeSyncKey; mirrors SavedPlacesSync.union incl. dup-preserve)

    static func union(local: [SavedRoute], remote: [SavedRoute]) -> (merged: [SavedRoute], toPush: [SavedRoute]) {
        var remoteByKey: [String: [SavedRoute]] = [:]
        for r in remote { remoteByKey[r.routeSyncKey, default: []].append(r) }

        var merged: [SavedRoute] = []
        var toPush: [SavedRoute] = []
        var reconciledKeys = Set<String>()

        for l in local {
            let key = l.routeSyncKey
            if reconciledKeys.contains(key) { merged.append(l); continue }   // extra local dup → keep
            reconciledKeys.insert(key)
            let group = remoteByKey[key] ?? []
            if group.isEmpty {
                merged.append(l); toPush.append(l)                           // local-only → keep + push
                continue
            }
            var newestIdx = 0
            for i in 1..<group.count where newer(group[i], than: group[newestIdx]) { newestIdx = i }
            let rNewest = group[newestIdx]
            if newer(l, than: rNewest) { merged.append(l); toPush.append(l) } // local newer → push ours
            else { merged.append(rNewest) }                                   // remote newer → adopt it
            for (i, r) in group.enumerated() where i != newestIdx { merged.append(r) } // keep remote dups
        }
        for r in remote where !reconciledKeys.contains(r.routeSyncKey) { merged.append(r) } // remote-only
        return (merged, toPush)
    }

    private static func newer(_ a: SavedRoute, than b: SavedRoute) -> Bool {
        (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
    }

    private static func sameContents(_ x: [SavedRoute], _ y: [SavedRoute]) -> Bool {
        guard x.count == y.count else { return false }
        func fp(_ list: [SavedRoute]) -> Set<String> {
            Set(list.map { "\($0.routeSyncKey)|\($0.points.count)|\($0.timestamps?.count ?? 0)" })
        }
        return fp(x) == fp(y)
    }

    // MARK: - Local store

    private func loadLocal() -> [SavedRoute] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let decoded = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return [] }
        return decoded
    }

    private func applyMergeLocally(_ merged: [SavedRoute]) {
        guard let data = try? JSONEncoder().encode(merged) else { return }
        isApplyingMerge = true
        UserDefaults.standard.set(data, forKey: savedKey)
        NotificationCenter.default.post(name: .savedRoutesDidChange, object: nil)
        DispatchQueue.main.async { [weak self] in self?.isApplyingMerge = false }
    }

    // MARK: - Firestore REST (via WanderProAccount's authenticated request)

    private func collectionPath(uid: String) -> String {
        "projects/\(account.firestoreProjectId)/databases/(default)/documents/users/\(uid)/savedRoutes"
    }

    private func docId(for route: SavedRoute) -> String { Self.stableDocId(route.routeSyncKey) }

    /// FNV-1a 64-bit → "wr_<hex>". Deterministic across devices/processes (unlike Swift's Hasher),
    /// always a valid Firestore doc id. MUST match the Android/desktop implementation.
    static func stableDocId(_ key: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(format: "wr_%016llx", hash)
    }

    /// Pull all remote routes. nil on ANY failure (caller aborts); [] only for a genuinely empty set.
    private func pullRemote(uid: String) async -> [SavedRoute]? {
        var results: [SavedRoute] = []
        var pageToken: String? = nil
        repeat {
            var query = "pageSize=300"
            if let pageToken { query += "&pageToken=\(pageToken)" }
            guard let (data, http) = await account.firestoreRequest(
                method: "GET", path: collectionPath(uid: uid), query: query
            ) else { return nil }
            if http.statusCode == 404 { return results }   // collection missing == empty, not an error
            guard http.statusCode == 200 else { return nil }
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            if let documents = obj["documents"] as? [[String: Any]] {
                for doc in documents { if let route = Self.decodeRoute(doc) { results.append(route) } }
            }
            pageToken = obj["nextPageToken"] as? String
        } while pageToken != nil
        return results
    }

    /// Idempotent PATCH (create-or-replace). Best-effort: a failed push just retries next run.
    private func pushOne(uid: String, route: SavedRoute) async {
        let path = "\(collectionPath(uid: uid))/\(docId(for: route))"
        guard let body = Self.encodeRoute(route) else { return }
        _ = await account.firestoreRequest(method: "PATCH", path: path, body: body)
    }

    // MARK: - Firestore document <-> SavedRoute

    private static func encodeRoute(_ r: SavedRoute) -> Data? {
        // Flatten to [lat,lng,…] and cap so a dense recorded route can't exceed Firestore's 1 MB doc.
        let cappedPoints = r.points.count > maxSyncPoints ? Array(r.points.prefix(maxSyncPoints)) : r.points
        var flatPts: [Double] = []
        for pair in cappedPoints where pair.count >= 2 { flatPts.append(pair[0]); flatPts.append(pair[1]) }
        var times: [Double] = []
        if let ts = r.timestamps { times = ts.count > maxSyncPoints ? Array(ts.prefix(maxSyncPoints)) : ts }

        var fields: [String: Any] = [
            "id": ["stringValue": r.id.uuidString],
            "name": ["stringValue": r.name],
            "pts": ["arrayValue": ["values": flatPts.map { ["doubleValue": $0] }]],
            "times": ["arrayValue": ["values": times.map { ["doubleValue": $0] }]],
            "pointCount": ["integerValue": String(cappedPoints.count)],
        ]
        let iso = ISO8601DateFormatter()
        fields["updatedAt"] = ["timestampValue": iso.string(from: r.updatedAt ?? Date())]
        return try? JSONSerialization.data(withJSONObject: ["fields": fields])
    }

    private static func decodeRoute(_ doc: [String: Any]) -> SavedRoute? {
        guard let fields = doc["fields"] as? [String: Any] else { return nil }
        func string(_ key: String) -> String? { (fields[key] as? [String: Any])?["stringValue"] as? String }
        func doubleArray(_ key: String) -> [Double] {
            guard let arr = (fields[key] as? [String: Any])?["arrayValue"] as? [String: Any],
                  let values = arr["values"] as? [[String: Any]] else { return [] }
            return values.compactMap { v in
                if let d = v["doubleValue"] as? Double { return d }
                if let n = v["doubleValue"] as? NSNumber { return n.doubleValue }
                if let i = v["integerValue"] as? String { return Double(i) }
                return nil
            }
        }
        guard let name = string("name") else { return nil }
        let flat = doubleArray("pts")
        guard flat.count >= 2 else { return nil }   // a route needs at least one point
        var points: [[Double]] = []
        var i = 0
        while i + 1 < flat.count { points.append([flat[i], flat[i + 1]]); i += 2 }

        let times = doubleArray("times")
        let timestamps: [Double]? = (!times.isEmpty && times.count == points.count) ? times : nil
        let id = string("id").flatMap { UUID(uuidString: $0) } ?? UUID()
        let updated = Self.decodeDate(fields["updatedAt"] as? [String: Any])
        return SavedRoute(id: id, name: name, points: points, timestamps: timestamps, updatedAt: updated)
    }

    /// Accept a Firestore timestampValue (ISO-8601, with or without fractional seconds) OR an
    /// integerValue epoch-millis (how some writers store it), so cross-platform docs decode.
    private static func decodeDate(_ field: [String: Any]?) -> Date? {
        guard let field else { return nil }
        if let iso = field["timestampValue"] as? String {
            let plain = ISO8601DateFormatter()
            if let d = plain.date(from: iso) { return d }
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return frac.date(from: iso)
        }
        if let ms = field["integerValue"] as? String, let msNum = Double(ms) {
            return Date(timeIntervalSince1970: msNum / 1000)
        }
        return nil
    }
}
