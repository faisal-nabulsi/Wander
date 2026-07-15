//
//  OfflineMapConfig.swift
//  Wander
//
//  Configuration constants for the MapLibre-backed Offline Maps surface.
//
//  The offline map renders a Protomaps vector basemap (basemap v4) whose tiles live in a
//  single PMTiles archive, read through MapLibre's `pmtiles://` protocol. The archive is
//  fetched over HTTP range requests from `pmTilesURL`.
//
//  NOTE: `pmTilesURL` currently points at the public Protomaps demo bucket. This is fine for
//  development and on-device render verification, but it is a shared demo resource — swap it
//  for our own Cloudflare R2 URL before shipping.
//

import Foundation

enum OfflineMapConfig {
    /// The PMTiles archive backing the vector basemap.
    ///
    /// TODO: swap to our R2 URL (e.g. https://<account>.r2.cloudflarestorage.com/wander/basemap.pmtiles)
    /// once the archive is uploaded. Keep this as an https:// URL — the MapLibre style rewrites it
    /// to a `pmtiles://` source URL so MapLibre's registered protocol handler serves range reads.
    static let pmTilesURL = "https://demo-bucket.protomaps.com/v4.pmtiles"

    /// Where the offline map starts before the user pans anywhere (San Francisco).
    static let defaultCenterLatitude = 37.7749
    static let defaultCenterLongitude = -122.4194

    /// Zoom range used for "Download this region" offline packs. The basemap is vector, so a
    /// modest max zoom already yields readable streets while keeping pack sizes reasonable.
    static let offlinePackMinZoom: Double = 0
    static let offlinePackMaxZoom: Double = 14
}
