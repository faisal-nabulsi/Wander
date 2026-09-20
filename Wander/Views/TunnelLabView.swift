//
//  TunnelLabView.swift
//  Wander
//
//  ONE SCREEN THAT CAN REACH EVERY TUNNEL DIAGNOSTIC.
//
//  WHY THIS FILE EXISTS. Six diagnostic modules were built in Wander/Device/ during the cellular
//  investigation — TunnelRoutePolicy, RpPairingHandshakeProbe, SocketInterfaceBinding,
//  CellularIPv6Probe, TunnelEndpointSweep and NetworkInterfaceDump. As of this file, exactly TWO of
//  them had a way to be run from the UI (the interface dump and the endpoint sweep, both in the
//  Console's overflow menu). The rest compiled, shipped inside the binary, and were unreachable.
//  A probe nobody can tap is worth nothing, so this screen exposes all of them in one place.
//
//  WHY NOT THE CONSOLE MENU. Wander/Views/ConsoleLogsView.swift is being edited by another workflow.
//  Adding a NEW view and one NavigationLink in ToolsView (which is not owned) reaches the same
//  buttons without touching a contested file. It is also a better home: these take seconds each and
//  produce paragraphs of output, which a menu alert reads badly.
//
//  SAFETY. Every probe here is READ-ONLY — with ONE named exception. The probes open bounded sockets
//  and read getifaddrs; none of them writes a UserDefaults tunnel address or starts or stops a VPN.
//  The exception is the "Location sink A/B" row, which INJECTS A LOCATION twice and clears it twice
//  (see Wander/Device/LocationSinkAB.swift). It lives in its own section, under its own warning, and
//  refuses to start while a simulation is active or while gs-loc mode is on — so it can never become
//  a second writer. The one screen that DOES mutate settings is TunnelMatrixView,
//  which is reached from Tools separately and does its own restore. Each run is a `Task.detached`
//  rather than a `Task {}` so the blocking connects never land on the main thread — a plain `Task {}`
//  inside a SwiftUI view inherits MainActor and would freeze the UI for the length of the sweep.
//

import SwiftUI

struct TunnelLabView: View {

    /// Which probe is running, so a second tap cannot start an overlapping run. The probes share
    /// nothing, but two at once would interleave their lines in the log and make the output unreadable.
    @State private var running: String?
    @State private var output: String = ""
    @State private var outputTitle: String = ""

    /// The two saved-preference routing levers. Both default OFF, i.e. Apple's defaults, i.e. exactly
    /// what shipped. They are read by `TunnelRoutePolicy.applyRoutePolicy`, which `WanderTunnel.start`
    /// calls just before the `saveToPreferences` it already does — so flipping one here rewrites the
    /// saved VPN profile on the NEXT start, and the tunnel must then be restarted for it to bite.
    /// They affect WANDER'S OWN tunnel only. LocalDevVPN's profile belongs to LocalDevVPN and iOS
    /// gives no app any way to read or write another app's NEVPNManager configuration.
    @AppStorage(TunnelRoutePolicy.enforceRoutesDefaultsKey) private var enforceRoutes = false
    @AppStorage(TunnelRoutePolicy.allowLocalNetworksDefaultsKey) private var allowLocalNetworks = false

    /// The ONE row on this screen that writes a location. It has its own runner rather than going
    /// through `probeRow` because it needs the main actor (it drives a CLLocationManager delegate
    /// feed), it takes a minute or two, and it must be able to refuse to start.
    @StateObject private var sinkAB = LocationSinkABRunner()

    var body: some View {
        List {
            Section {
                probeRow(id: "interfaces",
                         title: "Dump network interfaces",
                         detail: "getifaddrs, plus the lockdownd source-rule verdict for the configured addresses. Run this FIRST and confirm en0 has no IPv4 address before believing any cellular result.",
                         icon: "network") {
                    let lines = NetworkInterfaceDump.report(reason: "tunnel lab")
                    NetworkInterfaceDump.retain(lines)
                    return lines.joined(separator: "\n")
                }

                // The one measurement that closes (or breaks) the SO_RESTRICT_DENY_CELLULAR chain.
                // No sockets are opened to anything: one unbound UDP fd is used purely as a handle
                // for ioctl(SIOCGIFFUNCTIONALTYPE), which is a getter.
                probeRow(id: "functionaltype",
                         title: L("tunnellab.functional_type.title",
                                  fallback: "Interface functional type (is the utun cellular?)"),
                         detail: L("tunnellab.functional_type.detail",
                                   fallback: "Asks the kernel what KIND of interface each one is. lo0 and pdp_ip0 are built-in controls; if they come back wrong the answer is thrown out. Says in plain words whether Wander's own tunnel counts as cellular. Run it on cellular with Wi-Fi off."),
                         icon: "antenna.radiowaves.left.and.right") {
                    InterfaceFunctionalType.runAndSummarize(reason: "tunnel lab")
                }

                probeRow(id: "routepolicy",
                         title: "Explain the configured route",
                         detail: "No sockets. Prints the route CIDR the provider will install, whether it covers the address Wander dials, and which non-utun interface it collides with. Read this before spending a probe.",
                         icon: "arrow.triangle.branch") {
                    let report = TunnelRoutePolicy.analyzeConfiguredTunnel()
                    let lines = TunnelRoutePolicy.reportLines(report, reason: "tunnel lab")
                    NetworkInterfaceDump.retain(lines)
                    return lines.joined(separator: "\n")
                }
            } header: {
                Text("Look before you probe")
            } footer: {
                Text("These three connect to nothing and change nothing — they read the kernel's own interface tables. (The functional-type row opens one unbound UDP socket purely as a handle for a read-only ioctl; it dials no daemon.) Everything below opens bounded TCP connects.")
            }

            Section {
                probeRow(id: "sweep",
                         title: "Probe tunnel endpoints",
                         detail: "Bounded TCP connect to every candidate: the configured target, the tunnel's own address, 127.0.0.1, every non-utun address, and bridge100's gateway when the hotspot is up. Answers ROUTING only.",
                         icon: "dot.radiowaves.left.and.right") {
                    TunnelEndpointSweep.runAndSummarize(reason: "tunnel lab")
                }

                probeRow(id: "rppairing",
                         title: "RPPairing handshake probe",
                         detail: "One layer above the sweep: connects, sends the real 188-byte attemptPairVerify frame, and reports whether the daemon ANSWERS. A completed TCP connect is not evidence the daemon will talk to you.",
                         icon: "hand.wave") {
                    RpPairingHandshakeProbe.runAndSummarize(reason: "tunnel lab")
                }
            } header: {
                Text("Does anything answer?")
            } footer: {
                Text("The sweep answers \"did a SYN get answered\". The handshake probe answers \"will remotepairingd hold a conversation sourced from this address\" — which is the question the lockdownd source rule actually decides.")
            }

            Section {
                probeRow(id: "binding",
                         title: "Scoped-socket (IP_BOUND_IF) probe",
                         detail: "Dials the configured target with the socket bound to each candidate interface index. Apple documents socket scoping as superseding the system routing table, so this is the one app-side lever that can beat a local-network route.",
                         icon: "point.3.connected.trianglepath.dotted") {
                    SocketScopeSweep.runAndSummarize(reason: "tunnel lab")
                }

                probeRow(id: "ipv6",
                         title: "Cellular IPv6 inventory & carve",
                         detail: "Enumerates every non-utun IPv6 prefix, carves a usable device/peer pair out of the cellular /64, and probes it. This is the only address family with room to satisfy the source rule with Wi-Fi OFF and no hotspot.",
                         icon: "6.circle") {
                    CellularIPv6Probe.runAndSummarize(reason: "tunnel lab")
                }
            } header: {
                Text("The two untested levers")
            } footer: {
                Text("Run these ONE AT A TIME and never with enforceRoutes armed — Apple documents enforceRoutes as superseding \"scoping operations by apps\", so it would silently invalidate the binding result.")
            }

            // THE ONE ROW HERE THAT IS NOT READ-ONLY. It injects a location twice and clears twice,
            // which is why it sits in its own section under its own warning rather than beside the
            // socket probes above.
            Section {
                Button {
                    Task { await sinkAB.run() }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("tunnellab.sinkab.title",
                                   fallback: "Location sink A/B (does the sink set isSimulatedBySoftware?)"))
                            Text(L("tunnellab.sinkab.detail",
                                   fallback: "Sends ONE coordinate twice — first through the DVT service Wander ships, then through the lockdown sibling com.apple.dt.simulatelocation — and reads the flags off the LIVE location feed each time. Takes 1–2 minutes. Stop any spoof first; gs-loc mode must be OFF."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        if sinkAB.isRunning {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.left.arrow.right.circle")
                        }
                    }
                }
                .disabled(sinkAB.isRunning || running != nil)

                if sinkAB.isRunning && !sinkAB.progress.isEmpty {
                    Text(sinkAB.progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !sinkAB.report.isEmpty {
                    Text(sinkAB.report)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = sinkAB.report
                    } label: {
                        Label(L("tunnellab.sinkab.copy", fallback: "Copy the A/B report"),
                              systemImage: "doc.on.doc")
                    }
                }
            } header: {
                Text(L("tunnellab.sinkab.header", fallback: "The last open door — this one WRITES"))
            } footer: {
                Text(L("tunnellab.sinkab.footer",
                       fallback: "Keep Wander in the foreground for the whole run. It moves your device's reported location to a far-away landmark, reads what iOS hands apps, clears it, repeats through the other service, then clears again — it never leaves a spoof running. It refuses to start while a simulation is active or while gs-loc mode is on, because two writers to one location is a bug we already shipped once."))
            }

            Section {
                Toggle("enforceRoutes", isOn: $enforceRoutes)
                Toggle("Allow local networks (excludeLocalNetworks = false)", isOn: $allowLocalNetworks)
            } header: {
                Text("Saved-profile levers — Wander's own tunnel only")
            } footer: {
                Text("Both are Apple defaults when off. enforceRoutes is documented to supersede the system routing table, which is what claims a tunnel address sitting inside a physical interface's subnet. Flip one, then RESTART the tunnel — network settings are established once, inside startTunnel. Change ONE at a time so the result names a flag, and never with the scoped-socket probe: Apple documents enforceRoutes as also superseding app scoping.")
            }

            if !output.isEmpty {
                Section {
                    Text(output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = output
                    } label: {
                        Label("Copy this report", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text(outputTitle)
                }
            }
        }
        .navigationTitle("Tunnel Lab")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One row per probe. `work` runs OFF the main thread and returns the text to show.
    @ViewBuilder
    private func probeRow(id: String,
                          title: String,
                          detail: String,
                          icon: String,
                          work: @escaping @Sendable () -> String) -> some View {
        Button {
            start(id: id, title: title, work: work)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                if running == id {
                    ProgressView()
                } else {
                    Image(systemName: icon)
                }
            }
        }
        .disabled(running != nil)
    }

    private func start(id: String, title: String, work: @escaping @Sendable () -> String) {
        guard running == nil else { return }
        running = id
        outputTitle = title
        output = ""
        Task {
            let text = await Task.detached(priority: .userInitiated) { work() }.value
            output = text
            running = nil
        }
    }
}
