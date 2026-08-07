//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  On-device loopback tunnel for reaching the device's own developer services.
//  Ported from LocalDevVPN (github.com/StephenDev0/LocalDevVPN, by Stossy11) —
//  a small NEPacketTunnelProvider that swaps src/dst between the device IP and a
//  fake IP so traffic loops back to localhost. No external servers, no data leaves
//  the device. Lets Wander run its own tunnel instead of a separate app.
//

import NetworkExtension
import Darwin

class PacketTunnelProvider: NEPacketTunnelProvider {
    var tunnelDeviceIp: String = "10.7.0.0"
    var tunnelFakeIp: String = "10.7.0.1"
    var tunnelSubnetMask: String = "255.255.255.0"

    private var deviceIpValue: UInt32 = 0
    private var fakeIpValue: UInt32 = 0

    // MARK: - Experimental all-IPv6 loopback (opt-in, default OFF — see DeviceConnectionContext)
    //
    // Off by default, and when off this provider declares NO IPv6 at all — byte for byte the reference
    // implementation's IPv4-only tunnel. When on, the tunnel gets a real IPv6 loopback that mirrors the
    // working v4 one — an address for the interface, and an included route that COVERS the peer the app
    // dials.
    var tunnelDeviceIpv6: String = "fd00:7761:6e64:7272::1"
    var tunnelFakeIpv6: String = "fd00:7761:6e64:7272::2"
    var tunnelIpv6PrefixLength: NSNumber = 64
    private var ipv6LoopbackEnabled = false
    private var deviceIp6 = in6_addr()
    private var fakeIp6 = in6_addr()

    // REMOVED 2026-08-05 — DO NOT REINSTATE WITHOUT READING THIS.
    //
    // This provider used to run an `NWPathMonitor` and, on a path change, call
    // `setTunnelNetworkSettings(nil)` then re-apply, then call `setPackets()` again. It was added on
    // 2026-08-01 to survive an Airplane-Mode-off transition. It is what made the tunnel BLACKHOLE
    // every packet, measured on device 2026-08-05: a TCP connect to the tunnel target got no RST and
    // no route error, the bounded wait simply expired, while 127.0.0.1 and en0's own address
    // connected in 0 ms and LocalDevVPN's equivalent tunnel worked on the same phone.
    //
    // It could not do anything else, because it fed itself:
    //   • `setTunnelNetworkSettings(nil)` REMOVES the tunnel's addresses and routes. That is itself a
    //     network configuration change, so it produced the next path callback.
    //   • Re-applying produced another one. `reasserting = true/false` produced more.
    //   • The `summary != lastPathSummary` guard only suppresses IDENTICAL consecutive callbacks. The
    //     churn above alternates between "utun present" and "utun gone", so every callback differed
    //     from the one before it and every callback re-armed the cycle.
    //   • `guard path.status == .satisfied` was checked AFTER `lastPathSummary` was overwritten, so an
    //     unsatisfied intermediate state didn't damp the loop, it primed the next one.
    // A SYN handed to an interface whose addresses are being torn down and reinstalled is dropped
    // with no RST and no ICMP — which is exactly the measured signature.
    //
    // The second `setPackets()` was the other half: `NEPacketTunnelFlow` supports ONE outstanding
    // `readPackets` call, and each re-apply started another self-perpetuating chain on the same flow.
    //
    // The reference implementation (LocalDevVPN) has no path monitor at all and works. A tunnel that
    // never delivers is strictly worse than one that needs a reconnect, so this is gone rather than
    // patched. What is lost: nothing re-establishes settings after an Airplane-Mode-off. Recovery
    // belongs on the APP side, where it can be made conditional on the endpoint actually being dead —
    // see WanderTunnel/TunnelHealthMonitor.

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let deviceIp = options?["TunnelDeviceIP"] as? String { tunnelDeviceIp = deviceIp }
        if let fakeIp = options?["TunnelFakeIP"] as? String { tunnelFakeIp = fakeIp }
        if let mask = options?["TunnelSubnetMask"] as? String { tunnelSubnetMask = mask }
        if let deviceIp6 = options?["TunnelDeviceIPv6"] as? String { tunnelDeviceIpv6 = deviceIp6 }
        if let fakeIp6 = options?["TunnelFakeIPv6"] as? String { tunnelFakeIpv6 = fakeIp6 }
        if let prefix = options?["TunnelIPv6PrefixLength"] as? NSNumber { tunnelIpv6PrefixLength = prefix }
        if let enabled = options?["TunnelIPv6Loopback"] as? NSNumber { ipv6LoopbackEnabled = enabled.boolValue }

        deviceIpValue = ipToUInt32(tunnelDeviceIp)
        fakeIpValue = ipToUInt32(tunnelFakeIp)

        // Parse the v6 pair once. If either literal is unusable the experiment simply stays off rather
        // than installing a half-configured tunnel — the v4 loopback below is untouched either way.
        if ipv6LoopbackEnabled {
            let deviceParsed = tunnelDeviceIpv6.withCString { inet_pton(AF_INET6, $0, &deviceIp6) } == 1
            let fakeParsed = tunnelFakeIpv6.withCString { inet_pton(AF_INET6, $0, &fakeIp6) } == 1
            ipv6LoopbackEnabled = deviceParsed && fakeParsed
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIp)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIp], subnetMasks: [tunnelSubnetMask])
        // The route's destination must be the NETWORK address, not the interface's HOST address.
        // This line used to pass `tunnelDeviceIp` straight through, so any configuration whose device
        // IP is not already the network address produced a route with host bits set — e.g. the
        // "detect" button's 192.168.4.240 with mask 255.255.252.0 asks for a route to 192.168.4.240/22
        // when it means 192.168.4.0/22. It only ever went unnoticed because the shipping default,
        // 10.7.0.0/24, is the one config where the interface address IS the network address.
        // The IPv6 branch below already does this deliberately, with a comment saying not to trust
        // iOS to normalise it — this line was doing exactly what that comment warns against.
        let ipv4RouteDestination = Self.networkAddress(tunnelDeviceIp, mask: tunnelSubnetMask) ?? tunnelDeviceIp
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: ipv4RouteDestination, subnetMask: tunnelSubnetMask)]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        // ROUTING NOTE, 2026-08-06 — WHY REAL INTERNET TRAFFIC STILL SHOWS UP IN THE READ LOOP, AND
        // WHY THAT IS NOT A BUG IN THE TWO LINES ABOVE. DO NOT "FIX" THE ROUTES BECAUSE OF IT.
        //
        // A device trace caught 1029 packets of live FaceTime media in one session, sourced from the
        // tunnel's own address and addressed to a public host (10.7.0.0:16394 → 98.51.183.236:16393
        // UDP; 16384-16403 is FaceTime's RTP range). That looks impossible next to `excludedRoutes =
        // [.default()]`, and it isn't:
        //
        //   • includedRoutes/excludedRoutes are DESTINATION-based. They decide which destination
        //     prefixes the system routes into this utun. They say nothing about a socket that has
        //     already bound its SOURCE to the tunnel's address.
        //   • iOS/macOS route per-interface (scoped routing). A socket bound to an interface's
        //     address is scoped to that interface, and its output goes out through that interface
        //     whatever the destination-based table says. So a bound socket bypasses the exclusion.
        //   • The tunnel's address is an ordinary local address and appears in getifaddrs. Anything
        //     that enumerates interfaces and binds one socket per address will therefore send from
        //     it. ICE candidate gathering (FaceTime, WebRTC) does exactly that, per candidate — which
        //     is precisely the traffic observed.
        //
        // There is no NEPacketTunnelNetworkSettings knob that hides the utun address from interface
        // enumeration, so this is inherent to running a tunnel, not a misconfiguration here. The
        // correct defence is the one now in `rewriteIPv4`: anything that is not our loopback pair is
        // written back COMPLETELY UNTOUCHED. Such a packet is then injected into the local stack with
        // a non-local destination and dropped there (iOS does not forward), so that one ICE candidate
        // fails — the same outcome any VPN produces, and the same outcome the old code produced, minus
        // the corruption. Changing these routes would risk the ONE path confirmed working on device
        // (Cellular Mode: airplane-on → connect → teleport) to fix something that is already handled.

        // IPv6 is declared ONLY for the opt-in experiment. WHY NOT OTHERWISE:
        //
        // This provider used to declare an inert IPv6 config (a ULA plus a /128 route to the tunnel's
        // OWN address) unconditionally, on the theory that an IPv4-only NEPacketTunnelProvider can't
        // bind on an IPv6-only cellular carrier (Apple DTS, Developer Forums 670367). That inert config
        // bought nothing — a /128 route to our own address covers no peer — and it was not free: it put
        // an IPv6 address on the utun, so AF_INET6 packets (the kernel's own MLD reports and router
        // solicitations, at minimum) got handed to the read loop below, where with the experiment off
        // they were written back UNCHANGED into the same interface they came from. The reference
        // implementation declares no IPv6 at all. With the experiment off this now matches it exactly.
        //
        // ⚠️ HISTORY, CORRECTED 2026-08-06 — the note that used to live here was WRONG and it sent a
        // whole investigation down a dead end, so it is spelled out rather than deleted. The 2026-08-04
        // device failure (cellular-only, Wi-Fi off, no Airplane toggle, cert build; inject failed with
        // ENETUNREACH, "no route to 10.7.0.1") was the V4-ONLY dial: the code then dialled 10.7.0.1
        // unconditionally. The old note concluded "declaring a second address family cannot help while
        // the endpoint we dial is still IPv4 (simulate_location does inet_pton(AF_INET))", and that the
        // Airplane trick is therefore unavoidable on cellular. THAT CONCLUSION NO LONGER HOLDS. The dial
        // now runs through DeviceConnectionContext.dialTargets → makeSocketAddress, which does
        // inet_pton(AF_INET6) FIRST and dials the v6 peer FIRST whenever this SAME opt-in is on (see
        // DeviceConnectionContext.swift and IdeviceFFIBridge `_simulate_location`). So the endpoint
        // dialled is v6, not v4, and the 2026-08-04 result does not speak to the full v6 path at all —
        // that path is UNPROVEN on device and is exactly the experiment this branch exists to run.
        // See memory wander-tunnel-cellular-ipv6.
        //
        // The opt-in branch is the real fix: an address for the interface, and an included route that
        // COVERS the peer the app dials (::2, or the derived carrier-prefix peer) rather than the
        // /128-to-ourselves that covered nothing. Because that peer sits INSIDE the tunnel's own
        // included route, dialling it is delivered into the tunnel and looped locally — it does not
        // depend on the carrier having any v4 route, which is why it can succeed where the v4 dial got
        // ENETUNREACH on an IPv6-only carrier. The app only dials a v6 literal when this same opt-in is
        // on.
        if ipv6LoopbackEnabled {
            let ipv6 = NEIPv6Settings(addresses: [tunnelDeviceIpv6],
                                      networkPrefixLengths: [tunnelIpv6PrefixLength])
            // The route's destination must be the NETWORK address, not the peer's host address, so the
            // host bits are masked off here rather than trusting iOS to normalise "…::2/64".
            let routeDestination = ipv6NetworkAddress(fakeIp6, prefixLength: tunnelIpv6PrefixLength.intValue)
                ?? tunnelFakeIpv6
            ipv6.includedRoutes = [NEIPv6Route(destinationAddress: routeDestination,
                                               networkPrefixLength: tunnelIpv6PrefixLength)]
            ipv6.excludedRoutes = [.default()]
            settings.ipv6Settings = ipv6
        }

        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { return completionHandler(error) }
            self.startPacketLoop()
            PacketTrace.recordProviderStart(deviceIp: self.tunnelDeviceIp, fakeIp: self.tunnelFakeIp)
            completionHandler(nil)
        }
    }

    /// Arm the packet loop. THE ONLY WAY IT IS EVER ARMED, and it can only happen once.
    ///
    /// `setPackets()` re-arms itself from inside its own completion handler, so one call creates an
    /// endless chain. `NEPacketTunnelFlow` supports ONE outstanding `readPackets` call; a second
    /// entry point means a second concurrent chain on the same flow, with packets split between
    /// handlers or dropped outright. That is what the removed `reapplySettings()` did on every
    /// network change.
    ///
    /// A FLAG rather than "just don't call it twice": the flow is a property of the provider, not of
    /// the network settings, so there is never a legitimate reason to re-arm from outside — and
    /// making that structural is cheaper than trusting every future edit to know it. Read and written
    /// only from the `startTunnel` completion, so no lock is needed.
    /// ⚠️ MUST be reset in `stopTunnel`. Without that, a provider instance reused for a SECOND
    /// `startTunnel` installs its settings fine and then arms NO read loop at all — zero chains
    /// instead of two — which is a total blackhole and strictly worse than the double-arm this guard
    /// exists to prevent. iOS does not promise a fresh provider object per session, so this is not
    /// hypothetical.
    private var packetLoopStarted = false

    private func startPacketLoop() {
        guard !packetLoopStarted else { return }
        packetLoopStarted = true
        setPackets()
    }

    /// The only reason this override exists. `readPackets` chains are bound to the provider's flow,
    /// and the flow does not survive a stop — so the guard has to come back down with it, or a
    /// restarted tunnel carries nothing.
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        packetLoopStarted = false
        completionHandler()
    }

    func setPackets() {
        packetFlow.readPackets { [self] packets, protocols in
            let fakeip = self.fakeIpValue
            let deviceip = self.deviceIpValue
            var modified = packets
            // Hand the parsed v6 pair in too, so the trace can evaluate the SAME both-ends condition
            // the v6 arm below applies (src == device6 && dst == fake6) and record which side missed.
            // When the experiment is off these are the zeroed default and the v6 match is skipped.
            PacketTrace.record(packets: packets, protocols: protocols, deviceIp: deviceip, fakeIp: fakeip,
                               deviceIp6: self.deviceIp6, fakeIp6: self.fakeIp6)

            Self.rewriteIPv4(&modified, protocols: protocols, deviceIp: deviceip, fakeIp: fakeip)
            if self.ipv6LoopbackEnabled {
                Self.rewriteIPv6(&modified, protocols: protocols,
                                 deviceIp6: self.deviceIp6, fakeIp6: self.fakeIp6)
            }

            self.packetFlow.writePackets(modified, withProtocols: protocols)
            PacketTrace.recordWriteBack(count: modified.count)
            setPackets()
        }
    }

    // MARK: - The rewrite
    //
    // Lifted out of the `readPackets` closure ONLY so it can be driven directly by the host harness
    // (tools/packettrace compiles THIS FILE — see run.sh — so the scenarios exercise the shipping
    // code, not a transcription of it that can go stale). Behaviour is otherwise unchanged: same
    // loop, same guards, same offsets. `static` because neither arm reads any provider state.

    /// IPv4 arm of the loopback. Rewrites ONLY when BOTH ends match, and only ever as a true swap.
    ///
    /// ⚠️ DO NOT "SIMPLIFY" THIS BACK INTO TWO INDEPENDENT `if`s. Until 2026-08-06 it was:
    ///
    ///     if src == deviceip { ptr[3] = fakeip.bigEndian }
    ///     if dst == fakeip   { ptr[4] = deviceip.bigEndian }
    ///
    /// and the first line fired ALONE on any packet whose source merely happened to equal the
    /// tunnel's own interface address. That is not hypothetical: on the shipping default
    /// (deviceIp 10.7.0.0) a device trace on 2026-08-06 caught 1029 packets of LIVE FaceTime
    /// traffic in one session doing exactly that — e.g. `10.7.0.0:16394 -> 98.51.183.236:16393 UDP
    /// len=124 … ONE-SIDED` — because FaceTime's ICE candidate gathering binds a socket to EVERY
    /// local address, the utun's included. Source-bound sockets are scoped to their interface, so
    /// those packets enter this loop no matter what `excludedRoutes` says (see the routing note on
    /// `startTunnel`). Their source was being mangled to 10.7.0.1 — real user traffic, corrupted.
    ///
    /// WHY BOTH ENDS IS A CORRECTNESS REQUIREMENT, not tidiness. Nothing here recomputes a
    /// checksum, and nothing needs to *as long as the rewrite is a permutation*. The IPv4 header
    /// checksum and the TCP/UDP checksum are both one's-complement sums over a set that CONTAINS
    /// the source and the destination (for L4, via the pseudo-header), and addition is commutative
    /// — so exchanging the two leaves both sums bit-for-bit identical. Changing ONE side does not:
    /// both checksums go stale, and the packet is discarded as damaged. Requiring both ends makes
    /// that guarantee structural rather than incidental, exactly as the v6 arm below already did.
    ///
    /// Both directions of the intended loopback are device→fake (the daemon's reply leaves as
    /// deviceIp:port → fakeIp:ephemeral), so the designed flow always matches both ends and is
    /// unaffected. A packet that matches only one end is written back COMPLETELY UNTOUCHED.
    static func rewriteIPv4(_ packets: inout [Data], protocols: [NSNumber],
                            deviceIp: UInt32, fakeIp: UInt32) {
        for i in packets.indices where protocols[i].int32Value == AF_INET && packets[i].count >= 20 {
            packets[i].withUnsafeMutableBytes { bytes in
                guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                let src = UInt32(bigEndian: ptr[3])
                let dst = UInt32(bigEndian: ptr[4])
                guard src == deviceIp, dst == fakeIp else { return }
                ptr[3] = fakeIp.bigEndian
                ptr[4] = deviceIp.bigEndian
            }
        }
    }

    /// IPv6 arm of the same loopback. Separate loop on purpose: the v4 path above stays
    /// byte-identical, and this is called only when the experiment is on.
    ///
    /// The IPv6 header is FIXED at 40 bytes — version/traffic-class/flow-label (0..3), payload
    /// length (4..5), next header (6), hop limit (7), SOURCE at 8..<24, DESTINATION at 24..<40.
    ///
    /// NOTHING TO RECOMPUTE, and this looks like a bug until you see why it isn't. IPv6 deleted the
    /// header checksum outright, so there is none. The TCP/UDP checksum survives untouched for the
    /// commutativity reason spelled out above — and, for the same reason, only for a TRUE SWAP.
    /// This arm has required both ends since it was written; the v4 arm now matches it.
    static func rewriteIPv6(_ packets: inout [Data], protocols: [NSNumber],
                            deviceIp6: in6_addr, fakeIp6: in6_addr) {
        var device6 = deviceIp6
        var fake6 = fakeIp6
        for i in packets.indices where protocols[i].int32Value == AF_INET6 && packets[i].count >= 40 {
            packets[i].withUnsafeMutableBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                let sourceField = base.advanced(by: 8)
                let destinationField = base.advanced(by: 24)
                guard memcmp(sourceField, &device6, 16) == 0,
                      memcmp(destinationField, &fake6, 16) == 0 else { return }
                memcpy(sourceField, &fake6, 16)
                memcpy(destinationField, &device6, 16)
            }
        }
    }

    /// Masks the host bits off an IPv6 address so it can be used as a route destination.
    private func ipv6NetworkAddress(_ address: in6_addr, prefixLength: Int) -> String? {
        guard prefixLength >= 0, prefixLength <= 128 else { return nil }
        var bytes = withUnsafeBytes(of: address) { Array($0) }
        guard bytes.count == 16 else { return nil }
        for index in 0..<16 {
            let bitsBefore = index * 8
            if bitsBefore >= prefixLength {
                bytes[index] = 0
            } else if bitsBefore + 8 > prefixLength {
                let keep = prefixLength - bitsBefore
                bytes[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        var masked = in6_addr()
        withUnsafeMutableBytes(of: &masked) { raw in
            for index in 0..<16 { raw[index] = bytes[index] }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &masked, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private func ipToUInt32(_ ipString: String) -> UInt32 {
        let c = ipString.split(separator: ".")
        guard c.count == 4, let b1 = UInt32(c[0]), let b2 = UInt32(c[1]), let b3 = UInt32(c[2]), let b4 = UInt32(c[3]) else { return 0 }
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }

    /// Masks the host bits off a dotted-quad address so it can be used as a ROUTE destination.
    /// `static` because it runs while building the settings, before any instance state is needed.
    ///
    /// Returns nil for anything it cannot parse, so the caller falls back to the raw address and
    /// behaviour is never worse than before this existed. Deliberately strict: a component that is
    /// not a valid 0-255 octet is a parse failure rather than a silent 0, because "0" is a legal
    /// octet and swallowing a typo into 0.0.0.0 would produce a default route.
    static func networkAddress(_ address: String, mask: String) -> String? {
        func octets(_ s: String) -> [UInt32]? {
            let parts = s.split(separator: ".")
            guard parts.count == 4 else { return nil }
            var out: [UInt32] = []
            for p in parts {
                guard let v = UInt32(p), v <= 255 else { return nil }
                out.append(v)
            }
            return out
        }
        guard let a = octets(address), let m = octets(mask) else { return nil }
        return (0..<4).map { String(a[$0] & m[$0]) }.joined(separator: ".")
    }
}
