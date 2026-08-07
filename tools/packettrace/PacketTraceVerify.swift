// Host harness. Compiles the REAL PacketTrace.swift (only the App Group lookup is swapped for an
// env-var path) and the REAL PacketTraceReport.swift, and drives them with synthetic packet batches
// to prove the writer -> file -> reader -> verdict chain end to end.
//
// One scenario per process, because the extension-side statics (the mmap handle and the 2-second
// re-probe throttle) are per-process by design.

import Foundation

// MARK: - Stubs for the two app-side symbols PacketTraceReport touches

final class LogManager {
    static let shared = LogManager()
    var lines: [String] = []
    func addInfoLog(_ m: String) { lines.append(m) }
}
enum NetworkInterfaceDump {
    static func retain(_ lines: [String]) {}
}
extension UserDefaults {
    enum Keys {
        static let tunnelInterfaceIP = "TunnelInterfaceIP"
        static let targetDeviceIP = "TunnelDeviceIP"
    }
}
/// Stand-in for the app-target symbol `PacketTraceReport.v6Verdict` names when it prints the CONFIGURED
/// v6 pair. On device these come from the live tunnel; here they are the carved-carrier pair the v6
/// scenarios below dial, so the verdict text can be asserted end to end.
enum DeviceConnectionContext {
    static var activeTunnelInterfaceIPv6 = "2600:382:741c:7eca:7761:6e64:6572:2d10"   // device6
    static var activeTargetIPv6Address   = "2600:382:741c:7eca:7761:6e64:6572:2d11"   // fake6
}

// MARK: - Packet synthesis

func ip(_ s: String) -> UInt32 { PacketTrace.ipToUInt32(s) }

/// A real IPv4 + TCP packet with correct lengths (checksums are irrelevant here: the trace only
/// reads addresses, protocol and ports).
func v4tcp(src: String, dst: String, sport: UInt16, dport: UInt16, ihl: Int = 5, payload: Int = 0) -> Data {
    let headerLen = ihl * 4
    var d = Data(repeating: 0, count: headerLen + 20 + payload)
    d[0] = UInt8(0x40 | ihl)
    let total = UInt16(d.count)
    d[2] = UInt8(total >> 8); d[3] = UInt8(total & 0xFF)
    d[8] = 64
    d[9] = 6 // TCP
    let s = ip(src), t = ip(dst)
    for i in 0..<4 { d[12 + i] = UInt8((s >> (24 - 8 * i)) & 0xFF) }
    for i in 0..<4 { d[16 + i] = UInt8((t >> (24 - 8 * i)) & 0xFF) }
    d[headerLen + 0] = UInt8(sport >> 8); d[headerLen + 1] = UInt8(sport & 0xFF)
    d[headerLen + 2] = UInt8(dport >> 8); d[headerLen + 3] = UInt8(dport & 0xFF)
    d[headerLen + 12] = 0x50
    d[headerLen + 13] = 0x02 // SYN
    return d
}

/// A real IPv4 + UDP packet. Exists because the packet that exposed the one-sided-rewrite bug on
/// device was UDP: FaceTime media, `10.7.0.0:16394 -> 98.51.183.236:16393 UDP len=124`.
func v4udp(src: String, dst: String, sport: UInt16, dport: UInt16, payload: Int = 96) -> Data {
    var d = Data(repeating: 0, count: 20 + 8 + payload)
    d[0] = 0x45
    let total = UInt16(d.count)
    d[2] = UInt8(total >> 8); d[3] = UInt8(total & 0xFF)
    d[8] = 64
    d[9] = 17 // UDP
    let s = ip(src), t = ip(dst)
    for i in 0..<4 { d[12 + i] = UInt8((s >> (24 - 8 * i)) & 0xFF) }
    for i in 0..<4 { d[16 + i] = UInt8((t >> (24 - 8 * i)) & 0xFF) }
    d[20] = UInt8(sport >> 8); d[21] = UInt8(sport & 0xFF)
    d[22] = UInt8(dport >> 8); d[23] = UInt8(dport & 0xFF)
    let ulen = UInt16(8 + payload)
    d[24] = UInt8(ulen >> 8); d[25] = UInt8(ulen & 0xFF)
    for i in 0..<payload { d[28 + i] = UInt8(0x40 &+ UInt8(i & 0x3F)) }   // non-zero body
    return d
}

/// RFC 1071 one's-complement sum over the IPv4 header, returned already complemented.
func ipHeaderChecksum(_ d: Data) -> UInt16 {
    let ihl = Int(d[0] & 0x0F) * 4
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < ihl { sum &+= (UInt32(d[i]) << 8) | UInt32(d[i + 1]); i += 2 }
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return UInt16(truncatingIfNeeded: ~sum)
}
/// Stamp a CORRECT header checksum into a synthetic packet, so "the swap preserves the checksum" is
/// something these scenarios can assert rather than assume. (The full arithmetic — including the TCP
/// pseudo-header — is proven in tools/packetmath.)
func sealed(_ d: Data) -> Data {
    var out = d
    out[10] = 0; out[11] = 0
    let ck = ipHeaderChecksum(out)
    out[10] = UInt8(ck >> 8); out[11] = UInt8(ck & 0xFF)
    return out
}
func ipChecksumValid(_ d: Data) -> Bool { ipHeaderChecksum(d) == 0 }

func v6noise() -> Data {
    var d = Data(repeating: 0, count: 48)
    d[0] = 0x60
    d[6] = 58 // ICMPv6
    return d
}

/// 16 network-order bytes for an IPv6 literal.
func ip6bytes(_ s: String) -> [UInt8] {
    var a = in6_addr()
    _ = s.withCString { inet_pton(AF_INET6, $0, &a) }
    return withUnsafeBytes(of: &a) { Array($0) }
}
/// `in6_addr` for an IPv6 literal, for the record()/provider `deviceIp6:`/`fakeIp6:` arguments.
func addr6(_ s: String) -> in6_addr {
    var a = in6_addr()
    _ = s.withCString { inet_pton(AF_INET6, $0, &a) }
    return a
}
/// A real IPv6 + TCP packet: 40-byte fixed header (src at 8, dst at 24, next-header 6=TCP) then a
/// 20-byte TCP header (sport at 40, dport at 42). Checksums are irrelevant — the trace reads addresses
/// and ports only.
func v6tcp(src: String, dst: String, sport: UInt16, dport: UInt16) -> Data {
    var d = Data(repeating: 0, count: 40 + 20)
    d[0] = 0x60
    let payload = UInt16(20)
    d[4] = UInt8(payload >> 8); d[5] = UInt8(payload & 0xFF)
    d[6] = 6   // next header = TCP
    d[7] = 64  // hop limit
    let s = ip6bytes(src), t = ip6bytes(dst)
    for i in 0..<16 { d[8 + i] = s[i] }
    for i in 0..<16 { d[24 + i] = t[i] }
    d[40] = UInt8(sport >> 8); d[41] = UInt8(sport & 0xFF)
    d[42] = UInt8(dport >> 8); d[43] = UInt8(dport & 0xFF)
    d[40 + 12] = 0x50
    d[40 + 13] = 0x02 // SYN
    return d
}

let AFI = NSNumber(value: AF_INET)
let AFI6 = NSNumber(value: AF_INET6)

let device6 = DeviceConnectionContext.activeTunnelInterfaceIPv6
let fake6 = DeviceConnectionContext.activeTargetIPv6Address
// A plausible carrier-selected source: same /64 as device6 (that is the whole mechanism), different
// host bits — what RFC 6724 can pick instead of device6 on cellular.
let carrierSrc6 = "2600:382:741c:7eca:aaaa:bbbb:cccc:dddd"

// MARK: - Assertions

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("    [\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures += 1 }
}

func snapshotOrDie() -> PacketTrace.Snapshot {
    switch PacketTrace.snapshot() {
    case .ok(let s): return s
    case .neverArmed(let p): print("    !! neverArmed \(p)"); exit(2)
    case .noContainer(let t): print("    !! noContainer \(t)"); exit(2)
    case .unreadable(let w): print("    !! unreadable \(w)"); exit(2)
    }
}

func headline() -> String { PacketTraceReport.verdict(snapshotOrDie()).headline }

let device = "10.7.0.0"
let fake = "10.7.0.1"
let deviceV = ip(device), fakeV = ip(fake)

let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "help"
print("--- \(scenario) ---")

switch scenario {

case "layout":
    check("header is 192 bytes", PacketTrace.headerSize == 192)
    check("record is 128 bytes", PacketTrace.recordSize == 128)
    check("capacity is capped at 512", PacketTrace.capacity == 512)
    check("file is exactly header + capacity*record", PacketTrace.fileSize == 192 + 512 * 128,
          "\(PacketTrace.fileSize) bytes = \(PacketTrace.fileSize / 1024) KB")
    check("record size is a multiple of 8 (every field naturally aligned)", PacketTrace.recordSize % 8 == 0)
    check("header size is a multiple of 8", PacketTrace.headerSize % 8 == 0)
    check("dotted() round-trips", PacketTrace.dotted(ip("192.168.4.241")) == "192.168.4.241",
          PacketTrace.dotted(ip("192.168.4.241")))
    check("dotted() round-trips 10.7.0.1", PacketTrace.dotted(ip("10.7.0.1")) == "10.7.0.1")
    check("ipToUInt32 rejects out-of-range octets", ip("10.7.0.999") == 0)

case "disarmed-is-a-noop":
    // The gate: with no file at all, every entry point must return without creating anything.
    let path = ProcessInfo.processInfo.environment["WANDER_TRACE_PATH"]!
    try? FileManager.default.removeItem(atPath: path)
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    check("no trace file is created when disarmed", !FileManager.default.fileExists(atPath: path))
    if case .neverArmed = PacketTrace.snapshot() {
        check("reader reports neverArmed rather than inventing a verdict", true)
    } else {
        check("reader reports neverArmed rather than inventing a verdict", false)
    }

case "a-no-packets":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    let s = snapshotOrDie()
    check("provider start was recorded", s.providerStarted)
    check("zero batches", s.readBatches == 0)
    check("verdict is (a) ROUTING", headline().hasPrefix("(a) NO PACKETS ARRIVE"), headline())

case "a-ambiguous":
    _ = PacketTrace.arm()
    let s = snapshotOrDie()
    check("no provider-start marker", !s.providerStarted)
    check("verdict is the ambiguous (a?)", headline().hasPrefix("(a?)"), headline())

case "a-ipv6-only":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [v6noise(), v6noise()], protocols: [AFI6, AFI6],
                       deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 2)
    let s = snapshotOrDie()
    check("batches arrived", s.readBatches == 1)
    check("all IPv6, no IPv4", s.v4Seen == 0 && s.v6Seen == 2)
    check("verdict is (a) NO IPv4 PACKETS", headline().hasPrefix("(a) NO IPv4 PACKETS"), headline())

case "v6-source-mismatch":
    // THE DECISIVE NEXT-RUN CASE. A v6 dial whose dst IS fake6 but whose src is NOT device6 (the kernel
    // sourced it off the carrier /64). dst matches, src does not, the both-ends swap is a no-op.
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [v6tcp(src: carrierSrc6, dst: fake6, sport: 51000, dport: 49152)],
                       protocols: [AFI6], deviceIp: deviceV, fakeIp: fakeV,
                       deviceIp6: addr6(device6), fakeIp6: addr6(fake6))
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("one IPv6 packet, no IPv4", s.v4Seen == 0 && s.v6Seen == 1)
    check("v6 dst matched, v6 src did NOT, no full swap",
          s.v6DstMatched == 1 && s.v6SrcMatched == 0 && s.v6BothMatched == 0)
    check("verdict is (b/v6) SRC MISMATCH / SWAP NO-OP",
          headline().hasPrefix("(b/v6) IPv6 PACKETS ARRIVE, DST MATCHES, SRC DOES NOT"), headline())
    let e = s.entries.last!
    check("the record captured the kernel-selected source verbatim",
          PacketTrace.dotted6(e.v6Src) == carrierSrc6, PacketTrace.dotted6(e.v6Src))
    check("the record captured fake6 as the dialled destination",
          PacketTrace.dotted6(e.v6Dst) == "2600:382:741c:7eca:7761:6e64:6572:2d11", PacketTrace.dotted6(e.v6Dst))
    check("the report names the actual source and the expected device6",
          PacketTraceReport.verdict(s).detail.contains { $0.contains(carrierSrc6) })

case "v6-full-swap":
    // The v6 loopback working as intended: src == device6 AND dst == fake6, so the swap fires and the
    // packet is written back. Now the verdict must point past the swap (reinjection / daemon / DDI).
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [v6tcp(src: device6, dst: fake6, sport: 51000, dport: 49152)],
                       protocols: [AFI6], deviceIp: deviceV, fakeIp: fakeV,
                       deviceIp6: addr6(device6), fakeIp6: addr6(fake6))
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("the v6 swap fired on both ends", s.v6BothMatched == 1 && s.v6SrcMatched == 1 && s.v6DstMatched == 1)
    check("written back", s.writtenBack == 1 && s.writeBatches == 1)
    check("verdict is (c/v6) written back — past the swap",
          headline().hasPrefix("(c/v6) THE v6 SWAP FIRES AND PACKETS ARE WRITTEN BACK"), headline())
    let e = s.entries.last!
    check("record flagged V6-SWAPPED", e.v6BothMatched && e.wroteBack)
    check("v6 ports recorded", e.v6DstPort == 49152 && e.v6SrcPort == 51000, "\(e.v6SrcPort)→\(e.v6DstPort)")

case "v6-off-no-false-match":
    // Guard: with the experiment OFF (default zero device6/fake6), a v6 packet that happens to carry
    // zero addresses (or any addresses) must NOT be reported as a swap match.
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [v6tcp(src: carrierSrc6, dst: fake6, sport: 51000, dport: 49152)],
                       protocols: [AFI6], deviceIp: deviceV, fakeIp: fakeV)   // no v6 pair passed
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("v6 seen but NO v6 matches when the experiment is off",
          s.v6Seen == 1 && s.v6SrcMatched == 0 && s.v6DstMatched == 0 && s.v6BothMatched == 0)
    check("verdict stays (a) routing, not a v6 verdict", headline().hasPrefix("(a) NO IPv4 PACKETS"), headline())

case "b-no-match":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    // Packets arrive but they are addressed to something else entirely.
    PacketTrace.record(packets: [v4tcp(src: "192.168.4.20", dst: "192.168.4.241", sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("one IPv4 packet seen", s.v4Seen == 1)
    check("neither condition fired", s.srcMatched == 0 && s.dstMatched == 0 && s.bothMatched == 0)
    check("verdict is (b) SWAP NEVER FIRES",
          headline().hasPrefix("(b) PACKETS ARRIVE BUT THE SWAP NEVER FIRES"), headline())
    check("the report names the observed addresses",
          PacketTraceReport.verdict(s).detail.contains { $0.contains("192.168.4.20 → 192.168.4.241") })

case "b-one-sided":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    // Source-address selection picked en0: dst == fakeIp fires, src == deviceIp does not.
    PacketTrace.record(packets: [v4tcp(src: "192.168.4.241", dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("only dst matched", s.dstMatched == 1 && s.srcMatched == 0 && s.bothMatched == 0)
    // The headline used to say the packet was being CORRUPTED, which was true of the two-independent-
    // `if`s rewrite. Since 2026-08-06 the provider requires both ends, so a one-sided hit is an
    // observation, not damage — and the report must say so or it sends the next reader hunting a
    // corruption bug that no longer exists.
    check("verdict is (b) ONE SIDE, and says nothing was rewritten",
          headline().contains("ONLY ONE SIDE MATCHES") && headline().contains("Nothing was rewritten"), headline())
    check("the detail spells out SEEN, NOT TOUCHED",
          PacketTraceReport.verdict(s).detail.contains { $0.contains("SEEN, NOT TOUCHED") })
    check("no line still claims the packet is corrupted",
          !PacketTraceReport.verdict(s).detail.contains { $0.contains("MUTATION") })
    check("the row label says not touched",
          PacketTraceReport.report(s).contains { $0.contains("ONE-SIDED(not touched)") })

case "c-full":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    for i in 0..<3 {
        PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: UInt16(51000 + i), dport: 49152)],
                           protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    let s = snapshotOrDie()
    check("3 batches, 3 packets", s.readBatches == 3 && s.v4Seen == 3)
    check("both conditions fired on all 3", s.bothMatched == 3)
    check("all 3 written back", s.writtenBack == 3 && s.writeBatches == 3)
    check("verdict is (c) REINJECTION / SETTINGS",
          headline().contains("WRITTEN BACK — this is a REINJECTION"), headline())
    let e = s.entries.last!
    check("dotted quads survive the round trip",
          PacketTrace.dotted(e.src) == device && PacketTrace.dotted(e.dst) == fake,
          "\(PacketTrace.dotted(e.src)) → \(PacketTrace.dotted(e.dst))")
    check("the destination port is recorded (49152 = remotepairingd)", e.dstPort == 49152, "\(e.dstPort)")
    check("the source port is recorded", e.srcPort == 51002, "\(e.srcPort)")
    check("protocol decoded as TCP", PacketTrace.protocolName(e.ipProto) == "TCP")
    check("record is flagged SWAPPED and written back", e.bothMatched && e.wroteBack)

case "c-not-written":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    // The swap fires but writePackets is never reached.
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    let s = snapshotOrDie()
    check("swap fired", s.bothMatched == 1)
    check("nothing written back", s.writtenBack == 0 && s.writeBatches == 0)
    check("verdict distinguishes it from a clean (c)",
          headline().hasPrefix("(c) THE SWAP FIRES BUT NOTHING IS WRITTEN BACK"), headline())

case "ihl-and-short":
    _ = PacketTrace.arm()
    // Options present (IHL=8): src/dst are at fixed offsets, but the PORTS move.
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 4000, dport: 49152, ihl: 8)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    var s = snapshotOrDie()
    var e = s.entries.last!
    check("IHL=8: addresses still read correctly",
          PacketTrace.dotted(e.src) == device && PacketTrace.dotted(e.dst) == fake)
    check("IHL=8: ports read past the options, not at a fixed 20",
          e.srcPort == 4000 && e.dstPort == 49152, "\(e.srcPort)→\(e.dstPort)")
    // Runt: shorter than an IPv4 header. Must be counted and flagged, never read out of bounds.
    PacketTrace.record(packets: [Data(repeating: 0x45, count: 12)], protocols: [AFI],
                       deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    s = snapshotOrDie()
    e = s.entries.last!
    check("a 12-byte packet is flagged SHORT and not parsed", e.sawShort && e.src == 0 && e.dst == 0)
    check("it still counts as an IPv4 packet seen", s.v4Seen == 2)
    // Mixed batch: the reported packet must be the first IPv4 one, not the IPv6 noise at index 0.
    PacketTrace.record(packets: [v6noise(), v4tcp(src: device, dst: fake, sport: 7000, dport: 49152)],
                       protocols: [AFI6, AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 2)
    s = snapshotOrDie()
    e = s.entries.last!
    check("mixed batch reports the first IPv4 packet, not the v6 noise",
          e.proto == AF_INET && e.srcPort == 7000 && e.v6Count == 1 && e.v4Count == 1)

case "ring-wrap":
    _ = PacketTrace.arm()
    let n = PacketTrace.capacity + 10
    for i in 0..<n {
        PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: UInt16(1024 + i % 60000), dport: 49152)],
                           protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    let s = snapshotOrDie()
    check("counters see every batch", s.readBatches == UInt64(n))
    check("the ring is hard-capped at capacity", s.entries.count == PacketTrace.capacity, "\(s.entries.count)")
    check("the overflow is reported, not hidden", s.dropped == 10, "\(s.dropped)")
    check("entries are oldest-first and contiguous",
          s.entries.first!.seq == UInt64(n - PacketTrace.capacity + 1) && s.entries.last!.seq == UInt64(n),
          "\(s.entries.first!.seq)…\(s.entries.last!.seq)")
    check("verdict still (c) after wrapping", headline().contains("REINJECTION"))
    let size = (try? FileManager.default.attributesOfItem(
        atPath: ProcessInfo.processInfo.environment["WANDER_TRACE_PATH"]!)[.size] as? Int) ?? nil
    check("file did not grow", size == PacketTrace.fileSize, "\(size ?? -1) bytes")

case "expiry":
    // The safety gate: an arm that has run out must stop the writer dead.
    _ = PacketTrace.arm(forMinutes: -1)   // already expired
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    let s = snapshotOrDie()
    check("an expired arm records nothing", s.readBatches == 0 && s.writeSeq == 0)
    check("the reader reports it as EXPIRED", !s.armedNow)

case "disarm-stops-a-live-writer":
    _ = PacketTrace.arm()
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    check("one batch recorded while armed", snapshotOrDie().readBatches == 1)
    // Disarm through the same mapping a running extension would still be holding.
    PacketTrace.disarm()
    for _ in 0..<5 {
        PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                           protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    let s = snapshotOrDie()
    check("the live writer stops on its next batch", s.readBatches == 1, "\(s.readBatches)")
    check("the last capture stays readable", s.entries.count == 1 && !s.armedNow)

case "torn-record":
    // A record caught mid-write must be skipped, never misreported. Simulate by corrupting the
    // trailing sequence stamp of the middle record.
    _ = PacketTrace.arm()
    for i in 0..<3 {
        PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: UInt16(9000 + i), dport: 49152)],
                           protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    check("3 readable before corruption", snapshotOrDie().entries.count == 3)
    let path = ProcessInfo.processInfo.environment["WANDER_TRACE_PATH"]!
    let fh = try! FileHandle(forUpdating: URL(fileURLWithPath: path))
    // record #2 lives at slot 1; seqEnd is now the LAST 8 bytes of the record (v2 moved it there so its
    // invalidate/revalidate window covers the appended v6 fields too).
    try! fh.seek(toOffset: UInt64(PacketTrace.headerSize + 1 * PacketTrace.recordSize + (PacketTrace.recordSize - 8)))
    fh.write(Data(repeating: 0xEE, count: 8))
    try! fh.close()
    let s = snapshotOrDie()
    check("the torn record is skipped", s.entries.count == 2, "\(s.entries.count) entries")
    check("it is reported, not silently dropped", s.torn == 1)
    check("the surviving records are the intact ones",
          s.entries.map(\.seq) == [1, 3], "\(s.entries.map(\.seq))")

// ============================================================================
// THE REWRITE ITSELF — driven through the SHIPPING `PacketTunnelProvider.rewriteIPv4/6`, compiled
// verbatim by run.sh. Added 2026-08-06, after a device trace caught the old two-independent-`if`s
// version mangling live FaceTime traffic (1029 packets in one session).
// ============================================================================

case "v4-rewrite-both-match":
    // THE WORKING PATH — Cellular Mode (airplane-on → connect → teleport), confirmed on device on
    // the 10.7.0.x default. BOTH directions of the loopback are device→fake (the daemon's reply
    // leaves as deviceIp:49152 → fakeIp:ephemeral), so both must still be swapped exactly as before.
    let dial = sealed(v4tcp(src: device, dst: fake, sport: 51000, dport: 49152))
    let reply = sealed(v4tcp(src: device, dst: fake, sport: 49152, dport: 51000, payload: 8))
    check("the synthetic packets start out with a valid header checksum",
          ipChecksumValid(dial) && ipChecksumValid(reply))

    var batch = [dial, reply]
    PacketTunnelProvider.rewriteIPv4(&batch, protocols: [AFI, AFI], deviceIp: deviceV, fakeIp: fakeV)
    for (n, out) in batch.enumerated() {
        let original = n == 0 ? dial : reply
        check("[\(n)] src → fake, dst → device (a true swap)",
              Array(out[12..<16]) == Array(original[16..<20])
                && Array(out[16..<20]) == Array(original[12..<16]),
              "\(PacketTrace.dotted(ip(device))) …")
        check("[\(n)] every byte outside 12..19 is untouched",
              Array(out[0..<12]) == Array(original[0..<12]) && Array(out[20...]) == Array(original[20...]))
        check("[\(n)] the header checksum is STILL VALID without recomputation (swap is a permutation)",
              ipChecksumValid(out))
    }

    // A mixed batch: only the packet that matches BOTH ends may change.
    let facetime = sealed(v4udp(src: device, dst: "98.51.183.236", sport: 16394, dport: 16393))
    let en0 = sealed(v4tcp(src: "192.168.4.241", dst: fake, sport: 51000, dport: 49152))
    let foreign = sealed(v4tcp(src: "192.168.4.20", dst: "192.168.4.241", sport: 1234, dport: 80))
    var mixed = [facetime, dial, en0, foreign]
    PacketTunnelProvider.rewriteIPv4(&mixed, protocols: [AFI, AFI, AFI, AFI],
                                     deviceIp: deviceV, fakeIp: fakeV)
    check("mixed batch: the both-match packet is swapped", Array(mixed[1][12..<16]) == Array(dial[16..<20]))
    check("mixed batch: the src-only (FaceTime) packet is byte-identical", mixed[0] == facetime)
    check("mixed batch: the dst-only packet is byte-identical", mixed[2] == en0)
    check("mixed batch: the no-match packet is byte-identical", mixed[3] == foreign)

    // A packet the OS labels IPv6 must never be touched by the v4 arm even if its first 20 bytes
    // happen to match, and a runt must be skipped by the `count >= 20` guard.
    var guarded = [dial, dial.prefix(19)]
    PacketTunnelProvider.rewriteIPv4(&guarded, protocols: [AFI6, AFI], deviceIp: deviceV, fakeIp: fakeV)
    check("an AF_INET6-tagged packet is skipped by the v4 arm", guarded[0] == dial)
    check("a 19-byte runt is skipped, not truncated or rewritten", guarded[1] == dial.prefix(19))

case "v4-rewrite-src-only":
    // THE FACETIME CASE, verbatim from the device trace of 2026-08-06:
    //   "10.7.0.0:16394 -> 98.51.183.236:16393 UDP len=124 src OK1 dst OK0 ONE-SIDED wrote=1"
    // The old code rewrote the source to 10.7.0.1 here, breaking the UDP checksum (which covers a
    // pseudo-header containing both addresses) on live user traffic. It must now be a no-op.
    let ft = sealed(v4udp(src: device, dst: "98.51.183.236", sport: 16394, dport: 16393))
    check("the captured packet is the 124-byte shape from the trace", ft.count == 124, "\(ft.count)")
    var pkts = [ft]
    PacketTunnelProvider.rewriteIPv4(&pkts, protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    check("src == deviceIp but dst != fakeIp → written back COMPLETELY UNTOUCHED", pkts[0] == ft)
    check("the source is still the real one, not fakeIp",
          Array(pkts[0][12..<16]) == Array(ft[12..<16]),
          "\(pkts[0][12]).\(pkts[0][13]).\(pkts[0][14]).\(pkts[0][15])")
    check("the header checksum is untouched and still valid", ipChecksumValid(pkts[0]))

    // …and the trace still SEES it (that is the diagnosis), while the report no longer claims damage.
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [ft], protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    let sFT = snapshotOrDie()
    check("the trace records src✓1 dst✓0, both 0",
          sFT.srcMatched == 1 && sFT.dstMatched == 0 && sFT.bothMatched == 0)
    check("verdict is (b) one side, nothing rewritten",
          headline().contains("ONLY ONE SIDE MATCHES") && headline().contains("Nothing was rewritten"), headline())
    check("the report explains the source-bound-socket / ICE mechanism",
          PacketTraceReport.verdict(sFT).detail.contains { $0.contains("ICE candidate gathering") })
    check("the row shows the public destination and the not-touched label",
          PacketTraceReport.report(sFT).contains { $0.contains("98.51.183.236") && $0.contains("ONE-SIDED(not touched)") })

case "v4-rewrite-dst-only":
    // The other one-ended shape: source-address selection picked en0, so dst == fakeIp fires alone.
    // Rewriting the destination alone would have been the same corruption in the other direction.
    let p = sealed(v4tcp(src: "192.168.4.241", dst: fake, sport: 51000, dport: 49152))
    var pkts = [p]
    PacketTunnelProvider.rewriteIPv4(&pkts, protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    check("dst == fakeIp but src != deviceIp → written back COMPLETELY UNTOUCHED", pkts[0] == p)
    check("the destination is still fakeIp, not deviceIp", Array(pkts[0][16..<20]) == Array(p[16..<20]))
    check("the header checksum is untouched and still valid", ipChecksumValid(pkts[0]))
    // The literal reverse-direction packet (fake → device) matches neither end and must also pass.
    let rev = sealed(v4tcp(src: fake, dst: device, sport: 49152, dport: 51000))
    var revPkts = [rev]
    PacketTunnelProvider.rewriteIPv4(&revPkts, protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    check("fake → device matches neither end and is untouched", revPkts[0] == rev)

case "v6-rewrite-strict":
    // The v6 arm has always required both ends; this pins that down next to the v4 scenarios so the
    // two can never drift apart again.
    let v6dial = v6tcp(src: device6, dst: fake6, sport: 51000, dport: 49152)
    let v6carrier = v6tcp(src: carrierSrc6, dst: fake6, sport: 51000, dport: 49152)
    let v6elsewhere = v6tcp(src: device6, dst: carrierSrc6, sport: 51000, dport: 49152)
    var v6batch = [v6dial, v6carrier, v6elsewhere]
    PacketTunnelProvider.rewriteIPv6(&v6batch, protocols: [AFI6, AFI6, AFI6],
                                     deviceIp6: addr6(device6), fakeIp6: addr6(fake6))
    check("both ends match → swapped",
          Array(v6batch[0][8..<24]) == Array(v6dial[24..<40])
            && Array(v6batch[0][24..<40]) == Array(v6dial[8..<24]))
    check("both ends match → nothing outside the two address fields moved",
          Array(v6batch[0][0..<8]) == Array(v6dial[0..<8]) && Array(v6batch[0][40...]) == Array(v6dial[40...]))
    check("dst-only (carrier-selected source) → byte-identical", v6batch[1] == v6carrier)
    check("src-only (dialling a different peer) → byte-identical", v6batch[2] == v6elsewhere)
    // With the experiment off the provider never calls this arm at all; passing the zero pair must
    // also be inert rather than matching zero-addressed noise.
    var noiseBatch = [v6noise()]
    let noiseBefore = noiseBatch[0]
    PacketTunnelProvider.rewriteIPv6(&noiseBatch, protocols: [AFI6],
                                     deviceIp6: addr6(device6), fakeIp6: addr6(fake6))
    check("MLD/RS noise is untouched", noiseBatch[0] == noiseBefore)

case "bench":
    // The claim under test: this is cheap enough to sit in the packet path.
    let path = ProcessInfo.processInfo.environment["WANDER_TRACE_PATH"]!
    let batch = [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)]
    let protos = [AFI]
    let n = 3_000_000

    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    let toNs = Double(tb.numer) / Double(tb.denom)

    /// Best of 7 passes. The interesting costs here are a few tens of nanoseconds, which is close
    /// enough to scheduler noise that a single pass reported a 32-packet batch as CHEAPER than a
    /// 1-packet one. Minimum-of-N is the noise-resistant statistic for this.
    func bench(_ label: String, _ body: () -> Void) -> Double {
        for _ in 0..<50_000 { body() }             // warm up
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<7 {
            let t0 = mach_absolute_time()
            for _ in 0..<n { body() }
            let ns = Double(mach_absolute_time() - t0) * toNs / Double(n)
            best = min(best, ns)
        }
        print(String(format: "    %-46s %8.2f ns/batch", (label as NSString).utf8String!, best))
        return best
    }

    try? FileManager.default.removeItem(atPath: path)
    let off = bench("DISARMED (no trace file at all)") {
        PacketTrace.record(packets: batch, protocols: protos, deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    _ = PacketTrace.arm()
    // THE MAP DOES NOT OPEN INSTANTLY. `record` re-probes for the trace file at most once every
    // `probeInterval` seconds, and the disarmed bench above just consumed a probe — so without this
    // wait the "armed" benches silently measure the DISARMED path. A first version of this benchmark
    // did exactly that and reported a 32-packet batch as cheaper than a 1-packet one.
    Thread.sleep(forTimeInterval: PacketTrace.probeInterval + 0.2)
    PacketTrace.record(packets: batch, protocols: protos, deviceIp: deviceV, fakeIp: fakeV)
    guard case .ok(let armedCheck) = PacketTrace.snapshot(), armedCheck.readBatches > 0 else {
        print("    !! the trace never armed — benchmark would be measuring the wrong path"); exit(2)
    }
    print("    (map is open and recording — benchmarking the real armed path)")
    let on = bench("ARMED (1-packet batch, mmap write)") {
        PacketTrace.record(packets: batch, protocols: protos, deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 1)
    }
    // DISTINCT Data buffers, not 32 references to one COW buffer — otherwise the optimizer and the
    // cache make a 32-packet batch look cheaper than a 1-packet one, which is what a first run of
    // this benchmark reported.
    let big = (0..<32).map { v4tcp(src: device, dst: fake, sport: UInt16(20000 + $0), dport: 49152) }
    let bigProtos = Array(repeating: AFI, count: 32)
    let on32 = bench("ARMED (32-packet batch)") {
        PacketTrace.record(packets: big, protocols: bigProtos, deviceIp: deviceV, fakeIp: fakeV)
        PacketTrace.recordWriteBack(count: 32)
    }
    print(String(format: "    per-packet marginal cost while armed: %.1f ns", (on32 - on) / 31.0))
    check("disarmed costs well under a microsecond", off < 1_000, String(format: "%.1f ns", off))
    check("armed costs well under a microsecond", on < 1_000, String(format: "%.1f ns", on))
    check("no unbounded growth: file still one fixed size",
          ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil) == PacketTrace.fileSize)

case "full-report":
    _ = PacketTrace.arm()
    PacketTrace.recordProviderStart(deviceIp: device, fakeIp: fake)
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 51000, dport: 49152)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    PacketTrace.record(packets: [v4tcp(src: device, dst: fake, sport: 49152, dport: 51000, payload: 8)],
                       protocols: [AFI], deviceIp: deviceV, fakeIp: fakeV)
    PacketTrace.recordWriteBack(count: 1)
    print(PacketTraceReport.report(snapshotOrDie()).joined(separator: "\n"))

default:
    print("unknown scenario")
    exit(3)
}

if scenario != "full-report" {
    print(failures == 0 ? "  -> all checks passed" : "  -> \(failures) FAILURE(S)")
}
exit(failures == 0 ? 0 : 1)
