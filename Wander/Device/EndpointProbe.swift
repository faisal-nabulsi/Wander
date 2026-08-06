//
//  EndpointProbe.swift
//  Wander
//
//  ONE bounded TCP reachability probe, and it REPORTS WHY IT FAILED.
//
//  WHY THIS EXISTS. Every tunnel failure in this app used to arrive as the same sentence — "Can't
//  reach the device tunnel" — because the two probes that gate the dial path
//  (`JITEnableContext.isTunnelEndpointReachable` and `_isSimEndpointReachable`) returned a bare Bool
//  and threw the kernel's answer away. That single sentence covers three completely different
//  failures with three completely different fixes:
//
//    • ECONNREFUSED (61) — a RST came back. Packets ARE flowing and a daemon actively refused them.
//                          The destination is reachable; something decided to say no. POLICY.
//    • ENETUNREACH (51) / EHOSTUNREACH (65) — no route. The packet never left the phone. ROUTING.
//    • no answer at all — the SYN left and vanished. Nothing refused it, nothing routed it back.
//                          BLACKHOLE.
//
//  Measured 2026-08-05: the tunnel was moved to 172.20.10.4/30 alongside a Personal Hotspot bridge
//  (bridge100 owning 172.20.10.0/28), the /30 installed correctly, and the interface dump confirmed
//  the dialled address PASSES the believed lockdownd source-address test — and the dial still failed.
//  Either the believed rule is incomplete (would show as 61) or the packets never route into the
//  tunnel at all (would show as 51). The old Bool cannot tell those apart. This can.
//
//  ERRNO CAPTURE IS THE WHOLE POINT, so it is done with care: `errno` is a thread-local that ANY
//  subsequent libc call can overwrite, and reading it one line too late is the classic way this
//  diagnostic silently reports the wrong number. Every capture below happens in the statement
//  immediately after the syscall — for `connect` that means INSIDE the `withSockaddr` closure, before
//  the closure can even unwind. For an asynchronous (non-blocking) connect the real reason is NOT in
//  `errno` at all: it is in `SO_ERROR`, and that is what gets reported for that path.
//

import Foundation
import Darwin

// MARK: - What the probe found

/// The classification a probe result falls into. This is the question the owner is actually asking —
/// "is it policy, routing, or a blackhole?" — so it is modelled explicitly rather than left as a
/// number for the reader to decode.
enum EndpointProbeOutcome: String, Sendable {
    /// The TCP handshake completed. Something is listening on that port.
    case connected
    /// ECONNREFUSED / ECONNRESET — a RST came back.
    case refused
    /// ENETUNREACH / EHOSTUNREACH / ENETDOWN / EHOSTDOWN — no route.
    case noRoute
    /// ETIMEDOUT, or our bounded wait expiring with nothing at all coming back.
    case noAnswer
    /// EADDRNOTAVAIL — the address isn't one this device can source from / reach locally.
    case addressUnavailable
    /// The string wasn't a valid IP literal, so nothing was ever sent.
    case invalidAddress
    /// socket() / poll() / getsockopt() failed on OUR side; nothing reached the wire.
    case localFailure
    /// A real errno that isn't in any bucket above. The number is still reported verbatim.
    case otherError

    /// Short, shouty label for the log line.
    var label: String {
        switch self {
        case .connected:         return "CONNECTED"
        case .refused:           return "REFUSED"
        case .noRoute:           return "NO ROUTE"
        case .noAnswer:          return "NO ANSWER"
        case .addressUnavailable: return "ADDRESS UNAVAILABLE"
        case .invalidAddress:    return "INVALID ADDRESS"
        case .localFailure:      return "LOCAL FAILURE"
        case .otherError:        return "FAILED"
        }
    }

    /// Plain English, written for the person who has to decide what to change next.
    var meaning: String {
        switch self {
        case .connected:
            return "a TCP handshake completed — packets reach it and something is listening on that port."
        case .refused:
            return "a RST came back. Packets ARE flowing and a daemon actively refused — this is policy, not routing."
        case .noRoute:
            return "no route. The packet never left the phone — this is routing, not policy."
        case .noAnswer:
            return "the packet left and vanished: no RST, no route error — blackholed."
        case .addressUnavailable:
            return "the address is not available on this device, so no connection could be sourced to it."
        case .invalidAddress:
            return "not a valid IP literal — nothing was probed."
        case .localFailure:
            return "a local socket call failed before anything went on the wire — this says nothing about the network."
        case .otherError:
            return "an error outside the expected set — read the errno."
        }
    }
}

/// One probe, fully described. Built so a single `logLine` carries everything a reader needs:
/// destination, verdict, errno NUMBER, its SYMBOLIC NAME, `strerror`'s text, and how long it took.
struct EndpointProbeResult: Sendable {
    let address: String
    let port: UInt16
    let outcome: EndpointProbeOutcome
    /// The captured errno, or 0 when the kernel never set one (e.g. our bounded wait expired with no
    /// answer). Deliberately NOT faked into a plausible number — inventing an errno here would be
    /// inventing the very evidence this exists to collect.
    let errnoValue: Int32
    /// Which call produced `errnoValue`, so a local failure is never mistaken for a network verdict.
    let syscall: String
    let elapsedMilliseconds: Int

    /// Exactly the Bool the old probes returned: true ONLY on a completed handshake.
    var isReachable: Bool { outcome == .connected }

    var destination: String {
        // Bracket an IPv6 literal so `fd00::2:49152` can't be misread.
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    var errnoName: String { EndpointProbe.errnoName(errnoValue) }

    /// `strerror`'s own words for the number, so the log carries the system's description and not
    /// only ours.
    var errnoText: String {
        guard errnoValue != 0, let raw = strerror(errnoValue) else { return "no errno was set" }
        return String(cString: raw)
    }

    /// Everything after the destination — reused by the sweep, which prints its own prefix.
    var detail: String {
        var s = "→ \(outcome.label)"
        if errnoValue != 0 {
            s += " errno \(errnoValue) \(errnoName) (\(errnoText))"
        } else {
            s += " errno 0 \(errnoName) (\(errnoText))"
        }
        s += " after \(elapsedMilliseconds) ms via \(syscall)"
        return s
    }

    /// The line written to the app Console.
    var logLine: String { "probe \(destination) \(detail)" }
}

// MARK: - The probe

enum EndpointProbe {

    /// Bounded, non-blocking TCP connect. Never throws, never blocks longer than `timeoutSeconds`,
    /// and never traps — a diagnostic that can crash is worse than none.
    ///
    /// Family-agnostic: probes whatever it is handed (IPv4 or IPv6), because with the opt-in IPv6
    /// loopback the address being dialled may be a ULA and a hardcoded AF_INET probe would fail a v6
    /// dial before the v6 dial was ever tried.
    static func probe(_ address: String,
                      port: UInt16 = DeviceConnectionContext.developerTunnelPort,
                      timeoutSeconds: Double = 3) -> EndpointProbeResult {
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        }
        func result(_ outcome: EndpointProbeOutcome, _ code: Int32, _ syscall: String) -> EndpointProbeResult {
            EndpointProbeResult(address: address, port: port, outcome: outcome,
                                errnoValue: code, syscall: syscall, elapsedMilliseconds: elapsed())
        }

        guard let endpoint = DeviceConnectionContext.makeSocketAddress(address, port: port) else {
            return result(.invalidAddress, 0, "inet_pton")
        }

        let fd = socket(endpoint.family, SOCK_STREAM, 0)
        // CAPTURED IMMEDIATELY. Everything below — including `guard`'s own bookkeeping — is a chance
        // for something to overwrite the thread-local.
        let socketErrno = errno
        guard fd >= 0 else { return result(.localFailure, socketErrno, "socket") }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Read errno INSIDE the closure, in the statement directly after connect(). Reading it after
        // `withSockaddr` returned would let the closure's unwinding sit between the syscall and the
        // capture — the exact bug that makes this kind of diagnostic report a stale number.
        var connectErrno: Int32 = 0
        let rc = endpoint.withSockaddr { pointer, length -> Int32 in
            let returned = connect(fd, pointer, length)
            connectErrno = errno
            return returned
        }
        if rc == 0 { return result(.connected, 0, "connect") }
        if connectErrno != EINPROGRESS {
            // Immediate, synchronous failure: refused, no route, address unavailable…
            return result(classify(connectErrno), connectErrno, "connect")
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let waitMilliseconds = Int32(max(timeoutSeconds, 0.1) * 1000)
        let pollRC = poll(&pfd, 1, waitMilliseconds)
        let pollErrno = errno
        if pollRC == 0 {
            // The bound expired with NOTHING back — no RST, no ICMP unreachable. The kernel set no
            // errno here, and reporting one would be a fabrication; the outcome carries the meaning.
            return result(.noAnswer, 0, "poll (bounded wait expired)")
        }
        if pollRC < 0 { return result(.localFailure, pollErrno, "poll") }

        // The asynchronous connect's real reason lives in SO_ERROR, NOT in errno. Reading `errno`
        // here would report whatever the last unrelated call left behind.
        var soError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let getRC = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length)
        let getErrno = errno
        guard getRC == 0 else { return result(.localFailure, getErrno, "getsockopt(SO_ERROR)") }
        if soError == 0 { return result(.connected, 0, "connect (async)") }
        return result(classify(soError), soError, "connect (async, read from SO_ERROR)")
    }

    /// Which bucket an errno falls in. Kept tiny and total — an unrecognised code still reports its
    /// number and `strerror` text, it just isn't claimed to mean anything in particular.
    static func classify(_ code: Int32) -> EndpointProbeOutcome {
        switch code {
        case ECONNREFUSED, ECONNRESET:                  return .refused
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN: return .noRoute
        case ETIMEDOUT:                                 return .noAnswer
        case EADDRNOTAVAIL:                             return .addressUnavailable
        default:                                        return .otherError
        }
    }

    /// `61` → `"ECONNREFUSED"`. The number alone is unreadable without a copy of `errno.h` open, and
    /// the symbolic name is what every write-up about this problem actually uses.
    static func errnoName(_ code: Int32) -> String {
        if code == 0 { return "-" }
        return names[code] ?? "errno \(code)"
    }

    /// Built with `uniquingKeysWith` rather than a dictionary literal ON PURPOSE: several Darwin errno
    /// constants share a value (EAGAIN == EWOULDBLOCK), and a literal with duplicate keys traps at
    /// runtime. A diagnostic must not be able to crash the app it is diagnosing.
    private static let names: [Int32: String] = Dictionary(
        [
            (EPERM, "EPERM"), (EINTR, "EINTR"), (EBADF, "EBADF"), (EACCES, "EACCES"),
            (EFAULT, "EFAULT"), (EINVAL, "EINVAL"), (ENFILE, "ENFILE"), (EMFILE, "EMFILE"),
            (EPIPE, "EPIPE"), (EAGAIN, "EAGAIN"), (EINPROGRESS, "EINPROGRESS"),
            (EALREADY, "EALREADY"), (ENOTSOCK, "ENOTSOCK"), (EPROTOTYPE, "EPROTOTYPE"),
            (EPROTONOSUPPORT, "EPROTONOSUPPORT"), (EPFNOSUPPORT, "EPFNOSUPPORT"),
            (EAFNOSUPPORT, "EAFNOSUPPORT"), (EADDRINUSE, "EADDRINUSE"),
            (EADDRNOTAVAIL, "EADDRNOTAVAIL"), (ENETDOWN, "ENETDOWN"),
            (ENETUNREACH, "ENETUNREACH"), (ENETRESET, "ENETRESET"),
            (ECONNABORTED, "ECONNABORTED"), (ECONNRESET, "ECONNRESET"), (ENOBUFS, "ENOBUFS"),
            (EISCONN, "EISCONN"), (ENOTCONN, "ENOTCONN"), (ETIMEDOUT, "ETIMEDOUT"),
            (ECONNREFUSED, "ECONNREFUSED"), (EHOSTDOWN, "EHOSTDOWN"),
            (EHOSTUNREACH, "EHOSTUNREACH"), (EOPNOTSUPP, "EOPNOTSUPP")
        ],
        uniquingKeysWith: { first, _ in first }
    )
}

// MARK: - Logging the reason, without flooding the console

/// Writes probe FAILURES into the app Console in the existing `[spoof]` style.
///
/// THROTTLED, because the callers are not one-shot: `TunnelHealthMonitor` polls the sim endpoint
/// every few seconds and `WanderTunnel.ensureStarted` polls it in a loop. A line per poll would bury
/// the very failure it exists to surface, which is the same mistake `NetworkInterfaceDump` already
/// had to solve. Identical failures at one destination collapse; a CHANGED reason (61 → 51, the
/// interesting transition) is logged straight away.
enum EndpointProbeLog {
    /// Minimum spacing between identical failure lines for one destination.
    private static let repeatThrottle: TimeInterval = 30

    private static let lock = NSLock()
    private static var lastLogged: [String: (signature: String, at: Date)] = [:]

    static func record(_ result: EndpointProbeResult, context: String) {
        guard !result.isReachable else {
            // Success ENDS a failure streak, so forget the throttle: the next failure at this
            // destination should be logged at once rather than swallowed as a repeat.
            lock.lock()
            lastLogged[result.destination] = nil
            lock.unlock()
            return
        }

        let signature = "\(result.outcome.rawValue)/\(result.errnoValue)"
        let now = Date()
        var shouldLog = true
        lock.lock()
        if let previous = lastLogged[result.destination],
           previous.signature == signature,
           now.timeIntervalSince(previous.at) < repeatThrottle {
            shouldLog = false
        } else {
            // Cheap guard against unbounded growth if destinations ever churn (they don't today).
            if lastLogged.count > 32 { lastLogged.removeAll(keepingCapacity: true) }
            lastLogged[result.destination] = (signature, now)
        }
        lock.unlock()

        guard shouldLog else { return }
        SpoofTrace.log("\(context) \(result.logLine)")
    }
}
