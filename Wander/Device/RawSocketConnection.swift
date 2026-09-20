//
//  RawSocketConnection.swift
//  Wander
//
//  A minimal BSD-socket TCP client that DELIBERATELY bypasses every URL-loading-layer facility —
//  most importantly the system-wide Wi-Fi HTTP proxy.
//
//  WHY THIS EXISTS: the in-app gs-loc proxy (see GSLOC_INAPP_PLAN.md) runs while iOS is configured to
//  send Wi-Fi traffic to 127.0.0.1. The first pass-through implementation dialled upstream with
//  NWConnection and produced an endless CONNECT storm that also killed Wi-Fi internet — the signature
//  of the proxy dialling ITSELF, because the outbound connection was being routed back through the
//  system proxy (us). A proxy that cannot reach the real origin is not a proxy; it is a black hole.
//
//  The system HTTP proxy is applied by CFNetwork/URLSession (and is configurable on NWParameters), not
//  by the kernel socket layer. `socket()` + `connect()` therefore talks straight to the destination.
//  That is the entire point of this file: no URLSession, no NWConnection, no proxy inheritance.
//
//  Deliberately NOT a general networking layer — it does exactly what a MITM proxy's upstream leg needs:
//  connect to host:port, then read/write raw bytes.
//

import Foundation
import Darwin

/// A connected TCP socket. Not Sendable-by-inheritance: ownership is passed to one pump at a time and
/// every call is serialized by the caller's queue.
final class RawSocketConnection: @unchecked Sendable {

    enum ConnectError: Error, CustomStringConvertible {
        case resolveFailed(String, Int32)
        case connectFailed(String, Int32)

        var description: String {
            switch self {
            case let .resolveFailed(host, code):
                return "DNS failed for \(host) (\(code): \(String(cString: gai_strerror(code))))"
            case let .connectFailed(host, errnoValue):
                return "connect to \(host) failed (errno \(errnoValue): \(String(cString: strerror(errnoValue))))"
            }
        }
    }

    private let fd: Int32
    private var closed = false
    private let lock = NSLock()

    private init(fd: Int32) { self.fd = fd }

    /// The raw descriptor, for handing to a TLS layer that wants its own IO callbacks.
    var descriptor: Int32 { fd }

    // MARK: - Connect

    /// Blocking connect with a bounded timeout. Call OFF the main thread.
    ///
    /// Uses `getaddrinfo` so both IPv4 and IPv6 work (Apple hosts are dual-stack, and an IPv4-only path
    /// silently fails on IPv6-only cellular). Tries each returned address in order.
    static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) throws -> RawSocketConnection {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC          // v4 or v6, whichever resolves
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let list = info else { throw ConnectError.resolveFailed(host, rc) }
        defer { freeaddrinfo(info) }

        var lastErrno: Int32 = 0
        var candidate: UnsafeMutablePointer<addrinfo>? = list
        while let addr = candidate {
            let sock = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
            if sock >= 0 {
                // Don't let a dead peer raise SIGPIPE and kill the app — surface EPIPE instead.
                var on: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                if Darwin.connect(sock, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                    return RawSocketConnection(fd: sock)
                }
                lastErrno = errno
                Darwin.close(sock)
            } else {
                lastErrno = errno
            }
            candidate = addr.pointee.ai_next
        }
        throw ConnectError.connectFailed(host, lastErrno)
    }

    // MARK: - IO

    /// Write every byte, looping over partial writes. Returns false once the peer is gone.
    @discardableResult
    func writeAll(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n > 0 { sent += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                return false
            }
            return true
        }
    }

    /// Read up to `max` bytes. Returns nil on EOF or error — the caller's cue to tear the pair down.
    func read(max: Int = 65536) -> Data? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { p -> Int in
            guard let base = p.baseAddress else { return -1 }
            while true {
                let r = Darwin.recv(fd, base, max, 0)
                if r < 0 && errno == EINTR { continue }
                return r
            }
        }
        guard n > 0 else { return nil }
        return Data(buf.prefix(n))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    deinit { close() }
}
