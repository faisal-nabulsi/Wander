//
//  ProxyProbeServer.swift
//  Wander
//
//  THROWAWAY DIAGNOSTIC — not a shipping feature.
//
//  Single question this answers: when the iPhone's Wi-Fi "Manual HTTP Proxy" is pointed at a listener
//  running INSIDE Wander (127.0.0.1:8888), does `locationd`'s WPS lookup to gs-loc.apple.com actually
//  travel through that proxy? If YES, Wander could host the gs-loc MITM itself on free-sideload builds
//  (no Shadowrocket, no Network Extension) — see the `wander-inapp-gsloc-verdict` memory. If NO,
//  locationd bypasses the system HTTP proxy and the whole idea is dead; keep Shadowrocket.
//
//  It is a minimal pass-through HTTP proxy: it logs the request line of every connection (so a
//  `CONNECT gs-loc.apple.com:443` line is the proof we're looking for) and then forwards the bytes so
//  the phone stays online during the test. The log happens BEFORE forwarding, so even if forwarding
//  misbehaves the proof still lands.
//
//  Caveat baked into the test: the Wi-Fi HTTP proxy is Wi-Fi-ONLY. iOS has no cellular proxy setting,
//  so this can only ever see a lookup made while on Wi-Fi. Run the test ON WI-FI.
//

import Foundation
import Network

/// Sendable wrapper so NWConnection can cross the @Sendable network-callback boundary under Swift 6
/// strict concurrency. All access is serialized on the server's queue.
private final class ConnBox: @unchecked Sendable {
    let conn: NWConnection
    init(_ c: NWConnection) { conn = c }
}

@MainActor
final class ProxyProbeServer: ObservableObject {
    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isHit: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var sawTarget = false
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var lastError: String?

    /// Fixed so the on-screen instructions can name it. 8888 matches the ecosystem convention.
    static let listenPort: UInt16 = 8888
    let port: UInt16 = ProxyProbeServer.listenPort

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.wander.proxyprobe", attributes: .concurrent)

    /// When the last WPS (gs-loc) request arrived, so each new one can report the gap since the previous
    /// one. THE GAP IS THE MEASUREMENT: locationd's natural re-query cadence is what decides whether
    /// gs-loc can do movement at all (PoGo samples ~every 5s, so a fix that often IS walking).
    private var lastHitAt: Date?
    /// Every observed gap, for the summary line. Small; a long run is a few dozen entries.
    @Published private(set) var hitGaps: [TimeInterval] = []

    /// Every host seen and how many CONNECTs it made. Without this the counter is uninterpretable: a
    /// single logical WPS lookup is not one connection, and a failing proxy makes clients retry in a hot
    /// loop — which is exactly what "2000 hits in 30s" turned out to be. Seeing the hosts tells us
    /// whether we are watching locationd or a retry storm.
    @Published private(set) var hostCounts: [String: Int] = [:]
    /// Upstream connections that failed — the retry-storm tell. If this tracks `hostCounts`, the traffic
    /// is our own failure being retried, not organic re-querying.
    @Published private(set) var upstreamFailures = 0

    /// A WPS "query" is debounced: connections to the same host inside this window count as ONE logical
    /// lookup. TLS setup, retries and parallel sockets all fire several CONNECTs for one actual lookup,
    /// so counting raw connections overstates the rate by orders of magnitude.
    ///
    /// ⚠️ THIS VALUE IS AN INSTRUMENT FLOOR, and it WILL fake a result if you read the median naively.
    /// Set to 2.0s, the first run reported a median gap of exactly 2s — i.e. traffic was arriving
    /// continuously and every window produced one "lookup" by definition. A median equal to this
    /// constant means "continuous traffic", NOT "queries every 2 seconds". Dropped to 0.5s so the floor
    /// sits well below any plausible real cadence, and `quietGaps` below is what should actually be read.
    private static let queryDebounce: TimeInterval = 0.5

    /// Gaps long enough to be a genuine re-query rather than one lookup's connection burst. This is the
    /// number that answers the movement question; the raw median is dominated by burst structure.
    private static let quietThreshold: TimeInterval = 5.0
    var quietGaps: [TimeInterval] { hitGaps.filter { $0 >= Self.quietThreshold } }
    var medianQuietGap: TimeInterval? {
        let q = quietGaps.sorted()
        guard !q.isEmpty else { return nil }
        return q[q.count / 2]
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Median gap between WPS queries — the single number that decides the movement question.
    var medianGap: TimeInterval? {
        guard !hitGaps.isEmpty else { return nil }
        let s = hitGaps.sorted()
        return s[s.count / 2]
    }

    /// Host fragments that mean "this is Apple's WPS lookup" — the exact hosts Wander's gs-loc rewrite
    /// targets. Any of these arriving at the proxy is the positive result.
    private static let targetFragments = ["gs-loc", "ls.apple.com", "iphone-services.apple.com"]

    func start() {
        stop()
        lastError = nil
        sawTarget = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                lastError = "Bad port"
                return
            }
            // 🔒 BIND LOOPBACK ONLY. Without this, NWListener binds 0.0.0.0 and the phone becomes an
            // OPEN FORWARD PROXY for every device on the same Wi-Fi — anyone on the café network could
            // route traffic through it. Only locationd (on this device) is ever meant to reach us, and
            // it dials 127.0.0.1 because that is what the Wi-Fi proxy setting points at. Same defect
            // class as the desktop 0.0.0.0 bind already logged as critical in the 2026-07-18 audit.
            //
            // ⚠️ The port is specified HERE ONLY. Passing it again as `NWListener(using:on:)` while
            // `requiredLocalEndpoint` already carries a port makes Network framework reject the
            // listener with POSIX EINVAL (22) — "could not bind port 8888: invalid argument". The two
            // are alternative ways to say the same thing, not complementary.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
            let l = try NWListener(using: params)
            let q = queue
            let log = makeLog()
            let noter = makeNoter()
            l.newConnectionHandler = { conn in
                Self.handle(ConnBox(conn), queue: q, log: log, note: noter)
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.append("Proxy listening on 127.0.0.1:\(self.port)", hit: false)
                    case .failed(let e):
                        self.isRunning = false
                        self.lastError = "Listener failed: \(e.localizedDescription)"
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = "Could not bind port \(port): \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    func clearLog() {
        lines.removeAll()
        sawTarget = false
        hitGaps.removeAll()
        lastHitAt = nil
    }

    private func makeLog() -> @Sendable (String, Bool) -> Void {
        return { [weak self] text, isHit in
            Task { @MainActor in
                guard let self else { return }
                if isHit { self.sawTarget = true }
                self.append(text, hit: isHit)
            }
        }
    }

    private func makeNoter() -> @Sendable (String, Bool) -> Void {
        return { [weak self] host, ok in
            Task { @MainActor in self?.note(host: host, upstreamOK: ok) }
        }
    }

    private func append(_ text: String, hit: Bool) {
        let now = Date()
        var stamped = Self.clock.string(from: now) + "  " + text
        if hit {
            // DEBOUNCED. Only a connection at least `queryDebounce` after the previous one counts as a
            // new logical lookup. Raw connections massively overstate the rate — the first run of this
            // probe reported ~2000 "queries" in 30s with a median gap of 0, which was TLS setup plus a
            // retry storm, not locationd re-querying.
            if let last = lastHitAt {
                let gap = now.timeIntervalSince(last)
                if gap >= Self.queryDebounce {
                    hitGaps.append(gap)
                    stamped += String(format: "   [+%.0fs since last WPS]", gap)
                    lastHitAt = now
                } else {
                    stamped += "   (same lookup)"
                }
            } else {
                stamped += "   [first WPS]"
                lastHitAt = now
            }
        }
        lines.append(LogLine(text: stamped, isHit: hit))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    /// Tally a host and note whether reaching it upstream worked. Called off the main actor.
    fileprivate func note(host: String, upstreamOK: Bool) {
        hostCounts[host, default: 0] += 1
        if !upstreamOK { upstreamFailures += 1 }
    }

    /// Hosts sorted by traffic — the diagnostic that says whether we're watching locationd or a storm.
    var topHosts: [(host: String, count: Int)] {
        hostCounts.sorted { $0.value > $1.value }.prefix(6).map { (host: $0.key, count: $0.value) }
    }
    var totalConnections: Int { hostCounts.values.reduce(0, +) }

    // MARK: - Off-main-actor socket handling

    nonisolated private static func handle(_ client: ConnBox,
                                           queue: DispatchQueue,
                                           log: @escaping @Sendable (String, Bool) -> Void,
                                           note: @escaping @Sendable (String, Bool) -> Void) {
        client.conn.start(queue: queue)
        readRequestLine(client, buffer: Data(), queue: queue, log: log, note: note)
    }

    nonisolated private static func readRequestLine(_ client: ConnBox,
                                                    buffer: Data,
                                                    queue: DispatchQueue,
                                                    log: @escaping @Sendable (String, Bool) -> Void,
                                                    note: @escaping @Sendable (String, Bool) -> Void) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            if let crlf = buf.range(of: Data([0x0d, 0x0a])) {
                let line = String(decoding: buf.subdata(in: buf.startIndex..<crlf.lowerBound), as: UTF8.self)
                dispatchLine(line, client: client, initialBuffer: buf, queue: queue, log: log, note: note)
                return
            }
            if error != nil || isComplete { client.conn.cancel(); return }
            if buf.count > 65536 { client.conn.cancel(); return }
            readRequestLine(client, buffer: buf, queue: queue, log: log, note: note)
        }
    }

    nonisolated private static func dispatchLine(_ line: String,
                                                 client: ConnBox,
                                                 initialBuffer: Data,
                                                 queue: DispatchQueue,
                                                 log: @escaping @Sendable (String, Bool) -> Void,
                                                 note: @escaping @Sendable (String, Bool) -> Void) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { client.conn.cancel(); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let isHit = targetFragments.contains { target.contains($0) }

        // LOG FIRST — this is the proof, and it lands even if forwarding below fails.
        log("\(method) \(target)", isHit)
        if isHit {
            log("★★★ WPS lookup hit the proxy — locationd IS honoring it", true)
        }

        if method == "CONNECT" {
            let hp = parseHostPort(target, defaultPort: 443)
            connectUpstream(host: hp.host, port: hp.port, queue: queue) { upstream in
                note(hp.host, upstream != nil)
                guard let upstream else { client.conn.cancel(); return }
                let ok = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.conn.send(content: ok, completion: .contentProcessed { _ in
                    pumpClientToSocket(client: client, upstream: upstream, queue: queue)
                    pumpSocketToClient(upstream: upstream, client: client, queue: queue)
                })
            }
        } else {
            // Absolute-form origin request (plain HTTP): GET http://host/path HTTP/1.1
            guard let host = hostFromAbsoluteURI(target) ?? hostFromHeaders(initialBuffer) else {
                client.conn.cancel(); return
            }
            connectUpstream(host: host, port: 80, queue: queue) { upstream in
                note(host, upstream != nil)
                guard let upstream else { client.conn.cancel(); return }
                guard upstream.writeAll(initialBuffer) else { upstream.close(); client.conn.cancel(); return }
                pumpClientToSocket(client: client, upstream: upstream, queue: queue)
                pumpSocketToClient(upstream: upstream, client: client, queue: queue)
            }
        }
    }

    /// Dial upstream on a RAW BSD SOCKET, never NWConnection.
    ///
    /// THE LOOP BUG, and why this is not a style preference: Network framework connections are
    /// proxy-eligible by default — `nw_parameters_set_prefer_no_proxy` is documented as defaulting to
    /// FALSE. So while iOS is configured to send Wi-Fi traffic to 127.0.0.1:8888, our own upstream
    /// NWConnection was itself handed to 127.0.0.1:8888 — this listener. Every loop "succeeded"
    /// instantly (we always accept), which is why the probe showed thousands of connections with ~zero
    /// upstream failures, and why Wi-Fi lost internet: nothing ever reached Apple.
    ///
    /// `preferNoProxies` is NOT the fix — it is documented to fall back to the configured proxy when a
    /// direct attempt fails, i.e. it restores the loop exactly on flaky networks: works in testing,
    /// breaks in the field, impossible to reproduce. `connect(2)` has no userspace layer beneath it
    /// that could re-route, so the socket is the guarantee.
    nonisolated private static func connectUpstream(host: String,
                                                    port: UInt16,
                                                    queue: DispatchQueue,
                                                    completion: @escaping @Sendable (RawSocketConnection?) -> Void) {
        // Belt-and-braces against the loop: never dial our own listening port. Scoped to the PORT, not
        // to all of loopback, so legitimate loopback legs stay possible later.
        guard port != Self.listenPort else { completion(nil); return }
        queue.async {
            let sock = try? RawSocketConnection.connect(host: host, port: port, timeout: 10)
            completion(sock)
        }
    }

    /// Client (NWConnection) -> upstream (raw socket). Recurses per chunk; tears down both on EOF.
    nonisolated private static func pumpClientToSocket(client: ConnBox,
                                                       upstream: RawSocketConnection,
                                                       queue: DispatchQueue) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                upstream.close(); client.conn.cancel(); return
            }
            guard upstream.writeAll(data) else {
                upstream.close(); client.conn.cancel(); return
            }
            if isComplete || error != nil {
                upstream.close(); client.conn.cancel(); return
            }
            pumpClientToSocket(client: client, upstream: upstream, queue: queue)
        }
    }

    /// Upstream (raw socket) -> client (NWConnection). The socket read is BLOCKING, so this owns a
    /// queue slot for the life of the connection — acceptable here because the concurrent queue grows
    /// as needed and a MITM proxy is inherently one-thread-per-flow at this scale.
    nonisolated private static func pumpSocketToClient(upstream: RawSocketConnection,
                                                       client: ConnBox,
                                                       queue: DispatchQueue) {
        queue.async {
            while let chunk = upstream.read() {
                let sem = DispatchSemaphore(value: 0)
                var ok = true
                client.conn.send(content: chunk, completion: .contentProcessed { err in
                    ok = (err == nil)
                    sem.signal()
                })
                sem.wait()
                if !ok { break }
            }
            upstream.close()
            client.conn.cancel()
        }
    }

    // MARK: - Tiny parsers

    nonisolated private static func parseHostPort(_ s: String, defaultPort: UInt16) -> (host: String, port: UInt16) {
        if let colon = s.lastIndex(of: ":") {
            let host = String(s[s.startIndex..<colon])
            let portStr = String(s[s.index(after: colon)...])
            return (host, UInt16(portStr) ?? defaultPort)
        }
        return (s, defaultPort)
    }

    nonisolated private static func hostFromAbsoluteURI(_ uri: String) -> String? {
        guard let r = uri.range(of: "://") else { return nil }
        let afterScheme = uri[r.upperBound...]
        let hostPort = afterScheme.prefix { $0 != "/" }
        let host = hostPort.prefix { $0 != ":" }
        return host.isEmpty ? nil : String(host)
    }

    nonisolated private static func hostFromHeaders(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("host:") {
            return line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
