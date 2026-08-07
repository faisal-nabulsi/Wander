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
        if snap.v6Seen > 0 || snap.v6DstMatched > 0 || snap.v6SrcMatched > 0 {
            out.append("  v6 src == device6 fired               : \(snap.v6SrcMatched)")
            out.append("  v6 dst == fake6 fired                 : \(snap.v6DstMatched)")
            out.append("  v6 BOTH fired (the v6 swap)           : \(snap.v6BothMatched)")
        }
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
            s += " src✓\(e.srcMatchCount) dst✓\(e.dstMatchCount)"
            // ONE-SIDED means SEEN, NOT TOUCHED — since 2026-08-06 the provider rewrites only when
            // BOTH ends match. The label is kept because which end matched is the diagnosis, but it
            // no longer implies the packet was modified (it used to, and that was the FaceTime bug).
            s += e.bothMatched ? " SWAPPED" : (e.srcMatched || e.dstMatched ? " ONE-SIDED(not touched)" : " NO-MATCH")
        } else if e.hasV6 {
            // The v6 arm: print the source the KERNEL selected against the destination the app dialled,
            // so "src wrong" is legible at a glance rather than buried in the counters.
            s += " \(PacketTrace.dotted6(e.v6Src))"
            if e.v6SrcPort != 0 { s += ":\(e.v6SrcPort)" }
            s += " → \(PacketTrace.dotted6(e.v6Dst))"
            if e.v6DstPort != 0 { s += ":\(e.v6DstPort)" }
            s += " \(PacketTrace.protocolName(e.v6NextHeader)) len=\(e.v6FirstLen)"
            s += " src✓\(e.v6SrcMatchCount) dst✓\(e.v6DstMatchCount)"
            s += e.v6BothMatched ? " V6-SWAPPED"
                : (e.v6SrcMatched || e.v6DstMatched ? " V6-ONE-SIDED(not touched)" : " V6-NO-MATCH")
        } else {
            s += " (no IPv4 packet in this batch)"
            s += " src✓\(e.srcMatchCount) dst✓\(e.dstMatchCount)"
            s += e.bothMatched ? " SWAPPED" : (e.srcMatched || e.dstMatched ? " ONE-SIDED(not touched)" : " NO-MATCH")
        }
        s += e.wroteBack ? " wrote=\(e.wroteCount)" : " NOT-WRITTEN"
        if e.v6Count > 0 && e.proto == AF_INET { s += " v6=\(e.v6Count)" }
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
            // THE IPv6 OPT-IN ARM. It dials an IPv6 peer FIRST, so on that path the packets that matter
            // are IPv6 and the v6 counters answer the same three-way question the v4 ones do. Only take
            // this branch when a v6 DIAL packet actually reached the loop (a match on either end, or a
            // full swap); otherwise the v6 traffic is just the kernel's MLD/RS noise and it is routing.
            if snap.v6Seen > 0 && (snap.v6DstMatched > 0 || snap.v6SrcMatched > 0 || snap.v6BothMatched > 0) {
                return v6Verdict(snap)
            }
            return Verdict(
                headline: "(a) NO IPv4 PACKETS ARRIVE — this is a ROUTING problem.",
                detail: [
                    "\(snap.readBatches) batch(es) arrived but every packet was IPv6 (\(snap.v6Seen) of them),",
                    "and NONE of them matched the tunnel's v6 pair (device6/fake6) — so this is the kernel's own",
                    "MLD/router-solicitation noise on the utun, not our dial. If the IPv6 experiment is ON and you",
                    "expected a v6 connect here, the dial is not being routed into the tunnel at all: the included",
                    "IPv6 route must COVER the peer the app dials. If the experiment is OFF, this is the IPv4 case —",
                    "the included IPv4 route must cover the dialled address, with a network (not host) destination."
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
            var detail = [
                "src == deviceIp fired \(snap.srcMatched)×, dst == fakeIp fired \(snap.dstMatched)×, both together 0×.",
                "NOTHING WAS REWRITTEN. The provider swaps only when BOTH ends match (a true swap is the only",
                "rewrite that leaves the IPv4 and L4 checksums valid, since both are one's-complement sums over",
                "a set containing src and dst), so these packets were written back byte-for-byte untouched.",
                "ONE-SIDED in the rows above means SEEN, NOT TOUCHED. Before 2026-08-06 it did mean a mutation —",
                "two independent `if`s — and that was corrupting live FaceTime traffic; that is fixed, so a",
                "one-sided row is now a routing observation, not damage."
            ]
            if snap.srcMatched > 0 {
                detail.append("src matched but dst did not → packets whose SOURCE is the tunnel address but which are not addressed to fakeIp.")
                detail.append("Check the dst column above. A PUBLIC address means this is foreign traffic, not your dial: anything that")
                detail.append("enumerates interfaces binds a socket per local address (FaceTime/WebRTC ICE candidate gathering does exactly")
                detail.append("this), and a source-bound socket is scoped to that interface regardless of excludedRoutes. Ignore it.")
                detail.append("A dst INSIDE the tunnel subnet instead means something is dialling the wrong host — reconcile it with fakeIp.")
            }
            if snap.dstMatched > 0 {
                detail.append("dst matched but src did not → source-address selection is picking a non-tunnel interface (en0), so the")
                detail.append("packet never carried deviceIp and the swap cannot fire. Bind the dial socket's source to deviceIp.")
            }
            return Verdict(
                headline: "(b) PACKETS ARRIVE AND ONLY ONE SIDE MATCHES — config / addresses. Nothing was rewritten.",
                detail: detail)
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

    // MARK: - The IPv6 verdict
    //
    // The exact twin of `verdict`, one family over, reached only when the run was v6-only AND a v6 dial
    // packet actually matched an end. It exists because the v6 arm's failure is NOT a mirror of any v4
    // failure the original three cover: the provider's v6 rewrite is gated on BOTH ends matching (an
    // IPv6 header has no checksum, so a one-sided rewrite would silently break the L4 checksum), which
    // means a source the kernel selected off a carrier /64 instead of device6 makes the swap a NO-OP and
    // the packet is written back to the peer address with no listener → a 0 ms RST. That is invisible to
    // the v4 verdict, which is why this is separate.
    static func v6Verdict(_ snap: PacketTrace.Snapshot) -> Verdict {
        let sample = snap.entries.last(where: { $0.hasV6 })
        let kernelSrc = sample.map { PacketTrace.dotted6($0.v6Src) } ?? "?"
        let dialedDst = sample.map { PacketTrace.dotted6($0.v6Dst) } ?? "?"
        let expectedSrc = DeviceConnectionContext.activeTunnelInterfaceIPv6
        let expectedDst = DeviceConnectionContext.activeTargetIPv6Address

        if snap.v6BothMatched == 0 {
            if snap.v6DstMatched > 0 && snap.v6SrcMatched == 0 {
                // The headline finding this build exists to catch.
                return Verdict(
                    headline: "(b/v6) IPv6 PACKETS ARRIVE, DST MATCHES, SRC DOES NOT — the v6 swap is a NO-OP (source-address mismatch).",
                    detail: [
                        "dst == fake6 fired \(snap.v6DstMatched)×, but src == device6 fired 0× — so the provider's v6",
                        "rewrite (which requires BOTH, to keep the L4 checksum valid) never ran, and the packet was",
                        "written back UNCHANGED to \(dialedDst) — the point-to-point PEER, which has no listener — so the",
                        "local stack RSTs at 0 ms. That is exactly the errno-61-at-0 ms signature.",
                        "The kernel sourced the dial from \(kernelSrc), NOT device6 (\(expectedSrc)). device6 is carved",
                        "into the carrier's own /64, so RFC 6724 source selection can pick pdp_ip0's carrier (or a",
                        "temporary/privacy) address for a destination in that same /64. v4 never hit this because 10.7.x",
                        "is RFC1918 and no cellular interface shares it.",
                        "FIX (connect path, not this swap): bind the dial/probe socket's source to device6 before",
                        "connect (EndpointProbe.connect and the idevice FFI dial currently leave it to the kernel), so",
                        "src == device6 is forced and the existing both-ends swap fires. Do NOT rewrite dst to ::1 — the",
                        "daemon binds in6addr_any (per the launchd plist), so the device6 delivery is correct once the",
                        "source is right."
                    ])
            }
            if snap.v6SrcMatched > 0 && snap.v6DstMatched == 0 {
                return Verdict(
                    headline: "(b/v6) IPv6 SRC MATCHES BUT DST DOES NOT — the app is dialling a different v6 peer.",
                    detail: [
                        "src == device6 fired \(snap.v6SrcMatched)×, dst == fake6 fired 0×. The dial went to \(dialedDst),",
                        "not the configured fake peer \(expectedDst). The provider swaps only when BOTH match, so nothing",
                        "was rewritten. Reconcile the address the client dials with the fake6 the provider is configured",
                        "with (they are set from the same plan, so a mismatch means the tunnel was restarted with a",
                        "different pair than the app now dials)."
                    ])
            }
            // Reached only defensively — the caller already required at least one v6 match to get here.
            return Verdict(
                headline: "(a/v6) IPv6 ARRIVED BUT NEITHER END MATCHED — routing / not our dial.",
                detail: [
                    "\(snap.v6Seen) IPv6 packet(s) reached the loop and neither src == device6 nor dst == fake6 fired.",
                    "That is MLD/RS noise, not the dial — the v6 connect is not entering the tunnel. Check the included",
                    "IPv6 route covers the peer the app dials (\(expectedDst))."
                ])
        }

        if snap.writeBatches == 0 || snap.writtenBack == 0 {
            return Verdict(
                headline: "(c/v6) THE v6 SWAP FIRES BUT NOTHING IS WRITTEN BACK — reinjection.",
                detail: [
                    "\(snap.v6BothMatched) v6 packet(s) were swapped, yet writePackets was recorded \(snap.writeBatches)×",
                    "for \(snap.writtenBack) packet(s). Either the write line is not reached, or its trace call is missing.",
                    "Confirm packetFlow.writePackets runs after the v6 swap."
                ])
        }

        return Verdict(
            headline: "(c/v6) THE v6 SWAP FIRES AND PACKETS ARE WRITTEN BACK — reinjection / the daemon isn't answering on device6.",
            detail: [
                "\(snap.v6Seen) IPv6 packet(s) arrived, \(snap.v6BothMatched) were fully swapped (src↔dst), and",
                "\(snap.writtenBack) were written back. So the v6 loopback is delivering to device6 (\(expectedSrc)) —",
                "the swap is NOT the problem. A 0 ms RST now means the daemon is not answering on device6:port, or the",
                "DDI is not mounted, or the ephemeral control-channel port moved (remotepairingd's port is kernel-",
                "assigned, not a hardcoded 49152, and a daemon restart can move it). Re-check the dial port against the",
                "daemon's 'Resolved listening port…' log, and confirm the DDI mounted before the dial."
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
