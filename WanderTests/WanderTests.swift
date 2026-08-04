//
//  WanderTests.swift
//  WanderTests
//
//  Created by Stephen on 3/26/25.
//

import Foundation
import Testing
@testable import Wander

struct WanderTests {

    // `hasTXMSupport` is now purely a hardware-model threshold check. The OS-version gate lives in
    // `hasTXM` (iOS 27 → all but iPad8,11/8,12; iOS 26 → this threshold; older → false), and the old
    // "classic TXM" concept is gone. The two tests that passed `isIOS266OrNewer:`/`hasTXMClassic:`
    // were deleted rather than rewritten — those parameters no longer exist, so nothing survived for
    // them to assert. The iPhone/iPad threshold cases below are the original tests, unchanged in
    // intent. The OS gate itself is not unit-testable: it reads the live OS via `#available`.

    @Test func txmDetectionUsesIPhoneThreshold() async throws {
        // iPhone threshold is 14.2 — 14,1 is the last model below it.
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "iPhone14,1") == false)
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "iPhone14,2") == true)
        // Far below the threshold: ancient identifiers must never report TXM.
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "iPhone1,1") == false)
    }

    @Test func txmDetectionUsesIPadThreshold() async throws {
        // iPad threshold is 14.5, deliberately higher than the iPhone's 14.2.
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "iPad14,4") == false)
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "iPad14,5") == true)
    }

    @Test func txmDetectionFailsClosedOnUnparsableIdentifiers() async throws {
        // `deviceVersion` returns nil for anything that isn't iPhone*/iPad*, and the guard must fail
        // CLOSED — claiming TXM on an unknown device would enable a code path the hardware can't run.
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "Mac14,2") == false)
        #expect(ProcessInfo.hasTXMSupport(hardwareIdentifier: "") == false)
    }

    @Test func deviceVersionParsesSupportedIdentifiers() async throws {
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPhone14,2") == 14.2)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPad14,5") == 14.5)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "Mac14,2") == nil)
    }

    // MARK: - Spoof Doctor Rung 1 classification

    private func httpResponse(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://wander.gsloc/probe")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    @Test func probeInterceptingTrueOnOk200() async throws {
        let body = #"{"ok":true,"lat":40.0,"lng":-74.0}"#.data(using: .utf8)
        #expect(SpoofDoctor.interpretProbe(data: body, response: httpResponse(200), error: nil) == true)
    }

    @Test func probeNotInterceptingWhenOkFalse() async throws {
        let body = #"{"ok":false}"#.data(using: .utf8)
        #expect(SpoofDoctor.interpretProbe(data: body, response: httpResponse(200), error: nil) == false)
    }

    @Test func probeNotInterceptingOnNon200() async throws {
        let body = #"{"ok":true}"#.data(using: .utf8)
        // A 200 is required — a real server 404/500 (or a captive portal) must not read as interception.
        #expect(SpoofDoctor.interpretProbe(data: body, response: httpResponse(404), error: nil) == false)
    }

    @Test func probeNotInterceptingOnTransportError() async throws {
        // The proxy being OFF surfaces as a URLSession error (timeout / cannot connect) — the common case.
        let err = URLError(.cannotConnectToHost)
        #expect(SpoofDoctor.interpretProbe(data: nil, response: nil, error: err) == false)
    }

    @Test func probeNotInterceptingOnNonJSONBody() async throws {
        let body = "not json".data(using: .utf8)
        #expect(SpoofDoctor.interpretProbe(data: body, response: httpResponse(200), error: nil) == false)
    }

    // MARK: - gs-loc control channels (dual endpoint)

    @Test func channelsCarryBothEndpointContracts() async throws {
        // The proxy-side rewrite matches these verbatim — a typo here silently kills the spoof.
        #expect(GslocChannel.modern.setEndpoint == "https://gs-loc.apple.com/wander/set")
        #expect(GslocChannel.modern.probeEndpoint == "https://gs-loc.apple.com/wander/probe")
        #expect(GslocChannel.legacy.setEndpoint == "http://wander.gsloc/set")
        #expect(GslocChannel.legacy.probeEndpoint == "http://wander.gsloc/probe")
        // New first: the legacy channel needs a [Rule], which proxy updates keep switching off.
        #expect(GslocChannel.preferenceOrder == [.modern, .legacy])
    }

    @Test func learnedChannelIsTriedFirstButTheOtherStaysAFallback() async throws {
        GslocMode.forgetChannel()
        #expect(GslocMode.channelAttemptOrder() == [.modern, .legacy])
        GslocMode.rememberChannel(.legacy)
        #expect(GslocMode.channelAttemptOrder() == [.legacy, .modern])
        // Un-pinning must be total — a user who re-imports a newer config can't stay stuck on the old
        // channel, so `enabled`'s setter and reset() both call this.
        GslocMode.forgetChannel()
        #expect(GslocMode.preferredChannel == nil)
    }

    // MARK: - ProxyApp import contract

    @Test func proxyAppImportURLsMatchTheWorkerContract() async throws {
        #expect(ProxyApp.shadowrocket.importURL ==
                "https://wander-payments.wanderlocation.workers.dev/gsloc/wander.sgmodule")
        #expect(ProxyApp.loon.importURL ==
                "https://wander-payments.wanderlocation.workers.dev/gsloc/wander.plugin")
        #expect(ProxyApp.quantumultX.importURL ==
                "https://wander-payments.wanderlocation.workers.dev/gsloc/wander.qx.conf")
        #expect(ProxyApp.stash.importURL ==
                "https://wander-payments.wanderlocation.workers.dev/gsloc/wander.stoverride")
    }

    @Test func onlyShadowrocketShipsTheConfigAccelerator() async throws {
        #expect(ProxyApp.shadowrocket.supportsConfigAccelerator == true)
        #expect(ProxyApp.shadowrocket.configURL != nil)
        for app in [ProxyApp.loon, .quantumultX, .stash] {
            #expect(app.supportsConfigAccelerator == false)
            #expect(app.configURL == nil)
            #expect(app.configDeepLink() == nil)
        }
    }

    @Test func recommendedProxyAppIsShadowrocket() async throws {
        #expect(ProxyApp.recommended == .shadowrocket)
        #expect(ProxyApp.shadowrocket.isRecommended == true)
        #expect(ProxyApp.loon.isRecommended == false)
    }

}
