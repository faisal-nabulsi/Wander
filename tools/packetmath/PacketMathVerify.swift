//
//  PacketMathVerify.swift
//  tools/packetmath
//
//  OFFLINE PROOF OF THE TUNNEL'S PACKET-REWRITE MATH. No device, no Xcode target, no
//  NetworkExtension. Runs on the Mac with plain swiftc:
//
//      swiftc -O /Users/faisalnabulsi/Developer/wander-ios/tools/packetmath/PacketMathVerify.swift \
//             -o /tmp/packetmath && /tmp/packetmath
//
//  WHY THE LOGIC IS COPIED HERE: this file is deliberately a single self-contained .swift with no
//  dependencies, so it can be run against ANY revision of the provider (including a reverted one)
//  to answer arithmetic questions. `ipToUInt32` and the AF_INET arm of `setPackets` are TRANSCRIBED
//  below into `refIpToUInt32` / `refRewriteIPv4`, with the verbatim source quoted directly above
//  each copy so a diff is a two-second eyeball.
//
//  ⚠️ THE TRANSCRIPTION CAN GO STALE, so it is no longer the only check: tools/packettrace/run.sh
//  now COMPILES TunnelProv/PacketTunnelProvider.swift itself and drives the real
//  `PacketTunnelProvider.rewriteIPv4` (NetworkExtension does have a macOS-host build; the provider
//  is never instantiated, and the rewrite is a static function). An earlier version of this comment
//  claimed that was impossible. If the two files ever disagree, packettrace is the authority.
//
//  WHAT IT PROVES: whether a packet that enters the provider comes out the other side with the
//  right addresses and intact checksums. It says NOTHING about whether packets ever reach the
//  provider (routing) or survive re-injection (writePackets) — that is the point. A clean pass
//  here eliminates hypothesis (b) and narrows the blackhole to (a) or (c).
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// ============================================================================
// MARK: - 1. THE CODE UNDER TEST (verbatim transcription)
// ============================================================================

// VERBATIM from PacketTunnelProvider.swift:251-255
//
//     private func ipToUInt32(_ ipString: String) -> UInt32 {
//         let c = ipString.split(separator: ".")
//         guard c.count == 4, let b1 = UInt32(c[0]), let b2 = UInt32(c[1]), let b3 = UInt32(c[2]), let b4 = UInt32(c[3]) else { return 0 }
//         return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
//     }
func refIpToUInt32(_ ipString: String) -> UInt32 {
    let c = ipString.split(separator: ".")
    guard c.count == 4, let b1 = UInt32(c[0]), let b2 = UInt32(c[1]), let b3 = UInt32(c[2]), let b4 = UInt32(c[3]) else { return 0 }
    return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
}

// VERBATIM from PacketTunnelProvider.swift `rewriteIPv4` (the AF_INET arm of setPackets, factored
// out of the readPackets closure on 2026-08-06 so the packettrace harness can drive it directly).
//
//     for i in packets.indices where protocols[i].int32Value == AF_INET && packets[i].count >= 20 {
//         packets[i].withUnsafeMutableBytes { bytes in
//             guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
//             let src = UInt32(bigEndian: ptr[3])
//             let dst = UInt32(bigEndian: ptr[4])
//             guard src == deviceIp, dst == fakeIp else { return }
//             ptr[3] = fakeIp.bigEndian
//             ptr[4] = deviceIp.bigEndian
//         }
//     }
func refRewriteIPv4(_ packets: [Data], _ protocols: [NSNumber],
                    deviceip: UInt32, fakeip: UInt32) -> [Data] {
    var modified = packets
    for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
        modified[i].withUnsafeMutableBytes { bytes in
            guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            let src = UInt32(bigEndian: ptr[3])
            let dst = UInt32(bigEndian: ptr[4])
            guard src == deviceip, dst == fakeip else { return }
            ptr[3] = fakeip.bigEndian
            ptr[4] = deviceip.bigEndian
        }
    }
    return modified
}

/// THE PRE-2026-08-06 VERSION. Kept ONLY as a counterexample, so section 4 can measure the damage
/// the strict guard prevents rather than asserting it in prose. This is NOT what ships. The two
/// independent `if`s let the first fire alone on any packet whose source merely happened to equal
/// the tunnel's interface address — which on the shipping 10.7.0.0 default caught live FaceTime
/// media (1029 packets in one device session) and mangled its source.
func legacyRewriteIPv4_BUGGY(_ packets: [Data], _ protocols: [NSNumber],
                             deviceip: UInt32, fakeip: UInt32) -> [Data] {
    var modified = packets
    for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
        modified[i].withUnsafeMutableBytes { bytes in
            guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            let src = UInt32(bigEndian: ptr[3])
            let dst = UInt32(bigEndian: ptr[4])
            if src == deviceip { ptr[3] = fakeip.bigEndian }
            if dst == fakeip { ptr[4] = deviceip.bigEndian }
        }
    }
    return modified
}

// ============================================================================
// MARK: - 2. TEST HARNESS: real IPv4/TCP packets, real checksums
// ============================================================================

/// Standard RFC 1071 one's-complement sum, returned already complemented (i.e. a checksum field
/// value). Running it over a buffer that ALREADY carries a correct checksum yields 0.
func onesComplement(_ bytes: ArraySlice<UInt8>) -> UInt16 {
    var sum: UInt32 = 0
    var i = bytes.startIndex
    while i + 1 < bytes.endIndex {
        sum &+= (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
        i += 2
    }
    if i < bytes.endIndex { sum &+= UInt32(bytes[i]) << 8 }
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return UInt16(truncatingIfNeeded: ~sum)
}
func onesComplement(_ bytes: [UInt8]) -> UInt16 { onesComplement(bytes[...]) }

func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

/// Dotted-quad -> the same host-order UInt32 representation the provider's `ipToUInt32` claims to
/// produce. Deliberately written a DIFFERENT way (via inet_pton + byte swap) so it is an independent
/// oracle rather than a copy of the thing under test.
func oracleIp(_ s: String) -> UInt32 {
    var addr = in_addr()
    precondition(s.withCString { inet_pton(AF_INET, $0, &addr) } == 1, "bad literal \(s)")
    // s_addr is network order (big-endian). Host order value = byteswap on LE.
    return UInt32(bigEndian: addr.s_addr)
}

struct TestPacket {
    var bytes: [UInt8]
    var ihl: Int
    var tcpOffset: Int { ihl * 4 }
}

/// Builds a genuine IPv4+TCP packet with BOTH checksums correct.
/// `ihl` >= 5; anything above 5 inserts that many 4-byte NOP/EOL option words after byte 20.
func makePacket(src: String, dst: String, srcPort: UInt16, dstPort: UInt16,
                ihl: Int = 5, payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]) -> TestPacket {
    precondition(ihl >= 5 && ihl <= 15)
    let optionWords = ihl - 5
    // ---- TCP header (20 bytes) + payload
    var tcp: [UInt8] = []
    tcp += be16(srcPort)                    // 0-1   source port
    tcp += be16(dstPort)                    // 2-3   destination port
    tcp += be32(0x1234_5678)                // 4-7   sequence
    tcp += be32(0x9ABC_DEF0)                // 8-11  ack
    tcp += [0x50, 0x18]                     // 12-13 data offset 5, flags PSH|ACK
    tcp += be16(0xFFFF)                     // 14-15 window
    tcp += be16(0)                          // 16-17 checksum (filled below)
    tcp += be16(0)                          // 18-19 urgent pointer
    tcp += payload
    let tcpLen = tcp.count

    // TCP checksum over pseudo-header(src,dst,zero,proto,len) + segment
    var pseudo: [UInt8] = []
    pseudo += be32(oracleIp(src))
    pseudo += be32(oracleIp(dst))
    pseudo += [0x00, 6]
    pseudo += be16(UInt16(tcpLen))
    let tcpCk = onesComplement(pseudo + tcp)
    tcp[16] = be16(tcpCk)[0]; tcp[17] = be16(tcpCk)[1]

    // ---- IPv4 header
    let headerLen = 20 + optionWords * 4
    var ip = [UInt8](repeating: 0, count: headerLen)
    ip[0] = UInt8(0x40 | ihl)                                   // version 4, IHL
    ip[1] = 0x00                                                // DSCP/ECN
    let total = UInt16(headerLen + tcpLen)
    ip[2] = be16(total)[0]; ip[3] = be16(total)[1]              // total length
    ip[4] = 0xAB; ip[5] = 0xCD                                  // identification
    ip[6] = 0x40; ip[7] = 0x00                                  // flags DF, frag 0
    ip[8] = 64                                                  // TTL
    ip[9] = 6                                                   // protocol TCP
    ip[10] = 0; ip[11] = 0                                      // header checksum (filled below)
    let s = be32(oracleIp(src)), d = be32(oracleIp(dst))
    for k in 0..<4 { ip[12 + k] = s[k] }                        // 12-15 SOURCE
    for k in 0..<4 { ip[16 + k] = d[k] }                        // 16-19 DESTINATION
    for w in 0..<optionWords {                                  // options: NOP,NOP,NOP,EOL
        let o = 20 + w * 4
        ip[o] = 0x01; ip[o + 1] = 0x01; ip[o + 2] = 0x01; ip[o + 3] = 0x00
    }
    let ipCk = onesComplement(ip)
    ip[10] = be16(ipCk)[0]; ip[11] = be16(ipCk)[1]

    return TestPacket(bytes: ip + tcp, ihl: ihl)
}

func readSrc(_ b: [UInt8]) -> String { "\(b[12]).\(b[13]).\(b[14]).\(b[15])" }
func readDst(_ b: [UInt8]) -> String { "\(b[16]).\(b[17]).\(b[18]).\(b[19])" }

func ipChecksumValid(_ b: [UInt8]) -> Bool {
    let ihl = Int(b[0] & 0x0F)
    guard b.count >= ihl * 4, ihl >= 5 else { return false }
    return onesComplement(Array(b[0..<(ihl * 4)])) == 0
}

func tcpChecksumValid(_ b: [UInt8]) -> Bool {
    let ihl = Int(b[0] & 0x0F)
    let off = ihl * 4
    guard b.count > off, b[9] == 6 else { return false }
    let tcp = Array(b[off...])
    var pseudo: [UInt8] = []
    pseudo += Array(b[12..<16])
    pseudo += Array(b[16..<20])
    pseudo += [0x00, 6]
    pseudo += be16(UInt16(tcp.count))
    return onesComplement(pseudo + tcp) == 0
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

// ---- tiny reporting shell -------------------------------------------------
var failures: [String] = []
var checks = 0
func check(_ label: String, _ cond: Bool, detail: String = "") {
    checks += 1
    let mark = cond ? "PASS" : "**FAIL**"
    print("    [\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !cond { failures.append(label + (detail.isEmpty ? "" : " — " + detail)) }
}
func section(_ s: String) { print("\n" + s + "\n" + String(repeating: "-", count: s.count)) }

/// Drives one packet through the copied provider logic and reports everything.
@discardableResult
func run(_ title: String, packet: TestPacket, device: String, fake: String,
         expectSrc: String, expectDst: String,
         expectIpOK: Bool = true, expectTcpOK: Bool = true) -> [UInt8] {
    let dev = refIpToUInt32(device), fk = refIpToUInt32(fake)
    let input = Data(packet.bytes)
    let out = refRewriteIPv4([input], [NSNumber(value: AF_INET)], deviceip: dev, fakeip: fk)
    let o = [UInt8](out[0])
    print("  \(title)")
    print("    device=\(device) fake=\(fake)  |  in  src=\(readSrc(packet.bytes)) dst=\(readDst(packet.bytes))")
    print("                                   |  out src=\(readSrc(o)) dst=\(readDst(o))")
    check("src -> \(expectSrc)", readSrc(o) == expectSrc, detail: "got \(readSrc(o))")
    check("dst -> \(expectDst)", readDst(o) == expectDst, detail: "got \(readDst(o))")
    let ipOK = ipChecksumValid(o), tcpOK = tcpChecksumValid(o)
    check("IPv4 header checksum \(expectIpOK ? "still valid" : "BROKEN (expected)")", ipOK == expectIpOK,
          detail: "valid=\(ipOK)")
    check("TCP checksum \(expectTcpOK ? "still valid" : "BROKEN (expected)")", tcpOK == expectTcpOK,
          detail: "valid=\(tcpOK)")
    check("bytes 0..11 and 20..end untouched",
          Array(o[0..<12]) == Array(packet.bytes[0..<12])
            && Array(o[20...]) == Array(packet.bytes[20...]))
    return o
}

// ============================================================================
print("""
================================================================================
 WANDER TUNNEL — OFFLINE VERIFICATION OF THE src/dst SWAP
 logic transcribed from TunnelProv/PacketTunnelProvider.swift (setPackets, ipToUInt32)
 host: \(MemoryLayout<Int>.size * 8)-bit, endianness = \(UInt32(1).bigEndian == 1 ? "BIG" : "LITTLE")
================================================================================
""")

// ============================================================================
section("0. ipToUInt32 vs an independent oracle (inet_pton)")
// ============================================================================
for lit in ["10.7.0.0", "10.7.0.1", "0.0.7.10", "127.0.0.5", "127.0.0.1",
            "172.20.10.5", "172.20.10.6", "192.168.4.241", "255.255.255.255",
            "0.0.0.0", "1.2.3.4", "4.3.2.1"] {
    let mine = refIpToUInt32(lit), oracle = oracleIp(lit)
    check("ipToUInt32(\"\(lit)\") == inet_pton host-order", mine == oracle,
          detail: String(format: "0x%08X vs 0x%08X", mine, oracle))
}
print("\n  Byte-order trap — 10.7.0.0 and 0.0.7.10 are byte-reversals of each other:")
check("they produce DIFFERENT values (no accidental byteswap)",
      refIpToUInt32("10.7.0.0") != refIpToUInt32("0.0.7.10"),
      detail: String(format: "0x%08X vs 0x%08X", refIpToUInt32("10.7.0.0"), refIpToUInt32("0.0.7.10")))

print("\n  ipToUInt32 parse-failure behaviour (returns 0):")
for bad in ["10.7.0", "10.7.0.0.1", "", "abc", "10.7.0.x", "10.7.0.-1", " 10.7.0.1"] {
    print("    ipToUInt32(\"\(bad)\") = \(refIpToUInt32(bad))")
}
// Does it EVER return 0 for something that looks valid?
check("no valid dotted quad in our config set silently parses to 0",
      ["10.7.0.0", "10.7.0.1", "127.0.0.5", "172.20.10.5", "192.168.4.241"]
        .allSatisfy { refIpToUInt32($0) != 0 })
print("    NOTE: 0.0.0.0 legitimately maps to 0, indistinguishable from a parse failure.")
print("          Overflow check: 255<<24 = \(UInt32(255) << 24) — fits UInt32, no trap.")

// ============================================================================
section("1. Round-trip symmetry of UInt32(bigEndian:) <-> .bigEndian")
// ============================================================================
for lit in ["10.7.0.0", "10.7.0.1", "192.168.4.241", "172.20.10.5", "127.0.0.5"] {
    let host = refIpToUInt32(lit)
    // write path, exactly as the provider does it
    var word: UInt32 = host.bigEndian
    let onWire = withUnsafeBytes(of: &word) { Array($0) }
    // read path, exactly as the provider does it
    let readBack = UInt32(bigEndian: word)
    let expectedWire = be32(host)
    check("\(lit): .bigEndian lays down network order \(hex(expectedWire))",
          onWire == expectedWire, detail: "got \(hex(onWire))")
    check("\(lit): UInt32(bigEndian:) reads it back to the same host value",
          readBack == host, detail: String(format: "0x%08X", readBack))
}
print("""

  CONCLUSION: `UInt32(bigEndian: x)` and `x.bigEndian` are the same operation (byteSwapped on a
  little-endian host) and are mutual inverses. `ipToUInt32` builds (b1<<24)|(b2<<16)|(b3<<8)|b4,
  which IS the host-order value of the dotted quad — the same representation the comparison
  produces after UInt32(bigEndian:). The compare and the store agree. No byte-order mismatch.
""")

// ============================================================================
section("2. Offsets: are ptr[3] and ptr[4] really src and dst, for any IHL?")
// ============================================================================
print("""
  A UInt32 pointer indexes 4-byte words: ptr[3] = bytes 12..15, ptr[4] = bytes 16..19.
  IPv4 header layout (RFC 791): 0 ver/IHL | 1 DSCP | 2-3 total len | 4-5 id | 6-7 flags/frag
  | 8 TTL | 9 proto | 10-11 hdr cksum | 12-15 SOURCE | 16-19 DESTINATION | 20.. OPTIONS.
  Source and destination sit at FIXED offsets. Options begin AFTER byte 19, so a larger IHL
  pushes the payload down but never moves src/dst. ptr[3]/ptr[4] are correct for every IHL.
""")
for ihl in [5, 6, 8, 15] {
    let p = makePacket(src: "10.7.0.0", dst: "10.7.0.1", srcPort: 51000, dstPort: 49152, ihl: ihl)
    check("built IHL=\(ihl) packet has valid checksums to start with",
          ipChecksumValid(p.bytes) && tcpChecksumValid(p.bytes))
    let out = run("  IHL=\(ihl) (header \(ihl*4) bytes)", packet: p,
                  device: "10.7.0.0", fake: "10.7.0.1",
                  expectSrc: "10.7.0.1", expectDst: "10.7.0.0")
    check("IHL nibble preserved (=\(ihl))", Int(out[0] & 0x0F) == ihl)
}

// ============================================================================
section("3. THE SIX REQUIRED CASES")
// ============================================================================
let DEV = "10.7.0.0", FAKE = "10.7.0.1"

print("\n  CASE 1 — normal outbound: src=deviceIp, dst=fakeIp (both ifs should fire)")
_ = run("", packet: makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152),
        device: DEV, fake: FAKE, expectSrc: FAKE, expectDst: DEV)

print("\n  CASE 2 — the 'return path' as literally described: src=fakeIp, dst=deviceIp")
print("  (neither condition matches: src!=device and dst!=fake. Passes through UNTOUCHED.)")
_ = run("", packet: makePacket(src: FAKE, dst: DEV, srcPort: 49152, dstPort: 51000),
        device: DEV, fake: FAKE, expectSrc: FAKE, expectDst: DEV)

print("\n  CASE 2b — the ACTUAL return path this loopback produces. The daemon's reply is")
print("  src=deviceIp:49152 -> dst=fakeIp:ephemeral, i.e. device->fake AGAIN, not fake->device.")
_ = run("", packet: makePacket(src: DEV, dst: FAKE, srcPort: 49152, dstPort: 51000),
        device: DEV, fake: FAKE, expectSrc: FAKE, expectDst: DEV)

print("\n  CASE 3 — neither address matches: must pass through untouched")
_ = run("", packet: makePacket(src: "192.168.4.20", dst: "192.168.4.241", srcPort: 1234, dstPort: 80),
        device: DEV, fake: FAKE, expectSrc: "192.168.4.20", expectDst: "192.168.4.241")

print("\n  CASE 4 — IPv4 header WITH OPTIONS (IHL=6): covered in section 2, repeated here")
_ = run("", packet: makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152, ihl: 6),
        device: DEV, fake: FAKE, expectSrc: FAKE, expectDst: DEV)

print("\n  CASE 5 — packets shorter than 20 bytes (must not crash or corrupt)")
for n in [0, 1, 3, 12, 15, 16, 19, 20] {
    let full = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152).bytes
    let short = Array(full.prefix(n))
    let out = refRewriteIPv4([Data(short)], [NSNumber(value: AF_INET)],
                             deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    let o = [UInt8](out[0])
    if n < 20 {
        check("count=\(n): skipped by the `count >= 20` guard, bytes identical", o == short)
    } else {
        check("count=20 (bare IP header, no TCP): rewritten, no OOB — ptr[4] ends exactly at byte 19",
              readSrc(o) == FAKE && readDst(o) == DEV)
        check("count=20: IPv4 header checksum still valid after the swap", ipChecksumValid(o))
    }
}
print("""
    The guard is `count >= 20`. ptr[4] touches bytes 16..19, so 20 is the exact minimum —
    the bound is correct, not off by one. A 19-byte packet is skipped, not truncated.
""")

print("\n  CASE 6 — byte-order traps: every address family in play")
struct Trap { let dev: String; let fake: String }
for t in [Trap(dev: "10.7.0.0",      fake: "10.7.0.1"),
          Trap(dev: "0.0.7.10",      fake: "1.0.7.10"),
          Trap(dev: "127.0.0.5",     fake: "127.0.0.6"),
          Trap(dev: "172.20.10.5",   fake: "172.20.10.6"),
          Trap(dev: "192.168.4.241", fake: "192.168.4.242")] {
    _ = run("  device=\(t.dev) fake=\(t.fake)",
            packet: makePacket(src: t.dev, dst: t.fake, srcPort: 51000, dstPort: 49152),
            device: t.dev, fake: t.fake, expectSrc: t.fake, expectDst: t.dev)
}
print("\n  Decisive byte-order test: device=10.7.0.0, but the packet's src is the REVERSED 0.0.7.10.")
print("  If the comparison had an endianness bug, this would match. It must NOT.")
_ = run("", packet: makePacket(src: "0.0.7.10", dst: "1.0.7.10", srcPort: 1, dstPort: 2),
        device: "10.7.0.0", fake: "10.7.0.1",
        expectSrc: "0.0.7.10", expectDst: "1.0.7.10")

// ============================================================================
section("4. ONE-ENDED MATCHES — why the rewrite requires BOTH ends (fixed 2026-08-06)")
// ============================================================================
print("""
  A TRUE swap (src<->dst) leaves both the IPv4 header checksum and the TCP checksum unchanged,
  because both are one's-complement sums over a set that CONTAINS src and dst, and addition is
  commutative. Change only ONE side and that argument collapses: nothing here recomputes a
  checksum, so both go stale and the receiver discards the packet as damaged.
  The provider USED TO use two independent `if`s, so a one-ended match was a MUTATION rather than
  a swap. It now requires both ends and writes a one-ended packet back untouched. Both behaviours
  are on hand below — `refRewriteIPv4` (shipping) and `legacyRewriteIPv4_BUGGY` (the old one) —
  so the difference is measured, not asserted.
""")
print("\n  4a. Only the SRC condition fires. THE FIELD CASE: on 2026-08-06 a device trace caught 1029")
print("      packets of live FaceTime media doing this — 10.7.0.0:16394 -> 98.51.183.236:16393 UDP.")
print("      FaceTime binds an ICE candidate socket to EVERY local address, the utun's included.")
_ = run("", packet: makePacket(src: DEV, dst: "98.51.183.236", srcPort: 16394, dstPort: 16393),
        device: DEV, fake: FAKE, expectSrc: DEV, expectDst: "98.51.183.236")

print("\n  4b. Only the DST condition fires (source-address selection picked en0, not the utun):")
_ = run("", packet: makePacket(src: "192.168.4.241", dst: FAKE, srcPort: 51000, dstPort: 49152),
        device: DEV, fake: FAKE, expectSrc: "192.168.4.241", expectDst: FAKE)

print("\n  4c. Quantify it: the full swap, the shipping no-op, and what the OLD code did instead.")
do {
    let good = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152).bytes
    let bothOut = refRewriteIPv4([Data(good)], [NSNumber(value: AF_INET)],
                                 deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    let b = [UInt8](bothOut[0])
    print("    full swap        : ip residual=0x\(String(format: "%04x", onesComplement(Array(b[0..<20])))) (0 = valid), tcp valid=\(tcpChecksumValid(b))")

    let oneSided = makePacket(src: DEV, dst: "98.51.183.236", srcPort: 16394, dstPort: 16393).bytes
    let nowOut = refRewriteIPv4([Data(oneSided)], [NSNumber(value: AF_INET)],
                                deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    let n = [UInt8](nowOut[0])
    print("    src-only, SHIPPING: ip residual=0x\(String(format: "%04x", onesComplement(Array(n[0..<20])))) (0 = valid), tcp valid=\(tcpChecksumValid(n))")

    let legacyOut = legacyRewriteIPv4_BUGGY([Data(oneSided)], [NSNumber(value: AF_INET)],
                                            deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    let o = [UInt8](legacyOut[0])
    print("    src-only, OLD CODE: ip residual=0x\(String(format: "%04x", onesComplement(Array(o[0..<20])))) (non-zero = kernel drops it silently), tcp valid=\(tcpChecksumValid(o))")

    check("full swap preserves BOTH checksums", ipChecksumValid(b) && tcpChecksumValid(b))
    check("SHIPPING: a src-only match is written back byte-identical", n == oneSided)
    check("SHIPPING: both checksums therefore stay valid", ipChecksumValid(n) && tcpChecksumValid(n))
    check("REGRESSION GUARD: the old two-`if` code corrupted both checksums here",
          !ipChecksumValid(o) && !tcpChecksumValid(o))
    check("REGRESSION GUARD: and the shipping code differs from it on exactly this packet", n != o)
}

print("""

  WHICH PACKETS HIT THE ONE-ENDED CASE? Walk the loopback first:
    outbound  app -> daemon : src=deviceIp, dst=fakeIp   -> BOTH match -> true swap
    inbound   daemon -> app : src=deviceIp, dst=fakeIp   -> BOTH match -> true swap
  Both directions are device->fake, because after the outbound swap the daemon's accepted socket
  is (local deviceIp:49152, remote fakeIp:ephem), so its reply leaves as deviceIp -> fakeIp. The
  designed path always matches both ends, so requiring both costs it nothing.
  The one-ended cases are NOT rare, which is why this matters: 4a is any process that binds a
  socket to the utun's address (source-bound sockets are scoped to their interface, so they enter
  the tunnel whatever excludedRoutes says — FaceTime/WebRTC ICE gathering does this per candidate),
  and 4b is the kernel sourcing the dial from en0. Under the old code both corrupted the packet;
  under the strict guard both are inert.
""")

// ============================================================================
section("5. Pointer alignment: assumingMemoryBound(to: UInt32.self) on a Data buffer")
// ============================================================================
print("""
  `assumingMemoryBound` asserts nothing at runtime — it is a promise to the compiler. Nothing in
  Data's contract guarantees a 4-byte-aligned base address (a Data slice can start anywhere).
  Two questions: (i) what alignment do we actually get, (ii) does an unaligned access misbehave?
""")
do {
    var worstAlign = 99
    for trial in 0..<8 {
        var p = Data(makePacket(src: DEV, dst: FAKE, srcPort: UInt16(51000 + trial), dstPort: 49152).bytes)
        let a = p.withUnsafeMutableBytes { Int(bitPattern: $0.baseAddress!) % 4 }
        worstAlign = min(worstAlign, a == 0 ? 99 : a)
        if trial == 0 { print("    fresh Data(...)      base address % 4 = \(a)") }
    }
    check("every freshly-allocated Data was 4-byte aligned", worstAlign == 99)

    // Force a slice that starts on an odd byte and see what Data hands back.
    var backing = Data([0xAA])
    backing.append(Data(makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152).bytes))
    var slice = backing[1...]
    let sliceAlign = slice.withUnsafeMutableBytes { Int(bitPattern: $0.baseAddress!) % 4 }
    print("    Data slice at offset 1: base address % 4 = \(sliceAlign)")
    let sOut = refRewriteIPv4([slice], [NSNumber(value: AF_INET)],
                              deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    let so = [UInt8](sOut[0])
    check("slice-backed Data still rewrites correctly",
          readSrc(so) == FAKE && readDst(so) == DEV && ipChecksumValid(so),
          detail: "src=\(readSrc(so)) dst=\(readDst(so))")

    // Definitive unaligned test: a raw buffer deliberately offset by 1,2,3 bytes.
    for off in 1...3 {
        let pkt = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152).bytes
        let raw = UnsafeMutableRawPointer.allocate(byteCount: pkt.count + 8, alignment: 16)
        defer { raw.deallocate() }
        let base = raw.advanced(by: off)
        base.copyMemory(from: pkt, byteCount: pkt.count)
        let ptr = base.assumingMemoryBound(to: UInt32.self)
        let dev = refIpToUInt32(DEV), fk = refIpToUInt32(FAKE)
        let src = UInt32(bigEndian: ptr[3]), dst = UInt32(bigEndian: ptr[4])
        if src == dev && dst == fk {          // same both-ends guard the provider uses
            ptr[3] = fk.bigEndian
            ptr[4] = dev.bigEndian
        }
        var out = [UInt8](repeating: 0, count: pkt.count)
        out.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: base, byteCount: pkt.count) }
        check("raw pointer misaligned by \(off): unaligned load/store still correct on arm64",
              readSrc(out) == FAKE && readDst(out) == DEV && ipChecksumValid(out),
              detail: "src=\(readSrc(out)) dst=\(readDst(out))")
    }
}
print("""
    VERDICT on alignment: arm64 permits unaligned 4-byte integer loads/stores on normal memory,
    so this does not trap or corrupt in practice. It is still formally UB in Swift (a strict-
    aliasing / alignment promise the compiler may exploit) and would be cleaner as
    loadUnaligned(fromByteOffset:as:). It is NOT the blackhole.
""")

// ============================================================================
section("6. Copy-on-write: does `modified[i].withUnsafeMutableBytes` actually land?")
// ============================================================================
do {
    let original = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152).bytes
    let packets: [Data] = [Data(original)]
    let out = refRewriteIPv4(packets, [NSNumber(value: AF_INET)],
                             deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    check("mutation LANDED in the returned array (not lost to COW)",
          readSrc([UInt8](out[0])) == FAKE && readDst([UInt8](out[0])) == DEV,
          detail: "out src=\(readSrc([UInt8](out[0]))) dst=\(readDst([UInt8](out[0])))")
    check("the ORIGINAL input array is left untouched (COW did its job)",
          [UInt8](packets[0]) == original,
          detail: "in src=\(readSrc([UInt8](packets[0]))) dst=\(readDst([UInt8](packets[0])))")
    print("""
        `Array.subscript` yields inout access via _modify, and `Data.withUnsafeMutableBytes` is
        `mutating`, so Data uniques its own backing first. The write lands in modified[i]; the
        provider then passes `modified` to writePackets. Correct — the input array being unchanged
        is expected and harmless, since it is never used again.
    """)
}

// ============================================================================
section("7. What if ipToUInt32 silently returned 0?")
// ============================================================================
do {
    let p = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152)
    let out = refRewriteIPv4([Data(p.bytes)], [NSNumber(value: AF_INET)], deviceip: 0, fakeip: 0)
    let o = [UInt8](out[0])
    check("device=0 and fake=0: NOTHING matches, packet passes through verbatim", o == p.bytes,
          detail: "src=\(readSrc(o)) dst=\(readDst(o))")
    print("""
        So a parse failure gives NO matches, not universal matches (0.0.0.0 is not a src/dst that
        real traffic carries). The packet is written straight back with the FAKE destination still
        on it — the kernel routes it to the tunnel again, and it loops until it is dropped. That
        failure mode is EXACTLY the observed blackhole ("no answer, bounded wait expired"), so it
        is worth ruling out on device — but section 0 shows every address actually in use parses
        fine, so ipToUInt32 is not producing it here.
    """)
    // And the pathological half: device parses, fake does not. Under the OLD two-`if` code this was
    // destructive — the src `if` fired alone and stamped 0.0.0.0 onto every outbound packet. The
    // both-ends guard makes a half-parsed config inert instead, which is the same property that
    // fixed the FaceTime corruption; worth pinning down so it cannot regress.
    let out2 = refRewriteIPv4([Data(p.bytes)], [NSNumber(value: AF_INET)],
                              deviceip: refIpToUInt32(DEV), fakeip: 0)
    let o2 = [UInt8](out2[0])
    check("device valid, fake=0: nothing matches both ends, packet passes through verbatim",
          o2 == p.bytes, detail: "src=\(readSrc(o2)) dst=\(readDst(o2))")
    let legacy2 = [UInt8](legacyRewriteIPv4_BUGGY([Data(p.bytes)], [NSNumber(value: AF_INET)],
                                                  deviceip: refIpToUInt32(DEV), fakeip: 0)[0])
    check("REGRESSION GUARD: the old code destroyed it (src → 0.0.0.0)",
          readSrc(legacy2) == "0.0.0.0" && readDst(legacy2) == FAKE,
          detail: "src=\(readSrc(legacy2)) dst=\(readDst(legacy2))")
}

// ============================================================================
section("8. Read-before-write ordering")
// ============================================================================
do {
    // src and dst are both read into locals BEFORE either store. If they were re-read, a config
    // where device==fake, or a packet whose src equals fake, could double-apply.
    let p = makePacket(src: "10.7.0.0", dst: "10.7.0.0", srcPort: 1, dstPort: 2)
    let out = refRewriteIPv4([Data(p.bytes)], [NSNumber(value: AF_INET)],
                             deviceip: refIpToUInt32("10.7.0.0"), fakeip: refIpToUInt32("10.7.0.0"))
    let o = [UInt8](out[0])
    check("device==fake degenerate config: no-op swap, checksums intact",
          readSrc(o) == "10.7.0.0" && readDst(o) == "10.7.0.0" && ipChecksumValid(o) && tcpChecksumValid(o))
    print("      (both `src` and `dst` are captured before either store — no read-after-write hazard)")
}

// ============================================================================
section("9. Non-AF_INET packets are left alone")
// ============================================================================
do {
    let p = makePacket(src: DEV, dst: FAKE, srcPort: 51000, dstPort: 49152)
    let out = refRewriteIPv4([Data(p.bytes)], [NSNumber(value: AF_INET6)],
                             deviceip: refIpToUInt32(DEV), fakeip: refIpToUInt32(FAKE))
    check("protocol tagged AF_INET6: v4 arm skips it entirely", [UInt8](out[0]) == p.bytes)
}

// ============================================================================
section("10. ROUTE MATH for the exact configs that blackholed (offline, computed)")
// ============================================================================
print("""
  The swap is clean, so the packets must be dying before or after it. One thing IS computable
  offline: whether each tested config produces a well-formed included route. This section was
  written when the provider passed the HOST address straight through as the route destination:

      ipv4.includedRoutes = [NEIPv4Route(destinationAddress: tunnelDeviceIp,
                                         subnetMask: tunnelSubnetMask)]

  THAT HAS SINCE BEEN FIXED — `startTunnel` now masks the host bits off first, via the static
  `PacketTunnelProvider.networkAddress(_:mask:)`, matching what the IPv6 branch always did. The
  table below is kept because it is still the clearest statement of WHICH configs were broken and
  why, and because two of them (the /30 dial coverage, and 127/8) fail for reasons masking does
  not fix. "HOST BITS SET" now describes the raw config, not what the provider installs:
""")
struct Cfg { let name: String; let dev: String; let mask: String; let dialed: String }
let configs = [
    Cfg(name: "default (LocalDevVPN parity)", dev: "10.7.0.0",      mask: "255.255.255.0",   dialed: "10.7.0.1"),
    Cfg(name: "reported /22",                 dev: "192.168.4.241", mask: "255.255.252.0",   dialed: "192.168.4.242"),
    Cfg(name: "reported /30",                 dev: "172.20.10.5",   mask: "255.255.255.252", dialed: "172.20.10.6"),
    Cfg(name: "reported /30 loopback",        dev: "127.0.0.5",     mask: "255.255.255.252", dialed: "127.0.0.6"),
]
func dotted(_ v: UInt32) -> String { "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)" }
for c in configs {
    let dev = refIpToUInt32(c.dev), m = refIpToUInt32(c.mask), dial = refIpToUInt32(c.dialed)
    let net = dev & m
    let bcast = net | ~m
    let prefix = m.nonzeroBitCount
    let hostBitsSet = dev != net
    let dialCovered = (dial & m) == net
    let dialIsNetOrBcast = (dial == net) || (dial == bcast)
    let martian = (dev >> 24) == 127 || (dial >> 24) == 127
    print("""
      \(c.name)
        interface/route destination passed to NEIPv4Route : \(c.dev)  mask \(c.mask) (/\(prefix))
        true network address                              : \(dotted(net))
        broadcast                                         : \(dotted(bcast))
        HOST BITS SET IN ROUTE DESTINATION                : \(hostBitsSet ? "YES  <-- not normalised" : "no")
        app dials \(c.dialed) — covered by the route?\(String(repeating: " ", count: max(0, 10 - c.dialed.count))) \(dialCovered ? "yes" : "NO")
        dialed address is the network/broadcast address?  : \(dialIsNetOrBcast ? "YES  <-- unusable as a host" : "no")
        inside 127.0.0.0/8 (kernel martian filter)?       : \(martian ? "YES  <-- XNU drops non-lo0 127/8" : "no")
    """)
}
print("""
  READ THE COLUMN: the ONE config with no host bits set in the route destination (10.7.0.0/24,
  where the interface address IS the network address) is the one that is known to work under
  LocalDevVPN. All three configs reported as blackholing have host bits set. That was a
  correlation, not a proof — and it has since been acted on: the provider masks the destination
  before building the route. The remaining rows below (dial not covered, dial == network or
  broadcast, 127/8) are independent failures that masking does NOT fix.

  Separately, 127.0.0.5 has a second, independent reason to fail regardless of routes: XNU's
  input path treats 127.0.0.0/8 as loopback-only and discards such packets when they arrive on
  an interface that is not lo0. A utun is not lo0. That config cannot work on any mask.
""")

// ============================================================================
print("""

================================================================================
 RESULT: \(checks - failures.count)/\(checks) checks passed
================================================================================
""")
if failures.isEmpty {
    print("""
 THE SWAP MATH IS CORRECT. Byte order, offsets, IHL handling, the >=20 bound, COW, and the
 alignment behaviour all check out on synthetic packets. Hypothesis (b) — "the IP math or byte
 order is wrong" — is ELIMINATED for the steady-state device->fake flow.

 Therefore the blackhole is (a) packets never reach the provider, or (c) re-injection/settings.
 Ranked by what this exercise exposed, the things to instrument next:
   1. Whether readPackets fires AT ALL. A counter in setPackets separates (a) from (b)/(c)
      in one run. If it never fires, the included route never captured the dial.
      DONE — TunnelProv/PacketTrace.swift is that counter, and the app can dump it.
   2. IPv4 includedRoutes used to pass the HOST address as the route destination, so any config
      whose interface address is not already the network address installed a malformed route.
      FIXED — startTunnel masks it (PacketTunnelProvider.networkAddress). Section 10 has the
      per-config table, including the failures masking does not fix.
   3. Whether the app's fake IP is inside the included route at all (e.g. a /30 at 172.20.10.4
      covers only .5 and .6; a fake of 172.20.10.1 would never enter the tunnel).
   4. Source-address selection: if the kernel sources from en0 instead of the utun, only the dst
      end matches. That USED TO corrupt the packet (two independent `if`s); since 2026-08-06 the
      rewrite requires both ends, so such a packet is written back untouched and the failure is a
      clean "no swap" rather than silent damage. Section 4b is that case in bytes, and section 4c
      measures the old behaviour beside the new one so it cannot come back unnoticed.
""")
    exit(0)
} else {
    print(" FAILURES:")
    for f in failures { print("   - \(f)") }
    exit(1)
}
