//
//  GslocTLS.swift
//  Wander
//
//  Module 4 of the in-app gs-loc engine (GSLOC_INAPP_PLAN.md): TLS termination and re-encryption.
//
//  This is the piece that turns the pass-through proxy into a real MITM. Flow for an intercepted host:
//
//     locationd --CONNECT gs-loc.apple.com:443--> our proxy
//     our proxy --"200 Connection Established"--> locationd
//     locationd --TLS ClientHello------------->  US, acting as the TLS SERVER with our leaf cert
//     us        --TLS as CLIENT-------------->  the real gs-loc.apple.com
//     (decrypt Apple's response, poison it with WlocEnvelope+WlocRewriter, re-encrypt, hand it back)
//
//  WHY OPENSSL ON RAW FDs: Network.framework applies TLS at connection ESTABLISHMENT, so an already
//  accepted NWConnection cannot be upgraded mid-stream — and mid-stream is exactly where we are, because
//  the CONNECT verb has already been spoken in plaintext. SecureTransport could do it but is deprecated
//  (`__API_DEPRECATED(ios(5.0,13.0))`) and caps at TLS 1.2. OpenSSL 3.3.2 is ALREADY linked and embedded
//  in this app via the AltSign dependency (Apache-2.0), speaks TLS 1.3, and works directly on a file
//  descriptor via SSL_set_fd — which is why the upstream leg is a RawSocketConnection.
//
//  Macros that Swift cannot see (SSL_CTX_set_min_proto_version, SSL_set_tlsext_host_name, ...) come
//  from the small C shim in Wander/OpenSSLShim.
//

import Foundation
import OpenSSL
import OpenSSLShim

/// One TLS-terminated MITM session. Owns two OpenSSL connections — server side facing locationd, client
/// side facing Apple — and frees both exactly once.
final class GslocTLSSession {

    enum TLSError: Error, CustomStringConvertible {
        case contextFailed(String)
        case certificateRejected
        case handshakeFailed(String, Int32)
        case upstreamFailed(String)

        var description: String {
            switch self {
            case let .contextFailed(w): return "SSL_CTX setup failed: \(w)"
            case .certificateRejected: return "OpenSSL rejected our leaf certificate or key"
            case let .handshakeFailed(side, code): return "\(side) TLS handshake failed (SSL error \(code))"
            case let .upstreamFailed(w): return "upstream TLS failed: \(w)"
            }
        }
    }

    private var serverCtx: OpaquePointer?
    private var clientCtx: OpaquePointer?
    private var serverSSL: OpaquePointer?
    private var clientSSL: OpaquePointer?

    deinit { teardown() }

    func teardown() {
        if let s = serverSSL { SSL_free(s); serverSSL = nil }
        if let c = clientSSL { SSL_free(c); clientSSL = nil }
        if let s = serverCtx { SSL_CTX_free(s); serverCtx = nil }
        if let c = clientCtx { SSL_CTX_free(c); clientCtx = nil }
    }

    // MARK: - Server side (we impersonate gs-loc.apple.com to locationd)

    /// Present our leaf on `fd` and complete the handshake as the SERVER.
    ///
    /// `leaf`/`leafKey` come from GslocCertificateAuthority. `root` is added to the chain so locationd
    /// can build a path to the CA the user trusted — without it the chain is incomplete and validation
    /// fails even though the root IS trusted, which looks identical to "the cert is wrong".
    func acceptTLS(fd: Int32,
                   leaf: OpaquePointer,
                   leafKey: OpaquePointer,
                   root: OpaquePointer) throws {
        guard let ctx = SSL_CTX_new(TLS_server_method()) else {
            throw TLSError.contextFailed("SSL_CTX_new(server)")
        }
        serverCtx = ctx
        // TLS 1.2 floor: locationd will happily do 1.3, but a 1.2 floor avoids surprises on older iOS
        // without permitting anything genuinely weak.
        _ = wander_SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION)

        guard SSL_CTX_use_certificate(ctx, leaf) == 1 else { throw TLSError.certificateRejected }
        guard SSL_CTX_use_PrivateKey(ctx, leafKey) == 1 else { throw TLSError.certificateRejected }
        guard SSL_CTX_check_private_key(ctx) == 1 else { throw TLSError.certificateRejected }
        // Chain completion — see the doc comment. Ownership passes to the context on success, so this
        // X509 must NOT be freed by us afterwards.
        _ = wander_SSL_CTX_add_extra_chain_cert(ctx, root)

        guard let ssl = SSL_new(ctx) else { throw TLSError.contextFailed("SSL_new(server)") }
        serverSSL = ssl
        SSL_set_fd(ssl, fd)

        let rc = SSL_accept(ssl)
        guard rc == 1 else {
            throw TLSError.handshakeFailed("server", SSL_get_error(ssl, rc))
        }
    }

    // MARK: - Client side (we are an ordinary TLS client to the real Apple host)

    /// Open TLS to the genuine host over `fd`, with SNI set — Apple's edge requires SNI, and omitting it
    /// yields a certificate for the wrong host or an outright handshake failure.
    ///
    /// NOTE: we verify Apple's certificate the normal way. We are impersonating gs-loc TO locationd, but
    /// we should still be certain we are talking to the REAL gs-loc ourselves — otherwise a hostile
    /// network could feed us a forged response that we would then faithfully re-sign with a certificate
    /// the user trusts. That would turn Wander into an amplifier for someone else's attack.
    func connectTLS(fd: Int32, hostname: String) throws {
        guard let ctx = SSL_CTX_new(TLS_client_method()) else {
            throw TLSError.contextFailed("SSL_CTX_new(client)")
        }
        clientCtx = ctx
        _ = wander_SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION)
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
        guard SSL_CTX_set_default_verify_paths(ctx) == 1 else {
            throw TLSError.upstreamFailed("no system trust store available")
        }

        guard let ssl = SSL_new(ctx) else { throw TLSError.contextFailed("SSL_new(client)") }
        clientSSL = ssl
        SSL_set_fd(ssl, fd)
        _ = hostname.withCString { wander_SSL_set_tlsext_host_name(ssl, $0) }
        // Hostname verification is separate from chain verification and must be asked for explicitly,
        // or a valid certificate for ANY host would pass.
        if let param = SSL_get0_param(ssl) {
            _ = hostname.withCString { X509_VERIFY_PARAM_set1_host(param, $0, 0) }
        }

        let rc = SSL_connect(ssl)
        guard rc == 1 else {
            throw TLSError.handshakeFailed("client", SSL_get_error(ssl, rc))
        }
    }

    // MARK: - Plaintext IO

    /// Read decrypted bytes from locationd.
    func readFromClient(max: Int = 65536) -> Data? {
        Self.read(serverSSL, max: max)
    }
    /// Read decrypted bytes from Apple.
    func readFromUpstream(max: Int = 65536) -> Data? {
        Self.read(clientSSL, max: max)
    }
    @discardableResult func writeToClient(_ d: Data) -> Bool { Self.write(serverSSL, d) }
    @discardableResult func writeToUpstream(_ d: Data) -> Bool { Self.write(clientSSL, d) }

    private static func read(_ ssl: OpaquePointer?, max: Int) -> Data? {
        guard let ssl else { return nil }
        var buf = [UInt8](repeating: 0, count: max)
        let n = buf.withUnsafeMutableBytes { p -> Int32 in
            guard let base = p.baseAddress else { return -1 }
            return SSL_read(ssl, base, Int32(max))
        }
        guard n > 0 else { return nil }
        return Data(buf.prefix(Int(n)))
    }

    private static func write(_ ssl: OpaquePointer?, _ data: Data) -> Bool {
        guard let ssl, !data.isEmpty else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = SSL_write(ssl, base.advanced(by: sent), Int32(raw.count - sent))
                if n > 0 { sent += Int(n); continue }
                return false
            }
            return true
        }
    }
}

// MARK: - HTTP framing over the decrypted stream

/// Just enough HTTP to find the body of Apple's WPS response so it can be poisoned. Deliberately not a
/// general HTTP implementation — it handles exactly the two framings Apple's endpoint uses.
enum GslocHTTP {

    /// Split a raw HTTP message into (headers, body). nil when the header terminator hasn't arrived yet.
    static func split(_ data: Data) -> (head: Data, body: Data)? {
        let terminator = Data([0x0d, 0x0a, 0x0d, 0x0a])   // CRLFCRLF
        guard let r = data.range(of: terminator) else { return nil }
        return (data.subdata(in: data.startIndex..<r.lowerBound), data.subdata(in: r.upperBound..<data.endIndex))
    }

    /// Content-Length, if present. Apple's WPS response is length-delimited rather than chunked, so this
    /// is normally all we need to know the body is complete.
    static func contentLength(_ head: Data) -> Int? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func isChunked(_ head: Data) -> Bool {
        String(decoding: head, as: UTF8.self).lowercased().contains("transfer-encoding: chunked")
    }

    /// Rebuild a response with a new body, fixing Content-Length. The poisoned protobuf is very close to
    /// the original size but NOT guaranteed identical (varints are variable-width), so a stale
    /// Content-Length would truncate the body or hang the client waiting for bytes that never come.
    static func reassemble(head: Data, body: Data) -> Data {
        var text = String(decoding: head, as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        var rebuilt: [String] = []
        var sawLength = false
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                rebuilt.append("Content-Length: \(body.count)")
                sawLength = true
            } else {
                rebuilt.append(String(line))
            }
        }
        if !sawLength { rebuilt.append("Content-Length: \(body.count)") }
        text = rebuilt.joined(separator: "\r\n")
        var out = Data(text.utf8)
        out.append(contentsOf: [0x0d, 0x0a, 0x0d, 0x0a])
        out.append(body)
        return out
    }
}
