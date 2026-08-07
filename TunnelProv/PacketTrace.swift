//
//  PacketTrace.swift
//  SHARED — compiled into BOTH the Wander app AND the TunnelProv appex.
//
//  WHY THIS EXISTS. A Network Extension is a separate process with its own sandbox, so nothing it
//  logs reaches the app's Console. That is why nobody has ever been able to say WHERE the packets
//  die in Wander's own loopback tunnel. Three possibilities, three completely different fixes:
//
//      (a) no packets reach the provider at all      -> routing; they never enter the tunnel
//      (b) they reach it but the swap does not fire  -> the addresses/config do not match
//      (c) the swap fires and they are written back  -> reinjection / network settings
//
//  This is the bridge that tells them apart: a fixed-size ring buffer in the shared App Group
//  container, memory-mapped by the extension (the writer) and by the app (the reader).
//
//  COST, because this sits in the packet path:
//    • Disarmed: one clock read and one integer compare per BATCH (not per packet), then return.
//      No file is opened, nothing is mapped, nothing is allocated. Re-probes for the arming file at
//      most once every `probeInterval` seconds.
//    • Armed: one clock read, one compare against the header, a bounded scan of the batch that
//      allocates nothing (`Data.withUnsafeBytes` on a non-escaping closure), and a handful of
//      fixed-offset stores into mapped memory. No syscalls, no locks, no allocation per packet.
//    • The ring is CAPPED at `capacity` records and the file is a fixed 64 KB. It cannot grow.
//
//  SAFETY GATE (see also `arm(forMinutes:)`): tracing is OFF unless the trace file exists AND its
//  header's `armedUntil` is in the future. Only the Console's "Dump tunnel packet trace" row arms
//  it, and the arm EXPIRES on its own (default one hour), so a normal user cannot end up running
//  with tracing on. When off, every entry point returns before touching the filesystem.
//
//  SINGLE WRITER. `readPackets`' completion handler is the only thing that appends, and it is never
//  re-entered concurrently (one outstanding read at a time), so no lock is needed on the write side.
//  The reader may run concurrently, so every record carries its sequence number at BOTH ends and a
//  reader accepts a record only when the two agree — a torn record is skipped, never misreported.
//

import Foundation
import Darwin

enum PacketTrace {

    // MARK: - Where the trace lives

    /// The App Group declared in BOTH `Wander/Wander.entitlements` and `TunnelProv/TunnelProv.entitlements`.
    /// If this ever stops resolving, `resolvedAppGroup` will be nil and the reader says so explicitly
    /// rather than reporting "no packets", which would be indistinguishable from finding (a).
    static let declaredAppGroup = "group.com.stik.stikdebug"

    static let fileName = "wander-packet-trace.bin"

    /// How long an arm lasts before it expires by itself.
    static let defaultArmMinutes: Double = 60

    /// Minimum spacing between attempts to OPEN the trace file while disarmed. Time-based rather
    /// than batch-counted on purpose: a tunnel that only ever sees five packets must still be able
    /// to record them, and a batch counter would never reach its threshold in that case.
    static let probeInterval: Double = 2.0

    /// The candidates, in order. A re-signer (AltStore/SideStore/enterprise) rewrites both the bundle
    /// id and the App Group, so the literal from the entitlements file is only the first guess.
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil for a group the process is
    /// not actually entitled to, which makes this a safe probe rather than a guess.
    /// The groups the CERT-SIGNED profile actually carries. `containerURL(...)` returns nil for a
    /// group the process is not entitled to, so listing them is a safe probe, not a guess — and on a
    /// free-sideload build (which has none of these) the list simply yields nothing and the reader
    /// says so. Found by decoding Development.mobileprovision: the profile grants
    /// group.3b9b86f0bde630e2.1 ... .5, and NOT the literal in the entitlements file, which is why
    /// the trace reported "no App Group container is reachable" on the paid build.
    static let profileAppGroups = (1...5).map { "group.3b9b86f0bde630e2.\($0)" }

    static func appGroupCandidates() -> [String] {
        var out: [String] = [declaredAppGroup]
        out.append(contentsOf: profileAppGroups)
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        // In the appex this is "<app bundle id>.TunnelProv"; strip it so both processes derive the
        // same list.
        let base = bundleID.hasSuffix(".TunnelProv")
            ? String(bundleID.dropLast(".TunnelProv".count))
            : bundleID
        if !base.isEmpty {
            out.append("group." + base)
            let stem = "com.stik.stikdebug."
            if base.hasPrefix(stem) {
                let teamSuffix = String(base.dropFirst(stem.count))
                if !teamSuffix.isEmpty { out.append(declaredAppGroup + "." + teamSuffix) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static let pathLock = NSLock()
    nonisolated(unsafe) private static var pathResolved = false
    nonisolated(unsafe) private static var cachedPath: String?
    nonisolated(unsafe) private static var cachedGroup: String?

    /// Filesystem path of the trace, or nil when no candidate App Group resolves (i.e. the entitlement
    /// is missing or was stripped). Resolved once; the packet path never reaches this after the first
    /// successful map.
    static func tracePath() -> String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        if pathResolved { return cachedPath }
        pathResolved = true
        for group in appGroupCandidates() {
            guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
            cachedGroup = group
            cachedPath = container.appendingPathComponent(fileName).path
            return cachedPath
        }
        return nil
    }

    /// The App Group that actually resolved, for the report. Nil until `tracePath()` has been called.
    static func resolvedAppGroup() -> String? {
        pathLock.lock()
        defer { pathLock.unlock() }
        return cachedGroup
    }

    // MARK: - On-disk layout
    //
    // Hand-rolled fixed offsets rather than a Swift struct: this is a FILE FORMAT read by a second
    // process, and Swift makes no layout promise for a non-frozen struct. Every field below is
    // naturally aligned (the header is 128 bytes, each record 80, both multiples of 8), so the loads
    // and stores are aligned even though `loadUnaligned` is used for belt-and-braces.

    static let magic: UInt32 = 0x57545231          // "WTR1"
    /// v2 (2026-08-06): the record and header grew to carry the IPv6 arm's own src/dst and match
    /// counters — the v1 layout counted v6 packets but never inspected them, so a v6-only failing run
    /// could not be told apart from routing noise. Bumping this makes a device that still holds a v1
    /// file (wrong size / version) re-arm cleanly rather than misread it.
    static let formatVersion: UInt32 = 2
    static let headerSize = 192
    static let recordSize = 128
    /// Hard cap on entries. 512 batches is far more than any diagnosis session produces — a TCP
    /// connect attempt is a handful of packets — and keeps the whole file at 64 KB.
    static let capacity = 512
    static var fileSize: Int { headerSize + recordSize * capacity }

    private enum H {
        static let magic          = 0    // UInt32
        static let version        = 4    // UInt32
        static let capacity       = 8    // UInt32
        static let recordSize     = 12   // UInt32
        static let armedUntil     = 16   // Double, unix seconds
        static let writeSeq       = 24   // UInt64, total records ever appended
        static let armedAt        = 32   // Double
        static let deviceIp       = 40   // UInt32, host order
        static let fakeIp         = 44   // UInt32, host order
        static let packetsSeen    = 48   // UInt64
        static let v4Seen         = 56   // UInt64
        static let v6Seen         = 64   // UInt64
        static let srcMatched     = 72   // UInt64  packets where src == deviceIp (seen, not rewritten)
        static let dstMatched     = 80   // UInt64  packets where dst == fakeIp   (seen, not rewritten)
        static let bothMatched    = 88   // UInt64  packets where BOTH fired — the only ones rewritten
        static let writtenBack    = 96   // UInt64  packets handed to writePackets
        static let readBatches    = 104  // UInt64
        static let writeBatches   = 112  // UInt64
        static let flags          = 120  // UInt32
        static let providerStarts = 124  // UInt32
        // v2 — the IPv6 arm's aggregate counters, the exact twins of srcMatched/dstMatched/bothMatched
        // above. Kept at the header level (not only per-record) so a diagnosis survives a ring wrap.
        static let v6SrcMatched   = 128  // UInt64  v6 packets where src == device6
        static let v6DstMatched   = 136  // UInt64  v6 packets where dst == fake6
        static let v6BothMatched  = 144  // UInt64  v6 packets where BOTH fired (the v6 swap)
        // 152..191 reserved
    }

    private enum R {
        static let seq           = 0    // UInt64
        static let time          = 8    // Double
        static let batchCount    = 16   // UInt32
        static let proto         = 20   // Int32   AF_INET / AF_INET6 of the reported packet
        static let firstSrc      = 24   // UInt32  host order (the first IPv4 packet)
        static let firstDst      = 28   // UInt32  host order
        static let flags         = 32   // UInt32
        static let srcMatchCount = 36   // UInt32  v4: src == deviceIp
        static let dstMatchCount = 40   // UInt32  v4: dst == fakeIp
        static let v4Count       = 44   // UInt32
        static let v6Count       = 48   // UInt32
        static let wroteCount    = 52   // UInt32
        static let srcPort       = 56   // UInt16  v4
        static let dstPort       = 58   // UInt16  v4
        static let ipProto       = 60   // UInt8   v4
        static let reserved      = 61   // UInt8
        static let firstLen      = 62   // UInt16  v4
        // v2 — the IPv6 arm, recorded independently of the v4 fields above so a MIXED batch keeps both
        // stories. `v6FirstSrc` is the pre-swap source the KERNEL selected; comparing it against the
        // configured device6 is the whole point — a v6 dial that lands on a carrier /64 address instead
        // of device6 fails the provider's both-ends swap guard and is written back unchanged.
        static let v6FirstSrc    = 64   // 16 bytes, network order (the first IPv6 packet's source)
        static let v6FirstDst    = 80   // 16 bytes, network order
        static let v6SrcMatchCount = 96  // UInt32  v6: src == device6
        static let v6DstMatchCount = 100 // UInt32  v6: dst == fake6
        static let v6BothCount     = 104 // UInt32  v6: BOTH (the swap would fire)
        static let v6SrcPort     = 108  // UInt16
        static let v6DstPort     = 110  // UInt16
        static let v6NextHeader  = 112  // UInt8   IPv6 next-header (6 TCP / 17 UDP / 58 ICMPv6)
        static let v6Reserved    = 113  // UInt8
        static let v6FirstLen    = 114  // UInt16
        // 116..119 pad
        static let seqEnd        = 120  // UInt64  must equal `seq` for the record to be readable.
        // LAST field on purpose: the invalidate/revalidate window it defines now covers every v6 field
        // above, so a reader can never see a torn v6 address.
    }

    /// Per-record flags.
    ///
    /// `srcMatched`/`dstMatched` mean SEEN, NOT TOUCHED: the provider rewrites only when both ends
    /// match, so only `bothMatched` implies a packet was actually modified.
    enum RFlag {
        static let srcMatched: UInt32 = 1 << 0   // at least one packet had src == deviceIp
        static let dstMatched: UInt32 = 1 << 1   // at least one packet had dst == fakeIp
        static let bothMatched: UInt32 = 1 << 2  // at least one packet had BOTH (a true swap)
        static let sawIPv6: UInt32 = 1 << 3
        static let sawShort: UInt32 = 1 << 4     // an AF_INET packet under 20 bytes (provider skips it)
        static let wroteBack: UInt32 = 1 << 5    // writePackets was reached for this batch
        // v2 — the IPv6 twins of the first three. The provider's v6 arm rewrites only when BOTH match,
        // so `v6BothMatched` is the flag that says the v6 swap actually fired.
        static let v6SrcMatched: UInt32 = 1 << 6  // at least one v6 packet had src == device6
        static let v6DstMatched: UInt32 = 1 << 7  // at least one v6 packet had dst == fake6
        static let v6BothMatched: UInt32 = 1 << 8 // at least one v6 packet had BOTH (the swap fires)
    }

    /// Header flags.
    enum HFlag {
        static let providerStarted: UInt32 = 1 << 0
    }

    // MARK: - Raw memory helpers (all offsets are naturally aligned; see the layout note above)

    @inline(__always) private static func ld32(_ p: UnsafeRawPointer, _ o: Int) -> UInt32 {
        p.loadUnaligned(fromByteOffset: o, as: UInt32.self)
    }
    @inline(__always) private static func ld64(_ p: UnsafeRawPointer, _ o: Int) -> UInt64 {
        p.loadUnaligned(fromByteOffset: o, as: UInt64.self)
    }
    @inline(__always) private static func ldDouble(_ p: UnsafeRawPointer, _ o: Int) -> Double {
        p.loadUnaligned(fromByteOffset: o, as: Double.self)
    }
    @inline(__always) private static func ldI32(_ p: UnsafeRawPointer, _ o: Int) -> Int32 {
        p.loadUnaligned(fromByteOffset: o, as: Int32.self)
    }
    @inline(__always) private static func ld16(_ p: UnsafeRawPointer, _ o: Int) -> UInt16 {
        p.loadUnaligned(fromByteOffset: o, as: UInt16.self)
    }
    @inline(__always) private static func ld8(_ p: UnsafeRawPointer, _ o: Int) -> UInt8 {
        p.loadUnaligned(fromByteOffset: o, as: UInt8.self)
    }
    /// Copy 16 bytes (an IPv6 address) out of the mapping. Reader side only, so the allocation is fine.
    @inline(__always) private static func bytes16(_ p: UnsafeRawPointer, _ o: Int) -> [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: p.advanced(by: o), count: 16))
    }

    @inline(__always) private static func st32(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt32) {
        p.storeBytes(of: v, toByteOffset: o, as: UInt32.self)
    }
    @inline(__always) private static func st64(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt64) {
        p.storeBytes(of: v, toByteOffset: o, as: UInt64.self)
    }
    @inline(__always) private static func stDouble(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: Double) {
        p.storeBytes(of: v, toByteOffset: o, as: Double.self)
    }
    @inline(__always) private static func stI32(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: Int32) {
        p.storeBytes(of: v, toByteOffset: o, as: Int32.self)
    }
    @inline(__always) private static func st16(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt16) {
        p.storeBytes(of: v, toByteOffset: o, as: UInt16.self)
    }
    @inline(__always) private static func st8(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt8) {
        p.storeBytes(of: v, toByteOffset: o, as: UInt8.self)
    }
    @inline(__always) private static func add64(_ p: UnsafeMutableRawPointer, _ o: Int, _ v: UInt64) {
        st64(p, o, ld64(p, o) &+ v)
    }

    // MARK: - Writer state (extension side)

    nonisolated(unsafe) private static var map: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var mapFD: Int32 = -1
    nonisolated(unsafe) private static var nextProbeAt: Double = 0
    /// Byte offset of the record appended by the last `record(...)`, so `recordWriteBack` can
    /// back-patch it instead of spending a second slot. -1 when nothing has been appended yet.
    nonisolated(unsafe) private static var lastSlotOffset: Int = -1
    nonisolated(unsafe) private static var lastSeq: UInt64 = 0

    /// The armed mapping, or nil when tracing is off. THE HOT PATH — one clock read plus one
    /// compare when armed, one clock read plus one compare when disarmed.
    @inline(__always)
    private static func armedMap(now: Double) -> UnsafeMutableRawPointer? {
        if let existing = map {
            if now < ldDouble(existing, H.armedUntil) { return existing }
            unmap()          // the arm expired, or the app disarmed us
            return nil
        }
        guard now >= nextProbeAt else { return nil }
        nextProbeAt = now + probeInterval
        return openMap(now: now)
    }

    private static func openMap(now: Double) -> UnsafeMutableRawPointer? {
        guard let path = tracePath() else { return nil }
        // O_CREAT is deliberately absent: the file's EXISTENCE is half the gate. The extension never
        // creates it, so a build that is never armed never writes anything to the container.
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, Int(info.st_size) == fileSize else { close(fd); return nil }
        let raw = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p = raw, p != MAP_FAILED else { close(fd); return nil }
        guard ld32(p, H.magic) == magic,
              ld32(p, H.version) == formatVersion,
              ld32(p, H.capacity) == UInt32(capacity),
              ld32(p, H.recordSize) == UInt32(recordSize),
              now < ldDouble(p, H.armedUntil) else {
            munmap(p, fileSize)
            close(fd)
            return nil
        }
        map = p
        mapFD = fd
        lastSlotOffset = -1
        return p
    }

    private static func unmap() {
        if let p = map { munmap(p, fileSize) }
        if mapFD >= 0 { close(mapFD) }
        map = nil
        mapFD = -1
        lastSlotOffset = -1
    }

    // MARK: - The three provider call sites
    //
    // Each is ONE line at the call site and each is a no-op when tracing is off.

    /// ONE LINE IN THE READ LOOP, immediately after `var modified = packets`.
    ///
    /// Takes the batch BEFORE the swap and evaluates exactly the conditions the provider evaluates
    /// (v4: `src == deviceIp`, `dst == fakeIp`; v6: `src == device6`, `dst == fake6`) without mutating
    /// anything, so the trace says whether the swap fired rather than assuming it did. `packets` is
    /// untouched by the provider's loop (it mutates the `modified` copy), so this may sit before it.
    ///
    /// The two ends are counted SEPARATELY even though BOTH arms now rewrite only when both match
    /// (v4 since 2026-08-06, v6 from the start). A one-ended hit no longer means a rewrite happened —
    /// it means a packet that is not ours entered the tunnel and was written back untouched — but
    /// which end matched is still the whole diagnosis: src-only says something bound a socket to the
    /// tunnel address, dst-only says source-address selection did not pick it.
    ///
    /// `deviceIp6`/`fakeIp6` default to the all-zero address so every existing v4-only call site (and
    /// the host harness) compiles unchanged; the provider passes the real carved pair. The v6 match is
    /// SKIPPED entirely when both are zero, so a build with the v6 experiment off never reports a
    /// spurious "swap fired" against zeroed noise.
    static func record(packets: [Data], protocols: [NSNumber], deviceIp: UInt32, fakeIp: UInt32,
                       deviceIp6: in6_addr = in6_addr(), fakeIp6: in6_addr = in6_addr()) {
        let now = Date().timeIntervalSince1970
        guard let m = armedMap(now: now) else { return }

        let count = min(packets.count, protocols.count)
        var v4 = 0, v6 = 0
        var srcHits = 0, dstHits = 0, bothHits = 0
        var v6SrcHits = 0, v6DstHits = 0, v6BothHits = 0
        var flags: UInt32 = 0

        var haveFirst = false
        var reportedProto: Int32 = 0
        var firstSrc: UInt32 = 0, firstDst: UInt32 = 0
        var firstSrcPort: UInt16 = 0, firstDstPort: UInt16 = 0
        var firstIpProto: UInt8 = 0, firstLen: UInt16 = 0

        // The v6 arm's first packet, captured on the stack (in6_addr is a fixed 16 bytes — no heap).
        var device6 = deviceIp6
        var fake6 = fakeIp6
        let v6Active = isNonZero(&device6) || isNonZero(&fake6)
        var haveFirstV6 = false
        var firstV6Src = in6_addr(), firstV6Dst = in6_addr()
        var firstV6SrcPort: UInt16 = 0, firstV6DstPort: UInt16 = 0
        var firstV6Next: UInt8 = 0, firstV6Len: UInt16 = 0

        for i in 0..<count {
            let family = protocols[i].int32Value
            let packet = packets[i]

            if family == AF_INET6 {
                v6 += 1
                flags |= RFlag.sawIPv6
                // A v6 packet claims the "reported" (v4-shaped) slot only when no v4 packet has, so a
                // mixed batch still reports the v4 packet there. The v6 fields below are independent.
                if !haveFirst && reportedProto == 0 {
                    reportedProto = family
                    firstLen = UInt16(clamping: packet.count)
                }
                guard packet.count >= 40 else { continue }
                var srcFires = false, dstFires = false
                packet.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                    guard let b = buf.baseAddress, buf.count >= 40 else { return }
                    // IPv6: source at 8..<24, destination at 24..<40, next-header at 6.
                    if v6Active {
                        srcFires = withUnsafeBytes(of: &device6) {
                            memcmp(b.advanced(by: 8), $0.baseAddress!, 16) == 0
                        }
                        dstFires = withUnsafeBytes(of: &fake6) {
                            memcmp(b.advanced(by: 24), $0.baseAddress!, 16) == 0
                        }
                    }
                    if !haveFirstV6 {
                        haveFirstV6 = true
                        withUnsafeMutableBytes(of: &firstV6Src) { _ = memcpy($0.baseAddress!, b.advanced(by: 8), 16) }
                        withUnsafeMutableBytes(of: &firstV6Dst) { _ = memcpy($0.baseAddress!, b.advanced(by: 24), 16) }
                        firstV6Next = b.loadUnaligned(fromByteOffset: 6, as: UInt8.self)
                        firstV6Len = UInt16(clamping: packet.count)
                        // No IPv6 extension headers are assumed (a TCP SYN to remotepairingd has none),
                        // so the L4 header — and its ports — sit at the fixed offset 40.
                        if (firstV6Next == 6 || firstV6Next == 17), buf.count >= 44 {
                            firstV6SrcPort = UInt16(bigEndian: b.loadUnaligned(fromByteOffset: 40, as: UInt16.self))
                            firstV6DstPort = UInt16(bigEndian: b.loadUnaligned(fromByteOffset: 42, as: UInt16.self))
                        }
                    }
                }
                if srcFires { v6SrcHits += 1; flags |= RFlag.v6SrcMatched }
                if dstFires { v6DstHits += 1; flags |= RFlag.v6DstMatched }
                if srcFires && dstFires { v6BothHits += 1; flags |= RFlag.v6BothMatched }
                continue
            }
            guard family == AF_INET else { continue }
            v4 += 1
            guard packet.count >= 20 else { flags |= RFlag.sawShort; continue }

            var src: UInt32 = 0, dst: UInt32 = 0
            var ipProto: UInt8 = 0, sport: UInt16 = 0, dport: UInt16 = 0
            // Non-escaping, no allocation. Reads only; the provider's own copy is elsewhere.
            packet.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let b = buf.baseAddress, buf.count >= 20 else { return }
                src = UInt32(bigEndian: b.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                dst = UInt32(bigEndian: b.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
                ipProto = b.loadUnaligned(fromByteOffset: 9, as: UInt8.self)
                let ihl = Int(b.loadUnaligned(fromByteOffset: 0, as: UInt8.self) & 0x0F) * 4
                // Ports matter here: 49152 is remotepairingd, and "the packets arriving are not the
                // ones you think" is a real outcome this has to be able to show.
                if (ipProto == 6 || ipProto == 17), ihl >= 20, buf.count >= ihl + 4 {
                    sport = UInt16(bigEndian: b.loadUnaligned(fromByteOffset: ihl, as: UInt16.self))
                    dport = UInt16(bigEndian: b.loadUnaligned(fromByteOffset: ihl + 2, as: UInt16.self))
                }
            }

            let srcFires = (src == deviceIp)
            let dstFires = (dst == fakeIp)
            if srcFires { srcHits += 1; flags |= RFlag.srcMatched }
            if dstFires { dstHits += 1; flags |= RFlag.dstMatched }
            if srcFires && dstFires { bothHits += 1; flags |= RFlag.bothMatched }

            if !haveFirst {
                haveFirst = true
                reportedProto = AF_INET
                firstSrc = src
                firstDst = dst
                firstSrcPort = sport
                firstDstPort = dport
                firstIpProto = ipProto
                firstLen = UInt16(clamping: packet.count)
            }
        }

        // Stamp the configured pair every time. Costs two stores and means the report can compare
        // "what the provider was configured with" against "what actually showed up" even when the
        // optional `recordProviderStart` line was never added.
        st32(m, H.deviceIp, deviceIp)
        st32(m, H.fakeIp, fakeIp)

        let seq = ld64(m, H.writeSeq) &+ 1
        let slot = Int((seq &- 1) % UInt64(capacity))
        let off = headerSize + slot * recordSize

        // Invalidate, fill, revalidate. A concurrent reader sees seq != seqEnd for the duration and
        // skips the record rather than reporting a half-written one. Every v6 field is written here
        // too (zeros when the batch had no v6 packet) so a reused ring slot never leaks a stale address.
        st64(m, off + R.seqEnd, 0)
        st64(m, off + R.seq, seq)
        stDouble(m, off + R.time, now)
        st32(m, off + R.batchCount, UInt32(clamping: count))
        stI32(m, off + R.proto, reportedProto)
        st32(m, off + R.firstSrc, firstSrc)
        st32(m, off + R.firstDst, firstDst)
        st32(m, off + R.flags, flags)
        st32(m, off + R.srcMatchCount, UInt32(clamping: srcHits))
        st32(m, off + R.dstMatchCount, UInt32(clamping: dstHits))
        st32(m, off + R.v4Count, UInt32(clamping: v4))
        st32(m, off + R.v6Count, UInt32(clamping: v6))
        st32(m, off + R.wroteCount, 0)
        st16(m, off + R.srcPort, firstSrcPort)
        st16(m, off + R.dstPort, firstDstPort)
        st8(m, off + R.ipProto, firstIpProto)
        st8(m, off + R.reserved, 0)
        st16(m, off + R.firstLen, firstLen)
        withUnsafeBytes(of: &firstV6Src) { _ = memcpy(m.advanced(by: off + R.v6FirstSrc), $0.baseAddress!, 16) }
        withUnsafeBytes(of: &firstV6Dst) { _ = memcpy(m.advanced(by: off + R.v6FirstDst), $0.baseAddress!, 16) }
        st32(m, off + R.v6SrcMatchCount, UInt32(clamping: v6SrcHits))
        st32(m, off + R.v6DstMatchCount, UInt32(clamping: v6DstHits))
        st32(m, off + R.v6BothCount, UInt32(clamping: v6BothHits))
        st16(m, off + R.v6SrcPort, firstV6SrcPort)
        st16(m, off + R.v6DstPort, firstV6DstPort)
        st8(m, off + R.v6NextHeader, firstV6Next)
        st8(m, off + R.v6Reserved, 0)
        st16(m, off + R.v6FirstLen, firstV6Len)
        st64(m, off + R.seqEnd, seq)

        st64(m, H.writeSeq, seq)
        add64(m, H.readBatches, 1)
        add64(m, H.packetsSeen, UInt64(count))
        add64(m, H.v4Seen, UInt64(v4))
        add64(m, H.v6Seen, UInt64(v6))
        add64(m, H.srcMatched, UInt64(srcHits))
        add64(m, H.dstMatched, UInt64(dstHits))
        add64(m, H.bothMatched, UInt64(bothHits))
        add64(m, H.v6SrcMatched, UInt64(v6SrcHits))
        add64(m, H.v6DstMatched, UInt64(v6DstHits))
        add64(m, H.v6BothMatched, UInt64(v6BothHits))

        lastSlotOffset = off
        lastSeq = seq
    }

    /// True when any of the 16 address bytes is non-zero. Used to decide whether the v6 experiment is
    /// configured at all, so a zeroed default pair never produces spurious matches against zeroed noise.
    @inline(__always) private static func isNonZero(_ addr: inout in6_addr) -> Bool {
        withUnsafeBytes(of: &addr) { raw in raw.contains { $0 != 0 } }
    }

    /// ONE LINE AFTER `writePackets`. Back-patches the batch this call belongs to rather than
    /// spending a second ring slot, so each record reads as one complete story: "N arrived, M were
    /// swapped, N were written back". A record whose `wroteCount` stays 0 means writePackets was
    /// never reached for that batch — which is itself a finding.
    ///
    /// Reads `map` directly and never probes: if tracing is off this is a nil check and a return.
    static func recordWriteBack(count: Int) {
        guard let m = map, lastSlotOffset >= 0 else { return }
        let off = lastSlotOffset
        guard ld64(m, off + R.seq) == lastSeq else { return }
        st64(m, off + R.seqEnd, 0)
        st32(m, off + R.wroteCount, UInt32(clamping: count))
        st32(m, off + R.flags, ld32(m, off + R.flags) | RFlag.wroteBack)
        st64(m, off + R.seqEnd, lastSeq)
        add64(m, H.writtenBack, UInt64(max(0, count)))
        add64(m, H.writeBatches, 1)
    }

    /// OPTIONAL ONE LINE in `startTunnel`'s `setTunnelNetworkSettings` completion.
    ///
    /// Without it, "no records at all" is ambiguous between (a) nothing entered the tunnel and "the
    /// extension never ran" (stripped entitlement, provider crashed, tunnel never came up). With it,
    /// finding (a) is unambiguous: the provider started and then saw nothing.
    static func recordProviderStart(deviceIp: String, fakeIp: String) {
        let now = Date().timeIntervalSince1970
        guard let m = armedMap(now: now) else { return }
        st32(m, H.deviceIp, ipToUInt32(deviceIp))
        st32(m, H.fakeIp, ipToUInt32(fakeIp))
        st32(m, H.flags, ld32(m, H.flags) | HFlag.providerStarted)
        st32(m, H.providerStarts, ld32(m, H.providerStarts) &+ 1)
    }

    // MARK: - Arming (app side)

    enum ArmOutcome {
        case armed(until: Date)
        /// No candidate App Group resolved — the entitlement is missing or was stripped at re-sign.
        case noContainer(tried: [String])
        case failed(String)
    }

    /// Create (or re-arm and clear) the trace file. IN PLACE — the inode is never replaced, because
    /// the extension may already have it mapped and an atomic replace would leave it writing into an
    /// unlinked file.
    @discardableResult
    static func arm(forMinutes minutes: Double = defaultArmMinutes) -> ArmOutcome {
        guard let path = tracePath() else { return .noContainer(tried: appGroupCandidates()) }
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .failed("open() failed, errno \(errno)") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(fileSize)) == 0 else { return .failed("ftruncate() failed, errno \(errno)") }
        let raw = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p = raw, p != MAP_FAILED else { return .failed("mmap() failed, errno \(errno)") }
        defer { munmap(p, fileSize) }

        memset(p, 0, fileSize)
        let now = Date().timeIntervalSince1970
        let until = now + minutes * 60
        st32(p, H.magic, magic)
        st32(p, H.version, formatVersion)
        st32(p, H.capacity, UInt32(capacity))
        st32(p, H.recordSize, UInt32(recordSize))
        stDouble(p, H.armedAt, now)
        stDouble(p, H.armedUntil, until)
        msync(p, fileSize, MS_SYNC)

        // The extension runs while the device is locked. Complete-until-first-unlock would be enough
        // in practice, but there is nothing sensitive in a packet-count ring and a protection class
        // the extension cannot open would look exactly like finding (a).
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: path)
        return .armed(until: Date(timeIntervalSince1970: until))
    }

    /// Turn tracing off immediately. Zeroes `armedUntil` IN PLACE so a running extension sees it on
    /// its next batch through the mapping it already holds; the file is left in place (41 KB) so the
    /// last capture stays readable.
    static func disarm() {
        guard let path = tracePath() else { return }
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let raw = mmap(nil, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let p = raw, p != MAP_FAILED else { return }
        stDouble(p, H.armedUntil, 0)
        msync(p, fileSize, MS_SYNC)
        munmap(p, fileSize)
    }

    // MARK: - Reading (app side)

    struct Entry {
        var seq: UInt64
        var time: Date
        var batchCount: UInt32
        var proto: Int32
        var src: UInt32
        var dst: UInt32
        var srcPort: UInt16
        var dstPort: UInt16
        var ipProto: UInt8
        var firstLen: UInt16
        var flags: UInt32
        var srcMatchCount: UInt32
        var dstMatchCount: UInt32
        var v4Count: UInt32
        var v6Count: UInt32
        var wroteCount: UInt32
        // v2 — the IPv6 arm.
        var v6Src: [UInt8]           // 16 bytes, the first v6 packet's pre-swap source
        var v6Dst: [UInt8]           // 16 bytes
        var v6SrcPort: UInt16
        var v6DstPort: UInt16
        var v6NextHeader: UInt8
        var v6FirstLen: UInt16
        var v6SrcMatchCount: UInt32
        var v6DstMatchCount: UInt32
        var v6BothCount: UInt32

        var srcMatched: Bool  { flags & RFlag.srcMatched  != 0 }
        var dstMatched: Bool  { flags & RFlag.dstMatched  != 0 }
        var bothMatched: Bool { flags & RFlag.bothMatched != 0 }
        var sawIPv6: Bool     { flags & RFlag.sawIPv6     != 0 }
        var sawShort: Bool    { flags & RFlag.sawShort    != 0 }
        var wroteBack: Bool   { flags & RFlag.wroteBack   != 0 }
        var v6SrcMatched: Bool  { flags & RFlag.v6SrcMatched  != 0 }
        var v6DstMatched: Bool  { flags & RFlag.v6DstMatched  != 0 }
        var v6BothMatched: Bool { flags & RFlag.v6BothMatched != 0 }
        /// True when this record actually carried a v6 packet worth printing (not a stale zeroed slot).
        var hasV6: Bool { v6Count > 0 }
    }

    struct Snapshot {
        var appGroup: String
        var path: String
        var armedAt: Date
        var armedUntil: Date
        var armedNow: Bool
        var deviceIp: UInt32
        var fakeIp: UInt32
        var providerStarted: Bool
        var providerStarts: UInt32
        var writeSeq: UInt64
        var packetsSeen: UInt64
        var v4Seen: UInt64
        var v6Seen: UInt64
        var srcMatched: UInt64
        var dstMatched: UInt64
        var bothMatched: UInt64
        var writtenBack: UInt64
        var readBatches: UInt64
        var writeBatches: UInt64
        // v2 — the IPv6 arm's aggregate match totals.
        var v6SrcMatched: UInt64
        var v6DstMatched: UInt64
        var v6BothMatched: UInt64
        /// Oldest first.
        var entries: [Entry]
        /// Records overwritten because the ring wrapped.
        var dropped: UInt64
        /// Records skipped because they were mid-write when read (seq != seqEnd).
        var torn: Int
    }

    enum ReadOutcome {
        case ok(Snapshot)
        /// The trace has never been armed on this device (no file).
        case neverArmed(path: String)
        case noContainer(tried: [String])
        case unreadable(String)
    }

    static func snapshot() -> ReadOutcome {
        guard let path = tracePath() else { return .noContainer(tried: appGroupCandidates()) }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return errno == ENOENT ? .neverArmed(path: path)
                                   : .unreadable("open() failed, errno \(errno)")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable("fstat() failed, errno \(errno)") }
        guard Int(info.st_size) == fileSize else {
            return .unreadable("trace file is \(info.st_size) bytes, expected \(fileSize) — stale format")
        }
        let raw = mmap(nil, fileSize, PROT_READ, MAP_SHARED, fd, 0)
        guard let p = raw, p != MAP_FAILED else { return .unreadable("mmap() failed, errno \(errno)") }
        defer { munmap(p, fileSize) }

        guard ld32(p, H.magic) == magic else { return .unreadable("bad magic — not a Wander packet trace") }
        guard ld32(p, H.version) == formatVersion else {
            return .unreadable("format version \(ld32(p, H.version)), this build reads \(formatVersion)")
        }
        let cap = Int(ld32(p, H.capacity))
        let recSize = Int(ld32(p, H.recordSize))
        guard cap == capacity, recSize == recordSize else {
            return .unreadable("layout mismatch (capacity \(cap), record \(recSize))")
        }

        let writeSeq = ld64(p, H.writeSeq)
        let armedUntil = ldDouble(p, H.armedUntil)
        let now = Date().timeIntervalSince1970

        var entries: [Entry] = []
        var torn = 0
        let available = Int(min(writeSeq, UInt64(capacity)))
        if available > 0 {
            entries.reserveCapacity(available)
            let firstSeq = writeSeq - UInt64(available) + 1
            for n in 0..<available {
                let seq = firstSeq + UInt64(n)
                let off = headerSize + Int((seq &- 1) % UInt64(capacity)) * recordSize
                // Read the two sequence stamps around the body; a mismatch means the writer was
                // inside this record while we copied it.
                let s0 = ld64(p, off + R.seq)
                let entry = Entry(
                    seq: s0,
                    time: Date(timeIntervalSince1970: ldDouble(p, off + R.time)),
                    batchCount: ld32(p, off + R.batchCount),
                    proto: ldI32(p, off + R.proto),
                    src: ld32(p, off + R.firstSrc),
                    dst: ld32(p, off + R.firstDst),
                    srcPort: ld16(p, off + R.srcPort),
                    dstPort: ld16(p, off + R.dstPort),
                    ipProto: ld8(p, off + R.ipProto),
                    firstLen: ld16(p, off + R.firstLen),
                    flags: ld32(p, off + R.flags),
                    srcMatchCount: ld32(p, off + R.srcMatchCount),
                    dstMatchCount: ld32(p, off + R.dstMatchCount),
                    v4Count: ld32(p, off + R.v4Count),
                    v6Count: ld32(p, off + R.v6Count),
                    wroteCount: ld32(p, off + R.wroteCount),
                    v6Src: bytes16(p, off + R.v6FirstSrc),
                    v6Dst: bytes16(p, off + R.v6FirstDst),
                    v6SrcPort: ld16(p, off + R.v6SrcPort),
                    v6DstPort: ld16(p, off + R.v6DstPort),
                    v6NextHeader: ld8(p, off + R.v6NextHeader),
                    v6FirstLen: ld16(p, off + R.v6FirstLen),
                    v6SrcMatchCount: ld32(p, off + R.v6SrcMatchCount),
                    v6DstMatchCount: ld32(p, off + R.v6DstMatchCount),
                    v6BothCount: ld32(p, off + R.v6BothCount))
                let s1 = ld64(p, off + R.seqEnd)
                if s0 != s1 || s0 == 0 { torn += 1; continue }
                entries.append(entry)
            }
        }

        let snap = Snapshot(
            appGroup: resolvedAppGroup() ?? "?",
            path: path,
            armedAt: Date(timeIntervalSince1970: ldDouble(p, H.armedAt)),
            armedUntil: Date(timeIntervalSince1970: armedUntil),
            armedNow: now < armedUntil,
            deviceIp: ld32(p, H.deviceIp),
            fakeIp: ld32(p, H.fakeIp),
            providerStarted: ld32(p, H.flags) & HFlag.providerStarted != 0,
            providerStarts: ld32(p, H.providerStarts),
            writeSeq: writeSeq,
            packetsSeen: ld64(p, H.packetsSeen),
            v4Seen: ld64(p, H.v4Seen),
            v6Seen: ld64(p, H.v6Seen),
            srcMatched: ld64(p, H.srcMatched),
            dstMatched: ld64(p, H.dstMatched),
            bothMatched: ld64(p, H.bothMatched),
            writtenBack: ld64(p, H.writtenBack),
            readBatches: ld64(p, H.readBatches),
            writeBatches: ld64(p, H.writeBatches),
            v6SrcMatched: ld64(p, H.v6SrcMatched),
            v6DstMatched: ld64(p, H.v6DstMatched),
            v6BothMatched: ld64(p, H.v6BothMatched),
            entries: entries,
            dropped: writeSeq > UInt64(capacity) ? writeSeq - UInt64(capacity) : 0,
            torn: torn)
        return .ok(snap)
    }

    // MARK: - Small shared formatting helpers

    /// Host-order UInt32 back to a dotted quad.
    static func dotted(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// 16 raw network-order bytes back to an IPv6 presentation string (e.g. `2600:382:…:2d10`).
    /// Returns a raw-hex fallback rather than failing, so a diagnostic line is never blank.
    static func dotted6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "?" }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { raw in for i in 0..<16 { raw[i] = bytes[i] } }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return String(cString: buffer)
    }

    /// Same parse the provider uses, so the addresses stamped into the header are the same numbers
    /// the swap compares against.
    static func ipToUInt32(_ ipString: String) -> UInt32 {
        let c = ipString.split(separator: ".")
        guard c.count == 4,
              let b1 = UInt32(c[0]), let b2 = UInt32(c[1]),
              let b3 = UInt32(c[2]), let b4 = UInt32(c[3]),
              b1 <= 255, b2 <= 255, b3 <= 255, b4 <= 255 else { return 0 }
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }

    static func protocolName(_ ipProto: UInt8) -> String {
        switch ipProto {
        case 1: return "ICMP"
        case 2: return "IGMP"
        case 6: return "TCP"
        case 17: return "UDP"
        case 58: return "ICMPv6"
        case 0: return "?"
        default: return "ip-proto \(ipProto)"
        }
    }

    static func familyName(_ family: Int32) -> String {
        switch family {
        case AF_INET: return "IPv4"
        case AF_INET6: return "IPv6"
        case 0: return "none"
        default: return "af \(family)"
        }
    }
}
