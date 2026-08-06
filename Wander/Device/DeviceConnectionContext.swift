//
//  DeviceConnectionContext.swift
//  Wander
//
//  Created by Stephen.
//

import Foundation
import Darwin

enum DeviceConnectionContext {
    static let defaultTargetIPAddress = "10.7.0.1"

    /// The developer-tunnel (remotepairing) port. Same for both address families.
    static let developerTunnelPort: UInt16 = 49152

    // MARK: - Experimental all-IPv6 loopback (opt-in, default OFF)
    //
    // WHY IT EXISTS: on an IPv6-only cellular carrier (pdp_ip0 has no IPv4 address — increasingly
    // common) the developer tunnel does not come up, and the user has to toggle Airplane Mode to make
    // iOS rebuild the interface. Declaring an IPv6 address on the tunnel is NOT enough on its own —
    // tested on device 2026-08-04, the inject still failed with "network unreachable … adapter closed"
    // (ENETUNREACH: no route to 10.7.0.1) — because the endpoint we DIAL is still IPv4. Adding an
    // address family to the tunnel doesn't help while the socket still asks for a v4 route that an
    // IPv6-only carrier cannot provide.
    //
    // So this moves the WHOLE loopback to IPv6: the NE assigns a ULA and includes a route that covers
    // the peer, and the client dials that peer as an IPv6 literal. The FFI already supports this — its
    // entry points take a generic `const idevice_sockaddr *` plus a socklen, and the Rust side's
    // sockaddr→SocketAddr converter has a real AF_INET6 branch (verified in the vendored
    // libidevice_ffi.a: it contains the "Invalid sockaddr_in6 size" literal and its tracing call-site
    // marker). The inner leg of the tunnel is already IPv6 on iOS 17+; this only makes the OUTER hop
    // match.
    //
    // ⚠️ UNPROVEN UNTIL MEASURED ON A DEVICE. It is not known whether remotepairingd binds in6addr_any
    // (dual-stack) or only 0.0.0.0 on port 49152. iOS publishes AAAA records for _remotepairing._tcp
    // via Bonjour, which is suggestive, not proof. Hence: opt-in, default off, and every dial falls
    // back to the working IPv4 path.

    /// FALLBACK address the NE assigns to the tunnel interface — the analogue of 10.7.0.0.
    ///
    /// ⚠️ THIS IS A ULA, AND A ULA CANNOT PASS THE PLACEMENT TEST. It belongs to no interface, so it
    /// fails the "inside some non-utun interface's subnet" half of the believed lockdownd rule
    /// automatically — the same way 10.7.0.1 does on iOS 26.4+. It is kept ONLY as the fallback for a
    /// phone with no routable cellular IPv6 prefix, and only because it is the exact configuration
    /// that has already been on a device: falling back to it changes nothing rather than introducing
    /// a third untested shape. The address the experiment actually aims at now comes from
    /// `CellularIPv6Suggester` — see `plannedIPv6Loopback()`.
    static let defaultTunnelInterfaceIPv6 = "fd00:7761:6e64:7272::1"
    /// FALLBACK address the app DIALS — the analogue of 10.7.0.1. Same caveat as above.
    static let defaultTargetIPv6Address = "fd00:7761:6e64:7272::2"
    /// Prefix length for the fallback pair. A /64 included route is what makes the peer reachable;
    /// the older /128-to-our-own-address route covered nothing. The DERIVED pair uses /126 instead,
    /// because it sits inside a prefix a real interface owns and must not claim the whole of it.
    static let defaultTunnelIPv6PrefixLength = 64

    // MARK: - What the IPv6 experiment is aimed at

    /// The three numbers a tunnel started RIGHT NOW would be configured with.
    ///
    /// One struct rather than three loose calls, because the three must be decided TOGETHER from a
    /// single `getifaddrs` snapshot: an interface address from one snapshot and a peer address from
    /// another could straddle a prefix rotation and produce a pair that is not in the same subnet.
    struct PlannedIPv6Loopback: Sendable, Equatable {
        let interfaceAddress: String
        let targetAddress: String
        let prefixLength: Int
        /// The derived proposal, or nil when this phone had no routable cellular IPv6 prefix and the
        /// fixed ULA above is being used instead.
        let cellular: CellularIPv6TunnelPair?

        var isCellular: Bool { cellular != nil }

        /// Short label for a log line or a settings row.
        var sourceLabel: String {
            guard let cellular else { return "fixed fallback address — no cellular IPv6 prefix found" }
            return "carrier prefix \(cellular.parentCIDR) on \(cellular.parentName)"
        }
    }

    /// Derive the pair now. Costs one `getifaddrs` call.
    ///
    /// Called from exactly two kinds of place: `WanderTunnel.start()`, which then hands the result to
    /// the provider AND records it so the dial path can follow it, and the read-only surfaces (the
    /// settings screen, the interface dump, the endpoint sweep) that show the owner what will be
    /// dialled. Nothing here writes a preference or touches the tunnel.
    static func plannedIPv6Loopback() -> PlannedIPv6Loopback {
        if let pair = CellularIPv6Suggester.suggest() {
            return PlannedIPv6Loopback(interfaceAddress: pair.interfaceAddress,
                                       targetAddress: pair.targetAddress,
                                       prefixLength: pair.prefixLength,
                                       cellular: pair)
        }
        return PlannedIPv6Loopback(interfaceAddress: defaultTunnelInterfaceIPv6,
                                   targetAddress: defaultTargetIPv6Address,
                                   prefixLength: defaultTunnelIPv6PrefixLength,
                                   cellular: nil)
    }

    /// The v6 addresses the RUNNING provider was actually started with.
    ///
    /// Same discipline as `isIPv6LoopbackEnabled` and for the same reason: the provider reads its
    /// options exactly once, in `startTunnel(options:)`, and a carrier prefix can rotate underneath
    /// it. Re-deriving at dial time would eventually dial an address the live tunnel does not have.
    /// Falls back to the fixed ULA so a tunnel started by an older build still dials something.
    static var activeTargetIPv6Address: String {
        WanderTunnel.startedIPv6TargetAddress ?? defaultTargetIPv6Address
    }

    /// The tunnel interface's own v6 address on the running provider. Diagnostics only.
    static var activeTunnelInterfaceIPv6: String {
        WanderTunnel.startedIPv6InterfaceAddress ?? defaultTunnelInterfaceIPv6
    }

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.targetDeviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }

    /// What to ASK OUR OWN provider for when starting it. Own-tunnel-ness is implied here — this is
    /// only ever read from `WanderTunnel.start()`, which is literally starting Wander's tunnel — so it
    /// asks only the two questions that remain: did the user opt in, and can this install run the
    /// extension at all (the free-sideload re-sign strips the entitlement, and LocalDevVPN/StosVPN,
    /// which are IPv4-only byte-identical forks, could never carry a v6 loopback anyway).
    static var isIPv6LoopbackRequestedForOwnTunnel: Bool {
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.useIPv6TunnelLoopback) else { return false }
        return WanderTunnel.isSupported
    }

    /// Whether to ATTEMPT the IPv6 dial before the IPv4 one.
    ///
    /// Deliberately gated on what the RUNNING provider was actually started with, not just on the
    /// preference. The provider reads `TunnelIPv6Loopback` exactly once, in `startTunnel(options:)`,
    /// so a toggle flipped while the tunnel is already up leaves a provider configured for v4 only —
    /// and dialing a v6 literal at it would burn a doomed attempt on every single inject until the
    /// tunnel happened to be restarted. Asking the tunnel what it actually is costs one UserDefaults
    /// read and cannot drift.
    static var isIPv6LoopbackEnabled: Bool {
        guard isIPv6LoopbackRequestedForOwnTunnel else { return false }
        return WanderTunnel.providerStartedWithIPv6Loopback
    }

    /// One dial attempt: an address plus a label for the trace log, so a device test READS which
    /// family carried the session instead of leaving it to be inferred.
    struct DialTarget {
        let address: String
        let familyLabel: String

        /// Bound for the pre-dial TCP reachability probe of THIS candidate.
        ///
        /// IPv4 keeps the shipping 3s exactly. The IPv6 leg is speculative — it exists only to be
        /// tried before falling back — so it gets a tighter bound: `WanderTunnel.ensureStarted()`
        /// probes in a loop against a 12s deadline, and letting a blackholed v6 route eat a full 3s
        /// per pass would roughly halve the number of retries that fit inside it.
        let probeTimeoutSeconds: Double

        /// True for a v6 literal. Colons cannot appear in a dotted-quad, so this is unambiguous.
        var isIPv6: Bool { address.contains(":") }

        init(address: String, familyLabel: String, probeTimeoutSeconds: Double = 3) {
            self.address = address
            self.familyLabel = familyLabel
            self.probeTimeoutSeconds = probeTimeoutSeconds
        }
    }

    /// Bound for the speculative IPv6 probe. See `DialTarget.probeTimeoutSeconds`.
    static let ipv6ProbeTimeoutSeconds: Double = 1.5

    /// The addresses to try, in order. Default (opt-in off) this is EXACTLY one element — the same
    /// IPv4 address every call site used before — so the shipping path is unchanged.
    ///
    /// `ipv4Address` lets a caller keep the address IT was handed as the v4 candidate (the inject path
    /// is given one), so a user who moved the tunnel onto their Wi-Fi subnet on iOS 26.4+ keeps it.
    static func dialTargets(ipv4Address: String? = nil) -> [DialTarget] {
        let v4 = DialTarget(address: ipv4Address ?? targetIPAddress, familyLabel: "IPv4")
        guard isIPv6LoopbackEnabled else { return [v4] }
        // `activeTargetIPv6Address`, NOT a freshly derived one: the address dialled has to be the
        // address the LIVE provider was numbered with. Deriving here would re-read the interfaces on
        // every inject and, after a carrier prefix rotation, dial a peer no route covers.
        return [DialTarget(address: activeTargetIPv6Address,
                           familyLabel: "IPv6",
                           probeTimeoutSeconds: ipv6ProbeTimeoutSeconds), v4]
    }

    /// The same candidates ordered for a REACHABILITY question rather than for a dial: IPv4 FIRST.
    ///
    /// Dial order puts IPv6 first because that is the leg being tested. A reachability probe is the
    /// opposite: it only needs one family to answer, and v4 is the one that answers on every working
    /// setup today — so probing it first keeps the common case a single 3s-bounded probe, byte for
    /// byte what shipped, and only pays for the v6 probe when v4 has already failed.
    static func reachabilityProbeTargets() -> [DialTarget] {
        let all = dialTargets()
        return all.filter { !$0.isIPv6 } + all.filter { $0.isIPv6 }
    }

    // MARK: - Family-agnostic socket address

    /// A parsed endpoint held as a `sockaddr_storage` plus its real length, which is the only shape
    /// that works for both families: the FFI (`tunnel_create_rppairing` et al.) takes a generic
    /// `const idevice_sockaddr *` + `idevice_socklen_t`, and the Rust side reads the family out of the
    /// struct and checks the length against `sockaddr_in` / `sockaddr_in6` accordingly. Passing a v6
    /// address with a v4 length is rejected there, so the length must be exact — not
    /// `MemoryLayout<sockaddr_storage>.size`.
    struct SocketAddress {
        fileprivate(set) var storage = sockaddr_storage()
        fileprivate(set) var length: socklen_t = 0

        var family: Int32 { Int32(storage.ss_family) }
        var isIPv6: Bool { family == AF_INET6 }

        /// Hands the address to a C call as `(const struct sockaddr *, socklen_t)`.
        func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R) rethrows -> R {
            var copy = storage
            return try withUnsafePointer(to: &copy) { pointer in
                try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
            }
        }
    }

    /// Builds a `sockaddr_in6` for an IPv6 literal or a `sockaddr_in` for an IPv4 one. Returns nil if
    /// the string is neither.
    ///
    /// DELIBERATELY `inet_pton`, NOT `getaddrinfo`. Apple documents that getaddrinfo on an IPv4 literal
    /// synthesizes an IPv6 address on a DNS64/NAT64 network, which looks like exactly the fix we want —
    /// it is the opposite. Synthesis rewrites the destination into the CARRIER's NAT64 prefix, so
    /// "10.7.0.1" would become something like 64:ff9b::a07:1 and the tunnel's traffic would be sent to
    /// the carrier's gateway instead of the device's own loopback. For an on-device destination that is
    /// a silent, very confusing regression. Dial a literal.
    ///
    /// SCOPE ID — READ THIS BEFORE HANDING IT ANY v6 LITERAL. `sin6_scope_id` is pinned to 0 here, and
    /// that is only correct because every v6 address this app dials is UNSCOPED: the derived pair is a
    /// GLOBAL unicast address carved out of the carrier's routable /64 (`CellularIPv6Suggester`), and
    /// the fallback is a ULA (fd00::/8). Both are globally scoped, so no interface index is needed.
    ///
    /// A LINK-LOCAL LITERAL WOULD BE SILENTLY CORRUPTED HERE, which is why the design does not use one
    /// even though fe80:: is the obvious choice for a point-to-point link. Two separate reasons:
    ///   • `inet_pton(AF_INET6, "fe80::1%en0", …)` RETURNS 1 on Darwin and writes `fe80:b::1` — it
    ///     embeds the interface index into bytes 2..3, so the address no longer matches an fe80::/64
    ///     prefix compare, and there is no scope left to set (measured; see CellularIPv6Probe M2/M3).
    ///   • Even a correctly scoped one would need `if_nametoindex("utunN")`, and the app has no
    ///     reliable way to learn which utun the network extension was assigned.
    /// Anything link-local belongs in `CellularIPv6Probe`, which splits `%iface` off first and sets the
    /// scope itself. Do not route it through here.
    static func makeSocketAddress(_ address: String, port: UInt16 = developerTunnelPort) -> SocketAddress? {
        var result = SocketAddress()

        var v6 = sockaddr_in6()
        if address.withCString({ inet_pton(AF_INET6, $0, &v6.sin6_addr) }) == 1 {
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.stride)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = in_port_t(port).bigEndian
            v6.sin6_flowinfo = 0
            v6.sin6_scope_id = 0
            withUnsafeMutablePointer(to: &result.storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee = v6 }
            }
            result.length = socklen_t(MemoryLayout<sockaddr_in6>.stride)
            return result
        }

        var v4 = sockaddr_in()
        if address.withCString({ inet_pton(AF_INET, $0, &v4.sin_addr) }) == 1 {
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = in_port_t(port).bigEndian
            withUnsafeMutablePointer(to: &result.storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee = v4 }
            }
            result.length = socklen_t(MemoryLayout<sockaddr_in>.stride)
            return result
        }

        return nil
    }
}
