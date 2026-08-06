//
//  SocketInterfaceBinding.swift
//  Wander
//
//  WHICH INTERFACE DID THE PACKET ACTUALLY LEAVE ON — measured, not assumed.
//
//  WHY THIS EXISTS. Every tunnel diagnosis in this project so far has inferred the egress interface
//  from the OUTCOME: "the connect failed, so the packet must have gone the wrong way." That inference
//  is unsound in both directions, and it is the reason the cellular question keeps reopening. The
//  kernel already knows the answer and will hand it over for free:
//
//    • `getsockname()` on a socket that has begun connecting returns the LOCAL address the kernel
//      chose. On Darwin the source address is selected and latched inside `in_pcbconnect()`, before
//      the first SYN is emitted, so it is readable the moment `connect()` returns — including while
//      it is still EINPROGRESS. Match that address back to `getifaddrs` and you have the egress
//      interface, by measurement.
//    • `IP_BOUND_IF` / `IPV6_BOUND_IF` FORCE the choice. Setting them makes the route lookup scoped
//      to one interface (XNU sets `INP_BOUND_IF` on the PCB and passes `inp_boundifp->if_index` as
//      the `IFSCOPE` for `rtalloc_scoped*`), which decides both the outgoing interface and the source
//      address. So "probe unbound, then probe bound to the tunnel, and compare" separates a ROUTE
//      SELECTION failure from every other kind.
//
//  Apple's own guidance, verbatim: "With BSD Sockets, the best way to bind a socket to an interface
//  is with the IP_BOUND_IF (IPv4) or IPV6_BOUND_IF (IPv6) socket options."
//  — Quinn, DTS, Apple Developer Forums 734359 ("Network Interface Techniques").
//
//  ⚠️ THE ONE PLACE IT IS KNOWN NOT TO WORK is inside a NEPacketTunnelProvider: "This technique won't
//  work because NECP works hard to prevent VPN loops." — Quinn, forums 714370, answering someone who
//  said explicitly "Within the PacketTunnel itself". That is a different process and a different NECP
//  policy context from the one this file runs in. Nothing in that thread says an ordinary app cannot
//  scope its own socket to a utun, and an ordinary app scoping traffic INTO a VPN is not a loop. This
//  file is therefore app-side ONLY. Do not lift it into TunnelProv/.
//
//  SCOPE OF THIS FILE. It measures. It does not change the inject path: `tunnel_create_rppairing`
//  creates and connects its own socket internally (its FFI signature takes only `const sockaddr *` +
//  socklen — there is no fd, no options struct, and no `_from_fd` variant), so nothing here can bind
//  THAT socket. See `WanderConnectScope.swift` for the only in-process mechanism that could, and the
//  honest accounting of what it costs.
//
//  Interface NAMES are never string-matched here. "BSD interface names are not considered API.
//  There's no guarantee, for example, that an iPhone's Wi-Fi interface is en0." — Quinn, forums
//  734338. The tunnel is identified by the ADDRESS it was configured with (UserDefaults
//  `TunnelInterfaceIP`), which we own, and the name/index are read back from `getifaddrs` +
//  `if_nametoindex`. That works for LocalDevVPN's utun exactly as well as for Wander's own.
//

import Foundation
import Darwin

// MARK: - Naming an interface without guessing at its name

/// One interface, reduced to the three things a bind or a verdict needs.
struct ScopedInterface: Sendable, Equatable {
    /// `if_nametoindex`. Valid indexes are greater than 0 (Apple, forums 734338).
    let index: UInt32
    /// Kernel name — carried for the LOG only. Never compared against a literal.
    let name: String
    /// e.g. `192.168.4.0/22`. nil when the address had no netmask.
    let cidr: String?

    var label: String { cidr.map { "\(name) (\($0)) idx \(index)" } ?? "\(name) idx \(index)" }
}

enum InterfaceScope {

    /// The interface that HOLDS `address` — an exact address match, not a name match.
    ///
    /// This is how the tunnel's utun is identified: the app configured the tunnel's own interface
    /// address, so the interface carrying that address is the tunnel, whoever created it. Works
    /// identically for LocalDevVPN, StosVPN and Wander's own provider, which is what makes the
    /// address hypotheses testable through a tunnel that already works.
    static func owner(of address: String) -> ScopedInterface? {
        guard let (family, bytes) = WiFiSubnet.parseAddress(address) else { return nil }
        for entry in WiFiSubnet.allAddresses() where entry.isExactly(family: family, bytes: bytes) {
            guard let index = index(forName: entry.name) else { continue }
            return ScopedInterface(index: index, name: entry.name, cidr: entry.cidr)
        }
        return nil
    }

    /// Every interface whose SUBNET covers `address`, in kernel order. More than one is itself a
    /// finding: two interfaces claiming the same prefix is exactly the condition under which the
    /// route table can hand a packet to the wrong one (see the /22 tunnel-mask bug).
    static func covering(_ address: String) -> [ScopedInterface] {
        guard let (family, bytes) = WiFiSubnet.parseAddress(address) else { return [] }
        var out: [ScopedInterface] = []
        for entry in WiFiSubnet.allAddresses()
        where entry.containsAddress(family: family, bytes: bytes) {
            guard let index = index(forName: entry.name) else { continue }
            let candidate = ScopedInterface(index: index, name: entry.name, cidr: entry.cidr)
            if !out.contains(candidate) { out.append(candidate) }
        }
        return out
    }

    /// The first interface holding `address`, described for a log line — used to say which interface
    /// a chosen SOURCE address belongs to.
    static func describeOwner(ofAddress address: String) -> String? {
        owner(of: address)?.label
    }

    static func index(forName name: String) -> UInt32? {
        let index = name.withCString { if_nametoindex($0) }
        return index == 0 ? nil : index
    }

    static func name(forIndex index: UInt32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        guard if_indextoname(index, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// The tunnel's own interface, found by the address the app configured it with.
    ///
    /// Reads the key directly (`TunnelInterfaceIP`), the same way `NetworkInterfaceDump` and
    /// `TunnelEndpointSweep` do, so the interface named in this log is the one matching the number
    /// on disk and cannot drift from it.
    static func configuredTunnelInterface() -> ScopedInterface? {
        let configured = UserDefaults.standard.string(forKey: UserDefaults.Keys.tunnelInterfaceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let address = (configured?.isEmpty == false) ? configured! : "10.7.0.0"
        return owner(of: address)
    }
}

// MARK: - What to scope a probe to

/// How a probe socket should be scoped before it connects.
enum ScopedBind: Sendable, Equatable {
    /// Leave it to the routing table — what every probe in this app does today.
    case unbound
    /// `IP_BOUND_IF` / `IPV6_BOUND_IF` to this interface.
    case boundTo(ScopedInterface)

    var describedTarget: String {
        switch self {
        case .unbound:            return "unbound (routing table decides)"
        case .boundTo(let iface): return "bound to \(iface.label)"
        }
    }
}

// MARK: - One measurement

struct ScopedProbeResult: Sendable {
    let address: String
    let port: UInt16
    let bind: ScopedBind
    /// Which option was used — `IP_BOUND_IF` or `IPV6_BOUND_IF` — or nil when unbound.
    let bindOption: String?
    /// False when the `setsockopt` itself was refused. A refused bind makes the rest of the line a
    /// measurement of the UNBOUND path, so it must never be reported as a bound result.
    let bindApplied: Bool
    let bindErrno: Int32
    let outcome: EndpointProbeOutcome
    let errnoValue: Int32
    let syscall: String
    /// `getsockname()` — the source address the kernel actually chose. THE point of this file.
    let localAddress: String?
    /// Which interface holds `localAddress`, i.e. the egress interface, by measurement.
    let localAddressOwner: String?
    let elapsedMilliseconds: Int

    var isReachable: Bool { outcome == .connected }

    var destination: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    var logLine: String {
        var s = "probe \(destination) \(bind.describedTarget)"
        if let bindOption {
            s += bindApplied
                ? " · \(bindOption) OK"
                : " · \(bindOption) REFUSED errno \(bindErrno) \(EndpointProbe.errnoName(bindErrno)) — THIS LINE MEASURES THE UNBOUND PATH"
        }
        s += " → \(outcome.label)"
        s += " errno \(errnoValue) \(EndpointProbe.errnoName(errnoValue))"
        if errnoValue != 0, let text = strerror(errnoValue) {
            s += " (\(String(cString: text)))"
        }
        if let localAddress {
            s += " · source \(localAddress)"
            s += " via \(localAddressOwner ?? "NO INTERFACE HOLDS THIS ADDRESS")"
        } else {
            s += " · source <getsockname failed — no local address was ever assigned>"
        }
        s += " after \(elapsedMilliseconds) ms via \(syscall)"
        return s
    }
}

enum ScopedEndpointProbe {

    /// Bounded, non-blocking TCP connect with an OPTIONAL interface scope, reporting the source
    /// address the kernel picked. Never throws, never traps, never blocks past `timeoutSeconds`.
    ///
    /// Deliberately a sibling of `EndpointProbe.probe` rather than an extra parameter on it:
    /// `EndpointProbe.probe` gates the real dial path on every inject, and this is a diagnostic. The
    /// two shared pieces — the errno classifier and the errno name table — are reused from there, so
    /// the two probes can never disagree about what a number means.
    ///
    /// ERRNO IS CAPTURED IN THE STATEMENT IMMEDIATELY AFTER EACH SYSCALL, for the reason spelled out
    /// at the top of EndpointProbe.swift: it is a thread-local that any later libc call overwrites.
    static func probe(_ address: String,
                      port: UInt16 = DeviceConnectionContext.developerTunnelPort,
                      timeoutSeconds: Double = 1.5,
                      bind: ScopedBind = .unbound) -> ScopedProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }

        var bindOption: String?
        var bindApplied = false
        var bindErrno: Int32 = 0
        var localAddress: String?

        func result(_ outcome: EndpointProbeOutcome, _ code: Int32, _ syscall: String) -> ScopedProbeResult {
            ScopedProbeResult(address: address, port: port, bind: bind,
                              bindOption: bindOption, bindApplied: bindApplied, bindErrno: bindErrno,
                              outcome: outcome, errnoValue: code, syscall: syscall,
                              localAddress: localAddress,
                              localAddressOwner: localAddress.flatMap(InterfaceScope.describeOwner(ofAddress:)),
                              elapsedMilliseconds: elapsed())
        }

        guard let endpoint = DeviceConnectionContext.makeSocketAddress(address, port: port) else {
            return result(.invalidAddress, 0, "inet_pton")
        }

        let fd = socket(endpoint.family, SOCK_STREAM, 0)
        let socketErrno = errno
        guard fd >= 0 else { return result(.localFailure, socketErrno, "socket") }
        defer { close(fd) }

        // ── THE SCOPE ────────────────────────────────────────────────────────────────────────────
        // IP_BOUND_IF is netinet/in.h line 432 in the iPhoneOS 26.5 SDK (`#define IP_BOUND_IF 25`);
        // IPV6_BOUND_IF is netinet6/in6.h line 506 (`125`). Neither sits behind
        // __APPLE_API_PRIVATE — they are ordinary public SDK constants, which is why this needs no
        // entitlement and is not a private API.
        //
        // The option is an `int` holding the INTERFACE INDEX, not a name and not an address.
        if case .boundTo(let iface) = bind {
            var index = Int32(bitPattern: iface.index)
            let level = endpoint.isIPv6 ? IPPROTO_IPV6 : IPPROTO_IP
            let option = endpoint.isIPv6 ? IPV6_BOUND_IF : IP_BOUND_IF
            bindOption = endpoint.isIPv6 ? "IPV6_BOUND_IF" : "IP_BOUND_IF"
            let rc = setsockopt(fd, level, option, &index, socklen_t(MemoryLayout<Int32>.size))
            bindErrno = errno
            bindApplied = (rc == 0)
            if !bindApplied {
                // Reported, NOT fatal. A refused scope still produces a useful unbound measurement,
                // and `logLine` says loudly that it is one. Silently returning here would leave the
                // sweep with a hole exactly where the interesting comparison is.
                bindErrno = bindErrno == 0 ? EINVAL : bindErrno
            }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var connectErrno: Int32 = 0
        let rc = endpoint.withSockaddr { pointer, length -> Int32 in
            let returned = connect(fd, pointer, length)
            connectErrno = errno
            return returned
        }

        // READ THE SOURCE NOW, whether the connect succeeded, failed, or is still in flight. Darwin
        // latches the local address in in_pcbconnect() before the SYN goes out, so this is valid
        // under EINPROGRESS — and EINPROGRESS is the case we most want it for, because a blackholed
        // SYN tells us nothing else about where it went.
        localAddress = Self.localAddress(of: fd)

        if rc == 0 { return result(.connected, 0, "connect") }
        if connectErrno != EINPROGRESS {
            return result(EndpointProbe.classify(connectErrno), connectErrno, "connect")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waitMilliseconds = Int32(max(timeoutSeconds, 0.1) * 1000)
        let pollRC = poll(&pfd, 1, waitMilliseconds)
        let pollErrno = errno
        if pollRC == 0 {
            localAddress = Self.localAddress(of: fd) ?? localAddress
            return result(.noAnswer, 0, "poll (bounded wait expired)")
        }
        if pollRC < 0 { return result(.localFailure, pollErrno, "poll") }

        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let getRC = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        let getErrno = errno
        localAddress = Self.localAddress(of: fd) ?? localAddress
        guard getRC == 0 else { return result(.localFailure, getErrno, "getsockopt(SO_ERROR)") }
        if soError == 0 { return result(.connected, 0, "connect (async)") }
        return result(EndpointProbe.classify(soError), soError, "connect (async, read from SO_ERROR)")
    }

    /// `getsockname()` as a presentation string, or nil if the socket has no local address yet.
    /// Returns nil rather than "0.0.0.0" for an unassigned address, because "the kernel has not
    /// chosen yet" and "the kernel chose the wildcard" are different facts.
    static func localAddress(of fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { return nil }

        let family = Int32(storage.ss_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }

        var bytes = [UInt8](repeating: 0, count: family == AF_INET ? 4 : 16)
        let offset = family == AF_INET ? 4 : 8   // sin_addr / sin6_addr offsets on Darwin
        withUnsafeBytes(of: &storage) { raw in
            for i in 0..<bytes.count where offset + i < raw.count { bytes[i] = raw[offset + i] }
        }
        if bytes.allSatisfy({ $0 == 0 }) { return nil }

        let text = WiFiSubnet.presentation(family: family, bytes: bytes)
        return text.isEmpty ? nil : text
    }

    /// Runtime feature test for `SO_BINDTODEVICE` (sys/socket.h line 190 in the iPhoneOS 26.5 SDK,
    /// `0x1134`, "bind socket to a network device (max valid option length IFNAMSIZ)").
    ///
    /// WHY A RUNTIME TEST AND NOT A CALL SITE. Every public write-up still says this option does not
    /// exist on Darwin — it is a Linux-ism that has only recently appeared in Apple's headers. A
    /// constant in a header is not proof of a kernel implementation, and the difference shows up as
    /// `ENOPROTOOPT (42)`. So we ask the kernel and print the answer instead of asserting either way.
    /// `IP_BOUND_IF` remains the option this file actually binds with; this exists to be reported.
    static func soBindToDeviceProbe(interfaceName: String) -> (accepted: Bool, errnoValue: Int32) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, errno) }
        defer { close(fd) }

        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        _ = interfaceName.withCString { source in
            strncpy(&name, source, Int(IFNAMSIZ) - 1)
        }
        let rc = setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, &name, socklen_t(IFNAMSIZ))
        let code = errno
        return (rc == 0, rc == 0 ? 0 : code)
    }
}

// MARK: - The experiment

/// ONE TAP: does forcing the dial onto the tunnel interface change anything, and where was the
/// packet going before?
///
/// The comparison is the whole point, and it is a comparison no run of `TunnelEndpointSweep` can
/// make, because that sweep varies the DESTINATION while leaving the egress to the routing table.
/// This varies the EGRESS while holding the destination fixed at the one address that decides
/// whether spoofing works.
///
/// Read the output as a truth table on the tunnel target:
///
///   unbound        bound-to-tunnel     what it means
///   ────────────────────────────────────────────────────────────────────────────────────────────
///   fail           CONNECTED           ROUTE SELECTION. The packet was leaving on the wrong
///                                      interface. Fix it in the routing config (enforceRoutes, a
///                                      more specific tunnel mask) — not in the tunnel's data path.
///   fail           fail, same errno    NOT route selection. The packet was already going into the
///                                      tunnel and something past the route lookup ate it.
///   CONNECTED      CONNECTED           the tunnel is healthy; whatever is failing is above TCP.
///   CONNECTED      fail                the scope is landing on the WRONG interface — re-read which
///                                      interface `TunnelInterfaceIP` resolved to.
///
/// BLOCKING. Run it off the main thread and off `LocationSimulationCommandQueue`, which Stop and
/// Panic have to ride. Bounded at 1.5 s per probe, ≤ 6 probes.
enum SocketScopeSweep {

    static let probeTimeoutSeconds: Double = 1.5

    /// Probe everything, write the report to the Console, return a short summary for an alert.
    static func runAndSummarize(reason: String = "manual") -> String {
        var lines: [String] = []
        var results: [(label: String, result: ScopedProbeResult)] = []

        let target = DeviceConnectionContext.targetIPAddress
        let tunnel = InterfaceScope.configuredTunnelInterface()
        let loopback = InterfaceScope.owner(of: "127.0.0.1")

        lines.append("=== SOCKET SCOPE PROBE === port \(DeviceConnectionContext.developerTunnelPort) · reason: \(reason)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · target \(target) · \(Int(probeTimeoutSeconds * 1000)) ms bound each")

        let configuredInterfaceIP = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
        if let tunnel {
            lines.append("TUNNEL INTERFACE: \(configuredInterfaceIP) is held by \(tunnel.label)")
        } else {
            lines.append("TUNNEL INTERFACE: NO interface holds \(configuredInterfaceIP) — the tunnel is not up, or it was started with different addresses. Every bound probe below is skipped.")
        }

        // Which interfaces claim a subnet covering the destination. Two answers here is the /22
        // collision: the tunnel and Wi-Fi both claiming the prefix, with the route table free to
        // prefer either.
        let covering = InterfaceScope.covering(target)
        lines.append("SUBNETS COVERING \(target): " +
                     (covering.isEmpty ? "NONE — no interface's subnet contains it"
                                       : covering.map(\.label).joined(separator: ", ")))

        func run(_ label: String, _ address: String, _ bind: ScopedBind) {
            let result = ScopedEndpointProbe.probe(address, timeoutSeconds: probeTimeoutSeconds, bind: bind)
            results.append((label, result))
            lines.append("  [\(results.count)] \(label) — \(result.logLine)")
        }

        // 1 + 2. The comparison this file exists for.
        run("tunnel TARGET, unbound", target, .unbound)
        if let tunnel {
            run("tunnel TARGET, scoped to the tunnel", target, .boundTo(tunnel))
        }

        // 3. The control. F1 measured 127.0.0.1:49152 CONNECTED in 0 ms on cellular with Wi-Fi off,
        // so a failure HERE means the probe itself is broken, not the tunnel.
        run("loopback control 127.0.0.1, unbound", "127.0.0.1", .unbound)
        if let loopback {
            run("loopback control 127.0.0.1, scoped to lo0", "127.0.0.1", .boundTo(loopback))
        }

        // 4. Same pair on the IPv6 loopback when the experiment is on, so a v6 session gets the same
        // evidence rather than being diagnosed by analogy with v4.
        if DeviceConnectionContext.isIPv6LoopbackEnabled {
            // The address the LIVE provider was numbered with, not the fixed fallback: since the pair
            // is carved out of the carrier's prefix at start (CellularIPv6Suggester), the constant is
            // only what a phone with no cellular prefix would have got.
            let v6 = DeviceConnectionContext.activeTargetIPv6Address
            run("IPv6 tunnel TARGET, unbound", v6, .unbound)
            if let tunnel {
                run("IPv6 tunnel TARGET, scoped to the tunnel", v6, .boundTo(tunnel))
            }
        }

        // 5. Ask the kernel whether the new SO_BINDTODEVICE is real on this OS. One socket, no
        // connect, no wait.
        if let tunnel {
            let answer = ScopedEndpointProbe.soBindToDeviceProbe(interfaceName: tunnel.name)
            lines.append("SO_BINDTODEVICE(\(tunnel.name)) → " + (answer.accepted
                ? "ACCEPTED — the option is implemented on this OS, not just declared in the SDK header."
                : "REFUSED errno \(answer.errnoValue) \(EndpointProbe.errnoName(answer.errnoValue)) — declared in the SDK header but not usable here. Use IP_BOUND_IF."))
        }

        lines.append(contentsOf: verdictLines(results, tunnel: tunnel))
        lines.append("=== END SOCKET SCOPE PROBE ===")

        for line in lines { LogManager.shared.addInfoLog(line) }
        // Same retention store as the interface dump and the endpoint sweep: opening the Console
        // REPLACES the log buffer with what it parses off disk, which would otherwise wipe this the
        // moment someone navigated over to read it.
        NetworkInterfaceDump.retain(lines)

        return shortSummary(results)
    }

    // MARK: - The verdict

    static func verdictLines(_ results: [(label: String, result: ScopedProbeResult)],
                             tunnel: ScopedInterface?) -> [String] {
        guard !results.isEmpty else { return ["VERDICT: nothing was probed."] }

        var out: [String] = []

        let unbound = results.first { $0.label == "tunnel TARGET, unbound" }?.result
        let bound = results.first { $0.label == "tunnel TARGET, scoped to the tunnel" }?.result

        // The source address is the finding even when both probes agree, so it is stated first and
        // on its own line.
        if let unbound {
            if let source = unbound.localAddress {
                out.append("VERDICT unbound source: the kernel sourced from \(source) via \(unbound.localAddressOwner ?? "NO INTERFACE HOLDS IT") — that is the interface the SYN left on.")
            } else {
                out.append("VERDICT unbound source: the kernel assigned NO local address, so the packet never reached an interface at all.")
            }
        }

        switch (unbound?.outcome, bound?.outcome) {
        case (.some(let u), .some(.connected)) where u != .connected:
            out.append("VERDICT bottom line: ROUTE SELECTION. Scoping the socket to \(tunnel?.label ?? "the tunnel") made it CONNECT while the unbound socket did not. The packets were leaving on the wrong interface; fix the routing (enforceRoutes, or a tunnel mask specific enough to win the prefix), not the tunnel's data path.")
        case (.some(.connected), .some(let b)) where b != .connected:
            out.append("VERDICT bottom line: THE SCOPE IS WRONG, not the tunnel. The unbound socket connected and the scoped one did not, so \(tunnel?.label ?? "the interface we bound to") is not the interface that carries this destination. Re-read which interface TunnelInterfaceIP resolved to above.")
        case (.some(let u), .some(let b)) where u == b:
            if u == .connected {
                out.append("VERDICT bottom line: the tunnel is HEALTHY at TCP either way. Whatever is failing is above the transport — pairing, RSD, or the source-address rule inside remotepairingd — not the route.")
            } else {
                out.append("VERDICT bottom line: NOT route selection. Forcing the socket onto \(tunnel?.label ?? "the tunnel") produced the identical \(u.label). The packet was already going into the tunnel and something past the route lookup is eating it.")
            }
        case (.some, .none):
            out.append("VERDICT bottom line: no scoped probe ran, because no interface holds the configured tunnel address. Start the tunnel and run this again — an unbound-only result cannot separate routing from anything else.")
        default:
            out.append("VERDICT bottom line: read the per-line source addresses above; the two target probes did not both complete.")
        }

        // A source address that no interface holds would be a genuinely new fact, so it gets said
        // out loud rather than being left in a per-line detail.
        let orphaned = results.filter { $0.result.localAddress != nil && $0.result.localAddressOwner == nil }
        if !orphaned.isEmpty {
            out.append("VERDICT ⚠️ these probes were sourced from an address NO interface holds: " +
                       orphaned.map { "\($0.label) → \($0.result.localAddress ?? "?")" }.joined(separator: ", "))
        }

        let refusedBinds = results.filter { $0.result.bindOption != nil && !$0.result.bindApplied }
        if !refusedBinds.isEmpty {
            out.append("VERDICT ⚠️ the scope was REFUSED on: " +
                       refusedBinds.map { "\($0.label) (errno \($0.result.bindErrno) \(EndpointProbe.errnoName($0.result.bindErrno)))" }.joined(separator: ", ") +
                       " — those lines measure the unbound path and prove nothing about binding.")
        }

        return out
    }

    private static func shortSummary(_ results: [(label: String, result: ScopedProbeResult)]) -> String {
        guard !results.isEmpty else {
            return "Nothing could be probed — no tunnel address could be read."
        }
        let target = results[0].result
        var text = "\(results.count) probed.\n"
        text += "Unbound \(target.destination) → \(target.outcome.label), sourced from \(target.localAddress ?? "no local address") via \(target.localAddressOwner ?? "no interface").\n"
        if let bound = results.first(where: { $0.label == "tunnel TARGET, scoped to the tunnel" })?.result {
            text += "Scoped to the tunnel → \(bound.outcome.label).\n"
        }
        text += "\nFull detail and the verdict are in the log below — use Export Logs to send it."
        return text
    }
}
