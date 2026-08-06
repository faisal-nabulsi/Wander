//
//  MapSelectionView.swift
//  Wander
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import UIKit
import UniformTypeIdentifiers

private struct CoordinateSnapshot: Equatable, Identifiable {
    let latitude: Double
    let longitude: Double

    // Stable id so this can drive a `.sheet(item:)` (used by the Street View presenter).
    var id: String { "\(latitude),\(longitude)" }

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

extension Notification.Name {
    /// Ask the Teleport screen to open its coordinate/GPX file importer. Posted by Places, which
    /// owns the entry point; the parsing and the pin/route it produces belong to this screen, so
    /// the importer itself stays here rather than being rebuilt on the other side.
    static let importCoordinatesRequested = Notification.Name("wander.importCoordinatesRequested")

    /// Ask the Teleport screen to write a GPX of what it currently holds — the live route if there
    /// is one, otherwise the pin plus your saved and recent places. Also posted by Places, for the
    /// same reason: only this screen knows what "currently" means.
    static let exportGPXRequested = Notification.Name("wander.exportGPXRequested")
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
    static let importedRouteFallbackSpeedMetersPerSecond: CLLocationSpeed = 13.4
}

/// Tuning for "Smooth long jumps" (anti impossible-jump). A teleport farther than
/// `jumpThresholdMeters` from the current spoofed position is played back as a
/// fast, continuous glide instead of an instant hop, so apps that flag an
/// instantaneous impossible jump (dating apps, Life360) see a fast-but-continuous
/// move. The glide targets `targetGlideSeconds` but is capped at
/// `maxGlideSeconds` so very long jumps still complete promptly.
private enum JumpSmoothingDefaults {
    static let jumpThresholdMeters: CLLocationDistance = 2_000
    static let targetGlideSeconds: TimeInterval = 4.5
    static let maxGlideSeconds: TimeInterval = 6.0
    static let tickInterval: TimeInterval = 0.4
}

/// Build a short, high-speed glide track from `start` to `end` along the
/// great-circle line, timed to finish in roughly `JumpSmoothingDefaults`'
/// target duration (capped at the max). Reuses the same `RoutePlaybackSample`
/// machinery the route player already drives, so playback is cancelable by
/// Stop/panic and honors `.stopSimulationRequested` for free.
func buildJumpGlideSamples(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> [RoutePlaybackSample] {
    let coordinates = sampledRouteCoordinates(
        from: [start, end],
        targetDistance: RouteSimulationDefaults.pathSamplingDistance
    )
    guard coordinates.count > 1 else { return [] }

    // Aim for the target glide time, but never exceed the cap: a longer jump
    // just means a higher glide speed so it still lands within a few seconds.
    let duration = min(
        JumpSmoothingDefaults.targetGlideSeconds,
        JumpSmoothingDefaults.maxGlideSeconds
    )
    let stepCount = max(1, coordinates.count - 1)
    let stepDelay = duration / Double(stepCount)

    var samples = [RoutePlaybackSample(coordinate: coordinates[0], delayFromPrevious: 0)]
    for coordinate in coordinates.dropFirst() {
        if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
            samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
        }
    }
    return samples
}

struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
}

struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceAlong(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    zip(coordinates, coordinates.dropFirst()).reduce(0) { total, pair in
        total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
    }
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    let (data, response) = try await URLSession.shared.data(from: url)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass returned HTTP \(httpResponse.statusCode)."]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D],
    speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let firstCoordinate = displayCoordinates.first else { return [] }

    var samples = [RoutePlaybackSample(coordinate: firstCoordinate, delayFromPrevious: 0)]

    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speedLimit = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays) ?? fallbackSpeedMetersPerSecond
        let clampedSpeed = max(speedLimit, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        let segmentTravelTime = segmentDistance / clampedSpeed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / RouteSimulationDefaults.playbackTickInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
            }
        }
    }

    return samples
}

func prefetchRoutePlaybackSamples(
    displayCoordinates: [CLLocationCoordinate2D],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) async -> [RoutePlaybackSample] {
    let speedWays = (try? await fetchOpenStreetMapWays(for: displayCoordinates)) ?? []
    return buildPlaybackSamples(
        from: displayCoordinates,
        speedWays: speedWays,
        fallbackSpeedMetersPerSecond: fallbackSpeedMetersPerSecond
    )
}

private enum CoordinateImportError: LocalizedError {
    case emptyFile
    case noCoordinates

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .noCoordinates:
            return "No valid coordinates were found. Use GPX, GeoJSON, JSON, CSV, or plain text with latitude and longitude values."
        }
    }
}

private enum CoordinateImportParser {
    static let supportedContentTypes: [UTType] = [
        .plainText,
        .commaSeparatedText,
        .json,
        .xml,
        UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "kml", conformingTo: .xml) ?? .xml,
        UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json
    ]

    private enum CoordinateOrder {
        case latitudeLongitude
        case longitudeLatitude
    }

    static func parse(url: URL) throws -> [CLLocationCoordinate2D] {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CoordinateImportError.emptyFile }

        let fileExtension = url.pathExtension.lowercased()
        if fileExtension == "json" || fileExtension == "geojson" {
            if let coordinates = try? parseJSONCoordinates(from: data),
               !coordinates.isEmpty {
                return coordinates
            }
        }

        if fileExtension == "gpx" || fileExtension == "kml" || fileExtension == "xml" {
            let coordinates = parseXMLCoordinates(from: data)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let text = decodedText(from: data) {
            let coordinates = parseInline(text)
            if !coordinates.isEmpty {
                return coordinates
            }
        }

        if let coordinates = try? parseJSONCoordinates(from: data),
           !coordinates.isEmpty {
            return coordinates
        }

        let coordinates = parseXMLCoordinates(from: data)
        if !coordinates.isEmpty {
            return coordinates
        }

        throw CoordinateImportError.noCoordinates
    }

    static func parseInline(_ text: String) -> [CLLocationCoordinate2D] {
        // A pasted full Plus Code (e.g. "8FVC9G8F+6X") resolves standalone.
        // Short codes need a reference and are handled by the search bar, so
        // they fall through here unchanged.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("+"),
           PlusCode.isFullCode(trimmed.uppercased()),
           let coordinate = PlusCode.coordinate(from: trimmed, reference: nil) {
            return [coordinate]
        }
        return sanitized(parseTextCoordinates(from: text))
    }

    private static func decodedText(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .ascii)
    }

    private static func sanitized(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            if result.last.map(CoordinateSnapshot.init) == CoordinateSnapshot(coordinate) {
                continue
            }
            result.append(coordinate)
        }
        return result
    }

    private static func coordinate(
        first: Double,
        second: Double,
        order: CoordinateOrder
    ) -> CLLocationCoordinate2D? {
        let preferred: CLLocationCoordinate2D
        let fallback: CLLocationCoordinate2D

        switch order {
        case .latitudeLongitude:
            preferred = CLLocationCoordinate2D(latitude: first, longitude: second)
            fallback = CLLocationCoordinate2D(latitude: second, longitude: first)
        case .longitudeLatitude:
            preferred = CLLocationCoordinate2D(latitude: second, longitude: first)
            fallback = CLLocationCoordinate2D(latitude: first, longitude: second)
        }

        if CLLocationCoordinate2DIsValid(preferred) {
            return preferred
        }
        if CLLocationCoordinate2DIsValid(fallback) {
            return fallback
        }
        return nil
    }

    private static func parseJSONCoordinates(from data: Data) throws -> [CLLocationCoordinate2D] {
        let object = try JSONSerialization.jsonObject(with: data)
        return sanitized(coordinates(fromJSONObject: object, order: .latitudeLongitude))
    }

    private static func coordinates(
        fromJSONObject object: Any,
        order: CoordinateOrder
    ) -> [CLLocationCoordinate2D] {
        if let dictionary = object as? [String: Any] {
            if let latitude = numberValue(forAnyKey: ["latitude", "lat"], in: dictionary),
               let longitude = numberValue(forAnyKey: ["longitude", "lon", "lng"], in: dictionary),
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                return [coordinate]
            }

            if let geometry = dictionary["geometry"] {
                return coordinates(fromJSONObject: geometry, order: order)
            }

            if let type = dictionary["type"] as? String {
                let loweredType = type.lowercased()
                if loweredType == "featurecollection",
                   let features = dictionary["features"] as? [Any] {
                    return features.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if loweredType == "geometrycollection",
                   let geometries = dictionary["geometries"] as? [Any] {
                    return geometries.flatMap { coordinates(fromJSONObject: $0, order: .longitudeLatitude) }
                }
                if let coordinateObject = dictionary["coordinates"] {
                    return coordinates(fromJSONObject: coordinateObject, order: .longitudeLatitude)
                }
            }

            return dictionary.values.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        if let array = object as? [Any] {
            if array.count >= 2,
               let first = numericValue(array[0]),
               let second = numericValue(array[1]),
               let coordinate = coordinate(first: first, second: second, order: order) {
                return [coordinate]
            }

            return array.flatMap { coordinates(fromJSONObject: $0, order: order) }
        }

        return []
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func numberValue(forAnyKey keys: [String], in dictionary: [String: Any]) -> Double? {
        let keyedValues = Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = keyedValues[key],
               let number = numericValue(value) {
                return number
            }
        }
        return nil
    }

    private static func parseXMLCoordinates(from data: Data) -> [CLLocationCoordinate2D] {
        let collector = XMLCoordinateCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return sanitized(collector.coordinates)
    }

    private final class XMLCoordinateCollector: NSObject, XMLParserDelegate {
        var coordinates: [CLLocationCoordinate2D] = []
        private var isCollectingKMLCoordinates = false
        private var kmlCoordinateBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = elementName.lowercased()
            if ["wpt", "trkpt", "rtept"].contains(name),
               let latitude = Double(attributeDict["lat"] ?? ""),
               let longitude = Double(attributeDict["lon"] ?? ""),
               let coordinate = CoordinateImportParser.coordinate(
                    first: latitude,
                    second: longitude,
                    order: .latitudeLongitude
               ) {
                coordinates.append(coordinate)
            } else if name == "coordinates" {
                isCollectingKMLCoordinates = true
                kmlCoordinateBuffer = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isCollectingKMLCoordinates {
                kmlCoordinateBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName.lowercased() == "coordinates" else { return }
            coordinates.append(contentsOf: CoordinateImportParser.parseKMLCoordinateText(kmlCoordinateBuffer))
            isCollectingKMLCoordinates = false
            kmlCoordinateBuffer = ""
        }
    }

    private static func parseKMLCoordinateText(_ text: String) -> [CLLocationCoordinate2D] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> CLLocationCoordinate2D? in
                let values = token
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                guard values.count >= 2 else { return nil }
                return coordinate(first: values[0], second: values[1], order: .longitudeLatitude)
            }
    }

    private static func parseTextCoordinates(from text: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var headerIndices: (latitude: Int, longitude: Int)?

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitFields(trimmed)
            if headerIndices == nil,
               let detectedHeader = detectHeader(in: fields) {
                headerIndices = detectedHeader
                continue
            }

            if let headerIndices,
               fields.indices.contains(headerIndices.latitude),
               fields.indices.contains(headerIndices.longitude),
               let latitude = numbers(in: fields[headerIndices.latitude]).first,
               let longitude = numbers(in: fields[headerIndices.longitude]).first,
               let coordinate = coordinate(first: latitude, second: longitude, order: .latitudeLongitude) {
                coordinates.append(coordinate)
                continue
            }

            let values = numbers(in: trimmed)
            if values.count >= 2,
               let coordinate = coordinate(first: values[0], second: values[1], order: .latitudeLongitude) {
                coordinates.append(coordinate)
            }
        }

        return coordinates
    }

    private static func splitFields(_ line: String) -> [String] {
        line
            .split { character in
                character == "," ||
                character == ";" ||
                character == "\t"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func detectHeader(in fields: [String]) -> (latitude: Int, longitude: Int)? {
        let lowered = fields.map { $0.lowercased() }
        guard let latitude = lowered.firstIndex(where: { $0 == "lat" || $0 == "latitude" }),
              let longitude = lowered.firstIndex(where: { $0 == "lon" || $0 == "lng" || $0 == "long" || $0 == "longitude" }) else {
            return nil
        }
        return (latitude, longitude)
    }

    private static func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    // Optional organizing metadata (Favorites). All optional so records saved by
    // older builds — which had none of these fields — still decode cleanly.
    var folder: String? = nil
    var tags: [String] = []
    var notes: String? = nil

    // Last time this place was created/edited on this device. Drives multi-device
    // sync conflict resolution (newest-wins on the same key). Optional-back-compat:
    // records from older builds decode with `updatedAt == nil` and are treated as
    // oldest, so a newer edit on any device always wins over a legacy record.
    var updatedAt: Date? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Stable identity for the additive-union sync merge: lowercased, trimmed name +
    /// coordinates rounded to ~5 decimals (~1 m). Two records with the same syncKey are
    /// considered "the same place" regardless of their `id`, so a place saved on device A
    /// and independently on device B collapses to one row instead of duplicating.
    var syncKey: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lat = (latitude * 100_000).rounded() / 100_000
        let lng = (longitude * 100_000).rounded() / 100_000
        return String(format: "%@|%.5f|%.5f", n, lat, lng)
    }

    // Custom decoding keeps old saved data loadable: any missing metadata key
    // falls back to its empty/nil default rather than failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double,
         folder: String? = nil, tags: [String] = [], notes: String? = nil,
         updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.folder = folder
        self.tags = tags
        self.notes = notes
        self.updatedAt = updatedAt
    }
}

private extension View {
    /// Apple's full place card (name, category, hours, photos) for a tapped map
    /// feature. iOS 18+ only; the app still deploys to 17.4, where the selection
    /// binding alone already makes POIs tappable with the plain built-in callout —
    /// so 17 loses the rich card, not the interaction.
    @ViewBuilder
    func wanderMapFeatureAccessory() -> some View {
        if #available(iOS 18.0, *) {
            self.mapFeatureSelectionAccessory(.automatic)
        } else {
            self
        }
    }
}

// MARK: - Search Completer

/// The route sheet searches places exactly the way the main search bar does:
/// anchored to the spoof target, with the same worldwide retry when the anchor has
/// no answer (a Tokyo→Osaka route must still be searchable from a Tokyo pin). That
/// is one behaviour, so it is one implementation — see `AnchoredPlaceCompleter`
/// in AddressSearchBar.swift.
typealias LocationSearchCompleter = AnchoredPlaceCompleter

struct LocationSimulationView: View {
    @State private var coordinate: CLLocationCoordinate2D?
    // When PoGo (gs-loc) mode is on, teleport is the ONLY thing that works — so surface the soft-ban
    // cooldown a jump to this pin would cost right next to the Simulate button. Bound to GslocMode's own
    // defaults key so it appears/disappears the instant the mode is toggled.
    @AppStorage(GslocMode.defaultsKey) private var gslocMode = false
    @AppStorage("mapStyleMode") private var mapStyleModeRaw = MapStyleMode.standard.rawValue
    /// Which points of interest the base map draws. Lives beside the style choice in
    /// the same switcher menu — it's the same question ("what should this map show
    /// me?"), so it doesn't get its own floating control.
    @AppStorage("mapPOIPreset") private var mapPOIPresetRaw = MapPOIPreset.automatic.rawValue
    /// The Apple-drawn place the user last tapped on the map. Non-nil means Apple's
    /// own place card is up and our action row is offering to do something with it.
    ///
    /// Typed `MapFeature?` rather than `MapSelection<MKMapItem>?` for one reason:
    /// `MapSelection` is iOS 18+ and this target still deploys to 17.4. The two are
    /// equivalent here — `MapSelection` only earns its keep when you ALSO want your
    /// own `MKMapItem` annotations selectable, and Wander's markers are plain
    /// `Marker`s. Everything the action row needs (title, coordinate) comes straight
    /// off `MapFeature`, and `.mapFeatureSelectionAccessory` still attaches Apple's
    /// full place card on 18+.
    @State private var mapFeatureSelection: MapFeature?
    /// "Smooth long jumps": when on, a teleport farther than the threshold from
    /// the current spoofed position eases over a few seconds instead of hopping.
    @AppStorage("smoothLongJumps") private var smoothLongJumps = false
    // Backing keys for the on-map "Find My / Life360 mode" toggle (same keys Settings uses), so the
    // anti-detection preset for location-sharing apps lives where you actually spoof, not just Settings.
    @AppStorage("jitterEnabled") private var jitterEnabled = true
    @AppStorage("jitterRadius") private var jitterRadius = 1.5
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    // Set when the pin was moved BY the map itself (Move here / tap-to-place). The camera is already
    // showing exactly where the user put it, so the auto-recenter below must not fire — re-centring and
    // re-zooming to a fixed 1 km span there is what made the map visibly snap and lose the framing the
    // user had just chosen. Recentring is still correct for pins that arrive from OFF-screen sources
    // (search, saved places, share links, deep links), which is what it was written for.
    @State private var pinMovedFromMap = false
    @State private var visibleCenter: CLLocationCoordinate2D?
    // Debounced background task that warms the offline CARTO tile cache for wherever the user is
    // browsing on the (online, Apple) map — so flipping to airplane mode still shows a map instead
    // of a black screen. The online map is Apple's and doesn't fill the CARTO cache, which is why
    // "browse then airplane mode" went dark.
    @State private var tilePrefetchTask: Task<Void, Never>?
    @StateObject private var currentLocation = CurrentLocation()
    /// The device's own coordinate, captured ONCE and only while nothing is known to
    /// be spoofing. This is the only thing allowed to be labelled "your real
    /// location" in the search header.
    ///
    /// It exists because `currentLocation` cannot be trusted for that label: while a
    /// simulation is live, CoreLocation reports the FAKE position to this app too —
    /// that is exactly what the "Check my spoof" verify card reads. `request()` runs
    /// on every `onAppear`, so returning to this tab mid-spoof would quietly refresh
    /// the "real" coordinate to the spoof target, and "Near me" would re-anchor to
    /// the place it was already anchored to under a label claiming the opposite. In a
    /// feature whose entire subject is map honesty, that label has to be true or
    /// absent — so when we can't be sure, this stays nil and the toggle disappears.
    @State private var realLocationSnapshot: CLLocationCoordinate2D?
    @StateObject private var locationInfo = LocationInfoService()
    @ObservedObject private var reachability = NetworkReachability.shared
    /// Cellular Mode's own "the shortcut is installed" flag, read through the SAME defaults key
    /// `ShortcutRunner.cellularModeReady` writes — as an `@AppStorage` so the button re-labels itself
    /// the instant the setup sheet (or an x-error callback) flips it. Same pattern, same reason, as
    /// `SetupChecklistView`'s read of `shortcutsReady`.
    @AppStorage("cellularModeShortcutReady") private var legacyCellularModeReady = false
    /// The one-action `Wander Airplane` shortcut. Read alongside the legacy flag rather than replacing
    /// it, so somebody who did the old Shortcuts-editor work is not told to set up again.
    @AppStorage("wanderAirplaneShortcutReady") private var airplaneShortcutReady = false
    private var cellularModeReady: Bool { airplaneShortcutReady || legacyCellularModeReady }
    @State private var showCellularSetup = false
    /// Drives the in-place progress line and the failure alert for a Cellular Mode run. Wander is the
    /// conductor now, so unlike the old Shortcut-driven flow there is something to report.
    @ObservedObject private var cellularSequence = CellularModeSequence.shared
    // "First fix is real" guardrail (OFF by default — see RealGPSSeeder). When enabled, seeds the
    // device's real location before a teleport so the opening jump isn't an instant impossible delta.
    @StateObject private var realGPSSeeder = RealGPSSeeder()

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    /// Mean-reverting "breathing" jitter state for the current stationary hold, so a parked
    /// location wanders ~1–3 m and drifts back instead of teleporting a fresh random metre each
    /// tick. Created per hold in startResendLoop, cleared in stopResendLoop.
    @State private var breathingJitter: BreathingJitter?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false

    /// Which location command currently OWNS the controls, so `isBusy` can never latch true.
    ///
    /// `isBusy` greys out Simulate, Play Route and Stop, and its only reset used to live at the far
    /// end of the serial location queue — inside the block that runs after the FFI returns. A queue
    /// that could not drain (a dead tunnel, before the bounded probe in `_simulate_location` covered
    /// every dial) therefore left the whole action row disabled for the rest of the session, which is
    /// precisely the reported "Simulate goes gray and clicking Stop does nothing".
    ///
    /// Every command takes the next token, and three things can end its ownership: the command
    /// reporting back, the watchdog releasing it (`armBusyWatchdog`), or a Stop taking the controls
    /// (`clear()` / the `.stopSimulationRequested` handler) — the last of which is what guarantees a
    /// user-visible Stop is never gated on work it cannot see. A late outcome whose token no longer
    /// matches is discarded rather than allowed to re-disable a control somebody else now owns.
    @State private var locationCommandToken = 0
    @State private var showPaywall = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var showCoordinateImporter = false
    @State private var streetViewTarget: CoordinateSnapshot?
    // True while the address search is focused / showing results — hides the floating top card.
    @State private var searchActive = false
    // Crosshair placement and the bottom panel's height are NOT decided here — see
    // Support/MapModeChrome.swift, which owns both for Teleport, Joystick and Route alike. This
    // screen used to measure its own card top and derive a lift from it, which is why the crosshair
    // sat somewhere different here than it did on the other two tabs.
    // Region for the offline (cached-tile) map shown automatically when the device has no network.
    @State private var offlineRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        latitudinalMeters: 2000, longitudinalMeters: 2000)
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePolyline: MKPolyline?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()

    // Undo: the pin location immediately before the most recent move/teleport,
    // so the user can revert one step.
    @State private var previousCoordinate: CLLocationCoordinate2D?

    // Natural-language teleport (Pro): "Where do you want to go?" → POST /ai/place → teleport.
    @State private var nlQuery = ""
    @State private var isResolvingNLPlace = false

    // GPX export.
    @State private var showGPXExporter = false
    @State private var gpxDocument = GPXDocument(text: "")

    private static let routeDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    // Bookmarks. Saved to (and read back from) the shared `locationBookmarks` store — the same one
    // the Places screen lists — so the bookmark button below and Places are one feature, not two.
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        // gs-loc mode injects through the proxy, not the dev tunnel, so no pairing file is needed —
        // don't let the pairing guards block teleport or Stop. The FFI short-circuits to the proxy
        // before the pairing path is ever used.
        FileManager.default.fileExists(atPath: pairingFilePath) || GslocMode.enabled
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil
    }

    /// Whether Stop has anything to do — and therefore whether it is tappable.
    ///
    /// DELIBERATELY NOT GATED ON `isBusy`, unlike every other control in the row. `isBusy` means "a
    /// location command is out", and a command that is out is the single most likely reason someone
    /// is reaching for Stop in the first place. Gating Stop on it is what turned a slow command into
    /// "clicking Stop does nothing". `clear()` is safe to call at any moment: its whole first half is
    /// synchronous local teardown that touches no queue.
    ///
    /// Not gated on `pairingExists` either — standing the local session down is just as valid with
    /// no pairing file, and `clear()` skips only the device half in that case.
    private var canStop: Bool {
        hasActiveSimulation || isBusy
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let durationText = Self.routeDurationFormatter.string(from: routePlan.expectedTravelTime)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • ETA \(durationText)"
        }
        return distanceText
    }

    private var routeStatusText: String {
        if isLoadingRoute {
            return "Calculating route…"
        }
        if isPrefetchingRouteSpeeds {
            return "Prefetching road speeds…"
        }
        if routePlan != nil {
            return "Route ready."
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "Pick both route endpoints to build the drive."
        }
        // No toolbar to plan from any more — a route gets here by being imported (Places → Import
        // coordinates), and routes are BUILT on the Route tab.
        return "Import a route file from Places, or build one on the Route tab."
    }

    private var routeAttributionLink: some View {
        Link(
            "Speed limit data © OpenStreetMap contributors (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        // The tertiary-metadata token, not a raw `.caption2` — an attribution line is the textbook
        // case for `wanderMicro`, and a raw point size here is a fifth size on a panel that is
        // supposed to have four.
        .wanderMicro()
    }

    private var mapStyleMode: MapStyleMode {
        MapStyleMode(rawValue: mapStyleModeRaw) ?? .standard
    }

    private var mapPOIPreset: MapPOIPreset {
        MapPOIPreset(rawValue: mapPOIPresetRaw) ?? .automatic
    }

    /// True while there is a line on the map the user needs to be able to read — a
    /// route polyline, or a live playback/joystick track. POIs come off for both.
    private var isDrawingPath: Bool {
        hasRouteContext || routePlaybackCoordinate != nil
    }

    /// The POI set the base map is actually allowed to draw right now.
    private var mapPOICategories: PointOfInterestCategories {
        MapPOIPreset.categories(
            for: mapPOIPreset,
            gamesMode: gslocMode,
            drawingPath: isDrawingPath
        )
    }

    /// Where place search should be ranked around.
    ///
    /// MapKit's default is the device's PHYSICAL location, which in a spoofer is the
    /// one place the user is not asking about — spoof to Tokyo, search "coffee", get
    /// a café near your couch. So the anchor follows, in order: the position we are
    /// currently reporting to the device, the pin the user has dropped, and finally
    /// whatever the map is framed on. Nil (nothing pinned, camera not yet settled)
    /// leaves the search bar in its original unanchored behaviour.
    private var searchAnchor: MapSearchAnchor? {
        if let spoofed = currentSpoofedCoordinate {
            return MapSearchAnchor(
                coordinate: spoofed,
                name: L("search.anchor.spoof", fallback: "your spoofed location")
            )
        }
        if let coordinate {
            return MapSearchAnchor(
                coordinate: coordinate,
                name: L("search.anchor.pin", fallback: "your pin")
            )
        }
        if let visibleCenter {
            return MapSearchAnchor(
                coordinate: visibleCenter,
                name: L("search.anchor.map", fallback: "the map view")
            )
        }
        return nil
    }

    /// True when CoreLocation might be handing this app a spoofed fix rather than a
    /// device one, so nothing it reports may be labelled "your real location".
    ///
    /// Covers all three ways that happens: our own DVT simulation (`SimulationSession`
    /// survives leaving this tab, which is why the view's local flags aren't enough),
    /// a route/glide playing back, and gs-loc mode — where the poisoning happens
    /// outside the app entirely and we genuinely cannot tell a real fix from a
    /// rewritten one. Read-only use of the simulation state; nothing here touches it.
    private var mayBeReportingSpoofedLocation: Bool {
        SimulationSession.shared.isActive
            || hasActiveSimulation
            || currentSpoofedCoordinate != nil
            || gslocMode
    }

    /// Title + coordinate of the Apple POI the user last tapped, if any.
    private var selectedFeature: (title: String, coordinate: CLLocationCoordinate2D)? {
        guard let feature = mapFeatureSelection else { return nil }
        let name = feature.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (name.isEmpty ? L("map.poi.unnamed", fallback: "Dropped place") : name,
                feature.coordinate)
    }

    /// Action row for a tapped Apple POI. Apple's own accessory already answers
    /// "what is this place?" (name, category, hours, photos); this answers the two
    /// questions only Wander can: put me there, or remember it for later.
    @ViewBuilder
    private var selectedFeatureRow: some View {
        // Hidden while a route/track is on the map: POIs aren't drawn then, so any
        // selection still sitting here is left over from before the route existed.
        if !isDrawingPath, let selected = selectedFeature {
            VStack(spacing: MapModeChrome.groupSpacing) {
                HStack(spacing: MapModeChrome.chipSpacing) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(Wander.brand)
                    Text(selected.title)
                        .wanderLabel()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        mapFeatureSelection = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("map.poi.dismiss", fallback: "Dismiss place"))
                }

                HStack(spacing: MapModeChrome.rowSpacing) {
                    Button {
                        if isRouteRunning { return }
                        saveFeatureAsPlace(selected)
                    } label: {
                        Label(L("map.poi.save", fallback: "Save to Places"), systemImage: "bookmark")
                            .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                    }
                    .buttonStyle(.bordered)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .opacity(isRouteRunning ? 0.5 : 1)

                    Button {
                        if isRouteRunning || isBusy { return }
                        teleportToFeature(selected)
                    } label: {
                        Label(L("map.poi.teleport", fallback: "Teleport here"), systemImage: Wander.Icon.simulate)
                            .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .opacity((isRouteRunning || isBusy) ? 0.5 : 1)
                }
            }
            .transition(.opacity)
        }
    }

    /// Move the pin to a tapped POI and teleport, mirroring the shared
    /// `.teleportToRequested` path so there is exactly one teleport route.
    private func teleportToFeature(_ selected: (title: String, coordinate: CLLocationCoordinate2D)) {
        // The camera is already framed on the POI the user tapped — don't yank it.
        pinMovedFromMap = true
        applySelection(selected.coordinate)
        mapFeatureSelection = nil
        guard pairingExists else {
            alertTitle = "Pairing needed"
            alertMessage = "Import a pairing file in Settings, then tap Simulate to start."
            showAlert = true
            return
        }
        simulate()
    }

    /// Save a tapped POI straight into the same bookmark list the "Save Bookmark"
    /// alert writes to — including the `.placesDidChange` post, so the Places tab
    /// and multi-device sync pick it up with no extra plumbing.
    private func saveFeatureAsPlace(_ selected: (title: String, coordinate: CLLocationCoordinate2D)) {
        bookmarks.append(
            LocationBookmark(
                name: selected.title,
                latitude: selected.coordinate.latitude,
                longitude: selected.coordinate.longitude,
                updatedAt: Date()
            )
        )
        saveBookmarks()
        mapFeatureSelection = nil
        alertTitle = L("map.poi.saved.title", fallback: "Saved")
        alertMessage = String(format: L("map.poi.saved.body", fallback: "%@ was added to your Places."),
                              selected.title)
        showAlert = true
    }

    /// Floating control that lets the user switch between Standard, Satellite,
    /// and Hybrid imagery. Mirrors the app's floating-card design language.
    /// A subtle, non-nagging hint shown only while the device has no connectivity, so the app's
    /// calm offline states (hidden weather card, empty raids board, an unavailable globe) read as
    /// intentional. Core features (teleport, joystick, routes) keep working regardless.
    private var offlinePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.caption2)
            Text(L("offline.badge", fallback: "Offline — live extras paused"))
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .accessibilityLabel(L("offline.badge.a11y",
                              fallback: "You are offline. Live extras are paused. The map and teleport still work."))
    }

    /// Why the "Places shown" choice is currently being ignored, or nil when it
    /// isn't. Both cases are deliberate overrides, and both make the picker look
    /// broken from the outside — you move the checkmark and the map doesn't change.
    private var poiOverrideNote: String? {
        if isDrawingPath {
            return L("map.poi.hidden_for_route",
                     fallback: "Places are hidden while a route is on the map")
        }
        if mapStyleMode == .satellite {
            return L("map.poi.satellite_note",
                     fallback: "Satellite imagery draws no place labels")
        }
        return nil
    }

    @ViewBuilder
    private var poiPicker: some View {
        Picker(L("map.poi.title", fallback: "Places shown"), selection: $mapPOIPresetRaw) {
            ForEach(MapPOIPreset.allCases) { preset in
                Label(preset.label, systemImage: preset.symbol).tag(preset.rawValue)
            }
        }
    }

    private var mapStyleSwitcher: some View {
        Menu {
            Picker("Map style", selection: $mapStyleModeRaw) {
                ForEach(MapStyleMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode.rawValue)
                }
            }

            // Second section of the SAME menu rather than a second floating button:
            // "what imagery" and "which places" are one question to the user, and the
            // map already has as many controls on top of it as it can afford.
            Divider()

            // When the preset is being overridden, the reason goes in a SECTION
            // HEADER — not a loose `Text`. A SwiftUI `Menu` is built into a `UIMenu`,
            // which renders only Button/Toggle/Picker/Link/Menu/Divider/Section: a
            // bare `Text` has no `UIMenuElement` to map to and is silently dropped.
            // That mattered here more than anywhere, because the override is exactly
            // when the control looks broken — you move the checkmark and the map
            // doesn't change — so the one element carrying the explanation was the
            // one element guaranteed not to appear.
            if let note = poiOverrideNote {
                Section {
                    poiPicker
                } header: {
                    Text(note)
                }
            } else {
                poiPicker
            }
        } label: {
            Image(systemName: mapStyleMode.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Wander.brand)
                .frame(width: MapModeChrome.tapTarget, height: MapModeChrome.tapTarget)
                .background(MapModeChrome.panelMaterial,
                            in: RoundedRectangle(cornerRadius: MapModeChrome.innerCornerRadius,
                                                 style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MapModeChrome.innerCornerRadius, style: .continuous)
                        .strokeBorder(Wander.hairline, lineWidth: 0.5)
                )
                // The panel's shadow, not a second recipe — this button floats over the same map at
                // the same height, so it casts the same shadow.
                .wanderMapShadow()
        }
        .accessibilityLabel(L("map.style.switch", fallback: "Map style"))
    }

    /// The primary (online) map — Apple MapKit with pin/route markers + style switching + center
    /// tracking. Extracted from `body` so the ZStack stays within the type-checker's limits.
    @ViewBuilder private var onlineMap: some View {
        MapReader { proxy in
            // `selection:` is what makes Apple's own POIs tappable at all. Without a
            // selection binding every café, park and landmark MapKit draws is a dead
            // pixel — it looks interactive and does nothing. With it (plus
            // `.mapFeatureSelectionAccessory` below) we inherit Apple's full place
            // card — name, category, hours, photos — for free, and add the two
            // actions a spoofer actually wants on top.
            Map(position: $position, selection: $mapFeatureSelection) {
                if hasRouteContext {
                    if let routePolyline {
                        // Brand, matching the Route tab's drive line (RouteLegPalette.drive is
                        // Wander.brand) — the same route drawn on two screens was two different
                        // blues before this.
                        MapPolyline(routePolyline)
                            .stroke(Wander.brand.opacity(0.85), lineWidth: 5)
                    }
                    // Same two tokens the Route tab tints its first/last waypoint with, so a
                    // start pin is the same green on both screens.
                    if let routeStartCoordinate {
                        Marker("Start", coordinate: routeStartCoordinate)
                            .tint(Wander.good)
                    }
                    if let routeEndCoordinate {
                        Marker("End", coordinate: routeEndCoordinate)
                            .tint(Wander.blocked)
                    }
                    if let routePlaybackCoordinate {
                        // Where the spoof currently IS — the one live, working thing on the map,
                        // so it takes the brand colour rather than a raw `.blue` that happened to
                        // match nothing else in the panel below it.
                        Marker("Current", coordinate: routePlaybackCoordinate)
                            .tint(Wander.brand)
                    }
                } else if let coordinate {
                    // The pin the user placed. Brand, not `.red`: red is `Wander.blocked` in this
                    // app's vocabulary, and a pin you just dropped is not an error.
                    Marker("Pin", coordinate: coordinate)
                        .tint(Wander.brand)
                }
            }
            .mapStyle(mapStyleMode.mapStyle(pointsOfInterest: mapPOICategories))
            .wanderMapFeatureAccessory()
            .mapControls {
                MapCompass()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                // Report the point UNDER the lifted crosshair (shifted north), not the map centre.
                visibleCenter = MapModeChrome.dropPoint(in: context.region)
                // Warm the offline cache for the area being viewed. Debounced (wait for the camera to
                // settle), online-only, and only when zoomed to neighbourhood/city level so a wide
                // view can't queue thousands of tiles. Skips already-cached tiles, so it's cheap.
                let region = context.region
                tilePrefetchTask?.cancel()
                tilePrefetchTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if Task.isCancelled { return }
                    guard await MainActor.run(body: { NetworkReachability.shared.hasInternet }) else { return }
                    let span = region.span.longitudeDelta
                    guard span > 0, span < 0.12 else { return }
                    let z = max(11, min(OfflineTileStore.maxZoomCap, Int((log2(540.0 / span)).rounded())))
                    try? await OfflineTileStore.shared.downloadRegion(
                        name: OfflineTileStore.autoRegionName,
                        region: region,
                        minZoom: z,
                        maxZoom: min(OfflineTileStore.maxZoomCap, z + 1),
                        progress: { _, _ in }
                    )
                }
            }
        }
    }

    /// The offline fallback map — a UIKit MKMapView backed by cached CARTO tiles, shown
    /// automatically when the device is offline so the map still works instead of a blank grid.
    @ViewBuilder private var offlineMap: some View {
        OfflineMapView(
            selectedCoordinate: $coordinate,
            region: $offlineRegion,
            cacheOnly: false,
            onRegionChange: { region, dropPoint in
                // Point under the lifted crosshair, matching the online map — but MEASURED from
                // the map view's geometry, not derived from `region`. `MKMapView.region`
                // describes its layout-margins rect rather than its bounds, so the region-based
                // rule the online branch uses lands 46pt low here; the offline map hands us the
                // exact coordinate instead. See `MapModeChrome.dropPoint(in mapView:)`.
                visibleCenter = dropPoint
                // Track the user's pan. Without this, offlineRegion stays pinned to the selected
                // coordinate, and the visibleCenter re-render makes updateUIView re-apply it —
                // snapping the map back to the pin every time you tried to pan away while offline.
                offlineRegion = region
            }
        )
        .onAppear {
            if let center = visibleCenter {
                offlineRegion = MKCoordinateRegion(center: center,
                                                   latitudinalMeters: 2000, longitudinalMeters: 2000)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    if reachability.hasInternet {
                        onlineMap
                    } else {
                        offlineMap   // real internet unreachable (incl. Airplane Mode + LocalDevVPN) → cached CARTO, still spoofable
                    }
                }
                    .wanderMapCrosshair(!hasRouteContext && !hasActiveSimulation)
                    .ignoresSafeArea()
                    .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                        if let new {
                            let region = MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                            // Don't yank the camera when the user placed this pin on the map
                            // themselves — on EITHER branch. `offlineRegion` used to be written
                            // unconditionally here as "not user-visible framing", but it is the
                            // offline map's live camera (OfflineMapView re-applies it through
                            // `shouldApplyRegion`), so "Set pin here" re-centred the offline map
                            // on the pin — parking the pin at the region's centre, well below the
                            // crosshair the user aimed with, and resetting their zoom. Online was
                            // already exempt via `pinMovedFromMap`; this is the same exemption.
                            if pinMovedFromMap {
                                pinMovedFromMap = false
                            } else {
                                offlineRegion = region
                                position = .region(region)
                            }
                        }
                    }

                VStack(spacing: 0) {
                    Spacer()

                    WanderCard {
                        // One shared vertical rhythm across Teleport / Joystick / Route — this panel ran
                        // at 8pt while the other two ran at 12 and 14, which is invisible on one screen
                        // and obvious the moment you switch tabs.
                        VStack(spacing: MapModeChrome.rowSpacing) {
                            if !hasRouteContext {
                                AddressSearchBar(
                                    placeholder: "Search, coordinates, or Plus Code",
                                    mapCenter: visibleCenter,
                                    // Rank autocomplete around where the user is PRETENDING
                                    // to be, not where the phone is sitting.
                                    searchAnchor: searchAnchor,
                                    // Only used to offer "Near me" — never as the default,
                                    // and only ever the pre-simulation snapshot, never a
                                    // live CoreLocation fix that a spoof may have written.
                                    realLocation: realLocationSnapshot,
                                    onPick: { coord, _ in applySelection(coord) },
                                    onActiveChange: { searchActive = $0 }
                                )

                                nlTeleportBar

                                sharingModeToggle
                            }

                            selectedFeatureRow

                            if isImportingCoordinates {
                                ProgressView("Importing coordinates…")
                                    .font(.wanderDetail)
                                    .tint(Wander.brand)
                            }

                            if hasRouteContext {
                                routeControls
                            } else {
                                pinControls
                            }
                        }
                        // THE canonical panel height, shared with Joystick and Route. See MapModeChrome.
                        // This screen has no disclosure section, so it never asks for the expanded size.
                        .wanderMapPanel()
                        .wanderAnimation(WanderMotion.layout, on: hasRouteContext)
                    }
                }

                VStack(spacing: 6) {
                    if !reachability.isOnline {
                        offlinePill
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    // Hide the floating info card while searching — the results list grows up from the
                    // bottom card and would otherwise slide underneath it, hiding the top result.
                    if !searchActive {
                        LocationInfoCard(service: locationInfo)
                            .padding(.top, reachability.isOnline ? 8 : 0)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                }
                .animation(.easeInOut(duration: 0.25), value: locationInfo.info)
                .animation(.easeInOut(duration: 0.25), value: reachability.isOnline)
                .animation(.easeInOut(duration: 0.2), value: searchActive)

                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        mapStyleSwitcher
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    Spacer(minLength: 0)
                }
            }
            // (The card-measuring PreferenceKey that used to live here is gone: the crosshair no longer
            // depends on a live measurement, so swapping between the online and offline map — which tore
            // the GeometryReader down and briefly reported 0 — can't make it jump any more.)
            // The shared navigation treatment: an inline title over a full-bleed map, same as
            // Joystick and Route (see "THE NAVIGATION RULE" in MapModeChrome).
            //
            // NO `.toolbar` OF ITS OWN — see `mapModeToolbar` below. This screen once carried five
            // buttons up here while Joystick and Route carried none, so the top of the app changed
            // shape depending on which map mode you were on, and three of the five were a hidden
            // second copy of navigation the app already has. Both of those problems are still real;
            // the shared toolbar is what lets Places and Offline maps be one tap away WITHOUT
            // either of them coming back. A route-search button is not in it and must not be: the
            // Route tab is a permanent bottom tab.
            .navigationTitle(AppFeature.location.title)
            .navigationBarTitleDisplayMode(.inline)
            // The bar all three map tabs share. Its two file actions post the SAME notifications
            // the Places rows post (handled at the bottom of this chain), rather than reaching into
            // this screen's importer/exporter directly — one guarded code path, whichever door the
            // user came through.
            .mapModeToolbar(files: MapModeFileActions(
                importCoordinates: { NotificationCenter.default.post(name: .importCoordinatesRequested, object: nil) },
                exportGPX:         { NotificationCenter.default.post(name: .exportGPXRequested, object: nil) }
            ))
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            // FAIL LOUDLY. Every way a Cellular Mode run can go wrong — Shortcuts missing, the radio
            // never switching, the tunnel or teleport failing — surfaces here as a sentence about what
            // happened, with the manual route named in the copy. `offerSetup` is what separates "that
            // didn't work" from "the shortcut isn't installed": only the second one sends the user
            // back to the setup card, where the hand-add fallback also lives.
            .alert(cellularSequence.failure?.title ?? "",
                   isPresented: Binding(get: { cellularSequence.failure != nil },
                                        set: { if !$0 { cellularSequence.failure = nil } })) {
                if cellularSequence.failure?.offerSetup == true {
                    Button(L("map.cellular.fix", fallback: "Set up Cellular Mode")) {
                        cellularSequence.failure = nil
                        showCellularSetup = true
                    }
                }
                Button(L("action.ok", fallback: "OK"), role: .cancel) { cellularSequence.failure = nil }
            } message: {
                Text(cellularSequence.failure?.message ?? "")
            }
            .alert("Save Bookmark", isPresented: $showSaveBookmark) {
                TextField("Name", text: $newBookmarkName)
                Button("Save") { addBookmark() }
                Button("Cancel", role: .cancel) { newBookmarkName = "" }
            } message: {
                Text("Enter a name for this location.")
            }
            // Item-driven so Street View can ONLY open for a concrete, chosen pin — never on entry
            // with a stale/ambient coordinate. Set by the Street View button from the selected pin.
            .sheet(item: $streetViewTarget) { target in
                StreetViewSheet(coordinate: target.coordinate)
            }
            .fileImporter(
                isPresented: $showCoordinateImporter,
                allowedContentTypes: CoordinateImportParser.supportedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                importCoordinates(result)
            }
            .fileExporter(
                isPresented: $showGPXExporter,
                document: gpxDocument,
                contentType: UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml,
                defaultFilename: "wander-\(Self.gpxTimestamp())"
            ) { result in
                if case .failure(let error) = result {
                    alertTitle = "Export Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
            .onAppear {
                loadBookmarks()
                currentLocation.request()
            }
            .onReceive(currentLocation.$coordinate.compactMap { $0 }) { c in
                // Take the "real location" snapshot at most once, and only while nothing
                // could be feeding CoreLocation a fake fix. After that it is frozen: a
                // fix that arrives mid-spoof is the spoof target, not the device.
                if realLocationSnapshot == nil, !mayBeReportingSpoofedLocation {
                    realLocationSnapshot = c
                }
                if coordinate == nil && simulatedCoordinate == nil && !hasRouteContext {
                    position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2500, longitudinalMeters: 2500))
                }
            }
            .onDisappear {
                // Switching tabs shouldn't tear down a live spoof/route — keep it running and
                // let the explicit Stop button (or global stop) end it. Only clean up when idle.
                guard !SimulationSession.shared.isActive else { return }
                routeSpeedPrefetchTask?.cancel()
                routeSpeedPrefetchTask = nil
                cancelRoutePlayback(resetMarker: true)
                stopResendLoop()
                if backgroundTaskID != .invalid {
                    BackgroundLocationManager.shared.requestStop()
                }
                endBackgroundTask()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopSimulationRequested)) { _ in
                cancelRoutePlayback(resetMarker: true)
                stopResendLoop()
                endBackgroundTask()
                locationInfo.clear()
                // A global Stop / Panic outranks whatever command is holding this row. Without this,
                // Panic stood every mode down but left the Teleport tab's buttons greyed out behind
                // an `isBusy` only that command could clear. See `locationCommandToken`.
                locationCommandToken &+= 1
                isBusy = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .holdLocationRequested)) { note in
                guard let lat = note.userInfo?["lat"] as? Double,
                      let lng = note.userInfo?["lng"] as? Double else { return }
                // A joystick / auto-walk just parked here. Take over the warm-hold seeded at THIS
                // point (re-enables the 4 s resend at the live position, not the old teleport origin).
                startResendLoop(with: CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
            .sheet(isPresented: $showCellularSetup) { CellularModeSetupView() }
            .onReceive(NotificationCenter.default.publisher(for: .teleportToRequested)) { note in
                guard let lat = note.userInfo?["lat"] as? Double,
                      let lng = note.userInfo?["lng"] as? Double else { return }
                applySelection(CLLocationCoordinate2D(latitude: lat, longitude: lng))
                if pairingExists {
                    simulate()
                } else {
                    alertTitle = "Pairing needed"
                    alertMessage = "Import a pairing file in Settings, then tap Simulate to start."
                    showAlert = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .previewLocationRequested)) { note in
                guard let lat = note.userInfo?["lat"] as? Double,
                      let lng = note.userInfo?["lng"] as? Double else { return }
                // Preview ONLY: center the map, drop/move the pin, refresh its info. Do NOT simulate —
                // the user presses Simulate / "Set pin here" to actually teleport. Shared by a tapped
                // saved Place and a tapped PoGo hotspot so both behave identically.
                applySelection(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            .onReceive(NotificationCenter.default.publisher(for: .placesDidChange)) { _ in
                loadBookmarks()
            }
            // Import coordinates / Export GPX have TWO entry points — the Places rows and this
            // screen's own toolbar menu — and one implementation, here, against this screen's pin
            // and route, through the same `.fileImporter` / `.fileExporter` as before. Both doors
            // post these notifications rather than duplicating the guards below. Places switches to
            // this tab and dismisses itself before posting, so by the time either arrives this view
            // is on screen and the picker has somewhere to present from; the toolbar is already on
            // this view, so it can post directly.
            .onReceive(NotificationCenter.default.publisher(for: .importCoordinatesRequested)) { _ in
                guard !isBusy, !isRouteRunning, !isImportingCoordinates else { return }
                showCoordinateImporter = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportGPXRequested)) { _ in
                guard !isBusy, !isImportingCoordinates else { return }
                // The toolbar button used to just go grey when there was nothing to write. A row in
                // a list can't do that honestly (Places can't see this screen's pin), so say it.
                guard canExportGPX else {
                    alertTitle = L("map.export.nothing.title", fallback: "Nothing to export")
                    alertMessage = L("map.export.nothing.body",
                                     fallback: "Drop a pin, build a route, or save a place first — a GPX file needs at least one point.")
                    showAlert = true
                    return
                }
                prepareGPXExport()
            }
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
        NotificationCenter.default.post(name: .placesDidChange, object: nil)
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude,
            updatedAt: Date()   // stamp for multi-device sync newest-wins merge
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    private func setRoutePlan(_ plan: RouteSimulationPlan?) {
        routePlan = plan
        routePolyline = plan.flatMap { makeRoutePolyline(for: $0.displayCoordinates) }
    }

    private func makeRoutePolyline(for coordinates: [CLLocationCoordinate2D]) -> MKPolyline? {
        guard coordinates.count > 1 else { return nil }
        return coordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    // MARK: - Location

    private func importCoordinates(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let sourceName = url.deletingPathExtension().lastPathComponent
            isImportingCoordinates = true

            Task {
                do {
                    let coordinates = try await Task.detached(priority: .userInitiated) {
                        try CoordinateImportParser.parse(url: url)
                    }.value

                    await MainActor.run {
                        isImportingCoordinates = false
                        applyImportedCoordinates(
                            coordinates,
                            sourceName: sourceName.isEmpty ? "Imported" : sourceName
                        )
                    }
                } catch {
                    await MainActor.run {
                        isImportingCoordinates = false
                        showImportError(error)
                    }
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func applyImportedCoordinates(
        _ importedCoordinates: [CLLocationCoordinate2D],
        sourceName: String
    ) {
        guard !isRouteRunning else { return }

        let coordinates = importedCoordinates.filter(CLLocationCoordinate2DIsValid)
        guard let firstCoordinate = coordinates.first else {
            showImportError(CoordinateImportError.noCoordinates)
            return
        }

        if coordinates.count == 1 {
            applySelection(firstCoordinate)
            return
        }

        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        coordinate = nil

        let displayCoordinates = sampledRouteCoordinates(
            from: coordinates,
            targetDistance: RouteSimulationDefaults.pathSamplingDistance
        )

        guard displayCoordinates.count > 1,
              let lastCoordinate = displayCoordinates.last else {
            applySelection(firstCoordinate)
            return
        }

        let distance = distanceAlong(displayCoordinates)
        let fallbackSpeed = RouteSimulationDefaults.importedRouteFallbackSpeedMetersPerSecond
        routeStartSelection = RouteSearchSelection(title: "\(sourceName) Start", coordinate: firstCoordinate)
        routeEndSelection = RouteSearchSelection(title: "\(sourceName) End", coordinate: lastCoordinate)
        setRoutePlan(RouteSimulationPlan(
            displayCoordinates: displayCoordinates,
            distance: distance,
            expectedTravelTime: distance / fallbackSpeed
        ))

        if let routePolyline {
            position = .rect(routePolyline.boundingMapRect)
        }

        let requestID = UUID()
        routeRequestID = requestID
        isPrefetchingRouteSpeeds = true
        routeSpeedPrefetchTask = Task.detached(priority: .utility) {
            let playbackSamples = await prefetchRoutePlaybackSamples(
                displayCoordinates: displayCoordinates,
                fallbackSpeedMetersPerSecond: fallbackSpeed
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard routeRequestID == requestID else { return }
                routePlaybackSamples = playbackSamples
                isPrefetchingRouteSpeeds = false
            }
        }
    }

    private func showImportError(_ error: Error) {
        alertTitle = "Import Failed"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    // MARK: - Natural-language teleport (Pro)

    /// "Where do you want to go?" — an AI teleport bar. Pro-gated: free/trial users tapping it
    /// get the paywall. On success it drops the pin at the resolved place and simulates, reusing
    /// the exact teleport path the map already uses. Every failure is a friendly alert.
    @ViewBuilder
    /// On-map "Find My / Life360 mode" toggle. This is the REGULAR (dev-tunnel) spoof most apps use —
    /// Find My, Life360, iMessage, dating apps — and this preset bundles the anti-detection settings
    /// (natural drift + smooth long jumps) so a shared location looks real. (Anti-cheat games like
    /// Pokémon GO use gs-loc/Shadowrocket instead — that lives in the PoGo tab.)
    private var sharingModeToggle: some View {
        Toggle(isOn: Binding(
            get: { jitterEnabled && smoothLongJumps },
            set: { on in
                jitterEnabled = on
                smoothLongJumps = on
                if on && jitterRadius < 1.5 { jitterRadius = 1.5 }
            }
        )) {
            HStack(spacing: MapModeChrome.groupSpacing) {
                Image(systemName: "person.2.wave.2").foregroundStyle(Wander.brand)
                VStack(alignment: .leading, spacing: MapModeChrome.groupSpacing) {
                    Text(L("map.sharingmode.title", fallback: "Find My / Life360 mode"))
                        .font(.wanderDetail.weight(.semibold))
                    Text(L("map.sharingmode.sub", fallback: "Natural drift + smooth jumps so shared location looks real."))
                        .wanderMicro()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Wander.brand)
    }

    private var nlTeleportBar: some View {
        HStack(spacing: MapModeChrome.groupSpacing) {
            Image(systemName: "sparkles").foregroundStyle(Wander.brand)
            TextField("Where do you want to go?", text: $nlQuery)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .disabled(isResolvingNLPlace)
                .onSubmit { resolveNLPlace() }
            if isResolvingNLPlace {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    resolveNLPlace()
                } label: {
                    Image(systemName: License.shared.isLicensed ? "arrow.up.circle.fill" : "lock.fill")
                        .foregroundStyle(Wander.brand)
                }
                .disabled(nlQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Teleport there")
            }
        }
        // Nested-control tokens, not hand-rolled numbers: this bar sits INSIDE the card, so it
        // takes the card's inner radius, inner padding and inner material. It used to draw a third
        // corner radius (10) on a screen that already had 24 on the card and 12 on the map-style
        // button — the same 10 `AddressSearchBar`, directly above it, drew until this pass.
        .padding(MapModeChrome.innerPadding)
        .background(MapModeChrome.innerMaterial,
                    in: RoundedRectangle(cornerRadius: MapModeChrome.innerCornerRadius,
                                         style: .continuous))
    }

    private func resolveNLPlace() {
        let query = nlQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        // Pro-gated entry: free users get the upsell before any network call.
        if !License.shared.isLicensed { showPaywall = true; return }
        guard pairingExists else {
            alertTitle = "Pairing needed"
            alertMessage = "Import a pairing file in Settings, then try again."
            showAlert = true
            return
        }
        isResolvingNLPlace = true
        Task {
            let result = await WanderAIRoutine.place(query: query)
            isResolvingNLPlace = false
            switch result {
            case .success(let place):
                if place.found, let coord = place.coordinate {
                    applySelection(coord)
                    nlQuery = ""
                    simulate()
                } else {
                    alertTitle = "Couldn't place that"
                    alertMessage = place.label.isEmpty
                        ? "The AI couldn't turn that into a spot on the map. Try naming a place or city."
                        : place.label
                    showAlert = true
                }
            case .proRequired:
                showPaywall = true
            case .dailyLimit(let message):
                alertTitle = "Daily limit reached"
                alertMessage = message
                showAlert = true
            case .notConfigured(let message):
                alertTitle = "Not available yet"
                alertMessage = message
                showAlert = true
            case .failed(let message):
                alertTitle = "Teleport failed"
                alertMessage = message
                showAlert = true
            }
        }
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            // THE focal value of this panel — the one thing the user came to this screen to read.
            // It was `.subheadline` in secondary grey, i.e. quieter than the buttons around it.
            VStack(alignment: .leading, spacing: MapModeChrome.groupSpacing) {
                Text(String(format: "%.5f,  %.5f", coord.latitude, coord.longitude))
                    // `wanderMetric` at `.primary` — the ONE size and colour the focal value takes
                    // in all three modes (see the token's note in WanderStyle).
                    .font(.wanderMetric)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .wanderTick(CoordinateSnapshot(coord))
                Text(L("map.pin.label", fallback: "Pin"))
                    .wanderMicro()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: MapModeChrome.rowSpacing) {
                // Guard the inactive states in the ACTION + dim with .opacity, rather than via
                // .disabled — a disabled `.bordered` button renders a blank/invisible grey label on
                // the dark card in dark mode. Explicit .tint keeps the icon brand-coloured either way.
                Button {
                    if isRouteRunning { return }
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                        .frame(width: 34, height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.bordered)
                .tint(Wander.brand)
                .controlSize(.large)
                .opacity(isRouteRunning ? 0.5 : 1)

                // Undo the last move/teleport, reverting to the previous pin. Only shown once there's
                // something to revert to.
                if previousCoordinate != nil {
                    Button {
                        if hasActiveSimulation || isBusy || isRouteRunning { return }
                        revertToPrevious()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 34, height: MapModeChrome.controlHeight)
                    }
                    .buttonStyle(.bordered)
                    .tint(Wander.brand)
                    .controlSize(.large)
                    .opacity((hasActiveSimulation || isBusy || isRouteRunning) ? 0.5 : 1)
                    .accessibilityLabel(L("map.undo_move", fallback: "Undo move"))
                }

                // Re-position the pin to the crosshair (map center). Inactive while a simulation is
                // live — Stop first, then move.
                Button {
                    if hasActiveSimulation || isBusy { return }
                    setPinToCenter()
                } label: {
                    Label(L("map.move_here", fallback: "Move here"), systemImage: Wander.Icon.setHere)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.bordered)
                .tint(Wander.brand)
                .controlSize(.large)
                .opacity((hasActiveSimulation || isBusy) ? 0.5 : 1)
            }

            // Look Around — Apple's native street-level imagery. FREE, keyless, and costs
            // us no Worker quota, so it goes to everyone; it just hides itself on the many
            // coordinates Apple has no coverage for. Sits directly above the Google Street
            // View button so the paid fallback reads as exactly that: a fallback.
            LookAroundStrip(coordinate: coord)

            // Street View — Pro-only (it hits the paid Google Maps API). Shown to free users too
            // (with a lock affordance) so they discover it; tapping opens the paywall. The Maps key
            // is fetched from the Worker on open (Pro + quota gated) — it's no longer bundled.
            Button {
                if !License.shared.isLicensed { showPaywall = true } else if let coordinate { streetViewTarget = CoordinateSnapshot(coordinate) }
            } label: {
                Label(L("map.street_view", fallback: "Street View"),
                      systemImage: License.shared.isLicensed ? "binoculars.fill" : "lock.fill")
                    .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
            }
            .buttonStyle(.bordered)
            .tint(Wander.brand)
            .controlSize(.large)

            gslocCooldownHint(for: coord)

            cellularModeControls(for: coord)

            HStack(spacing: MapModeChrome.rowSpacing) {
                Button {
                    if !canStop { return }
                    clear()
                } label: {
                    Label(L("map.stop", fallback: "Stop"), systemImage: Wander.Icon.stop)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.bordered)
                .tint(Wander.blocked)
                .controlSize(.large)
                .opacity(canStop ? 1 : 0.5)

                Button(action: simulate) {
                    Label(L("map.simulate", fallback: "Simulate"), systemImage: Wander.Icon.simulate)
                        .font(.wanderLabel)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .controlSize(.large)
                .disabled(!pairingExists || isBusy || isLoadingRoute)
            }
        } else {
            WanderPrimaryButton(title: "Set pin here", icon: Wander.Icon.setHere) {
                setPinToCenter()
            }
        }
    }

    private func setPinToCenter() {
        guard let center = visibleCenter else {
            alertTitle = "Pan the map"
            alertMessage = "Move the map so a spot is centered, then tap Set pin here."
            showAlert = true
            return
        }
        // The camera is already framed on this exact point — suppress the auto-recenter so the map
        // doesn't jump and reset the user's zoom the instant the pin lands.
        pinMovedFromMap = true
        applySelection(center)
    }

    /// Soft-ban cooldown a teleport to this pin would cost, shown only in PoGo (gs-loc) mode and only when
    /// there's a prior teleport to measure the jump from. Reuses the shipped CooldownPreview helper (the
    /// same distance→wait curve the PoGo tab's per-row estimates use), so the numbers can't disagree.
    /// Renders nothing on a first teleport (no origin) or for a preset with no distance cooldown.
    @ViewBuilder private func gslocCooldownHint(for coord: CLLocationCoordinate2D) -> some View {
        if gslocMode, CooldownPreview.status(for: coord) != nil {
            // The shared advisory row, like the other eight in these panels — this one was the last
            // hand-rolled copy, with its own glyph size and its own gap. It takes the content-based
            // initialiser because its body is a live countdown, not a fixed sentence.
            WanderPanelNote(status: .caution, icon: "hourglass") {
                CooldownPreviewLabel(destination: coord)
            }
        }
    }

    // MARK: - Cellular Mode (mobile data, no Wi-Fi)
    //
    // WHY THIS ROW EXISTS. lockdownd refuses the developer-tunnel connection while the device has
    // cellular and NO Wi-Fi *at connect time* — so on mobile data the plain Simulate button below
    // usually comes back with "Can't reach the device tunnel", and the only fix in the whole system is
    // a toggle no app is allowed to touch. lockdownd does NOT re-evaluate an established session
    // (confirmed on device, build 139: Airplane ON → connect → Airplane OFF, and the spoof HOLDS), so
    // the toggle is needed for the moment of connection and nothing more. That is exactly the shape of
    // thing a Shortcut can do and an app cannot, so this offers the sequence instead of failing.
    //
    // NOTHING HERE TOGGLES ANYTHING. The button runs a shortcut the user installed, only when the user
    // taps it. The copy states the cost up front — Shortcuts flashes, signal drops for up to about half
    // a minute — because a radio going dark unannounced reads as a crash.
    //
    // AND IT CAN GO WRONG. The shortcut turns the radio off and back on; an interrupted run never
    // reaches the second half. This row cannot be the thing that says so, because it is gated on
    // `isOnCellular`, which is FALSE in Airplane Mode. `CellularModeRun` + `CellularModeBanner` own
    // that recovery, from outside this gate.
    //
    // Deliberately does NOT replace the Simulate button: a user who already brought the tunnel up (by
    // hand, or by running this once already) should still be able to teleport without paying another
    // airplane cycle, and the shortcut's own check is "is there Wi-Fi", not "is the tunnel up".

    /// True only where Cellular Mode is the actual answer.
    ///
    /// The cellular question is asked ONCE, through `NetworkReachability.isOnCellular` — the app's
    /// existing NWPathMonitor flag, which already reads the UNDERLYING transport so Wander's own utun
    /// can't fool it, and which is false whenever Wi-Fi is present at all. No second way of asking.
    private var offersCellularMode: Bool {
        reachability.isOnCellular
        // gs-loc pushes through Shadowrocket's proxy, not the developer tunnel. Airplane Mode would
        // tear that proxy down, i.e. this would break PoGo mode rather than fix it.
        && !gslocMode
        && pairingExists
        // Something is already being simulated, so the tunnel is demonstrably up — there is nothing
        // for an airplane cycle to fix, and offering one would invite the user to break what works.
        && !hasActiveSimulation
        && !isRouteRunning
    }

    @ViewBuilder private func cellularModeControls(for coord: CLLocationCoordinate2D) -> some View {
        if offersCellularMode {
            WanderPanelNote(
                status: .caution,
                text: L("map.cellular.note",
                        fallback: "Mobile data, no Wi-Fi — iOS won't let the tunnel connect. Cellular Mode turns Airplane Mode on just long enough to get it up, sets this pin, then turns it back off. You're offline for up to about half a minute."),
                icon: "antenna.radiowaves.left.and.right"
            )
            Button {
                if cellularModeReady {
                    // THE SAME PAYWALL GATE AS THE SIMULATE BUTTON BELOW (`simulate()`). Cellular
                    // Mode is a teleport with an Airplane Mode dance wrapped around it; shipping it
                    // ungated made it a free door to the paid engine. The predicate lives in
                    // `CellularModeRun.isAllowedToStart` so the button and the retry in the recovery
                    // banner cannot drift; the trial is CHARGED where every other path charges it —
                    // at the confirmed teleport, in `WanderLocationIntent.teleport`.
                    guard CellularModeRun.isAllowedToStart else {
                        showPaywall = true
                        return
                    }
                    // Routes to whichever shortcut this user has: the one-action `Wander Airplane`
                    // file with `CellularModeSequence` conducting, or the legacy all-in-one shortcut.
                    // Both record the pin for the recovery card's "Try again".
                    ShortcutRunner.runCellularMode(latitude: coord.latitude, longitude: coord.longitude)
                } else {
                    showCellularSetup = true
                }
            } label: {
                Label(cellularModeReady
                      ? L("map.cellular.run", fallback: "Simulate — Cellular Mode")
                      : L("map.cellular.setup", fallback: "Set up Cellular Mode"),
                      systemImage: "airplane")
                    .font(.wanderLabel)
                    .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(Wander.brand)
            .controlSize(.large)
            .disabled(isBusy || isLoadingRoute || cellularSequence.isRunning)
            .opacity((isBusy || isLoadingRoute || cellularSequence.isRunning) ? 0.5 : 1)

            // WHAT THE OLD FLOW COULD NOT DO. While a Shortcut conducted the sequence, Wander was in
            // the background with nothing to say; the user watched a dead screen and a dark radio.
            // Wander conducts it now, so each step can name itself as it happens.
            if let status = cellularSequence.statusText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Wander.brand)
                    Text(status).wanderMicro()
                    Spacer(minLength: 0)
                    Button(L("action.cancel", fallback: "Cancel")) { cellularSequence.cancel() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Wander.brand)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if cellularModeReady {
                // HONEST NUMBER. The old copy said "a few seconds"; the run is a 4 s settle, up to
                // 12 s in `WanderTunnel.ensureStarted()`, up to ~12 s in the teleport, and the second
                // Shortcuts hop. Someone waiting on a call notices the difference between that and
                // "a few seconds", and a promise we break costs more than a number that sounds bad.
                Text(localized: "map.cellular.cost",
                     fallback: "Shortcuts flashes twice, and calls and data are off for up to about 30 seconds — usually less.")
                    .wanderMicro()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var routeControls: some View {
        VStack(spacing: MapModeChrome.rowSpacing) {
            Text(routeStatusText)
                .wanderDetail()

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
                    .tint(Wander.brand)
            } else if let routeSummaryText {
                // The focal value while a route is loaded. It now genuinely does match the Route
                // tab's ETA — the old comment claimed that while rendering a brand-blue subheadline
                // against that tab's title3, i.e. the two lines it said were the same were two
                // sizes and two colours apart. Both are `wanderMetric` at `.primary`.
                Text(routeSummaryText)
                    .font(.wanderMetric)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            routeAttributionLink

            if gslocMode {
                WanderPanelNote(
                    status: .caution,
                    text: "PoGo mode is teleport-only — route playback works in every other app and mode.",
                    icon: "hand.raised.fill"
                )
            }

            // THE SHARED CONTROL RHYTHM — `wanderLabel` on the title, `controlHeight` for the box,
            // `.controlSize(.large)` for the ~44pt tap target, `rowSpacing` between peers. Exactly
            // what the Route tab's Preview/Drive and Pause/Stop pairs use. This row was the last
            // action row in the app still drawing default-sized, content-hugging buttons, so
            // Teleport's route controls read as a smaller, different class of control from every
            // peer that does the same job one tab over.
            HStack(spacing: MapModeChrome.rowSpacing) {
                Button(action: clear) {
                    Text("Stop")
                        .font(.wanderLabel)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.bordered)
                .tint(Wander.blocked)
                .controlSize(.large)
                .disabled(!canStop)

                Button(action: simulateRoute) {
                    Text("Play Route")
                        .font(.wanderLabel)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(Wander.brand)
                .controlSize(.large)
                .disabled(
                    gslocMode ||
                    !pairingExists ||
                    isBusy ||
                    isLoadingRoute ||
                    isPrefetchingRouteSpeeds ||
                    routePlan == nil ||
                    routePlaybackSamples.isEmpty
                )

                Button(action: resetRouteSelection) {
                    Text("Reset")
                        .font(.wanderLabel)
                        .frame(maxWidth: .infinity).frame(height: MapModeChrome.controlHeight)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isBusy || isRouteRunning)
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        if !License.shared.isLicensed && !TrialManager.shared.canUse(.teleport) {
            showPaywall = true
            return
        }
        // "First fix is real" guardrail (OFF by default): seed the device's REAL location before the
        // teleport so the opening move isn't an instant impossible-speed delta. Fail-safe — a nil real
        // fix (flag off / denied / no fix) just falls straight through to the normal teleport. When
        // the flag is off (the default) this is a synchronous no-op and the path is unchanged.
        if RealGPSSeeder.isEnabled {
            let path = pairingFilePath
            Task {
                await realGPSSeeder.seedRealFirstFix(pairingFilePath: path)
                performSimulate(coord: coord)
            }
            return
        }
        performSimulate(coord: coord)
    }

    private func performSimulate(coord: CLLocationCoordinate2D) {
        // Bring Wander's own tunnel up before the first inject, so "connect the tunnel first" stops being
        // a manual step. No-ops instantly unless the user opted in (useOwnTunnel) and never runs while
        // gs-loc owns the VPN slot — see WanderTunnel.ensureStarted. If the tunnel is already carrying
        // traffic the probe returns immediately, so the normal path is unaffected.
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel),
           !GslocMode.enabled,
           !isTunnelSimEndpointReachable() {
            Task {
                await WanderTunnel.shared.ensureStarted()
                performSimulateInner(coord: coord)
            }
            return
        }
        performSimulateInner(coord: coord)
    }

    private func performSimulateInner(coord: CLLocationCoordinate2D) {
        SavedPlacesStore.recordRecent(coord, name: "Pinned location")
        locationInfo.refresh(lat: coord.latitude, lng: coord.longitude)

        // Smooth long jumps: when enabled and the move from the *current* spoofed
        // position is a big teleport, glide there over a few seconds so apps that
        // flag an impossible instantaneous jump see a fast-but-continuous move.
        // Small jumps (and every jump when the toggle is off) stay instant.
        if smoothLongJumps, let origin = currentSpoofedCoordinate {
            let jumpDistance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            let glideSamples = buildJumpGlideSamples(from: origin, to: coord)
            if jumpDistance > JumpSmoothingDefaults.jumpThresholdMeters, glideSamples.count > 1 {
                glideTeleport(to: coord, samples: glideSamples)
                return
            }
        }

        let stopGen = SimulationSession.shared.stopGeneration
        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                "Couldn't simulate location (error \(code)). Make sure LocalDevVPN is connected and Developer Mode is ON (Settings → Privacy & Security → Developer Mode). On cellular with no Wi‑Fi? Connect LocalDevVPN first, then turn Airplane Mode ON (you can turn it back OFF after) — that usually fixes it."
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
            // A Stop/Panic landed while this teleport was in flight — don't revive the hold loop
            // (which would re-freeze the fake location right after the user reverted).
            guard SimulationSession.shared.stopGeneration == stopGen else { return }
            routePlaybackCoordinate = nil
            beginBackgroundTask()
            startResendLoop(with: coord)
            SimulationSession.shared.started()
            SimulationSession.shared.noteTeleport(to: coord)
            if !License.shared.isLicensed { TrialManager.shared.chargeTeleport() }
        }
    }

    /// The location currently being reported to the device: the steady teleport
    /// position, or the live route-playback marker if a route/glide is running.
    private var currentSpoofedCoordinate: CLLocationCoordinate2D? {
        simulatedCoordinate ?? routePlaybackCoordinate
    }

    /// Play a fast glide `origin → coord` via the route-playback machinery, then
    /// settle into the normal resend loop at the destination. Reusing
    /// `routePlaybackTask` means Stop/panic (which cancels it via
    /// `.stopSimulationRequested`) already interrupts the glide cleanly.
    private func glideTeleport(to coord: CLLocationCoordinate2D, samples: [RoutePlaybackSample]) {
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                "Couldn't simulate location (error \(code)). Make sure LocalDevVPN is connected and Developer Mode is ON (Settings → Privacy & Security → Developer Mode). On cellular with no Wi‑Fi? Connect LocalDevVPN first, then turn Airplane Mode ON (you can turn it back OFF after) — that usually fixes it."
            },
            operation: { locationUpdateCode(for: samples[0].coordinate) }
        ) {
            beginBackgroundTask()
            SimulationSession.shared.started()
            SimulationSession.shared.noteTeleport(to: coord)
            if !License.shared.isLicensed { TrialManager.shared.chargeTeleport() }
            simulatedCoordinate = nil
            routePlaybackSamples = samples
            routePlaybackCoordinate = samples[0].coordinate
            startRoutePlayback()
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              routePlan != nil,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy else {
            return
        }
        if !License.shared.isLicensed && !TrialManager.shared.canUse(.route) {
            showPaywall = true
            return
        }
        stopResendLoop()
        cancelRoutePlayback(resetMarker: false)
        runLocationCommand(
            errorTitle: "Route Simulation Failed",
            errorMessage: { code in
                "Couldn't start the route (error \(code)). Make sure LocalDevVPN is connected and Developer Mode is ON (Settings → Privacy & Security → Developer Mode). On cellular with no Wi‑Fi? Connect LocalDevVPN first, then turn Airplane Mode ON (you can turn it back OFF after) — that usually fixes it."
            },
            operation: { locationUpdateCode(for: firstCoordinate) }
        ) {
            beginBackgroundTask()
            SimulationSession.shared.started()
            if !License.shared.isLicensed { TrialManager.shared.chargeRoute() }
            simulatedCoordinate = nil
            routePlaybackCoordinate = firstCoordinate
            locationInfo.refresh(lat: firstCoordinate.latitude, lng: firstCoordinate.longitude)
            startRoutePlayback()
        }
    }

    /// Where this view hands STARTING work to the location FFI — teleport, glide and route start —
    /// which is why the pending-tunnel-disconnect cancellation lives at this level rather than in
    /// each of them (see `LocationSimulationCommandQueue.submit`).
    ///
    /// ⚠️ STOP NO LONGER COMES THROUGH HERE. `clear()` enqueues its own `submitClear` directly and
    /// never sets `isBusy`, because everything in this function — the busy latch, the watchdog, the
    /// DDI auto-mount retry — is machinery for a command that OPENS a session, and every bit of it
    /// was a way for a Stop to be delayed or disabled. See `clear()`.
    ///
    /// - Parameter isClear: enqueue via `submitClear`, i.e. WITHOUT cancelling a pending
    ///   auto-disconnect. Unused today (see above); kept because the distinction is load-bearing and
    ///   a future closing command must not silently get the opening behaviour.
    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        isClear: Bool = false,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        // Claim the controls for THIS command. See `locationCommandToken`.
        locationCommandToken &+= 1
        let token = locationCommandToken
        armBusyWatchdog(token: token)
        // Capture on the caller (main) for the mount guard below — a simulation that is ALREADY running
        // proves the developer image is mounted, so a remount can only do harm.
        let simulationWasActive = hasActiveSimulation
        let enqueue = isClear ? LocationSimulationCommandQueue.submitClear
                              : LocationSimulationCommandQueue.submit
        enqueue {
            var code = operation()
            // Auto-recover the most common failure (error 3): the tunnel is up but the device's
            // developer image isn't mounted yet. The built-in auto-mount only fires for Wander's OWN
            // tunnel, so LocalDevVPN users (free installs) never get it — their first teleport fails.
            // Mount it here (the DDI files are downloaded at launch), then retry the command once.
            //
            // GUARDED ON `!simulationWasActive` (build 128+). This block fires on ANY non-zero code, not
            // only the "not mounted" one it was written for. So a TRANSIENT failure during a LIVE spoof —
            // exactly what the cellular re-attach after turning Airplane Mode off produces (it surfaces as
            // error 9) — used to trigger a full personalized DDI mount underneath a running simulation.
            // Mounting re-initialises the device's developer services, which drops the location simulation
            // the mount was supposed to be helping: the spoof reverted to the real location, and the retry
            // then "succeeded" on a session that no longer owned the fix. Routes died the same way, since
            // they run through this same helper. A live simulation cannot need a mount, so skip it.
            var mountFailure: String? = nil
            if code != 0, !simulationWasActive, isPairing(), !isMounted() {
                let mountError = mountPersonalDDI(
                    imagePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path,
                    trustcachePath: URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path,
                    manifestPath: URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path
                )
                if mountError == nil {
                    MountingProgress.shared.checkforMounted()
                    code = operation()
                } else {
                    // Mounting itself failed — remember why, so the alert reports the ACTUAL cause
                    // (missing/corrupt DDI, tunnel dropped mid-mount) instead of the misleading raw
                    // "error 3" the operation would keep returning.
                    mountFailure = mountError
                }
            }
            DispatchQueue.main.async {
                // Somebody else owns the controls now — a newer command, or a Stop that unlatched
                // them. This outcome is stale and must not re-disable or re-alert over them.
                guard locationCommandToken == token else { return }
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else if LocationSimulationOutcome.isTunnelUnreachable(code) {
                    // NAME THE CAUSE. A bounded probe established that the tunnel endpoint isn't
                    // answering before anything was dialled, so this is a fact, not the old paragraph
                    // of guesses ending in "(error 3)". Same words as the tunnel chip.
                    alertTitle = LocationSimulationOutcome.tunnelDownTitle
                    alertMessage = LocationSimulationOutcome.tunnelDownMessage
                    showAlert = true
                } else {
                    alertTitle = errorTitle
                    if let mountFailure {
                        alertMessage = "Your device's Developer Disk Image couldn't be mounted (\(mountFailure)). Make sure LocalDevVPN is connected, then fully reopen Wander so it can re-fetch the developer image, and try again."
                    } else {
                        alertMessage = errorMessage(code)
                    }
                    showAlert = true
                }
            }
        }
    }

    /// How long a location command may hold the controls without reporting back.
    ///
    /// Generous on purpose: a healthy rebuild over a live tunnel finishes in a second or two, and a
    /// dead one now fails inside the probe's own bound, so nothing legitimate should ever reach this.
    /// It exists as the backstop for the class of bug this whole change is about — a control that is
    /// disabled forever is never acceptable, whatever went wrong underneath it.
    private static let busyWatchdogSeconds: TimeInterval = 20

    /// Release the controls if `token`'s command has not reported back in time, and say why.
    ///
    /// Deliberately does NOT bump the token: if that command is merely slow and lands afterwards, it
    /// still owns the controls and its result is still honoured — a late SUCCESS must arm the hold
    /// loop, or the device would be spoofed with nothing keeping the fix warm.
    private func armBusyWatchdog(token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyWatchdogSeconds) {
            guard locationCommandToken == token, isBusy else { return }
            isBusy = false
            alertTitle = LocationSimulationOutcome.tunnelStalledTitle
            alertMessage = LocationSimulationOutcome.tunnelStalledMessage
            showAlert = true
        }
    }

    /// Stop.
    ///
    /// ── HOW STOP IS GUARANTEED TO RESPOND ────────────────────────────────────────────────────────
    /// It is two halves, and only the second one can ever be delayed.
    ///
    ///   1. THE LOCAL HALF runs SYNCHRONOUSLY on the main thread, unconditionally, before anything is
    ///      enqueued. It stops re-injecting, tears the run state down, releases the keep-alive, ends
    ///      the session and unlatches `isBusy`. Not one line of it touches the serial location queue,
    ///      so no state of that queue — backed up, busy, or wedged — can stop the button from working.
    ///      This is what "Stop always responds" means concretely.
    ///   2. THE DEVICE HALF is enqueued. Clearing the fix ON THE DEVICE requires the tunnel, so it
    ///      inherently cannot be made independent of the transport — but it does not need to be:
    ///      the DVT location session is connection-scoped, so if the tunnel is down there is nothing
    ///      live left to clear and the device has already reverted to real GPS. Being late here costs
    ///      nothing the user can see.
    ///
    /// It also no longer returns early when `pairingExists` is false. Standing the local session down
    /// is exactly as valid without a pairing file — and bailing first was another way for a tap to
    /// look like a no-op.
    private func clear() {
        // ── 1. LOCAL, SYNCHRONOUS, UNCONDITIONAL ────────────────────────────────────────────────
        stopResendLoop()                     // also sets suppressResends + clears simulatedCoordinate
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        cancelRoutePlayback(resetMarker: true)
        locationInfo.clear()
        // Stop OUTRANKS any command still holding the controls. Taking the token away both releases
        // the row now and discards that command's late outcome, so a teleport that reports back after
        // the user stopped cannot re-disable the buttons or re-alert over the stop.
        locationCommandToken &+= 1
        isBusy = false
        endBackgroundTask()
        BackgroundLocationManager.shared.requestStop()

        // ── 2. DEVICE HALF — needs the tunnel, so it is enqueued and never gated on ──────────────
        // Ordering is unchanged from before and from `SimulationSession.stopAll()`: the clear is
        // ENQUEUED first, and `markStopped()` (which arms the tunnel auto-disconnect) comes after, so
        // the scheduler's drain still cannot start its grace timer ahead of the clear it is waiting on.
        if pairingExists {
            LocationSimulationCommandQueue.submitClear {
                let code = clear_simulated_location()
                // Every return path of that call has already freed the FFI session, so no handle is
                // open at this instant. Recorded on the location queue, where the tunnel's
                // auto-disconnect reads it. See LocationSessionActivity.
                LocationSessionActivity.noteSessionClosed()
                DispatchQueue.main.async {
                    // Only a REAL failure is worth an alert. "The tunnel was down" is not one: the
                    // stop already happened locally and the device had nothing of ours left to clear,
                    // so the old "Clear Failed (error 12)" reported a successful stop as broken.
                    guard code != 0, !LocationSimulationOutcome.isTunnelUnreachable(code) else { return }
                    alertTitle = "Clear Failed"
                    alertMessage = "Could not clear simulated location (error \(code))."
                    showAlert = true
                }
            }
        }

        // Ends the session and arms the tunnel auto-disconnect under its existing conditions (a human
        // asked, and something was actually running). Now runs on EVERY stop rather than only when
        // the device clear came back 0 — with the tunnel down that success handler never ran, so the
        // session stayed "active" forever, the chip stayed up and the keep-alive was never released.
        SimulationSession.shared.markStopped()
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
        // Hold the app awake for the WHOLE spoof, not just this task.
        //
        // beginBackgroundTask buys seconds, then iOS suspends us — and per Apple TN2277 the system
        // "may choose to reclaim resources out from underneath a network socket used by the app",
        // which closes the DVT connection holding the fake location. On cellular that is terminal,
        // because lockdownd refuses the reconnect (it cannot tell our loopback TUN from pdp_ip0), so
        // the spoof is gone until Airplane Mode comes back. This is why it advances only while Wander
        // is frontmost.
        //
        // Continuous location updates are one of the two things that actually keep an app running
        // (declaring UIBackgroundModes alone grants nothing). requestStop() was already being called
        // on stop/clear WITHOUT a matching requestStart() anywhere in this view — so the location
        // keep-alive has never once started for a teleport, route, or walk.
        BackgroundLocationManager.shared.requestStart()
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        // Fresh breathing state per hold so the mean-reverting walk starts centered on this anchor
        // (and never carries drift over from a previous hold).
        breathingJitter = BreathingJitter()
        LocationSimulationCommandQueue.suppressResends = false   // a new hold re-enables re-injection
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard let simulatedCoordinate else { return }
            // "Hold perfectly still" (frozen hold) disables the breathing jitter so a held
            // location is rock-steady. Otherwise we drive the injected point through the
            // mean-reverting BreathingJitter so a parked spot wanders ~1–3 m and drifts back
            // instead of teleporting a fresh random metre each tick (which reads as micro-jumps).
            // The underlying `simulatedCoordinate` anchor stays CLEAN — the wander lives only in
            // the breathing state — so the held point never drifts away over a long hold.
            //
            // NOTE: the iOS injection FFI is lat/lng ONLY (no horizontalAccuracy/altitude field),
            // so we can only breathe POSITIONALLY here — accuracy-radius variation isn't carryable.
            let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
            // Coarse offset is applied centrally in locationUpdateCode(for:), so we only
            // decide jitter here.
            let target: CLLocationCoordinate2D
            if !frozen && UserDefaults.standard.bool(forKey: "jitterEnabled") {
                target = breathingJitter?.next(around: simulatedCoordinate) ?? simulatedCoordinate
            } else {
                target = simulatedCoordinate
            }
            LocationSimulationCommandQueue.submit {
                // A Stop/Clear may have landed after this tick was queued — don't re-inject then.
                if LocationSimulationCommandQueue.suppressResends { return }
                _ = locationUpdateCode(for: target)
            }
        }
    }

    private func stopResendLoop() {
        LocationSimulationCommandQueue.suppressResends = true   // no queued resend may re-inject now
        resendTimer?.invalidate()
        resendTimer = nil
        simulatedCoordinate = nil
        breathingJitter = nil
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        // Remember where the pin was so the user can undo this move. Skip if it
        // isn't actually changing (avoids a no-op undo).
        if let current = self.coordinate,
           CoordinateSnapshot(current) != CoordinateSnapshot(coordinate) {
            previousCoordinate = current
        }
        self.coordinate = coordinate
        locationInfo.refresh(lat: coordinate.latitude, lng: coordinate.longitude)
    }

    // MARK: - GPX export

    /// The route points available to export (empty if there's no route).
    private var exportableRoute: [CLLocationCoordinate2D] {
        if !routePlaybackSamples.isEmpty {
            return routePlaybackSamples.map { $0.coordinate }
        }
        var endpoints: [CLLocationCoordinate2D] = []
        if let start = routeStartCoordinate { endpoints.append(start) }
        if let end = routeEndCoordinate { endpoints.append(end) }
        return endpoints.count >= 2 ? endpoints : []
    }

    /// Waypoints to export when there's no route: the current pin, plus saved
    /// and recent places.
    private var exportableWaypoints: [(name: String, coordinate: CLLocationCoordinate2D)] {
        var result: [(String, CLLocationCoordinate2D)] = []
        if let coordinate {
            result.append(("Current pin", coordinate))
        }
        for bookmark in bookmarks {
            result.append((bookmark.name, bookmark.coordinate))
        }
        for recent in SavedPlacesStore.exportRecents() {
            result.append((recent.name, recent.coordinate))
        }
        return result
    }

    /// Whether there's anything at all to export.
    private var canExportGPX: Bool {
        !exportableRoute.isEmpty || !exportableWaypoints.isEmpty
    }

    private func prepareGPXExport() {
        let route = exportableRoute
        if route.count >= 2 {
            gpxDocument = GPXDocument(text: GPXBuilder.makeGPX(route: route))
        } else {
            gpxDocument = GPXDocument(text: GPXBuilder.makeGPX(waypoints: exportableWaypoints))
        }
        showGPXExporter = true
    }

    private static func gpxTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Revert the pin to the location immediately before the last move.
    private func revertToPrevious() {
        guard !isRouteRunning, let target = previousCoordinate else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        previousCoordinate = nil
        self.coordinate = target
        locationInfo.refresh(lat: target.latitude, lng: target.longitude)
    }

    private func resetRouteSelection() {
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeRequestID = UUID()
        setRoutePlan(nil)
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
    }

    private func startRoutePlayback() {
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate = routePlaybackSamples.first?.coordinate

            for sample in routePlaybackSamples.dropFirst() {
                try? await Task.sleep(for: .seconds(sample.delayFromPrevious))
                guard !Task.isCancelled else { return }

                // While the route drives the location WE are the sole writer. Re-assert suppression of
                // the Map tab's teleport "hold" resend every step so nothing (e.g. an auto-walk arrival
                // on the Joystick tab posting .holdLocationRequested) can silently re-enable it and
                // re-inject a STALE point every 4 s that rubber-bands us backward mid-route — the
                // impossible backward jump that trips PoGo's "Failed to detect location (12)".
                // simulateRoute()/glideTeleport() already cleared it at start; this keeps it clear.
                LocationSimulationCommandQueue.suppressResends = true

                let code = await sendLocationUpdate(for: sample.coordinate)
                guard code == 0 else {
                    await MainActor.run {
                        routePlaybackTask = nil
                        routePlaybackCoordinate = lastSuccessfulCoordinate
                        if let lastSuccessfulCoordinate {
                            startResendLoop(with: lastSuccessfulCoordinate)
                        }
                        alertTitle = "Route Simulation Failed"
                        alertMessage = "Could not continue route simulation (error \(code))."
                        showAlert = true
                    }
                    return
                }

                lastSuccessfulCoordinate = sample.coordinate
                await MainActor.run {
                    routePlaybackCoordinate = sample.coordinate
                }
            }

            await MainActor.run {
                routePlaybackTask = nil
                if let lastSuccessfulCoordinate {
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                }
            }
        }
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.submit {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        // "Approximate location" (privacy): shift every injected fix by a stable
        // per-session offset (~3–5 km) so the reported spot shares a neighborhood, not
        // the exact target. No-op when the toggle is off.
        let coordinate = CoarseLocation.apply(coordinate)
        return simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath)
    }
}

// The two sheets that used to live down here are GONE, not orphaned:
//
//   RouteSearchSheet — a start/end place picker reached from the old toolbar. The Route tab is a
//                      whole tab of exactly this, with more in it (multiple stops, reordering,
//                      transport modes, Preview/Drive), so this was a smaller second copy of the
//                      app's own navigation hiding behind a glyph.
//   BookmarksView    — a plain list of `locationBookmarks`. The Places screen lists the SAME store
//                      (More → Places → "Saved"), with search, folders, tags, sharing and delete
//                      on top of it.
//
// `RouteSearchSelection` above survives on purpose: imported coordinates still become a route
// start/end through it (see `applyImportedCoordinates`).
