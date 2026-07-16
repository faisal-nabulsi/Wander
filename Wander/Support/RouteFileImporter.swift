//
//  RouteFileImporter.swift
//  Wander
//
//  Parses a route/coordinate file (GPX, KML, GeoJSON/JSON, or CSV/plain lat,lng list) into an
//  ordered list of coordinates the Route builder can load as waypoints. Mirrors the Android and
//  desktop importers (which already ship this) so iOS reaches parity — see the site's Route docs.
//
//  Dependency-light: GPX/KML are read with lightweight regex extraction (like the desktop's
//  tryXml), GeoJSON via JSONSerialization, CSV/TXT via line parsing with a header sniff for
//  lat,lng vs lng,lat order. Elevation is ignored. Robust to junk lines (skips, never throws).
//

import Foundation
import CoreLocation
import UniformTypeIdentifiers

enum RouteFileImporter {

    /// The document types the Route importer accepts.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .json, .xml, .text]
        for ext in ["gpx", "kml", "geojson"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    enum ImportError: LocalizedError {
        case empty, tooLarge, noCoordinates
        var errorDescription: String? {
            switch self {
            case .empty:         return "That file was empty."
            case .tooLarge:      return "That file is too large (max 4 MB)."
            case .noCoordinates: return "No coordinates found — is it a GPX, KML, GeoJSON or lat,lng list?"
            }
        }
    }

    private static let maxBytes = 4 * 1024 * 1024
    private static let maxPoints = 2000

    /// Parse `data` (named `filename`, used only to bias format detection) into coordinates.
    static func parse(data: Data, filename: String) throws -> [CLLocationCoordinate2D] {
        guard !data.isEmpty else { throw ImportError.empty }
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.noCoordinates
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        // Try in the most-likely order for the extension, then fall back to the others.
        let order: [(String) -> [CLLocationCoordinate2D]]
        switch ext {
        case "geojson", "json": order = [parseGeoJSON, parseXML, parsePlain]
        case "gpx", "kml", "xml": order = [parseXML, parseGeoJSON, parsePlain]
        default: order = [parsePlain, parseGeoJSON, parseXML]
        }

        var coords: [CLLocationCoordinate2D] = []
        for parser in order {
            coords = parser(text)
            if !coords.isEmpty { break }
        }

        let cleaned = dedupeConsecutive(coords.filter(isValid))
        guard !cleaned.isEmpty else { throw ImportError.noCoordinates }
        return Array(cleaned.prefix(maxPoints))
    }

    // MARK: - Validation

    private static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude >= -90 && c.latitude <= 90 && c.longitude >= -180 && c.longitude <= 180 &&
        !(c.latitude == 0 && c.longitude == 0)
    }

    private static func dedupeConsecutive(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var out: [CLLocationCoordinate2D] = []
        for c in coords {
            if let last = out.last, abs(last.latitude - c.latitude) < 1e-9, abs(last.longitude - c.longitude) < 1e-9 {
                continue
            }
            out.append(c)
        }
        return out
    }

    // MARK: - GPX / KML (regex over the XML)

    private static func parseXML(_ text: String) -> [CLLocationCoordinate2D] {
        // GPX: <trkpt lat=".." lon="..">, <rtept ...>, <wpt ...> — lat/lon are attributes.
        var pts = matchLatLonAttributes(in: text)
        if !pts.isEmpty { return pts }

        // KML: <coordinates>lon,lat,alt lon,lat,alt ...</coordinates> and <gx:coord>lon lat alt</gx:coord>.
        for block in captures(of: "<coordinates[^>]*>([\\s\\S]*?)</coordinates>", in: text) {
            for tuple in block.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
                let parts = tuple.split(separator: ",")
                if parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) {
                    pts.append(.init(latitude: lat, longitude: lon))
                }
            }
        }
        for coord in captures(of: "<gx:coord[^>]*>([\\s\\S]*?)</gx:coord>", in: text) {
            let nums = coord.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
            if nums.count >= 2 { pts.append(.init(latitude: nums[1], longitude: nums[0])) } // lon lat
        }
        return pts
    }

    /// Extracts every `lat="..."` + `lon="..."` pair from GPX-style elements, order-independent.
    private static func matchLatLonAttributes(in text: String) -> [CLLocationCoordinate2D] {
        // Match a point element and pull lat/lon regardless of attribute order.
        let elementPattern = "<(?:trkpt|rtept|wpt)\\b[^>]*>"
        var out: [CLLocationCoordinate2D] = []
        for tag in captures(of: "(" + elementPattern + ")", in: text, group: 1) {
            guard let lat = firstDouble(of: "lat\\s*=\\s*\"([\\-0-9.]+)\"", in: tag),
                  let lon = firstDouble(of: "lon\\s*=\\s*\"([\\-0-9.]+)\"", in: tag) else { continue }
            out.append(.init(latitude: lat, longitude: lon))
        }
        return out
    }

    // MARK: - GeoJSON

    private static func parseGeoJSON(_ text: String) -> [CLLocationCoordinate2D] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [CLLocationCoordinate2D] = []
        walkGeoJSON(obj, into: &out)
        return out
    }

    /// Recursively pull [lng, lat] pairs out of any GeoJSON structure.
    private static func walkGeoJSON(_ node: Any, into out: inout [CLLocationCoordinate2D]) {
        if let dict = node as? [String: Any] {
            if let coords = dict["coordinates"] { walkCoordinates(coords, into: &out) }
            if let geom = dict["geometry"] { walkGeoJSON(geom, into: &out) }
            if let geoms = dict["geometries"] as? [Any] { geoms.forEach { walkGeoJSON($0, into: &out) } }
            if let feats = dict["features"] as? [Any] { feats.forEach { walkGeoJSON($0, into: &out) } }
        }
    }

    /// A GeoJSON `coordinates` value is a nested array; a leaf is [lng, lat, (alt)].
    private static func walkCoordinates(_ node: Any, into out: inout [CLLocationCoordinate2D]) {
        guard let arr = node as? [Any] else { return }
        if let lng = arr.first as? Double, arr.count >= 2, let lat = arr[1] as? Double {
            out.append(.init(latitude: lat, longitude: lng))
            return
        }
        // Numbers can decode as NSNumber; handle that leaf shape too.
        if arr.count >= 2, let lng = (arr[0] as? NSNumber)?.doubleValue, let lat = (arr[1] as? NSNumber)?.doubleValue,
           !(arr[0] is [Any]) {
            out.append(.init(latitude: lat, longitude: lng))
            return
        }
        arr.forEach { walkCoordinates($0, into: &out) }
    }

    // MARK: - CSV / plain text

    private static func parsePlain(_ text: String) -> [CLLocationCoordinate2D] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return [] }

        // Header sniff: if the first non-comment line contains "lon"/"lng" before "lat", the
        // columns are lng,lat; otherwise assume lat,lng. Range-check as a fallback.
        var lngFirst = false
        if let header = lines.first(where: { !$0.hasPrefix("#") && !$0.hasPrefix("//") })?.lowercased(),
           header.contains("lat") || header.contains("lon") || header.contains("lng") {
            let latIdx = header.range(of: "lat").map { header.distance(from: header.startIndex, to: $0.lowerBound) } ?? Int.max
            let lonIdx = (header.range(of: "lng") ?? header.range(of: "lon")).map { header.distance(from: header.startIndex, to: $0.lowerBound) } ?? Int.max
            lngFirst = lonIdx < latIdx
        }

        var out: [CLLocationCoordinate2D] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            let nums = line
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" || $0 == " " })
                .compactMap { Double($0) }
            guard nums.count >= 2 else { continue }
            var lat = lngFirst ? nums[1] : nums[0]
            var lon = lngFirst ? nums[0] : nums[1]
            // Fallback: if lat is out of range but lon isn't, they're clearly swapped.
            if abs(lat) > 90 && abs(lon) <= 90 { swap(&lat, &lon) }
            out.append(.init(latitude: lat, longitude: lon))
        }
        return out
    }

    // MARK: - Regex helpers

    private static func captures(of pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: group))
        }
    }

    private static func firstDouble(of pattern: String, in text: String) -> Double? {
        captures(of: pattern, in: text).first.flatMap(Double.init)
    }
}
