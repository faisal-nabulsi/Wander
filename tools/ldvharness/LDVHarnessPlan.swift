//
//  LDVHarnessPlan.swift
//  tools/ldvharness
//
//  OFFLINE PLANNER FOR THE LOCALDEVVPN ADDRESS HARNESS. No device, no Xcode target. Runs on the Mac:
//
//      swiftc -O /Users/faisalnabulsi/Developer/wander-ios/tools/ldvharness/LDVHarnessPlan.swift \
//             -o /tmp/ldvplan && /tmp/ldvplan
//
//  WHAT IT IS FOR. LocalDevVPN's tunnel WORKS on this phone (measured) and its address fields are
//  editable, so every address hypothesis can be tested through it TODAY. But a candidate address is
//  only worth an on-device run if it can actually SURVIVE THE ROUTING TABLE, and that is pure
//  arithmetic — longest-prefix match against the interface inventory that was already measured on
//  cellular. This file does that arithmetic for every candidate so the ordered test list is computed
//  rather than asserted, and so a config that cannot possibly work is never spent on a device run.
//
//  THE THREE FACTS IT ENCODES (each cited where it is used):
//
//  1. WHAT REMOTEPAIRINGD SEES AS THE SOURCE IS THE *PEER* ADDRESS. Derived from the shipped rewrite:
//     the app dials P, the kernel sources from the utun's own address D, and the provider does
//         if src == D && dst == P { src = P; dst = D }      // both ends, or nothing (2026-08-06)
//     so the packet re-injected into the utun is src=P dst=D. This dial matches both ends, so the
//     fact is unchanged by that guard. D is a local address, so it is
//     delivered locally and the daemon's accept() reports the peer as P. The address the lockdownd
//     source-check judges is therefore the FAKE/PEER IP, not the interface IP.
//
//  2. THE PEER MUST WIN LONGEST-PREFIX MATCH AGAINST EVERY NON-UTUN CONNECTED ROUTE, or the dial
//     never enters the tunnel at all and the test measures nothing.
//
//  3. LOCALDEVVPN'S SHIPPED PROVIDER IGNORES THE SUBNET-MASK FIELD. Verified against
//     github.com/StephenDev0/LocalDevVPN main (TunnelProv/PacketTunnelProvider.swift, last touched
//     2025-10-02): startTunnel reads only "TunnelDeviceIP" and "TunnelFakeIP"; `tunnelSubnetMask`
//     stays at its hardcoded "255.255.255.0" even though the app passes "TunnelSubnetMask" in the
//     options dictionary. So both worlds are computed below — mask HONORED and mask IGNORED — because
//     which one is real on the App Store build is the first thing the owner must measure.
//
//  IT PROVES NOTHING ABOUT POLICY. Whether lockdownd accepts a source that satisfies the rule is a
//  device question; this only says which candidates are even reachable.
//

import Foundation

// MARK: - Address arithmetic

func v4(_ s: String) -> UInt32 {
    let c = s.split(separator: ".")
    guard c.count == 4 else { return 0 }
    var out: UInt32 = 0
    for part in c { out = (out << 8) | (UInt32(part) ?? 0) }
    return out
}
func dotted(_ v: UInt32) -> String { "\(v >> 24 & 255).\(v >> 16 & 255).\(v >> 8 & 255).\(v & 255)" }
func maskFor(prefix p: Int) -> UInt32 { p == 0 ? 0 : (~UInt32(0) << (32 - p)) }
func prefixOf(mask m: UInt32) -> Int { m.nonzeroBitCount }

/// One connected route the kernel holds, i.e. one interface address plus its netmask.
struct Iface {
    let name: String
    let addr: String
    let prefix: Int
    var isUtun: Bool { name.hasPrefix("utun") }
    var network: UInt32 { v4(addr) & maskFor(prefix: prefix) }
    var cidr: String { "\(dotted(network))/\(prefix)" }
    func covers(_ ip: UInt32) -> Bool { (ip & maskFor(prefix: prefix)) == network }
}

/// The inventory measured on device (iPhone 15 Pro Max, iOS 26.5.2, AT&T) with Wi-Fi OFF in Settings.
/// The two pdp addresses are placeholders in the right shape — carrier CGNAT /32s; only the PREFIX
/// matters to every computation here, never the digits.
let cellularBase: [Iface] = [
    Iface(name: "lo0",     addr: "127.0.0.1",   prefix: 8),
    Iface(name: "pdp_ip0", addr: "10.130.44.17", prefix: 32),
    Iface(name: "pdp_ip2", addr: "10.130.55.9",  prefix: 32),
]
let hotspotBridge = Iface(name: "bridge100", addr: "172.20.10.1", prefix: 28)
let wifiEn0 = Iface(name: "en0", addr: "192.168.4.46", prefix: 22)

// MARK: - A candidate config

enum Radio: String { case cellularOnly = "cellular only, Wi-Fi OFF"
                     case cellularHotspot = "cellular + Personal Hotspot ON"
                     case wifi = "Wi-Fi ON (reference)" }

struct Candidate {
    let id: String
    let purpose: String
    /// Goes in LocalDevVPN's row labelled "Tunnel IP" (key TunnelDeviceIP) = the address ON the utun.
    let interfaceIP: String
    /// Goes in LocalDevVPN's row labelled "Device IP" (key TunnelFakeIP) = the peer Wander dials.
    let peerIP: String
    /// What the owner types into the Subnet Mask row. May be ignored by the provider — see fact 3.
    let requestedPrefix: Int
    let radio: Radio
    /// True for the candidates run with NO tunnel at all (LocalDevVPN disconnected), where "does the
    /// dial enter a utun" is not the question and must not be reported as a failure.
    var noTunnel: Bool = false
}

let candidates: [Candidate] = [
    Candidate(id: "A-CONTROL", purpose: "Does the working Wi-Fi config work at all on cellular?",
              interfaceIP: "10.7.0.0", peerIP: "10.7.0.1", requestedPrefix: 24, radio: .cellularOnly),
    Candidate(id: "B-LOOPBACK", purpose: "Peer inside lo0's /8 — the only non-utun subnet broader than /24 on cellular",
              interfaceIP: "127.0.1.0", peerIP: "127.0.1.2", requestedPrefix: 24, radio: .cellularOnly),
    Candidate(id: "B2-LOOPBACK-LOW", purpose: "Same idea in 127.0.0.x, adjacent to the address lo0 actually holds",
              interfaceIP: "127.0.0.0", peerIP: "127.0.0.2", requestedPrefix: 24, radio: .cellularOnly),
    Candidate(id: "C-HOTSPOT-30", purpose: "Peer inside bridge100's /28; needs a /30 to beat it on prefix length",
              interfaceIP: "172.20.10.4", peerIP: "172.20.10.5", requestedPrefix: 30, radio: .cellularHotspot),
    Candidate(id: "C2-HOTSPOT-24", purpose: "The same peer if the mask field turns out to be ignored",
              interfaceIP: "172.20.10.0", peerIP: "172.20.10.5", requestedPrefix: 24, radio: .cellularHotspot),
    Candidate(id: "D-WIFI-ON-CELL", purpose: "Negative control: the config that works on Wi-Fi, run with Wi-Fi off",
              interfaceIP: "192.168.4.240", peerIP: "192.168.4.241", requestedPrefix: 24, radio: .cellularOnly),
    Candidate(id: "E-PDP-NEIGHBOUR", purpose: "Peer next door to pdp_ip0 — only works if the /32 is not really a /32",
              interfaceIP: "10.130.44.0", peerIP: "10.130.44.200", requestedPrefix: 24, radio: .cellularOnly),
    Candidate(id: "F-WIFI-REF", purpose: "Reference: the same knobs on Wi-Fi, where this is known to work",
              interfaceIP: "192.168.4.240", peerIP: "192.168.4.241", requestedPrefix: 24, radio: .wifi),
    Candidate(id: "G-HOTSPOT-GW-DIRECT", purpose: "The StikDebug PR #1/#3 claim: dial bridge100's own address with NO tunnel",
              interfaceIP: "(none)", peerIP: "172.20.10.1", requestedPrefix: 24, radio: .cellularHotspot, noTunnel: true),
    Candidate(id: "H-PDP-OWN-DIRECT", purpose: "Dial pdp_ip0's own address with NO tunnel — the cellular twin of the 127.0.0.1 probe",
              interfaceIP: "(none)", peerIP: "10.130.44.17", requestedPrefix: 32, radio: .cellularOnly, noTunnel: true),
]

// MARK: - Evaluation

func inventory(for radio: Radio) -> [Iface] {
    switch radio {
    case .cellularOnly:    return cellularBase
    case .cellularHotspot: return cellularBase + [hotspotBridge]
    case .wifi:            return cellularBase + [wifiEn0]
    }
}

struct Verdict {
    let installedPrefix: Int
    let routeDestinationHasHostBits: Bool
    let lpmWinner: String
    let entersTunnel: Bool
    let peerInsideNonUtunSubnet: String?
    let peerIsDeviceHeld: String?
    let martian: Bool
    var reachable: Bool { entersTunnel && !martian }
    var satisfiesSourceRule: Bool { peerInsideNonUtunSubnet != nil && peerIsDeviceHeld == nil }
}

func evaluate(_ c: Candidate, maskHonored: Bool) -> Verdict {
    let installedPrefix = maskHonored ? c.requestedPrefix : 24
    let utun = Iface(name: "utun9", addr: c.interfaceIP, prefix: installedPrefix)
    let physical = inventory(for: c.radio)
    let peer = v4(c.peerIP)

    // Fact 3's consequence, computed rather than assumed: the provider passes the HOST address as the
    // route destination (NEIPv4Route(destinationAddress: tunnelDeviceIp, subnetMask: ...)). BSD's radix
    // tree masks a net route's key on insert, so this is almost certainly normalised by the kernel —
    // but it is reported because it is the one difference between the default config and every config
    // that has been observed to blackhole, and it costs nothing to keep an eye on.
    let hostBits = v4(c.interfaceIP) != utun.network

    // Longest-prefix match over every connected route, the utun included.
    var winner = "(no route — packet does not leave the stack)"
    var winnerPrefix = -1
    var winnerIsUtun = false
    for i in physical + [utun] where i.covers(peer) {
        if i.prefix > winnerPrefix {
            winnerPrefix = i.prefix; winner = "\(i.name) \(i.cidr)"; winnerIsUtun = i.isUtun
        }
    }

    // The lockdownd source rule (F7), applied to the peer address — see fact 1.
    let coveringNonUtun = physical.first { !$0.isUtun && $0.covers(peer) }
    let holder = physical.first { v4($0.addr) == peer }

    // XNU, bsd/netinet/ip_input.c (apple-oss-distributions/xnu, main), lines 1104-1129, verbatim
    // comment "/* 127/8 must not appear on wire - RFC1122 */": if EITHER ip_src or ip_dst is in
    // 127/8, the packet is dropped (ips_badaddr, DROP_REASON_IP_INVALID_ADDR) unless the receiving
    // interface has IFF_LOOPBACK or the mbuf carries PKTF_LOOP. A NEPacketTunnelProvider's utun has
    // neither: it is not lo0, and PKTF_LOOP is set by the loopback OUTPUT path, not by
    // packetFlow.writePackets. So a re-injected 127/8 packet dies in ip_input with no RST and no ICMP
    // — which is exactly the "no answer, bounded wait expired" signature already measured for the
    // 127.0.0.5/30 config. This is a primary-source fact, not an inference.
    // A no-tunnel dial is exempt: it never leaves the loopback path, which is why probing 127.0.0.1
    // directly CONNECTS.
    let martian = !c.noTunnel && ((peer >> 24) == 127 || (v4(c.interfaceIP) >> 24) == 127)

    return Verdict(installedPrefix: installedPrefix,
                   routeDestinationHasHostBits: hostBits,
                   lpmWinner: winner,
                   entersTunnel: winnerIsUtun,
                   peerInsideNonUtunSubnet: coveringNonUtun.map { "\($0.name) \($0.cidr)" },
                   peerIsDeviceHeld: holder?.name,
                   martian: martian)
}

// MARK: - Report

func line(_ s: String = "") { print(s) }
func rule(_ ch: String = "─") { print(String(repeating: ch, count: 92)) }

rule("═")
line(" LOCALDEVVPN ADDRESS HARNESS — computed reachability for every candidate config")
rule("═")
line("""
 Reading the columns:
   ENTERS TUNNEL   the peer address wins longest-prefix match against a utun route. If NO, the dial
                   goes out a physical interface and the run measures nothing about the tunnel.
   MARTIAN         127/8 arriving on a non-lo0 interface; XNU drops it in ip_input regardless of routes.
   SOURCE RULE     the peer sits inside a NON-utun subnet and is not an address the device holds — the
                   published lockdownd test. Only meaningful once ENTERS TUNNEL is yes.
""")

for c in candidates {
    rule()
    line(" \(c.id)   [\(c.radio.rawValue)]")
    line("   \(c.purpose)")
    line("   LocalDevVPN  'Tunnel IP' row = \(c.interfaceIP)   'Device IP' row = \(c.peerIP)   'Subnet Mask' row = \(dotted(maskFor(prefix: c.requestedPrefix)))")
    line("   Wander       'Device IP'   = \(c.interfaceIP)   'Tunnel IP'   = \(c.peerIP)   mask = \(dotted(maskFor(prefix: c.requestedPrefix)))")
    for honored in [true, false] {
        let v = evaluate(c, maskHonored: honored)
        let world = honored ? "mask HONORED " : "mask IGNORED "
        line("     \(world) → utun installs \(c.interfaceIP)/\(v.installedPrefix)")
        line("        route winner for \(c.peerIP): \(v.lpmWinner)   ENTERS TUNNEL: \(v.entersTunnel ? "yes" : "NO")")
        line("        martian(127/8 off-lo0): \(v.martian ? "YES — dropped in ip_input" : "no")   route dest host bits: \(v.routeDestinationHasHostBits ? "set" : "clean")")
        let inside = v.peerInsideNonUtunSubnet ?? "NONE"
        let held = v.peerIsDeviceHeld ?? "no"
        line("        source rule: peer inside non-utun subnet = \(inside); device-held = \(held) → \(v.satisfiesSourceRule ? "PASSES" : "FAILS")")
        let call: String
        if c.noTunnel {
            call = v.satisfiesSourceRule
                ? "no tunnel involved; source rule PASSES — worth a run"
                : "no tunnel involved; expect TCP connect then a pairing-stage failure (source rule fails)"
        }
        else if !v.entersTunnel { call = "NOT WORTH A DEVICE RUN as-is (dial never enters the tunnel)" }
        else if v.martian { call = "reaches the tunnel and dies in ip_input — expect silence, no RST" }
        else if !v.satisfiesSourceRule { call = "reaches the daemon; expect TCP connect then a pairing-stage failure" }
        else { call = "REACHABLE **and** satisfies the source rule — this is a real experiment" }
        line("        CALL: \(call)")
        if honored != false { line("") }
    }
}

rule("═")
line(" THE STRUCTURAL RESULT")
rule("═")
line("""
 The tunnel's peer address has to satisfy two demands at once:
   (a) it must be covered by the utun's route and WIN longest-prefix match, and
   (b) it must sit inside the subnet of a non-utun interface.
 So the utun's prefix must be STRICTLY LONGER than that of the non-utun interface whose subnet the
 peer borrows. With Wi-Fi off the non-utun IPv4 subnets are lo0 /8 and two pdp_ip /32s, plus
 bridge100 /28 when the Personal Hotspot is up.

 If LocalDevVPN's provider really does ignore the mask field and always installs /24, the only
 cellular subnet broader than /24 is lo0's 127.0.0.0/8 — and every address in it is martian on a
 utun. Every other cellular candidate needs a longer prefix than /24 and therefore CANNOT be
 expressed through LocalDevVPN at all.

 That makes ONE measurement the gate for everything else: set the Subnet Mask row to
 255.255.255.252, reconnect, and read the utun's mask out of a getifaddrs dump.
""")
rule("═")
