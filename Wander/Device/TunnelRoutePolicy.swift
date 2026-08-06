//
//  TunnelRoutePolicy.swift
//  Wander
//
//  THE ROUTING HALF OF THE TUNNEL, kept apart from the tunnel controller.
//
//  WHY THIS FILE EXISTS. `includedRoutes` is not a command. Apple's own header for `enforceRoutes`
//  says it in one sentence — "If YES, route rules for this tunnel will take precendence over any
//  locally-defined routes. The default is NO." — which means that by default the phone's EXISTING
//  routes win, and an included route is only a request. That matters here and almost nowhere else,
//  because of a tension this app is structurally stuck in:
//
//    • lockdownd (iOS 26.4+, from the published decompilation) requires the connection's SOURCE
//      address to fall inside the subnet of some interface NOT named `utun*`. So the tunnel address
//      has to sit inside en0's — or bridge100's — subnet. That is the whole reason
//      `WiFiSubnet.suggestTunnelIPs()` exists.
//    • The moment it does, the phone already HAS a connected route for that subnet, pointing at the
//      physical interface. Two interfaces now claim overlapping prefixes and, by default, the
//      system's route wins.
//
//  A packet handed to en0 for a host that does not exist on the LAN produces no RST and no ICMP
//  error — it is ARPed for and dropped. That is EXACTLY the "no answer, bounded wait expired"
//  signature measured on device on 2026-08-05 for the 192.168.4.x configuration, and it is
//  indistinguishable at the socket layer from a broken tunnel.
//
//  There are two independent ways out, and this file provides both so they can be tested separately:
//
//    1. WIN ON PREFIX LENGTH (no entitlement, no saved-preference change, works on the reference
//       tunnel too). Keep the tunnel ADDRESS inside the physical interface's subnet — which is what
//       lockdownd looks at — but give the tunnel a mask specific enough that longest-prefix match
//       sends the packet to the utun anyway. A /30 around the pair does it: the address still sits
//       inside en0's /22 for lockdownd's purposes, while /30 beats /22 in the routing table.
//       `suggestNonCollidingTunnelIPs()`.
//    2. WIN ON POLICY. Set `enforceRoutes` on the saved VPN configuration so the tunnel's routes
//       take precedence outright. `applyEnforceRoutes(to:)`.
//
//  (1) is strictly cheaper and should be tried first: it changes three strings in UserDefaults,
//  needs no profile change, and can be tested through LocalDevVPN's tunnel as well as ours. (2) is
//  the fallback for the case where even a longer prefix loses.
//
//  NOTHING HERE CHANGES BEHAVIOUR ON ITS OWN. `applyEnforceRoutes` reads a preference that is off
//  until somebody turns it on, and the analysis functions only produce text.
//

import Foundation
import NetworkExtension

enum TunnelRoutePolicy {

    // MARK: - The two saved-preference flags

    /// Opt-in, default OFF. Declared here rather than in `UserDefaults.Keys` so this whole lever can
    /// be added, tested and removed without touching a shared file.
    ///
    /// OFF by default because `enforceRoutes` lives in the SAVED VPN configuration, so turning it on
    /// rewrites a profile the user may be sharing with other tools, and because the reference
    /// implementation (LocalDevVPN) does not set it — a divergence from the one configuration known
    /// to work should never be the default.
    static let enforceRoutesDefaultsKey = "WanderTunnelEnforceRoutes"

    /// Opt-in, default OFF — meaning "leave Apple's default alone", which on iOS is `excludeLocalNetworks = YES`.
    ///
    /// THIS IS NOT A SYMMETRIC PAIR WITH THE ONE ABOVE, and the asymmetry is the point. From
    /// NEVPNProtocol.h, verbatim: "If YES, all traffic destined for local networks will be excluded
    /// from the tunnel. The default is NO on macOS and YES on iOS." So on iOS this is ON unless
    /// somebody turns it off, and every address this tunnel has ever been configured with —
    /// 10.7.0.x, 172.20.10.x, 192.168.4.x, 127.0.0.x — is a local network by any reading.
    ///
    /// WHAT THE EVIDENCE DOES AND DOES NOT SETTLE. LocalDevVPN carries 10.7.0.1 with this flag left
    /// at the same default, so the broad reading ("everything RFC1918 is stripped from a split
    /// tunnel") is refuted by a working tunnel. The narrow reading — that "local networks" means the
    /// subnets the PHYSICAL interfaces are on — is NOT refuted, and under it this flag fires only for
    /// a tunnel whose addresses were deliberately placed on en0's subnet, which is precisely the
    /// configuration that has to satisfy lockdownd. That makes it an independent second explanation
    /// for the same blackhole, testable at the same cost as `enforceRoutes`, on the same object, in
    /// the same save.
    static let allowLocalNetworksDefaultsKey = "WanderTunnelAllowLocalNetworks"

    static var isEnforceRoutesEnabled: Bool {
        UserDefaults.standard.bool(forKey: enforceRoutesDefaultsKey)
    }

    /// True when the user asked us to override iOS's `excludeLocalNetworks = YES` default.
    static var isAllowLocalNetworksEnabled: Bool {
        UserDefaults.standard.bool(forKey: allowLocalNetworksDefaultsKey)
    }

    /// Push both route-policy preferences onto a VPN manager's protocol configuration.
    ///
    /// MUST BE CALLED BEFORE `saveToPreferences()`, and it must be called on EVERY start rather than
    /// only when the configuration is first created. Both flags are properties of `NEVPNProtocol`,
    /// i.e. of `manager.protocolConfiguration`, which is persisted by `saveToPreferences()` — so a
    /// profile that already exists carries whatever value it was saved with, forever, and a "create
    /// the protocol object and set it there" edit would silently do nothing for every user who has
    /// ever run the tunnel before. Applying it on the start path (which already saves) fixes existing
    /// profiles without making anyone delete and re-add one.
    ///
    /// `protocolConfiguration` is declared `strong`, not `copy` (NEVPNManager.h), so the object
    /// returned by the getter IS the stored one and mutating it in place is sufficient. It is
    /// assigned back anyway — that costs nothing and does not depend on an implementation detail.
    ///
    /// NOTE the tunnel must be RESTARTED afterwards. Network settings are established once, inside
    /// `startTunnel(options:)`; rewriting the saved profile under a live tunnel changes what the NEXT
    /// start does and nothing about the current one.
    ///
    /// Returns true when something actually changed, so a caller can log a profile rewrite rather
    /// than a no-op. Never throws; a manager with no protocol configuration is left alone.
    @discardableResult
    static func applyRoutePolicy(to manager: NEVPNManager) -> Bool {
        guard let proto = manager.protocolConfiguration else { return false }
        let wantedEnforce = isEnforceRoutesEnabled
        let wantedExcludeLocal = !isAllowLocalNetworksEnabled
        guard proto.enforceRoutes != wantedEnforce
                || proto.excludeLocalNetworks != wantedExcludeLocal else { return false }
        proto.enforceRoutes = wantedEnforce
        proto.excludeLocalNetworks = wantedExcludeLocal
        manager.protocolConfiguration = proto
        LogManager.shared.addInfoLog(
            "Tunnel: route policy → enforceRoutes \(wantedEnforce ? "ON" : "OFF"), excludeLocalNetworks \(wantedExcludeLocal ? "ON (iOS default)" : "OFF") — saved VPN profile rewritten; restart the tunnel for it to take effect")
        return true
    }

    // MARK: - Does the configured tunnel subnet collide with a real interface?

    /// How the tunnel's declared prefix compares with a non-utun interface that also covers the
    /// address being dialled.
    enum Relation: String {
        /// The tunnel's prefix is LONGER. Longest-prefix match sends the packet to the utun without
        /// any need for `enforceRoutes`. This is the state to aim for.
        case tunnelMoreSpecific
        /// Identical prefix length on both. The routing table decides, and Apple documents that it
        /// supersedes `includedRoutes` unless `enforceRoutes` is set. This is the failure shape.
        case identicalPrefix
        /// The physical interface's prefix is longer, so it wins outright. Worse than identical.
        case tunnelLessSpecific

        var summary: String {
            switch self {
            case .tunnelMoreSpecific:
                return "the tunnel's prefix is LONGER, so longest-prefix match should send the packet to the utun"
            case .identicalPrefix:
                return "IDENTICAL prefix length — the system routing table decides, and by default it supersedes includedRoutes"
            case .tunnelLessSpecific:
                return "the physical interface's prefix is LONGER, so it wins and the tunnel never sees the packet"
            }
        }
    }

    /// One non-utun interface whose subnet also covers the dialled address.
    struct Collision {
        let interfaceName: String
        let interfaceCIDR: String
        let interfacePrefixLength: Int
        let relation: Relation
    }

    /// Everything worth knowing about the CONFIGURED tunnel, computed from the same `getifaddrs`
    /// enumerator the rest of the app uses. Pure: reads UserDefaults and the interface table, writes
    /// nothing.
    struct Report {
        let interfaceIP: String
        let targetIP: String
        let subnetMask: String
        /// The route `PacketTunnelProvider` installs, as CIDR, after masking host bits off the
        /// destination the way `NEIPv4Route` documents it will ("this mask in combination with the
        /// destinationAddress property is used to determine the destination network of the route").
        let routeCIDR: String?
        /// Whether that route actually covers the address Wander dials. Answered arithmetically
        /// rather than assumed — it is the first thing to rule out and it has never been printed.
        let routeCoversTarget: Bool
        /// Non-utun interfaces that ALSO cover the target.
        let collisions: [Collision]
        /// Non-utun interfaces whose subnet contains the tunnel's INTERFACE address — i.e. the ones
        /// that make the source address acceptable to lockdownd.
        let lockdowndWitnesses: [String]

        /// True when the route is uncontested or wins on length. The thing a device test should be
        /// able to read in one glance.
        var routeShouldWin: Bool {
            collisions.allSatisfy { $0.relation == .tunnelMoreSpecific }
        }
    }

    static func analyzeConfiguredTunnel() -> Report {
        let defaults = UserDefaults.standard
        let interfaceIP = defaults.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
        let targetIP = DeviceConnectionContext.targetIPAddress
        let mask = defaults.string(forKey: UserDefaults.Keys.tunnelSubnetMask) ?? "255.255.255.0"
        return analyze(interfaceIP: interfaceIP, targetIP: targetIP, subnetMask: mask)
    }

    /// The same analysis for an arbitrary triple, so a candidate can be evaluated BEFORE it is saved
    /// and before a tunnel is restarted onto it.
    static func analyze(interfaceIP: String, targetIP: String, subnetMask: String) -> Report {
        guard let (family, interfaceBytes) = WiFiSubnet.parseAddress(interfaceIP),
              family == AF_INET,
              let (targetFamily, targetBytes) = WiFiSubnet.parseAddress(targetIP),
              targetFamily == AF_INET,
              let (maskFamily, maskBytes) = WiFiSubnet.parseAddress(subnetMask),
              maskFamily == AF_INET
        else {
            return Report(interfaceIP: interfaceIP, targetIP: targetIP, subnetMask: subnetMask,
                          routeCIDR: nil, routeCoversTarget: false,
                          collisions: [], lockdowndWitnesses: [])
        }

        let prefixLength = WiFiSubnet.leadingOnes(maskBytes)
        let networkBytes = zip(interfaceBytes, maskBytes).map { $0 & $1 }
        let networkText = WiFiSubnet.presentation(family: AF_INET, bytes: networkBytes)
        let routeCIDR = networkText.isEmpty ? nil : "\(networkText)/\(prefixLength)"

        // The masked compare the kernel makes: the target is on the route when it masks to the same
        // network. This is also the exact test that has never been printed anywhere in the app.
        let covers = zip(zip(targetBytes, maskBytes).map { $0 & $1 }, networkBytes).allSatisfy(==)

        var collisions: [Collision] = []
        var witnesses: [String] = []
        for entry in WiFiSubnet.allAddresses() where entry.isIPv4 && entry.isUp && !entry.isUtun {
            guard let entryPrefix = entry.prefixLength, let entryCIDR = entry.cidr else { continue }
            if entry.containsAddress(family: AF_INET, bytes: interfaceBytes) {
                witnesses.append("\(entry.name) \(entryCIDR)")
            }
            guard entry.containsAddress(family: AF_INET, bytes: targetBytes) else { continue }
            // A /32 (pdp_ip0) covers only itself and cannot be a competing SUBNET route, so it is not
            // a collision even when the arithmetic above happens to match.
            guard entryPrefix < 32 else { continue }
            let relation: Relation
            if prefixLength > entryPrefix { relation = .tunnelMoreSpecific }
            else if prefixLength == entryPrefix { relation = .identicalPrefix }
            else { relation = .tunnelLessSpecific }
            collisions.append(Collision(interfaceName: entry.name,
                                        interfaceCIDR: entryCIDR,
                                        interfacePrefixLength: entryPrefix,
                                        relation: relation))
        }

        return Report(interfaceIP: interfaceIP, targetIP: targetIP, subnetMask: subnetMask,
                      routeCIDR: routeCIDR, routeCoversTarget: covers,
                      collisions: collisions, lockdowndWitnesses: witnesses)
    }

    /// The report as Console lines, written for whoever has to decide what to change next rather
    /// than for someone holding a routing table.
    static func reportLines(_ report: Report, reason: String = "manual") -> [String] {
        var out: [String] = []
        out.append("=== TUNNEL ROUTE POLICY === reason: \(reason)")
        out.append("  configured: interface \(report.interfaceIP) · dials \(report.targetIP) · mask \(report.subnetMask)")
        out.append("  included route installed: \(report.routeCIDR ?? "<could not be computed>")")
        out.append(report.routeCoversTarget
                   ? "  ROUTE COVERS the address Wander dials — so a failure here is NOT missing coverage."
                   : "  ROUTE DOES NOT COVER the address Wander dials — nothing can work until the mask or the addresses change.")

        out.append("  enforceRoutes preference: \(isEnforceRoutesEnabled ? "ON" : "OFF (Apple's default — the system routing table supersedes includedRoutes)")")
        out.append("  excludeLocalNetworks: \(isAllowLocalNetworksEnabled ? "OFF (overridden — local-network traffic may enter the tunnel)" : "ON (iOS's default; local-network traffic may be kept OUT of the tunnel)")")

        if report.lockdowndWitnesses.isEmpty {
            out.append("  lockdownd source rule: NO non-utun interface subnet contains \(report.interfaceIP) → the source address is expected to be rejected")
        } else {
            out.append("  lockdownd source rule: satisfied via " + report.lockdowndWitnesses.joined(separator: ", "))
        }

        if report.collisions.isEmpty {
            out.append("  route collisions: NONE — no non-utun interface claims a subnet containing \(report.targetIP)")
        } else {
            for collision in report.collisions {
                out.append("  route COLLISION with \(collision.interfaceName) \(collision.interfaceCIDR): \(collision.relation.summary)")
            }
        }

        out.append(report.routeShouldWin
                   ? "  BOTTOM LINE: routing is not the obstacle for this configuration."
                   : "  BOTTOM LINE: the phone already has a route that is at least as specific as the tunnel's. Either shorten the tunnel's subnet to a /30 around the pair, or turn enforceRoutes on.")
        out.append("=== END TUNNEL ROUTE POLICY ===")
        return out
    }

    /// Write the analysis into the app Console, retained through the same store the interface dump
    /// uses so opening the Console cannot wipe it.
    static func logConfiguredTunnel(reason: String = "manual") {
        let lines = reportLines(analyzeConfiguredTunnel(), reason: reason)
        for line in lines { LogManager.shared.addInfoLog(line) }
        NetworkInterfaceDump.retain(lines)
    }

    // MARK: - A suggestion that does not collide

    /// ⚠️ OVERLAPS `TunnelIPPlanner`, which landed alongside this file and does the same job BETTER —
    /// it also falls back to the Personal Hotspot subnet when Wi-Fi is off, which is the only
    /// non-utun IPv4 subnet with room on a cellular-only phone. If `TunnelIPPlanner` is in the tree,
    /// USE IT and delete this section: two suggesters that can disagree about the tunnel's mask is a
    /// worse bug than either of them fixes. This is kept only so the /30 lever does not depend on
    /// another in-flight change landing.
    ///
    /// The mask that makes a two-address tunnel win on prefix length: a /30, the smallest IPv4
    /// subnet that still holds two usable hosts.
    static let nonCollidingSubnetMask = "255.255.255.252"

    /// Wi-Fi-subnet tunnel addresses that satisfy lockdownd WITHOUT contesting en0's route.
    ///
    /// The difference from `WiFiSubnet.suggestTunnelIPs()` is the third element and only the third
    /// element. That function returns en0's OWN netmask, so on a /22 home network the tunnel claims
    /// 192.168.4.0/22 — the identical prefix en0 already owns — and the tie is resolved by the system
    /// routing table, which by default wins. The addresses were never the problem; the mask was.
    ///
    /// The addresses stay inside en0's subnet, which is what lockdownd's check reads (it walks
    /// `getifaddrs` and asks whether the source falls inside a non-`utun` interface's subnet — it does
    /// not care what mask the utun itself declares). So this satisfies both rules at once: en0's /22
    /// still contains .240 for lockdownd, and /30 beats /22 in the routing table.
    ///
    /// Returns nil when not on Wi-Fi, when the netmask is longer than a /30 (there is no room for a
    /// more specific route), or when the pair would fall outside the interface's own subnet — in
    /// which case lockdownd would reject the source and the suggestion would be worse than none.
    static func suggestNonCollidingTunnelIPs() -> (device: String, fake: String, mask: String)? {
        guard let (ip, mask) = WiFiSubnet.currentIPv4(),
              let (family, ipBytes) = WiFiSubnet.parseAddress(ip), family == AF_INET,
              let (maskFamily, maskBytes) = WiFiSubnet.parseAddress(mask), maskFamily == AF_INET
        else { return nil }

        // A /31 or /32 leaves nothing more specific to offer.
        guard WiFiSubnet.leadingOnes(maskBytes) <= 30 else { return nil }

        // .240/.241 for the same reason the existing suggestion picks them: high host addresses are
        // usually outside a home DHCP pool. Built from the interface's OWN address masked by its OWN
        // netmask, so the pair is inside the interface's subnet on a /25 or /26 too — where taking
        // the first three octets verbatim can land outside it.
        let networkBytes = zip(ipBytes, maskBytes).map { $0 & $1 }
        var device = networkBytes
        var fake = networkBytes
        device[3] |= 0xF0            // .240 within the network
        fake[3] |= 0xF1              // .241 within the network

        let deviceText = WiFiSubnet.presentation(family: AF_INET, bytes: device)
        let fakeText = WiFiSubnet.presentation(family: AF_INET, bytes: fake)
        guard !deviceText.isEmpty, !fakeText.isEmpty else { return nil }

        // Both must still be inside the interface's subnet, or lockdownd's source test fails.
        let insideDevice = zip(zip(device, maskBytes).map { $0 & $1 }, networkBytes).allSatisfy(==)
        let insideFake = zip(zip(fake, maskBytes).map { $0 & $1 }, networkBytes).allSatisfy(==)
        guard insideDevice, insideFake else { return nil }

        // …and the /30 around .240 must contain both, which it does by construction (240 & 252 == 240,
        // so the network is x.x.x.240 and the pair is .240/.241). Asserted rather than assumed.
        guard device[3] & 0xFC == device[3], fake[3] & 0xFC == device[3] else { return nil }

        return (deviceText, fakeText, nonCollidingSubnetMask)
    }
}
