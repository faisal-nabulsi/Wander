//
//  WanderTileOverlay.swift
//  Wander
//
//  An MKTileOverlay that renders OSM raster tiles, backed by the on-disk OfflineTileStore.
//  With `canReplaceMapContent = true`, it fully hides Apple's base map and draws OSM instead —
//  the same result the Android build gets from osmdroid.
//
//  loadTile(at:result:) is the whole story:
//    1. Disk cache hit  → return the cached tile (works with no internet).
//    2. Miss + online   → fetch from OSM, return it, AND write it to the cache
//                         (cache-on-browse: browsing online quietly fills the offline cache).
//    3. Miss + offline  → return a blank transparent tile (no error spam, no gap noise).
//
//  A `cacheOnly` toggle forces step 3 even when a network exists, so the user can preview
//  exactly what's available offline.
//

import Foundation
import MapKit

final class WanderTileOverlay: MKTileOverlay {
    /// When true, never hit the network — serve only what's already cached (offline preview).
    var cacheOnly: Bool = false

    private let store: OfflineTileStore
    private let session: URLSession

    /// A 1×1 transparent PNG returned for misses while offline, so MapKit gets *something*
    /// instead of logging load failures for every empty tile.
    private static let blankTile: Data = {
        // 1×1 fully transparent PNG.
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        return Data(base64Encoded: base64) ?? Data()
    }()

    init(store: OfflineTileStore = .shared) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)

        // A URL template is required by the initializer; loadTile overrides fetching entirely.
        super.init(urlTemplate: "https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png")
        canReplaceMapContent = true
        maximumZ = OfflineTileStore.maxZoomCap
        minimumZ = 0
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let z = path.z
        let x = path.x
        let y = path.y

        // 1. Disk first — the offline path.
        if let cached = store.tileData(z: z, x: x, y: y) {
            result(cached, nil)
            return
        }

        // 2. Offline (or forced cache-only): hand back a blank tile, quietly.
        //    Use the nonisolated snapshot — loadTile runs off the main actor. `hasInternet` (not the
        //    raw path flag) so a doomed fetch isn't attempted on Airplane Mode + LocalDevVPN.
        if cacheOnly || !NetworkReachability.hasInternetSnapshot {
            result(Self.blankTile, nil)
            return
        }

        // 3. Online miss: fetch a tile, return it, and cache-on-browse. Source = CARTO's public
        //    "Voyager" basemap CDN (OSM data under ODbL), NOT OSM's volunteer servers, which block
        //    apps that bulk-download and serve "Access blocked" tiles. Attribution: © OSM © CARTO.
        guard let url = URL(string: "https://a.basemaps.cartocdn.com/rastertiles/voyager/\(z)/\(x)/\(y).png") else {
            result(Self.blankTile, nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(OfflineTileStore.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            if let data,
               !data.isEmpty,
               let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode) {
                self.store.writeTile(data, z: z, x: x, y: y)
                result(data, nil)
            } else {
                // Don't propagate the error (avoids console spam); a blank tile is calmer.
                result(Self.blankTile, nil)
            }
        }.resume()
    }
}
