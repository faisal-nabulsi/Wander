//
//  WiFiSubnet.swift
//  Wander
//
//  Reads the phone's own Wi-Fi (en0) IPv4 address + netmask and suggests two tunnel IPs on that
//  subnet. WHY: iOS 26.4 changed lockdownd to DROP the developer tunnel's default loopback address
//  (10.7.0.0 / 10.7.0.1), so on 26.4+ the tunnel won't connect until its IPs are moved onto the
//  phone's real Wi-Fi subnet (the SideStore/StikDebug fix). This turns "read your router config and
//  pick a free IP" into one tap. Best-effort: it assumes a typical home /24 and picks high host
//  addresses (.240/.241) that are usually outside the DHCP pool — the user can edit if either collides.
//
//  ALSO IN THIS FILE: the general interface enumerator that read is built on (`allAddresses()`), plus
//  `NetworkInterfaceDump` — a diagnostic that writes EVERY interface and address into the app Console.
//
//  WHY THE DIAGNOSTIC EXISTS: the cellular-spoof investigation has been GUESSING which interfaces the
//  phone has when Wi-Fi is off in Settings. Nobody — here or anywhere public — has actually looked.
//  The believed iOS 26.4 lockdownd rule is that the connection's source address must fall inside the
//  subnet of some interface that is NOT named `utun*` (one `strncmp(ifa_name, "utun", 4)`), while the
//  older check separately rejects a source address the device itself holds. If that is the whole rule,
//  the cellular answer is any non-utun interface that exists without Wi-Fi — pdp_ip0, lo0, or the
//  Personal Hotspot bridge. Every one of those questions is answered by one getifaddrs dump taken in
//  the failing state, which is what this produces. Read the dump; stop guessing.
//
//  Cost: one getifaddrs call, on demand or on a tunnel failure (throttled). No polling, no timers.
//

import Foundation

// MARK: - One address on one interface

/// A single address reported by `getifaddrs`, decoded into something readable.
///
/// This is the raw material for BOTH the Wi-Fi subnet suggestion below and the interface dump — there
/// is exactly one enumerator in this app (`WiFiSubnet.allAddresses()`) and both go through it.
struct NetworkInterfaceAddress: Sendable {
    /// Kernel interface name: en0, pdp_ip0, utun3, bridge100, awdl0, llw0, ap1, lo0, …
    let name: String
    /// `AF_INET` or `AF_INET6`.
    let family: Int32
    /// Raw `ifa_flags` (IFF_UP, IFF_RUNNING, IFF_LOOPBACK, IFF_POINTOPOINT, IFF_BROADCAST, …).
    let flags: UInt32
    /// IPv6 scope id — nonzero for link-local (`fe80::…%en0`). 0 for IPv4.
    let scopeID: UInt32
    /// The address itself: 4 bytes (IPv4) or 16 (IPv6), network order.
    let addressBytes: [UInt8]
    /// `ifa_netmask`, same width as the address. nil when the interface has no mask.
    let maskBytes: [UInt8]?
    /// `ifa_dstaddr` — the PEER address on a point-to-point link, the BROADCAST address otherwise.
    let peerBytes: [UInt8]?

    var isIPv4: Bool { family == AF_INET }
    var isIPv6: Bool { family == AF_INET6 }
    var familyName: String { isIPv4 ? "AF_INET" : (isIPv6 ? "AF_INET6" : "AF_\(family)") }

    var isUp: Bool { flags & UInt32(IFF_UP) != 0 }
    var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }
    var isPointToPoint: Bool { flags & UInt32(IFF_POINTOPOINT) != 0 }
    var isBroadcast: Bool { flags & UInt32(IFF_BROADCAST) != 0 }

    /// True for the interface names the developer tunnel gets. A NEPacketTunnelProvider is always
    /// `utunN` and can't rename itself, which is exactly why the believed lockdownd rule excludes it.
    var isUtun: Bool { name.hasPrefix("utun") }

    /// Tunnel-ish by name (not just ours): utun/ipsec/ppp/tap/gif/stf. Used only for the "physical-ish"
    /// summary line — the lockdownd test itself is believed to look at `utun` and nothing else.
    var isVirtualByName: Bool {
        ["utun", "ipsec", "ppp", "tap", "gif", "stf"].contains { name.hasPrefix($0) }
    }

    /// Presentation form. IPv6 link-local carries its scope (`fe80::1%en0`); without it the address is
    /// ambiguous, and the scope is what any connect() would have to be bound to.
    var address: String {
        let s = WiFiSubnet.presentation(family: family, bytes: addressBytes)
        if isIPv6, scopeID != 0, !s.isEmpty { return "\(s)%\(name)" }
        return s
    }

    var netmask: String? {
        guard let m = maskBytes else { return nil }
        let s = WiFiSubnet.presentation(family: family, bytes: m)
        return s.isEmpty ? nil : s
    }

    /// Number of leading 1-bits in the netmask — the `/n` of the CIDR. nil when there is no mask.
    var prefixLength: Int? { maskBytes.map { WiFiSubnet.leadingOnes($0) } }

    /// False when the mask is not a run of ones followed by zeros. Worth printing, because a `/n`
    /// would then be a lie about what the kernel actually compares.
    var maskIsContiguous: Bool {
        guard let m = maskBytes else { return true }
        return WiFiSubnet.popCount(m) == WiFiSubnet.leadingOnes(m)
    }

    /// The derived subnet, e.g. `192.168.1.0/24` or `127.0.0.0/8`. nil without a mask.
    var cidr: String? {
        guard let m = maskBytes, let p = prefixLength, m.count == addressBytes.count else { return nil }
        let net = zip(addressBytes, m).map { $0 & $1 }
        let s = WiFiSubnet.presentation(family: family, bytes: net)
        return s.isEmpty ? nil : "\(s)/\(p)"
    }

    /// `peer x` on a point-to-point link (pdp_ip0 is one), `bcast x` on a broadcast link. nil otherwise:
    /// on an interface that is neither, `ifa_dstaddr` carries nothing meaningful (lo0 reports its own
    /// address there) and printing it would invent a fact.
    var peerDescription: String? {
        guard let p = peerBytes, isPointToPoint || isBroadcast else { return nil }
        let s = WiFiSubnet.presentation(family: family, bytes: p)
        guard !s.isEmpty else { return nil }
        return isPointToPoint ? "peer \(s)" : "bcast \(s)"
    }

    var flagsDescription: String {
        var names: [String] = []
        func test(_ f: Int32, _ label: String) { if flags & UInt32(f) != 0 { names.append(label) } }
        test(IFF_UP, "UP")
        test(IFF_RUNNING, "RUNNING")
        test(IFF_LOOPBACK, "LOOPBACK")
        test(IFF_POINTOPOINT, "POINTOPOINT")
        test(IFF_BROADCAST, "BROADCAST")
        test(IFF_MULTICAST, "MULTICAST")
        return names.isEmpty ? "-" : names.joined(separator: ",")
    }

    /// True when `bytes` (same family) falls inside this address's subnet — i.e. the masked compare
    /// `((A ^ B) & mask) == 0` that the lockdownd check is believed to run.
    func containsAddress(family f: Int32, bytes: [UInt8]) -> Bool {
        guard f == family,
              let m = maskBytes,
              m.count == bytes.count,
              addressBytes.count == bytes.count else { return false }
        for i in 0..<bytes.count {
            if (addressBytes[i] ^ bytes[i]) & m[i] != 0 { return false }
        }
        return true
    }

    /// True when this entry IS the given address — the older lockdownd check rejects a source address
    /// that appears in the device's own address table (which is why plain 127.0.0.1 never worked).
    func isExactly(family f: Int32, bytes: [UInt8]) -> Bool {
        f == family && addressBytes == bytes
    }
}

enum WiFiSubnet {

    // MARK: - The one enumerator

    /// Every IPv4/IPv6 address on every interface, in kernel order. One `getifaddrs` call.
    static func allAddresses() -> [NetworkInterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var out: [NetworkInterfaceAddress] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let nameRaw = ptr.pointee.ifa_name, let sa = ptr.pointee.ifa_addr else { continue }
            let fam = Int32(sa.pointee.sa_family)
            guard fam == AF_INET || fam == AF_INET6 else { continue }
            guard let addr = rawAddressBytes(from: sa, family: fam) else { continue }

            // Decode the MASK using the ADDRESS's family on purpose: Darwin often reports
            // sa_family == 0 on an ifa_netmask, so trusting the mask's own family drops real masks.
            let mask = ptr.pointee.ifa_netmask.flatMap { rawAddressBytes(from: $0, family: fam) }

            // The PEER is the opposite: ifa_dstaddr is a union that frequently holds a LINK-LEVEL
            // (sockaddr_dl) address, not an IP one. Force-decoding it as IP prints the interface name's
            // bytes as an address — verified: lo0's came out as "3704:0:6769:6630::", which is ASCII.
            // A fake peer on pdp_ip0 would be worse than none, so require a matching family here.
            let peer = ptr.pointee.ifa_dstaddr.flatMap { dst -> [UInt8]? in
                guard Int32(dst.pointee.sa_family) == fam else { return nil }
                return rawAddressBytes(from: dst, family: fam)
            }

            out.append(NetworkInterfaceAddress(
                name: String(cString: nameRaw),
                family: fam,
                flags: ptr.pointee.ifa_flags,
                scopeID: fam == AF_INET6 ? scopeID(of: sa) : 0,
                addressBytes: addr,
                maskBytes: mask,
                peerBytes: peer
            ))
        }
        return out
    }

    /// The device's IPv4 address + netmask on the Wi-Fi interface (en0), if connected to Wi-Fi.
    static func currentIPv4() -> (ip: String, netmask: String)? {
        for e in allAddresses() where e.name == "en0" && e.isIPv4 && e.isUp && !e.isLoopback {
            let ip = e.address
            guard !ip.isEmpty else { continue }
            return (ip, e.netmask ?? "255.255.255.0")
        }
        return nil
    }

    /// Suggest a (deviceIP, fakeIP, mask) triple on the current Wi-Fi subnet, or nil if not on Wi-Fi.
    /// Picks two high host addresses (.240 / .241 within the masked network) that are usually free in a
    /// home DHCP range. Tuned for the common case where the final octet is the host part (a /24 home LAN).
    static func suggestTunnelIPs() -> (device: String, fake: String, mask: String)? {
        guard let (ip, mask) = currentIPv4() else { return nil }
        let ipP = ip.split(separator: ".").compactMap { UInt8($0) }
        let mP = mask.split(separator: ".").compactMap { UInt8($0) }
        guard ipP.count == 4, mP.count == 4, mP[3] != 255 else { return nil }
        let net = (0..<4).map { ipP[$0] & mP[$0] }
        let base = "\(net[0]).\(net[1]).\(net[2])"
        return ("\(base).240", "\(base).241", mask)
    }

    /// Validate a dotted-quad IPv4 string.
    static func isValidIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    // MARK: - Byte helpers (shared by the enumerator and the dump)

    /// Parse an IPv4 or IPv6 literal into (family, network-order bytes). A `%scope` suffix is ignored.
    static func parseAddress(_ ip: String) -> (family: Int32, bytes: [UInt8])? {
        let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip

        var v4 = in_addr()
        if bare.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            var bytes = [UInt8](repeating: 0, count: 4)
            withUnsafeBytes(of: &v4.s_addr) { raw in
                for i in 0..<4 { bytes[i] = raw[i] }
            }
            return (AF_INET, bytes)
        }

        var v6 = in6_addr()
        if bare.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            var bytes = [UInt8](repeating: 0, count: 16)
            withUnsafeBytes(of: &v6) { raw in
                for i in 0..<16 { bytes[i] = raw[i] }
            }
            return (AF_INET6, bytes)
        }
        return nil
    }

    /// Bytes → presentation string. Empty on failure (never traps).
    static func presentation(family: Int32, bytes: [UInt8]) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return inet_ntop(family, base, &buf, socklen_t(buf.count)) != nil
        }
        return ok ? String(cString: buf) : ""
    }

    /// Leading 1-bits across the byte array — the `/n` of a netmask.
    static func leadingOnes(_ bytes: [UInt8]) -> Int {
        var n = 0
        for b in bytes {
            if b == 0xFF { n += 8 } else { n += (~b).leadingZeroBitCount; break }
        }
        return n
    }

    /// Total 1-bits. Equal to `leadingOnes` only when the mask is contiguous.
    static func popCount(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Copy the address bytes out of a `sockaddr`, clamped by its own `sa_len` so a truncated netmask
    /// (which the kernel does hand back) can never over-read. Missing trailing bytes read as 0, which
    /// is what a truncated mask means anyway.
    private static func rawAddressBytes(from sa: UnsafeMutablePointer<sockaddr>, family: Int32) -> [UInt8]? {
        let size = family == AF_INET ? 4 : 16
        let offset = family == AF_INET ? 4 : 8   // sin_addr / sin6_addr offsets on Darwin
        var declared = Int(sa.pointee.sa_len)
        if declared <= 0 {
            declared = family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
        }
        var bytes = [UInt8](repeating: 0, count: size)
        let available = declared - offset
        guard available > 0 else { return bytes }
        let raw = UnsafeRawPointer(sa)
        for i in 0..<min(size, available) {
            bytes[i] = raw.load(fromByteOffset: offset + i, as: UInt8.self)
        }
        return bytes
    }

    private static func scopeID(of sa: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        guard Int(sa.pointee.sa_len) >= MemoryLayout<sockaddr_in6>.size else { return 0 }
        return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_scope_id }
    }
}

// MARK: - The diagnostic

/// Writes the full interface picture into the app Console (LogManager), so it exports with the
/// existing Export Logs button. On demand from the Console menu, and once — throttled — whenever a
/// tunnel connection fails, so a failure report always carries the interface state that caused it.
enum NetworkInterfaceDump {

    /// Minimum spacing between AUTOMATIC dumps. Failure paths retry in tight loops (the health monitor
    /// polls every few seconds), and a dump per retry would bury the very log it is meant to explain.
    private static let failureThrottle: TimeInterval = 90

    private static let lock = NSLock()
    private static var lastAutoDump: Date?

    /// The most recent dumps, kept in memory as well as in the log.
    ///
    /// WHY: opening the Console runs `loadIdeviceLogsAsync`, which REPLACES the whole buffer with what
    /// it parses out of `idevice_log.txt`. An automatic dump written while the Console was closed —
    /// i.e. every dump that matters, since failures happen while you're on the Map — would be wiped the
    /// instant you opened the Console to read it. The Console re-appends these after a reload.
    private static var retainedDumps: [[String]] = []
    /// Enough to hold a failure and the manual dump you take afterwards, without unbounded growth.
    private static let maxRetainedDumps = 3

    /// Build the report without writing it (also what the tests would read).
    static func report(reason: String) -> [String] {
        let entries = WiFiSubnet.allAddresses()
        var out: [String] = []

        out.append("=== NETWORK INTERFACES === reason: \(reason)")
        out.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(entries.count) address(es)")

        if entries.isEmpty {
            out.append("  (getifaddrs returned nothing — no interface has an IP at all)")
        }
        for e in entries {
            var line = "  \(e.name) \(e.familyName) \(e.address.isEmpty ? "<unreadable>" : e.address)"
            if let m = e.netmask {
                line += " mask \(m)"
                if let c = e.cidr { line += " subnet \(c)" }
                if !e.maskIsContiguous { line += " NON-CONTIGUOUS-MASK" }
            } else {
                line += " mask <none>"
            }
            if let peer = e.peerDescription { line += " \(peer)" }
            if e.isIPv6, e.scopeID != 0 { line += " scopeid \(e.scopeID)" }
            line += " [\(e.flagsDescription)]"
            out.append(line)
        }

        out.append(contentsOf: summaryLines(entries))
        out.append("=== END NETWORK INTERFACES ===")
        return out
    }

    /// The lines that answer the actual question, so a reader never has to do the masking by hand.
    private static func summaryLines(_ entries: [NetworkInterfaceAddress]) -> [String] {
        var out: [String] = []

        func list(_ xs: [NetworkInterfaceAddress]) -> String {
            xs.isEmpty ? "NONE" : xs.map { "\($0.name) \($0.cidr ?? $0.address)" }.joined(separator: ", ")
        }

        let withSubnet = entries.filter { $0.cidr != nil }
        let physicalish = withSubnet.filter { !$0.isLoopback && !$0.isVirtualByName }
        out.append("SUMMARY physical-ish interfaces with a netmask: " + list(physicalish))

        // The believed iOS 26.4 lockdownd rule does exactly ONE name test — strncmp(name, "utun", 4).
        // So this, not the Wi-Fi subnet, is the set of subnets a tunnel address may legally sit in.
        let eligible4 = withSubnet.filter { !$0.isUtun && $0.isIPv4 }
        let eligible6 = withSubnet.filter { !$0.isUtun && $0.isIPv6 }
        out.append("SUMMARY non-utun IPv4 subnets (lockdownd-eligible): " + list(eligible4))
        out.append("SUMMARY non-utun IPv6 subnets (lockdownd-eligible): " + list(eligible6))

        for (label, ip) in tunnelCandidates() {
            out.append(verdict(label: label, ip: ip, entries: entries))
        }
        return out
    }

    /// The addresses the tunnel is actually configured with, read from the same UserDefaults keys the
    /// inject path reads (deliberately by key, not through the connection context — the numbers in the
    /// log must be the numbers on disk).
    private static func tunnelCandidates() -> [(String, String)] {
        let d = UserDefaults.standard
        var out: [(String, String)] = [
            ("tunnel interface IP", d.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"),
            ("tunnel target IP (what Wander dials)", d.string(forKey: UserDefaults.Keys.targetDeviceIP) ?? "10.7.0.1")
        ]
        // The v6 pair is no longer a constant — it is carved out of the carrier's prefix at tunnel
        // start (see CellularIPv6Suggester), so the dump has to ask rather than print two literals.
        // Two entries, deliberately: what a tunnel started NOW would use, and what the RUNNING one
        // actually has. They differ after a carrier prefix rotation, and that difference is exactly
        // the thing a reader needs to see. `verdict()` below then runs the believed lockdownd test on
        // each, so the derived address gets the same PASSES/FAILS line as the IPv4 ones.
        if d.bool(forKey: UserDefaults.Keys.useIPv6TunnelLoopback) {
            let planned = DeviceConnectionContext.plannedIPv6Loopback()
            out.append(("tunnel interface IPv6 (\(planned.sourceLabel))", planned.interfaceAddress))
            out.append(("tunnel target IPv6 — what Wander would dial after a restart", planned.targetAddress))
            if let live = WanderTunnel.startedIPv6TargetAddress, live != planned.targetAddress {
                out.append(("tunnel target IPv6 — what the RUNNING tunnel actually has", live))
            }
        }
        return out
    }

    /// Does this address satisfy the two composed lockdownd checks?
    ///   • 26.4-era: it must fall inside the subnet of an interface NOT named `utun*`.
    ///   • 2022-era: it must NOT be an address the device itself holds.
    /// The verdict is about the BELIEVED rule (one published decompilation), so it is worded as such —
    /// the dump's job is to hand over the evidence, not to be the last word.
    private static func verdict(label: String, ip: String, entries: [NetworkInterfaceAddress]) -> String {
        guard let (fam, bytes) = WiFiSubnet.parseAddress(ip) else {
            return "SUMMARY \(label) \(ip): not a valid IP address"
        }
        let containing = entries.filter { $0.containsAddress(family: fam, bytes: bytes) }
        let nonUtun = containing.filter { !$0.isUtun }
        let ownedBy = entries.filter { $0.isExactly(family: fam, bytes: bytes) }

        var s = "SUMMARY \(label) \(ip): "
        s += containing.isEmpty
            ? "inside NO interface subnet"
            : "inside " + containing.map { "\($0.name) \($0.cidr ?? "?")" }.joined(separator: ", ")

        if let owner = ownedBy.first {
            s += " — and it IS this device's own \(owner.name) address"
            s += " → FAILS the believed lockdownd test (own-address reset)"
        } else if let firstNonUtun = nonUtun.first {
            let via = nonUtun.map(\.name).joined(separator: "/")
            s += " → PASSES the believed lockdownd test via \(via) (\(firstNonUtun.cidr ?? "?"))"
        } else if containing.isEmpty {
            s += " → FAILS (no interface subnet covers it)"
        } else {
            s += " → FAILS (only utun* subnets cover it, which the check excludes)"
        }
        return s
    }

    // MARK: - Writing it out

    /// Write the dump now, unconditionally. Returns the number of lines written.
    @discardableResult
    static func logNow(reason: String) -> Int {
        let lines = report(reason: reason)
        for line in lines { LogManager.shared.addInfoLog(line) }
        retain(lines)
        return lines.count
    }

    /// Keep a block of diagnostic lines alive across a Console reload.
    ///
    /// Shared with `TunnelEndpointSweep` deliberately: it has exactly the same problem this store was
    /// built for (its lines are written into the log buffer, and `loadIdeviceLogsAsync` REPLACES that
    /// buffer with what it parses off disk the next time the App tab appears), and one replay
    /// mechanism the Console already calls beats a second one it would have to learn about.
    /// Thread-safe.
    static func retain(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock()
        retainedDumps.append(lines)
        if retainedDumps.count > maxRetainedDumps { retainedDumps.removeFirst(retainedDumps.count - maxRetainedDumps) }
        lock.unlock()
    }

    /// Every retained dump, flattened, for the Console to re-append after it reloads its buffer.
    /// Marked as a replay so nobody mistakes it for a dump taken just now.
    static func retainedLines() -> [String] {
        lock.lock()
        let dumps = retainedDumps
        lock.unlock()
        guard !dumps.isEmpty else { return [] }
        var out = ["=== REPLAYED DIAGNOSTIC DUMPS (\(dumps.count)) — captured earlier this session ==="]
        for d in dumps { out.append(contentsOf: d) }
        return out
    }

    /// Write the dump because something failed — at most once per `failureThrottle`, so a retry loop
    /// can't flood the console. Safe to call from any thread.
    static func logOnFailure(reason: String) {
        let now = Date()
        lock.lock()
        if let last = lastAutoDump, now.timeIntervalSince(last) < failureThrottle {
            lock.unlock()
            return
        }
        lastAutoDump = now
        lock.unlock()
        logNow(reason: "tunnel failure — \(reason)")
    }
}
