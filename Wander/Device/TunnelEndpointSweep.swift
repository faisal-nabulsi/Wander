//
//  TunnelEndpointSweep.swift
//  Wander
//
//  ONE TAP, THE WHOLE PICTURE. Probes port 49152 on every destination worth asking about, back to
//  back, and writes the errno for each into the app Console with a plain-English verdict at the end.
//
//  WHY A SWEEP RATHER THAN A SINGLE PROBE. The failing dial gives exactly one data point per app
//  restart, and re-signing a build to move one address is the reason this has never actually been
//  measured. The interesting facts are COMPARATIVE: "61 refused here but 51 unreachable there" says
//  something neither number says alone — the first proves packets reach a daemon, the second proves
//  they never left the phone. Both in one screen, in the state that is failing.
//
//  The five destinations, in the order they are probed:
//    1. the configured tunnel TARGET — the address Wander actually dials.
//    2. the configured tunnel INTERFACE address (the NE's own end of the loopback).
//    3. 127.0.0.1 — the control. remotepairingd is known to reject this source, so a 61 here is the
//       reference shape of "packets flow, policy says no".
//    4. every non-utun interface address that has a real subnet (en0, bridge100 …). These are the
//       addresses the believed lockdownd rule would accept as a source.
//    5. bridge100's gateway 172.20.10.1 when the Personal Hotspot bridge is up — a third-party
//       project claims this reaches remotepairingd with NO tunnel involved at all, which makes it
//       the single most interesting destination in the list.
//
//  Every probe is individually bounded (1.5 s) so the whole sweep finishes in a few seconds. It does
//  blocking socket work and must therefore run OFF the main thread and off the serial location queue.
//

import Foundation

enum TunnelEndpointSweep {

    /// Per-destination bound. Short on purpose: with ~6 destinations, a 3 s bound could stall the
    /// caller for 18 s, and every failure mode we care about (RST, ICMP unreachable, or silence)
    /// declares itself far inside 1.5 s on a loopback or a local link.
    static let probeTimeoutSeconds: Double = 1.5

    /// The Personal Hotspot bridge's own address. iOS always numbers `bridge100` 172.20.10.1/28.
    static let hotspotGatewayAddress = "172.20.10.1"

    /// One thing to probe, plus why it is in the list. `aliases` collects the OTHER reasons an
    /// address ended up here — if the tunnel target happens to equal en0's address, that collision is
    /// itself a finding (the older lockdownd check rejects a source the device already holds), so it
    /// is printed rather than silently deduplicated away.
    struct Destination: Sendable {
        let label: String
        let address: String
        var aliases: [String] = []
    }

    // MARK: - Building the list

    static func destinations() -> [Destination] {
        var ordered: [Destination] = []
        var indexByAddress: [String: Int] = [:]

        func add(_ label: String, _ address: String) {
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let existing = indexByAddress[trimmed] {
                ordered[existing].aliases.append(label)
                return
            }
            indexByAddress[trimmed] = ordered.count
            ordered.append(Destination(label: label, address: trimmed))
        }

        let defaults = UserDefaults.standard

        // 1 + 2. Read the interface IP by key, exactly as NetworkInterfaceDump does, so the numbers in
        // this log are the numbers on disk and cannot drift from what the tunnel was configured with.
        add("tunnel TARGET — the address Wander dials", DeviceConnectionContext.targetIPAddress)
        add("tunnel INTERFACE address (TunnelInterfaceIP)",
            defaults.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0")

        // 2b. The IPv6 pair, when the experiment is on. It is carved out of the carrier's prefix at
        // tunnel start rather than being a constant (see CellularIPv6Suggester), so the sweep asks
        // for it the same way the interface dump does. Gated on the preference, not on the running
        // provider, because the interesting question before a restart is "what WOULD be dialled" —
        // and `EndpointProbe` is family-agnostic, so a v6 literal needs nothing special here.
        if defaults.bool(forKey: UserDefaults.Keys.useIPv6TunnelLoopback) {
            let planned = DeviceConnectionContext.plannedIPv6Loopback()
            add("tunnel IPv6 TARGET — what Wander would dial (\(planned.sourceLabel))", planned.targetAddress)
            add("tunnel IPv6 INTERFACE address", planned.interfaceAddress)
            if let live = WanderTunnel.startedIPv6TargetAddress {
                // `add` folds a duplicate into an alias line, so when the running tunnel already has
                // the planned address this costs a note rather than a second 1.5 s probe.
                add("tunnel IPv6 TARGET — what the RUNNING tunnel actually has", live)
            }
        }

        // 3. The control.
        add("loopback control", "127.0.0.1")

        // 4. Reuse the app's ONE interface enumerator (WiFiSubnet.allAddresses, the same getifaddrs
        // call behind NetworkInterfaceDump). Writing a third enumerator would be a third thing to keep
        // in agreement with the kernel.
        let entries = WiFiSubnet.allAddresses()
        for entry in entries where entry.isIPv4 && entry.isUp && !entry.isUtun {
            guard entry.maskBytes != nil, !entry.address.isEmpty else { continue }
            // Skip /32s. A point-to-point address (pdp_ip0 is one) covers only itself, so it is not
            // one of the "subnets" the believed lockdownd rule can match — and each one costs a
            // wasted 1.5 s of the owner's sweep.
            if entry.prefixLength == 32 { continue }
            add("\(entry.name) own address (\(entry.cidr ?? "no subnet"))", entry.address)
        }

        // 5. The claim worth testing.
        if entries.contains(where: { $0.name == "bridge100" && $0.isUp }) {
            add("bridge100 GATEWAY — claimed to reach remotepairingd with NO tunnel",
                hotspotGatewayAddress)
        }

        return ordered
    }

    // MARK: - Running it

    /// Probe everything, write the report to the Console, and return a short summary for an alert.
    ///
    /// BLOCKING. Call it from a background queue — never the main thread and never the serial
    /// `LocationSimulationCommandQueue`, which Stop and Panic have to ride.
    static func runAndSummarize(reason: String = "manual") -> String {
        let destinations = destinations()
        var results: [(Destination, EndpointProbeResult)] = []
        results.reserveCapacity(destinations.count)

        var lines: [String] = []
        lines.append("=== TUNNEL ENDPOINT PROBE === port \(DeviceConnectionContext.developerTunnelPort) · reason: \(reason)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(destinations.count) destination(s) · \(Int(probeTimeoutSeconds * 1000)) ms bound each")

        if destinations.isEmpty {
            lines.append("  (nothing to probe — no address could be read at all)")
        }

        for (index, destination) in destinations.enumerated() {
            let result = EndpointProbe.probe(destination.address, timeoutSeconds: probeTimeoutSeconds)
            results.append((destination, result))
            var line = "  [\(index + 1)/\(destinations.count)] \(destination.label) — \(result.destination) \(result.detail)"
            if !destination.aliases.isEmpty {
                line += " · SAME ADDRESS AS: \(destination.aliases.joined(separator: ", "))"
            }
            lines.append(line)
        }

        lines.append(contentsOf: verdictLines(results))
        lines.append("=== END TUNNEL ENDPOINT PROBE ===")

        for line in lines { LogManager.shared.addInfoLog(line) }
        // Retained through the same store as the interface dump, so opening/reopening the Console —
        // which REPLACES the log buffer with what it parses off disk — cannot wipe the sweep the
        // moment the owner navigates away to read it.
        NetworkInterfaceDump.retain(lines)

        return shortSummary(results)
    }

    // MARK: - The verdict

    /// The lines that answer the actual question, so nobody has to decode errno numbers by hand.
    static func verdictLines(_ results: [(Destination, EndpointProbeResult)]) -> [String] {
        guard !results.isEmpty else { return ["VERDICT: nothing was probed."] }

        func addresses(_ outcome: EndpointProbeOutcome) -> [String] {
            results.filter { $0.1.outcome == outcome }.map(\.1.address)
        }
        func list(_ xs: [String]) -> String { xs.isEmpty ? "NONE" : xs.joined(separator: ", ") }

        let connected = addresses(.connected)
        let refused = addresses(.refused)
        let noRoute = addresses(.noRoute)
        let noAnswer = addresses(.noAnswer)
        let unavailable = addresses(.addressUnavailable)
        let otherFailures = results
            .filter { $0.1.outcome == .otherError || $0.1.outcome == .localFailure || $0.1.outcome == .invalidAddress }
            .map { "\($0.1.address) (\($0.1.outcome.label) \($0.1.errnoName))" }

        var out: [String] = []
        out.append("VERDICT connected — a daemon accepted the connection: " + list(connected))
        out.append("VERDICT refused (errno 61) — packets reach a daemon, it sent a RST: " + list(refused))
        out.append("VERDICT no route (errno 51/65) — the packet never left the phone: " + list(noRoute))
        out.append("VERDICT no answer — the packet left and vanished (blackholed): " + list(noAnswer))
        if !unavailable.isEmpty {
            out.append("VERDICT address unavailable (errno 49): " + list(unavailable))
        }
        if !otherFailures.isEmpty {
            out.append("VERDICT other: " + list(otherFailures))
        }

        // The destination that actually decides whether spoofing works is the first one — the address
        // Wander dials — so it gets its own sentence rather than being one entry in a list.
        if let (_, target) = results.first {
            out.append("VERDICT the address Wander dials (\(target.destination)) → \(target.outcome.label): \(target.outcome.meaning)")
        }

        out.append("VERDICT bottom line: " + bottomLine(connected: connected,
                                                        refused: refused,
                                                        noRoute: noRoute,
                                                        noAnswer: noAnswer))
        return out
    }

    /// One sentence naming what the PATTERN means, in the owner's own terms: policy, routing, or a
    /// blackhole. Written to be read by someone deciding what to change next, not by an expert.
    private static func bottomLine(connected: [String],
                                   refused: [String],
                                   noRoute: [String],
                                   noAnswer: [String]) -> String {
        if !connected.isEmpty {
            var s = "port 49152 ACCEPTED a connection from \(connected.joined(separator: ", ")) — packets reach the daemon there and it is listening."
            if !noRoute.isEmpty {
                s += " \(noRoute.joined(separator: ", ")) had no route at all, so that address is a routing problem, not a policy one."
            }
            return s
        }
        if !refused.isEmpty && !noRoute.isEmpty {
            return "61 refused on \(refused.joined(separator: ", ")) but 51/65 unreachable on \(noRoute.joined(separator: ", ")) → packets reach the daemon on the refused ones and it is turning them away (policy); the unreachable ones have no route, so nothing ever left the phone (routing)."
        }
        if !refused.isEmpty {
            return "every destination that answered answered with a REFUSAL (61) on \(refused.joined(separator: ", ")) → packets are flowing and a daemon is actively saying no. This is policy: the source-address rule is the thing to change, not the routing."
        }
        if !noRoute.isEmpty && noAnswer.isEmpty {
            return "no destination had a route (51/65) → not one packet left the phone. This is routing: until a route exists the source-address theory cannot even be tested."
        }
        if !noAnswer.isEmpty && noRoute.isEmpty {
            return "\(noAnswer.joined(separator: ", ")) took the packet and returned nothing — no RST, no route error → blackholed. Something is swallowing the SYN rather than refusing it."
        }
        if !noRoute.isEmpty && !noAnswer.isEmpty {
            return "\(noRoute.joined(separator: ", ")) had no route (51/65) while \(noAnswer.joined(separator: ", ")) swallowed the packet silently → a mix of missing routes and a blackhole; no daemon refused anything, so nothing here is policy."
        }
        return "no destination produced a route, a refusal, or an answer — read the per-line errnos above."
    }

    /// Two or three lines for the confirmation alert, so the result is readable without scrolling the
    /// log. The log remains the full record.
    private static func shortSummary(_ results: [(Destination, EndpointProbeResult)]) -> String {
        guard !results.isEmpty else {
            return L("console.probe_endpoints.empty",
                     fallback: "No destinations could be read, so nothing was probed.")
        }
        let counts = results.reduce(into: [String: Int]()) { $0[$1.1.outcome.label, default: 0] += 1 }
        let tally = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let target = results[0].1
        let intro = L("console.probe_endpoints.done.body",
                      fallback: "Full detail and the verdict are in the log below — use Export Logs to send it.")
        return "\(results.count) probed: \(tally).\nWander's own target \(target.destination) → \(target.outcome.label).\n\n\(intro)"
    }
}
