//
//  TunnelIPPlanner.swift
//  Wander
//
//  PICKS THE DEVELOPER TUNNEL'S TWO ADDRESSES — AND, THE PART THAT WAS WRONG, A MASK NARROW ENOUGH
//  TO WIN THE ROUTE.
//
//  THE BUG THIS REPLACES. `WiFiSubnet.suggestTunnelIPs()` returned the parent interface's OWN mask
//  alongside the two addresses it invented. On the owner's network — en0 at 192.168.4.46 with mask
//  255.255.252.0 — "Detect" therefore proposed:
//
//        device 192.168.4.240   fake 192.168.4.241   mask 255.255.252.0
//
//  which tells iOS the tunnel owns 192.168.4.0/22: THE IDENTICAL PREFIX en0 ALREADY OWNS. Two
//  interfaces then claim the same prefix, the route for .241 is ambiguous, and the tie is resolved
//  by the routing table rather than by us — plausibly out over real Wi-Fi, to a host that does not
//  exist. On a textbook home /24 the same code happened to be harmless (the mask was 255.255.255.0
//  and .240/.241 were free), which is why it survived: it is only wrong when the parent prefix is
//  not a /24, and that is exactly the network it was measured on.
//
//  THE FIX, in one sentence: carve a /30 — four addresses — out of the parent subnet. Darwin routes
//  by LONGEST MATCHING PREFIX, so a /30 on the utun beats en0's /22 (or /24, or /16) for those four
//  addresses and for nothing else. The tunnel wins the two addresses it needs; every other address
//  on the LAN keeps going out over Wi-Fi exactly as before. A mask is not decoration here — it IS
//  the mechanism that decides which interface a packet enters.
//
//  WHY THE DEVICE IP IS THE /30's NETWORK ADDRESS (e.g. .240 of .240/30, not .241 of .241/30).
//  The provider builds its included route as
//        NEIPv4Route(destinationAddress: <device IP>, subnetMask: <mask>)
//  i.e. it uses the HOST address as a route DESTINATION. That is only well-formed when the host
//  address has no bits set below the mask. The default config that demonstrably works — 10.7.0.0
//  with 255.255.255.0 — satisfies that by accident: 10.7.0.0 IS the network address of 10.7.0.0/24.
//  Every failing config measured so far had host bits set. So this planner keeps that shape on
//  purpose: device IP == the /30's network address, fake IP == network + 1, both inside the route.
//  (`TunnelIPPlacement.firstTwoHosts` produces the other arrangement if it ever needs testing.)
//
//  WHAT IS NEW: THE PERSONAL HOTSPOT FALLBACK. The old code returned nil the moment Wi-Fi was off,
//  which made "Detect" useless in the state the cellular investigation actually cares about. The
//  measured interface inventory with Wi-Fi off is: lo0 (loopback), pdp_ip0 and pdp_ip2 — both /32
//  POINT-TO-POINT, one member each, and that member is the device's own address. A /32 has no room
//  for anybody, so there is nothing to carve. Turn Personal Hotspot on and `bridge100` appears at
//  172.20.10.1/28, BROADCAST, backhauled by cellular and surviving with Wi-Fi off — the ONLY
//  non-utun IPv4 subnet on a cellular-only phone with space in it. So that is where this falls back
//  to. Two measured caveats travel with the plan as notes: iOS drops the hotspot after roughly 90
//  seconds with no client attached, and enabling it can quietly switch the Wi-Fi radio back on.
//
//  WHAT IT REFUSES, and why refusing is the right answer:
//    • a POINT-TO-POINT or /31 or /32 parent (pdp_ip0) — a one-member subnet whose one member the
//      device already holds. Any address "inside" it is either that address (the older lockdownd
//      check rejects a source the device itself holds) or outside the subnet entirely.
//    • a /29 or /30 parent — every /30 inside it contains the parent's network or broadcast address.
//    • lo0 — not by arithmetic (127.0.0.0/8 has ample room and this file will happily plan inside it
//      if asked directly) but by POLICY, in `parents(from:)`: a 127.x address assigned to a utun was
//      measured to give EADDRNOTAVAIL (49) on connect — assigned, but not deliverable.
//    • any block containing the parent's own address, the parent's network or broadcast address, or
//      ANY address this device currently holds on ANY interface.
//
//  THE MATH IS PURE AND HOST-TESTABLE. Everything above the `#if !WANDER_PLANNER_STANDALONE` marker
//  depends on nothing but Foundation, so `tools/tunnelipplan` compiles THIS FILE — not a
//  transcription of it — and exercises it against the real subnets measured on the device. Only the
//  adapter below that marker touches app types (`NetworkInterfaceAddress`), and the flag excludes it
//  from the host build. Run the check with:
//
//      swiftc -O -D WANDER_PLANNER_STANDALONE \
//             /Users/faisalnabulsi/Developer/wander-ios/Wander/Device/TunnelIPPlanner.swift \
//             /Users/faisalnabulsi/Developer/wander-ios/tools/tunnelipplan/main.swift \
//             -o /tmp/tunnelipplan && /tmp/tunnelipplan
//

import Foundation

// MARK: - Inputs

/// The interface a tunnel address is being carved out of, reduced to the four facts that decide the
/// answer. Addresses are HOST byte order throughout this file (`getifaddrs` hands back network
/// order; the adapter converts once, at the boundary, so the arithmetic below never has to think
/// about it).
struct TunnelParentSubnet: Sendable, Equatable {
    /// Kernel interface name — en0, bridge100, lo0, pdp_ip0 … Carried for the message, not the math.
    let name: String
    /// The interface's own IPv4 address.
    let address: UInt32
    /// Its netmask.
    let mask: UInt32
    /// `IFF_POINTOPOINT`. pdp_ip0 sets it; a /32 is treated the same way even when the flag is absent.
    let isPointToPoint: Bool
    /// `IFF_LOOPBACK`. Not used by the arithmetic — the interface SELECTION policy is what rejects lo0.
    let isLoopback: Bool

    init(name: String, address: UInt32, mask: UInt32, isPointToPoint: Bool = false, isLoopback: Bool = false) {
        self.name = name
        self.address = address
        self.mask = mask
        self.isPointToPoint = isPointToPoint
        self.isLoopback = isLoopback
    }

    var prefixLength: Int { TunnelIPPlanner.prefixLength(ofMask: mask) }
    var network: UInt32 { address & mask }
    var broadcast: UInt32 { network | ~mask }
    var cidr: String { "\(TunnelIPPlanner.dotted(network))/\(prefixLength)" }
    var maskText: String { TunnelIPPlanner.dotted(mask) }
}

/// Where the plan's parent subnet came from. The UI says different things for each, because the
/// hotspot case carries caveats Wi-Fi does not.
enum TunnelIPPlanSource: String, Sendable {
    /// en0 — the phone is on Wi-Fi. The normal case.
    case wifi
    /// bridge100 — Wi-Fi is off (or unusable) and Personal Hotspot is on. The cellular case.
    case personalHotspot
    /// Some other non-utun broadcast interface (a second Ethernet-ish link, a Mac's en1 …).
    case otherBroadcast
    /// Handed in directly — what the offline check and any caller-supplied subnet report.
    case explicit
}

/// Which two of the /30's four addresses to hand out.
enum TunnelIPPlacement: Sendable {
    /// device = the /30's network address, fake = network + 1. DEFAULT, and the shape the working
    /// 10.7.0.0/24 default already has: the route destination the provider builds from the device IP
    /// then has no host bits set.
    case networkAligned
    /// device = network + 1, fake = network + 2 — the two "real" hosts of the /30. Kept so the other
    /// arrangement is one argument away if a device test ever needs to compare them.
    case firstTwoHosts
}

// MARK: - Outputs

/// A concrete, checked proposal. Every string here is presentation; the numbers were decided by the
/// arithmetic in `plan(in:avoiding:placement:source:)`.
struct TunnelIPPlan: Sendable, Equatable {
    /// LocalDevVPN's "Device IP" — the tunnel interface's own address (key `TunnelInterfaceIP`).
    let deviceIP: String
    /// LocalDevVPN's "Tunnel IP" — the fake peer Wander dials (key `TunnelDeviceIP`).
    let fakeIP: String
    /// Always 255.255.255.252. The whole point.
    let mask: String
    /// Always 30.
    let prefixLength: Int
    /// The /30's own network and broadcast addresses, so a reader can see the pair is inside it.
    let blockNetwork: String
    let blockBroadcast: String
    /// The interface the pair was carved out of, and its subnet.
    let parentName: String
    let parentCIDR: String
    /// The mask the OLD code would have returned — i.e. the bug, kept so the fix is visible in a log.
    let parentMask: String
    let source: TunnelIPPlanSource
    /// Plain-English reasons, in the order they matter. Safe to print straight into the Console.
    let notes: [String]
}

/// Why no plan exists. Refusing is a real answer — proposing an address inside a /32 would be worse
/// than saying there is no room.
enum TunnelIPPlanRefusal: Error, Equatable {
    /// Nothing on the phone has a usable non-utun IPv4 subnet.
    case noEligibleInterface
    /// The parent is point-to-point / a /31 / a /32: one member, and the device already holds it.
    case pointToPointParent(name: String, cidr: String)
    /// The mask is not a run of ones followed by zeros, so "/n" would be a lie about what is compared.
    case nonContiguousMask(name: String, mask: String)
    /// A /29 or /30 parent: too small to contain a /30 that avoids its own network and broadcast.
    case parentTooSmall(name: String, cidr: String, prefixLength: Int)
    /// Every candidate block was already occupied by the device itself.
    case everyBlockCollides(name: String, cidr: String)

    /// One sentence, written for the person reading the Console, not for an expert.
    var message: String {
        switch self {
        case .noEligibleInterface:
            return "No interface has a usable IPv4 subnet. With Wi-Fi off the phone has only lo0 and the cellular interfaces, and each cellular interface is a /32 — a subnet with exactly one member, which the device itself already holds. Turn on Wi-Fi, or turn on Personal Hotspot (which adds 172.20.10.0/28)."
        case .pointToPointParent(let name, let cidr):
            return "\(name) is \(cidr) — a point-to-point link whose subnet has one member, and that member is this phone. There is no second address to give the tunnel."
        case .nonContiguousMask(let name, let mask):
            return "\(name)'s netmask \(mask) is not a contiguous run of ones, so no prefix length describes it and no safe block can be carved out of it."
        case .parentTooSmall(let name, let cidr, let prefixLength):
            return "\(name) is \(cidr) — a /\(prefixLength) has too few addresses to hold a /30 that avoids its own network and broadcast addresses."
        case .everyBlockCollides(let name, let cidr):
            return "Every four-address block inside \(cidr) on \(name) contains an address this device already holds. Nothing here is free to hand to the tunnel."
        }
    }
}

// MARK: - The planner

enum TunnelIPPlanner {

    /// The prefix the plan always returns. Chosen as the SMALLEST block that still holds two
    /// addresses plus its own network and broadcast — the narrower the prefix, the more decisively it
    /// wins longest-prefix-match against the parent interface, and the less of the parent's address
    /// space is taken away from the LAN.
    static let planPrefixLength = 30
    static let planMask: UInt32 = 0xFFFF_FFFC

    /// The host address the old code always proposed (`.240`), relative to the containing /24. Tried
    /// FIRST when it is legal, so a user who already typed 192.168.4.240 / .241 into LocalDevVPN has
    /// to change one field — the mask — and not three.
    static let traditionalHostOffset: UInt32 = 240

    /// How far down from the top of the parent range the search will walk before giving up. A /8 (lo0)
    /// holds four million /30s and the device holds a dozen addresses, so the answer is always within
    /// the first few blocks; this bound exists so a pathological parent cannot turn a button tap into
    /// a multi-second stall.
    static let maxBlocksScanned = 4096

    // MARK: Pure planning

    /// Carve a /30 out of `parent`, avoiding `held` (every address this device currently has).
    ///
    /// Deterministic and side-effect free: same inputs, same answer, which is what makes it testable
    /// off-device against the subnets that were actually measured.
    static func plan(in parent: TunnelParentSubnet,
                     avoiding held: Set<UInt32> = [],
                     placement: TunnelIPPlacement = .networkAligned,
                     source: TunnelIPPlanSource = .explicit) -> Result<TunnelIPPlan, TunnelIPPlanRefusal> {

        guard isContiguous(mask: parent.mask) else {
            return .failure(.nonContiguousMask(name: parent.name, mask: parent.maskText))
        }

        let prefix = parent.prefixLength

        // A /31 or /32 (and anything flagged point-to-point) has no room by construction: its subnet
        // has one or two members and the device holds them. pdp_ip0 lands here, which is the whole
        // reason the cellular case falls through to the hotspot bridge.
        if parent.isPointToPoint || prefix >= 31 {
            return .failure(.pointToPointParent(name: parent.name, cidr: parent.cidr))
        }
        // /29 and /30: the first block holds the network address, the last holds the broadcast, and
        // in a /29 those are the only two blocks. Nothing survives the filter, so say so by name
        // rather than reporting "everything collided".
        guard prefix <= 28 else {
            return .failure(.parentTooSmall(name: parent.name, cidr: parent.cidr, prefixLength: prefix))
        }

        let network = parent.network
        let broadcast = parent.broadcast

        /// A block is usable only if all four of its addresses are inside the parent AND none of them
        /// is spoken for. The parent's own address and the parent's broadcast are called out in the
        /// task; the parent's NETWORK address is excluded for the same reason, and excluding the
        /// first block has a useful side effect — network+1 is where home routers and the hotspot
        /// bridge itself live, so the default gateway is never proposed either.
        func isUsable(_ base: UInt32) -> Bool {
            guard base >= network, base &+ 3 <= broadcast, base &+ 3 >= base else { return false }
            func inBlock(_ a: UInt32) -> Bool { a >= base && a <= base &+ 3 }
            if inBlock(network) || inBlock(broadcast) || inBlock(parent.address) { return false }
            for h in held where inBlock(h) { return false }
            return true
        }

        // Candidates are generated and tested LAZILY, first usable wins. Eagerly listing every /30 in
        // the parent would be 4 million blocks on a /8 (lo0 is one) to answer a question the first
        // candidate almost always settles.
        //
        // 1. The historical .240 pair, when it is legal inside this parent. Continuity with what the
        //    old button proposed and with what is already typed into LocalDevVPN.
        let traditional = ((parent.address & 0xFFFF_FF00) | traditionalHostOffset) & planMask
        var chosen: UInt32?
        if isUsable(traditional) { chosen = traditional }

        // 2. Otherwise walk DOWN from the top of the parent range. High addresses are the ones a DHCP
        //    server hands out last, so they are the least likely to be taken by a real device — and on
        //    a Personal Hotspot's /28 they leave the low addresses free for actual hotspot clients
        //    (there has to be one attached, or iOS shuts the hotspot down).
        if chosen == nil {
            var base = broadcast & planMask
            var scanned = 0
            while scanned < maxBlocksScanned {
                if base != traditional, isUsable(base) { chosen = base; break }
                if base < 4 || base &- 4 < network { break }
                base &-= 4
                scanned += 1
            }
        }

        guard let chosen else {
            return .failure(.everyBlockCollides(name: parent.name, cidr: parent.cidr))
        }

        let device = placement == .networkAligned ? chosen : chosen &+ 1
        let fake = device &+ 1

        return .success(TunnelIPPlan(
            deviceIP: dotted(device),
            fakeIP: dotted(fake),
            mask: dotted(planMask),
            prefixLength: planPrefixLength,
            blockNetwork: dotted(chosen),
            blockBroadcast: dotted(chosen &+ 3),
            parentName: parent.name,
            parentCIDR: parent.cidr,
            parentMask: parent.maskText,
            source: source,
            notes: notes(parent: parent,
                         block: chosen,
                         device: device,
                         fake: fake,
                         placement: placement,
                         source: source)
        ))
    }

    /// The reasons, in the order a reader needs them. Written to be pasted into a log and understood
    /// without this file open next to it.
    private static func notes(parent: TunnelParentSubnet,
                              block: UInt32,
                              device: UInt32,
                              fake: UInt32,
                              placement: TunnelIPPlacement,
                              source: TunnelIPPlanSource) -> [String] {
        var out: [String] = []

        out.append("mask 255.255.255.252 (/30) covers exactly \(dotted(block))–\(dotted(block &+ 3)). Darwin routes by longest matching prefix, so those four addresses go to the tunnel and every other address in \(parent.cidr) keeps using \(parent.name).")

        out.append("the old Detect returned \(parent.name)'s own mask \(parent.maskText), which claimed the WHOLE of \(parent.cidr) for the tunnel — the identical prefix \(parent.name) already owns, so the route for the fake address was ambiguous.")

        switch placement {
        case .networkAligned:
            out.append("device IP \(dotted(device)) is the /30's network address, so the included route the provider builds from it (destination \(dotted(device)), mask 255.255.255.252) has no host bits set — the same shape as the 10.7.0.0/24 default that works.")
        case .firstTwoHosts:
            out.append("device IP \(dotted(device)) is the first HOST of the /30 (network \(dotted(block))), so the route the provider builds from it has host bits set. This arrangement exists for comparison; the default is networkAligned.")
        }

        out.append("avoided: \(parent.name)'s own address \(dotted(parent.address)), the subnet's network \(dotted(parent.network)) and broadcast \(dotted(parent.broadcast)) addresses, and every address this device currently holds.")

        if block == ((parent.address & 0xFFFF_FF00) | traditionalHostOffset) {
            out.append("this is the same .240/.241 pair the old button suggested — ONLY the mask changed, so LocalDevVPN needs one field edited, not three.")
        }

        if source == .personalHotspot {
            out.append("Wi-Fi is off: this came from the Personal Hotspot bridge, which is the only non-utun IPv4 subnet with room on a cellular-only phone.")
            out.append("CAVEAT: iOS shuts the hotspot down after roughly 90 seconds with no client attached — keep something connected to it, or bridge100 and these addresses disappear underneath the tunnel.")
            out.append("CAVEAT: turning Personal Hotspot on can silently switch the Wi-Fi radio back on and rejoin a known network, which would defeat the point of testing on cellular. Check Settings after enabling it.")
        }

        out.append("fake IP \(dotted(fake)) is not an address this device holds, so it does not trip the older lockdownd check that rejects a source the device itself owns.")
        return out
    }

    /// Console-ready lines for either outcome. Pure, so the offline check prints exactly what the
    /// device would.
    static func explain(_ result: Result<TunnelIPPlan, TunnelIPPlanRefusal>) -> [String] {
        switch result {
        case .success(let p):
            var out = ["TUNNEL IP PLAN: device \(p.deviceIP) · fake \(p.fakeIP) · mask \(p.mask) (/\(p.prefixLength))",
                       "  from \(p.parentName) \(p.parentCIDR) [\(p.source.rawValue)] · block \(p.blockNetwork)–\(p.blockBroadcast)"]
            out.append(contentsOf: p.notes.map { "  • \($0)" })
            return out
        case .failure(let r):
            return ["TUNNEL IP PLAN: none — \(r.message)"]
        }
    }

    // MARK: Address arithmetic

    /// Dotted quad from a host-order address.
    static func dotted(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// Host-order address from a dotted quad. nil on anything that is not four 0…255 decimal octets —
    /// deliberately stricter than `inet_pton`, which also accepts "10.1" and octal forms.
    static func parseDotted(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = UInt32(p), n <= 255 else { return nil }
            out = (out << 8) | n
        }
        return out
    }

    /// Leading 1-bits — the `/n` of a netmask. (The leading ones of the mask are exactly the leading
    /// ZEROS of its complement, which is one instruction and cannot get the edges wrong: an all-ones
    /// mask gives 32, an all-zero mask gives 0.)
    static func prefixLength(ofMask mask: UInt32) -> Int {
        (~mask).leadingZeroBitCount
    }

    /// True when the mask is a run of ones followed by zeros. `prefixLength` is only meaningful then.
    static func isContiguous(mask: UInt32) -> Bool {
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }
}

// MARK: - Live interfaces (app target only)

#if !WANDER_PLANNER_STANDALONE

extension TunnelIPPlanner {

    /// Interface names that are never a sane parent even though they are non-utun and have a mask:
    /// Apple Wireless Direct Link and low-latency WLAN are peer-to-peer link-local transports with no
    /// routable subnet, and the rest are other people's tunnels.
    private static let excludedParentPrefixes = ["awdl", "llw", "anpi", "ipsec", "ppp", "tap", "gif", "stf", "utun"]

    /// Every candidate parent, best first: Wi-Fi, then the Personal Hotspot bridge, then anything else
    /// with a real broadcast subnet.
    ///
    /// lo0 is excluded on purpose and NOT for arithmetic reasons: 127.0.0.0/8 has ample room and
    /// `plan(in:)` will happily carve it up if handed to it directly. It is excluded because a 127.x
    /// address assigned to a utun was measured to give EADDRNOTAVAIL (49) on connect — the kernel
    /// accepts the assignment and then refuses to deliver to it.
    static func parents(from entries: [NetworkInterfaceAddress]) -> [(TunnelParentSubnet, TunnelIPPlanSource)] {
        var wifi: [(TunnelParentSubnet, TunnelIPPlanSource)] = []
        var hotspot: [(TunnelParentSubnet, TunnelIPPlanSource)] = []
        var other: [(TunnelParentSubnet, TunnelIPPlanSource)] = []

        for e in entries where e.isIPv4 && e.isUp && !e.isLoopback {
            guard let maskBytes = e.maskBytes,
                  let address = hostOrder(e.addressBytes),
                  let mask = hostOrder(maskBytes) else { continue }
            guard !excludedParentPrefixes.contains(where: { e.name.hasPrefix($0) }) else { continue }

            let parent = TunnelParentSubnet(name: e.name,
                                            address: address,
                                            mask: mask,
                                            isPointToPoint: e.isPointToPoint,
                                            isLoopback: e.isLoopback)

            if e.name == "en0" {
                wifi.append((parent, .wifi))
            } else if e.name.hasPrefix("bridge") {
                hotspot.append((parent, .personalHotspot))
            } else if e.isBroadcast {
                other.append((parent, .otherBroadcast))
            }
        }
        return wifi + hotspot + other
    }

    /// Every IPv4 address the device currently holds, on every interface INCLUDING utuns. A block
    /// containing any of these is unusable: the older lockdownd check rejects a source address the
    /// device itself holds, and a duplicate assignment would be a routing problem regardless.
    static func heldIPv4Addresses(_ entries: [NetworkInterfaceAddress]) -> Set<UInt32> {
        Set(entries.compactMap { $0.isIPv4 ? hostOrder($0.addressBytes) : nil })
    }

    /// Plan against the phone's real interfaces. Tries each candidate parent in order and returns the
    /// first that yields a plan; if none does, returns the FIRST refusal, which is the one about the
    /// interface the user most likely expected to be used.
    static func planFromCurrentInterfaces(placement: TunnelIPPlacement = .networkAligned)
        -> Result<TunnelIPPlan, TunnelIPPlanRefusal> {
        let entries = WiFiSubnet.allAddresses()
        let held = heldIPv4Addresses(entries)
        let candidates = parents(from: entries)
        guard !candidates.isEmpty else { return .failure(.noEligibleInterface) }

        var firstRefusal: TunnelIPPlanRefusal?
        for (parent, source) in candidates {
            switch plan(in: parent, avoiding: held, placement: placement, source: source) {
            case .success(let p): return .success(p)
            case .failure(let r): if firstRefusal == nil { firstRefusal = r }
            }
        }
        return .failure(firstRefusal ?? .noEligibleInterface)
    }

    /// Drop-in replacement for the old `WiFiSubnet.suggestTunnelIPs()` — same tuple, same nil-on-
    /// failure contract, so the owned file can adopt it in one line and no call site changes.
    static func suggest() -> (device: String, fake: String, mask: String)? {
        guard case .success(let p) = planFromCurrentInterfaces() else { return nil }
        return (p.deviceIP, p.fakeIP, p.mask)
    }

    /// Network-order bytes → host order.
    private static func hostOrder(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.count == 4 else { return nil }
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
    }
}

#endif
