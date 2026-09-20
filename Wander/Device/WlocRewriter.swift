//
//  WlocRewriter.swift
//  Wander
//
//  Clean-room Swift port of the AppleWLoc (gs-loc /clls/wloc) response poisoner. This is module 1 of
//  the in-app gs-loc engine (see the `wander-inapp-gsloc-verdict` memory). It takes the protobuf
//  payload Apple returns for a Wi-Fi/cell location lookup and rewrites every access-point and
//  cell-tower coordinate to a single target, so locationd computes an honest weighted-centroid that
//  lands on the target — leaving isSimulatedBySoftware FALSE.
//
//  CLEAN-ROOM: written from the wire-format field map only (varint/TLV protobuf + the AppleWLoc field
//  numbers), NOT copied from the AGPL rewriter served by the worker. The field map it implements:
//    root payload:  field 2  (wire 2) = a Wi-Fi device record
//                   fields 22, 24 (wire 2) = cell-tower response records
//                   fields 3, 4, 33 = request-only fields, DROPPED from a response
//    Wi-Fi record:  field 2  (wire 2) = the Location submessage
//    cell record:   field 5  (wire 2) = the Location submessage
//    Location:      field 1 = latitude  (signed varint, coord × 1e8)
//                   field 2 = longitude (signed varint, coord × 1e8)
//                   field 3 = horizontalAccuracy (kept as-is; synthesized only if Apple omitted it)
//  Only fields 1/2 of each Location are overwritten; everything else Apple sent is passed through in
//  its original position, so a poisoned record is wire-identical to a real one except the two coords.
//
//  This module does NOT touch the transport envelopes (the ARPC pascal-string frame or the
//  length-prefixed AppleWLoc frame) — that is module 2. It operates on the already-unwrapped payload.
//

import Foundation

enum WlocRewriter {

    /// Root fields that only appear in a REQUEST (counts / device type) and must not survive into a
    /// response. Passing them through would leave request-shaped fields in a response body.
    ///
    /// NOTE field 4 = `num_wifi_results`. It is dropped by default (matching every shipping rewriter),
    /// but `Options.suppressNeighbors` deliberately EMITS it — see that option.
    private static let rootDropFields: Set<Int> = [3, 4, 33]

    /// Experimental levers, all defaulting to today's shipped behavior so turning none of them on is a
    /// no-op. Each targets a specific locationd internal recovered from `/usr/libexec/locationd` symbol
    /// strings (2026-08-08). ALL ARE HYPOTHESES — they exist to be A/B'd on device, not trusted.
    struct Options {
        /// What to write into per-AP `Location` field 9 (`timestamp`) — the OBSERVATION time of that
        /// AP's position estimate. NOT a TTL (the proto has no TTL/expiry field); it says "this is when
        /// the measurement was taken", and locationd's own staleness policy reads it.
        enum Timestamp {
            /// Today's behavior: leave whatever Apple sent, byte-for-byte.
            case passthrough
            /// Stamp "now". Hypothesis: every shipping rewriter omits this, so locationd may be treating
            /// our poisoned records as ancient observations and discounting them.
            case now
            /// Stamp `now - seconds`. Opposite hypothesis: entries born stale get purged by
            /// `CLNetworkLocationProvider::onPurgeTimer`, forcing a fresh query — i.e. a movement clock.
            case backdated(TimeInterval)
        }
        var timestamp: Timestamp = .passthrough

        /// Emit root field 4 (`num_wifi_results`) = -1, whose schema comment reads "Set to -1 to
        /// disable". Targets the up-to-400 unrequested neighbour APs Apple pre-loads so the device
        /// "need only consult its cache when the user walks down the block" (Rye & Levin, IEEE S&P
        /// 2024). That pre-fill is exactly what makes the cache self-sufficient and movement
        /// impossible; suppressing it should make the cached AP set equal the VISIBLE AP set.
        var suppressNeighbors: Bool = false

        static let shipped = Options()
    }

    /// Cocoa/CFAbsoluteTime epoch — 2001-01-01 UTC. Apple's location timestamps count from here, not 1970.
    private static let cocoaEpoch = Date(timeIntervalSince1970: 978_307_200)

    /// Root fields that carry a cell-tower record in a RESPONSE.
    private static let cellResponseFields: Set<Int> = [22, 24]

    // MARK: - Public entry

    /// Rewrite an unwrapped AppleWLoc payload so every Wi-Fi AP and cell tower resolves to (lat, lng).
    /// `horizontalAccuracy` is only used for records where Apple supplied none (real located APs
    /// always carry their own, which is kept). Returns the rewritten payload and the counts patched.
    /// A wifi AP's position among all wifi devices in the payload, so the scatter/heal-N
    /// experiments can place it on a ring. nil for cells and synthesized records.
    private typealias Ring = (index: Int, total: Int)

    /// - scatterRadius: metres. 0 (default) = every AP stacked on the exact target, i.e.
    ///   today's behaviour. >0 spreads the wifi APs onto a ring of this radius (the
    ///   equal-weight centroid is still the target) and pulls each ring AP's field-3
    ///   accuracy down to `scatterApUnc`. This mirrors the worker's scatterRadius lever.
    /// - healCount: how many wifi APs to heal to the target. A large default heals every
    ///   AP = today's behaviour; a small value heals the first N and writes Apple's
    ///   unlocatable sentinel into the rest (the S2 heal-N experiment).
    @discardableResult
    static func poison(payload: Data,
                       latitude: Double,
                       longitude: Double,
                       horizontalAccuracy: Int64 = 39,
                       scatterRadius: Double = 0,
                       healCount: Int = .max,
                       options: Options = .shipped,
                       now: Date = Date()) -> (payload: Data, wifiCount: Int, cellCount: Int) {
        let radius = (scatterRadius.isFinite && scatterRadius > 0) ? scatterRadius : 0
        let heal = healCount < 0 ? .max : healCount
        let cfg = Coord(lat: coordToInt(latitude),
                        lng: coordToInt(longitude),
                        latDeg: latitude,
                        lngDeg: longitude,
                        hAcc: horizontalAccuracy,
                        ringR: radius,
                        healCount: heal,
                        stamp: stampValue(options.timestamp, now: now))
        // Pre-count the wifi devices so each AP knows its {index, total} for the ring geometry.
        var wifiTotal = 0
        for f in parseFields(payload) where f.fieldNumber == 2 && f.wireType == 2 { wifiTotal += 1 }

        var out = Data()
        var wifi = 0
        var cell = 0
        var wifiIdx = 0
        for f in parseFields(payload) {
            if f.fieldNumber == 2, f.wireType == 2 {
                out.append(lengthDelimited(2, patchWifiDevice(f.valueBytes, cfg, (index: wifiIdx, total: wifiTotal))))
                wifiIdx += 1
                wifi += 1
            } else if cellResponseFields.contains(f.fieldNumber), f.wireType == 2 {
                // Cells are the anchor — always stacked on the exact target (ring nil).
                out.append(lengthDelimited(f.fieldNumber, patchCellTower(f.valueBytes, cfg)))
                cell += 1
            } else if !rootDropFields.contains(f.fieldNumber) {
                out.append(f.raw)
            }
        }
        // Emitted LAST and only on request: field 4 is normally a request-only field we drop, so writing
        // it into a response is deliberately non-standard — the point of the experiment.
        if options.suppressNeighbors {
            out.append(varintField(4, signed: -1))
        }
        return (out, wifi, cell)
    }

    /// nil = don't touch field 9. Otherwise the CFAbsoluteTime (seconds since 2001-01-01) to write.
    private static func stampValue(_ mode: Options.Timestamp, now: Date) -> Int64? {
        switch mode {
        case .passthrough:
            return nil
        case .now:
            return Int64(now.timeIntervalSince(cocoaEpoch))
        case let .backdated(seconds):
            return Int64(now.addingTimeInterval(-seconds).timeIntervalSince(cocoaEpoch))
        }
    }

    private struct Coord {
        let lat: Int64          // target latitude  × 1e8 (fixed point)
        let lng: Int64          // target longitude × 1e8 (fixed point)
        let latDeg: Double      // target latitude  in degrees (kept for exact ring math / worker parity)
        let lngDeg: Double      // target longitude in degrees
        let hAcc: Int64
        let ringR: Double       // scatter radius, metres. 0 = exact-stack (today).
        let healCount: Int      // how many wifi APs to heal to target; rest get the sentinel.
        let stamp: Int64?
    }

    /// Metres per degree of latitude (1 deg lat ≈ 111320 m). Mirrors the worker's METRES_PER_DEGREE.
    private static let metresPerDegree: Double = 111_320
    /// Field-3 accuracy written onto RING (scattered) APs so their apUnc does not floor reported hAcc.
    private static let scatterApUnc: Int64 = 5
    /// Apple's "unlocatable" sentinel coordinate: -180.0 × 1e8. Paired with hAcc = -1.
    private static let appleSentinelCoord: Int64 = -18_000_000_000
    private static let appleSentinelUnc: Int64 = -1

    /// int64(coord * 1e8), truncated toward zero — matches Apple's fixed-point coordinate encoding.
    static func coordToInt(_ value: Double) -> Int64 {
        Int64((value * 100_000_000).rounded(.towardZero))
    }

    // MARK: - Record patchers

    private static func patchWifiDevice(_ payload: Data, _ cfg: Coord, _ ring: Ring?) -> Data {
        patchRecord(payload, locationField: 2, cfg, ring)
    }

    private static func patchCellTower(_ payload: Data, _ cfg: Coord) -> Data {
        patchRecord(payload, locationField: 5, cfg, nil)
    }

    /// A Wi-Fi record nests its Location at field 2; a cell record at field 5. Otherwise identical:
    /// replace the Location submessage in place, or synthesize one if the record carried none.
    private static func patchRecord(_ payload: Data, locationField: Int, _ cfg: Coord, _ ring: Ring?) -> Data {
        var out = Data()
        var patched = false
        for f in parseFields(payload) {
            if f.fieldNumber == locationField, f.wireType == 2 {
                out.append(lengthDelimited(locationField, patchLocation(f.valueBytes, cfg, ring)))
                patched = true
            } else {
                out.append(f.raw)
            }
        }
        if !patched {
            out.append(lengthDelimited(locationField, patchLocation(Data(), cfg, ring)))
        }
        return out
    }

    /// Overwrite an AP's Location to Apple's "unlocatable" sentinel: fields 1/2 = the sentinel
    /// coordinate, field 3 = -1. Zero centroid weight, still on the wire. S2 heal-N only.
    private static func sentinelLocation(_ payload: Data) -> Data {
        var out = Data()
        var hasLat = false, hasLng = false, hasAcc = false
        if !payload.isEmpty {
            for f in parseFields(payload) {
                switch f.fieldNumber {
                case 1: out.append(varintField(1, signed: appleSentinelCoord)); hasLat = true
                case 2: out.append(varintField(2, signed: appleSentinelCoord)); hasLng = true
                case 3: out.append(varintField(3, signed: appleSentinelUnc)); hasAcc = true
                default: out.append(f.raw)
                }
            }
        }
        if !hasLat { out.append(varintField(1, signed: appleSentinelCoord)) }
        if !hasLng { out.append(varintField(2, signed: appleSentinelCoord)) }
        if !hasAcc { out.append(varintField(3, signed: appleSentinelUnc)) }
        return out
    }

    /// Overwrite ONLY latitude (1) and longitude (2). Keep field 3 (horizontalAccuracy) and every other
    /// field byte-for-byte in place. Synthesize a coord/accuracy only when Apple omitted it.
    ///
    /// scatter (ringR>0, wifi ring of total>=4): place this AP on a ring around the target and pull its
    /// field 3 to `scatterApUnc`. sentinel (index>=healCount): write the AP unlocatable. Both collapse to
    /// today's exact-stack behaviour when ringR=0 and healCount heals every AP.
    private static func patchLocation(_ payload: Data, _ cfg: Coord, _ ring: Ring?) -> Data {
        let scatter = ring != nil && cfg.ringR > 0 && ring!.total >= 4
        if let r = ring, r.index >= cfg.healCount {
            return sentinelLocation(payload)
        }

        var la = cfg.lat
        var ln = cfg.lng
        if scatter, let r = ring {
            let theta = 2 * Double.pi * Double(r.index) / Double(r.total)
            let dLat = (cfg.ringR * sin(theta)) / metresPerDegree
            let dLng = (cfg.ringR * cos(theta)) / (metresPerDegree * cos(cfg.latDeg * Double.pi / 180))
            la = coordToInt(cfg.latDeg + dLat)
            ln = coordToInt(cfg.lngDeg + dLng)
        }

        var out = Data()
        var hasLat = false, hasLng = false, hasAcc = false, hasStamp = false
        if !payload.isEmpty {
            for f in parseFields(payload) {
                switch f.fieldNumber {
                case 1:
                    out.append(varintField(1, signed: la)); hasLat = true
                case 2:
                    out.append(varintField(2, signed: ln)); hasLng = true
                case 3 where scatter:
                    // Ring AP: overwrite apUnc down so it does not floor the reported hAcc.
                    out.append(varintField(3, signed: scatterApUnc)); hasAcc = true
                case 9 where cfg.stamp != nil:
                    // Field 9 = observation timestamp. Only rewritten when the experiment asks for it;
                    // otherwise it falls to `default` and passes through byte-for-byte like everything else.
                    out.append(varintField(9, signed: cfg.stamp!)); hasStamp = true
                default:
                    if f.fieldNumber == 3 { hasAcc = true }
                    if f.fieldNumber == 9 { hasStamp = true }
                    out.append(f.raw)
                }
            }
        }
        if !hasLat { out.append(varintField(1, signed: la)) }
        if !hasLng { out.append(varintField(2, signed: ln)) }
        if !hasAcc { out.append(varintField(3, signed: scatter ? scatterApUnc : cfg.hAcc)) }
        // Apple often omits field 9 entirely; when the experiment is on we ADD it, since "absent" is
        // exactly the state we're testing against.
        if !hasStamp, let stamp = cfg.stamp { out.append(varintField(9, signed: stamp)) }
        return out
    }

    // MARK: - Protobuf primitives

    struct Field {
        let fieldNumber: Int
        let wireType: Int
        let raw: Data        // key + value, exactly as it appeared — for byte-identical passthrough
        let valueBytes: Data // wire-2: the inner payload; other wire types: the value region
    }

    /// Walk a protobuf message into its top-level fields. Throws nothing — a malformed tail simply ends
    /// the walk (callers pass Apple's own well-formed bytes; defensive truncation beats a crash in an
    /// NE/loopback proxy).
    static func parseFields(_ bytes: Data) -> [Field] {
        var fields: [Field] = []
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let keyStart = i
            guard let (key, afterKey) = decodeVarint(bytes, i) else { break }
            i = afterKey
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x7)
            if fieldNumber == 0 { break }

            let valueStart = i
            var valueEnd: Data.Index
            var valueBytes = Data()
            switch wireType {
            case 0: // varint
                guard let (_, after) = decodeVarint(bytes, i) else { return fields }
                valueEnd = after
            case 1: // 64-bit
                guard bytes.index(i, offsetBy: 8, limitedBy: end) != nil else { return fields }
                valueEnd = bytes.index(i, offsetBy: 8)
            case 2: // length-delimited
                guard let (len, afterLen) = decodeVarint(bytes, i) else { return fields }
                let payloadLen = Int(len)
                guard let e = bytes.index(afterLen, offsetBy: payloadLen, limitedBy: end) else { return fields }
                valueBytes = bytes.subdata(in: afterLen..<e)
                valueEnd = e
            case 5: // 32-bit
                guard bytes.index(i, offsetBy: 4, limitedBy: end) != nil else { return fields }
                valueEnd = bytes.index(i, offsetBy: 4)
            default:
                return fields // unknown wire type — stop rather than misread
            }
            if wireType != 2 {
                valueBytes = bytes.subdata(in: valueStart..<valueEnd)
            }
            let raw = bytes.subdata(in: keyStart..<valueEnd)
            fields.append(Field(fieldNumber: fieldNumber, wireType: wireType, raw: raw, valueBytes: valueBytes))
            i = valueEnd
        }
        return fields
    }

    /// Decode a base-128 varint starting at `offset`. Returns the value and the index just past it,
    /// or nil if the buffer ends mid-varint.
    static func decodeVarint(_ bytes: Data, _ offset: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        let end = bytes.endIndex
        while i < end {
            let b = bytes[i]
            i = bytes.index(after: i)
            result |= UInt64(b & 0x7f) << shift
            if (b & 0x80) == 0 { return (result, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while v >= 0x80 {
            out.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    /// A key is (fieldNumber << 3 | wireType) as a varint.
    private static func key(_ fieldNumber: Int, _ wireType: Int) -> Data {
        encodeVarint((UInt64(fieldNumber) << 3) | UInt64(wireType))
    }

    /// A wire-type-0 field. Signed int64 goes on the wire as its two's-complement unsigned pattern.
    private static func varintField(_ fieldNumber: Int, signed value: Int64) -> Data {
        var d = key(fieldNumber, 0)
        d.append(encodeVarint(UInt64(bitPattern: value)))
        return d
    }

    /// A wire-type-2 (length-delimited) field wrapping `payload`.
    private static func lengthDelimited(_ fieldNumber: Int, _ payload: Data) -> Data {
        var d = key(fieldNumber, 2)
        d.append(encodeVarint(UInt64(payload.count)))
        d.append(payload)
        return d
    }
}
