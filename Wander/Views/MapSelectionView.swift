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

private enum RouteSearchField {
    case start
    case end
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

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct LocationSimulationView: View {
    @State private var coordinate: CLLocationCoordinate2D?
    @AppStorage("mapStyleMode") private var mapStyleModeRaw = MapStyleMode.standard.rawValue
    /// "Smooth long jumps": when on, a teleport farther than the threshold from
    /// the current spoofed position eases over a few seconds instead of hopping.
    @AppStorage("smoothLongJumps") private var smoothLongJumps = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleCenter: CLLocationCoordinate2D?
    // Debounced background task that warms the offline CARTO tile cache for wherever the user is
    // browsing on the (online, Apple) map — so flipping to airplane mode still shows a map instead
    // of a black screen. The online map is Apple's and doesn't fill the CARTO cache, which is why
    // "browse then airplane mode" went dark.
    @State private var tilePrefetchTask: Task<Void, Never>?
    @StateObject private var currentLocation = CurrentLocation()
    @StateObject private var locationInfo = LocationInfoService()
    @ObservedObject private var reachability = NetworkReachability.shared

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var showPaywall = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var isImportingCoordinates = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var showCoordinateImporter = false
    @State private var streetViewTarget: CoordinateSnapshot?
    @State private var showOfflineMaps = false
    // Region for the offline (cached-tile) map shown automatically when the device has no network.
    @State private var offlineRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        latitudinalMeters: 2000, longitudinalMeters: 2000)
    @State private var showRouteSearch = false
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

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
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
        return "Plan a route from the toolbar."
    }

    private var routeAttributionLink: some View {
        Link(
            "Speed limit data © OpenStreetMap contributors (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var mapStyleMode: MapStyleMode {
        MapStyleMode(rawValue: mapStyleModeRaw) ?? .standard
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

    private var mapStyleSwitcher: some View {
        Menu {
            Picker("Map style", selection: $mapStyleModeRaw) {
                ForEach(MapStyleMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode.rawValue)
                }
            }
        } label: {
            Image(systemName: mapStyleMode.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Wander.brand)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
        .accessibilityLabel(L("map.style.switch", fallback: "Map style"))
    }

    /// The primary (online) map — Apple MapKit with pin/route markers + style switching + center
    /// tracking. Extracted from `body` so the ZStack stays within the type-checker's limits.
    @ViewBuilder private var onlineMap: some View {
        MapReader { proxy in
            Map(position: $position) {
                if hasRouteContext {
                    if let routePolyline {
                        MapPolyline(routePolyline)
                            .stroke(.blue.opacity(0.8), lineWidth: 5)
                    }
                    if let routeStartCoordinate {
                        Marker("Start", coordinate: routeStartCoordinate)
                            .tint(.green)
                    }
                    if let routeEndCoordinate {
                        Marker("End", coordinate: routeEndCoordinate)
                            .tint(.red)
                    }
                    if let routePlaybackCoordinate {
                        Marker("Current", coordinate: routePlaybackCoordinate)
                            .tint(.blue)
                    }
                } else if let coordinate {
                    Marker("Pin", coordinate: coordinate)
                        .tint(.red)
                }
            }
            .mapStyle(mapStyleMode.mapStyle)
            .mapControls {
                MapCompass()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleCenter = context.region.center
                // Warm the offline cache for the area being viewed. Debounced (wait for the camera to
                // settle), online-only, and only when zoomed to neighbourhood/city level so a wide
                // view can't queue thousands of tiles. Skips already-cached tiles, so it's cheap.
                let region = context.region
                tilePrefetchTask?.cancel()
                tilePrefetchTask = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if Task.isCancelled { return }
                    guard await MainActor.run(body: { NetworkReachability.shared.isOnline }) else { return }
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
            onRegionChange: { region in
                visibleCenter = region.center
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
        ZStack(alignment: .bottom) {
            Group {
                if reachability.isOnline {
                    onlineMap
                } else {
                    offlineMap
                }
            }
                .overlay(alignment: .center) {
                    if !hasRouteContext && !hasActiveSimulation { MapCrosshair() }
                }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        let region = MKCoordinateRegion(
                            center: new.coordinate,
                            latitudinalMeters: 1000,
                            longitudinalMeters: 1000
                        )
                        position = .region(region)
                        offlineRegion = region
                    }
                }

            VStack(spacing: 0) {
                Spacer()

                WanderCard {
                    VStack(spacing: 12) {
                        if !hasRouteContext {
                            AddressSearchBar(
                                placeholder: "Search, coordinates, or Plus Code",
                                mapCenter: visibleCenter
                            ) { coord, _ in
                                applySelection(coord)
                            }

                            nlTeleportBar
                        }

                        if isImportingCoordinates {
                            ProgressView("Importing coordinates…")
                                .font(.footnote)
                        }

                        if hasRouteContext {
                            routeControls
                        } else {
                            pinControls
                        }
                    }
                    .hugScrollCard(maxHeight: UIScreen.main.bounds.height * 0.5)
                }
            }

            VStack(spacing: 6) {
                if !reachability.isOnline {
                    offlinePill
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                LocationInfoCard(service: locationInfo)
                    .padding(.top, reachability.isOnline ? 8 : 0)
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.25), value: locationInfo.info)
            .animation(.easeInOut(duration: 0.25), value: reachability.isOnline)

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }
                .accessibilityLabel(L("map.bookmarks", fallback: "Bookmarks"))

                Button {
                    showRouteSearch = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .accessibilityLabel(L("map.route_search", fallback: "Search routes"))
                .disabled(isBusy || isRouteRunning)

                Button {
                    showCoordinateImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(isBusy || isRouteRunning || isImportingCoordinates)
                .accessibilityLabel("Import Coordinates")

                Button {
                    prepareGPXExport()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(isBusy || isImportingCoordinates || !canExportGPX)
                .accessibilityLabel("Export GPX")

                // Offline Maps — a free, self-contained OSM tile-cache screen (parity with
                // Android). Doesn't affect the online map above; just opens its own sheet.
                Button {
                    showOfflineMaps = true
                } label: {
                    Image(systemName: "map.circle")
                }
                .accessibilityLabel(L("offline.maps.open", fallback: "Offline Maps"))
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Save Bookmark", isPresented: $showSaveBookmark) {
            TextField("Name", text: $newBookmarkName)
            Button("Save") { addBookmark() }
            Button("Cancel", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("Enter a name for this location.")
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection
            ) { startSelection, endSelection in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                refreshRoute()
            }
        }
        // Item-driven so Street View can ONLY open for a concrete, chosen pin — never on entry
        // with a stale/ambient coordinate. Set by the Street View button from the selected pin.
        .sheet(item: $streetViewTarget) { target in
            StreetViewSheet(coordinate: target.coordinate)
        }
        .sheet(isPresented: $showOfflineMaps) {
            OfflineMapsSheet()
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
            if coordinate == nil && simulatedCoordinate == nil && !hasRouteContext {
                position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 2500, longitudinalMeters: 2500))
            }
        }
        .onDisappear {
            // Switching tabs shouldn't tear down a live spoof/route — keep it running and
            // let the explicit Stop button (or global stop) end it. Only clean up when idle.
            guard !SimulationSession.shared.isActive else { return }
            routeLoadTask?.cancel()
            routeLoadTask = nil
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
        }
        .sheet(isPresented: $showPaywall) { PaywallView(onClose: { showPaywall = false }) }
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

        routeLoadTask?.cancel()
        routeLoadTask = nil
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
    private var nlTeleportBar: some View {
        HStack(spacing: 8) {
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
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            Text(String(format: "%.5f,  %.5f", coord.latitude, coord.longitude))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isRouteRunning)

                // Undo the last move/teleport, reverting to the previous pin.
                // Only shown once there's something to revert to.
                if previousCoordinate != nil {
                    Button {
                        revertToPrevious()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 34, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(hasActiveSimulation || isBusy || isRouteRunning)
                    .accessibilityLabel(L("map.undo_move", fallback: "Undo move"))
                }

                // Re-position the pin to the crosshair (map center). Disabled while
                // a simulation is live — Stop first, then move.
                Button {
                    setPinToCenter()
                } label: {
                    Label(L("map.move_here", fallback: "Move here"), systemImage: Wander.Icon.setHere)
                        .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(hasActiveSimulation || isBusy)
            }

            // Street View — Pro-only (it hits the paid Google Maps API). Shown to free users too
            // (with a lock affordance) so they discover it; tapping opens the paywall. The Maps key
            // is fetched from the Worker on open (Pro + quota gated) — it's no longer bundled.
            Button {
                if !License.shared.isLicensed { showPaywall = true } else if let coordinate { streetViewTarget = CoordinateSnapshot(coordinate) }
            } label: {
                Label(L("map.street_view", fallback: "Street View"),
                      systemImage: License.shared.isLicensed ? "binoculars.fill" : "lock.fill")
                    .frame(maxWidth: .infinity).frame(height: 30)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            HStack(spacing: 10) {
                Button(action: clear) {
                    Label(L("map.stop", fallback: "Stop"), systemImage: Wander.Icon.stop)
                        .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
                .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button(action: simulate) {
                    Label(L("map.simulate", fallback: "Simulate"), systemImage: Wander.Icon.simulate)
                        .font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 30)
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
        applySelection(center)
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute || isPrefetchingRouteSpeeds {
                ProgressView()
                    .controlSize(.small)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            routeAttributionLink

            HStack(spacing: 12) {
                Button("Stop", action: clear)
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!pairingExists || isBusy || !hasActiveSimulation)

                Button("Play Route", action: simulateRoute)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !pairingExists ||
                        isBusy ||
                        isLoadingRoute ||
                        isPrefetchingRouteSpeeds ||
                        routePlan == nil ||
                        routePlaybackSamples.isEmpty
                    )

                Button("Reset", action: resetRouteSelection)
                    .buttonStyle(.bordered)
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

        runLocationCommand(
            errorTitle: "Simulation Failed",
            errorMessage: { code in
                "Couldn't simulate location (error \(code)). Make sure LocalDevVPN is connected. On cellular with no Wi‑Fi? Turn Airplane Mode ON, connect LocalDevVPN, then turn Airplane Mode OFF — that usually fixes it."
            },
            operation: { locationUpdateCode(for: coord) }
        ) {
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
                "Couldn't simulate location (error \(code)). Make sure LocalDevVPN is connected. On cellular with no Wi‑Fi? Turn Airplane Mode ON, connect LocalDevVPN, then turn Airplane Mode OFF — that usually fixes it."
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
                "Couldn't start the route (error \(code)). Make sure LocalDevVPN is connected. On cellular with no Wi‑Fi? Turn Airplane Mode ON, connect LocalDevVPN, then turn Airplane Mode OFF — that usually fixes it."
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

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        LocationSimulationCommandQueue.shared.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    private func clear() {
        guard pairingExists, !isBusy else { return }
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        cancelRoutePlayback(resetMarker: true)
        stopResendLoop()
        locationInfo.clear()
        runLocationCommand(
            errorTitle: "Clear Failed",
            errorMessage: { code in "Could not clear simulated location (error \(code))." },
            operation: clear_simulated_location
        ) {
            endBackgroundTask()
            BackgroundLocationManager.shared.requestStop()
            SimulationSession.shared.markStopped()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard let simulatedCoordinate else { return }
            // "Hold perfectly still" (frozen hold) disables the breathing/idle jitter so a
            // held location is rock-steady. Otherwise the existing jitter behavior applies.
            let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
            // Coarse offset is applied centrally in locationUpdateCode(for:), so we only
            // decide jitter here.
            let target = (!frozen && UserDefaults.standard.bool(forKey: "jitterEnabled"))
                ? LocationJitter.apply(simulatedCoordinate)
                : simulatedCoordinate
            LocationSimulationCommandQueue.shared.async {
                _ = locationUpdateCode(for: target)
            }
        }
    }

    private func stopResendLoop() {
        resendTimer?.invalidate()
        resendTimer = nil
        simulatedCoordinate = nil
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
        routeLoadTask?.cancel()
        routeLoadTask = nil
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

    private func refreshRoute() {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        setRoutePlan(nil)
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.requestsAlternateRoutes = false
        request.transportType = .automobile

        routeLoadTask = Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled else { return }
                guard let route = response.routes.first else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No drivable route was returned."]
                    )
                }

                let displayCoordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: RouteSimulationDefaults.pathSamplingDistance
                )
                let routePlan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: route.distance,
                    expectedTravelTime: route.expectedTravelTime
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    self.setRoutePlan(routePlan)
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = true
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                }

                let fallbackSpeed = route.expectedTravelTime > 0
                    ? route.distance / route.expectedTravelTime
                    : 13.4

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    routeSpeedPrefetchTask?.cancel()
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
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = false
                    alertTitle = "Route Failed"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRoutePlayback() {
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate = routePlaybackSamples.first?.coordinate

            for sample in routePlaybackSamples.dropFirst() {
                try? await Task.sleep(for: .seconds(sample.delayFromPrevious))
                guard !Task.isCancelled else { return }

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
            LocationSimulationCommandQueue.shared.async {
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

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: RouteSearchSelection?
    let initialEnd: RouteSearchSelection?
    let onApply: (RouteSearchSelection, RouteSearchSelection) -> Void

    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: RouteSearchField?

    init(
        initialStart: RouteSearchSelection?,
        initialEnd: RouteSearchSelection?,
        onApply: @escaping (RouteSearchSelection, RouteSearchSelection) -> Void
    ) {
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onApply = onApply
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start:
            return startCompleter.results
        case .end:
            return endCompleter.results
        case .none:
            return []
        }
    }

    private var canApply: Bool {
        startSelection != nil && endSelection != nil && !isResolvingSelection
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                routeField(
                    title: "Start",
                    icon: "circle.fill",
                    tint: .green,
                    text: $startQuery,
                    selection: startSelection,
                    field: .start
                )

                routeField(
                    title: "End",
                    icon: "flag.checkered.circle.fill",
                    tint: .red,
                    text: $endQuery,
                    selection: endSelection,
                    field: .end
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isResolvingSelection {
                    ProgressView("Resolving location…")
                        .font(.footnote)
                } else if !activeResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(activeResults.enumerated()), id: \.element) { index, result in
                                Button {
                                    resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)

                                if index < activeResults.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("Search for a start and destination to build the route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("Simulate Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Route") {
                        guard let startSelection, let endSelection else { return }
                        onApply(startSelection, endSelection)
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if startSelection == nil {
                focusedField = .start
            } else if endSelection == nil {
                focusedField = .end
            }
        }
    }

    private func routeField(
        title: String,
        icon: String,
        tint: Color,
        text: Binding<String>,
        selection: RouteSearchSelection?,
        field: RouteSearchField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                TextField(title, text: text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        errorMessage = nil
                        update(query: newValue, for: field)
                    }
                    .onSubmit {
                        if field == .start {
                            focusedField = .end
                        } else {
                            focusedField = nil
                        }
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func update(query: String, for field: RouteSearchField) {
        switch field {
        case .start:
            if query != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: query)
        case .end:
            if query != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: query)
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? .start
        let request = MKLocalSearch.Request(completion: completion)
        isResolvingSelection = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isResolvingSelection = false

                guard let item = response?.mapItems.first else {
                    errorMessage = error?.localizedDescription ?? "Could not resolve that location."
                    return
                }

                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                let selection = RouteSearchSelection(title: title, coordinate: item.placemark.coordinate)

                switch field {
                case .start:
                    startSelection = selection
                    startQuery = title
                    startCompleter.results = []
                    focusedField = .end
                case .end:
                    endSelection = selection
                    endQuery = title
                    endCompleter.results = []
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks",
                        systemImage: "bookmark.slash",
                        description: Text("Drop a pin on the map and tap the bookmark icon to save a location.")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
