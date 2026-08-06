//
//  TunnelConfigMatrix.swift
//  Wander
//
//  THE CANDIDATE LIST AND THE ARITHMETIC. No side effects, no networking, no UI — this file only
//  answers "which configurations are worth testing, and given a getifaddrs snapshot plus a probe
//  result, what does this row MEAN?". `TunnelConfigMatrixRunner` does the running.
//
//  WHY THIS EXISTS. The cellular question has been investigated by hand-editing one tunnel config,
//  reconnecting, dialling, and reading a single Bool — several minutes per data point. Most of those
//  data points were then thrown away, for three reasons that have nothing to do with the hypothesis:
//
//    1. STALE CONFIG. The tunnel provider reads its addresses ONLY in `startTunnel(options:)`
//       (TunnelProv/PacketTunnelProvider.swift lines 66-73, fed by WanderTunnel.start() lines
//       578-586). Nothing re-reads them; the only code that ever re-applied settings was the path
//       monitor removed on 2026-08-05. So editing the addresses while the tunnel is up changes
//       NOTHING, and the next probe measures the PREVIOUS config while appearing to measure the new
//       one. Every row here therefore reconnects, and then VERIFIES.
//    2. THE MASK. `WiFiSubnet.suggestTunnelIPs()` returns the FULL Wi-Fi netmask, so "detect" on a
//       192.168.4.46/22 phone proposes 192.168.4.240 with mask 255.255.252.0 — the tunnel claims the
//       IDENTICAL /22 prefix en0 already owns, and the route that decides where the packet goes is a
//       coin flip. A whole evening's Wi-Fi-subnet rows were run that way.
//    3. A CONFIG THAT NEVER INSTALLED. What the app stored and what the utun actually carries are two
//       different facts, and only the second one is being measured. They are compared per row.
//
//  THE ONE INTERFACE ENUMERATOR. Everything here reads `WiFiSubnet.allAddresses()` — the single
//  getifaddrs call that `NetworkInterfaceDump` and `TunnelEndpointSweep` already use. A second
//  enumerator would be a second thing to keep in agreement with the kernel.
//

import Foundation

// MARK: - One configuration to test

/// A candidate tunnel configuration, or a no-tunnel control.
///
/// `deviceIP` is the address the tunnel interface takes (LocalDevVPN calls it "Device IP", our
/// UserDefaults key is `TunnelInterfaceIP`, the provider option is `TunnelDeviceIP`). `targetIP` is
/// the fake peer the app dials (LocalDevVPN's "Tunnel IP", our key `TunnelDeviceIP`, the provider
/// option `TunnelFakeIP`). Those three naming schemes disagree with each other, which is exactly why
/// this struct spells out which is which once and everything downstream reads these two fields.
struct TunnelConfigCandidate: Sendable, Identifiable {

    enum Kind: Sendable {
        /// Bring a tunnel up with these addresses, then dial the target through it.
        case tunnel
        /// Dial the target with NO tunnel configuration change at all.
        case direct
    }

    /// Why this row might not be runnable right now.
    enum Requirement: Sendable {
        case none
        /// Needs `bridge100` (Personal Hotspot) to be up — iOS numbers it 172.20.10.1/28.
        case hotspotBridge
        /// Needs a Wi-Fi subnet to derive the addresses from.
        case wifiSubnet
    }

    let id: String
    let title: String
    let kind: Kind
    /// nil for a `.direct` row — nothing is configured.
    let deviceIP: String?
    let targetIP: String
    let mask: String?
    let requirement: Requirement
    /// One sentence: what a CONNECTED on this row would prove. Printed with the row.
    let rationale: String

    /// TRUE for a row that exists only to prove the measurement rig is working, and whose success
    /// therefore answers NOTHING.
    ///
    /// This matters more than it sounds. 127.0.0.1:49152 connects on this phone in 0 ms with Wi-Fi
    /// off (F1) — that is the whole point of having it — so a bottom line that counted every
    /// CONNECTED row equally would announce "1 configuration CONNECTED" on every single run and read
    /// as a solved problem. A control that can be mistaken for a result is worse than no control.
    var isControl: Bool = false

    /// `10.7.0.0 → 10.7.0.1 /24`, or just the target for a direct row.
    var configDescription: String {
        guard let deviceIP, let mask else { return "\(targetIP) (no tunnel)" }
        let bits = TunnelConfigMatrix.prefixLength(ofMask: mask).map { "/\($0)" } ?? " mask \(mask)"
        return "\(deviceIP) → \(targetIP)\(bits)"
    }
}

// MARK: - What one row measured

/// Whether the configuration this row ASKED for is the configuration the kernel actually has.
///
/// This is the check that would have caught the /22 evening. It is deliberately three-valued rather
/// than a Bool: "the address is there but the mask is wrong" is a completely different problem from
/// "no utun carries this address at all", and they have opposite fixes.
enum TunnelConfigInstallState: Sendable {
    /// A utun carries the requested address AND the requested mask.
    case installed
    /// A utun carries the requested address but with a DIFFERENT mask than requested.
    case maskMismatch(requested: String, actual: String)
    /// No utun carries the requested address at all — the config never reached the interface.
    case addressMissing
    /// A direct row: nothing was configured, so there is nothing to verify.
    case notApplicable

    var label: String {
        switch self {
        case .installed:       return "INSTALLED"
        case .maskMismatch:    return "MASK MISMATCH"
        case .addressMissing:  return "NOT INSTALLED"
        case .notApplicable:   return "n/a"
        }
    }

    /// False when the row's numbers cannot be trusted to describe what was measured.
    var isTrustworthy: Bool {
        switch self {
        case .installed, .notApplicable: return true
        case .maskMismatch, .addressMissing: return false
        }
    }
}

/// Everything one row of the matrix found. Built so the log line can be assembled from it alone.
struct TunnelConfigMatrixRow: Sendable, Identifiable {
    let candidate: TunnelConfigCandidate
    var id: String { candidate.id }

    /// Why the row was not run, when it was not run. nil means it ran.
    var skippedReason: String?

    /// What the interface actually had, read from getifaddrs after the reconnect settled.
    var installState: TunnelConfigInstallState = .notApplicable
    /// e.g. `utun4 127.0.0.4/30`. nil when nothing carried the address.
    var installedOn: String?
    /// True when some utun's subnet covers `targetIP` — i.e. a route to the peer exists at all.
    var targetCoveredByTunnel = false
    /// The believed-lockdownd read on the SOURCE address this row would connect from, computed from
    /// the same public helpers `NetworkInterfaceDump` uses. Wording mirrors that dump on purpose.
    var lockdowndNote: String = ""

    /// The probe that decides the row.
    var target: EndpointProbeResult?
    /// 127.0.0.1 — F1's control. If this ever stops connecting, the daemon died and the whole run is
    /// suspect, so it is re-measured on EVERY row rather than once at the start.
    var loopbackControl: EndpointProbeResult?
    /// The tunnel's own interface address. Measured because F6 found that an address can be assigned
    /// to a utun and still give EADDRNOTAVAIL — "assigned" and "deliverable" are different facts.
    var interfaceControl: EndpointProbeResult?

    var elapsedSeconds: Double = 0

    /// True only for the thing the whole exercise is looking for.
    var targetConnected: Bool { target?.outcome == .connected }

    /// The per-row verdict, in the owner's vocabulary.
    var verdict: String {
        if let skippedReason { return "SKIPPED — \(skippedReason)" }
        guard let target else { return "NOT MEASURED" }
        switch installState {
        case .addressMissing:
            return "INVALID — the config never installed on any utun, so this row measured the PREVIOUS config, not this one. Ignore the errno."
        case .maskMismatch(let requested, let actual):
            return "INVALID — asked for mask \(requested), the interface has \(actual). The prefix being tested is not the prefix that was configured."
        case .installed, .notApplicable:
            break
        }
        switch target.outcome {
        case .connected:
            return "CONNECTED — this configuration reaches remotepairingd. THIS IS THE ANSWER."
        case .refused:
            return "REFUSED (61) — packets reached the daemon and it sent a RST. Routing works; the source-address policy rejected it."
        case .noRoute:
            return "NO ROUTE (\(target.errnoValue)) — the packet never left the phone. Routing, not policy."
        case .noAnswer:
            return targetCoveredByTunnel
                ? "NO ANSWER — a route to the peer exists and the SYN still vanished. Blackhole inside the tunnel, not an address problem."
                : "NO ANSWER — and no utun subnet covers the target, so there was no route into the tunnel to begin with."
        case .addressUnavailable:
            return "ADDRESS UNAVAILABLE (49) — the address is assigned but not deliverable, so nothing could be sourced to it."
        case .invalidAddress, .localFailure, .otherError:
            return "\(target.outcome.label) — \(target.outcome.meaning)"
        }
    }
}

// MARK: - The candidate list and the arithmetic

enum TunnelConfigMatrix {

    /// The shipping default, and the control for the whole matrix: if this row behaves the same as
    /// every other row, the address is not the variable.
    static let shippingDefault = TunnelConfigCandidate(
        id: "default-10.7.0",
        title: "Shipping default (control)",
        kind: .tunnel,
        deviceIP: "10.7.0.0", targetIP: "10.7.0.1", mask: "255.255.255.0",
        requirement: .none,
        rationale: "The configuration every previous test used. Establishes what THIS phone, in THIS network state, does with the known config — every other row is read against it.")

    /// The Personal Hotspot bridge's own address. iOS always numbers `bridge100` 172.20.10.1/28.
    static let hotspotGatewayAddress = "172.20.10.1"

    /// Every candidate, in run order. Rows whose preconditions are missing are still returned — they
    /// are marked SKIPPED with the reason, because "the hotspot was down so four rows silently did
    /// not happen" is precisely the kind of thing that has wasted whole runs.
    ///
    /// Order matters: the direct rows go FIRST (they need no reconnect and cost ~1 s each, so the
    /// most interesting single claim in the whole investigation is answered before a long run can be
    /// interrupted), then the control, then the loopback rows, then hotspot, then Wi-Fi.
    static func candidates(entries: [NetworkInterfaceAddress]) -> [TunnelConfigCandidate] {
        var out: [TunnelConfigCandidate] = []

        // --- Direct, no tunnel ---------------------------------------------------------------
        out.append(TunnelConfigCandidate(
            id: "direct-hotspot-gw",
            title: "DIRECT to the hotspot bridge, no tunnel",
            kind: .direct, deviceIP: nil, targetIP: hotspotGatewayAddress, mask: nil,
            requirement: .hotspotBridge,
            rationale: "midodotcom0/StikDebug PR #1/#3 claims this reaches remotepairingd with Personal Hotspot on, cellular only, and NO tunnel. F1 (the daemon accepts on cellular) makes it plausible. The single most interesting untested claim."))

        out.append(TunnelConfigCandidate(
            id: "direct-loopback",
            title: "DIRECT to 127.0.0.1, no tunnel (CONTROL)",
            kind: .direct, deviceIP: nil, targetIP: "127.0.0.1", mask: nil,
            requirement: .none,
            rationale: "F1's control, re-taken now. Proves remotepairingd is alive and accepting in the current network state — without it, a run of NO ANSWERs could just mean the daemon is dead. It is EXPECTED to connect, so its connecting is not a finding.",
            isControl: true))

        // --- Tunnel rows ---------------------------------------------------------------------
        out.append(shippingDefault)

        out.append(TunnelConfigCandidate(
            id: "loopback-30-4",
            title: "Loopback /30",
            kind: .tunnel, deviceIP: "127.0.0.4", targetIP: "127.0.0.5", mask: "255.255.255.252",
            requirement: .none,
            rationale: "lo0 carries 127.0.0.0/8 and is NOT named utun*, so any 127.x source passes the believed lockdownd subnet test — and unlike Wi-Fi or the hotspot, lo0 exists with Wi-Fi off, no hotspot, and no carrier. If a 127.x tunnel address is deliverable, the cellular problem is solved outright."))

        out.append(TunnelConfigCandidate(
            id: "loopback-30-2",
            title: "Loopback /30, different offset",
            kind: .tunnel, deviceIP: "127.0.0.2", targetIP: "127.0.0.3", mask: "255.255.255.252",
            requirement: .none,
            rationale: "Same theory, different offset — isolates 'this particular pair collides with something' from 'the whole 127.x idea fails'."))

        out.append(TunnelConfigCandidate(
            id: "hotspot-30-4",
            title: "Hotspot /30",
            kind: .tunnel, deviceIP: "172.20.10.4", targetIP: "172.20.10.5", mask: "255.255.255.252",
            requirement: .hotspotBridge,
            rationale: "bridge100 owns 172.20.10.0/28, is not a utun, is BROADCAST rather than point-to-point, and survives with Wi-Fi off — the only non-loopback interface on a cellular-only phone that has a real multi-host subnet."))

        out.append(TunnelConfigCandidate(
            id: "hotspot-30-8",
            title: "Hotspot /30, different offset",
            kind: .tunnel, deviceIP: "172.20.10.8", targetIP: "172.20.10.9", mask: "255.255.255.252",
            requirement: .hotspotBridge,
            rationale: "Second offset inside bridge100's /28, for the same reason as the second loopback row."))

        if let wifi = wifiSlashThirty(entries: entries) {
            out.append(TunnelConfigCandidate(
                id: "wifi-30",
                title: "Wi-Fi subnet, CORRECT /30",
                kind: .tunnel, deviceIP: wifi.device, targetIP: wifi.target, mask: wifi.mask,
                requirement: .none,
                rationale: "The known-good Wi-Fi trick, but with a /30 instead of the full Wi-Fi netmask that Detect produces. A /30 is more specific than en0's prefix, so it WINS the route lookup instead of tying with it. Not a cellular answer — it needs Wi-Fi — but it is the reference for 'a tunnel address that is definitely routable'."))
        } else {
            out.append(TunnelConfigCandidate(
                id: "wifi-30",
                title: "Wi-Fi subnet, CORRECT /30",
                kind: .tunnel, deviceIP: nil, targetIP: "-", mask: nil,
                requirement: .wifiSubnet,
                rationale: "Needs en0 to have an address; on a cellular-only run this row is expected to skip."))
        }

        return out
    }

    /// The Wi-Fi row's addresses, computed HERE rather than through `WiFiSubnet.suggestTunnelIPs()`.
    ///
    /// That helper hands back the phone's FULL netmask, which on a /22 Wi-Fi (measured: 192.168.4.46
    /// mask 255.255.252.0) makes the tunnel claim the identical /22 that en0 already owns. Two
    /// interfaces claiming the same prefix is not a configuration, it is a race. A /30 is strictly
    /// more specific, so the longest-prefix-match rule sends the target into the tunnel.
    ///
    /// The pair is aligned to a /30 boundary so `device` is the network address and `target` the
    /// first host — the same shape as the shipping 10.7.0.0/10.7.0.1 default.
    static func wifiSlashThirty(entries: [NetworkInterfaceAddress]) -> (device: String, target: String, mask: String)? {
        guard let en0 = entries.first(where: { $0.name == "en0" && $0.isIPv4 && $0.isUp && !$0.isLoopback }),
              en0.addressBytes.count == 4,
              let maskBytes = en0.maskBytes, maskBytes.count == 4 else { return nil }

        // Base the pair on the Wi-Fi NETWORK, then place it high in the range (.240) where a home DHCP
        // pool usually is not — the same instinct as the existing suggestion, but with a /30 mask.
        let network = (0..<4).map { en0.addressBytes[$0] & maskBytes[$0] }
        // Only meaningful when the last octet is host space; a /30-inside-a-/30 is not a test.
        guard WiFiSubnet.leadingOnes(maskBytes) <= 29 else { return nil }
        let device: [UInt8] = [network[0], network[1], network[2], 240]
        let target: [UInt8] = [network[0], network[1], network[2], 241]
        // 240 & 252 == 240, so .240 IS the /30 network address and .241 its first host. Asserted by
        // construction rather than assumed — see `slashThirtyAlignment`.
        return (device.map { String($0) }.joined(separator: "."),
                target.map { String($0) }.joined(separator: "."),
                "255.255.255.252")
    }

    // MARK: - Arithmetic the report needs

    /// `255.255.255.252` → 30. nil when the string is not a valid contiguous IPv4 mask.
    static func prefixLength(ofMask mask: String) -> Int? {
        guard let (family, bytes) = WiFiSubnet.parseAddress(mask), family == AF_INET else { return nil }
        guard WiFiSubnet.popCount(bytes) == WiFiSubnet.leadingOnes(bytes) else { return nil }
        return WiFiSubnet.leadingOnes(bytes)
    }

    /// Where `deviceIP`/`targetIP` sit inside the subnet the mask defines.
    ///
    /// WHY IT IS PRINTED. One of the listed candidates is 127.0.0.2/127.0.0.3 with a /30 — and
    /// 2 & 252 == 0, so that pair's network is 127.0.0.0/30, which makes 127.0.0.3 the BROADCAST
    /// address of its own subnet, not a host. That is a completely different thing to dial than
    /// 127.0.0.5 (a genuine host inside 127.0.0.4/30). If those two rows disagree, alignment is the
    /// first explanation to rule out, and nobody should have to do this masking by hand at 2am.
    static func slashThirtyAlignment(deviceIP: String, targetIP: String, mask: String) -> String? {
        guard let prefix = prefixLength(ofMask: mask), prefix == 30,
              let (df, device) = WiFiSubnet.parseAddress(deviceIP), df == AF_INET,
              let (tf, target) = WiFiSubnet.parseAddress(targetIP), tf == AF_INET,
              let (mf, maskBytes) = WiFiSubnet.parseAddress(mask), mf == AF_INET else { return nil }

        let network = (0..<4).map { device[$0] & maskBytes[$0] }
        let broadcast = (0..<4).map { network[$0] | ~maskBytes[$0] }
        func text(_ b: [UInt8]) -> String { b.map { String($0) }.joined(separator: ".") }

        var notes: [String] = []
        if network != Array(device) {
            notes.append("device \(deviceIP) is NOT the network address of \(text(network))/30")
        }
        if Array(target) == broadcast {
            notes.append("target \(targetIP) is the BROADCAST address of \(text(network))/30, not a host — read this row against the aligned one before blaming the offset")
        }
        if !zip(target, maskBytes).map({ $0 & $1 }).elementsEqual(network) {
            notes.append("target \(targetIP) is OUTSIDE \(text(network))/30 — the tunnel's own subnet does not cover the address being dialled")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    /// Is the configuration this row asked for the configuration the kernel actually has?
    ///
    /// Looks at utun interfaces only: a tunnel address that turned up on en0 would be somebody else's.
    static func installState(deviceIP: String,
                             mask: String,
                             entries: [NetworkInterfaceAddress]) -> (TunnelConfigInstallState, String?) {
        guard let (family, wanted) = WiFiSubnet.parseAddress(deviceIP), family == AF_INET else {
            return (.addressMissing, nil)
        }
        let carrier = entries.first { entry in
            entry.isUtun && entry.isIPv4 && entry.addressBytes == Array(wanted)
        }
        guard let carrier else { return (.addressMissing, nil) }

        let where_ = "\(carrier.name) \(carrier.cidr ?? carrier.address)"
        let actualMask = carrier.netmask ?? "<none>"
        if actualMask == mask { return (.installed, where_) }
        return (.maskMismatch(requested: mask, actual: actualMask), where_)
    }

    /// True when SOME utun's subnet covers the target — i.e. a route into the tunnel exists for it.
    static func targetCoveredByTunnel(_ targetIP: String, entries: [NetworkInterfaceAddress]) -> Bool {
        guard let (family, bytes) = WiFiSubnet.parseAddress(targetIP) else { return false }
        return entries.contains { $0.isUtun && $0.containsAddress(family: family, bytes: Array(bytes)) }
    }

    /// The believed-lockdownd read on this row's SOURCE address (the tunnel's own device IP, which is
    /// what the connection would be sourced from). Deliberately worded the same as
    /// `NetworkInterfaceDump`'s SUMMARY lines, and deliberately hedged the same way — the rule comes
    /// from one published decompilation, and this is evidence, not a ruling.
    static func lockdowndNote(sourceIP: String, entries: [NetworkInterfaceAddress]) -> String {
        guard let (family, raw) = WiFiSubnet.parseAddress(sourceIP) else { return "source \(sourceIP): not a valid IP" }
        let bytes = Array(raw)
        let containing = entries.filter { $0.containsAddress(family: family, bytes: bytes) }
        let nonUtun = containing.filter { !$0.isUtun }
        let ownedBy = entries.filter { $0.isExactly(family: family, bytes: bytes) && !$0.isUtun }

        if let owner = ownedBy.first {
            return "source \(sourceIP) IS this device's own \(owner.name) address → FAILS the believed lockdownd own-address check"
        }
        if let first = nonUtun.first {
            return "source \(sourceIP) is inside \(nonUtun.map(\.name).joined(separator: "/")) (\(first.cidr ?? "?")) → PASSES the believed lockdownd subnet test"
        }
        if containing.isEmpty {
            return "source \(sourceIP) is inside NO interface subnet → FAILS the believed lockdownd subnet test"
        }
        return "source \(sourceIP) is covered only by utun* subnets, which the check excludes → FAILS"
    }
}
