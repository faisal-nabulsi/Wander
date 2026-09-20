//
//  WlocEnvelope.swift
//  Wander
//
//  Module 2 of the in-app gs-loc engine (see GSLOC_INAPP_PLAN.md). Apple's /clls/wloc and
//  /dispatcher.arpc responses wrap the AppleWLoc protobuf payload in one of a few transport frames.
//  This unwraps the payload so `WlocRewriter` can poison it, then rewraps it in the SAME frame so
//  locationd accepts the reply byte-for-byte except the coordinates.
//
//  CLEAN-ROOM: ported from the frame shapes only, not the AGPL source. Four shapes, matching the
//  worker rewriter's detection order:
//    • arpc      — the real modern response: uint16 version, 3 pascal strings (locale, appId, osVer),
//                  uint32 functionId, uint32 payloadLength, payload. (Re-serialize with new length.)
//    • synthetic — 8-byte prefix (00 01 xx xx 00 00 xx xx) + uint16 length + payload + suffix.
//    • marker    — fallback: search for 00 00 00 01 00 00, then uint16 length + payload.
//    • bare      — raw protobuf payload, no frame.
//

import Foundation

enum WlocEnvelope {

    private static let marker: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x00, 0x00]

    enum Frame {
        case synthetic(prefix: [UInt8], suffix: [UInt8])
        case arpc(version: UInt16, locale: String, appId: String, osVersion: String, functionId: UInt32)
        case marker(prefix: [UInt8], suffix: [UInt8])
        case bare
    }

    // MARK: - Public API

    /// Unwrap a /clls/wloc response into its AppleWLoc payload plus the frame needed to rewrap it.
    /// Returns nil if no known frame matches (caller should pass the body through untouched).
    static func unwrap(_ response: Data) -> (payload: Data, frame: Frame)? {
        let b = [UInt8](response)

        if let s = unwrapSynthetic(b) { return s }
        if let a = unwrapArpc(b) { return a }
        if let m = unwrapMarker(b) { return m }
        if looksLikePayload(b) { return (Data(b), .bare) }
        return nil
    }

    /// Rewrap a (poisoned) payload in the same frame it came from.
    static func rewrap(payload: Data, frame: Frame) -> Data {
        let p = [UInt8](payload)
        switch frame {
        case let .synthetic(prefix, suffix):
            var out = prefix
            out += u16(p.count)
            out += p
            out += suffix
            return Data(out)
        case let .arpc(version, locale, appId, osVersion, functionId):
            var out = u16(Int(version))
            out += pascal(locale)
            out += pascal(appId)
            out += pascal(osVersion)
            out += u32(Int(functionId))
            out += u32(p.count)
            out += p
            return Data(out)
        case let .marker(prefix, suffix):
            var out = prefix
            out += marker
            out += u16(p.count)
            out += p
            out += suffix
            return Data(out)
        case .bare:
            return payload
        }
    }

    /// Full module-2 entry: unwrap → poison → rewrap. Returns nil (pass-through) if the body isn't a
    /// recognizable WLoc response — exactly the safe behavior for a shared endpoint.
    /// Returns the rewrapped body AND the counts, so a caller never has to poison twice to learn how
    /// much it changed — doing that once meant the logged numbers could drift from the bytes actually
    /// sent.
    static func poisonResponse(_ response: Data,
                               latitude: Double,
                               longitude: Double,
                               horizontalAccuracy: Int64 = 39,
                               options: WlocRewriter.Options = .shipped) -> (body: Data, wifi: Int, cell: Int)? {
        guard let (payload, frame) = unwrap(response) else { return nil }
        let result = WlocRewriter.poison(payload: payload,
                                         latitude: latitude,
                                         longitude: longitude,
                                         horizontalAccuracy: horizontalAccuracy,
                                         options: options)
        return (rewrap(payload: result.payload, frame: frame), result.wifiCount, result.cellCount)
    }

    // MARK: - Unwrappers

    private static func unwrapSynthetic(_ b: [UInt8]) -> (Data, Frame)? {
        guard b.count >= 10, b[0] == 0x00, b[1] == 0x01, b[6] == 0x00, b[7] == 0x00 else { return nil }
        let len = readU16(b, 8)
        let start = 10
        guard len > 0, start + len <= b.count else { return nil }
        let payload = Array(b[start..<start + len])
        guard looksLikePayload(payload) else { return nil }
        return (Data(payload), .synthetic(prefix: Array(b[0..<8]), suffix: Array(b[(start + len)...])))
    }

    private static func unwrapArpc(_ b: [UInt8]) -> (Data, Frame)? {
        var off = 0
        guard b.count >= 2 else { return nil }
        let version = UInt16(readU16(b, off)); off += 2
        guard let (locale, o1) = readPascal(b, off) else { return nil }; off = o1
        guard let (appId, o2) = readPascal(b, off) else { return nil }; off = o2
        guard let (osVersion, o3) = readPascal(b, off) else { return nil }; off = o3
        guard off + 8 <= b.count else { return nil }
        let functionId = UInt32(readU32(b, off)); off += 4
        let payloadLen = readU32(b, off); off += 4
        guard payloadLen > 0, off + payloadLen <= b.count else { return nil }
        let payload = Array(b[off..<off + payloadLen])
        guard looksLikePayload(payload) else { return nil }
        return (Data(payload), .arpc(version: version, locale: locale, appId: appId,
                                     osVersion: osVersion, functionId: functionId))
    }

    private static func unwrapMarker(_ b: [UInt8]) -> (Data, Frame)? {
        guard let idx = find(b, marker) else { return nil }
        let lenOff = idx + marker.count
        guard lenOff + 2 <= b.count else { return nil }
        let len = readU16(b, lenOff)
        let start = lenOff + 2
        guard len > 0, start + len <= b.count else { return nil }
        let payload = Array(b[start..<start + len])
        guard looksLikePayload(payload) else { return nil }
        return (Data(payload), .marker(prefix: Array(b[0..<idx]), suffix: Array(b[(start + len)...])))
    }

    /// A valid AppleWLoc payload starts with a protobuf tag whose field number > 0 and wire type is
    /// 0 or 2 (field 2 / wifi = tag 0x12).
    private static func looksLikePayload(_ b: [UInt8]) -> Bool {
        guard let tag = b.first else { return false }
        let fieldNumber = tag >> 3
        let wireType = tag & 0x7
        return fieldNumber > 0 && (wireType == 0 || wireType == 2)
    }

    // MARK: - Byte helpers (big-endian, as Apple frames them)

    private static func readU16(_ b: [UInt8], _ o: Int) -> Int {
        (Int(b[o]) << 8) | Int(b[o + 1])
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> Int {
        (Int(b[o]) << 24) | (Int(b[o + 1]) << 16) | (Int(b[o + 2]) << 8) | Int(b[o + 3])
    }
    private static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private static func u32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    /// A pascal string: uint16 BE length + that many ASCII bytes (7-bit).
    private static func readPascal(_ b: [UInt8], _ o: Int) -> (String, Int)? {
        guard o + 2 <= b.count else { return nil }
        let len = readU16(b, o)
        let start = o + 2
        guard start + len <= b.count else { return nil }
        let chars = b[start..<start + len].map { Character(UnicodeScalar($0 & 0x7f)) }
        return (String(chars), start + len)
    }
    private static func pascal(_ s: String) -> [UInt8] {
        let bytes = s.unicodeScalars.map { UInt8($0.value & 0x7f) }
        return u16(bytes.count) + bytes
    }

    private static func find(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}
