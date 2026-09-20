//
//  ProxyProbeView.swift
//  Wander
//
//  THROWAWAY DIAGNOSTIC UI for ProxyProbeServer. Answers one yes/no question on-device:
//  does locationd's gs-loc WPS lookup travel through an in-app Wi-Fi HTTP proxy?
//  If yes → Wander could host gs-loc itself (no Shadowrocket) for the Wi-Fi case. If no → dead lead.
//

import SwiftUI
import CoreLocation

struct ProxyProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var server = ProxyProbeServer()
    @StateObject private var locator = ProbeLocationSnapshot()
    @StateObject private var forcer = QueryForcer()
    @State private var filed = false

    /// Record the proxy result into the shared experiment log under the claim's label, so
    /// "locationd honors the in-app proxy" becomes a re-readable record rather than a remembered banner.
    private func fileProxyEvidence() {
        guard let loc = locator.latest else { return }
        let hosts = server.topHosts.map { "\($0.host)×\($0.count)" }.joined(separator: ", ")
        let note = "WPS lookups: \(server.hitGaps.count + 1). Connections: \(server.totalConnections), "
            + "upstream failures: \(server.upstreamFailures). Hosts: \(hosts)."
        let record = ExperimentLog.capture(location: loc,
                                           label: "claim:inapp-proxy-honored",
                                           note: note,
                                           proxyRunning: server.isRunning)
        ExperimentLog.shared.add(record)
        filed = true
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    resultBanner
                } header: {
                    Text("Result")
                }

                Section {
                    Button {
                        server.isRunning ? server.stop() : server.start()
                    } label: {
                        Label(server.isRunning ? "Stop proxy" : "Start proxy",
                              systemImage: server.isRunning ? "stop.circle.fill" : "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(server.isRunning ? .red : .accentColor)

                    if let err = server.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Proxy — 127.0.0.1 : \(String(server.port))")
                } footer: {
                    Text("This only tests Wi-Fi. iOS has no cellular proxy setting, so make sure you're connected to a Wi-Fi network before running it.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { forcer.running },
                        set: { $0 ? forcer.start() : forcer.stop() }
                    )) {
                        Label("Force re-queries (movement experiment)", systemImage: "arrow.clockwise.circle")
                    }
                    if forcer.running {
                        Text("\(forcer.ticks) forcing rounds · \(forcer.lastAction)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("THE MOVEMENT TEST. Run the proxy with this OFF for ~3 min and note the WPS-lookup count, then ON for ~3 min. If forcing raises the rate toward one lookup every few seconds, stepwise gs-loc movement (route/joystick) becomes possible — the first genuinely new angle on it. If the rate doesn't move, teleport-only is confirmed by measurement instead of assumption.")
                }

                Section("Steps") {
                    step(1, "Tap **Start proxy** above.")
                    step(2, "Go to **Settings → Wi-Fi**, tap the **ⓘ** next to your network, scroll down to **Configure Proxy → Manual**.")
                    step(3, "Server **127.0.0.1**, Port **\(String(server.port))**, leave Authentication off, tap **Save**.")
                    step(4, "Open **Apple Maps** and tap the location arrow so the phone re-locates. (Give it 10–20s.)")
                    step(5, "Come back here and watch the log. A **gs-loc** / **ls.apple.com** line = it works.")
                    step(6, "When done: **Settings → Wi-Fi → ⓘ → Configure Proxy → Off**, then Stop the proxy here.")
                }

                Section {
                    if server.lines.isEmpty {
                        Text("No connections yet.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(server.lines.reversed()) { line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.isHit ? Color.green : Color.primary)
                                .fontWeight(line.isHit ? .bold : .regular)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    HStack {
                        Text("Log")
                        Spacer()
                        if !server.lines.isEmpty {
                            Button("Clear") { server.clearLog() }
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("In-app proxy probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        server.stop()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultBanner: some View {
        if server.sawTarget {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("locationd honored the proxy").fontWeight(.semibold)
                    Text("The WPS lookup reached the in-app proxy. In-app gs-loc is viable for the Wi-Fi case.")
                        .font(.caption).foregroundStyle(.secondary)

                    // THE MEASUREMENT. How often locationd re-queries decides whether gs-loc can do
                    // movement at all: Pokémon GO samples roughly every 5s, so a fix arriving that
                    // often already IS walking — no continuous stream required.
                    Divider().padding(.vertical, 2)
                    // Distinct WPS lookups, debounced — raw connections overstate this hugely (TLS
                    // setup + retries), which is why the first run read ~2000 in 30s with a 0s median.
                    Text("Distinct WPS lookups: \(server.hitGaps.count + 1)")
                        .font(.caption).fontWeight(.medium)

                    // File the evidence for the claim this probe exists to settle, so it lives in the
                    // same log as everything else instead of only ever being a green banner.
                    Button {
                        fileProxyEvidence()
                    } label: {
                        Label(filed ? "Filed ✓" : "File this as proof",
                              systemImage: filed ? "checkmark.seal.fill" : "square.and.arrow.down")
                            .font(.caption)
                    }
                    .disabled(filed)
                    // Read the QUIET gaps, not the raw median: the raw one is dominated by each lookup's
                    // burst of connections and by the debounce floor, and will happily report a number
                    // that is really just the floor value.
                    if let quiet = server.medianQuietGap {
                        Text(String(format: "Median gap between re-queries: %.0fs", quiet))
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(quiet <= 30 ? .green : .orange)
                        Text(quiet <= 30
                             ? "Fast enough that repeated teleports would read as movement."
                             : "Too slow for movement on its own — the cache-starvation levers are the next test.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("(\(server.quietGaps.count) quiet gaps ≥5s out of \(server.hitGaps.count) total)")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if server.hitGaps.count > 3 {
                        Text("Traffic is continuous — no gap ≥5s yet.")
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                        Text("Either locationd is querying nonstop, or the probe is causing retries. Check the failure count below.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("Leave this running with Maps or PoGo open to measure the re-query rate.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    // HEALTH — if failures track total connections, we're measuring our own retry storm
                    // rather than locationd, and the cadence number above is meaningless.
                    if server.totalConnections > 0 {
                        Divider().padding(.vertical, 2)
                        Text("Connections: \(server.totalConnections)   ·   upstream failures: \(server.upstreamFailures)")
                            .font(.caption2)
                            .foregroundStyle(server.upstreamFailures > server.totalConnections / 4 ? .orange : .secondary)
                        if server.upstreamFailures > server.totalConnections / 4 {
                            Text("Heavy failures — this traffic is mostly retries caused by the probe, not organic queries.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        ForEach(server.topHosts, id: \.host) { row in
                            Text("· \(row.host) × \(row.count)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } icon: {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
        } else if server.isRunning {
            Label {
                Text("Waiting for a gs-loc lookup… trigger one in Apple Maps.")
            } icon: {
                ProgressView()
            }
        } else {
            Label("Not started.", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(.init(text))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Minimal location feed for the probe screen. The evidence record needs a real CLLocation (that is the
/// point — every record carries what Core Location actually reported), but this screen is about network
/// traffic and has no location manager of its own.
@MainActor
final class ProbeLocationSnapshot: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var latest: CLLocation?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in self.latest = loc }
    }
}
