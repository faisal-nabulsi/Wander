//
//  GslocEngineView.swift
//  Wander
//
//  Runs the in-app gs-loc engine (GslocProxyServer + GslocEngine) and shows, in plain language, the ONE
//  thing that proves it works: a line reading "rewrote gs-loc.apple.com: N APs". That line is what
//  settles the A4 question (does locationd's WPS lookup actually traverse our proxy) AND answers whether
//  cell poisoning ever fires (the cell count), both of which have been open for weeks.
//

import SwiftUI

struct GslocEngineView: View {
    @StateObject private var server = GslocProxyServer()
    @Environment(\.dismiss) private var dismiss

    private var sawRewrite: Bool { server.rewriteCount > 0 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    result
                } header: {
                    Text("Result")
                }

                Section {
                    Button {
                        server.isRunning ? server.stop() : server.start()
                    } label: {
                        Label(server.isRunning ? "Stop engine" : "Start engine",
                              systemImage: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(server.isRunning ? .red : .accentColor)
                    if let err = server.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("In-app engine — 127.0.0.1:\(String(GslocProxyServer.port))")
                }

                Section("Before you start") {
                    step("Trust Wander's certificate (the previous screen) — the badge must read trusted.")
                    step("Arm a target: turn on PoGo mode and teleport somewhere, so the engine has coordinates to write.")
                    step("Start the engine above.")
                    step("Settings → Wi-Fi → ⓘ → Configure Proxy → Manual, 127.0.0.1, port \(String(GslocProxyServer.port)), Save.")
                    step("Open Apple Maps and let it re-locate.")
                    step("When done: set Configure Proxy → Off.")
                }

                Section {
                    if server.events.isEmpty {
                        Text("No connections yet.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(server.events) { e in
                            Text(e.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(e.rewrote ? .green : .primary)
                                .fontWeight(e.rewrote ? .bold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    HStack {
                        Text("Engine log")
                        Spacer()
                        if !server.events.isEmpty { Button("Clear") { server.clear() }.font(.caption) }
                    }
                } footer: {
                    Text("A green line reading “rewrote gs-loc.apple.com: N APs, M cells” is the proof: locationd's WPS lookup went through the engine and was rewritten. The cell count answers whether cell-tower poisoning fires.")
                }
            }
            .navigationTitle("In-app gs-loc engine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { server.stop(); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        if sawRewrite {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Engine is rewriting WPS lookups").fontWeight(.semibold)
                    Text("\(server.rewriteCount) rewrite\(server.rewriteCount == 1 ? "" : "s") so far. This proves the in-app engine works — Shadowrocket is not needed for the Wi-Fi case.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        } else if server.isRunning {
            Label {
                Text("Waiting for a gs-loc lookup to rewrite… trigger one in Apple Maps.")
            } icon: { ProgressView() }
        } else {
            Label("Not started.", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func step(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).padding(.top, 6)
            Text(.init(text)).font(.footnote)
        }
    }
}
