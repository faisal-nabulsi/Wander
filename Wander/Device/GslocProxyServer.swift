//
//  GslocProxyServer.swift
//  Wander
//
//  Module 6 — the listener. This is what the user's Wi-Fi "Manual Proxy" setting points at.
//
//  WHY POSIX AND NOT NWListener: OpenSSL terminates TLS via SSL_set_fd, so we need the raw file
//  descriptor of the accepted connection. NWConnection deliberately hides it, and Network.framework
//  applies TLS only at connection establishment — but our TLS starts mid-stream, after the plaintext
//  CONNECT verb. accept(2) hands us the fd directly, so one mechanism covers the whole path.
//
//  Binding: INADDR_LOOPBACK only, never INADDR_ANY. The earlier NWListener build bound 0.0.0.0 and
//  turned the phone into an open forward proxy for everyone on the same Wi-Fi. Only locationd on this
//  device is ever meant to reach us, and it dials 127.0.0.1 because that is what the proxy setting says.
//

import Foundation
import Darwin

@MainActor
final class GslocProxyServer: ObservableObject {

    struct Event: Identifiable {
        let id = UUID()
        let at: Date
        let text: String
        let rewrote: Bool
    }

    @Published private(set) var isRunning = false
    @Published private(set) var events: [Event] = []
    @Published private(set) var rewriteCount = 0
    @Published private(set) var lastError: String?

    static let port: UInt16 = 8888

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.wander.gslocproxy", attributes: .concurrent)

    // MARK: - Lifecycle

    func start() {
        stop()
        lastError = nil

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            lastError = "socket() failed: \(String(cString: strerror(errno)))"
            return
        }
        // Without SO_REUSEADDR a restart inside TIME_WAIT fails to bind, which reads to the user as
        // "the proxy is broken" when it is simply the previous socket cooling down.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(Self.port).bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian   // 🔒 loopback ONLY — see the file header
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            lastError = "bind(127.0.0.1:\(Self.port)) failed: \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            return
        }
        guard Darwin.listen(fd, 16) == 0 else {
            lastError = "listen() failed: \(String(cString: strerror(errno)))"
            Darwin.close(fd)
            return
        }

        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            // One connection per queue slot. A MITM proxy is inherently one-flow-per-thread at this
            // scale, and the concurrent queue grows as needed.
            self.queue.async { Self.serve(clientFD: client, owner: self) }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        acceptSource = src

        isRunning = true
        note("listening on 127.0.0.1:\(Self.port)", rewrote: false)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        isRunning = false
    }

    func clear() {
        events.removeAll()
        rewriteCount = 0
    }

    private func note(_ text: String, rewrote: Bool) {
        events.insert(Event(at: Date(), text: text, rewrote: rewrote), at: 0)
        if rewrote { rewriteCount += 1 }
        if events.count > 300 { events.removeLast(events.count - 300) }
    }

    // MARK: - Per-connection

    /// Read the request line, then either MITM it (Apple's WPS hosts) or tunnel it blind.
    nonisolated private static func serve(clientFD: Int32, owner: GslocProxyServer) {
        defer { Darwin.close(clientFD) }

        guard let line = readRequestLine(clientFD) else { return }
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        guard method == "CONNECT" else {
            // Plain HTTP through a proxy is absolute-form. locationd's WPS traffic is HTTPS, so this is
            // other apps' traffic — tunnel it and never inspect it.
            tunnelPlain(clientFD: clientFD, requestLine: line, owner: owner)
            return
        }

        let (host, port) = splitHostPort(target, fallback: 443)
        let snapshot = MainActor.assumeIsolated { GslocMode.currentTargetSnapshot }

        let outcome = GslocEngine.handleConnect(
            clientFD: clientFD,
            host: host,
            port: port,
            target: snapshot,
            writeRaw: { fd, data in writeAll(fd, data) },
            log: { msg in Task { @MainActor in owner.note(msg, rewrote: false) } }
        )

        switch outcome {
        case let .rewritten(wifi, cell):
            Task { @MainActor in owner.note("rewrote \(host): \(wifi) APs, \(cell) cells", rewrote: true) }
        case let .passedThrough(what):
            // Not ours to touch — open a blind tunnel so the connection still works.
            blindTunnel(clientFD: clientFD, host: host, port: port)
            Task { @MainActor in owner.note("tunnelled \(what)", rewrote: false) }
        case let .failed(why):
            Task { @MainActor in owner.note("FAILED \(host): \(why)", rewrote: false) }
        }
    }

    /// CONNECT to a host we do not intercept: acknowledge, then shuttle bytes both ways untouched.
    nonisolated private static func blindTunnel(clientFD: Int32, host: String, port: UInt16) {
        guard let up = try? RawSocketConnection.connect(host: host, port: port) else { return }
        defer { up.close() }
        guard writeAll(clientFD, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else { return }

        let done = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "com.wander.gslocproxy.tunnel", attributes: .concurrent)
        q.async {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { p -> Int in
                    guard let b = p.baseAddress else { return -1 }
                    return Darwin.recv(clientFD, b, 65536, 0)
                }
                guard n > 0, up.writeAll(Data(buf.prefix(n))) else { break }
            }
            done.signal()
        }
        while let chunk = up.read() {
            guard writeAll(clientFD, chunk) else { break }
        }
        _ = done.wait(timeout: .now() + 1)
    }

    nonisolated private static func tunnelPlain(clientFD: Int32, requestLine: String, owner: GslocProxyServer) {
        // Absolute-form origin request over plain HTTP. Extract the host, forward verbatim.
        guard let r = requestLine.range(of: "://") else { return }
        let after = requestLine[r.upperBound...]
        let hostPort = after.prefix { $0 != "/" && $0 != " " }
        let (host, port) = splitHostPort(String(hostPort), fallback: 80)
        guard let up = try? RawSocketConnection.connect(host: host, port: port) else { return }
        defer { up.close() }
        _ = up.writeAll(Data((requestLine + "\r\n").utf8))
        while let chunk = up.read() {
            guard writeAll(clientFD, chunk) else { break }
        }
    }

    // MARK: - Raw fd helpers

    nonisolated private static func readRequestLine(_ fd: Int32) -> String? {
        var acc = Data()
        var byte: UInt8 = 0
        while acc.count < 8192 {
            let n = Darwin.recv(fd, &byte, 1, 0)
            guard n == 1 else { return nil }
            if byte == 0x0a {   // LF ends the request line; the CR is trimmed below
                return String(decoding: acc, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            acc.append(byte)
        }
        return nil
    }

    nonisolated private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n > 0 { sent += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    nonisolated private static func splitHostPort(_ s: String, fallback: UInt16) -> (String, UInt16) {
        if let colon = s.lastIndex(of: ":") {
            let h = String(s[s.startIndex..<colon])
            let p = UInt16(String(s[s.index(after: colon)...])) ?? fallback
            return (h, p)
        }
        return (s, fallback)
    }
}
