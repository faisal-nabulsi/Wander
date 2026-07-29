//
//  WanderShareLink.swift
//  Wander
//
//  Encode/decode for the SHARE LINK — the thing people actually paste into Discord when they
//  trade a spot or a route. Value-level code on purpose: no UI, no stores, so both directions
//  (build a link / read a link) are trivially testable.
//
//  THE WIRE CONTRACT IS SHARED WITH ANDROID AND MUST NOT DRIFT. A share is one URL in two
//  interchangeable forms — the app form `wander://share?…` and the web form
//  `https://wanderspoofer.com/go?…` carrying the SAME query (the web form is what survives being
//  pasted into a chat app; it hands off to the app when installed):
//
//    SPOT   ?t=s&lat=<%.5f>&lng=<%.5f>&n=<percent-encoded name, optional, ≤60 chars>
//    ROUTE  ?t=r&n=<percent-encoded name, optional>&d=<payload>
//           payload = base64url( raw-DEFLATE( UTF-8 JSON ) ), '=' padding stripped
//           JSON    = {"v":1,"p":[lat0,lng0,lat1,lng1,…]}   // FLAT, alternating, 5 decimals
//
//  Two rules exist because getting them wrong breaks the OTHER platform's import, silently:
//   • every number is formatted with an INVARIANT locale — a device on a comma-decimal locale
//     must still emit "35.65858", never "35,65858";
//   • the JSON is assembled by hand rather than through JSONSerialization, so the bytes we
//     compress are fully determined by the contract instead of by a serializer's float printing.
//     Decoding stays permissive (JSONDecoder), so anything Android emits that MEANS the same
//     thing still reads.
//
//  Unknown/extra query params are ignored, so a future field can be added without breaking today's
//  builds. Everything else is validated hard and rejected whole: a share link comes from a stranger,
//  and a half-imported route is worse than no route.
//

import Foundation
import Compression
import CoreLocation

// MARK: - Decoded payloads

/// A shared single place.
struct WanderSharedSpot {
    /// Optional — a link may carry only coordinates.
    var name: String?
    var coordinate: CLLocationCoordinate2D
}

/// A shared ordered path.
struct WanderSharedRoute {
    var name: String?
    var coordinates: [CLLocationCoordinate2D]
}

/// What a share link turned out to contain.
enum WanderSharePayload {
    case spot(WanderSharedSpot)
    case route(WanderSharedRoute)
}

// MARK: - Errors

/// Why a link couldn't be read. Every case carries a message meant to be shown verbatim to a
/// human — "this link is broken" with no hint is the reason people give up and paste raw
/// coordinates instead.
enum WanderShareLinkError: LocalizedError {
    case notAShareLink
    case unknownKind(String)
    case missingCoordinate
    case coordinateOutOfRange
    case missingRouteData
    case corruptRouteData
    case unsupportedVersion(Int)
    case malformedRoutePoints
    case routeTooShort
    case routeTooLong(Int)
    case encodingFailed
    case pasteHandoffLost

    var errorDescription: String? {
        switch self {
        case .notAShareLink:
            return "That doesn't look like a Wander share link. Copy the whole link — it starts with https://wanderspoofer.com/go?"
        case .unknownKind(let kind):
            return "This link is for something Wander doesn't recognize (\"\(kind)\"). Update Wander and try again."
        case .missingCoordinate:
            return "This link is missing its coordinates, so there's nothing to import."
        case .coordinateOutOfRange:
            return "This link contains an impossible coordinate. Latitude must be between -90 and 90, longitude between -180 and 180."
        case .missingRouteData:
            return "This route link is missing its path data. It was probably cut short when it was copied — ask for the whole link."
        case .corruptRouteData:
            return "This route link is damaged and can't be read. It was probably cut short when it was copied — ask for the whole link."
        case .unsupportedVersion(let v):
            return "This route link was made by a newer version of Wander (format v\(v)). Update Wander to import it."
        case .malformedRoutePoints:
            return "This route link's path is malformed, so Wander won't import part of it. Ask for the link again."
        case .routeTooShort:
            return "This route link has fewer than two points, so there's no path to follow."
        case .routeTooLong(let count):
            return "This route link has \(count) points — more than the \(WanderShareLink.maxRoutePoints) Wander can import."
        case .encodingFailed:
            return "Wander couldn't build a share link for this route."
        case .pasteHandoffLost:
            return "That pasted link didn't make it through. Tap Paste share link and try again."
        }
    }
}

// MARK: - Encode / decode

enum WanderShareLink {

    // MARK: Contract constants

    static let appScheme = "wander"
    static let appHost = "share"
    static let webHost = "wanderspoofer.com"
    static let webPath = "/go"

    /// Matches the SavedRoutes sync cap (`SavedRoutesSync.maxSyncPoints`). A route longer than this
    /// is evenly downsampled before encoding rather than refused — a shared 20k-point recording is
    /// still a useful route at 5k, and the alternative is the share button just failing.
    static let maxRoutePoints = 5000

    /// Names are display text, not data. Capped so a hostile (or accidental) 10k-character name can
    /// neither bloat the link past what chat apps will carry nor blow up a list row.
    static let maxNameLength = 60

    /// Ceiling on the LENGTH of a route link we hand to the share sheet, in characters.
    ///
    /// `maxRoutePoints` is the format's limit; this is the MEDIUM's, and it bites ~20× sooner. These
    /// links exist to be pasted into Discord, which hard-caps a message at 2000 characters — and a
    /// 5000-point route encodes to a ~39,000-character URL, 1000 points to ~7,300, 300 points to
    /// ~2,250. Past the limit the message arrives truncated and the recipient gets nothing but
    /// "this route link is damaged", which is the single worst outcome for a trade-your-routes
    /// feature. So a shared route is thinned to FIT rather than thinned to the point cap. 1800
    /// leaves room for whatever the sender types around the link.
    static let maxShareURLLength = 1800

    /// Ceiling on how much we'll inflate a route payload. A few KB of base64 can legitimately
    /// decompress to ~110 KB (5000 points × ~22 bytes of JSON); anything wildly past that is a
    /// compression bomb from a stranger's link, not a route.
    private static let maxInflatedBytes = 2 * 1024 * 1024

    // MARK: Building links (spot)

    /// The web form — THIS is what the share sheet hands over, because it's what survives being
    /// pasted into Discord/Messages and still opens the app when it's installed.
    static func webURL(forSpot coordinate: CLLocationCoordinate2D, name: String?) -> URL? {
        url(host: .web, query: spotQuery(coordinate: coordinate, name: name))
    }

    private static func spotQuery(coordinate: CLLocationCoordinate2D, name: String?) -> String {
        var items: [(String, String)] = [
            ("t", "s"),
            ("lat", fixed5(coordinate.latitude)),
            ("lng", fixed5(coordinate.longitude)),
        ]
        if let trimmed = normalizedName(name) { items.append(("n", trimmed)) }
        return queryString(items)
    }

    // MARK: Building links (route)

    /// A route link, plus what fitting it into the length budget cost.
    struct ShareableRouteLink {
        let url: URL
        /// How many points the link actually carries.
        let pointCount: Int
        /// How many the route had before any thinning.
        let originalPointCount: Int

        var wasThinned: Bool { pointCount < originalPointCount }
    }

    /// THE route-sharing entry point: the web link for a route, thinned as far as it takes to fit
    /// `budget` characters, plus the numbers the UI needs to tell the user what happened.
    ///
    /// Length can't be computed from the point count — DEFLATE's ratio depends on the path (a
    /// straight highway compresses far better than a hand-drawn scribble) — so this measures,
    /// shrinks by the overshoot, and measures again rather than trusting a formula. Two or three
    /// passes in practice; the attempt counter is a stop, not a plan.
    static func shareableWebURL(forRoute coordinates: [CLLocationCoordinate2D],
                                name: String?,
                                budget: Int = maxShareURLLength) throws -> ShareableRouteLink {
        let original = coordinates.count
        var points = downsampled(coordinates)   // the format cap first; the budget cap below
        var url = try webURL(forRoute: points, name: name)

        var attempts = 0
        while url.absoluteString.count > budget, points.count > 2, attempts < 12 {
            // The 0.9 is headroom: dropping points shortens the JSON but also costs a little
            // compression ratio, so aiming exactly at the budget tends to land just over it.
            let overshoot = Double(budget) / Double(url.absoluteString.count)
            let target = max(2, min(points.count - 1, Int(Double(points.count) * overshoot * 0.9)))
            points = downsampled(points, to: target)
            url = try webURL(forRoute: points, name: name)
            attempts += 1
        }
        return ShareableRouteLink(url: url, pointCount: points.count, originalPointCount: original)
    }

    /// The web form for a route at exactly the points given (beyond the format cap, which is applied
    /// here). Throws only when the payload genuinely can't be built (too short a path, or the
    /// compressor refusing) — callers surface `error.localizedDescription` as-is. Prefer
    /// `shareableWebURL(forRoute:name:)` for anything the user will paste somewhere.
    static func webURL(forRoute coordinates: [CLLocationCoordinate2D], name: String?) throws -> URL {
        let points = downsampled(coordinates)
        guard points.count >= 2 else { throw WanderShareLinkError.routeTooShort }

        var items: [(String, String)] = [("t", "r")]
        if let trimmed = normalizedName(name) { items.append(("n", trimmed)) }
        items.append(("d", try encodeRoutePayload(points)))

        guard let built = url(host: .web, query: queryString(items)) else {
            throw WanderShareLinkError.encodingFailed
        }
        return built
    }

    /// `base64url( raw-DEFLATE( {"v":1,"p":[…]} ) )`, no padding. Split out from URL assembly so a
    /// cross-platform conformance test can drive it directly. Note what such a test may NOT assert:
    /// Apple's `compression_encode_buffer` and Android's `Deflater` emit DIFFERENT (both valid)
    /// streams for the same input, so comparing payload bytes across platforms fails spuriously.
    /// The real invariants are `decode(encode(x)) == x` on each side, and each side decoding the
    /// other's payload.
    static func encodeRoutePayload(_ coordinates: [CLLocationCoordinate2D]) throws -> String {
        // Hand-built JSON: the exact bytes matter (see the file header), and this is both shorter
        // and more predictable than teaching a serializer to print 5-decimal fixed-point.
        var json = "{\"v\":1,\"p\":["
        json.reserveCapacity(coordinates.count * 20 + 16)
        for (index, c) in coordinates.enumerated() {
            if index > 0 { json += "," }
            json += fixed5(c.latitude)
            json += ","
            json += fixed5(c.longitude)
        }
        json += "]}"

        guard let raw = json.data(using: .utf8) else { throw WanderShareLinkError.encodingFailed }
        let deflated = try deflate(raw)
        return base64url(deflated)
    }

    /// Evenly thin a path down to `limit` points, always keeping the first and last fix so the route
    /// still starts and ends where the sharer's did. Returns the input untouched when it already fits.
    static func downsampled(_ coordinates: [CLLocationCoordinate2D],
                            to limit: Int = maxRoutePoints) -> [CLLocationCoordinate2D] {
        guard limit >= 2, coordinates.count > limit else { return coordinates }
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(limit)
        let step = Double(coordinates.count - 1) / Double(limit - 1)
        for i in 0..<limit {
            let index = min(Int((Double(i) * step).rounded()), coordinates.count - 1)
            out.append(coordinates[index])
        }
        return out
    }

    // MARK: Reading links

    /// True when this URL is one of our two share forms. Cheap enough to call from a deep-link
    /// switch's `default:` so the web form (arriving as a universal link) lands in the same path.
    static func isShareURL(_ url: URL) -> Bool {
        form(of: url) != nil
    }

    /// Decode a share URL, or throw a `WanderShareLinkError` whose `localizedDescription` is
    /// already a sentence you can show the user.
    static func payload(from url: URL) throws -> WanderSharePayload {
        guard form(of: url) != nil else { throw WanderShareLinkError.notAShareLink }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ names: [String]) -> String? {
            for name in names {
                if let v = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value,
                   !v.isEmpty {
                    return v
                }
            }
            return nil
        }

        let name = normalizedName(value(["n", "name"]))
        // Extra/unknown params are deliberately never consulted — forward compatibility.
        switch (value(["t", "type"]) ?? "").lowercased() {
        case "s", "spot":
            // `lon`/`long` aren't in the contract; we accept them on IMPORT only, because being
            // lenient about someone's hand-edited link can't break the Android encoder.
            guard let latText = value(["lat", "latitude"]),
                  let lngText = value(["lng", "lon", "long", "longitude"]),
                  let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
                  let lng = Double(lngText.trimmingCharacters(in: .whitespaces))
            else { throw WanderShareLinkError.missingCoordinate }
            guard isValid(latitude: lat, longitude: lng) else {
                throw WanderShareLinkError.coordinateOutOfRange
            }
            return .spot(WanderSharedSpot(name: name,
                                          coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)))

        case "r", "route":
            guard let payload = value(["d", "data"]) else { throw WanderShareLinkError.missingRouteData }
            let coordinates = try decodeRoutePayload(payload)
            return .route(WanderSharedRoute(name: name, coordinates: coordinates))

        case let other:
            throw WanderShareLinkError.unknownKind(other.isEmpty ? "unknown" : other)
        }
    }

    /// Decode a link the user PASTED (from a chat app), tolerating the surrounding whitespace and
    /// stray quotes that come with a copy-paste.
    static func payload(fromPastedText text: String) throws -> WanderSharePayload {
        try payload(from: parsePastedURL(text))
    }

    // MARK: Pasted-link hand-off

    /// A pasted link takes the SAME preview path as a tapped one: the paste screen re-opens it as a
    /// `wander://share` URL so there is exactly one import flow to reason about. What it must NOT do
    /// is put the link's bytes in that URL — an imported route payload can be tens of KB, and
    /// `UIApplication.open` is a signal, not a data channel. So the already-decoded payload is
    /// parked here and the URL that travels is a flag.
    ///
    /// Main-actor only by convention (both ends are SwiftUI views); the slot is cleared on collection
    /// so a stale paste can never resurface behind a later, unrelated link.
    private static var parkedPastedPayload: WanderSharePayload?

    /// Query flag marking the hand-off URL.
    static let pasteHandoffFlag = "paste"

    /// Park a decoded payload and return the tiny URL that tells the deep-link handler to collect it.
    static func handoffURL(for payload: WanderSharePayload) -> URL {
        parkedPastedPayload = payload
        // Force-unwrap is safe: a fixed string with nothing user-supplied in it.
        return url(host: .app, query: "\(pasteHandoffFlag)=1")!
    }

    /// Collect the parked payload if `url` is a hand-off, else nil so the caller decodes normally.
    /// Throws when the flag is present but the slot is empty — the user tapped Import and deserves a
    /// "try again", not a button that silently does nothing.
    static func handedOffPayload(from url: URL) throws -> WanderSharePayload? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.contains(where: { $0.name.caseInsensitiveCompare(pasteHandoffFlag) == .orderedSame })
        else { return nil }
        defer { parkedPastedPayload = nil }
        guard let parked = parkedPastedPayload else { throw WanderShareLinkError.pasteHandoffLost }
        return parked
    }

    /// `base64url( raw-DEFLATE( JSON ) )` → coordinates. Every failure mode is distinct so the
    /// message tells the user whether the link was truncated, too big, or simply from the future.
    static func decodeRoutePayload(_ encoded: String) throws -> [CLLocationCoordinate2D] {
        guard let deflated = base64urlDecode(encoded) else { throw WanderShareLinkError.corruptRouteData }
        let json = try inflate(deflated)

        struct RoutePayload: Decodable {
            let v: Int
            let p: [Double]
        }
        guard let decoded = try? JSONDecoder().decode(RoutePayload.self, from: json) else {
            throw WanderShareLinkError.corruptRouteData
        }
        guard decoded.v == 1 else { throw WanderShareLinkError.unsupportedVersion(decoded.v) }
        guard decoded.p.count % 2 == 0 else { throw WanderShareLinkError.malformedRoutePoints }

        let count = decoded.p.count / 2
        guard count >= 2 else { throw WanderShareLinkError.routeTooShort }
        guard count <= maxRoutePoints else { throw WanderShareLinkError.routeTooLong(count) }

        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(count)
        for i in stride(from: 0, to: decoded.p.count, by: 2) {
            let lat = decoded.p[i], lng = decoded.p[i + 1]
            // All-or-nothing: one bad pair rejects the whole route. Importing "most" of a stranger's
            // path would silently teleport someone through a coordinate nobody drew.
            guard isValid(latitude: lat, longitude: lng) else {
                throw WanderShareLinkError.coordinateOutOfRange
            }
            out.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
        }
        return out
    }

    // MARK: Shared helpers

    /// Straight-line length of a path, in metres. Lives here (not in a view) because the import
    /// preview has to state a route's size before the user commits to it.
    static func totalDistanceMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
            let b = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            total += a.distance(from: b)
        }
        return total
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        return (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    // MARK: - Private

    private enum LinkForm { case app, web }

    private static func form(of url: URL) -> LinkForm? {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host()?.lowercased()) ?? ""
        if scheme == appScheme && host == appHost { return .app }
        if scheme == "https" || scheme == "http" {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            // Trailing-slash tolerant: some chat clients "helpfully" append one.
            let path = url.path().hasSuffix("/") && url.path().count > 1
                ? String(url.path().dropLast()) : url.path()
            if bare == webHost && path.lowercased() == webPath { return .web }
        }
        return nil
    }

    private static func url(host: LinkForm, query: String) -> URL? {
        switch host {
        case .app: return URL(string: "\(appScheme)://\(appHost)?\(query)")
        case .web: return URL(string: "https://\(webHost)\(webPath)?\(query)")
        }
    }

    private static func parsePastedURL(_ text: String) throws -> URL {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        guard let url = URL(string: cleaned) else { throw WanderShareLinkError.notAShareLink }
        guard isShareURL(url) else { throw WanderShareLinkError.notAShareLink }
        return url
    }

    /// Fixed 5 decimals, ALWAYS with a dot. The explicit POSIX locale is the whole point: a
    /// locale-formatted "35,65858" is a different link that no other device can read.
    private static func fixed5(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Trim, collapse to the name cap, and drop empties — used on BOTH sides so what we emit and
    /// what we accept have the same shape.
    private static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count <= maxNameLength ? trimmed : String(trimmed.prefix(maxNameLength))
    }

    /// Percent-encode against the UNRESERVED set only. URLComponents leaves characters such as `+`
    /// alone, and `+` is read as a space by plenty of query parsers — a place called "R&B + Jazz"
    /// would arrive mangled on the other platform. Encoding everything but `A-Za-z0-9-._~` removes
    /// that whole class of question.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func queryString(_ items: [(String, String)]) -> String {
        items
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
            .joined(separator: "&")
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ text: String) -> Data? {
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Padding is stripped on the wire; Foundation's decoder requires it back.
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

    // MARK: DEFLATE

    /// COMPRESSION_ZLIB on Apple platforms is RAW deflate (no zlib header/trailer) — which is
    /// exactly what the contract specifies, and what Android's `Deflater(level, nowrap = true)`
    /// produces.
    private static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw WanderShareLinkError.encodingFailed }
        // Deflate can EXPAND incompressible input, so the destination has to be bigger than the
        // source or compression_encode_buffer just reports failure on a route that happens not to
        // compress. (Ours always does; the headroom is for the pathological case.)
        let capacity = data.count + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        // 0 means "didn't fit" or "failed" — indistinguishable, and both are fatal for us.
        guard written > 0 else { throw WanderShareLinkError.encodingFailed }
        return Data(out.prefix(written))
    }

    /// The inverse. `compression_decode_buffer` wants the output size UP FRONT, which we can't know
    /// from a link, so we guess and grow: a result that exactly fills the buffer may have been
    /// truncated, so it's retried larger. The `maxInflatedBytes` ceiling stops the loop from being a
    /// compression-bomb amplifier for a link handed to us by a stranger.
    private static func inflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { throw WanderShareLinkError.corruptRouteData }
        var capacity = max(data.count * 8, 4096)
        while capacity <= maxInflatedBytes {
            var out = Data(count: capacity)
            let size = capacity
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                          let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, size, s, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { throw WanderShareLinkError.corruptRouteData }
            if written < capacity { return Data(out.prefix(written)) }
            capacity *= 4
        }
        throw WanderShareLinkError.corruptRouteData
    }
}
