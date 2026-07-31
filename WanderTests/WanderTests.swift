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

    @Test func txmDetectionUsesClassicTXMBeforeIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: false,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone15,2"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: false,
                hasTXMClassic: true,
                hardwareIdentifier: "iPhone1,1"
            ) == true
        )
    }

    @Test func txmDetectionUsesClassicTXMWhenAvailableOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: true,
                hardwareIdentifier: "iPhone1,1"
            ) == true
        )
    }

    @Test func txmDetectionFallsBackToIPhoneThresholdOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone14,1"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone14,2"
            ) == true
        )
    }

    @Test func txmDetectionFallsBackToIPadThresholdOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPad14,4"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPad14,5"
            ) == true
        )
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
