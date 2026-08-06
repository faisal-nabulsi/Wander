//
//  main.swift
//  tools/tunnelipplan
//
//  OFFLINE PROOF OF THE TUNNEL-IP PLANNER. No device, no Xcode target, no NetworkExtension. Runs on
//  the Mac with plain swiftc:
//
//      swiftc -O -D WANDER_PLANNER_STANDALONE \
//             /Users/faisalnabulsi/Developer/wander-ios/Wander/Device/TunnelIPPlanner.swift \
//             /Users/faisalnabulsi/Developer/wander-ios/tools/tunnelipplan/main.swift \
//             -o /tmp/tunnelipplan && /tmp/tunnelipplan
//
//  UNLIKE tools/packetmath, NOTHING IS TRANSCRIBED HERE. The planner's arithmetic has no app
//  dependencies at all, so this compiles the SHIPPING FILE and exercises it directly — there is no
//  copy to go stale. The `-D WANDER_PLANNER_STANDALONE` flag excludes only the adapter at the bottom
//  of that file, the part that reads live interfaces through `WiFiSubnet.allAddresses()`.
//
//  WHAT IT PROVES: that for the four subnets actually measured on the device tonight, the planner
//  returns a mask NARROW ENOUGH TO WIN THE ROUTE (/30 — strictly longer than any parent prefix),
//  keeps both addresses inside the parent, never proposes the parent's own address, the parent's
//  network address, the parent's broadcast address, or any address the device already holds, and
//  REFUSES outright on a /32 point-to-point interface such as pdp_ip0.
//
//  WHAT IT DOES NOT PROVE: that iOS accepts these addresses on a utun, or that a packet sent to the
//  fake address reaches remotepairingd. Those are device facts and this is arithmetic.
//

import Foundation

// ============================================================================
// MARK: - Tiny check harness
// ============================================================================

var checks = 0
var failures: [String] = []

func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    let ok = condition()
    if !ok { failures.append(label) }
    print("   \(ok ? "PASS" : "FAIL")  \(label)")
}

func parse(_ s: String) -> UInt32 {
    guard let v = TunnelIPPlanner.parseDotted(s) else {
        fatalError("test input is not a dotted quad: \(s)")
    }
    return v
}

func subnet(_ name: String,
            _ address: String,
            _ mask: String,
            pointToPoint: Bool = false,
            loopback: Bool = false) -> TunnelParentSubnet {
    TunnelParentSubnet(name: name,
                       address: parse(address),
                       mask: parse(mask),
                       isPointToPoint: pointToPoint,
                       isLoopback: loopback)
}

/// The shared assertions every successful plan must satisfy, whatever the parent.
func assertWellFormed(_ plan: TunnelIPPlan, in parent: TunnelParentSubnet, held: Set<UInt32> = []) {
    let device = parse(plan.deviceIP)
    let fake = parse(plan.fakeIP)
    let mask = parse(plan.mask)

    check("\(parent.name): mask is 255.255.255.252 (/30)", plan.mask == "255.255.255.252" && plan.prefixLength == 30)
    check("\(parent.name): /30 is STRICTLY longer than the parent's /\(parent.prefixLength) — it wins longest-prefix-match",
          plan.prefixLength > parent.prefixLength)
    check("\(parent.name): the two addresses are adjacent", fake == device &+ 1)
    check("\(parent.name): both addresses are inside the parent subnet",
          (device & parent.mask) == parent.network && (fake & parent.mask) == parent.network)
    check("\(parent.name): both addresses are inside the /30 the mask describes",
          (device & mask) == (fake & mask))
    check("\(parent.name): neither address is the parent interface's OWN address (\(TunnelIPPlanner.dotted(parent.address)))",
          device != parent.address && fake != parent.address)
    check("\(parent.name): neither address is the parent's BROADCAST address (\(TunnelIPPlanner.dotted(parent.broadcast)))",
          device != parent.broadcast && fake != parent.broadcast)
    check("\(parent.name): neither address is the parent's NETWORK address (\(TunnelIPPlanner.dotted(parent.network)))",
          device != parent.network && fake != parent.network)
    check("\(parent.name): neither address is one the device already holds",
          !held.contains(device) && !held.contains(fake))
    check("\(parent.name): the device IP is the /30's network address, so the provider's included route has no host bits set",
          (device & mask) == device)
    check("\(parent.name): the returned mask is NOT the parent's own mask (the bug being fixed)",
          plan.mask != parent.maskText || parent.prefixLength == 30)
}

func show(_ title: String, _ result: Result<TunnelIPPlan, TunnelIPPlanRefusal>) {
    print("\n--------------------------------------------------------------------------------")
    print(title)
    print("--------------------------------------------------------------------------------")
    for line in TunnelIPPlanner.explain(result) { print(line) }
    print("")
}

print("""
================================================================================
 TUNNEL IP PLANNER — offline check against the subnets measured on device
================================================================================
""")

// ============================================================================
// MARK: - 1. The owner's Wi-Fi, exactly as getifaddrs reported it
// ============================================================================
//   en0  192.168.4.46  mask 255.255.252.0  subnet 192.168.4.0/22
// The OLD code proposed 192.168.4.240 / .241 with mask 255.255.252.0 — the identical /22 en0 owns.

let en0 = subnet("en0", "192.168.4.46", "255.255.252.0")
let en0Held: Set<UInt32> = [parse("192.168.4.46"), parse("127.0.0.1")]
let en0Result = TunnelIPPlanner.plan(in: en0, avoiding: en0Held, source: .wifi)
show("1. Wi-Fi — en0 192.168.4.46/22 (the network the bug was measured on)", en0Result)

if case .success(let p) = en0Result {
    assertWellFormed(p, in: en0, held: en0Held)
    check("en0: keeps the historical .240/.241 pair, so only the mask has to change in LocalDevVPN",
          p.deviceIP == "192.168.4.240" && p.fakeIP == "192.168.4.241")
    check("en0: the OLD mask 255.255.252.0 is reported alongside, so a log shows the fix",
          p.parentMask == "255.255.252.0")
} else {
    check("en0: a plan exists", false)
}

// ============================================================================
// MARK: - 2. Personal Hotspot — the only non-utun IPv4 subnet with room on cellular
// ============================================================================
//   bridge100  172.20.10.1  mask 255.255.255.240  subnet 172.20.10.0/28  BROADCAST
// Wi-Fi off. .0 is the network, .1 is the bridge itself, .15 is the broadcast; clients get .2 up.

let bridge = subnet("bridge100", "172.20.10.1", "255.255.255.240")
let bridgeHeld: Set<UInt32> = [parse("172.20.10.1"), parse("10.181.22.7"), parse("127.0.0.1")]
let bridgeResult = TunnelIPPlanner.plan(in: bridge, avoiding: bridgeHeld, source: .personalHotspot)
show("2. Personal Hotspot — bridge100 172.20.10.1/28 (Wi-Fi OFF, cellular backhaul)", bridgeResult)

if case .success(let p) = bridgeResult {
    assertWellFormed(p, in: bridge, held: bridgeHeld)
    check("bridge100: the .240 heuristic is correctly abandoned — 172.20.10.240 is outside a /28",
          p.deviceIP != "172.20.10.240")
    check("bridge100: the pair sits high in the /28, leaving the low addresses for hotspot clients",
          parse(p.deviceIP) >= parse("172.20.10.8"))
    check("bridge100: the plan is labelled as the hotspot fallback so the UI can say so",
          p.source == .personalHotspot)
    check("bridge100: the 90-second-with-no-client caveat travels with the plan",
          p.notes.contains { $0.contains("90 seconds") })
} else {
    check("bridge100: a plan exists", false)
}

// ============================================================================
// MARK: - 3. Loopback — arithmetic works, POLICY still says no
// ============================================================================
//   lo0  127.0.0.1  mask 255.0.0.0  subnet 127.0.0.0/8
// 127.x CAN be assigned to a utun; connecting to the utun's own 127.x gives EADDRNOTAVAIL (49).
// So the planner will carve it if ASKED, and `parents(from:)` never asks. Also the performance case:
// a /8 holds 4,194,304 /30s.

let lo0 = subnet("lo0", "127.0.0.1", "255.0.0.0", loopback: true)
let lo0Held: Set<UInt32> = [parse("127.0.0.1")]
let started = Date()
let lo0Result = TunnelIPPlanner.plan(in: lo0, avoiding: lo0Held, source: .explicit)
let elapsedMs = Date().timeIntervalSince(started) * 1000
show("3. Loopback — lo0 127.0.0.1/8 (planned only when asked directly; never selected)", lo0Result)

if case .success(let p) = lo0Result {
    assertWellFormed(p, in: lo0, held: lo0Held)
    check("lo0: a /8 parent is answered in under 50 ms — the search is lazy, not 4.2 million blocks (took \(String(format: "%.2f", elapsedMs)) ms)",
          elapsedMs < 50)
} else {
    check("lo0: a plan exists when asked directly", false)
}

// ============================================================================
// MARK: - 4. Cellular — a /32 point-to-point interface, which must be REFUSED
// ============================================================================
//   pdp_ip0  10.181.22.7  mask 255.255.255.255  POINTOPOINT

let pdp = subnet("pdp_ip0", "10.181.22.7", "255.255.255.255", pointToPoint: true)
let pdpResult = TunnelIPPlanner.plan(in: pdp, avoiding: [parse("10.181.22.7")], source: .explicit)
show("4. Cellular — pdp_ip0 10.181.22.7/32 POINTOPOINT (must refuse)", pdpResult)

switch pdpResult {
case .success(let p):
    check("pdp_ip0: REFUSED", false)
    print("      (it wrongly proposed \(p.deviceIP) / \(p.fakeIP))")
case .failure(let r):
    check("pdp_ip0: refused, and refused as point-to-point rather than by accident",
          r == .pointToPointParent(name: "pdp_ip0", cidr: "10.181.22.7/32"))
    check("pdp_ip0: the refusal explains itself without this file open",
          r.message.contains("one member"))
}

// A /32 WITHOUT the point-to-point flag must refuse for the same reason — the flag is a hint, the
// prefix is the fact.
let pdpNoFlag = subnet("pdp_ip2", "10.181.22.9", "255.255.255.255")
if case .failure(let r) = TunnelIPPlanner.plan(in: pdpNoFlag, source: .explicit) {
    check("a /32 with no POINTOPOINT flag is refused on the prefix alone",
          r == .pointToPointParent(name: "pdp_ip2", cidr: "10.181.22.9/32"))
} else {
    check("a /32 with no POINTOPOINT flag is refused on the prefix alone", false)
}

// ============================================================================
// MARK: - 5. Edge cases the four real subnets do not cover
// ============================================================================
print("\n--------------------------------------------------------------------------------")
print("5. Edge cases")
print("--------------------------------------------------------------------------------")

// 5a. A textbook home /24 — the case the OLD code got right by luck. The addresses must not move,
//     because thousands of users have them typed into LocalDevVPN already.
let home = subnet("en0", "192.168.1.50", "255.255.255.0")
if case .success(let p) = TunnelIPPlanner.plan(in: home, avoiding: [parse("192.168.1.50")], source: .wifi) {
    check("home /24: still 192.168.1.240 / .241 — only the mask changes (255.255.255.0 → 255.255.255.252)",
          p.deviceIP == "192.168.1.240" && p.fakeIP == "192.168.1.241" && p.mask == "255.255.255.252")
    assertWellFormed(p, in: home, held: [parse("192.168.1.50")])
} else {
    check("home /24: a plan exists", false)
}

// 5b. The phone itself is sitting on .240. The traditional block must be abandoned.
let collide = subnet("en0", "192.168.1.241", "255.255.255.0")
if case .success(let p) = TunnelIPPlanner.plan(in: collide, avoiding: [parse("192.168.1.241")], source: .wifi) {
    check("own address inside the .240 block: the planner moves off it",
          parse(p.deviceIP) < parse("192.168.1.240") || parse(p.deviceIP) > parse("192.168.1.243"))
    check("own address inside the .240 block: it does not fall back onto the broadcast block either",
          parse(p.fakeIP) != parse("192.168.1.255") && parse(p.deviceIP) != parse("192.168.1.252"))
    assertWellFormed(p, in: collide, held: [parse("192.168.1.241")])
} else {
    check("own address inside the .240 block: a plan still exists", false)
}

// 5c. A held address (e.g. another utun) sitting in the .240 block must push the plan elsewhere.
let heldInBlock: Set<UInt32> = [parse("192.168.1.50"), parse("192.168.1.242")]
if case .success(let p) = TunnelIPPlanner.plan(in: home, avoiding: heldInBlock, source: .wifi) {
    check("an address the device already holds inside the .240 block pushes the plan off it",
          p.deviceIP != "192.168.1.240")
    assertWellFormed(p, in: home, held: heldInBlock)
} else {
    check("an address the device already holds inside the .240 block still yields a plan", false)
}

// 5d. /29 and /30 parents have no interior block at all.
for (mask, prefix) in [("255.255.255.248", 29), ("255.255.255.252", 30)] {
    let tiny = subnet("en0", "10.0.0.1", mask)
    if case .failure(let r) = TunnelIPPlanner.plan(in: tiny, source: .wifi) {
        check("a /\(prefix) parent is refused as too small",
              r == .parentTooSmall(name: "en0", cidr: "10.0.0.0/\(prefix)", prefixLength: prefix))
    } else {
        check("a /\(prefix) parent is refused as too small", false)
    }
}

// 5e. A /28 is the tightest parent that still works — one address wider than the refusal boundary,
//     and exactly what a Personal Hotspot gives.
let tightest = subnet("bridge100", "172.20.10.1", "255.255.255.240")
check("/28 is the tightest parent that still yields a plan",
      { if case .success = TunnelIPPlanner.plan(in: tightest, source: .personalHotspot) { return true }; return false }())

// 5f. A non-contiguous mask is refused rather than silently described as a /n.
let weird = TunnelParentSubnet(name: "en0", address: parse("192.168.1.50"), mask: 0xFF00_FF00)
if case .failure(let r) = TunnelIPPlanner.plan(in: weird, source: .wifi) {
    check("a non-contiguous netmask is refused, not silently rounded to a /n",
          r == .nonContiguousMask(name: "en0", mask: "255.0.255.0"))
} else {
    check("a non-contiguous netmask is refused, not silently rounded to a /n", false)
}

// 5g. The alternate placement, kept for a device comparison.
if case .success(let p) = TunnelIPPlanner.plan(in: en0, avoiding: en0Held, placement: .firstTwoHosts, source: .wifi) {
    check("firstTwoHosts placement yields the two real hosts of the same /30 (.241/.242)",
          p.deviceIP == "192.168.4.241" && p.fakeIP == "192.168.4.242")
} else {
    check("firstTwoHosts placement yields a plan", false)
}

// 5h. Address arithmetic sanity — the parser is stricter than inet_pton on purpose.
check("parseDotted rejects short forms inet_pton would accept (\"10.1\")", TunnelIPPlanner.parseDotted("10.1") == nil)
check("parseDotted rejects out-of-range octets (\"192.168.1.256\")", TunnelIPPlanner.parseDotted("192.168.1.256") == nil)
check("parseDotted round-trips", TunnelIPPlanner.dotted(parse("192.168.4.240")) == "192.168.4.240")
check("prefixLength(255.255.252.0) == 22", TunnelIPPlanner.prefixLength(ofMask: parse("255.255.252.0")) == 22)
check("prefixLength(255.255.255.255) == 32", TunnelIPPlanner.prefixLength(ofMask: parse("255.255.255.255")) == 32)
check("prefixLength(0.0.0.0) == 0", TunnelIPPlanner.prefixLength(ofMask: 0) == 0)

// ============================================================================
print("""

================================================================================
 RESULT: \(checks - failures.count)/\(checks) checks passed
================================================================================
""")
if failures.isEmpty {
    print("""
 THE PLANNER IS CORRECT ON EVERY SUBNET MEASURED ON DEVICE. On the owner's own Wi-Fi it returns the
 SAME two addresses the old button did — 192.168.4.240 / .241 — with mask 255.255.255.252 instead of
 255.255.252.0, so the tunnel now claims a four-address /30 instead of re-claiming the identical /22
 en0 already owns. With Wi-Fi off it falls back to the Personal Hotspot bridge, the only non-utun
 IPv4 subnet with room on a cellular-only phone. It refuses pdp_ip0 outright.

 THIS IS ARITHMETIC, NOT A DEVICE RESULT. Still unverified on hardware:
   1. that iOS accepts a /30 on the utun and installs the route (getifaddrs after connecting says so).
   2. that the /30 actually WINS the route against en0's /22 — the observable is that a dial to the
      fake address reaches the provider's readPackets at all.
   3. that a device IP equal to the /30's NETWORK address is accepted. The working 10.7.0.0/24
      default has that same shape, which is the reason to expect yes.
 All three are testable TODAY through LocalDevVPN's working tunnel by typing these values into its
 Device IP / Tunnel IP fields — no Wander build required.
""")
    exit(0)
} else {
    print(" FAILURES:")
    for f in failures { print("   - \(f)") }
    exit(1)
}
