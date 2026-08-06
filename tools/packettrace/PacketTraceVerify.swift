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

func v6noise() -> Data {
    var d = Data(repeating: 0, count: 48)
    d[0] = 0x60
    d[6] = 58 // ICMPv6
    return d
}

let AFI = NSNumber(value: AF_INET)
let AFI6 = NSNumber(value: AF_INET6)

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
    check("header is 128 bytes", PacketTrace.headerSize == 128)
    check("record is 80 bytes", PacketTrace.recordSize == 80)
    check("capacity is capped at 512", PacketTrace.capacity == 512)
    check("file is exactly header + capacity*record", PacketTrace.fileSize == 128 + 512 * 80,
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
    check("verdict is (b) ONE SIDE, and calls out the corruption",
          headline().contains("ONLY ONE SIDE MATCHES") && headline().contains("CORRUPTED"), headline())

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
    // record #2 lives at slot 1; seqEnd sits at offset 64 inside it
    try! fh.seek(toOffset: UInt64(PacketTrace.headerSize + 1 * PacketTrace.recordSize + 64))
    fh.write(Data(repeating: 0xEE, count: 8))
    try! fh.close()
    let s = snapshotOrDie()
    check("the torn record is skipped", s.entries.count == 2, "\(s.entries.count) entries")
    check("it is reported, not silently dropped", s.torn == 1)
    check("the surviving records are the intact ones",
          s.entries.map(\.seq) == [1, 3], "\(s.entries.map(\.seq))")

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
