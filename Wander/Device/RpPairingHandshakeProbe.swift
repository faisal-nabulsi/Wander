//
//  RpPairingHandshakeProbe.swift
//  Wander
//
//  DOES remotepairingd TALK BACK WHEN WE DIAL IT WITH NO TUNNEL?
//
//  ─── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
//  A bounded TCP connect to 127.0.0.1:49152 on pure cellular returns errno 0 in 0 ms. That is a
//  measured fact. It is also the WEAKEST possible evidence, because a completed TCP handshake only
//  proves the kernel's listen backlog accepted a SYN. It says nothing about whether remotepairingd
//  then called accept(), looked at who we are, and hung up — which is exactly what the folklore
//  ("lockdownd rejects a source IP the device already holds", and 127.0.0.1 obviously is one) claims
//  happens. TCP-level success and policy-level rejection look IDENTICAL to EndpointProbe.
//
//  So this probe goes one layer up. It speaks the first message of the RemotePairing protocol by hand
//  and reports whether ANY bytes come back. That single fact splits the two worlds:
//
//    • bytes come back  → remotepairingd is willing to converse with this source. The premise that a
//                         tunnel exists to launder the source address is WRONG at this layer, and the
//                         no-tunnel path is worth pursuing.
//    • no bytes / EOF   → it accepted the socket and then refused to speak. The old rule is confirmed
//                         empirically for the first time, and we can stop trying.
//
//  ─── WHY NOT JUST POINT WANDER AT 127.0.0.1 AND TRY A TELEPORT ───────────────────────────────────
//  Because that test cannot report the interesting outcome, and can wedge the app while failing to.
//  The vendored FFI's `tunnel_create_rppairing` (ffi/src/tunnel_provider.rs) dials with a bare
//  `tokio::net::TcpStream::connect` and then reads the reply with `read_exact` — NO timeout anywhere
//  (the upstream `run_global_timeout` wrapper landed 2026-06-23 and is NOT in the vendored .a; there
//  is no `idevice_set_global_timeout` symbol in it). If the daemon accepts and then simply never
//  answers — the precise outcome the StikDebug PR predicts, and the one we most want to distinguish —
//  the FFI blocks forever on the serial location queue and Stop/Panic go with it. This probe owns its
//  own bounded poll() on every read and write, so "it went quiet" is a RESULT, not a hang.
//
//  ─── THE MESSAGE WE SEND ─────────────────────────────────────────────────────────────────────────
//  Byte-for-byte the FFI's first write, so a reply here means a reply there. Two sources, both read
//  rather than guessed:
//    • framing — idevice/src/remote_pairing/socket.rs, `RpPairingSocket::send_rppairing`:
//        b"RPPairing" ++ u16-big-endian(len(json)) ++ json
//    • payload — idevice/src/remote_pairing/mod.rs, `RemotePairingClient::attempt_pair_verify`,
//      wrapped by `send_plain`'s envelope.
//  It is the UNAUTHENTICATED opening handshake: no pairing file, no keys, nothing secret. That is
//  what makes it safe to fire by hand and what makes a reply meaningful — the device answers it
//  before it has any reason to trust us, so a refusal to answer is a decision about the SOURCE.
//
//  ─── WHAT getsockname() IS DOING HERE ────────────────────────────────────────────────────────────
//  It is the whole point, not a footnote. The believed lockdownd rule is about the SOURCE address of
//  the connection, and nothing in this codebase has ever recorded what the kernel actually chose. For
//  a 127.0.0.1 destination it will be 127.0.0.1 — a device-owned address, the exact shape the rule is
//  said to reject. For a 172.20.10.1 (Personal Hotspot bridge100) destination with no client attached
//  it will also be 172.20.10.1, i.e. source == destination == an address the device holds. Printing it
//  turns "we think the source was X" into "the source WAS X".
//
//  BLOCKING. Run it off the main thread and off `LocationSimulationCommandQueue`.
//

import Foundation
import Darwin

// MARK: - What one handshake attempt found

/// How far the conversation got. Ordered roughly by how far through the exchange we reached, because
/// that ordering IS the diagnosis.
enum RpPairingProbeStage: String, Sendable {
    /// The string wasn't a valid IP literal, or a source address we were asked to bind wasn't.
    case invalidAddress
    /// socket()/bind()/fcntl() failed on our side. Nothing went on the wire.
    case localFailure
    /// The TCP handshake never completed. `EndpointProbe`'s territory; included so this probe can be
    /// run standalone without needing the other one first.
    case connectFailed
    /// Connected, but our own write failed or could not drain inside the bound.
    case writeFailed
    /// Connected, the request went out in full, and the bounded wait expired with NOTHING back.
    /// No FIN, no RST — the daemon is holding the socket open and saying nothing.
    case silentAfterRequest
    /// Connected, request sent, and the peer closed cleanly (read returned 0).
    case closedAfterRequest
    /// Connected, request sent, and the peer sent a RST (ECONNRESET).
    case resetAfterRequest
    /// Bytes came back but they were not an RPPairing frame.
    case repliedNotRpPairing
    /// A well-formed RPPairing frame came back. The daemon is talking to us.
    case replied

    var label: String {
        switch self {
        case .invalidAddress:      return "INVALID ADDRESS"
        case .localFailure:        return "LOCAL FAILURE"
        case .connectFailed:       return "CONNECT FAILED"
        case .writeFailed:         return "WRITE FAILED"
        case .silentAfterRequest:  return "SILENT"
        case .closedAfterRequest:  return "CLOSED ON US"
        case .resetAfterRequest:   return "RESET"
        case .repliedNotRpPairing: return "REPLIED (unrecognised framing)"
        case .replied:             return "REPLIED"
        }
    }

    /// Plain English, aimed at the person deciding what to try next — not at someone who already
    /// knows the protocol.
    var meaning: String {
        switch self {
        case .invalidAddress:
            return "not a valid IP literal — nothing was sent."
        case .localFailure:
            return "a socket call failed on this phone before anything went on the wire. Says nothing about the daemon."
        case .connectFailed:
            return "the TCP handshake never completed, so the daemon was never reached. Read the errno."
        case .writeFailed:
            return "the socket connected but our request could not be written. The peer went away between the handshake and the first byte."
        case .silentAfterRequest:
            return "the daemon ACCEPTED the connection, took the whole request, and answered nothing — it did not close and it did not reset. It is ignoring us, deliberately."
        case .closedAfterRequest:
            return "the daemon ACCEPTED the connection, took the request, and then closed it cleanly without a word. That is a policy rejection after accept() — the classic shape of a source-address check."
        case .resetAfterRequest:
            return "the daemon ACCEPTED the connection, took the request, then RST it. Policy rejection, delivered rudely."
        case .repliedNotRpPairing:
            return "something answered, but not with an RPPairing frame. Whatever is on that port is not remotepairingd."
        case .replied:
            return "remotepairingd ANSWERED. It is willing to hold an RPPairing conversation sourced from this address — the source-address rule does NOT bite at this layer."
        }
    }

    /// True when the peer got as far as accepting our bytes. Everything from here up is a statement
    /// about POLICY; everything below it is a statement about the network.
    var reachedTheDaemon: Bool {
        switch self {
        case .invalidAddress, .localFailure, .connectFailed, .writeFailed: return false
        default: return true
        }
    }
}

/// One handshake attempt, fully described.
struct RpPairingProbeResult: Sendable {
    let address: String
    let port: UInt16
    let stage: RpPairingProbeStage
    /// The errno captured at the failing syscall, or 0 when the kernel never set one. Never invented.
    let errnoValue: Int32
    /// Which call produced `errnoValue`, so a local failure can never be read as a network verdict.
    let syscall: String
    /// What `getsockname()` said the kernel chose as our source. The crux of the whole question.
    let localEndpoint: String?
    /// Source address we asked the kernel for with bind(), if any.
    let requestedSource: String?
    let bytesSent: Int
    let bytesReceived: Int
    /// Decoded body of the reply frame, capped. Empty when nothing was decodable.
    let replyBody: String
    let elapsedMilliseconds: Int

    var destination: String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    var errnoName: String { EndpointProbe.errnoName(errnoValue) }

    var errnoText: String {
        guard errnoValue != 0, let raw = strerror(errnoValue) else { return "no errno was set" }
        return String(cString: raw)
    }

    /// Everything after the destination, in the same shape `EndpointProbeResult.detail` uses so the
    /// two probes read as one family in the log.
    var detail: String {
        var s = "→ \(stage.label)"
        if errnoValue != 0 {
            s += " errno \(errnoValue) \(errnoName) (\(errnoText)) via \(syscall)"
        }
        s += " · sent \(bytesSent)B, received \(bytesReceived)B"
        if let localEndpoint {
            s += " · SOURCE \(localEndpoint)"
        }
        if let requestedSource {
            s += " (bind requested \(requestedSource))"
        }
        s += " · \(elapsedMilliseconds) ms"
        return s
    }

    var logLine: String { "rppairing \(destination) \(detail)" }
}

// MARK: - The probe

enum RpPairingHandshakeProbe {

    /// The 9-byte frame magic. `idevice/src/remote_pairing/mod.rs`: `const RPPAIRING_MAGIC = b"RPPairing"`.
    static let magic = Array("RPPairing".utf8)

    /// `WIRE_PROTOCOL_VERSION` in the same file. Sent verbatim; if the device disagrees with it we
    /// still learn what we came for, because disagreeing is a REPLY.
    static let wireProtocolVersion = 19

    /// The exact JSON the FFI's first write carries. Written as a literal rather than assembled from a
    /// dictionary ON PURPOSE: a diagnostic's value is that a reader can check it against the Rust by
    /// eye, and `JSONSerialization` would order the keys however it liked and bridge `true` through
    /// NSNumber on the way.
    ///
    /// Envelope from `RpPairingSocket::send_plain`; payload from `attempt_pair_verify`.
    static var handshakeJSON: String {
        "{\"message\":{\"plain\":{\"_0\":{\"request\":{\"_0\":{\"handshake\":{\"_0\":"
        + "{\"hostOptions\":{\"attemptPairVerify\":true},"
        + "\"wireProtocolVersion\":\(wireProtocolVersion)}}}}}}},"
        + "\"originatedBy\":\"host\",\"sequenceNumber\":0}"
    }

    /// The framed bytes actually put on the wire.
    static func handshakeFrame() -> [UInt8] {
        let body = Array(handshakeJSON.utf8)
        var frame = magic
        // u16, big-endian, exactly as `send_rppairing` writes it.
        frame.append(UInt8((body.count >> 8) & 0xFF))
        frame.append(UInt8(body.count & 0xFF))
        frame.append(contentsOf: body)
        return frame
    }

    /// How much of a reply we keep. The opening response is a few hundred bytes; this is generous
    /// enough to hold it whole and small enough that a hostile or confused peer cannot make us grow.
    static let maxReplyBytes = 8192
    /// How much of the decoded reply gets printed. It is the user's own device, but the response can
    /// name it, so the log gets a capped excerpt rather than an unbounded dump.
    static let maxLoggedReplyCharacters = 900

    // MARK: One attempt

    /// Dial `address:port`, send the opening RemotePairing handshake, and report what came back.
    ///
    /// - Parameters:
    ///   - sourceAddress: optional local address to `bind()` before connecting. This is the one knob
    ///     the StikDebug PR is actually about — it wants the daemon to see a source that is NOT the
    ///     destination. Leave nil for the honest default the kernel would pick.
    ///   - connectTimeoutSeconds: bound on the TCP handshake.
    ///   - replyTimeoutSeconds: bound on waiting for the first reply byte. Deliberately longer than
    ///     the connect bound: "it connected instantly and then thought about it for four seconds
    ///     before hanging up" is a different finding from "it never answered", and too tight a bound
    ///     would erase the difference.
    ///
    /// Never throws, never traps, never blocks longer than the two bounds combined.
    static func probe(_ address: String,
                      port: UInt16 = DeviceConnectionContext.developerTunnelPort,
                      sourceAddress: String? = nil,
                      connectTimeoutSeconds: Double = 3,
                      replyTimeoutSeconds: Double = 6) -> RpPairingProbeResult {

        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int { Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000) }

        var localEndpoint: String?
        var sent = 0
        var received = 0
        var body = ""

        func result(_ stage: RpPairingProbeStage, _ code: Int32, _ syscall: String) -> RpPairingProbeResult {
            RpPairingProbeResult(address: address, port: port, stage: stage,
                                 errnoValue: code, syscall: syscall,
                                 localEndpoint: localEndpoint, requestedSource: sourceAddress,
                                 bytesSent: sent, bytesReceived: received, replyBody: body,
                                 elapsedMilliseconds: elapsed())
        }

        guard let endpoint = DeviceConnectionContext.makeSocketAddress(address, port: port) else {
            return result(.invalidAddress, 0, "inet_pton(destination)")
        }

        let fd = socket(endpoint.family, SOCK_STREAM, 0)
        let socketErrno = errno   // captured in the statement immediately after the syscall
        guard fd >= 0 else { return result(.localFailure, socketErrno, "socket") }
        defer { close(fd) }

        // Optional source bind, BEFORE connect. Port 0 so the kernel picks the ephemeral port.
        if let sourceAddress {
            guard let source = DeviceConnectionContext.makeSocketAddress(sourceAddress, port: 0) else {
                return result(.invalidAddress, 0, "inet_pton(source)")
            }
            var bindErrno: Int32 = 0
            let bindRC = source.withSockaddr { pointer, length -> Int32 in
                let returned = bind(fd, pointer, length)
                bindErrno = errno
                return returned
            }
            if bindRC != 0 { return result(.localFailure, bindErrno, "bind(source)") }
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // ── TCP handshake, bounded ───────────────────────────────────────────────────────────────
        var connectErrno: Int32 = 0
        let connectRC = endpoint.withSockaddr { pointer, length -> Int32 in
            let returned = connect(fd, pointer, length)
            connectErrno = errno
            return returned
        }
        if connectRC != 0 {
            if connectErrno != EINPROGRESS {
                return result(.connectFailed, connectErrno, "connect")
            }
            switch waitFor(fd, events: Int16(POLLOUT), seconds: connectTimeoutSeconds) {
            case .failed(let code, let call):
                return result(.localFailure, code, call)
            case .timedOut:
                return result(.connectFailed, 0, "poll(POLLOUT) — bounded wait expired")
            case .ready:
                // The async connect's real reason lives in SO_ERROR, never in errno.
                var soError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                let getRC = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
                let getErrno = errno
                guard getRC == 0 else { return result(.localFailure, getErrno, "getsockopt(SO_ERROR)") }
                if soError != 0 {
                    return result(.connectFailed, soError, "connect (async, read from SO_ERROR)")
                }
            }
        }

        // THE MEASUREMENT THE WHOLE THEORY TURNS ON: what did the kernel pick as our source?
        localEndpoint = describeLocalEndpoint(fd)

        // ── Send the opening handshake, bounded ──────────────────────────────────────────────────
        let frame = handshakeFrame()
        switch writeAll(fd, frame, seconds: connectTimeoutSeconds) {
        case .failed(let written, let code, let call):
            sent = written
            return result(.writeFailed, code, call)
        case .wrote(let written):
            sent = written
        }

        // ── Wait for the reply, bounded ──────────────────────────────────────────────────────────
        switch waitFor(fd, events: Int16(POLLIN), seconds: replyTimeoutSeconds) {
        case .failed(let code, let call):
            return result(.localFailure, code, call)
        case .timedOut:
            // Accepted us, swallowed the request, said nothing, did not close. The "stall".
            return result(.silentAfterRequest, 0, "poll(POLLIN) — bounded wait expired")
        case .ready:
            break
        }

        var buffer = [UInt8](repeating: 0, count: maxReplyBytes)
        let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
            read(fd, raw.baseAddress, raw.count)
        }
        let readErrno = errno
        if readCount < 0 {
            let stage: RpPairingProbeStage = (readErrno == ECONNRESET) ? .resetAfterRequest : .localFailure
            return result(stage, readErrno, "read")
        }
        if readCount == 0 {
            // Clean FIN with no payload: accepted, read our bytes, hung up without answering.
            return result(.closedAfterRequest, 0, "read (EOF)")
        }

        received = readCount
        let reply = Array(buffer.prefix(readCount))
        body = decodeReply(reply)
        let looksLikeRpPairing = reply.count >= magic.count && Array(reply.prefix(magic.count)) == magic
        return result(looksLikeRpPairing ? .replied : .repliedNotRpPairing, 0, "read")
    }

    // MARK: Bounded socket helpers

    private enum WaitOutcome {
        case ready
        case timedOut
        case failed(Int32, String)
    }

    private static func waitFor(_ fd: Int32, events: Int16, seconds: Double) -> WaitOutcome {
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let milliseconds = Int32(max(seconds, 0.1) * 1000)
        let rc = poll(&pfd, 1, milliseconds)
        let pollErrno = errno
        if rc == 0 { return .timedOut }
        if rc < 0 { return .failed(pollErrno, "poll") }
        return .ready
    }

    private enum WriteOutcome {
        case wrote(Int)
        case failed(Int, Int32, String)   // bytes written so far, errno, syscall
    }

    /// Write every byte or say exactly where it stopped. The socket is non-blocking, so a short write
    /// is normal and must be looped — treating one as a failure would invent a finding.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], seconds: Double) -> WriteOutcome {
        var offset = 0
        let deadline = Date().addingTimeInterval(max(seconds, 0.1))
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            let writeErrno = errno
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (writeErrno == EAGAIN || writeErrno == EINTR) {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .failed(offset, 0, "write — bounded wait expired") }
                switch waitFor(fd, events: Int16(POLLOUT), seconds: remaining) {
                case .ready:    continue
                case .timedOut: return .failed(offset, 0, "poll(POLLOUT) — bounded wait expired")
                case .failed(let code, let call): return .failed(offset, code, call)
                }
            }
            return .failed(offset, writeErrno, "write")
        }
        return .wrote(offset)
    }

    /// `getsockname()` rendered as `ip:port`. Returns nil rather than a guess if it cannot be read —
    /// this value is evidence, and a plausible-looking invention would be worse than a blank.
    private static func describeLocalEndpoint(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let nameRC = withUnsafePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, length,
                            &host, socklen_t(host.count),
                            &service, socklen_t(service.count),
                            NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard nameRC == 0 else { return nil }
        let ip = String(cString: host)
        let portText = String(cString: service)
        return ip.contains(":") ? "[\(ip)]:\(portText)" : "\(ip):\(portText)"
    }

    /// Turn the reply into something readable: the JSON body if it is a well-formed RPPairing frame,
    /// otherwise a hex prefix so an unexpected peer is still identifiable.
    private static func decodeReply(_ bytes: [UInt8]) -> String {
        if bytes.count >= magic.count + 2, Array(bytes.prefix(magic.count)) == magic {
            let declared = (Int(bytes[magic.count]) << 8) | Int(bytes[magic.count + 1])
            let start = magic.count + 2
            let available = bytes.count - start
            let take = min(declared, available)
            let text = String(decoding: bytes[start ..< start + max(take, 0)], as: UTF8.self)
            var out = "declared body \(declared)B, have \(available)B — \(text)"
            if take < declared { out += " …(frame truncated: the rest had not arrived yet)" }
            return String(out.prefix(maxLoggedReplyCharacters))
        }
        let hex = bytes.prefix(64).map { String(format: "%02x", $0) }.joined()
        return "non-RPPairing bytes, first \(min(bytes.count, 64))B hex: \(hex)"
    }
}

// MARK: - One tap, the whole no-tunnel question

extension RpPairingHandshakeProbe {

    /// The destinations worth asking, in the order the answers matter.
    ///
    /// Kept separate from `TunnelEndpointSweep.destinations()` on purpose: that sweep asks "does port
    /// 49152 answer a SYN anywhere?" and wants breadth. This one costs up to `replyTimeout` per
    /// destination, so it asks only the three that can change the conclusion.
    static func destinations() -> [(label: String, address: String, source: String?)] {
        var out: [(String, String, String?)] = [
            // 1. The headline. F1 says this ACCEPTS a TCP connection on pure cellular. Does the daemon
            //    behind it actually speak?
            ("loopback — the no-tunnel question itself", "127.0.0.1", nil)
        ]

        // 2. Whatever Wander is configured to dial, when that is something else. If a tunnel is up this
        //    is the control: it is the path already known to work, so a reply here and silence at
        //    127.0.0.1 is the cleanest possible statement that the tunnel is doing real work.
        let configured = DeviceConnectionContext.targetIPAddress
        if configured != "127.0.0.1" {
            out.append(("configured tunnel target — the path Wander dials today", configured, nil))
        }

        // 3. The StikDebug PR's claim: hotspot on, cellular only, DIRECT connect, no tunnel. Only
        //    meaningful while bridge100 actually exists, and iOS drops the bridge ~90 s after the last
        //    client detaches — so if this line is missing from the report, the hotspot was already gone.
        let entries = WiFiSubnet.allAddresses()
        if entries.contains(where: { $0.name == "bridge100" && $0.isUp }) {
            out.append(("hotspot bridge100 gateway — the StikDebug PR's claim, no tunnel",
                        TunnelEndpointSweep.hotspotGatewayAddress, nil))
        }
        return out
    }

    /// Probe every destination, write the full record to the Console, and return a short summary.
    ///
    /// BLOCKING. Background queue only — never the main thread, never `LocationSimulationCommandQueue`.
    static func runAndSummarize(reason: String = "manual") -> String {
        let targets = destinations()
        var results: [(String, RpPairingProbeResult)] = []

        var lines: [String] = []
        lines.append("=== RPPAIRING HANDSHAKE PROBE === port \(DeviceConnectionContext.developerTunnelPort) · reason: \(reason)")
        lines.append("os: \(ProcessInfo.processInfo.operatingSystemVersionString) · \(targets.count) destination(s)")
        lines.append("sending the FFI's own first message: \"RPPairing\" + u16 length + \(handshakeFrame().count - magic.count - 2)B of JSON (attemptPairVerify, wireProtocolVersion \(wireProtocolVersion))")
        lines.append("NO tunnel is required for this probe and none is created. It never touches the pairing file.")

        for (index, target) in targets.enumerated() {
            let result = probe(target.address, sourceAddress: target.source)
            results.append((target.label, result))
            lines.append("  [\(index + 1)/\(targets.count)] \(target.label) — \(result.logLine)")
            if !result.replyBody.isEmpty {
                lines.append("      reply: \(result.replyBody)")
            }
            lines.append("      means: \(result.stage.meaning)")
        }

        lines.append(contentsOf: verdictLines(results))
        lines.append("=== END RPPAIRING HANDSHAKE PROBE ===")

        for line in lines { LogManager.shared.addInfoLog(line) }
        // Same retention the interface dump and the endpoint sweep use, so opening the Console to read
        // this cannot wipe it (`loadIdeviceLogsAsync` REPLACES the buffer with what it parses off disk).
        NetworkInterfaceDump.retain(lines)

        return shortSummary(results)
    }

    /// The lines that answer the question, so nobody has to decode stages by hand.
    static func verdictLines(_ results: [(String, RpPairingProbeResult)]) -> [String] {
        guard !results.isEmpty else { return ["VERDICT: nothing was probed."] }

        var out: [String] = []
        let replied = results.filter { $0.1.stage == .replied }
        let rejectedAfterAccept = results.filter {
            $0.1.stage == .closedAfterRequest || $0.1.stage == .resetAfterRequest
        }
        let silent = results.filter { $0.1.stage == .silentAfterRequest }
        let neverReached = results.filter { !$0.1.stage.reachedTheDaemon }

        func list(_ xs: [(String, RpPairingProbeResult)]) -> String {
            xs.isEmpty ? "NONE" : xs.map { "\($0.1.destination) (source \($0.1.localEndpoint ?? "unknown"))" }
                                   .joined(separator: ", ")
        }

        out.append("VERDICT answered with an RPPairing frame: " + list(replied))
        out.append("VERDICT accepted then closed/reset without answering: " + list(rejectedAfterAccept))
        out.append("VERDICT accepted then went silent (no close, no answer): " + list(silent))
        out.append("VERDICT never reached a daemon at all: " + list(neverReached))

        if let loopback = results.first(where: { $0.1.address == "127.0.0.1" })?.1 {
            out.append("VERDICT loopback 127.0.0.1 → \(loopback.stage.label): \(loopback.stage.meaning)")
            if loopback.stage == .replied {
                out.append("VERDICT ⇒ THE NO-TUNNEL PATH IS OPEN AT THIS LAYER. remotepairingd answered a connection sourced from an address the device owns. Next question is whether pair-verify also passes — set the tunnel target to 127.0.0.1 and attempt a real spoof, but expect it to HANG rather than fail if the daemon stops answering later (the vendored FFI has no read timeout).")
            } else if loopback.stage.reachedTheDaemon {
                out.append("VERDICT ⇒ THE OLD RULE IS CONFIRMED, and this is the first time it has been measured rather than assumed. The TCP connect succeeding (errno 0) was never evidence of anything: the daemon accepts the socket and then refuses to converse with a device-owned source. A tunnel is not optional plumbing — it exists to give the connection a source address the daemon will talk to.")
            } else {
                out.append("VERDICT ⇒ INCONCLUSIVE about policy: the connection never got far enough to ask the question. Fix the transport first, then re-run.")
            }
        }

        // The hotspot line only exists when bridge100 was up, so its absence is itself information.
        if let hotspot = results.first(where: { $0.1.address == TunnelEndpointSweep.hotspotGatewayAddress })?.1 {
            out.append("VERDICT hotspot 172.20.10.1 (the StikDebug PR's claim) → \(hotspot.stage.label): \(hotspot.stage.meaning)")
            if let source = hotspot.localEndpoint, source.hasPrefix("172.20.10.1:") {
                out.append("VERDICT ⇒ note the source the kernel chose for it: \(source). Destination and source are the SAME device-owned address, because with no client attached the phone is the only host on that /28. Any test of the hotspot path that does not bind a different source is not testing anything new.")
            }
        } else {
            out.append("VERDICT hotspot 172.20.10.1 was NOT probed — bridge100 was not up. iOS drops the bridge about 90 s after the last client detaches, so re-enable Personal Hotspot and run this again within that window.")
        }

        return out
    }

    private static func shortSummary(_ results: [(String, RpPairingProbeResult)]) -> String {
        guard !results.isEmpty else { return "No destinations could be read, so nothing was probed." }
        let tally = results.reduce(into: [String: Int]()) { $0[$1.1.stage.label, default: 0] += 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        let headline = results[0].1
        return "\(results.count) probed: \(tally).\n"
            + "\(headline.destination) → \(headline.stage.label) (source \(headline.localEndpoint ?? "unknown")).\n\n"
            + "Full detail and the verdict are in the log below — use Export Logs to send it."
    }
}
