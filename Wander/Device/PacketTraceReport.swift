//
//  PacketTraceReport.swift
//  Wander
//
//  THE READER SIDE of `PacketTrace` (TunnelProv/PacketTrace.swift, compiled into both targets).
//  Turns the extension's ring buffer into lines in the app Console, ending with a plain-English
//  VERDICT that names which of the three failure shapes the data actually shows:
//
//      (a) NO PACKETS ARRIVE                  -> routing. Nothing is entering the tunnel.
//      (b) packets arrive, the swap does NOT fire -> the addresses/config do not match.
//      (c) the swap fires and packets are written back -> reinjection / network settings.
//
//  WHY A VERDICT LINE RATHER THAN JUST NUMBERS. The three findings need completely different fixes
//  and have been guessed at for weeks. A reader who has to derive "readBatches == 0 means routing"
//  from a counter dump will derive it wrong under pressure, so the derivation is done here, once,
//  next to the definition of the counters it reads.
//
//  ARMING IS PART OF THE SAME BUTTON on purpose. Tracing is off unless the trace file exists and its
//  arm has not expired, so the first tap can only ever arm — there is nothing to dump yet. Making
//  that a separate row would guarantee the sequence gets done in the wrong order on a device that is
//  already misbehaving.
//

import Foundation

enum PacketTraceReport {

    /// How many of the most recent batches to print in full. The ring holds 512; a failing connect
    /// is a handful of batches, and printing every slot would bury the summary it exists to support.
    static let maxDetailRows = 60

    enum Action {
        /// Nothing was armed, so this tap armed it. Nothing to report yet.
        case armed(String)
        /// A trace was present and has been written into the log.
        case dumped(summary: String, lines: Int)
        case blocked(String)
    }

    /// Arm-or-dump, whichever the state calls for. Writes into `LogManager` and returns a short
    /// message for the alert. Safe to call from the main thread: it maps a 41 KB file and formats a
    /// few dozen lines.
    @discardableResult
    static func run() -> Action {
        switch PacketTrace.snapshot() {
        case .noContainer(let tried):
            let message = """
                No App Group container is reachable, so the extension has nowhere to write the trace. \
                Add \(PacketTrace.declaredAppGroup) to BOTH Wander.entitlements and \
                TunnelProv.entitlements (tried: \(tried.joined(separator: ", "))).
                """
            log(["=== TUNNEL PACKET TRACE ===", "BLOCKED: " + message, "=== END TUNNEL PACKET TRACE ==="])
            return .blocked(message)

        case .neverArmed:
            return armNow()

        case .unreadable(let why):
            // A stale or corrupt file is not worth preserving — re-arm over it.
            log(["=== TUNNEL PACKET TRACE ===", "Existing trace unreadable: \(why) — re-arming.",
                 "=== END TUNNEL PACKET TRACE ==="])
            switch armNow() {
            case .armed(let m): return .armed("Previous trace unreadable (\(why)). " + m)
            case let other: return other
            }

        case .ok(let snap):
            // Armed but nothing recorded yet AND the arm has expired: the window closed without a
            // capture, so start a fresh one rather than reporting an empty old file as evidence.
            if !snap.armedNow && snap.readBatches == 0 && !snap.providerStarted {
                switch armNow() {
                case .armed(let m):
                    return .armed("The previous arm expired with nothing captured. " + m)
                case let other: return other
                }
            }
            let lines = report(snap)
            log(lines)
            return .dumped(summary: verdict(snap).headline, lines: lines.count)
        }
    }

    private static func armNow() -> Action {
        switch PacketTrace.arm() {
        case .armed(let until):
            let stamp = DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .medium)
            log(["=== TUNNEL PACKET TRACE ===",
                 "ARMED. Tracing is now ON in the tunnel extension until \(stamp) (it expires by itself).",
                 "Container: \(PacketTrace.resolvedAppGroup() ?? "?")",
                 "Now reproduce the failure — start Wander's own tunnel and let it try to connect —",
                 "then tap \"Dump tunnel packet trace\" again.",
                 "=== END TUNNEL PACKET TRACE ==="])
            return .armed("Packet tracing is ARMED until \(stamp). Reproduce the failure (start the tunnel and let it try to connect), then tap this again to read the trace.")
        case .noContainer(let tried):
            let message = "No App Group container. Add \(PacketTrace.declaredAppGroup) to both entitlements (tried: \(tried.joined(separator: ", ")))."
            log(["=== TUNNEL PACKET TRACE ===", "BLOCKED: " + message, "=== END TUNNEL PACKET TRACE ==="])
            return .blocked(message)
        case .failed(let why):
            log(["=== TUNNEL PACKET TRACE ===", "BLOCKED: could not arm — \(why)", "=== END TUNNEL PACKET TRACE ==="])
            return .blocked("Could not arm the trace: \(why)")
        }
    }

    /// Turn tracing off now, without waiting for the arm to expire.
    static func stop() {
        PacketTrace.disarm()
        log(["=== TUNNEL PACKET TRACE ===", "DISARMED. The extension stops recording on its next packet batch.",
             "=== END TUNNEL PACKET TRACE ==="])
    }

    // MARK: - The report

    static func report(_ snap: PacketTrace.Snapshot) -> [String] {
        var out: [String] = []
        out.append("=== TUNNEL PACKET TRACE ===")
        out.append("container: \(snap.appGroup)")
        out.append("armed: \(time(snap.armedAt)) → \(time(snap.armedUntil)) · currently \(snap.armedNow ? "ON" : "EXPIRED")")
        out.append("provider start recorded: \(snap.providerStarted ? "YES (\(snap.providerStarts)×)" : "no — the optional startTunnel line is not installed, or the extension never ran")")

        let configuredDevice = UserDefaults.standard.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
        let configuredFake = UserDefaults.standard.string(forKey: UserDefaults.Keys.targetDeviceIP) ?? "10.7.0.1"
        out.append("app settings say: interface(device) IP \(configuredDevice), target(fake) IP \(configuredFake)")
        if snap.deviceIp != 0 || snap.fakeIp != 0 {
            out.append("provider was running with: deviceIp \(PacketTrace.dotted(snap.deviceIp)), fakeIp \(PacketTrace.dotted(snap.fakeIp))")
            if PacketTrace.ipToUInt32(configuredDevice) != snap.deviceIp
                || PacketTrace.ipToUInt32(configuredFake) != snap.fakeIp {
                out.append("  ⚠️ MISMATCH — the live provider is not using the addresses the app now has on disk (restart the tunnel after changing them).")
            }
        } else {
            out.append("provider was running with: (not stamped — no batch has been recorded yet)")
        }

        out.append("COUNTERS")
        out.append("  read batches (readPackets callbacks) : \(snap.readBatches)")
        out.append("  packets seen                          : \(snap.packetsSeen)  (IPv4 \(snap.v4Seen), IPv6 \(snap.v6Seen))")
        out.append("  src == deviceIp fired                 : \(snap.srcMatched)")
        out.append("  dst == fakeIp fired                   : \(snap.dstMatched)")
        out.append("  BOTH fired (a true swap)              : \(snap.bothMatched)")
        out.append("  write batches (after writePackets)    : \(snap.writeBatches)")
        out.append("  packets written back                  : \(snap.writtenBack)")
        if snap.dropped > 0 { out.append("  older batches dropped by the ring     : \(snap.dropped)") }
        if snap.torn > 0 { out.append("  records skipped as mid-write          : \(snap.torn)") }

        if snap.entries.isEmpty {
            out.append("BATCHES: none recorded.")
        } else {
            let shown = snap.entries.suffix(maxDetailRows)
            let hidden = snap.entries.count - shown.count
            out.append("BATCHES (most recent \(shown.count)\(hidden > 0 ? ", \(hidden) older omitted" : "")):")
            for e in shown { out.append("  " + line(for: e)) }
        }

        let v = verdict(snap)
        out.append("VERDICT: " + v.headline)
        for detail in v.detail { out.append("  " + detail) }
        out.append("=== END TUNNEL PACKET TRACE ===")
        return out
    }

    private static func line(for e: PacketTrace.Entry) -> String {
        var s = "#\(e.seq) \(time(e.time)) \(PacketTrace.familyName(e.proto))"
        s += " n=\(e.batchCount)"
        if e.proto == AF_INET {
            s += " \(PacketTrace.dotted(e.src))"
            if e.srcPort != 0 { s += ":\(e.srcPort)" }
            s += " → \(PacketTrace.dotted(e.dst))"
            if e.dstPort != 0 { s += ":\(e.dstPort)" }
            s += " \(PacketTrace.protocolName(e.ipProto)) len=\(e.firstLen)"
        } else {
            s += " (no IPv4 packet in this batch)"
        }
        s += " src✓\(e.srcMatchCount) dst✓\(e.dstMatchCount)"
        s += e.bothMatched ? " SWAPPED" : (e.srcMatched || e.dstMatched ? " ONE-SIDED" : " NO-MATCH")
        s += e.wroteBack ? " wrote=\(e.wroteCount)" : " NOT-WRITTEN"
        if e.v6Count > 0 { s += " v6=\(e.v6Count)" }
        if e.sawShort { s += " SHORT-PACKET" }
        return s
    }

    // MARK: - The verdict

    struct Verdict {
        let headline: String
        let detail: [String]
    }

    /// The whole point of the exercise. Ordered from the outside in: nothing arrived → arrived but
    /// wrong shape → arrived, matched, and left again.
    static func verdict(_ snap: PacketTrace.Snapshot) -> Verdict {
        if snap.readBatches == 0 {
            if snap.providerStarted {
                return Verdict(
                    headline: "(a) NO PACKETS ARRIVE — this is a ROUTING problem.",
                    detail: [
                        "The provider started \(snap.providerStarts)× and its read loop was never handed a single packet.",
                        "Nothing is being routed INTO the tunnel, so the swap, the write-back and the network",
                        "settings are all irrelevant — the packet never gets that far.",
                        "Look at the included route: NEIPv4Route(destinationAddress:subnetMask:) must be given the",
                        "NETWORK address, not the interface's host address. 10.7.0.0/255.255.255.0 works because",
                        "10.7.0.0 already IS the network address; 192.168.4.241/22 and 172.20.10.5/30 are not.",
                        "Also confirm the target the app dials is INSIDE that included route."
                    ])
            }
            return Verdict(
                headline: "(a?) NOTHING RECORDED — either no packets arrived, or the extension never ran.",
                detail: [
                    "No batches and no provider-start marker. Those are different problems and this trace",
                    "cannot separate them until the optional one-line PacketTrace.recordProviderStart(...) call",
                    "is added to startTunnel. Until then, check the tunnel actually reached Connected",
                    "(free-sideload builds have the Network Extension entitlement stripped, so the appex never",
                    "launches at all), then re-arm and reproduce."
                ])
        }

        if snap.v4Seen == 0 {
            return Verdict(
                headline: "(a) NO IPv4 PACKETS ARRIVE — this is a ROUTING problem.",
                detail: [
                    "\(snap.readBatches) batch(es) arrived but every packet was IPv6 (\(snap.v6Seen) of them) —",
                    "that is the kernel's own MLD/router-solicitation noise on the utun, not our traffic.",
                    "The IPv4 connect is not being routed into the tunnel at all. Same fix as (a): the included",
                    "IPv4 route must cover the address the app dials, and its destination must be the network",
                    "address rather than the interface's host address."
                ])
        }

        if snap.bothMatched == 0 {
            if snap.srcMatched == 0 && snap.dstMatched == 0 {
                var detail = [
                    "\(snap.v4Seen) IPv4 packet(s) reached the read loop and NEITHER condition ever fired:",
                    "no packet had src == deviceIp, and none had dst == fakeIp.",
                    "So the packets entering the tunnel are not the ones the swap is written for. Compare the",
                    "src/dst printed in the BATCHES rows above against deviceIp/fakeIp printed at the top."
                ]
                if let sample = snap.entries.last(where: { $0.proto == AF_INET }) {
                    detail.append("Most recent IPv4 packet: \(PacketTrace.dotted(sample.src)) → \(PacketTrace.dotted(sample.dst)); provider expected src \(PacketTrace.dotted(snap.deviceIp)) / dst \(PacketTrace.dotted(snap.fakeIp)).")
                }
                return Verdict(headline: "(b) PACKETS ARRIVE BUT THE SWAP NEVER FIRES — config / addresses.",
                               detail: detail)
            }
            return Verdict(
                headline: "(b) PACKETS ARRIVE AND ONLY ONE SIDE MATCHES — config / addresses, and the packet is being CORRUPTED.",
                detail: [
                    "src == deviceIp fired \(snap.srcMatched)×, dst == fakeIp fired \(snap.dstMatched)×, both together 0×.",
                    "The provider uses two independent `if`s, so a one-sided hit is a MUTATION, not a swap: the",
                    "IPv4 header checksum and the L4 checksum are both left stale and the kernel silently drops",
                    "the packet. A true swap preserves both checksums; a one-sided rewrite cannot.",
                    snap.srcMatched > 0
                        ? "src matched but dst did not → the destination is not fakeIp. Something is dialling a different host inside the included subnet."
                        : "dst matched but src did not → source-address selection is picking a non-tunnel interface (en0), so the packet never carried deviceIp."
                ])
        }

        if snap.writeBatches == 0 || snap.writtenBack == 0 {
            return Verdict(
                headline: "(c) THE SWAP FIRES BUT NOTHING IS WRITTEN BACK — reinjection.",
                detail: [
                    "\(snap.bothMatched) packet(s) were swapped, yet writePackets was recorded \(snap.writeBatches)×",
                    "for \(snap.writtenBack) packet(s). Either the write line is not reached (an early return or a",
                    "throw between the swap and writePackets) or the trace line after writePackets was not installed.",
                    "Confirm the second one-line call is present immediately after packetFlow.writePackets."
                ])
        }

        return Verdict(
            headline: "(c) THE SWAP FIRES AND PACKETS ARE WRITTEN BACK — this is a REINJECTION / SETTINGS problem.",
            detail: [
                "\(snap.v4Seen) IPv4 packet(s) arrived, \(snap.bothMatched) were fully swapped, and \(snap.writtenBack)",
                "were handed back to writePackets across \(snap.writeBatches) batch(es).",
                "So the packets do enter the tunnel and they are rewritten correctly — they die AFTER reinjection.",
                "That is a network-settings problem, not routing and not IP math: the re-injected packet is",
                "addressed to the tunnel's own address, and the OS is not delivering it locally to the listener.",
                "Look at NEPacketTunnelNetworkSettings — tunnelRemoteAddress, the address/mask pair, and whether",
                "the destination is an address the stack will accept on a utun at all (127.0.0.0/8 is discarded",
                "outright on any interface that is not lo0, so a 127.x tunnel address can never work here).",
                "If the write-backs are all SYNs with no reply, nothing is answering on that port at that address."
            ])
    }

    // MARK: - Plumbing

    private static func log(_ lines: [String]) {
        for line in lines { LogManager.shared.addInfoLog(line) }
        // Same replay store the interface dump and endpoint sweep use, so opening the Console (which
        // REPLACES the buffer with the parsed idevice file) does not wipe what we just wrote.
        NetworkInterfaceDump.retain(lines)
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
