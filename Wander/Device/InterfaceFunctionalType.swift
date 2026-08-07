//
//  InterfaceFunctionalType.swift
//  Wander
//
//  IS THE TUNNEL'S utun CELLULAR AS FAR AS THE KERNEL IS CONCERNED? Measured, once, on the phone.
//
//  WHY THIS EXISTS. The cellular investigation ended on this chain:
//
//    1. `remotepairingdeviced` applies, unconditionally, to every listening socket launchd hands it
//       `setsockopt(fd, SOL_SOCKET, SO_RESTRICTIONS, &{SO_RESTRICT_DENY_CELLULAR}, 4)`. XNU's own
//       header calls that option a "trapdoor" — once set it is never unsettable.
//    2. The kernel then does, inside `in_pcblookup_hash_locked()`:
//           if (inp_restricted_recv(inp, ifp)) { continue; }
//       i.e. a restricted listener is SKIPPED BY THE LOOKUP for a packet arriving on a cellular
//       interface — made invisible — so TCP takes the "no such port" path and emits an instant RST.
//    3. That matches the measurement exactly: errno 61 ECONNREFUSED at 0-1 ms on cellular, CONNECTED
//       in Airplane Mode, CONNECTED to 127.0.0.1 in both.
//
//  Step 2 is only about "a packet arriving on a cellular interface", and our packet arrives on a
//  utun, which is not a modem. The link that closes the chain is XNU's macro:
//
//        #define IFNET_IS_CELLULAR(_ifp)                                 \
//            ((_ifp)->if_type == IFT_CELLULAR ||                         \
//             ((_ifp)->if_delegated.type == IFT_CELLULAR))
//
//  — a utun DELEGATED to the cellular interface counts as cellular to the kernel. Nobody has ever
//  measured whether Wander's utun carries that delegate. This file measures it. If it comes back
//  cellular the chain is closed end to end; if it does not, the mechanism story is wrong (the
//  OUTCOME is unchanged either way, because NetworkExtension exposes no API to set or clear a
//  delegate).
//
//  HOW IT MEASURES. `ioctl(SIOCGIFFUNCTIONALTYPE)`. In XNU that ioctl answers with
//  `if_functional_type(ifp, /* exclude_delegate */ FALSE)` — the delegate-INCLUSIVE form — whose
//  cellular branch is `IFNET_IS_CELLULAR(ifp)`, the macro above. See `delegateNotes` at the bottom
//  for why that makes it the closest available proxy for a direct `if_delegated` read, and why this
//  file deliberately does NOT guess at the private `SIOCGIFDELEGATE` request number.
//
//  SAFETY. Read-only in the strictest sense. It opens one unbound, unconnected `AF_INET SOCK_DGRAM`
//  socket purely as a handle to hang the ioctl off — the standard way to issue an interface ioctl —
//  and closes it. It connects to nothing, dials no daemon, writes no preference, and never touches
//  the tunnel. `SIOCGIFFUNCTIONALTYPE` is a `SIOCG*` getter; the only thing it modifies is the
//  caller's own `struct ifreq`.
//
//  BLOCKING-ish. One ioctl per interface is microseconds, but the optional Network.framework
//  cross-check waits up to 2 s. Call it off the main thread like every other probe here.
//

import Foundation
import Darwin
import Network

enum InterfaceFunctionalType {

    // MARK: - The ioctl request number, rebuilt rather than hardcoded

    /// `SIOCGIFFUNCTIONALTYPE`, i.e. `_IOWR('i', 173, struct ifreq)`.
    ///
    /// The macro IS in the public SDK — `iPhoneOS.sdk/usr/include/sys/sockio.h`:
    ///
    ///     #define SIOCGIFFUNCTIONALTYPE   _IOWR('i', 173, struct ifreq)
    ///
    /// but Clang refuses to import it into Swift ("macro 'SIOCGIFFUNCTIONALTYPE' unavailable:
    /// structure not supported" — `_IOWR` expands to an expression containing `sizeof`). So it is
    /// rebuilt here from the SDK's OWN pieces rather than pasted in as a magic number: `IOC_INOUT`
    /// and `IOCPARM_MASK` come from `sys/ioccom.h`, the length comes from `MemoryLayout<ifreq>.size`
    /// (the real imported `struct ifreq`, not a guess), and only the group `'i'` and the number `173`
    /// are read off the header line above.
    ///
    /// Verified against the SDK at build time by a `_Static_assert` in C: this evaluates to
    /// 0xC02069AD, byte-for-byte what the macro produces.
    static let request: UInt = {
        let length = UInt(MemoryLayout<ifreq>.size) & UInt(IOCPARM_MASK)
        return UInt(IOC_INOUT) | (length << 16) | (UInt(UInt8(ascii: "i")) << 8) | 173
    }()

    /// One line for the log saying where the number came from, so a reader never has to trust it.
    static var requestProvenance: String {
        let hex = String(request, radix: 16, uppercase: true)
        return "ioctl SIOCGIFFUNCTIONALTYPE = 0x\(hex) — rebuilt as _IOWR('i', 173, struct ifreq) from the iPhoneOS SDK's own IOC_INOUT/IOCPARM_MASK and MemoryLayout<ifreq>.size = \(MemoryLayout<ifreq>.size). The SDK has the macro (sys/sockio.h) but Clang will not import it into Swift, so it is derived, not pasted."
    }

    /// The documented values, straight out of `net/if.h`, printed once so nobody has to look them up.
    static var valueLegend: String {
        "values: 0 UNKNOWN · 1 LOOPBACK · 2 WIRED · 3 WIFI_INFRA · 4 WIFI_AWDL · 5 CELLULAR · 6 INTCOPROC · 7 COMPANIONLINK · 8 MANAGEMENT"
    }

    /// `IFRTYPE_FUNCTIONAL_*` → name. Built with `uniquingKeysWith` for the same reason
    /// `EndpointProbe.names` is: a dictionary literal with two equal keys traps at runtime, and a
    /// diagnostic must never be able to crash the app it is diagnosing.
    private static let typeNames: [UInt32: String] = Dictionary(
        [
            (UInt32(IFRTYPE_FUNCTIONAL_UNKNOWN), "UNKNOWN"),
            (UInt32(IFRTYPE_FUNCTIONAL_LOOPBACK), "LOOPBACK"),
            (UInt32(IFRTYPE_FUNCTIONAL_WIRED), "WIRED"),
            (UInt32(IFRTYPE_FUNCTIONAL_WIFI_INFRA), "WIFI_INFRA"),
            (UInt32(IFRTYPE_FUNCTIONAL_WIFI_AWDL), "WIFI_AWDL"),
            (UInt32(IFRTYPE_FUNCTIONAL_CELLULAR), "CELLULAR"),
            (UInt32(IFRTYPE_FUNCTIONAL_INTCOPROC), "INTCOPROC"),
            (UInt32(IFRTYPE_FUNCTIONAL_COMPANIONLINK), "COMPANIONLINK"),
            (UInt32(IFRTYPE_FUNCTIONAL_MANAGEMENT), "MANAGEMENT")
        ],
        uniquingKeysWith: { first, _ in first }
    )

    static let cellularValue = UInt32(IFRTYPE_FUNCTIONAL_CELLULAR)   // 5
    static let loopbackValue = UInt32(IFRTYPE_FUNCTIONAL_LOOPBACK)   // 1

    static func typeName(_ raw: UInt32) -> String {
        typeNames[raw] ?? "UNDOCUMENTED-VALUE"
    }

    // MARK: - One reading

    /// What the kernel said about one interface.
    struct Reading: Sendable {
        let name: String
        /// The functional type, or nil when the ioctl itself failed.
        let raw: UInt32?
        /// errno from a failed ioctl. 0 on success.
        let failureErrno: Int32

        var isReadable: Bool { raw != nil }

        /// `5 CELLULAR`, or a readable failure.
        var display: String {
            guard let raw else {
                return "-- unreadable (ioctl failed: errno \(failureErrno) \(EndpointProbe.errnoName(failureErrno)))"
            }
            return "\(raw) \(InterfaceFunctionalType.typeName(raw))"
        }

        var isCellular: Bool { raw == InterfaceFunctionalType.cellularValue }
    }

    /// Ask the kernel for one interface's functional type.
    ///
    /// The socket is a bare unbound UDP socket used only as an ioctl handle. It is never bound, never
    /// connected, and is closed before this returns.
    static func read(_ interfaceName: String) -> Reading {
        // An interface name must fit in IFNAMSIZ including its NUL. A longer one cannot exist, so
        // rejecting it here is not a limitation — it just means the caller handed us something bogus.
        guard interfaceName.utf8.count > 0, interfaceName.utf8.count < Int(IFNAMSIZ) else {
            return Reading(name: interfaceName, raw: nil, failureErrno: EINVAL)
        }

        var fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { fd = socket(AF_INET6, SOCK_DGRAM, 0) }   // an IPv6-only phone still has this one
        guard fd >= 0 else {
            return Reading(name: interfaceName, raw: nil, failureErrno: errno)
        }
        defer { close(fd) }

        var ifr = ifreq()
        withUnsafeMutableBytes(of: &ifr.ifr_name) { raw in
            raw.copyBytes(from: interfaceName.utf8.prefix(raw.count - 1))
        }

        guard ioctl(fd, request, &ifr) == 0 else {
            return Reading(name: interfaceName, raw: nil, failureErrno: errno)
        }
        return Reading(name: interfaceName, raw: ifr.ifr_ifru.ifru_functional_type, failureErrno: 0)
    }

    // MARK: - Every interface on the phone

    /// Every interface name, in a stable order: the ones `getifaddrs` reports (kernel order, and the
    /// only ones that have an IP address) first, then any remaining name from `if_nameindex`.
    ///
    /// WHY BOTH. `getifaddrs` only lists interfaces that HOLD an address, and the question here is
    /// about interfaces, not addresses — an interface with no IP still has a functional type, and a
    /// utun that exists but has not been configured yet is exactly the kind of thing worth seeing.
    /// `if_nameindex` lists them all. Neither call opens a socket to anything.
    static func allInterfaceNames() -> (withAddresses: [String], addressless: [String]) {
        var ordered: [String] = []
        var seen = Set<String>()
        for entry in WiFiSubnet.allAddresses() where !seen.contains(entry.name) {
            seen.insert(entry.name)
            ordered.append(entry.name)
        }

        var extra: [String] = []
        if let list = if_nameindex() {
            defer { if_freenameindex(list) }
            var p = list
            while p.pointee.if_index != 0 || p.pointee.if_name != nil {
                guard let raw = p.pointee.if_name else { break }
                let name = String(cString: raw)
                if !name.isEmpty, !seen.contains(name) {
                    seen.insert(name)
                    extra.append(name)
                }
                p = p.advanced(by: 1)
            }
        }
        return (ordered, extra)
    }

    // MARK: - Which utun is ours

    /// The interfaces that hold an address Wander's tunnel was configured with, plus the label of the
    /// address that identified them.
    ///
    /// Identified by ADDRESS, never by name — `InterfaceScope.owner(of:)` is the same helper
    /// `SocketInterfaceBinding` already uses, and it is right for the same reason: the app owns the
    /// number it configured the tunnel with, and BSD interface names are not API. A phone can carry
    /// half a dozen utuns (iCloud Private Relay, a corporate VPN, LocalDevVPN, ours) and guessing
    /// among them would produce a confidently wrong answer.
    static func tunnelInterfaceNames() -> [(name: String, via: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()

        func consider(_ label: String, _ address: String) {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let owner = InterfaceScope.owner(of: trimmed) else { return }
            let key = "\(owner.name)|\(trimmed)"
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append((owner.name, "\(label) \(trimmed)"))
        }

        let defaults = UserDefaults.standard
        // Read the key directly, exactly as NetworkInterfaceDump and TunnelEndpointSweep do, so the
        // interface named in this log is the one matching the number on disk.
        consider("TunnelInterfaceIP",
                 defaults.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0")
        // The far end is on the same utun, and after a manual address edit it is sometimes the only
        // one of the pair that resolves, so it is worth asking about too.
        consider("tunnel target IP", DeviceConnectionContext.targetIPAddress)

        if defaults.bool(forKey: UserDefaults.Keys.useIPv6TunnelLoopback) {
            consider("running tunnel IPv6 interface address", DeviceConnectionContext.activeTunnelInterfaceIPv6)
            let planned = DeviceConnectionContext.plannedIPv6Loopback()
            consider("planned tunnel IPv6 interface address", planned.interfaceAddress)
        }
        return out
    }

    // MARK: - The report

    /// Read every interface, print the table, check the controls, and state the verdict.
    ///
    /// Returns the whole report as one string (the Tunnel Lab shows it verbatim) and also writes it
    /// into the app Console through `LogManager`, retained the same way the interface dump is so that
    /// opening the Console cannot wipe it.
    static func runAndSummarize(reason: String = "manual") -> String {
        let addressEntries = WiFiSubnet.allAddresses()
        let (named, addressless) = allInterfaceNames()

        var readings: [String: Reading] = [:]
        for name in named + addressless { readings[name] = read(name) }

        let tunnels = tunnelInterfaceNames()
        let tunnelNames = Set(tunnels.map(\.name))

        var lines: [String] = []
        lines.append("=== INTERFACE FUNCTIONAL TYPE === reason: \(reason)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(named.count + addressless.count) interface(s)")
        lines.append(requestProvenance)
        lines.append(valueLegend)
        lines.append("")
        lines.append(contentsOf: whichUtunLines(tunnels))
        lines.append("")
        lines.append(contentsOf: tableLines(named: named,
                                            addressless: addressless,
                                            entries: addressEntries,
                                            readings: readings,
                                            tunnelNames: tunnelNames))
        lines.append("")

        let controls = controlCheck(readings: readings)
        lines.append(contentsOf: controls.lines)
        lines.append("")
        lines.append(contentsOf: stateLines(addressEntries))
        lines.append("")
        lines.append(contentsOf: verdictLines(tunnels: tunnels,
                                              readings: readings,
                                              controls: controls,
                                              named: named + addressless))
        lines.append("")
        lines.append(contentsOf: differentialLines(readings: readings,
                                                   named: named + addressless,
                                                   tunnelNames: tunnelNames))
        lines.append("")
        lines.append(contentsOf: delegateNotes())
        lines.append("")
        lines.append(contentsOf: networkFrameworkCrossCheck())
        lines.append("=== END INTERFACE FUNCTIONAL TYPE ===")

        for line in lines { LogManager.shared.addInfoLog(line) }
        NetworkInterfaceDump.retain(lines)

        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces of the report

    private static func whichUtunLines(_ tunnels: [(name: String, via: String)]) -> [String] {
        guard !tunnels.isEmpty else {
            let configured = UserDefaults.standard.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
            return [
                "WHICH utun IS THE TUNNEL: NOT IDENTIFIED — no interface on this phone holds the configured tunnel address \(configured).",
                "  That normally means the tunnel is not running. Start it, then run this again; the rest of the table below is still valid."
            ]
        }
        var out = ["WHICH utun IS THE TUNNEL: identified by ADDRESS, not by name —"]
        for t in tunnels {
            out.append("  \(t.name) holds \(t.via) → marked <<< TUNNEL in the table.")
        }
        out.append("  (Whichever app created that utun. If LocalDevVPN is providing the tunnel, this is still the interface Wander's packets ride.)")
        return out
    }

    private static func tableLines(named: [String],
                                   addressless: [String],
                                   entries: [NetworkInterfaceAddress],
                                   readings: [String: Reading],
                                   tunnelNames: Set<String>) -> [String] {
        var out: [String] = []
        out.append("INTERFACES — name / functional type / addresses")
        out.append("  \(pad("iface", 12)) \(pad("type", 18)) addresses")
        out.append("  \(String(repeating: "-", count: 12)) \(String(repeating: "-", count: 18)) ---------")

        func row(_ name: String, addressText: String) -> String {
            let reading = readings[name] ?? Reading(name: name, raw: nil, failureErrno: ENXIO)
            var line = "  \(pad(name, 12)) \(pad(reading.display, 18)) \(addressText)"
            if name == "lo0" { line += "   [CONTROL: must be 1 LOOPBACK]" }
            if name.hasPrefix("pdp_ip") { line += "   [CONTROL: must be 5 CELLULAR]" }
            if tunnelNames.contains(name) { line += "   <<< TUNNEL — the row this whole test is about" }
            return line
        }

        for name in named {
            let addresses = entries.filter { $0.name == name }.map { entry -> String in
                let base = entry.address.isEmpty ? "<unreadable>" : entry.address
                if let p = entry.prefixLength { return "\(base)/\(p)" }
                return base
            }
            out.append(row(name, addressText: addresses.isEmpty ? "(no IP address)" : addresses.joined(separator: ", ")))
        }
        for name in addressless {
            out.append(row(name, addressText: "(no IP address — exists, but getifaddrs lists nothing on it)"))
        }
        return out
    }

    private struct ControlResult {
        let passed: Bool
        let incomplete: Bool
        let lines: [String]
    }

    /// The controls ARE the point. The utun answer is worth nothing unless the two interfaces whose
    /// answers are known in advance come back right.
    private static func controlCheck(readings: [String: Reading]) -> ControlResult {
        var out: [String] = []
        var failures: [String] = []
        var missing: [String] = []

        // lo0 — always present, always LOOPBACK.
        if let lo = readings["lo0"], let raw = lo.raw {
            if raw == loopbackValue {
                out.append("  CONTROL \(pad("lo0", 10)) = \(raw) \(typeName(raw))  — expected 1 LOOPBACK  ✓")
            } else {
                out.append("  CONTROL \(pad("lo0", 10)) = \(raw) \(typeName(raw))  — expected 1 LOOPBACK  ✗ WRONG")
                failures.append("lo0 answered \(raw) \(typeName(raw)), not 1 LOOPBACK")
            }
        } else {
            out.append("  CONTROL \(pad("lo0", 10)) = \(readings["lo0"]?.display ?? "not present at all")  — expected 1 LOOPBACK  ✗ COULD NOT READ")
            failures.append("lo0 could not be read")
        }

        // pdp_ip0 — the cellular data interface. Absent in Airplane Mode / with cellular data off,
        // which is a DIFFERENT thing from answering wrongly, and is reported as such.
        let cellularNames = readings.keys.filter { $0.hasPrefix("pdp_ip") }.sorted()
        if cellularNames.isEmpty {
            out.append("  CONTROL \(pad("pdp_ip0", 10)) = not present  — expected 5 CELLULAR  ⚠︎ CONTROL NOT RUN")
            missing.append("pdp_ip0 does not exist on this phone right now (Airplane Mode, or cellular data off)")
        } else {
            for name in cellularNames {
                let reading = readings[name]!
                if let raw = reading.raw, raw == cellularValue {
                    out.append("  CONTROL \(pad(name, 10)) = \(raw) \(typeName(raw))  — expected 5 CELLULAR  ✓")
                } else {
                    out.append("  CONTROL \(pad(name, 10)) = \(reading.display)  — expected 5 CELLULAR  ✗ WRONG")
                    failures.append("\(name) answered \(reading.display), not 5 CELLULAR")
                }
            }
        }

        var header: [String]
        if !failures.isEmpty {
            header = [
                "CONTROLS FAILED — \(failures.joined(separator: "; ")).",
                "  The ioctl is NOT being called correctly, so the tunnel row means NOTHING. DISREGARD the utun answer and the verdict below."
            ]
        } else if !missing.isEmpty {
            header = [
                "CONTROLS INCOMPLETE — \(missing.joined(separator: "; ")).",
                "  The loopback control passed, so the ioctl works. But the CELLULAR control could not be run, and this whole test is about a phone that is ON CELLULAR WITH WI-FI OFF. Re-run it in that state before believing the verdict."
            ]
        } else {
            header = [
                "CONTROLS PASSED — every interface whose answer was known in advance came back right.",
                "  The ioctl is being called correctly, so the tunnel row below can be trusted."
            ]
        }
        return ControlResult(passed: failures.isEmpty && missing.isEmpty,
                             incomplete: failures.isEmpty && !missing.isEmpty,
                             lines: header + out)
    }

    /// Was the phone even in the failing state when this was taken? A reading with Wi-Fi on answers a
    /// question nobody asked.
    private static func stateLines(_ entries: [NetworkInterfaceAddress]) -> [String] {
        let wifi = entries.filter { $0.name == "en0" && $0.isIPv4 && $0.isUp && !$0.address.isEmpty }
        let cellular = entries.filter { $0.name.hasPrefix("pdp_ip") && $0.isUp && !$0.address.isEmpty }

        var out: [String] = []
        if let w = wifi.first {
            out.append("STATE: Wi-Fi is ON — en0 holds \(w.address). The claim under test is about the phone WITH WI-FI OFF on cellular, so re-run this in that state for the answer that matters.")
        } else {
            out.append("STATE: no IPv4 address on en0 — Wi-Fi is off or not associated. Good: this is the state the question is about.")
        }
        if cellular.isEmpty {
            out.append("STATE: no cellular address (pdp_ip*) — the modem is not carrying data right now.")
        } else {
            out.append("STATE: cellular is up — " + cellular.map { "\($0.name) \($0.address)" }.joined(separator: ", "))
        }
        return out
    }

    private static func verdictLines(tunnels: [(name: String, via: String)],
                                     readings: [String: Reading],
                                     controls: ControlResult,
                                     named: [String]) -> [String] {
        guard let tunnel = tunnels.first else {
            return ["VERDICT: no interface holds Wander's configured tunnel address, so there is no utun to judge. Start the tunnel and run this again. Nothing is proved or disproved by this run."]
        }
        guard let reading = readings[tunnel.name], let raw = reading.raw else {
            return ["VERDICT: the tunnel interface \(tunnel.name) was found, but the kernel would not answer for it (\(readings[tunnel.name]?.display ?? "no reading")). No verdict."]
        }

        var out: [String] = []

        if raw == cellularValue {
            out.append("VERDICT: Wander's tunnel \(tunnel.name) reports functional type 5 (CELLULAR) — it IS cellular-delegated, so the kernel treats packets arriving on it as cellular and hides the developer-tunnel listener from them. Chain closed.")
            out.append("  In plain words: our own tunnel is wearing the modem's badge. The daemon's listening socket said \"deny cellular\", the kernel therefore skips it for anything wearing that badge, and the connect gets an instant refusal instead of an answer. That is the whole mechanism, now measured rather than assumed.")
        } else {
            out.append("VERDICT: Wander's tunnel \(tunnel.name) reports functional type \(raw) (\(typeName(raw))), NOT 5 (CELLULAR) — it is NOT cellular-delegated.")
            out.append("  What that means: IFNET_IS_CELLULAR() is false for this interface, so the \"the kernel hides the restricted listener from a cellular-delegated utun\" explanation does not hold as written. The MECHANISM story needs another explanation.")
            out.append("  What it does NOT mean: the outcome is unchanged. The dial still fails on cellular and still succeeds in Airplane Mode, and NetworkExtension exposes no API to set or clear an interface delegate, so nothing here becomes fixable either way.")
        }

        if !controls.passed {
            let why = controls.incomplete
                ? "the cellular control could not be run (no pdp_ip* interface), so this was not measured in the state the question is about"
                : "the controls FAILED, so the ioctl is not being called correctly"
            out.append("  ⚠︎ VERDICT WITHHELD: \(why). Treat the line above as unconfirmed until a run with CONTROLS PASSED reproduces it.")
        }

        if tunnels.count > 1 {
            let others = tunnels.dropFirst().map { "\($0.name) (\($0.via))" }.joined(separator: ", ")
            out.append("  NOTE: more than one interface matched a configured tunnel address — also \(others). Read their rows too; a split match usually means a stale address in Settings.")
        }
        return out
    }

    /// The differential control: do OTHER utuns answer the same way? If every utun on the phone says
    /// 5, the ioctl is labelling utuns wholesale and the tunnel row proves nothing specific. If ours
    /// says 5 and the others say 0, the delegate is doing real work.
    private static func differentialLines(readings: [String: Reading],
                                          named: [String],
                                          tunnelNames: Set<String>) -> [String] {
        let utuns = named.filter { $0.hasPrefix("utun") }.sorted()
        guard !utuns.isEmpty else { return ["OTHER utunS: none on this phone."] }

        let described = utuns.map { name -> String in
            let mark = tunnelNames.contains(name) ? " <<< TUNNEL" : ""
            return "\(name)=\(readings[name]?.display ?? "unread")\(mark)"
        }
        var out = ["OTHER utunS (differential control): " + described.joined(separator: " · ")]

        let cellularUtuns = utuns.filter { readings[$0]?.isCellular == true }
        if cellularUtuns.count == utuns.count && utuns.count > 1 {
            out.append("  Every utun answered CELLULAR. That is still consistent with delegation (on a cellular-only phone every tunnel gets the same delegate) but it means this run cannot tell delegation apart from a blanket label. Re-run with Wi-Fi ON: a Wi-Fi-delegated utun should then answer 3 WIFI_INFRA, and if it still answers 5 the reading is not tracking the delegate.")
        } else if !cellularUtuns.isEmpty && cellularUtuns.count < utuns.count {
            out.append("  Some utuns answered CELLULAR and some did not — the reading DISCRIMINATES between tunnels, which is what a real per-interface delegate looks like. This is the strongest form of this evidence.")
        }
        return out
    }

    /// Requirement 5, answered honestly.
    private static func delegateNotes() -> [String] {
        [
            "DELEGATE — how close this gets to reading if_delegated directly:",
            "  There is NO public way to read ifp->if_delegated from an app. Functional type is the closest available proxy, and for a utun row specifically it is a very tight one. Reasoning:",
            "    • The kernel answers SIOCGIFFUNCTIONALTYPE with if_functional_type(ifp, exclude_delegate = FALSE) — the delegate-INCLUSIVE form of that function.",
            "    • Its cellular branch is IFNET_IS_CELLULAR(ifp), which is ((ifp->if_type == IFT_CELLULAR) || (ifp->if_delegated.type == IFT_CELLULAR)).",
            "    • A utun's OWN if_type is never IFT_CELLULAR — a packet-tunnel interface is not a modem. So for a utun, the only way this ioctl can return 5 is through the delegate. A 5 on the tunnel row IS a delegate reading.",
            "  Not attempted on purpose: SIOCGIFDELEGATE is not in the public iPhoneOS SDK, and its request number is NOT guessed here. A wrong guess inside the 'i' ioctl group can land on a SETTER (SIOCSIF*), and this diagnostic is read-only. The proxy above is worth more than a coin-flip on a private constant.",
            "  Also unavailable without extra entitlement: ifru_is_vpn and the peer-egress functional type exist in the SDK's struct ifreq, but the ioctls that fetch them are private too."
        ]
    }

    /// A second opinion from a completely different stack. Network.framework classifies interfaces
    /// through libnetwork rather than through this ioctl, so agreement is real corroboration and
    /// disagreement is itself worth seeing. Bounded, and it opens no connection.
    private static func networkFrameworkCrossCheck() -> [String] {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.wander.functionaltype.path")
        let gate = DispatchSemaphore(value: 0)
        let box = PathBox()

        monitor.pathUpdateHandler = { path in
            guard box.store(path.availableInterfaces.map { ($0.name, describe($0.type)) }) else { return }
            gate.signal()
        }
        monitor.start(queue: queue)
        let timedOut = gate.wait(timeout: .now() + 2) == .timedOut
        monitor.cancel()

        guard !timedOut, let list = box.value else {
            return ["CROSS-CHECK (Network.framework): no path update within 2 s — skipped. Nothing depends on it."]
        }
        guard !list.isEmpty else {
            return ["CROSS-CHECK (Network.framework): the current path lists no interfaces."]
        }
        return [
            "CROSS-CHECK (Network.framework, a different stack asking the same question): "
                + list.map { "\($0.0)=\($0.1)" }.joined(separator: " · "),
            "  This is a SECOND OPINION, not a delegate read. Network.framework only reports interfaces attached to the current path, so a missing utun here is not evidence of anything."
        ]
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:           return "wifi"
        case .cellular:       return "CELLULAR"
        case .wiredEthernet:  return "wired"
        case .loopback:       return "loopback"
        case .other:          return "other"
        @unknown default:     return "unknown"
        }
    }

    /// One-shot holder for the first path update, so the semaphore is signalled exactly once.
    private final class PathBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, String)]?
        private var filled = false

        func store(_ value: [(String, String)]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !filled else { return false }
            filled = true
            stored = value
            return true
        }

        var value: [(String, String)]? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
