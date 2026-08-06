//
//  CellularIPv6Probe.swift
//  Wander
//
//  THE IPv6 TRACK: is the developer daemon reachable over IPv6 AT ALL, and can a tunnel address be
//  placed inside a prefix that a cellular-only phone actually has?
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHY THIS IS NOT THE IPv6 EXPERIMENT THAT ALREADY SHIPPED AND CHANGED NOTHING
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  The shipped opt-in (`DeviceConnectionContext.defaultTargetIPv6Address`) moves the loopback to
//  IPv6 but numbers it `fd00:7761:6e64:7272::2` — a ULA. A ULA sits inside NO non-utun interface's
//  prefix, which is the EXACT property that makes 10.7.0.1 fail the believed lockdownd rule on
//  iOS 26.4+. So that experiment changed the address FAMILY while holding the address PLACEMENT
//  wrong, and the rule reads placement. Even a perfectly working v6 loopback would be expected to
//  fail at the same policy gate the v4 one fails at.
//
//  Three separate things are therefore being confused with each other, and this file keeps them
//  apart:
//    (1) the OLD inert v6 config — a ULA plus a /128 route to the tunnel's own address, which
//        covered nothing. Device-tested 2026-08-04, did not work, now removed. It could not have
//        worked: the route covered no peer.
//    (2) the CURRENT opt-in v6 loopback. Still a ULA, and — read
//        DeviceConnectionContext.swift:35 — "⚠️ UNPROVEN UNTIL MEASURED ON A DEVICE". As far as
//        this file's author can tell it has never been measured at all, so it is neither confirmed
//        nor refuted, and its result would not decide (3) either way.
//    (3) THIS: place the address inside a prefix that a NON-utun interface owns on cellular. On a
//        cellular-only phone the IPv4 side has nothing to offer (pdp_ip0 is a /32 — one member, and
//        the device holds it). The IPv6 side has two prefixes with room on every cellular
//        interface: fe80::/64 and the carrier's routable /64.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT WAS MEASURED ON THE HOST BEFORE ANY OF THIS WAS WRITTEN (Darwin libc; same code as iOS)
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  M1. `getifaddrs` does NOT hand back link-local addresses in the KAME embedded-scope form. The
//      raw 16 bytes are `fe80:0000:0000:0000:…` and `sin6_scope_id` carries the real interface
//      index (lo0→1, en0→11, utun0→15). ⇒ EVERY link-local entry on the phone is BYTE-IDENTICAL in
//      its first 8 bytes, and each carries a real `ffff:ffff:ffff:ffff::` netmask.
//      CONSEQUENCE: a masked compare of the shape lockdownd is believed to run —
//      `((candidate ^ ifaceAddr) & mask) == 0` — passes TRIVIALLY for any fe80:: candidate against
//      any interface's link-local entry, including pdp_ip0's. That is the whole reason link-local
//      is interesting, and the reason it might also be the case Apple special-cased. Unknown.
//
//  M2. `inet_pton(AF_INET6, "fe80::1%en0", …)` RETURNS 1 ON DARWIN and writes `fe80:b::1` — it
//      EMBEDS the interface index into bytes 2..3 and leaves you no scope id (there is no field for
//      it). It does the same for any name it resolves, and silently ignores `%25en0` and unknown
//      names. This is a live trap in the current code: `DeviceConnectionContext.makeSocketAddress`
//      pton's the WHOLE string and then hardcodes `sin6_scope_id = 0`, so handing it a scoped
//      literal yields a corrupted address with no scope — and `fe80:b::…` no longer matches a
//      `fe80::/64` prefix compare, so it would fail the very test it was written for.
//      ⇒ Everything here splits `%iface` off FIRST and sets the scope from `if_nametoindex`.
//
//  M3. THE SCOPE ID IS LOAD-BEARING, and its absence is not a subtle difference:
//        [fe80::1]:9      scope 0    → errno 65 EHOSTUNREACH   "No route to host"
//        [fe80::1%lo0]:9  scope 1    → errno 61 ECONNREFUSED   (reached lo0's stack)
//        [fe80::1%en0]:9  scope 11   → errno 60 ETIMEDOUT      (left on en0)
//      Identical address bytes; only the scope changed, and it changed WHICH INTERFACE the packet
//      left on. ⇒ For a link-local destination the SCOPE ID — not the routing table — selects the
//      egress interface. That sidesteps, for this one family, the entire longest-prefix /
//      `enforceRoutes` / `excludeLocalNetworks` fight the IPv4 track is stuck in: there is no
//      ambiguous route to lose, because there is no route lookup to win.
//
//  M4. `sizeof(struct sockaddr_in6)` == 28 on Darwin, and the vendored FFI's converter requires
//      exactly that ("IPv6 sockaddr_in6 data too short, expected at least 28 bytes", present as a
//      literal in libidevice_ffi.a).
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE FFI CARRIES THE SCOPE. VERIFIED IN THE UPSTREAM SOURCE, NOT ASSUMED.
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  jkcoxson/idevice, ffi/src/util.rs, `c_socket_to_rust`, AF_INET6 branch, verbatim:
//
//      let a = &*(addr as *const sockaddr_in6);
//      let ip = Ipv6Addr::from(a.sin6_addr.s6_addr);
//      let port = u16::from_be(a.sin6_port);
//      Ok(SocketAddr::V6(std::net::SocketAddrV6::new(
//          ip, port, a.sin6_flowinfo, a.sin6_scope_id,
//      )))
//
//  and ffi/src/tunnel_provider.rs hands that `SocketAddr` straight to
//  `tokio::net::TcpStream::connect(socket_addr)`, which writes `sin6_scope_id` back out. The
//  SECOND hop inherits it too — `finish_tunnel` copies the same address and only calls
//  `tunnel_addr.set_port(tunnel_port)`. ⇒ A scoped link-local dial survives end to end. Nothing in
//  the FFI has to be rebuilt for this track.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT THIS FILE DOES
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  It runs the IPv6 TWIN OF FACT F1 — the measurement that found `127.0.0.1:49152` CONNECTED on
//  cellular with Wi-Fi off — and it needs NO tunnel, NO Wi-Fi, NO entitlement and no reconnect. It
//  is the cheapest decisive experiment in the whole track, because it can KILL the track outright:
//
//      [::1]:49152 REFUSED  ⇒ remotepairingd does not listen on IPv6. Every v6 tunnel address in
//                             this file is then unreachable by construction. Stop here.
//      [::1]:49152 CONNECTED ⇒ the daemon is dual-stack (or v6-bound), the family is live, and the
//                             placement question below is worth the reconnects it costs.
//
//  It then dumps every IPv6 address the phone holds with its RAW BYTES (so M1 is re-verified on the
//  phone rather than inherited from the Mac), runs the believed lockdownd compare against each
//  candidate, and proposes concrete tunnel addresses carved out of the non-utun prefixes.
//
//  NOTHING HERE CHANGES ANY BEHAVIOUR. No preference is written, no tunnel is started or stopped,
//  no address is applied. It measures and it prints.
//
//  BLOCKING. Run it off the main thread and off `LocationSimulationCommandQueue`, which Stop and
//  Panic have to ride. Bounded at 1.5 s per probe.
//

import Foundation
import Darwin

// MARK: - An IPv6 endpoint that actually carries its scope

/// An IPv6 destination parsed the way Darwin needs it: address bytes and scope id kept APART.
///
/// Built instead of reusing `DeviceConnectionContext.makeSocketAddress` for one reason, and it is
/// not a style preference — see M2 above. That function pton's the whole string and pins
/// `sin6_scope_id = 0`, which silently corrupts any scoped literal into the KAME embedded form. A
/// link-local probe built on it would measure a different address than the one printed in its own
/// log line, which is the worst failure mode a diagnostic can have.
struct ScopedIPv6Endpoint: Sendable {

    /// Exactly what the caller wrote, e.g. `fe80::14ba:f0a2:…%pdp_ip0`. Printed verbatim.
    let text: String
    /// The address with any `%iface` suffix removed — the part that goes through `inet_pton`.
    let bareAddress: String
    /// The interface named after `%`, if any.
    let interfaceName: String?
    /// `if_nametoindex` of that interface. 0 when unscoped.
    let scopeID: UInt32
    /// The 16 address bytes, network order.
    let bytes: [UInt8]
    let port: UInt16

    /// fe80::/10. The scope id is REQUIRED for these (M3).
    var isLinkLocal: Bool { bytes.count == 16 && bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 }
    /// ::1
    var isLoopback: Bool { bytes.count == 16 && bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1 }
    /// fc00::/7 — a unique local address, e.g. the ULA the shipped opt-in uses.
    var isUniqueLocal: Bool { bytes.count == 16 && (bytes[0] & 0xFE) == 0xFC }
    /// ::ffff:a.b.c.d — a v4-mapped address. Only a DUAL-STACK listener answers one of these.
    var isV4Mapped: Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
    }
    /// 2000::/3 — a global unicast address, which is what a carrier hands a phone.
    var isGlobalUnicast: Bool { bytes.count == 16 && (bytes[0] & 0xE0) == 0x20 }

    /// True when this endpoint is unusable as written: a link-local with no scope. Measured to give
    /// EHOSTUNREACH rather than anything that looks like a real network answer, so a probe that
    /// reported it as "no route" without saying why would be actively misleading.
    var isUnscopedLinkLocal: Bool { isLinkLocal && scopeID == 0 }

    /// `[addr%iface]:49152`, bracketed so the port can't be misread as another hextet.
    var destination: String { "[\(text)]:\(port)" }

    var familyNote: String {
        if isLoopback { return "IPv6 loopback" }
        if isV4Mapped { return "IPv4-mapped (only a dual-stack listener answers)" }
        if isLinkLocal { return "link-local fe80::/10" + (scopeID == 0 ? " — NO SCOPE" : " scope \(scopeID)") }
        if isUniqueLocal { return "unique-local fc00::/7" }
        if isGlobalUnicast { return "global unicast 2000::/3" }
        return "IPv6"
    }

    /// Parse `addr` or `addr%iface`. Returns nil when the address part is not an IPv6 literal.
    ///
    /// An UNKNOWN interface name is kept, with scope 0, rather than rejected: "you named an
    /// interface that does not exist" is a finding worth printing, and silently dropping it would
    /// turn it into a mysterious EHOSTUNREACH later.
    init?(_ address: String, port: UInt16 = DeviceConnectionContext.developerTunnelPort) {
        let parts = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let bare = String(parts.first ?? "")
        let iface = parts.count > 1 ? String(parts[1]) : nil

        var storage = in6_addr()
        guard bare.withCString({ inet_pton(AF_INET6, $0, &storage) }) == 1 else { return nil }

        var decoded = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &storage) { raw in
            for i in 0..<16 { decoded[i] = raw[i] }
        }

        self.text = address
        self.bareAddress = bare
        self.interfaceName = (iface?.isEmpty == false) ? iface : nil
        self.scopeID = self.interfaceName.flatMap { InterfaceScope.index(forName: $0) } ?? 0
        self.bytes = decoded
        self.port = port
    }

    /// Build the address from bytes we computed ourselves (a carved candidate), with an explicit
    /// scope. No parsing round-trip, so a carved address can never be mangled on the way back in.
    init?(bytes: [UInt8], scopeID: UInt32, interfaceName: String?,
          port: UInt16 = DeviceConnectionContext.developerTunnelPort) {
        guard bytes.count == 16 else { return nil }
        let bare = WiFiSubnet.presentation(family: AF_INET6, bytes: bytes)
        guard !bare.isEmpty else { return nil }
        self.bytes = bytes
        self.bareAddress = bare
        self.interfaceName = interfaceName
        self.scopeID = scopeID
        self.text = interfaceName.map { "\(bare)%\($0)" } ?? bare
        self.port = port
    }

    /// A `sockaddr_in6` with the scope in the field the kernel reads, handed to a C call as
    /// `(const struct sockaddr *, socklen_t)`.
    ///
    /// The length is `MemoryLayout<sockaddr_in6>.size` — 28 — and NOT `sockaddr_storage`'s size,
    /// because the FFI's converter checks it against `size_of::<sockaddr_in6>()` and rejects a
    /// mismatch (M4).
    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
        var sa = sockaddr_in6()
        sa.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sa.sin6_family = sa_family_t(AF_INET6)
        sa.sin6_port = in_port_t(port).bigEndian
        sa.sin6_flowinfo = 0
        sa.sin6_scope_id = scopeID
        withUnsafeMutableBytes(of: &sa.sin6_addr) { raw in
            for i in 0..<16 { raw[i] = bytes[i] }
        }
        return try withUnsafePointer(to: &sa) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    }
}

// MARK: - One IPv6 probe

struct IPv6ProbeResult: Sendable {
    let endpoint: ScopedIPv6Endpoint
    let label: String
    let outcome: EndpointProbeOutcome
    let errnoValue: Int32
    let syscall: String
    /// `getsockname()` — the source address the kernel chose, which is the address the believed
    /// lockdownd rule actually inspects.
    let localAddress: String?
    let elapsedMilliseconds: Int

    var isReachable: Bool { outcome == .connected }

    var logLine: String {
        var s = "\(endpoint.destination) [\(endpoint.familyNote)] → \(outcome.label)"
        s += " errno \(errnoValue) \(EndpointProbe.errnoName(errnoValue))"
        if errnoValue != 0, let text = strerror(errnoValue) {
            s += " (\(String(cString: text)))"
        }
        s += " · source \(localAddress ?? "<none assigned>")"
        s += " after \(elapsedMilliseconds) ms via \(syscall)"
        return s
    }
}

enum ScopedIPv6Probe {

    /// Bounded, non-blocking TCP connect over IPv6 WITH the scope id set. Never throws, never traps.
    ///
    /// Deliberately a sibling of `EndpointProbe.probe` rather than a parameter on it: that function
    /// gates the real dial path on every inject and must not grow a v6-only concept. The two shared
    /// pieces — `EndpointProbe.classify` and `EndpointProbe.errnoName` — are reused, so this probe
    /// and every other probe in the app can never disagree about what a number means.
    ///
    /// ERRNO IS CAPTURED IN THE STATEMENT IMMEDIATELY AFTER EACH SYSCALL, for the reason spelled out
    /// at the top of EndpointProbe.swift: it is a thread-local any later libc call overwrites.
    static func probe(_ endpoint: ScopedIPv6Endpoint,
                      label: String,
                      timeoutSeconds: Double = 1.5) -> IPv6ProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }

        var localAddress: String?
        func result(_ outcome: EndpointProbeOutcome, _ code: Int32, _ syscall: String) -> IPv6ProbeResult {
            IPv6ProbeResult(endpoint: endpoint, label: label, outcome: outcome,
                            errnoValue: code, syscall: syscall,
                            localAddress: localAddress, elapsedMilliseconds: elapsed())
        }

        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        let socketErrno = errno
        guard fd >= 0 else { return result(.localFailure, socketErrno, "socket") }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var connectErrno: Int32 = 0
        let rc = endpoint.withSockaddr { pointer, length -> Int32 in
            let returned = connect(fd, pointer, length)
            connectErrno = errno
            return returned
        }

        // Read the source NOW, whether the connect succeeded, failed, or is still in flight: Darwin
        // latches the local address in in6_pcbconnect() before the SYN goes out, so it is valid
        // under EINPROGRESS — and EINPROGRESS is the case it matters most for.
        localAddress = ScopedEndpointProbe.localAddress(of: fd)

        if rc == 0 { return result(.connected, 0, "connect") }
        if connectErrno != EINPROGRESS {
            return result(EndpointProbe.classify(connectErrno), connectErrno, "connect")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRC = poll(&pfd, 1, Int32(max(timeoutSeconds, 0.1) * 1000))
        let pollErrno = errno
        if pollRC == 0 {
            localAddress = ScopedEndpointProbe.localAddress(of: fd) ?? localAddress
            return result(.noAnswer, 0, "poll (bounded wait expired)")
        }
        if pollRC < 0 { return result(.localFailure, pollErrno, "poll") }

        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let getRC = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        let getErrno = errno
        localAddress = ScopedEndpointProbe.localAddress(of: fd) ?? localAddress
        guard getRC == 0 else { return result(.localFailure, getErrno, "getsockopt(SO_ERROR)") }
        if soError == 0 { return result(.connected, 0, "connect (async)") }
        return result(EndpointProbe.classify(soError), soError, "connect (async, read from SO_ERROR)")
    }
}

// MARK: - Carving a tunnel address out of an IPv6 prefix

/// A concrete proposal: two addresses inside a non-utun interface's IPv6 prefix, plus the prefix
/// length the tunnel should DECLARE so it wins the route without claiming the parent's whole /64.
struct IPv6TunnelPlan: Sendable {
    /// The interface the prefix was taken from.
    let parentName: String
    let parentCIDR: String
    /// True when the parent prefix is fe80::/64 — the case where the scope id, not the route table,
    /// picks the interface.
    let parentIsLinkLocal: Bool
    /// The address the tunnel interface takes (the analogue of `TunnelInterfaceIP`).
    let deviceAddress: String
    /// The fake peer the app dials (the analogue of `TunnelDeviceIP`) — and, after the provider's
    /// src/dst swap, the SOURCE ADDRESS remotepairingd sees.
    let fakeAddress: String
    /// What the provider should declare in `NEIPv6Settings(networkPrefixLengths:)`.
    let declaredPrefixLength: Int
    /// The parent's own prefix length, for the comparison that makes the point.
    let parentPrefixLength: Int
    let notes: [String]
}

enum IPv6TunnelPlanner {

    /// The host part written into every carved address: ASCII "wander" then a zero byte, then a
    /// counter. Chosen so a candidate is instantly recognisable in a packet trace or a system log,
    /// and so two carved addresses differ only in the final byte.
    static let hostSignature: [UInt8] = [0x77, 0x61, 0x6E, 0x64, 0x65, 0x72, 0x00]

    /// Declare a /126 on the tunnel for the SAME reason the IPv4 planner declares a /30: Darwin
    /// routes by longest matching prefix, so a /126 beats the parent's /64 for exactly the four
    /// addresses we carved and for nothing else. The parent keeps every other address in its /64.
    ///
    /// For a LINK-LOCAL parent this is belt and braces rather than the mechanism — M3 showed the
    /// scope id selects the interface for a link-local destination, so there is no route to win.
    /// Declaring it anyway costs nothing and keeps the two cases configured identically.
    static let declaredPrefixLength = 126

    /// Carve a pair out of `entry`'s prefix, avoiding every address the device already holds.
    ///
    /// Returns nil when the entry has no netmask (the lockdownd IPv6 branch could not match it
    /// either), when the prefix leaves fewer than 8 free bits, or when the entry is a utun (whose
    /// prefixes the believed rule excludes — that is the one `strncmp(ifa_name, "utun", 4)`).
    static func plan(from entry: NetworkInterfaceAddress,
                     held: Set<[UInt8]>) -> IPv6TunnelPlan? {
        guard entry.isIPv6, !entry.isUtun, entry.isUp else { return nil }
        guard let mask = entry.maskBytes, mask.count == 16, entry.addressBytes.count == 16 else { return nil }
        guard entry.maskIsContiguous else { return nil }
        let prefixLength = WiFiSubnet.leadingOnes(mask)
        guard prefixLength <= 120 else { return nil }
        // ::1/128 is the loopback entry; a /128 is caught above, but say so explicitly for the
        // reader rather than relying on the arithmetic to have covered it.
        guard !entry.isLoopback else { return nil }

        let network = zip(entry.addressBytes, mask).map { $0 & $1 }

        /// prefix bits from `network`, host bits from `pattern`. The mask is the only thing that
        /// decides which is which, so a carved address can never disturb the parent's prefix.
        func carve(lastByte: UInt8) -> [UInt8] {
            var pattern = [UInt8](repeating: 0, count: 16)
            // Right-align the signature in the low bytes, leaving the final byte for the counter.
            let start = 16 - hostSignature.count - 1
            for (offset, byte) in hostSignature.enumerated() { pattern[start + offset] = byte }
            pattern[15] = lastByte
            return (0..<16).map { network[$0] | (pattern[$0] & ~mask[$0]) }
        }

        var device = carve(lastByte: 0x10)
        var fake = carve(lastByte: 0x11)
        // A collision with an address the device already holds would trip the OTHER believed
        // lockdownd check (a source the device itself owns is rejected), so walk the counter.
        var counter: UInt8 = 0x10
        while (held.contains(device) || held.contains(fake)) && counter < 0xF0 {
            counter &+= 2
            device = carve(lastByte: counter)
            fake = carve(lastByte: counter &+ 1)
        }
        guard !held.contains(device), !held.contains(fake) else { return nil }

        let deviceText = WiFiSubnet.presentation(family: AF_INET6, bytes: device)
        let fakeText = WiFiSubnet.presentation(family: AF_INET6, bytes: fake)
        guard !deviceText.isEmpty, !fakeText.isEmpty else { return nil }

        let isLinkLocal = entry.addressBytes[0] == 0xFE && (entry.addressBytes[1] & 0xC0) == 0x80

        var notes: [String] = []
        notes.append("the fake peer \(fakeText) is what remotepairingd sees as the connection SOURCE, after the provider swaps src/dst. It sits inside \(entry.name)'s \(entry.cidr ?? "prefix"), which is not a utun — the two conditions the believed lockdownd rule composes.")
        notes.append("declare /\(declaredPrefixLength) on the tunnel, NOT /\(prefixLength). A /\(prefixLength) would claim the identical prefix \(entry.name) already owns and the route would be a coin flip — the same bug the IPv4 planner fixes with a /30.")
        if isLinkLocal {
            notes.append("LINK-LOCAL: measured on Darwin, the scope id — not the routing table — selects the egress interface for an fe80:: destination (same address, scope lo0 → ECONNREFUSED, scope en0 → ETIMEDOUT). So this candidate does not have to WIN a route, and enforceRoutes / excludeLocalNetworks are not in play for it.")
            notes.append("LINK-LOCAL: fe80::/64 is a CONSTANT. It survives a PDP re-establishment, a carrier renumbering, airplane mode and a handover, none of which a carrier-prefix address survives.")
            notes.append("LINK-LOCAL CAVEAT: every interface's fe80::/64 has identical prefix bytes, so the believed masked compare is VACUOUSLY true for any fe80:: source. If Apple noticed that, the IPv6 branch may special-case link-local — and that branch is exactly the one the published decompilation snipped. This is the single biggest unknown in this plan.")
        } else {
            notes.append("CARRIER PREFIX CAVEAT: this /\(prefixLength) is delegated by the network and is NOT stable — it changes on PDP re-establishment, on a handover, and after airplane mode. The provider reads its addresses ONCE in startTunnel(options:), so a rotation leaves the tunnel numbered in a prefix the phone no longer has, with nothing to notice it.")
            notes.append("the packets never leave the phone (the provider swaps src/dst and writes them straight back), so the carrier is not involved and cannot object; nothing is ever sourced onto pdp_ip0 from these addresses, so there is nothing for duplicate-address detection to collide with.")
        }
        notes.append("neither address is one this device currently holds, so neither trips the older lockdownd check that rejects a source the device itself owns.")

        return IPv6TunnelPlan(parentName: entry.name,
                              parentCIDR: entry.cidr ?? "?",
                              parentIsLinkLocal: isLinkLocal,
                              deviceAddress: deviceText,
                              fakeAddress: fakeText,
                              declaredPrefixLength: declaredPrefixLength,
                              parentPrefixLength: prefixLength,
                              notes: notes)
    }
}

// MARK: - The run

enum CellularIPv6Probe {

    static let probeTimeoutSeconds: Double = 1.5

    /// Probe, dump, plan, and write it all into the Console. Returns a short summary for an alert.
    ///
    /// BLOCKING — call from a background queue, never the main thread and never
    /// `LocationSimulationCommandQueue`.
    static func runAndSummarize(reason: String = "manual") -> String {
        var lines: [String] = []
        var results: [IPv6ProbeResult] = []

        lines.append("=== CELLULAR IPv6 PROBE === port \(DeviceConnectionContext.developerTunnelPort) · reason: \(reason)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Int(probeTimeoutSeconds * 1000)) ms bound per probe")
        lines.append("QUESTION 1 (decisive): does remotepairingd answer on IPv6 AT ALL? If [::1] is REFUSED, every IPv6 tunnel address below is unreachable by construction and this whole track is dead.")

        let entries = WiFiSubnet.allAddresses()
        let v6 = entries.filter { $0.isIPv6 }

        // ── 1. THE RAW INVENTORY ─────────────────────────────────────────────────────────────────
        // Raw bytes, not just the presentation form. The KAME embedded-scope question (M1) cannot be
        // answered from `inet_ntop` output alone, and it decides whether a masked prefix compare
        // against a link-local entry can ever match.
        lines.append("--- IPv6 ADDRESSES, RAW ---")
        if v6.isEmpty { lines.append("  (none — the phone holds no IPv6 address at all)") }
        for e in v6 {
            var line = "  \(e.name) \(WiFiSubnet.presentation(family: AF_INET6, bytes: e.addressBytes))"
            line += " raw \(hex(e.addressBytes))"
            line += " sin6_scope_id \(e.scopeID)"
            if let m = e.maskBytes {
                line += " mask /\(WiFiSubnet.leadingOnes(m))"
                if let c = e.cidr { line += " subnet \(c)" }
                if !e.maskIsContiguous { line += " NON-CONTIGUOUS-MASK" }
            } else {
                line += " mask <NONE — the lockdownd subnet compare cannot match this entry>"
            }
            let linkLocal = e.addressBytes.count == 16 && e.addressBytes[0] == 0xFE && (e.addressBytes[1] & 0xC0) == 0x80
            if linkLocal {
                let embedded = e.addressBytes.count == 16 && (e.addressBytes[2] != 0 || e.addressBytes[3] != 0)
                line += embedded
                    ? " ⚠️ KAME-EMBEDDED SCOPE in bytes 2..3 — link-local prefixes are NOT byte-identical on this OS, which breaks the fe80 plan below"
                    : " link-local, scope NOT embedded (prefix bytes identical to every other fe80::/64 — the plan below holds)"
            }
            line += " [\(e.flagsDescription)]\(e.isUtun ? " UTUN — excluded by the believed rule" : "")"
            lines.append(line)
        }

        let eligible = v6.filter { !$0.isUtun && $0.maskBytes != nil && !$0.isLoopback }
        lines.append("NON-UTUN IPv6 PREFIXES (the ones the believed rule can match): " +
                     (eligible.isEmpty ? "NONE"
                      : eligible.map { "\($0.name) \($0.cidr ?? "?")" }.joined(separator: ", ")))

        // ── 2. THE PROBES ────────────────────────────────────────────────────────────────────────
        lines.append("--- PROBES ---")
        func run(_ label: String, _ address: String) {
            guard let endpoint = ScopedIPv6Endpoint(address) else {
                lines.append("  \(label) — \(address): not an IPv6 literal, nothing probed")
                return
            }
            if endpoint.isUnscopedLinkLocal {
                lines.append("  \(label) — \(endpoint.destination): link-local with NO scope id. Measured to give EHOSTUNREACH regardless of what is listening, so this would prove nothing. Skipped.")
                return
            }
            let result = ScopedIPv6Probe.probe(endpoint, label: label, timeoutSeconds: probeTimeoutSeconds)
            results.append(result)
            lines.append("  [\(results.count)] \(label) — \(result.logLine)")
        }

        // The decisive pair. `::1` answers "is the daemon on IPv6"; `::ffff:127.0.0.1` separates a
        // DUAL-STACK v6 socket (which answers both) from a v6-only one (which answers only `::1`).
        run("IPv6 loopback — THE decisive probe", "::1")
        run("IPv4-mapped loopback — dual-stack test", "::ffff:127.0.0.1")

        // Every non-utun IPv6 address the phone holds, scoped to its own interface. On a
        // cellular-only phone these are pdp_ip0/1/2's link-locals and the carrier's routable
        // address. A CONNECTED here says the daemon accepts a connection arriving over that
        // interface's IPv6 — which is more than `::1` proves.
        for e in eligible {
            let bare = WiFiSubnet.presentation(family: AF_INET6, bytes: e.addressBytes)
            guard !bare.isEmpty else { continue }
            let linkLocal = e.addressBytes[0] == 0xFE && (e.addressBytes[1] & 0xC0) == 0x80
            run("\(e.name) own address (\(e.cidr ?? "?"))", linkLocal ? "\(bare)%\(e.name)" : bare)
        }

        // The IPv4 control. F1 measured 127.0.0.1:49152 CONNECTED on cellular with Wi-Fi off, so a
        // failure HERE means the run itself is broken and every v6 line above should be discarded.
        let control = EndpointProbe.probe("127.0.0.1", timeoutSeconds: probeTimeoutSeconds)
        lines.append("  [control] IPv4 loopback (F1 said CONNECTED, 0 ms) — \(control.logLine)")

        // ── 3. THE PLANS ─────────────────────────────────────────────────────────────────────────
        lines.append("--- CANDIDATE TUNNEL ADDRESSES ---")
        let held = Set(entries.filter { $0.isIPv6 }.map(\.addressBytes))
        var plans: [IPv6TunnelPlan] = []
        for e in eligible {
            guard let plan = IPv6TunnelPlanner.plan(from: e, held: held) else { continue }
            plans.append(plan)
            lines.append("  \(plan.parentName) \(plan.parentCIDR) → device \(plan.deviceAddress) · fake peer \(plan.fakeAddress) · declare /\(plan.declaredPrefixLength)")
            for note in plan.notes { lines.append("    • \(note)") }
        }
        if plans.isEmpty {
            lines.append("  NONE — no non-utun IPv6 prefix on this phone has a netmask and room to carve. With Wi-Fi off that would mean the cellular interfaces are reporting IPv6 without a mask, which is itself the answer to the placement question.")
        }

        lines.append(contentsOf: verdictLines(results: results, control: control, plans: plans, eligible: eligible))
        lines.append("=== END CELLULAR IPv6 PROBE ===")

        for line in lines { LogManager.shared.addInfoLog(line) }
        // Same retention store as the interface dump and the endpoint sweep: opening the Console
        // REPLACES the log buffer with what it parses off disk, which would otherwise wipe this the
        // moment somebody navigated over to read it.
        NetworkInterfaceDump.retain(lines)

        return shortSummary(results: results, control: control, plans: plans)
    }

    // MARK: - The verdict

    static func verdictLines(results: [IPv6ProbeResult],
                             control: EndpointProbeResult,
                             plans: [IPv6TunnelPlan],
                             eligible: [NetworkInterfaceAddress]) -> [String] {
        var out: [String] = []

        guard control.isReachable else {
            out.append("VERDICT ⚠️ THE CONTROL FAILED. 127.0.0.1:49152 → \(control.outcome.label), but F1 measured it CONNECTED in 0 ms. Something about this run is broken — the developer tunnel daemon may not be up at all. Discard every IPv6 line above and re-run once the control passes.")
            return out
        }

        let loopback = results.first { $0.endpoint.isLoopback }
        let mapped = results.first { $0.endpoint.isV4Mapped }

        switch loopback?.outcome {
        case .some(.connected):
            out.append("VERDICT Q1 — remotepairingd DOES answer on IPv6: [::1]:49152 CONNECTED. The address family is live, so the placement question below is worth the reconnects it costs.")
            switch mapped?.outcome {
            case .some(.connected):
                out.append("VERDICT the listener is DUAL-STACK — an IPv4-mapped address was accepted too, so it is one in6addr_any socket with IPV6_V6ONLY off, not a separate v6 listener.")
            case .some(let other):
                out.append("VERDICT the listener is IPv6-ONLY or separately bound — the IPv4-mapped probe came back \(other.label). Not a blocker; noted so the shape of the bind is on record.")
            case .none:
                break
            }
        case .some(.refused):
            out.append("VERDICT Q1 — ⛔️ THE IPv6 TRACK IS DEAD. [::1]:49152 was REFUSED: packets reach the stack and nothing is listening on IPv6. remotepairingd binds IPv4 only, so NO IPv6 tunnel address can ever reach it, however it is placed. Stop here and spend the effort on the IPv4 tracks.")
            return out
        case .some(let other):
            out.append("VERDICT Q1 — INCONCLUSIVE. [::1]:49152 came back \(other.label), which is neither 'listening' nor 'nothing there'. \(other.meaning) Re-run; if it repeats, the phone's IPv6 loopback itself is the thing to look at, not the daemon.")
            return out
        case .none:
            out.append("VERDICT Q1 — NOT MEASURED. The IPv6 loopback probe never ran.")
            return out
        }

        // Which interfaces answered on their OWN v6 address. That is a stronger fact than `::1`:
        // it says the daemon accepts a connection arriving over that interface, not just over lo0.
        let answered = results.filter { $0.isReachable && !$0.endpoint.isLoopback && !$0.endpoint.isV4Mapped }
        if answered.isEmpty {
            out.append("VERDICT Q2 — the daemon answers on ::1 but on NO other IPv6 address the phone holds. Either it binds the loopback specifically, or the source-address policy already rejected these (they ARE addresses the device holds, which the older lockdownd check rejects outright — so this result is EXPECTED and does not refute the plan). The plan's fake peer is NOT an address the device holds, which is the difference.")
        } else {
            out.append("VERDICT Q2 — the daemon also answered on: " +
                       answered.map { $0.endpoint.destination }.joined(separator: ", ") +
                       ". Those are addresses the device holds, so a connection to them was accepted despite the older own-address check — worth knowing, because it bounds how strict the policy actually is.")
        }

        let linkLocalPlans = plans.filter(\.parentIsLinkLocal)
        let routablePlans = plans.filter { !$0.parentIsLinkLocal }
        if plans.isEmpty {
            out.append("VERDICT Q3 — no candidate could be carved. Read the raw inventory above: either no non-utun IPv6 entry has a netmask, or every prefix is too long to hold a pair.")
        } else {
            out.append("VERDICT Q3 — try them in this order:")
            for plan in linkLocalPlans {
                out.append("  1. LINK-LOCAL on \(plan.parentName): device \(plan.deviceAddress), fake peer \(plan.fakeAddress), declare /\(plan.declaredPrefixLength). FIRST because fe80::/64 is constant and the scope id picks the interface, so no route has to be won.")
            }
            for plan in routablePlans {
                out.append("  2. CARRIER PREFIX on \(plan.parentName) (\(plan.parentCIDR)): device \(plan.deviceAddress), fake peer \(plan.fakeAddress), declare /\(plan.declaredPrefixLength). SECOND because the prefix is delegated and rotates underneath a tunnel that reads its addresses only once.")
            }
            out.append("VERDICT ⚠️ what this run CANNOT tell you: whether iOS will accept these in NEIPv6Settings at all (a link-local address in `addresses:` may be refused outright — it is normally auto-assigned), and whether lockdownd's IPv6 branch does the same masked compare as its IPv4 one. That branch is the piece the published decompilation snipped, so it is unknown here and unknown everywhere. Only a tunnel started with these addresses answers it.")
        }

        let unscoped = results.filter { $0.endpoint.isLinkLocal && $0.endpoint.scopeID == 0 }
        if !unscoped.isEmpty {
            out.append("VERDICT ⚠️ these link-local probes ran with NO scope id and therefore measured nothing: " +
                       unscoped.map { $0.endpoint.destination }.joined(separator: ", "))
        }

        return out
    }

    private static func shortSummary(results: [IPv6ProbeResult],
                                     control: EndpointProbeResult,
                                     plans: [IPv6TunnelPlan]) -> String {
        guard control.isReachable else {
            return "The IPv4 control failed (127.0.0.1:49152 → \(control.outcome.label)), so nothing here is trustworthy. The developer tunnel daemon may not be up. Re-run.\n\nFull detail is in the log below."
        }
        guard let loopback = results.first(where: { $0.endpoint.isLoopback }) else {
            return "The IPv6 loopback was never probed. Full detail is in the log below."
        }
        var text: String
        switch loopback.outcome {
        case .connected:
            text = "IPv6 IS LIVE: [::1]:49152 accepted a connection, so remotepairingd listens on IPv6.\n"
            text += plans.isEmpty
                ? "No tunnel address could be carved — read the raw inventory in the log."
                : "\(plans.count) candidate tunnel address(es) proposed; the link-local one is listed first."
        case .refused:
            text = "IPv6 IS DEAD: [::1]:49152 was REFUSED. Nothing listens on IPv6, so no IPv6 tunnel address can reach the daemon however it is placed. This closes the track."
        default:
            text = "Inconclusive: [::1]:49152 → \(loopback.outcome.label). \(loopback.outcome.meaning)"
        }
        text += "\n\nFull detail and the verdict are in the log below — use Export Logs to send it."
        return text
    }

    /// 16 bytes as `fe80:0000:…`, so the KAME question is answerable by eye.
    private static func hex(_ bytes: [UInt8]) -> String {
        var out = ""
        for (i, b) in bytes.enumerated() {
            out += String(format: "%02x", b)
            if i % 2 == 1 && i != bytes.count - 1 { out += ":" }
        }
        return out
    }
}
