//
//  SpoofDoctor.swift
//  Wander
//
//  "Spoof Doctor" — automates the manual triage of a failing gs-loc setup into a two-rung ladder that
//  reports the EXACT fix instead of a generic "it's not working". The two rungs isolate the two independent
//  failure planes:
//
//   • RUNG 1 — is the proxy intercepting AT ALL? A plain-HTTP GET to the fake control host
//     (http://wander.gsloc/probe) that the Wander rewrite answers locally with {"ok":true}. This proves the
//     proxy's rules are firing WITHOUT needing a trusted CA — it's plain HTTP, nothing is decrypted. If it
//     fails/timeouts, the rules are OFF (routing set to Direct, module disabled, proxy not connected, or
//     LocalDevVPN stealing the tunnel). No point checking location until this passes.
//
//   • RUNG 2 — is the location ACTUALLY spoofed? Reuses GslocVerifier (live CoreLocation vs the pushed
//     target). A match means the HTTPS MITM is landing end-to-end. A mismatch means Rung 1 passed (rules
//     fire) but the decrypted rewrite isn't taking — almost always the CA isn't trusted, or a strong real
//     GPS fix / stale location cache is overriding the network fix.
//
//  Read-only: Rung 1 sends one throwaway GET the proxy catches locally; Rung 2 only asks iOS where it
//  thinks the phone is. Neither injects or changes location.
//
//  The probe + ladder live here, separate from the view, so the classification is unit-testable
//  (see `interpretProbe`) without standing up any UI or CoreLocation.
//

import Foundation
import Combine

@MainActor
final class SpoofDoctor: ObservableObject {

    /// The made-up host + path the Wander rewrite intercepts to answer the interception probe. Sibling of
    /// GslocMode.setEndpoint (…/set); this one is …/probe and returns JSON rather than steering location.
    nonisolated static let probeEndpoint = "http://wander.gsloc/probe"

    /// The full ladder result. Each terminal case maps to one exact, user-facing fix (see SpoofDoctorView).
    enum Stage: Equatable {
        case idle
        case probing            // Rung 1 in flight
        case checkingLocation   // Rung 1 passed; Rung 2 in flight
        case notIntercepting    // Rung 1 failed → proxy rules are OFF
        case working(distanceMeters: Double)        // Rung 2 match → all good
        case httpsNotLanding(distanceMeters: Double) // Rung 2 mismatch → CA-trust / GPS-override
        case noTarget           // nothing pushed yet — teleport first
        case locationDenied     // Location off for Wander
        case locationUnavailable // couldn't get a fix
    }

    @Published private(set) var stage: Stage = .idle

    /// True while a rung is in flight (drives the button's spinner/disabled state).
    var isRunning: Bool { stage == .probing || stage == .checkingLocation }

    // Rung 2 is delegated to the shipped GslocVerifier so the comparison logic lives in exactly one place.
    // A fresh verifier per run keeps each run's CoreLocation read clean (no stale terminal state to filter).
    private var verifier: GslocVerifier?
    private var rung2Cancellable: AnyCancellable?
    /// Monotonic token so a late async result from a superseded run can't clobber a newer one.
    private var runToken = 0

    /// Short-timeout session for Rung 1. The probe is caught locally by the proxy, so it resolves near
    /// instantly when interception is on; when it's OFF we want to fail fast, not hang the diagnostic.
    nonisolated static let probeSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 3
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: cfg)
    }()

    // MARK: - Rung 1 (pure + testable)

    /// Classify a probe response. Interception is proven ONLY by HTTP 200 with a JSON body carrying
    /// "ok": true. Any error, non-200, non-JSON, or missing/false flag ⇒ not intercepting. Pure so it can
    /// be unit-tested without the network or the main actor.
    nonisolated static func interpretProbe(data: Data?, response: URLResponse?, error: Error?) -> Bool {
        guard error == nil,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["ok"] as? Bool) == true
    }

    /// Run Rung 1: GET the probe host and report whether the proxy intercepted it. Endpoint + session are
    /// injectable so a test can point at a stub. Treats any thrown error as "not intercepting".
    static func probeIntercepting(endpoint: String = probeEndpoint,
                                  session: URLSession = probeSession) async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            return interpretProbe(data: data, response: response, error: nil)
        } catch {
            return interpretProbe(data: nil, response: nil, error: error)
        }
    }

    // MARK: - Ladder

    /// Run the full two-rung ladder and publish the exact diagnosis. Safe to call repeatedly — a new run
    /// supersedes any in-flight one.
    func run() {
        runToken &+= 1
        let token = runToken
        rung2Cancellable = nil
        verifier = nil
        stage = .probing

        Task { @MainActor in
            let intercepting = await Self.probeIntercepting()
            guard token == self.runToken else { return }   // superseded
            if intercepting {
                self.startRung2(token: token)
            } else {
                self.stage = .notIntercepting
            }
        }
    }

    /// Reset back to idle (e.g. when the sheet is dismissed) and drop any in-flight run.
    func reset() {
        runToken &+= 1
        rung2Cancellable = nil
        verifier = nil
        stage = .idle
    }

    private func startRung2(token: Int) {
        stage = .checkingLocation
        let verifier = GslocVerifier()
        self.verifier = verifier
        rung2Cancellable = verifier.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, token == self.runToken else { return }
                switch state {
                case .idle, .checking:
                    break   // not terminal — keep waiting
                case .verified(let d):
                    self.finish(.working(distanceMeters: d), token: token)
                case .wrongLocation(let d):
                    self.finish(.httpsNotLanding(distanceMeters: d), token: token)
                case .noTarget:
                    self.finish(.noTarget, token: token)
                case .denied:
                    self.finish(.locationDenied, token: token)
                case .failed:
                    self.finish(.locationUnavailable, token: token)
                }
            }
        verifier.check()
    }

    private func finish(_ stage: Stage, token: Int) {
        guard token == runToken else { return }
        self.stage = stage
        rung2Cancellable = nil
        verifier = nil
    }
}
