//
//  GslocCAInstall.swift
//  Wander
//
//  The install + trust flow for Wander's on-device root CA (module 7, the last one — see
//  GSLOC_INAPP_PLAN.md). To MITM locationd's TLS the device must TRUST our root, and iOS makes that a
//  deliberately manual two-step: install the certificate, THEN enable full trust under
//  Settings → General → About → Certificate Trust Settings. Neither can be automated without MDM
//  (Apple support 102390), so this flow's job is to make the manual steps as un-missable as possible and
//  to VERIFY the end state rather than assume it.
//
//  Serving mechanism: a tiny loopback HTTP server hands the DER to Safari as
//  `application/x-x509-ca-cert`, which is the content type that makes iOS show "Profile Downloaded".
//  Loopback works cross-app on-device (Safari -> our listener on 127.0.0.1), exactly like the proxy.
//

import Foundation
import Security
import Network
import OpenSSL

@MainActor
final class GslocCAInstall: ObservableObject {

    enum TrustState: Equatable {
        case unknown
        case notTrusted      // not installed, or installed but full trust not enabled — both fail the same way
        case trusted
    }

    @Published private(set) var trustState: TrustState = .unknown
    @Published private(set) var downloadURL: URL?
    @Published private(set) var lastError: String?

    private var listener: NWListener?

    /// A DER wrapper that can cross the @Sendable listener-callback boundary under Swift 6.
    private final class Payload: @unchecked Sendable {
        let der: Data
        init(_ d: Data) { der = d }
    }

    // MARK: - Certificates

    /// Root + a fresh leaf, as DER. Both OpenSSL objects are freed before returning — only the byte
    /// copies escape, so there is nothing to leak or double-free.
    private func certificates() throws -> (rootDER: Data, leafDER: Data) {
        let root = try GslocCertificateAuthority.loadOrCreateRoot()
        defer { GslocCertificateAuthority.free(root) }
        let leaf = try GslocCertificateAuthority.makeLeaf(rootCert: root.x509, rootKey: root.key)
        defer { GslocCertificateAuthority.free(leaf) }
        return (root.der, leaf.der)
    }

    // MARK: - Trust check

    /// Evaluate a leaf-signed-by-our-root chain WITHOUT adding our root as an anchor. If it passes, the
    /// system already trusts our root — i.e. the user installed it AND enabled full trust. If it fails,
    /// one of those two steps is missing. This is the standard "is my user CA trusted yet" probe, and it
    /// is honest: it verifies the actual end state instead of trusting that the user tapped the toggles.
    func refreshTrust() {
        do {
            let (rootDER, leafDER) = try certificates()
            guard let leaf = SecCertificateCreateWithData(nil, leafDER as CFData),
                  let root = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                trustState = .unknown
                return
            }
            let policy = SecPolicyCreateSSL(true, "gs-loc.apple.com" as CFString)
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates([leaf, root] as CFArray, policy, &trust) == errSecSuccess,
                  let t = trust else {
                trustState = .unknown
                return
            }
            var err: CFError?
            trustState = SecTrustEvaluateWithError(t, &err) ? .trusted : .notTrusted
        } catch {
            lastError = "\(error)"
            trustState = .unknown
        }
    }

    // MARK: - Serve for install

    /// Stand up the loopback server and publish the URL to open in Safari.
    func startServing() {
        stopServing()
        do {
            let (rootDER, _) = try certificates()
            let payload = Payload(rootDER)
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only — no reason for anyone else on the network to fetch our root.
            let l = try NWListener(using: params)
            l.newConnectionHandler = { conn in Self.serve(conn, payload) }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = l.port {
                            self.downloadURL = URL(string: "http://127.0.0.1:\(port.rawValue)/WanderCA.cer")
                        }
                    case .failed(let e):
                        self.lastError = "server failed: \(e.localizedDescription)"
                    default:
                        break
                    }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            lastError = "\(error)"
        }
    }

    func stopServing() {
        listener?.cancel()
        listener = nil
        downloadURL = nil
    }

    /// Answer any GET with the DER and the content type that triggers iOS's profile-download prompt.
    nonisolated private static func serve(_ conn: NWConnection, _ payload: Payload) {
        conn.start(queue: .global(qos: .userInitiated))
        // Drain the request (we don't care what it asks for — there is exactly one thing to serve).
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: application/x-x509-ca-cert\r\n"
            header += "Content-Length: \(payload.der.count)\r\n"
            header += "Content-Disposition: attachment; filename=\"WanderCA.cer\"\r\n"
            header += "Connection: close\r\n\r\n"
            var out = Data(header.utf8)
            out.append(payload.der)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
