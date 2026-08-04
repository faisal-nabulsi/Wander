//
//  SpoofDoctor.swift
//  Wander
//
//  "Spoof Doctor" — automates the manual triage of a failing gs-loc setup into a two-rung ladder that
//  reports the EXACT fix instead of a generic "it's not working". The two rungs isolate the two independent
//  failure planes:
//
//   • RUNG 1 — is the proxy intercepting AT ALL? A GET to the Wander control endpoint, which the rewrite
//     answers locally with {"ok":true}. Tried on BOTH channels (see GslocChannel) — new path-based one
//     first, legacy fake-host one second — because a user on an older imported config only answers the old
//     one, and a Doctor that called that "broken" would send them re-installing a working setup. EITHER
//     channel answering means interception is live. Neither answering means it's OFF (routing set to
//     Direct, module disabled, proxy not connected, or LocalDevVPN stealing the tunnel). No point checking
//     location until this passes.
//
//     Note the legacy channel is plain HTTP, so it proves rules fire without a trusted CA; the new channel
//     rides the MITM, so it additionally implies the CA is trusted. Neither distinction changes Rung 1's
//     verdict — Rung 2 is what separates "rules fire" from "the rewrite lands".
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

    /// The endpoint the Wander rewrite intercepts to answer the interception probe — sibling of the
    /// channel's …/set, but returning JSON instead of steering location. This is the PREFERRED (new) one;
    /// `probeAnyChannel()` is what actually runs Rung 1 across both. Kept as the default argument of
    /// `probeIntercepting` so single-endpoint callers and tests still read cleanly.
    nonisolated static let probeEndpoint = GslocChannel.modern.probeEndpoint

    /// Per-attempt ceiling. Short on purpose: the fallback attempt is queued behind this one, so it caps how
    /// long the diagnostic sits on a dead channel before trying the other.
    nonisolated static let attemptTimeout: TimeInterval = 2

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
    /// Each request also sets its own (shorter) `timeoutInterval` — these are the backstop.
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

    /// Probe ONE endpoint and report whether the proxy intercepted it. Endpoint + session + timeout are
    /// injectable so a test can point at a stub. Treats any thrown error as "not intercepting".
    static func probeIntercepting(endpoint: String = probeEndpoint,
                                  session: URLSession = probeSession,
                                  timeout: TimeInterval = attemptTimeout) async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await session.data(for: request)
            return interpretProbe(data: data, response: response, error: nil)
        } catch {
            return interpretProbe(data: nil, response: nil, error: error)
        }
    }

    /// Run Rung 1 for real: try the channels in preference order and return the first that answers
    /// `{"ok":true}` (nil = neither, i.e. not intercepting). Interception is proven by EITHER channel, so an
    /// older config keeps passing the Doctor exactly as it did before the new endpoint existed.
    ///
    /// The winner is published into GslocMode's channel cache, so running the Doctor also spares the next
    /// teleport its doomed first attempt.
    static func probeAnyChannel() async -> GslocChannel? {
        for channel in GslocMode.channelAttemptOrder() {
            if await probeIntercepting(endpoint: channel.probeEndpoint) {
                GslocMode.rememberChannel(channel)
                return channel
            }
        }
        GslocMode.forgetChannel()
        return nil
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
            let intercepting = (await Self.probeAnyChannel()) != nil
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
