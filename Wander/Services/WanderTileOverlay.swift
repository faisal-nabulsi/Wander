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
//    3. Miss + offline  → SUBSTITUTE from a neighbouring zoom level (see below), and only
//                         return a blank tile when there is genuinely nothing to draw.
//
//  A `cacheOnly` toggle forces step 3 even when a network exists, so the user can preview
//  exactly what's available offline.
//
//  WHY THE SUBSTITUTION EXISTS. `canReplaceMapContent` hides Apple's base map, so a transparent
//  tile is not "a gap in our map" — it is a hole straight through to MapKit's empty canvas, which
//  draws as a cream field with faint grid lines and nothing else. A user who zooms one step past
//  what they downloaded therefore got a screen with no map on it and no explanation. A saved
//  region only covers minZoom…maxZoom, so that band is one pinch away at all times.
//
//  Half of that was NOT a cache problem at all: past `maximumZ`, MapKit stops requesting tiles
//  rather than scaling the deepest ones up, so the overlay never even heard about the empty
//  screen. See the `maximumZ` assignment in init — it is quoted deliberately above the store's
//  download cap so the requests keep arriving and the substitution can answer them.
//
//  So a miss now walks OUTWARDS through the pyramid before giving up:
//    * ANCESTORS (zoomed in past what's saved): take the nearest cached tile from a lower zoom,
//      crop this tile's quadrant out of it and scale it up. Blurry, but it is the right ground.
//    * CHILDREN (zoomed out past what's saved): compose this tile out of the cached tiles one or
//      two levels deeper. Sharp, and it is exactly the case the owner hit by pinching out.
//  Whatever the tiles end up being, the overlay REPORTS what it managed to draw through
//  `onCoverageChange`, so the screen can say "this is a lower-detail stand-in" or "there is
//  nothing saved here" instead of leaving an empty grid the user cannot interpret.
//

import Foundation
import MapKit
import UIKit

final class WanderTileOverlay: MKTileOverlay {

    /// How much of what the map is currently asking for we can actually draw.
    ///
    /// Reported (not inferred by the host) because only the overlay knows whether a tile came from
    /// its own zoom level, from a scaled stand-in, or from nowhere at all.
    enum Coverage: Equatable {
        /// Every tile came from its own zoom level — cache or network. Nothing to say.
        case exact
        /// A meaningful share of the screen is a stand-in scaled from a neighbouring zoom level.
        case approximate
        /// There is essentially nothing to draw here: the map is an empty grid.
        case none
    }

    /// When true, never hit the network — serve only what's already cached (offline preview).
    var cacheOnly: Bool = false

    /// Called on the MAIN queue whenever the coverage verdict changes. Set by the map coordinator;
    /// the host uses it to explain an empty or blurry map in words.
    var onCoverageChange: ((Coverage) -> Void)?

    private let store: OfflineTileStore
    private let session: URLSession

    /// How many zoom levels to climb looking for a cached ancestor.
    ///
    /// THREE, measured rather than picked: at four levels one 256 px tile is drawn from a 16×16 px
    /// crop, and on screen that is a flat cream wash — pixel-indistinguishable from the empty grid
    /// this whole mechanism exists to avoid, except that it ALSO counts as "covered" and suppresses
    /// the honest "nothing saved here" notice. Three levels is a 32×32 crop: blurry, clearly a map,
    /// still the right place. Past that, saying so beats faking it.
    private static let maxAncestorSteps = 3

    /// How many levels to descend looking for cached children. Two levels is at most 16 tile reads
    /// per drawn tile, which is affordable on the (background) tile queue.
    private static let maxChildSteps = 2

    /// A composed-from-children tile is only worth it if a reasonable share of the children exist;
    /// below this it's a few islands floating in an empty square, which reads worse than blank.
    private static let minChildFraction = 0.25

    /// Substitution does file reads and image work, so it stays off whatever queue MapKit used to
    /// ask for the tile. Concurrent: every task here only reads.
    private static let fallbackQueue = DispatchQueue(
        label: "com.wander.offline-tiles.fallback",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// A 1×1 transparent PNG returned when there is nothing at all to draw, so MapKit gets
    /// *something* instead of logging load failures for every empty tile.
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
        // DELIBERATELY ABOVE the store's download cap, and this is the fix for the reported
        // "can't load at a certain zoom".
        //
        // MEASURED with a trace on loadTile: past `maximumZ`, MapKit does NOT scale the deepest
        // tiles up — it stops asking the overlay for anything at all and draws its own empty
        // canvas. With this set to the 16-level download cap, zooming one step further than a
        // saved map produced a screen with no map on it and not one line of tile traffic, so
        // nothing inside `loadTile` could ever have rescued it. Quoting the cap higher keeps the
        // requests coming, and the ancestor substitution below turns them into scaled-up tiles.
        // `maxAncestorSteps` past the cap is exactly as far as substitution can still look like a
        // map; beyond that MapKit going quiet is the correct outcome.
        maximumZ = OfflineTileStore.maxZoomCap + Self.maxAncestorSteps
        minimumZ = 0
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let z = path.z
        let x = path.x
        let y = path.y

        // 1. Disk first — the offline path.
        if let cached = store.tileData(z: z, x: x, y: y) {
            record(.exact)
            result(cached, nil)
            return
        }

        // 2. Offline (or forced cache-only): substitute from a neighbouring zoom level.
        //    Use the nonisolated snapshot — loadTile runs off the main actor. `hasInternet` (not the
        //    raw path flag) so a doomed fetch isn't attempted on Airplane Mode + LocalDevVPN.
        if cacheOnly || !NetworkReachability.hasInternetSnapshot {
            serveSubstitute(z: z, x: x, y: y, result: result)
            return
        }

        // 3. Online miss: fetch a tile, return it, and cache-on-browse. Source = CARTO's public
        //    "Voyager" basemap CDN (OSM data under ODbL), NOT OSM's volunteer servers, which block
        //    apps that bulk-download and serve "Access blocked" tiles. Attribution: © OSM © CARTO.
        guard let url = URL(string: "https://a.basemaps.cartocdn.com/rastertiles/voyager/\(z)/\(x)/\(y).png") else {
            serveSubstitute(z: z, x: x, y: y, result: result)
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
                self.record(.exact)
                result(data, nil)
            } else {
                // Don't propagate the error (avoids console spam). A CDN hiccup on one tile is
                // exactly the case where a cached neighbour is better than a hole.
                self.serveSubstitute(z: z, x: x, y: y, result: result)
            }
        }.resume()
    }

    // MARK: - Substitution

    /// Nothing at this zoom: try an upscaled ancestor, then a mosaic of children, then give up
    /// and report a blank so the host can say so on screen.
    private func serveSubstitute(z: Int, x: Int, y: Int, result: @escaping (Data?, Error?) -> Void) {
        Self.fallbackQueue.async { [weak self] in
            guard let self else {
                result(Self.blankTile, nil)
                return
            }
            if let substitute = self.upscaledAncestor(z: z, x: x, y: y)
                ?? self.mosaicFromChildren(z: z, x: x, y: y) {
                self.record(.approximate)
                result(substitute, nil)
            } else {
                self.record(.blank)
                result(Self.blankTile, nil)
            }
        }
    }

    /// The nearest cached tile from a LOWER zoom level, cropped to this tile's quadrant and scaled
    /// up to tile size. This is the "zoomed in past what I downloaded" case.
    private func upscaledAncestor(z: Int, x: Int, y: Int) -> Data? {
        guard z > 0 else { return nil }
        for step in 1...min(Self.maxAncestorSteps, z) {
            let ancestorZ = z - step
            let ancestorX = x >> step
            let ancestorY = y >> step
            guard let data = store.tileData(z: ancestorZ, x: ancestorX, y: ancestorY),
                  let image = UIImage(data: data),
                  let source = image.cgImage else { continue }

            let divisions = 1 << step
            // Tile y grows southward and CGImage row 0 is the north edge, so the quadrant indices
            // map straight onto the image with no flip.
            let subX = x - (ancestorX << step)
            let subY = y - (ancestorY << step)
            let pieceWidth = CGFloat(source.width) / CGFloat(divisions)
            let pieceHeight = CGFloat(source.height) / CGFloat(divisions)
            guard pieceWidth >= 1, pieceHeight >= 1 else { continue }

            let crop = CGRect(
                x: CGFloat(subX) * pieceWidth,
                y: CGFloat(subY) * pieceHeight,
                width: pieceWidth,
                height: pieceHeight
            ).integral
            guard let piece = source.cropping(to: crop) else { continue }

            return render(size: tileSize, opaque: true) { _ in
                UIImage(cgImage: piece).draw(in: CGRect(origin: .zero, size: self.tileSize))
            }
        }
        return nil
    }

    /// Compose this tile out of cached tiles from a HIGHER zoom level. This is the "pinched out
    /// past what I downloaded" case — the one that produced a completely empty screen, because an
    /// ancestor search can't help when the saved region starts BELOW the requested zoom.
    private func mosaicFromChildren(z: Int, x: Int, y: Int) -> Data? {
        for step in 1...Self.maxChildSteps {
            let childZ = z + step
            // Bounded by what a download can ever have WRITTEN, not by `maximumZ` — the latter is
            // quoted high so MapKit keeps asking, and no tile is ever stored above the store's cap.
            guard childZ <= OfflineTileStore.maxZoomCap else { break }
            let divisions = 1 << step
            let baseX = x << step
            let baseY = y << step

            var pieces: [(column: Int, row: Int, image: UIImage)] = []
            for column in 0..<divisions {
                for row in 0..<divisions {
                    guard let data = store.tileData(z: childZ, x: baseX + column, y: baseY + row),
                          let image = UIImage(data: data) else { continue }
                    pieces.append((column, row, image))
                }
            }
            let slots = divisions * divisions
            guard Double(pieces.count) >= Double(slots) * Self.minChildFraction else { continue }

            let cellWidth = tileSize.width / CGFloat(divisions)
            let cellHeight = tileSize.height / CGFloat(divisions)
            return render(size: tileSize, opaque: false) { _ in
                for piece in pieces {
                    piece.image.draw(in: CGRect(
                        x: CGFloat(piece.column) * cellWidth,
                        y: CGFloat(piece.row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    ))
                }
            }
        }
        return nil
    }

    /// One place that knows how a substitute tile is rasterised. `scale = 1` because tile sizes are
    /// already in tile PIXELS, not points — letting it default to the screen scale would hand
    /// MapKit a 512px image for a 256px tile.
    private func render(size: CGSize, opaque: Bool, _ body: @escaping (CGContext) -> Void) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            context.cgContext.interpolationQuality = .medium
            body(context.cgContext)
        }
    }

    // MARK: - Coverage reporting

    private enum Outcome {
        case exact
        case approximate
        case blank
    }

    /// How many recent tiles the verdict is computed over. A phone screen holds roughly 12–20
    /// tiles, so this window is "what is on screen now" without needing to know about the camera.
    private static let coverageWindow = 24

    private let outcomeLock = NSLock()
    private var recentOutcomes: [Outcome] = []
    private var reportedCoverage: Coverage?

    /// Throw away the window because the camera moved.
    ///
    /// MEASURED, not assumed: without this, pinching out from a saved area into empty space left
    /// the previous zoom's ~20 successful tiles in the window, so six new blanks scored 6/24 = 25%
    /// and the verdict stayed `.exact`. The screen was completely empty and the overlay was
    /// reporting that everything was fine. A verdict is only meaningful over one camera position,
    /// so the window is per-camera.
    func resetCoverageWindow() {
        outcomeLock.lock()
        recentOutcomes.removeAll(keepingCapacity: true)
        // nil, not `.exact`: the next verdict must always be delivered, even if it repeats the
        // last one, because the host's banner is about THIS view.
        reportedCoverage = nil
        outcomeLock.unlock()
    }

    private func record(_ outcome: Outcome) {
        outcomeLock.lock()
        recentOutcomes.append(outcome)
        if recentOutcomes.count > Self.coverageWindow {
            recentOutcomes.removeFirst(recentOutcomes.count - Self.coverageWindow)
        }
        let verdict = Self.verdict(for: recentOutcomes)
        let changed = verdict != reportedCoverage
        if changed { reportedCoverage = verdict }
        outcomeLock.unlock()

        guard changed, let callback = onCoverageChange else { return }
        DispatchQueue.main.async { callback(verdict) }
    }

    private static func verdict(for outcomes: [Outcome]) -> Coverage {
        guard !outcomes.isEmpty else { return .exact }
        let total = Double(outcomes.count)
        let blank = Double(outcomes.filter { $0 == .blank }.count) / total
        let approximate = Double(outcomes.filter { $0 == .approximate }.count) / total
        // Mostly holes: the screen is the empty grid, and saying so is the only useful move.
        if blank > 0.75 { return .none }
        // A quarter of the view standing in for itself is enough to be worth a word — below that
        // it's an edge tile mid-pan and a banner would be noise.
        if blank + approximate > 0.25 { return .approximate }
        return .exact
    }
}
