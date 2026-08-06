//
//  CellularIPv6Suggester.swift
//  Wander
//
//  AIMS THE IPv6 TUNNEL EXPERIMENT AT AN ADDRESS THE lockdownd CHECK CAN ACTUALLY ACCEPT.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE BUG THIS FIXES
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  The shipped IPv6 experiment numbers the loopback `fd00:7761:6e64:7272::1 / ::2` — a ULA (a
//  "unique local address", the IPv6 equivalent of 192.168.x.x: private, and belonging to no
//  interface unless something assigns it). The believed lockdownd rule composes two tests on the
//  SOURCE address of an incoming connection:
//
//      (1) it must fall inside the subnet of some interface that is NOT named `utun*`
//          (one `strncmp(ifa_name, "utun", 4)`), and
//      (2) it must NOT be an address the device itself holds.
//
//  A ULA is inside NO interface's subnet, so it fails (1) automatically. That is the SAME property
//  that makes 10.7.0.1 fail on iOS 26.4+. So the shipped experiment changed the address FAMILY while
//  keeping the address PLACEMENT wrong, and the rule reads placement. It could not have worked.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHY A CELLULAR IPv6 PREFIX IS THE ONE PLACE LEFT TO PUT IT
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  Measured on device, Wi-Fi off, hotspot on, every IPv4 address the phone can see is dead by one of
//  the two tests above:
//      pdp_ip0   10.186.34.129/32   ← a /32 has ONE member and the device holds it. Dead by (2).
//      pdp_ip2   10.18.53.198/32    ← same.
//      lo0       127.0.0.1/8        ← xnu drops 127/8 arriving on a non-IFF_LOOPBACK interface, and
//                                     a utun is not one. Structurally dead on any implementation.
//      bridge100 172.20.10.1/28     ← the only IPv4 room, and it was tested and refused.
//
//  The same dump shows the carrier hands out a real routable /64 per cellular interface:
//      pdp_ip0   2600:381:5b2a:1f7f:…/64   (two addresses, same prefix)
//
//  A /64 holds 2^64 addresses. An address inside it is inside a NON-utun subnet (passes 1) and is
//  held by nothing (passes 2) — which no IPv4 address on cellular can do. That is the whole reason
//  this file exists.
//
//  ⚠️ THIS IS AN UNKNOWN, NOT A KNOWN WIN. The published decompilation of the lockdownd routine
//  SNIPPED its IPv6-with-netmask branch as "not applicable", so nobody — here or publicly — knows
//  whether that branch does the same masked compare as the IPv4 one. Only a device test answers it.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT IT PICKS, AND WHY EACH CHOICE
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  • ROUTABLE ONLY. `fe80::/10` (link-local) is rejected even though every cellular interface has
//    one, because a link-local destination needs a `sin6_scope_id` and `DeviceConnectionContext
//    .makeSocketAddress` pins that to 0 — a scoped literal would be silently corrupted there (see
//    the M2 note in CellularIPv6Probe.swift). A global address needs no scope, so the existing dial
//    path carries it unchanged. `fc00::/7` (ULA) is rejected because that is the bug above.
//  • CELLULAR ONLY (`pdp_ip*`). The point of the experiment is the case where Wi-Fi is off. Wi-Fi
//    and the hotspot bridge are already served by the IPv4 planner (`TunnelIPPlanner`).
//  • A /126 IS DECLARED ON THE TUNNEL, NOT THE PARENT'S /64. Darwin routes by LONGEST MATCHING
//    PREFIX, so a /126 wins exactly the four addresses we carved and nothing else; the parent keeps
//    every other address in its /64 and the default route is excluded outright. Declaring the /64
//    would claim the identical prefix pdp_ip0 already owns — the same bug `TunnelIPPlanner` fixes on
//    the IPv4 side with a /30.
//  • THE DEVICE ADDRESS IS THE /126'S NETWORK ADDRESS. The provider builds its included route by
//    masking the host bits off, so an aligned device address makes the route destination EQUAL the
//    interface address — the same shape as the 10.7.0.0/24 default that demonstrably works.
//  • THE HOST PART IS A SIGNATURE, NOT A LOW NUMBER: `…:7761:6e64:6572:2dNN` is ASCII "wander-" plus
//    a counter. Far away from ::1/::2 (which routers and gateways use) and instantly recognisable in
//    a packet trace or a system log.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  CAN THIS BREAK THE PHONE'S OWN CELLULAR DATA? THE HONEST ANSWER
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  Read this before shipping the toggle to anyone. Three things bound the risk, and one thing is
//  genuinely unknown.
//
//  BOUNDED 1 — nothing we number ever leaves the phone. The provider swaps source and destination
//  and writes the packet straight back into the same interface. No packet carrying these addresses
//  is ever sourced onto pdp_ip0, so the carrier never sees them, never learns them, and has nothing
//  to object to. There is no neighbour discovery and no duplicate-address detection for them on the
//  cellular link, because they live on the utun and not on pdp_ip0.
//
//  BOUNDED 2 — the default route is explicitly excluded. `PacketTunnelProvider` sets
//  `excludedRoutes = [.default()]` on BOTH families, and the only included IPv6 route is the /126
//  computed from the pair. So `::/0` stays on pdp_ip0 and internet traffic is untouched. The tunnel
//  claims four addresses, not a prefix.
//
//  BOUNDED 3 — the four addresses are nobody's. 3GPP assigns a /64 per PDP context, to this device
//  alone, and the carrier gateway is reached over `fe80::` link-local (RFC 6459) rather than from
//  inside the subscriber's own prefix. So no carrier service lives at an address we could shadow.
//
//  THE REAL COST, stated plainly: while the tunnel is up, those four addresses are unreachable from
//  this device by any other means. That is the intended behaviour, and it is the entire footprint.
//
//  THE ROTATION CAVEAT: a carrier prefix is delegated, not owned. It changes on PDP re-establishment,
//  on a handover, and after Airplane Mode. The provider reads its addresses ONCE, in
//  `startTunnel(options:)`. After a rotation the tunnel is numbered in a prefix the phone no longer
//  holds, so the placement test fails again and the dial falls back to IPv4 — it does NOT break
//  connectivity, because the stale /126 points at four addresses in a prefix nothing on this phone
//  uses any more. Mitigation: the pair is re-derived on EVERY tunnel start, so a reconnect fixes it.
//
//  THE UNKNOWN, said loudly: what iOS's own routing and neighbour-discovery machinery does when a
//  utun claims a more-specific route inside an ACTIVE cellular prefix cannot be settled by reading
//  code. It is the one mechanism by which this could plausibly disturb cellular data. That is why
//  step 1 of the device test is "with the tunnel up, does a web page still load over cellular?" —
//  and why the answer to that question, not the tunnel result, decides whether this ships.
//
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE ARITHMETIC IS PURE AND HOST-TESTABLE, like TunnelIPPlanner's.
//  ─────────────────────────────────────────────────────────────────────────────────────────────
//  `CellularIPv6Carve` depends on nothing but Foundation, so it can be compiled and exercised on a
//  Mac against the exact prefix measured on the phone. Only the adapter below the
//  `#if !WANDER_V6_CARVE_STANDALONE` marker touches app types, and it reuses the app's ONE
//  `getifaddrs` enumerator (`WiFiSubnet.allAddresses()`) rather than adding a second one.
//

import Foundation

// MARK: - The pure part

/// Carves a pair of tunnel addresses out of a cellular interface's routable IPv6 prefix.
///
/// Deterministic and side-effect free: the same interface state always yields the same pair, which
/// is what lets the settings screen, the diagnostic dump and the tunnel start agree without any of
/// them storing the answer.
enum CellularIPv6Carve {

    /// Kernel name prefix for a cellular data interface. iOS numbers them `pdp_ip0`, `pdp_ip1`, …
    static let cellularInterfacePrefix = "pdp_ip"

    /// ASCII "wander-", written into the host part so a carved address is recognisable on sight.
    /// Occupies bytes 8…14; byte 15 is the counter. The last signature byte (`0x2D`) is deliberately
    /// non-zero, so even on a prefix longer than /64 — where the earlier signature bytes get masked
    /// away — the address is still far from the low addresses a gateway would use. That last byte is
    /// also the SALT: adding to it moves the whole search to a different /120, which is the only way
    /// out of a neighbourhood something else already occupies (see `carve`).
    static let hostSignature: [UInt8] = [0x77, 0x61, 0x6E, 0x64, 0x65, 0x72, 0x2D]

    /// How many /120 neighbourhoods the search may move through. Sixteen is far more than can ever
    /// be needed — the odds of even the first being occupied are astronomical — and it bounds the
    /// work at a few hundred byte comparisons.
    static let maximumSalt: UInt8 = 15

    /// What the tunnel DECLARES, for its own address and for its one included route. See the header:
    /// a /126 wins longest-prefix-match against the parent's /64 for exactly four addresses.
    static let declaredPrefixLength = 126

    /// Counters are tried 4 apart so the device address is always aligned to a /126 boundary, which
    /// makes the route destination the provider derives from it EQUAL the device address (no host
    /// bits set) — the shape the working IPv4 default already has.
    static let counterStride: UInt8 = 4
    static let firstCounter: UInt8 = 0x10
    static let lastCounter: UInt8 = 0xF0

    /// Shortest parent prefix worth carving. Anything shorter than a /16 is not a prefix a carrier
    /// delegates to a handset, and treating it as one would be inventing a fact.
    static let minimumParentPrefixLength = 16
    /// Longest parent prefix that still leaves the whole final byte free for the counter.
    static let maximumParentPrefixLength = 120

    /// The two carved addresses, as raw network-order bytes. Presentation is the adapter's job.
    struct Pair: Equatable, Sendable {
        /// Goes on the tunnel interface — the analogue of `TunnelInterfaceIP`.
        let device: [UInt8]
        /// The peer the app dials — and, after the provider swaps source and destination, the SOURCE
        /// address lockdownd inspects. This is the address the whole experiment is about.
        let fake: [UInt8]
    }

    /// Why no pair exists. Refusing is a real answer: proposing an address in the wrong prefix is
    /// exactly the mistake the ULA made.
    enum Refusal: Error, Equatable, Sendable {
        /// The address or mask was not 16 bytes.
        case malformed(name: String)
        /// Not a `pdp_ip*` interface.
        case notCellular(name: String)
        /// `getifaddrs` reported no netmask, so the lockdownd subnet compare could not match it either.
        case noNetmask(name: String)
        /// The mask is not a run of ones followed by zeros, so no "/n" describes it.
        case nonContiguousMask(name: String)
        /// Link-local, unique-local, loopback, multicast or unspecified — see `kind` for which.
        case notRoutable(name: String, kind: String)
        case prefixTooShort(name: String, prefixLength: Int)
        case prefixTooLong(name: String, prefixLength: Int)
        /// Every candidate collided with an address the device already holds.
        case everyCandidateCollides(name: String)

        /// One sentence, written for the person reading the Console rather than for an expert.
        var message: String {
            switch self {
            case .malformed(let name):
                return "\(name) reported an IPv6 address or netmask that was not 16 bytes long, so nothing could be derived from it."
            case .notCellular(let name):
                return "\(name) is not a cellular interface. This experiment only carves addresses out of a cellular prefix (pdp_ip0 and friends), because the whole point is the case where Wi-Fi is off."
            case .noNetmask(let name):
                return "\(name) has an IPv6 address but no netmask, so there is no subnet to place an address inside — and the lockdownd subnet test could not match it either."
            case .nonContiguousMask(let name):
                return "\(name)'s IPv6 netmask is not a contiguous run of ones, so no prefix length describes it and no safe address can be carved out of it."
            case .notRoutable(let name, let kind):
                return "\(name)'s address is \(kind), which this experiment cannot use. It needs a routable global address (2000::/3) — the kind a carrier hands out — because a link-local one would need an interface scope the dial path does not carry, and a private one belongs to no interface at all."
            case .prefixTooShort(let name, let prefixLength):
                return "\(name)'s prefix is /\(prefixLength), which is shorter than any prefix a carrier delegates to a phone. Treating it as one would be guessing."
            case .prefixTooLong(let name, let prefixLength):
                return "\(name)'s prefix is /\(prefixLength), which leaves too few free bits to place two addresses inside it."
            case .everyCandidateCollides(let name):
                return "Every candidate address inside \(name)'s prefix was already taken by this device. Nothing there is free to hand to the tunnel."
            }
        }
    }

    // MARK: The carve

    /// Derive the pair, or say why not.
    ///
    /// `held` is every IPv6 address on every NON-utun interface. Utun addresses are deliberately
    /// excluded, for a reason that matters on a RESTART: once the tunnel is up, the device address
    /// below is assigned to the utun, so counting utun addresses as "taken" would make this refuse
    /// the very pair it had just chosen and silently fall back to the ULA. The exclusion is also
    /// what the lockdownd rule itself does — its one name test is `strncmp(ifa_name, "utun", 4)`.
    /// The peer address is never assigned to anything, on any interface, which is the property test
    /// (2) actually reads.
    static func carve(interfaceName: String,
                      address: [UInt8],
                      mask: [UInt8]?,
                      held: Set<[UInt8]>) -> Result<Pair, Refusal> {

        guard interfaceName.hasPrefix(cellularInterfacePrefix) else {
            return .failure(.notCellular(name: interfaceName))
        }
        guard address.count == 16 else { return .failure(.malformed(name: interfaceName)) }
        guard let mask else { return .failure(.noNetmask(name: interfaceName)) }
        guard mask.count == 16 else { return .failure(.malformed(name: interfaceName)) }

        if let kind = nonRoutableKind(address) {
            return .failure(.notRoutable(name: interfaceName, kind: kind))
        }
        guard isContiguous(mask) else { return .failure(.nonContiguousMask(name: interfaceName)) }

        let prefix = leadingOnes(mask)
        guard prefix >= minimumParentPrefixLength else {
            return .failure(.prefixTooShort(name: interfaceName, prefixLength: prefix))
        }
        guard prefix <= maximumParentPrefixLength else {
            return .failure(.prefixTooLong(name: interfaceName, prefixLength: prefix))
        }

        let network = zip(address, mask).map { $0 & $1 }

        /// Prefix bits from the parent's network, host bits from our pattern. The mask is the only
        /// thing that decides which is which, so a carved address can never disturb the parent's
        /// prefix — it is inside the parent's subnet by construction, not by hope.
        func candidate(salt: UInt8, counter: UInt8) -> [UInt8] {
            var pattern = [UInt8](repeating: 0, count: 16)
            for (offset, byte) in hostSignature.enumerated() { pattern[8 + offset] = byte }
            pattern[14] = pattern[14] &+ salt
            pattern[15] = counter
            return (0..<16).map { network[$0] | (pattern[$0] & ~mask[$0]) }
        }

        // TWO PASSES, and the order is the whole design.
        //
        // Pass 1 wants MARGIN: a /120 neighbourhood (the address with its final byte free) in which
        // the device holds nothing at all. That is the "far from any address already present"
        // requirement — iOS keeps generating temporary privacy addresses on this same /64 and
        // rotating them, and a whole free byte of clearance means our pair is never merely one digit
        // away from something real.
        //
        // Pass 2 drops the margin and asks only what the lockdownd rule actually asks: is this
        // address one the device holds? Reaching pass 2 means every neighbourhood was occupied,
        // which cannot happen in practice — but a search that can fail entirely when a weaker answer
        // was available would be trading a working tunnel for tidiness.
        //
        // THE SALT IS WHY PASS 1 CAN SUCCEED AT ALL. An earlier version walked only the counter,
        // which varies the FINAL byte — the one byte the margin ignores — so every candidate shared
        // a neighbourhood and one occupied neighbourhood rejected all of them. The salt moves the
        // search to a different /120; the counter then picks a pair inside it.
        for requireMargin in [true, false] {
            var salt: UInt8 = 0
            while salt <= maximumSalt {
                defer { salt &+= 1 }
                // Every counter inside one salt shares bytes 0…14, so the margin is a property of the
                // neighbourhood and is tested once rather than 61 times.
                if requireMargin, !isNeighbourhoodFree(candidate(salt: salt, counter: 0), held: held) {
                    continue
                }
                var counter = firstCounter
                while counter <= lastCounter {
                    let device = candidate(salt: salt, counter: counter)
                    let fake = candidate(salt: salt, counter: counter &+ 1)
                    if !held.contains(device), !held.contains(fake) {
                        return .success(Pair(device: device, fake: fake))
                    }
                    counter &+= counterStride
                }
            }
        }
        return .failure(.everyCandidateCollides(name: interfaceName))
    }

    /// True when the device holds nothing that shares this address's first 15 bytes — i.e. its whole
    /// /120 is empty. See `carve` for why the margin is worth having and why it is not required.
    static func isNeighbourhoodFree(_ candidate: [UInt8], held: Set<[UInt8]>) -> Bool {
        guard candidate.count == 16 else { return false }
        for taken in held where taken.count == 16 {
            if taken[0..<15].elementsEqual(candidate[0..<15]) { return false }
        }
        return true
    }

    // MARK: Address classification

    /// Names why an address is unusable, or nil when it is a routable global unicast address.
    /// Returns a phrase that reads correctly in the middle of a sentence.
    static func nonRoutableKind(_ address: [UInt8]) -> String? {
        guard address.count == 16 else { return "not a 16-byte address" }
        if address.allSatisfy({ $0 == 0 }) { return "the unspecified address (::)" }
        if address[0] == 0xFF { return "a multicast address (ff00::/8)" }
        if address[0] == 0xFE, (address[1] & 0xC0) == 0x80 { return "a link-local address (fe80::/10)" }
        if (address[0] & 0xFE) == 0xFC { return "a private unique-local address (fc00::/7)" }
        if address.dropLast().allSatisfy({ $0 == 0 }), address[15] == 1 { return "the loopback address (::1)" }
        guard (address[0] & 0xE0) == 0x20 else { return "not a global unicast address (2000::/3)" }
        return nil
    }

    // MARK: Mask arithmetic

    /// Leading 1-bits across the mask — the "/n" of the prefix.
    static func leadingOnes(_ bytes: [UInt8]) -> Int {
        var n = 0
        for b in bytes {
            if b == 0xFF { n += 8 } else { n += (~b).leadingZeroBitCount; break }
        }
        return n
    }

    /// True when the mask is a run of ones followed by zeros. "/n" only means anything then.
    static func isContiguous(_ bytes: [UInt8]) -> Bool {
        var seenZero = false
        for b in bytes {
            if seenZero, b != 0 { return false }
            if b != 0xFF {
                let ones = (~b).leadingZeroBitCount
                // The rest of this byte must be zeros for the run to be contiguous.
                if b != UInt8(truncatingIfNeeded: (0xFF << (8 - ones)) & 0xFF) { return false }
                seenZero = true
            }
        }
        return true
    }

    /// Masks the host bits off, so a caller can check what an included route would actually cover.
    /// Present here rather than only in the provider so the claim "the route covers exactly four
    /// addresses" is testable on a Mac.
    static func networkAddress(_ address: [UInt8], prefixLength: Int) -> [UInt8]? {
        guard address.count == 16, prefixLength >= 0, prefixLength <= 128 else { return nil }
        var out = address
        for index in 0..<16 {
            let bitsBefore = index * 8
            if bitsBefore >= prefixLength {
                out[index] = 0
            } else if bitsBefore + 8 > prefixLength {
                let keep = prefixLength - bitsBefore
                out[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        return out
    }
}

// MARK: - Live interfaces (app target only)

#if !WANDER_V6_CARVE_STANDALONE

/// A concrete, checked proposal: two addresses inside a cellular carrier's routable prefix, plus
/// everything a reader needs to see WHY those two.
struct CellularIPv6TunnelPair: Sendable, Equatable {
    /// Goes on the tunnel interface — the analogue of `TunnelInterfaceIP`.
    let interfaceAddress: String
    /// The peer Wander dials — the analogue of `TunnelDeviceIP`, and the source address lockdownd
    /// sees after the provider's swap.
    let targetAddress: String
    /// What the tunnel declares for both its address and its one included route. Always 126.
    let prefixLength: Int
    /// The four addresses that /126 covers, as first–last, so "only the pair, never the /64" is
    /// visible rather than asserted.
    let routeFirstAddress: String
    let routeLastAddress: String
    /// The interface the prefix came from, and that prefix.
    let parentName: String
    let parentCIDR: String
    let parentPrefixLength: Int
    /// Plain-English reasons, safe to print straight into the Console.
    let notes: [String]

    /// One line for a settings row or a log label.
    var summary: String { "\(interfaceAddress) / \(targetAddress) · /\(prefixLength) from \(parentName)" }
}

enum CellularIPv6Suggester {

    /// The pair a tunnel started right now would use, or nil when this phone has no routable
    /// cellular IPv6 prefix to carve one out of.
    ///
    /// Reuses the app's ONE `getifaddrs` enumerator. Cheap enough to call from a settings screen's
    /// `onAppear` and from `WanderTunnel.start()`; it does no I/O beyond that single syscall.
    static func suggest(from entries: [NetworkInterfaceAddress]? = nil) -> CellularIPv6TunnelPair? {
        guard case .success(let pair) = plan(from: entries) else { return nil }
        return pair
    }

    /// Same thing, but it says why when there is nothing. Returns the FIRST refusal, which is the
    /// one about the interface a reader would most expect to have been used.
    static func plan(from entries: [NetworkInterfaceAddress]? = nil)
        -> Result<CellularIPv6TunnelPair, CellularIPv6Carve.Refusal> {

        let all = entries ?? WiFiSubnet.allAddresses()

        // Every IPv6 address on every NON-utun interface. See `CellularIPv6Carve.carve` for why the
        // utuns are left out — in short, one of them is our own previous device address.
        let held = Set(all
            .filter { $0.isIPv6 && !$0.isUtun && $0.addressBytes.count == 16 }
            .map(\.addressBytes))

        // pdp_ip0 before pdp_ip2. Two entries on the same interface share a prefix, so which of them
        // wins does not change the answer — the carve reads the NETWORK, not the host part.
        let candidates = all
            .filter { $0.isIPv6 && $0.isUp && !$0.isUtun && $0.name.hasPrefix(CellularIPv6Carve.cellularInterfacePrefix) }
            .sorted { $0.name < $1.name }

        guard !candidates.isEmpty else {
            return .failure(.notCellular(name: "no pdp_ip* interface"))
        }

        var firstRefusal: CellularIPv6Carve.Refusal?
        for entry in candidates {
            switch CellularIPv6Carve.carve(interfaceName: entry.name,
                                           address: entry.addressBytes,
                                           mask: entry.maskBytes,
                                           held: held) {
            case .success(let raw):
                if let built = build(raw, parent: entry) { return .success(built) }
            case .failure(let refusal):
                if firstRefusal == nil { firstRefusal = refusal }
            }
        }
        return .failure(firstRefusal ?? .notCellular(name: "no pdp_ip* interface"))
    }

    /// Console-ready lines for either outcome, matching `TunnelIPPlanner.explain`'s shape.
    static func explain(_ result: Result<CellularIPv6TunnelPair, CellularIPv6Carve.Refusal>) -> [String] {
        switch result {
        case .success(let p):
            var out = ["CELLULAR IPv6 PLAN: tunnel \(p.interfaceAddress) · dial \(p.targetAddress) · declare /\(p.prefixLength)",
                       "  from \(p.parentName) \(p.parentCIDR) · the included route covers \(p.routeFirstAddress)–\(p.routeLastAddress) and nothing else"]
            out.append(contentsOf: p.notes.map { "  • \($0)" })
            return out
        case .failure(let refusal):
            return ["CELLULAR IPv6 PLAN: none — \(refusal.message)"]
        }
    }

    // MARK: Presentation

    private static func build(_ raw: CellularIPv6Carve.Pair,
                              parent: NetworkInterfaceAddress) -> CellularIPv6TunnelPair? {
        let deviceText = WiFiSubnet.presentation(family: AF_INET6, bytes: raw.device)
        let fakeText = WiFiSubnet.presentation(family: AF_INET6, bytes: raw.fake)
        guard !deviceText.isEmpty, !fakeText.isEmpty else { return nil }

        let declared = CellularIPv6Carve.declaredPrefixLength
        // What the provider's included route will actually cover, computed the same way the provider
        // computes it, so the number shown to the owner is the number that will be installed.
        guard let routeBase = CellularIPv6Carve.networkAddress(raw.fake, prefixLength: declared) else { return nil }
        var routeLast = routeBase
        routeLast[15] |= 0x03
        let routeFirstText = WiFiSubnet.presentation(family: AF_INET6, bytes: routeBase)
        let routeLastText = WiFiSubnet.presentation(family: AF_INET6, bytes: routeLast)
        guard !routeFirstText.isEmpty, !routeLastText.isEmpty else { return nil }

        let parentPrefix = parent.maskBytes.map { CellularIPv6Carve.leadingOnes($0) } ?? 0

        var notes: [String] = []
        notes.append("\(fakeText) is the address Wander dials, and it is what the developer daemon sees as the connection's SOURCE after the tunnel swaps source and destination. It sits inside \(parent.name)'s \(parent.cidr ?? "prefix"), which is not a utun, and no interface on this phone holds it — the two things the believed lockdownd rule checks.")
        notes.append("the tunnel declares /\(declared), not /\(parentPrefix). Darwin picks a route by longest matching prefix, so a /\(declared) wins exactly \(routeFirstText)–\(routeLastText) and \(parent.name) keeps every other address in its /\(parentPrefix).")
        notes.append("the default route stays on \(parent.name): the tunnel excludes ::/0 outright, so nothing about normal cellular traffic changes.")
        notes.append("no packet carrying these addresses ever leaves the phone — the tunnel swaps source and destination and writes it straight back — so the carrier never sees them and nothing can collide on the cellular link.")
        notes.append("CAVEAT: a carrier prefix is delegated, not owned. It changes on a handover, a data reconnect, and after Airplane Mode. The tunnel reads its addresses once when it starts, so after a rotation it is numbered in a prefix this phone no longer has and the dial falls back to IPv4. Reconnect the tunnel to re-derive the pair.")
        notes.append("if the prefix rotates away, this phone keeps routing those four addresses into the tunnel until it restarts. That costs four addresses of somebody else's prefix and nothing else — the default route is untouched.")

        return CellularIPv6TunnelPair(interfaceAddress: deviceText,
                                      targetAddress: fakeText,
                                      prefixLength: declared,
                                      routeFirstAddress: routeFirstText,
                                      routeLastAddress: routeLastText,
                                      parentName: parent.name,
                                      parentCIDR: parent.cidr ?? "?",
                                      parentPrefixLength: parentPrefix,
                                      notes: notes)
    }
}

#endif
