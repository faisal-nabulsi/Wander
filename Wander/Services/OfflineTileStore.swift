//
//  OfflineTileStore.swift
//  Wander
//
//  On-disk OSM tile cache for the Offline Maps feature (parity with the Android
//  osmdroid offline flow). Tiles live under Application Support/wander-offline-tiles,
//  keyed z/x/y ({z}/{x}/{y}.png). This store can:
//    - read/write a single tile from/to disk (used by WanderTileOverlay for cache-on-browse);
//    - download an entire REGION (bbox + minZ...maxZ) with progress + cancellation;
//    - estimate the tile count + approximate MB BEFORE downloading, so the UI can warn;
//    - persist a manifest of saved regions (name, bbox, zoom range, count, bytes, date);
//    - report total cache size, delete one region, or delete everything.
//
//  OSM tile-usage policy is respected: a descriptive User-Agent is always sent, the max
//  zoom is capped at 16, and downloads are serialized (no aggressive parallel hammering).
//  The caller is expected to warn when an estimate exceeds `largeDownloadTileThreshold`.
//

import Foundation
import MapKit

// MARK: - Manifest model

/// One saved offline region, persisted in the manifest JSON so regions survive relaunch
/// and can be listed + deleted. `bytes`/`tileCount` reflect what actually landed on disk.
struct OfflineRegion: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
    var minZoom: Int
    var maxZoom: Int
    var tileCount: Int
    var bytes: Int64
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

/// A pre-download estimate the UI shows before committing (count + approx bytes + a "large" flag).
struct OfflineDownloadEstimate: Equatable {
    let tileCount: Int
    let approximateBytes: Int64
    /// True when `tileCount` exceeds the store's large-download threshold — the caller should warn.
    let isLarge: Bool
}

/// Errors surfaced during a region download. `.offline` is the calm no-connection case.
enum OfflineTileError: LocalizedError {
    case offline
    case cancelled

    var errorDescription: String? {
        switch self {
        case .offline:
            return L("offline.download.no_connection",
                     fallback: "No internet connection. Connect to Wi‑Fi or cellular and try downloading again.")
        case .cancelled:
            return L("offline.download.cancelled", fallback: "Download cancelled.")
        }
    }
}

// MARK: - Store

/// Disk-backed OSM tile cache + region manager. `shared` is safe to use from anywhere; the
/// blocking disk reads/writes are cheap and the download runs on its own async task.
final class OfflineTileStore {
    static let shared = OfflineTileStore()

    /// A descriptive User-Agent identifying the app to the tile CDN (CARTO). Reused for tile
    /// fetches here and in WanderTileOverlay.
    static let userAgent = "Wander/1.0 (+https://wanderspoofer.com)"

    /// OSM's max usable raster zoom is 19, but for an offline *region* cache we cap at 16 so a
    /// download can't explode into hundreds of thousands of tiles.
    static let maxZoomCap = 16

    /// Above this many tiles, the UI should warn before downloading (~a big multi-hundred-MB grab).
    static let largeDownloadTileThreshold = 5000

    /// Rough average PNG tile size on disk, used only for the pre-download MB estimate.
    private static let averageTileBytes: Int64 = 18_000

    private let fileManager = FileManager.default
    private let rootURL: URL
    private let manifestURL: URL

    /// Serializes manifest read/modify/write so concurrent deletes/saves don't clobber the file.
    private let manifestQueue = DispatchQueue(label: "com.wander.offline-tiles.manifest")

    private init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // v2 cache dir: the old "wander-offline-tiles" folder can hold OSM "Access blocked" tiles
        // (OSM served the block image with HTTP 200, so it got cached + rendered). Purge it and
        // start fresh under CARTO tiles so those poisoned tiles never render again.
        try? fileManager.removeItem(at: base.appendingPathComponent("wander-offline-tiles", isDirectory: true))
        rootURL = base.appendingPathComponent("wander-map-tiles-v2", isDirectory: true)
        manifestURL = rootURL.appendingPathComponent("manifest.json", isDirectory: false)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    // MARK: Single-tile disk access

    /// On-disk URL for a tile. Layout: {root}/{z}/{x}/{y}.png.
    private func tileURL(z: Int, x: Int, y: Int) -> URL {
        rootURL
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
            .appendingPathComponent("\(y).png", isDirectory: false)
    }

    /// Reads a cached tile, or nil if it isn't on disk. Cheap — used on the tile-render path.
    func tileData(z: Int, x: Int, y: Int) -> Data? {
        let url = tileURL(z: z, x: x, y: y)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes a tile to disk (creating the z/x directories). Used by cache-on-browse and downloads.
    @discardableResult
    func writeTile(_ data: Data, z: Int, x: Int, y: Int) -> Bool {
        let url = tileURL(z: z, x: x, y: y)
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func hasTile(z: Int, x: Int, y: Int) -> Bool {
        fileManager.fileExists(atPath: tileURL(z: z, x: x, y: y).path)
    }

    // MARK: Tile math

    /// Clamps a requested zoom range into the legal [0, maxZoomCap] window, ordered low→high.
    private func clampedZoomRange(minZoom: Int, maxZoom: Int) -> ClosedRange<Int> {
        let lo = max(0, min(minZoom, maxZoom))
        let hi = min(Self.maxZoomCap, max(minZoom, maxZoom))
        return lo...max(lo, hi)
    }

    /// Longitude/latitude → tile x/y at a given zoom (standard slippy-map formula).
    private func tileX(longitude: Double, zoom: Int) -> Int {
        let n = Double(1 << zoom)
        let x = Int(floor((longitude + 180.0) / 360.0 * n))
        return min(max(x, 0), (1 << zoom) - 1)
    }

    private func tileY(latitude: Double, zoom: Int) -> Int {
        let n = Double(1 << zoom)
        let clampedLat = min(max(latitude, -85.05112878), 85.05112878)
        let latRad = clampedLat * .pi / 180.0
        let y = Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
        return min(max(y, 0), (1 << zoom) - 1)
    }

    /// Enumerates every (z, x, y) tile covering `region` across the clamped zoom range.
    private func tiles(in region: MKCoordinateRegion, minZoom: Int, maxZoom: Int) -> [(z: Int, x: Int, y: Int)] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2

        var result: [(Int, Int, Int)] = []
        for z in clampedZoomRange(minZoom: minZoom, maxZoom: maxZoom) {
            let xStart = tileX(longitude: minLng, zoom: z)
            let xEnd = tileX(longitude: maxLng, zoom: z)
            // Note: tile-Y grows southward, so maxLat maps to the smaller y.
            let yStart = tileY(latitude: maxLat, zoom: z)
            let yEnd = tileY(latitude: minLat, zoom: z)
            for x in min(xStart, xEnd)...max(xStart, xEnd) {
                for y in min(yStart, yEnd)...max(yStart, yEnd) {
                    result.append((z, x, y))
                }
            }
        }
        return result
    }

    /// How many tiles a region+zoom-range would produce, and roughly how many bytes.
    func estimate(region: MKCoordinateRegion, minZoom: Int, maxZoom: Int) -> OfflineDownloadEstimate {
        let count = tiles(in: region, minZoom: minZoom, maxZoom: maxZoom).count
        return OfflineDownloadEstimate(
            tileCount: count,
            approximateBytes: Int64(count) * Self.averageTileBytes,
            isLarge: count > Self.largeDownloadTileThreshold
        )
    }

    // MARK: Region download

    /// Downloads every tile covering `region` across the (clamped) zoom range, writing each to
    /// disk and reporting progress as (done, total). Skips tiles already cached (resumable — a
    /// partial region can be re-run to fill gaps). On completion, records/merges a manifest entry.
    ///
    /// - Throws `OfflineTileError.offline` if there's no connection, `.cancelled` on cancellation.
    /// - Returns the persisted `OfflineRegion`.
    @discardableResult
    func downloadRegion(
        name: String,
        region: MKCoordinateRegion,
        minZoom: Int,
        maxZoom: Int,
        progress: @escaping (_ done: Int, _ total: Int) -> Void
    ) async throws -> OfflineRegion {
        let allTiles = tiles(in: region, minZoom: minZoom, maxZoom: maxZoom)
        let total = allTiles.count
        var downloadedBytes: Int64 = 0
        var done = 0

        // A short per-request timeout so a dead network never spins forever.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Detect a total lack of connectivity up front so we show the calm "offline" message
        // instead of grinding through hundreds of timeouts. `isOnline` is main-actor isolated.
        let online = await MainActor.run { NetworkReachability.shared.isOnline }
        if total > 0, !online {
            throw OfflineTileError.offline
        }

        var firstNetworkFailureWasConnectivity = false
        var sawAnySuccess = false

        for tile in allTiles {
            try Task.checkCancellation()

            // Skip anything already on disk (makes the download resumable + cheap to top up).
            if let existing = tileData(z: tile.z, x: tile.x, y: tile.y) {
                downloadedBytes += Int64(existing.count)
                done += 1
                progress(done, total)
                continue
            }

            if let data = await fetchTile(z: tile.z, x: tile.x, y: tile.y, session: session) {
                writeTile(data, z: tile.z, x: tile.x, y: tile.y)
                downloadedBytes += Int64(data.count)
                sawAnySuccess = true
            } else if !sawAnySuccess {
                // Never got a single tile — treat as an offline/unreachable situation.
                firstNetworkFailureWasConnectivity = true
            }

            done += 1
            progress(done, total)
        }

        if total > 0, !sawAnySuccess, firstNetworkFailureWasConnectivity {
            throw OfflineTileError.offline
        }

        let clamped = clampedZoomRange(minZoom: minZoom, maxZoom: maxZoom)
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLng = region.center.longitude - region.span.longitudeDelta / 2
        let maxLng = region.center.longitude + region.span.longitudeDelta / 2

        let saved = OfflineRegion(
            name: name,
            minLatitude: minLat,
            maxLatitude: maxLat,
            minLongitude: minLng,
            maxLongitude: maxLng,
            minZoom: clamped.lowerBound,
            maxZoom: clamped.upperBound,
            tileCount: total,
            bytes: downloadedBytes,
            createdAt: Date()
        )
        appendRegion(saved)
        return saved
    }

    /// Fetches one tile PNG from OSM with the required User-Agent. Returns nil on any failure
    /// (network down, non-200, empty) so the download loop can keep going rather than abort.
    private func fetchTile(z: Int, x: Int, y: Int, session: URLSession) async -> Data? {
        guard let url = URL(string: "https://a.basemaps.cartocdn.com/rastertiles/voyager/\(z)/\(x)/\(y).png") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    // MARK: Manifest

    func loadRegions() -> [OfflineRegion] {
        manifestQueue.sync {
            guard let data = try? Data(contentsOf: manifestURL),
                  let regions = try? JSONDecoder().decode([OfflineRegion].self, from: data) else {
                return []
            }
            return regions.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func appendRegion(_ region: OfflineRegion) {
        manifestQueue.sync {
            var current = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode([OfflineRegion].self, from: $0) } ?? []
            current.append(region)
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: manifestURL, options: .atomic)
            }
        }
    }

    /// Deletes a region's manifest entry and any tiles it uniquely owns (tiles still covered by
    /// another saved region are kept so a shared area doesn't go blank).
    func deleteRegion(_ region: OfflineRegion) {
        manifestQueue.sync {
            var current = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode([OfflineRegion].self, from: $0) } ?? []
            current.removeAll { $0.id == region.id }
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: manifestURL, options: .atomic)
            }

            // Compute tiles owned by the deleted region minus those still covered by survivors.
            let doomed = Set(tiles(in: region.region, minZoom: region.minZoom, maxZoom: region.maxZoom).map(tileKey))
            var stillNeeded = Set<String>()
            for survivor in current {
                for tile in tiles(in: survivor.region, minZoom: survivor.minZoom, maxZoom: survivor.maxZoom) {
                    stillNeeded.insert(tileKey(tile))
                }
            }
            for key in doomed.subtracting(stillNeeded) {
                let parts = key.split(separator: "/")
                guard parts.count == 3,
                      let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else { continue }
                try? fileManager.removeItem(at: tileURL(z: z, x: x, y: y))
            }
        }
    }

    private func tileKey(_ tile: (z: Int, x: Int, y: Int)) -> String {
        "\(tile.z)/\(tile.x)/\(tile.y)"
    }

    /// Wipes every cached tile and the manifest. Recreates an empty root so the store stays usable.
    func deleteAll() {
        manifestQueue.sync {
            try? fileManager.removeItem(at: rootURL)
            try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    // MARK: Cache size

    /// Total bytes on disk across all cached tiles (walks the tree; call off the main thread).
    func totalCacheBytes() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
