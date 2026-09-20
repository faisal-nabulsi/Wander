//
//  ExperimentLogView.swift
//  Wander
//
//  Reads back the evidence captured in LocationDiagnosticView. The point of this screen is that a
//  claim about what the device does can be RE-READ rather than remembered — see ExperimentLog.
//

import SwiftUI

struct ExperimentLogView: View {
    @ObservedObject private var log = ExperimentLog.shared
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        List {
            if log.records.isEmpty {
                Section {
                    Text("Nothing captured yet. Run a spoof, open Location diagnostic, name what you're testing and tap Capture evidence.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button {
                        UIPasteboard.general.string = log.fullExport
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Copied ✓" : "Copy all as text", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } footer: {
                    Text("Paste this anywhere — it's the full record of every measurement, with the engine state each was taken under.")
                }

                ForEach(log.records) { r in
                    Section {
                        // The two numbers every argument has come down to, first and unmissable.
                        HStack {
                            Text("isSimulatedBySoftware").font(.caption)
                            Spacer()
                            Text(flagText(r.isSimulatedBySoftware))
                                .font(.caption.bold())
                                .foregroundStyle(flagColor(r.isSimulatedBySoftware))
                        }
                        HStack {
                            Text("isProducedByAccessory").font(.caption)
                            Spacer()
                            Text(flagText(r.isProducedByAccessory))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                        detail("coordinate", String(format: "%.5f, %.5f", r.latitude, r.longitude))
                        detail("hAcc / vAcc", String(format: "%.1f m / %.1f m", r.horizontalAccuracy, r.verticalAccuracy))
                        detail("altitude", String(format: "%.1f m", r.altitude))
                        detail("engines", enginesText(r))
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.footnote.bold())
                            Text(r.timestamp.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    idx.map { log.records[$0] }.forEach(log.delete)
                }

                Section {
                    Button(role: .destructive) { confirmClear = true } label: {
                        Text("Clear all").frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Experiment log")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete every record?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This is the only copy of these measurements. Copy them out first if they still matter.")
        }
    }

    private func flagText(_ b: Bool?) -> String {
        guard let b else { return "nil" }
        return b ? "TRUE" : "FALSE"
    }
    /// TRUE is the bad outcome for the flag that causes Error 12, so it reads red.
    private func flagColor(_ b: Bool?) -> Color {
        guard let b else { return .secondary }
        return b ? .red : .green
    }
    private func enginesText(_ r: ExperimentRecord) -> String {
        var parts: [String] = []
        parts.append(r.gslocModeEnabled ? "gs-loc ON" : "gs-loc off")
        if r.dualEngineEnabled { parts.append("DUAL") }
        parts.append(r.tunnelEndpointReachable ? "tunnel up" : "tunnel down")
        if r.foreignVPNActive { parts.append("VPN up") }
        if r.proxyProbeRunning { parts.append("proxy running") }
        return parts.joined(separator: " · ")
    }
    private func detail(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption, design: .monospaced))
        }
    }
}
