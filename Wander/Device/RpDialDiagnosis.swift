//
//  RpDialDiagnosis.swift
//  Wander
//
//  HOW FAR DID THE DEVELOPER-TUNNEL DIAL ACTUALLY GET?
//
//  ─── THE PROBLEM THIS SOLVES ─────────────────────────────────────────────────────────────────────
//  Every measurement we have of the cellular question stops at a completed TCP handshake. A completed
//  TCP handshake is the kernel's listen backlog accepting a SYN. It happens BEFORE remotepairingd has
//  called accept(), before it has looked at who we are, and before it has decided whether to speak to
//  us. So "127.0.0.1:49152 -> CONNECTED, errno 0, 0 ms on pure cellular" is compatible with two
//  completely opposite worlds:
//
//      • the daemon will hold a full conversation with us          → cellular is genuinely open
//      • the daemon accepts, reads our request, and hangs up       → the source-address rule bites,
//        (or says nothing at all, forever)                            just one layer higher than we
//                                                                     have ever looked
//
//  Those two are indistinguishable to a connect() probe and they have opposite consequences. The whole
//  point of this file is to make Wander able to tell them apart from its own logs, using the dial it
//  already performs, with no new network traffic.
//
//  ─── WHAT ACTUALLY HAPPENS INSIDE `tunnel_create_rppairing` ──────────────────────────────────────
//  Read out of the vendored FFI's own source (jkcoxson/idevice, `ffi/src/tunnel_provider.rs`,
//  `idevice/src/remote_pairing/{mod,socket,tunnel}.rs`) and confirmed against the string table of the
//  vendored `libidevice_ffi.a`. In order:
//
//   1  OS DIAL #1        `TcpStream::connect(addr)` to the address Wander passes, port 49152.
//                        Failure prefix: InternalError("connect: …")
//   2  CONTROL HANDSHAKE first bytes on the wire, immediately, unprompted:
//                            b"RPPairing" ++ u16-BE(len) ++ JSON
//                            {"message":{"plain":{"_0":{"request":{"_0":{"handshake":{"_0":
//                             {"hostOptions":{"attemptPairVerify":true},"wireProtocolVersion":19}}}}}}},
//                             "originatedBy":"host","sequenceNumber":0}
//                        then a BLOCKING `read_exact` of 9 magic bytes. ← A SOURCE-ADDRESS REJECTION
//                        APPEARS HERE AND NOWHERE EARLIER. It arrives as EOF or RST on that read, i.e.
//                        IdeviceError::Socket(io::Error) — ffi code 1 — or as nothing at all, forever.
//   3  PAIR-VERIFY       `verifyManualPairing` TLV8 + X25519 public key, reply carries the device's
//                        public key; shared secret becomes the tunnel PSK. This is what the StikDebug
//                        PR calls "self-pair verification". Failure: ffi code 103 sub_code 5.
//   4  CREATE LISTENER   ChaCha20-Poly1305-encrypted request
//                        {"createListener":{"key":<b64 psk>,"transportProtocolType":"tcp"}}
//                        The device answers with a FRESHLY ALLOCATED port number.
//   5  OS DIAL #2        `TcpStream::connect(<same IP as dial #1>, <that new port>)`.
//                        Failure prefix: InternalError("TLS tunnel: …")
//   6  TUNNEL SESSION    TLS-PSK 1.2 handshake, then b"CDTunnel" ++ u16-BE(len) ++
//                        {"type":"clientHandshakeRequest","mtu":16000}; the reply hands back
//                        clientParameters.address / netmask / serverAddress / serverRSDPort.
//   7  RSD OVER TUNNEL   `adapter.connect(rsd_port)` — NOT an OS socket. This is jktcp's USERSPACE TCP
//                        stack writing IP packets into the TLS stream. Bounded internally at 8 s
//                        ("channel recv timeout"). Then RsdHandshake::new.
//
//  ONLY STEPS 1 AND 5 OPEN AN OS SOCKET. Everything else rides one of those two. That has three
//  consequences worth stating plainly:
//
//    (a) `remote_server_connect_rsd` — which IdeviceFFIBridge's comment currently calls "the SECOND
//        hop … the FFI asks the device to open a fresh TCP listener and dials it" — is NOT a second
//        dial. It is a userspace-TCP connect over an already-established tunnel. The real second dial
//        happens INSIDE `tunnel_create_rppairing`, several steps before that function returns.
//    (b) Both OS dials go to the SAME destination IP. Dial #2 is `connect_addr` with only the port
//        replaced (`tunnel_addr.set_port(tunnel_port)`). It is a brand-new socket with a fresh
//        ephemeral source port, unbound, so the kernel repeats the same route lookup and — same
//        destination, same routing table — picks the SAME source address. Family is inherited for the
//        same reason: the SocketAddr is reused wholesale.
//    (c) A relay that forwards ONE port cannot carry this protocol. That is exactly the third outcome
//        the StikDebug PR anticipates ("the native tunnel likely opens an additional transport not
//        covered by the TCP relay") — it is dial #5, and it is not a hypothetical.
//
//  ─── WHY THE INTERESTING FAILURE IS CURRENTLY INVISIBLE ──────────────────────────────────────────
//  The vendored `libidevice_ffi.a` has NO timeout anywhere on the network path. Verified, not assumed:
//  `_idevice_set_global_timeout` is absent from the archive's symbol table, and the Display string
//  "Operation Timeout" (IdeviceError::Timeout) does not occur in its string table at all. So step 2's
//  blocking `read_exact` has no bound. If the daemon accepts our connection and then simply never
//  answers — the single most diagnostic outcome available to us — `tunnel_create_rppairing` never
//  returns, the serial location queue wedges behind it, and Wander logs NOTHING. The one result that
//  would settle the question is the one result the current code cannot record.
//
//  `boundedDial` below fixes that, and only that.
//
//  ─── WHAT THIS FILE DOES NOT DO ──────────────────────────────────────────────────────────────────
//  It sends no traffic of its own and changes no address, route, or socket option. `classify` is pure.
//  `boundedDial` performs the identical FFI call the app already performs, with a wall clock on it.
//

import Foundation
import idevice

// MARK: - How deep the conversation got

/// The steps of a `tunnel_create_rppairing` call, in the order they execute.
///
/// `rawValue` is the depth: higher means the exchange got further. Comparing two attempts' depths is
/// the whole diagnostic — "the hotspot address gets to 3 and the loopback address gets to 2" says more
/// than either result alone.
enum RpDialHop: Int, Comparable, Sendable {
    /// Could not be attributed to a step. Report the raw message.
    case unknown = -1
    /// Nothing was dialled.
    case notStarted = 0
    /// OS dial #1 — TCP connect to ip:49152. The only step a connect() probe can see.
    case controlConnect = 1
    /// The opening RPPairing frame went out and we are reading the reply. **Where a source-address
    /// rejection lands.**
    case controlHandshake = 2
    /// pair-verify (`verifyManualPairing`) — the StikDebug PR's "self-pair verification".
    case pairVerify = 3
    /// Encrypted `createListener` request; the device allocates a port.
    case createListener = 4
    /// OS dial #2 — TCP connect to the same IP on that freshly allocated port.
    case tunnelConnect = 5
    /// TLS-PSK handshake and the CDTunnel handshake that hands back the tunnel's addressing.
    case tunnelSession = 6
    /// `adapter.connect(rsd_port)` + RSD handshake, over jktcp's userspace TCP inside the tunnel.
    case rsdOverTunnel = 7
    /// Everything above completed.
    case established = 8

    static func < (lhs: RpDialHop, rhs: RpDialHop) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .unknown:          return "UNATTRIBUTED"
        case .notStarted:       return "NOT STARTED"
        case .controlConnect:   return "OS DIAL #1 (ip:49152)"
        case .controlHandshake: return "CONTROL HANDSHAKE (attemptPairVerify)"
        case .pairVerify:       return "PAIR-VERIFY (self-pair verification)"
        case .createListener:   return "CREATE LISTENER"
        case .tunnelConnect:    return "OS DIAL #2 (device-allocated port)"
        case .tunnelSession:    return "TLS-PSK + CDTunnel"
        case .rsdOverTunnel:    return "RSD OVER TUNNEL"
        case .established:      return "ESTABLISHED"
        }
    }

    /// True when reaching this step proves remotepairingd was willing to *talk* to our source address,
    /// not merely to let the kernel complete a handshake on its behalf.
    var provesDaemonSpokeToUs: Bool { self >= .pairVerify }

    /// True when this step opens a real BSD socket (as opposed to riding an existing one).
    var opensOSSocket: Bool { self == .controlConnect || self == .tunnelConnect }
}

// MARK: - One classified outcome

struct RpDialDiagnosis: Sendable {
    /// The furthest step we can prove was reached (for a failure: the step that failed).
    let hop: RpDialHop
    /// `IdeviceFfiError.code` — see `IdeviceError::code()` upstream.
    let ffiCode: Int32
    /// `IdeviceFfiError.sub_code`.
    let subCode: Int32
    /// `format!("{:?}", err)` from the FFI. Debug, not Display — which is why the detail survives at
    /// all: `IdeviceError`'s Display for `Socket` is the bare string "device socket io failed" and for
    /// `InternalError` it is "internal error", both of which throw the payload away.
    let rawMessage: String

    /// The shape of a policy rejection: the daemon accepted the TCP connection, took our request, and
    /// then ended the conversation without answering. This is the ONLY signature that would confirm
    /// the folk rule ("lockdownd refuses a source address the device already holds") at the layer where
    /// it is actually claimed to operate.
    var looksLikeSourceAddressRejection: Bool {
        guard hop == .controlHandshake else { return false }
        let m = rawMessage.lowercased()
        return m.contains("unexpectedeof")
            || m.contains("early eof")
            || m.contains("connectionreset")
            || m.contains("connection reset")
            || m.contains("brokenpipe")
            || m.contains("broken pipe")
    }

    /// A one-line log entry. Deliberately leads with the step, because the step is the finding.
    var logLine: String {
        "hop=\(hop.rawValue) \(hop.label) ffi_code=\(ffiCode) sub=\(subCode) msg=\(rawMessage)"
    }

    /// Plain English for whoever is reading the console at 2am.
    var meaning: String {
        switch hop {
        case .controlConnect:
            return "The TCP connect to port 49152 failed outright. Nothing reached remotepairingd. This is routing or reachability, not policy — read the OS error."
        case .controlHandshake:
            return looksLikeSourceAddressRejection
                ? "remotepairingd ACCEPTED the connection, took the opening handshake, and then ended it without replying. That is a decision made after accept() — the source-address rule, confirmed at the layer it lives on."
                : "The opening handshake went out but the reply did not come back cleanly. The daemon was reached; something above TCP went wrong."
        case .pairVerify:
            return "The daemon TALKED TO US and then refused the pair-verify exchange. Reaching this step already disproves a source-address rejection — the problem is the pairing material or the self-pair case, not who we appear to be."
        case .createListener:
            return "Pair-verify succeeded and the encrypted session is live; the device would not open a listener for us."
        case .tunnelConnect:
            return "The device allocated a listener port and the second TCP dial to it failed. Same destination IP as the first dial, new port — so a relay or route that only covers 49152 stops working exactly here."
        case .tunnelSession:
            return "The second socket connected but the TLS-PSK or CDTunnel handshake on it failed."
        case .rsdOverTunnel:
            return "The tunnel is up; the userspace-TCP connect to the RSD port inside it failed. This is tunnel data path, not pairing."
        case .established:
            return "Everything completed."
        case .notStarted:
            return "No dial was attempted."
        case .unknown:
            return "The failure could not be attributed to a step. Report the raw message verbatim."
        }
    }
}

// MARK: - Classification

enum RpDialDiagnosisClassifier {

    /// `IdeviceError::code()` values that matter here. Named so a reader does not have to trust a
    /// magic number.
    private enum FfiCode {
        static let socket: Int32 = 1          // IdeviceError::Socket(io::Error)
        static let json: Int32 = 8            // Json
        static let addrParse: Int32 = 9       // AddrParseError
        static let notEnoughBytes: Int32 = 10 // NotEnoughBytes
        static let unexpectedResponse: Int32 = 13
        static let internalError: Int32 = 16
        static let remotePairing: Int32 = 103 // RemotePairingError, see sub_code
    }

    /// `RemotePairingError::sub_code()`.
    private enum PairingSubCode {
        static let pairingRejected: Int32 = 3
        static let pairVerifyFailed: Int32 = 5
        static let srpAuthFailed: Int32 = 6
    }

    /// Attribute an FFI failure to the step that produced it.
    ///
    /// Pure — no I/O, no globals. Safe to unit-test and safe to call from anywhere.
    static func classify(code: Int32, subCode: Int32, message: String) -> RpDialDiagnosis {
        let hop = attribute(code: code, subCode: subCode, message: message)
        return RpDialDiagnosis(hop: hop, ffiCode: code, subCode: subCode, rawMessage: message)
    }

    private static func attribute(code: Int32, subCode: Int32, message: String) -> RpDialHop {
        // The FFI's own prefixes are the strongest signal available and they are unambiguous. They
        // exist verbatim in the vendored archive's string table, in this order:
        //     "TLS tunnel: ", "tunnel service: ", "RSD connect: ", "connect: "
        // The first and last are the two dials on the path Wander uses.
        if message.contains("InternalError(\"TLS tunnel:") { return .tunnelConnect }
        if message.contains("InternalError(\"connect:") { return .controlConnect }
        // The RemoteXPC path (tunnel_create_remotexpc). Wander does not call it, but attribute it
        // rather than reporting "unattributed" if it ever does.
        if message.contains("InternalError(\"RSD connect:") { return .controlConnect }
        if message.contains("InternalError(\"tunnel service:") { return .controlConnect }

        switch code {
        case FfiCode.socket:
            // A raw io::Error escaping the FFI can only come from a read or write on a socket that
            // was ALREADY connected — the two connect() calls both have prefixes above. On Wander's
            // path the first such read is the reply to attemptPairVerify.
            return .controlHandshake

        case FfiCode.remotePairing:
            switch subCode {
            case PairingSubCode.pairVerifyFailed, PairingSubCode.pairingRejected,
                 PairingSubCode.srpAuthFailed:
                return .pairVerify
            default:
                return .pairVerify
            }

        case FfiCode.notEnoughBytes:
            // "Device public key isn't the expected size" is the only one on this path.
            return .pairVerify

        case FfiCode.addrParse:
            // finish_tunnel parsing clientParameters.address / serverAddress out of the CDTunnel reply.
            return .tunnelSession

        case FfiCode.unexpectedResponse:
            if message.contains("attemptPairVerify") { return .controlHandshake }
            if message.contains("createListener") { return .createListener }
            if message.contains("CDTunnel") { return .tunnelSession }
            if message.contains("pair-verify") || message.contains("pairing data")
                || message.contains("public key") { return .pairVerify }
            return .unknown

        case FfiCode.internalError:
            // finish_tunnel's `adapter.connect(rsd_port)` wraps jktcp's io::Error with no prefix.
            if message.contains("channel recv timeout") || message.contains("adapter closed") {
                return .rsdOverTunnel
            }
            return .unknown

        case FfiCode.json:
            // Malformed JSON can only be a reply we already received.
            return .controlHandshake

        default:
            return .unknown
        }
    }

    /// Read an `IdeviceFfiError` without consuming it. The caller still owns it and must still call
    /// `idevice_error_free`.
    static func classify(_ error: UnsafeMutablePointer<IdeviceFfiError>?) -> RpDialDiagnosis {
        guard let error else {
            return RpDialDiagnosis(hop: .established, ffiCode: 0, subCode: 0, rawMessage: "(no error)")
        }
        let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? "(no message)"
        return classify(code: error.pointee.code, subCode: error.pointee.sub_code, message: message)
    }
}

// MARK: - The dial, with a wall clock on it

/// What a bounded dial found.
enum RpBoundedDialOutcome {
    /// The FFI returned success. The out-handles were written and are the caller's to free.
    case established(adapter: OpaquePointer?, handshake: OpaquePointer?)
    /// The FFI returned an error, attributed to a step.
    case failed(RpDialDiagnosis)
    /// The FFI DID NOT RETURN inside the bound. The daemon is holding the socket and saying nothing —
    /// the outcome the current unbounded code can only express as a hang.
    ///
    /// `hop` is the deepest step this can possibly be stuck in given that the pre-probe already
    /// completed a TCP handshake to the same address: the blocking read in the control handshake.
    case silent(afterSeconds: Double, hop: RpDialHop)
}

enum RpBoundedDial {

    /// Run `tunnel_create_rppairing` with a hard wall clock, so "the daemon never answered" becomes a
    /// RESULT instead of a wedged serial queue.
    ///
    /// ─── OWNERSHIP, WHICH IS THE WHOLE DIFFICULTY ───────────────────────────────────────────────
    /// The FFI has no cancellation. If the bound expires the worker thread is still inside Rust, still
    /// blocked on `read_exact`, and still holding a borrow of the pairing-file handle. So this function
    /// reads its OWN pairing handle from `pairingFilePath` and, on abandonment, DELIBERATELY LEAKS it
    /// along with the two out-pointer cells. That is the correct trade: a few hundred bytes lost once
    /// per abandoned dial, versus a use-after-free the moment the caller's `defer
    /// { rp_pairing_file_free(...) }` runs while Rust is still reading the same object. Do not "fix"
    /// the leak by freeing on the timeout path.
    ///
    /// The same reasoning is already in this codebase — see `_boundedSet` in IdeviceFFIBridge.swift,
    /// which abandons a `location_simulation_set` the same way.
    ///
    /// BLOCKING for at most `timeoutSeconds`. Call it off the main thread.
    ///
    /// - Parameters:
    ///   - address: destination IP literal, IPv4 or IPv6.
    ///   - port: destination port; 49152 unless you are testing a relay.
    ///   - pairingFilePath: path to the RpPairingFile plist. Read inside, owned inside.
    ///   - hostname: the `sendingHost` string the FFI puts in the pairing request.
    ///   - timeoutSeconds: wall clock. Generous by default — a live loopback dial finishes in
    ///     milliseconds, and the point of the bound is only that the caller regains control.
    static func dial(address: String,
                     port: UInt16 = DeviceConnectionContext.developerTunnelPort,
                     pairingFilePath: String,
                     hostname: String = "StikDebugLocation",
                     timeoutSeconds: Double = 12) -> RpBoundedDialOutcome {

        guard let endpoint = DeviceConnectionContext.makeSocketAddress(address, port: port) else {
            return .failed(RpDialDiagnosis(hop: .notStarted, ffiCode: -1, subCode: 0,
                                           rawMessage: "not a valid IP literal: \(address)"))
        }

        var pairingHandle: OpaquePointer?
        if let readError = pairingFilePath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            let diagnosis = RpDialDiagnosisClassifier.classify(readError)
            idevice_error_free(readError)
            return .failed(RpDialDiagnosis(hop: .notStarted, ffiCode: diagnosis.ffiCode,
                                           subCode: diagnosis.subCode,
                                           rawMessage: "pairing file unreadable: \(diagnosis.rawMessage)"))
        }
        guard let pairingHandle else {
            return .failed(RpDialDiagnosis(hop: .notStarted, ffiCode: -1, subCode: 0,
                                           rawMessage: "pairing file produced no handle"))
        }

        // Heap cells, so an abandoned worker thread writes into memory that is still valid.
        let adapterCell = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        adapterCell.initialize(to: nil)
        let handshakeCell = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 1)
        handshakeCell.initialize(to: nil)

        let handoff = RpDialHandoff()
        let semaphore = DispatchSemaphore(value: 0)
        let started = DispatchTime.now().uptimeNanoseconds

        Thread.detachNewThread {
            let error = hostname.withCString { host in
                endpoint.withSockaddr { pointer, length in
                    tunnel_create_rppairing(pointer, length, host, pairingHandle,
                                            nil, nil, adapterCell, handshakeCell)
                }
            }
            let callerGaveUp = handoff.finish(with: error)
            semaphore.signal()
            if callerGaveUp {
                // Nobody is listening any more. Release what the late call produced so an abandoned
                // dial that eventually succeeds does not strand a live tunnel.
                if let error { idevice_error_free(error) }
                if let adapter = adapterCell.pointee { adapter_free(adapter) }
                if let handshake = handshakeCell.pointee { rsd_handshake_free(handshake) }
                rp_pairing_file_free(pairingHandle)
                adapterCell.deallocate()
                handshakeCell.deallocate()
            }
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if handoff.giveUp() {
                // It finished in the race window; we own everything after all.
                let error = handoff.takeError()
                defer {
                    rp_pairing_file_free(pairingHandle)
                    adapterCell.deallocate()
                    handshakeCell.deallocate()
                }
                if let error {
                    let diagnosis = RpDialDiagnosisClassifier.classify(error)
                    idevice_error_free(error)
                    return .failed(diagnosis)
                }
                return .established(adapter: adapterCell.pointee, handshake: handshakeCell.pointee)
            }
            // Still inside Rust. Everything above stays alive on purpose.
            let seconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000
            return .silent(afterSeconds: seconds, hop: .controlHandshake)
        }

        let error = handoff.takeError()
        defer {
            rp_pairing_file_free(pairingHandle)
            adapterCell.deallocate()
            handshakeCell.deallocate()
        }
        if let error {
            let diagnosis = RpDialDiagnosisClassifier.classify(error)
            idevice_error_free(error)
            return .failed(diagnosis)
        }
        return .established(adapter: adapterCell.pointee, handshake: handshakeCell.pointee)
    }
}

/// Which side owns the FFI's output. Same shape as `BoundedSetHandoff` in IdeviceFFIBridge.swift.
private final class RpDialHandoff {
    private let lock = NSLock()
    private var callerGaveUp = false
    private var threadFinished = false
    private var error: UnsafeMutablePointer<IdeviceFfiError>?

    /// The worker finished. Returns true if the caller had already walked away, meaning the worker
    /// must clean up.
    func finish(with error: UnsafeMutablePointer<IdeviceFfiError>?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.error = error
        threadFinished = true
        return callerGaveUp
    }

    /// The caller's bound expired. Returns true if the worker had ALREADY finished, meaning the caller
    /// owns the result after all.
    func giveUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        callerGaveUp = true
        return threadFinished
    }

    func takeError() -> UnsafeMutablePointer<IdeviceFfiError>? {
        lock.lock(); defer { lock.unlock() }
        let taken = error
        error = nil
        return taken
    }
}
