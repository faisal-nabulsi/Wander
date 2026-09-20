//
//  GslocEngine.swift
//  Wander
//
//  Module 5 — the assembly. Everything else was a part; this is the machine.
//
//  For a CONNECT to one of Apple's WPS hosts:
//    1. answer "200 Connection Established" so locationd starts its TLS handshake
//    2. terminate that TLS ourselves, presenting the leaf from GslocCertificateAuthority
//    3. open real TLS to the genuine Apple host over a raw socket (raw = bypasses the system proxy,
//       which is US — see RawSocketConnection for the loop that cost an evening)
//    4. forward locationd's request unchanged, read Apple's response
//    5. unwrap the transport frame, poison every AP + cell coordinate, rewrap, fix Content-Length
//    6. hand it back encrypted
//  Any other host is tunnelled blind, byte-for-byte, with no decryption. We hold a certificate the user
//  trusts; decrypting traffic we have no business reading would be an abuse of that.
//
//  WHY THIS EXISTS: it removes Shadowrocket. gs-loc is the ONLY path that produces a fix Pokémon GO
//  accepts (measured — see the error-12 memory), so the friction around it is the product's biggest
//  weakness. This deletes the third-party app, its config, and its periodically-self-resetting routing.
//

import Foundation
import OpenSSL

/// Serves one accepted proxy connection end to end.
enum GslocEngine {

    /// Result of handling one CONNECT, for the diagnostics UI.
    enum Outcome {
        case rewritten(wifi: Int, cell: Int)
        case passedThrough(String)
        case failed(String)
    }

    /// Handle a CONNECT that has already been parsed. `clientFD` is the accepted socket, still plaintext.
    ///
    /// Runs synchronously and blocks — call it on a dedicated queue. OpenSSL's `SSL_read`/`SSL_write` on
    /// a blocking fd is exactly the shape this wants; async would buy nothing and cost correctness.
    @discardableResult
    static func handleConnect(clientFD: Int32,
                              host: String,
                              port: UInt16,
                              target: (lat: Double, lng: Double)?,
                              options: WlocRewriter.Options = .shipped,
                              writeRaw: (Int32, Data) -> Bool,
                              log: (String) -> Void) -> Outcome {

        // Only ever MITM Apple's WPS endpoints. Everything else is none of our business.
        guard GslocHosts.shouldIntercept(host: host) else {
            return .passedThrough(host)
        }
        // Nothing to poison with — tunnel it rather than terminating TLS for no reason.
        guard let target else {
            log("[gsloc] \(host): no target armed, passing through")
            return .passedThrough(host)
        }

        let session = GslocTLSSession()
        defer { session.teardown() }

        do {
            let ca = try GslocCertificateAuthority.loadOrCreateRoot()
            let leaf = try GslocCertificateAuthority.makeLeaf(rootCert: ca.x509, rootKey: ca.key)
            defer {
                GslocCertificateAuthority.free(leaf)
                // NOTE: `ca.x509` is handed to the SSL_CTX as an extra chain cert, which TAKES OWNERSHIP,
                // so it must not be freed here. Only the key is ours to release.
                EVP_PKEY_free(ca.key)
            }

            // Tell locationd the tunnel is open; from here the bytes on this socket are TLS.
            guard writeRaw(clientFD, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) else {
                return .failed("could not acknowledge CONNECT")
            }

            try session.acceptTLS(fd: clientFD, leaf: leaf.x509, leafKey: leaf.key, root: ca.x509)

            // Upstream on a RAW socket. This is the whole reason RawSocketConnection exists: an
            // NWConnection here gets handed back to the system proxy — i.e. to us — and loops forever.
            guard let upstream = try? RawSocketConnection.connect(host: host, port: port) else {
                return .failed("upstream connect failed for \(host)")
            }
            defer { upstream.close() }
            try session.connectTLS(fd: upstream.descriptor, hostname: host)

            // locationd's request, forwarded untouched. We only rewrite the RESPONSE.
            guard let request = session.readFromClient(), !request.isEmpty else {
                return .failed("empty request from locationd")
            }
            guard session.writeToUpstream(request) else {
                return .failed("could not forward request")
            }

            // Read until the body is complete. Apple's WPS response is Content-Length delimited, so we
            // know exactly when to stop rather than waiting for a close.
            var raw = Data()
            var head = Data()
            var body = Data()
            var expected: Int?
            while let chunk = session.readFromUpstream() {
                raw.append(chunk)
                if expected == nil, let split = GslocHTTP.split(raw) {
                    head = split.head
                    body = split.body
                    expected = GslocHTTP.contentLength(head)
                    if GslocHTTP.isChunked(head) {
                        // Not expected on this endpoint. Rather than half-implement chunked decoding and
                        // silently corrupt a response, hand it back verbatim and say so.
                        log("[gsloc] \(host): chunked response, passing through unmodified")
                        _ = session.writeToClient(raw)
                        return .passedThrough(host + " (chunked)")
                    }
                } else if expected != nil {
                    body.append(chunk)
                }
                if let need = expected, body.count >= need { break }
            }
            guard expected != nil else {
                // No parsable framing — return exactly what Apple sent.
                _ = session.writeToClient(raw)
                return .passedThrough(host + " (unframed)")
            }

            // THE POINT OF ALL OF THIS.
            guard let poisoned = WlocEnvelope.poisonResponse(body,
                                                             latitude: target.lat,
                                                             longitude: target.lng,
                                                             options: options) else {
                // Not a WLoc body (this endpoint carries other traffic too) — pass it through untouched.
                _ = session.writeToClient(GslocHTTP.reassemble(head: head, body: body))
                return .passedThrough(host + " (not a WLoc body)")
            }

            _ = session.writeToClient(GslocHTTP.reassemble(head: head, body: poisoned.body))
            log("[gsloc] rewrote \(host): \(poisoned.wifi) APs, \(poisoned.cell) cells → \(target.lat), \(target.lng)")
            return .rewritten(wifi: poisoned.wifi, cell: poisoned.cell)

        } catch {
            return .failed("\(error)")
        }
    }
}
