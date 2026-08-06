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
//  SAFETY. Every probe here is READ-ONLY: it opens bounded sockets and reads getifaddrs. Nothing on
//  this screen writes a UserDefaults tunnel address, starts or stops a VPN, or touches
//  LocationSimulationCommandQueue. The one screen that DOES mutate settings is TunnelMatrixView,
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
                Text("These two touch no sockets and change nothing. Everything below opens bounded TCP connects.")
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
