//
//  TunnelMatrixView.swift
//  Wander
//
//  The one button. Picks a mode, shows the preconditions BEFORE the run (so a hotspot that is down
//  is discovered now rather than four skipped rows later), streams each row as it completes, and
//  ends on a single bottom line. The full report also goes to the Console, so Export Logs carries it.
//
//  In ASSISTED mode this screen is also the instruction card: it shows the exact three numbers to
//  type into LocalDevVPN, then watches getifaddrs and measures the moment they appear.
//

import SwiftUI
import UIKit

struct TunnelMatrixView: View {
    // The SHARED runner, deliberately — see `TunnelConfigMatrixRunner.shared`. A `@StateObject` here
    // would be destroyed if the user navigated away mid-run, killing the task that has to put their
    // tunnel settings back.
    @ObservedObject private var runner = TunnelConfigMatrixRunner.shared
    @State private var mode: TunnelConfigMatrixRunner.Mode = .auto
    @State private var interfaces: [NetworkInterfaceAddress] = []
    @State private var copied = false

    var body: some View {
        List {
            introSection
            modeSection
            preconditionSection
            controlSection
            if !runner.rows.isEmpty { resultsSection }
            if case .finished(let bottom) = runner.phase { bottomLineSection(bottom) }
            if !runner.reportLines.isEmpty { reportSection }
        }
        .navigationTitle("Tunnel Matrix")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { interfaces = WiFiSubnet.allAddresses() }
    }

    // MARK: - Sections

    private var introSection: some View {
        Section {
            Text("Runs every candidate tunnel configuration back to back: reconnects, checks that the addresses actually reached the interface, probes port 49152 with a 1.5-second bound, and writes a table plus one bottom line into the Console.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("A reconnect IS required between configurations — the tunnel reads its addresses only when it starts, so changing them while it is up does nothing at all. That is why hand-testing kept measuring the previous config.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: $mode) {
                ForEach(TunnelConfigMatrixRunner.Mode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(runner.isRunning)
            Text(modeExplanation)
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Which tunnel")
        }
    }

    private var modeExplanation: String {
        switch mode {
        case .auto:
            return "Unattended, about a minute. Drives Wander's own tunnel — which means it measures OUR provider. If every row comes back with no answer, that says the provider is swallowing packets, not that the addresses are wrong. It takes iOS's single VPN slot for the duration and hands it back at the end; any other VPN app you had connected has to be reconnected by you. Needs a certificate build."
        case .assisted:
            return "You type each row's three numbers into LocalDevVPN and reconnect; this screen detects the change and measures it automatically. Slower, but it tests the tunnel that is known to work — which is where the open question actually lives. Changes nothing in Wander."
        case .directOnly:
            return "Just the two no-tunnel probes (the hotspot bridge gateway and 127.0.0.1). About three seconds, touches nothing."
        }
    }

    private var preconditionSection: some View {
        Section {
            checkRow(label: "Wander's own tunnel is usable",
                     ok: WanderTunnel.isSupported,
                     detail: WanderTunnel.isSupported ? "signed with the Network Extension entitlement" : "not signed for it — Automatic mode is unavailable, use Assisted")
            checkRow(label: "Personal Hotspot bridge (bridge100)",
                     ok: hotspotUp,
                     detail: hotspotUp ? "up — the four 172.20.10.x rows can run" : "down — four rows will be skipped. iOS also drops the hotspot after about 90 seconds with no client attached")
            checkRow(label: "Wi-Fi (en0)",
                     ok: wifiAddress != nil,
                     detail: wifiAddress ?? "no address — the Wi-Fi /30 row will be skipped (expected on a cellular-only run)")
            checkRow(label: "No simulation running",
                     ok: !SimulationSession.shared.isActive,
                     detail: SimulationSession.shared.isActive ? "stop it first — reconnecting the tunnel would kill the live session" : "safe to reconnect the tunnel")
            checkRow(label: "gs-loc mode off",
                     ok: !GslocMode.enabled,
                     detail: GslocMode.enabled ? "on — it needs Shadowrocket to hold the VPN slot" : "the VPN slot is free")
            if mode == .auto {
                checkRow(label: "No other VPN holding the slot",
                         ok: !foreignVPNActive,
                         detail: foreignVPNActive
                            ? "another tunnel app is connected. Automatic mode will disconnect it to take the slot, and cannot reconnect it for you — that is allowed, just know it will happen"
                            : "nothing else is using it")
            }
            if mode == .assisted {
                checkRow(label: "LocalDevVPN ready",
                         ok: foreignVPNActive,
                         detail: foreignVPNActive
                            ? "an external tunnel is up — good, this mode measures that one"
                            : "no external tunnel interface is up yet. Open LocalDevVPN and connect it before starting, or the first row will just wait")
            }
            Button {
                interfaces = WiFiSubnet.allAddresses()
            } label: {
                Label("Re-read interfaces", systemImage: "arrow.clockwise")
            }
            .disabled(runner.isRunning)
        } header: {
            Text("Before you run")
        }
    }

    private var controlSection: some View {
        Section {
            if let refusal = runner.refusal {
                Text(refusal).font(.footnote).foregroundStyle(.red)
            }

            switch runner.phase {
            case .running(let index, let total, let detail):
                HStack {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(total > 0 ? "Row \(index) of \(total)" : "Starting")
                            .font(.subheadline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            case .waitingForUser(let index, let total, let instruction):
                assistedCard(index: index, total: total, instruction: instruction)
            default:
                EmptyView()
            }

            if runner.isRunning {
                Button(role: .destructive) { runner.cancel() } label: {
                    Label("Cancel run", systemImage: "stop.circle")
                }
            } else {
                Button {
                    runner.start(mode: mode)
                } label: {
                    Label("Run the matrix", systemImage: "play.circle.fill")
                }
                .tint(Wander.accent)
                .disabled(runner.refusalReason(for: mode) != nil)
                if let reason = runner.refusalReason(for: mode) {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// ASSISTED mode's whole user interface: the three numbers, copyable, plus the two escape hatches.
    private func assistedCard(index: Int, total: Int, instruction: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Row \(index) of \(total) — waiting for you")
                .font(.subheadline.bold())
            Text(instruction)
                .font(.footnote)
            if let current = currentCandidate(index: index) {
                VStack(alignment: .leading, spacing: 4) {
                    copyableRow("Device IP", current.deviceIP ?? "-")
                    copyableRow("Tunnel IP", current.targetIP)
                    copyableRow("Subnet mask", current.mask ?? "-")
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Measure now") { runner.proceedNow() }
                    .buttonStyle(.bordered)
                Button("Skip this row") { runner.skipCurrentRow() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func copyableRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospaced())
            Button {
                UIPasteboard.general.string = value
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Wander.accent)
        }
    }

    /// The candidate the runner is parked on. Derived from the same list the runner built, so the
    /// numbers on screen cannot drift from the numbers being measured.
    private func currentCandidate(index: Int) -> TunnelConfigCandidate? {
        let all = TunnelConfigMatrix.candidates(entries: interfaces)
        guard index >= 1, index <= all.count else { return nil }
        return all[index - 1]
    }

    private var resultsSection: some View {
        Section {
            ForEach(runner.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.candidate.title).font(.subheadline)
                        Spacer()
                        Text(statusBadge(row))
                            .font(.caption.bold())
                            .foregroundStyle(badgeColor(row))
                    }
                    Text(row.candidate.configDescription)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(row.verdict).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Rows")
        }
    }

    private func bottomLineSection(_ bottom: String) -> some View {
        Section {
            Text(bottom).font(.footnote)
        } header: {
            Text("Bottom line")
        }
    }

    private var reportSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = runner.reportLines.joined(separator: "\n")
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy the full report", systemImage: "doc.on.doc")
            }
            Text("The same report is in the Console (App tab) and exports with Export Logs.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Report")
        }
    }

    // MARK: - Small helpers

    /// True when some non-Wander tunnel interface is carrying IPv4 — LocalDevVPN, StosVPN,
    /// Shadowrocket or a real VPN. Reuses the app's existing test rather than a second one.
    private var foreignVPNActive: Bool {
        WanderTunnel.foreignVPNInterfaceActive() && WanderTunnel.shared.status != .connected
    }

    private var hotspotUp: Bool {
        interfaces.contains { $0.name == "bridge100" && $0.isUp && $0.isIPv4 }
    }

    private var wifiAddress: String? {
        interfaces.first { $0.name == "en0" && $0.isIPv4 && $0.isUp }.map { $0.cidr ?? $0.address }
    }

    private func checkRow(label: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func statusBadge(_ row: TunnelConfigMatrixRow) -> String {
        if row.skippedReason != nil { return "SKIPPED" }
        guard let target = row.target else { return "—" }
        if !row.installState.isTrustworthy { return "INVALID" }
        return target.outcome.label
    }

    private func badgeColor(_ row: TunnelConfigMatrixRow) -> Color {
        if row.skippedReason != nil { return .secondary }
        if !row.installState.isTrustworthy { return .orange }
        return row.targetConnected ? .green : .secondary
    }
}

#Preview {
    NavigationStack { TunnelMatrixView() }
}
