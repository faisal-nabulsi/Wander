//
//  OfflineMapPackStore.swift
//  Wander
//
//  Manages MapLibre offline packs for the Offline Maps surface. Replaces the old
//  OfflineTileStore OSM raster-tile bulk downloader (which violated OSM's tile-usage policy).
//
//  A "pack" is a MapLibre-managed download of a bbox + zoom range against our Protomaps
//  vector style: MLNOfflineStorage stores the vector tiles + glyphs + sprites in its own
//  SQLite cache. We wrap the MapLibre APIs so the SwiftUI sheet gets:
//    - `downloadCurrentRegion(...)` → create + resume a pack for the visible bbox;
//    - progress callbacks (completed / expected resource counts);
//    - `loadPacks()` → the saved packs, decoded from each pack's context blob;
//    - `delete(_:)` / `deleteAll()`.
//
//  Pack context is a small JSON blob (name, bbox, zoom range, created date) so a listed pack
//  can be named and re-centred on the map.
//

import Foundation
import MapLibre
import MapKit

/// Metadata we store in each MapLibre pack's `context` blob so the UI can name + locate it.
struct OfflineMapPackInfo: Codable, Equatable {
    var id: UUID
    var name: String
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
    var minZoom: Double
    var maxZoom: Double
    var createdAt: Date

    var region: MKCoordinateRegion {
        let centerLat = (minLatitude + maxLatitude) / 2
        let centerLng = (minLongitude + maxLongitude) / 2
        let spanLat = max(abs(maxLatitude - minLatitude), 0.0001)
        let spanLng = max(abs(maxLongitude - minLongitude), 0.0001)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLng),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLng)
        )
    }
}

/// A saved pack surfaced to the UI: identity + metadata + live byte/progress snapshot.
struct OfflineMapPack: Identifiable, Equatable {
    let id: UUID
    let info: OfflineMapPackInfo
    /// Bytes downloaded so far for this pack (from MapLibre's progress).
    let bytes: Int64
    /// Resources expected / completed, for a rough "N%" if the pack is mid-download.
    let completedResources: UInt64
    let expectedResources: UInt64

    var name: String { info.name }
    var region: MKCoordinateRegion { info.region }
    var isComplete: Bool { expectedResources == 0 || completedResources >= expectedResources }
}

@MainActor
final class OfflineMapPackStore: NSObject {
    static let shared = OfflineMapPackStore()

    /// Cap the download zoom so a pack can't explode. Vector tiles stay readable at z14.
    static let maxZoomCap: Double = OfflineMapConfig.offlinePackMaxZoom

    private let storage = MLNOfflineStorage.shared

    /// Progress handler for the currently-downloading pack, keyed by pack id.
    private var activeProgress: [UUID: (Int64, UInt64, UInt64) -> Void] = [:]
    /// Completion handlers keyed by pack id.
    private var activeCompletion: [UUID: (Result<Void, Error>) -> Void] = [:]

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(progressChanged(_:)),
            name: NSNotification.Name.MLNOfflinePackProgressChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(errorReceived(_:)),
            name: NSNotification.Name.MLNOfflinePackError, object: nil)
    }

    // MARK: - Download

    /// Create + resume an offline pack for `region` against the offline vector style. `progress`
    /// reports (bytes, completed, expected); `completion` fires once when the pack finishes or errors.
    func downloadRegion(
        name: String,
        region: MKCoordinateRegion,
        minZoom: Double,
        maxZoom: Double,
        progress: @escaping (_ bytes: Int64, _ completed: UInt64, _ expected: UInt64) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2

        let sw = CLLocationCoordinate2D(latitude: minLat, longitude: minLng)
        let ne = CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
        let bounds = MLNCoordinateBounds(sw: sw, ne: ne)

        let cappedMax = min(maxZoom, Self.maxZoomCap)
        let cappedMin = max(0, min(minZoom, cappedMax))

        let mlnRegion = MLNTilePyramidOfflineRegion(
            styleURL: OfflineMapStyle.localStyleURL(),
            bounds: bounds,
            fromZoomLevel: cappedMin,
            toZoomLevel: cappedMax
        )

        let info = OfflineMapPackInfo(
            id: UUID(),
            name: name,
            minLatitude: minLat, maxLatitude: maxLat,
            minLongitude: minLng, maxLongitude: maxLng,
            minZoom: cappedMin, maxZoom: cappedMax,
            createdAt: Date()
        )

        guard let context = try? JSONEncoder().encode(info) else {
            completion(.failure(OfflineMapPackError.encodingFailed))
            return
        }

        storage.addPack(for: mlnRegion, withContext: context) { [weak self] pack, error in
            guard let self else { return }
            if let error {
                completion(.failure(error))
                return
            }
            guard let pack else {
                completion(.failure(OfflineMapPackError.packCreationFailed))
                return
            }
            self.activeProgress[info.id] = progress
            self.activeCompletion[info.id] = completion
            pack.resume()
        }
    }

    // MARK: - Listing

    /// All saved packs, most-recent first. Packs without decodable context are skipped.
    func loadPacks() -> [OfflineMapPack] {
        guard let packs = storage.packs else { return [] }
        let mapped: [OfflineMapPack] = packs.compactMap { pack in
            guard let info = try? JSONDecoder().decode(OfflineMapPackInfo.self, from: pack.context) else {
                return nil
            }
            let progress = pack.progress
            return OfflineMapPack(
                id: info.id,
                info: info,
                bytes: Int64(progress.countOfBytesCompleted),
                completedResources: progress.countOfResourcesCompleted,
                expectedResources: progress.countOfResourcesExpected
            )
        }
        return mapped.sorted { $0.info.createdAt > $1.info.createdAt }
    }

    /// Total bytes across every saved pack.
    func totalBytes() -> Int64 {
        (storage.packs ?? []).reduce(0) { $0 + Int64($1.progress.countOfBytesCompleted) }
    }

    // MARK: - Delete

    func delete(_ pack: OfflineMapPack, completion: (() -> Void)? = nil) {
        guard let mlnPack = matchingPack(for: pack.id) else { completion?(); return }
        activeProgress[pack.id] = nil
        activeCompletion[pack.id] = nil
        storage.removePack(mlnPack) { _ in completion?() }
    }

    func deleteAll(completion: (() -> Void)? = nil) {
        let packs = storage.packs ?? []
        activeProgress.removeAll()
        activeCompletion.removeAll()
        guard !packs.isEmpty else { completion?(); return }
        var remaining = packs.count
        for pack in packs {
            storage.removePack(pack) { _ in
                remaining -= 1
                if remaining == 0 { completion?() }
            }
        }
    }

    // MARK: - Helpers

    private func matchingPack(for id: UUID) -> MLNOfflinePack? {
        (storage.packs ?? []).first {
            (try? JSONDecoder().decode(OfflineMapPackInfo.self, from: $0.context))?.id == id
        }
    }

    private func packInfo(for pack: MLNOfflinePack) -> OfflineMapPackInfo? {
        try? JSONDecoder().decode(OfflineMapPackInfo.self, from: pack.context)
    }

    // MARK: - Notifications

    @objc private func progressChanged(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let info = packInfo(for: pack) else { return }
        let progress = pack.progress
        let bytes = Int64(progress.countOfBytesCompleted)

        if let handler = activeProgress[info.id] {
            handler(bytes, progress.countOfResourcesCompleted, progress.countOfResourcesExpected)
        }

        if pack.state == .complete {
            activeProgress[info.id] = nil
            if let completion = activeCompletion.removeValue(forKey: info.id) {
                completion(.success(()))
            }
        }
    }

    @objc private func errorReceived(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let info = packInfo(for: pack) else { return }
        let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error
            ?? OfflineMapPackError.downloadFailed
        // MapLibre keeps retrying on transient errors; only surface it once and let the pack ride.
        if let completion = activeCompletion.removeValue(forKey: info.id) {
            activeProgress[info.id] = nil
            completion(.failure(error))
        }
    }
}

enum OfflineMapPackError: LocalizedError {
    case encodingFailed
    case packCreationFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed, .packCreationFailed:
            return L("offline.download.failed.body",
                     fallback: "Couldn't start the download. Please try again.")
        case .downloadFailed:
            return L("offline.download.failed.body",
                     fallback: "Some map data couldn't be fetched. Anything downloaded is still available offline.")
        }
    }
}
