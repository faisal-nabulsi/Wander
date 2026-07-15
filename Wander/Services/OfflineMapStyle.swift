//
//  OfflineMapStyle.swift
//  Wander
//
//  Prepares the MapLibre style URL for the Offline Maps surface.
//
//  We ship `protomaps-basemap-v4.json` in the bundle. Its vector source `url` is a
//  `pmtiles://…` string pointing at the Protomaps demo bucket. At runtime we rewrite that
//  URL to `pmtiles://<OfflineMapConfig.pmTilesURL>` (so the archive location is a single
//  config constant, swappable to R2 without touching the JSON), write the patched style to a
//  cache file, and hand MapLibre a file:// URL to it.
//
//  PMTiles is served through MapLibre Native iOS's built-in `pmtiles://` protocol (native
//  since MapLibre iOS 6.10) — no manual protocol-handler registration is required.
//

import Foundation
import MapKit
import MapLibre

enum OfflineMapStyle {
    /// The bundled style JSON name (without extension).
    private static let bundledStyleName = "protomaps-basemap-v4"

    /// Where we drop the patched style so MapLibre can read it as a file:// URL.
    private static var patchedStyleURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("wander-offline-style.json", isDirectory: false)
    }

    /// The `pmtiles://` source URL MapLibre should read, built from the config constant.
    static var pmTilesSourceURL: String {
        "pmtiles://\(OfflineMapConfig.pmTilesURL)"
    }

    /// Returns a file:// URL to a style whose PMTiles source points at `OfflineMapConfig.pmTilesURL`.
    ///
    /// Loads the bundled JSON, replaces the vector source `url` with `pmTilesSourceURL`, and
    /// writes the result to the cache. Falls back to the raw bundled URL if anything goes wrong
    /// (the bundled JSON is itself a valid, loadable style pointing at the demo bucket).
    static func localStyleURL() -> URL {
        guard let bundledURL = Bundle.main.url(forResource: bundledStyleName, withExtension: "json") else {
            // No bundled style — hand MapLibre a data-less fallback so it still constructs.
            return patchedStyleURL
        }

        guard
            let data = try? Data(contentsOf: bundledURL),
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            var sources = json["sources"] as? [String: Any],
            var protomaps = sources["protomaps"] as? [String: Any]
        else {
            return bundledURL
        }

        protomaps["url"] = pmTilesSourceURL
        sources["protomaps"] = protomaps
        json["sources"] = sources

        guard
            let patched = try? JSONSerialization.data(withJSONObject: json, options: []),
            (try? patched.write(to: patchedStyleURL, options: .atomic)) != nil
        else {
            return bundledURL
        }

        return patchedStyleURL
    }

    // MARK: - Zoom helpers

    /// Convert an `MKCoordinateRegion` longitude span into an approximate MapLibre zoom level.
    /// Mirrors the slippy-map relation z ≈ log2(360 / longitudeSpan).
    static func zoomLevel(for region: MKCoordinateRegion) -> Double {
        let span = max(region.span.longitudeDelta, 0.0001)
        let zoom = log2(360.0 / span)
        return min(max(zoom, 1.0), 20.0)
    }
}
