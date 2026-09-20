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

    // MARK: - WlocRewriter (in-app gs-loc poisoner, module 1)

    /// Build a protobuf key (fieldNumber<<3 | wireType).
    private func pbKey(_ field: Int, _ wire: Int) -> Data {
        WlocRewriter.encodeVarint((UInt64(field) << 3) | UInt64(wire))
    }
    /// A wire-0 field carrying a signed int64 (two's-complement on the wire, as Apple encodes coords).
    private func pbVarint(_ field: Int, _ value: Int64) -> Data {
        var d = pbKey(field, 0)
        d.append(WlocRewriter.encodeVarint(UInt64(bitPattern: value)))
        return d
    }
    /// A wire-2 length-delimited field wrapping `payload`.
    private func pbLen(_ field: Int, _ payload: Data) -> Data {
        var d = pbKey(field, 2)
        d.append(WlocRewriter.encodeVarint(UInt64(payload.count)))
        d.append(payload)
        return d
    }
    private func readSigned(_ fields: [WlocRewriter.Field], _ field: Int) -> Int64? {
        guard let f = fields.first(where: { $0.fieldNumber == field }), f.wireType == 0,
              let (v, _) = WlocRewriter.decodeVarint(f.valueBytes, f.valueBytes.startIndex) else { return nil }
        return Int64(bitPattern: v)
    }

    @Test func wlocPoisonMovesWifiCoordsAndKeepsApplesAccuracy() async throws {
        // A Location submessage Apple would return for one AP: lat=1.0, lng=2.0, hAcc=57.
        var loc = pbVarint(1, WlocRewriter.coordToInt(1.0))
        loc.append(pbVarint(2, WlocRewriter.coordToInt(2.0)))
        loc.append(pbVarint(3, 57))
        let wifi = pbLen(2, loc)                 // Wi-Fi record: Location at field 2
        var root = pbLen(2, wifi)                // root: Wi-Fi record at field 2
        root.append(pbVarint(3, 999))            // a request-only root field that MUST be dropped

        let out = WlocRewriter.poison(payload: root, latitude: 40.5, longitude: -74.25)
        #expect(out.wifiCount == 1)
        #expect(out.cellCount == 0)

        let rootFields = WlocRewriter.parseFields(out.payload)
        #expect(rootFields.contains { $0.fieldNumber == 3 } == false)   // dropped
        let wifiField = try #require(rootFields.first { $0.fieldNumber == 2 })
        let locField = try #require(WlocRewriter.parseFields(wifiField.valueBytes).first { $0.fieldNumber == 2 })
        let locInner = WlocRewriter.parseFields(locField.valueBytes)
        #expect(readSigned(locInner, 1) == WlocRewriter.coordToInt(40.5))
        #expect(readSigned(locInner, 2) == WlocRewriter.coordToInt(-74.25))
        #expect(readSigned(locInner, 3) == 57)   // Apple's real per-AP accuracy preserved, not clobbered
    }

    @Test func wlocPoisonMovesCellTowersAtRootFields22And24() async throws {
        // Cell record nests its Location at field 5. Two towers, at root fields 22 and 24.
        func cell() -> Data {
            var loc = pbVarint(1, WlocRewriter.coordToInt(10.0))
            loc.append(pbVarint(2, WlocRewriter.coordToInt(20.0)))
            return pbLen(5, loc)
        }
        var root = pbLen(22, cell())
        root.append(pbLen(24, cell()))

        let out = WlocRewriter.poison(payload: root, latitude: -33.0, longitude: 151.0)
        #expect(out.cellCount == 2)

        for rootField in [22, 24] {
            let f = try #require(WlocRewriter.parseFields(out.payload).first { $0.fieldNumber == rootField })
            let loc = try #require(WlocRewriter.parseFields(f.valueBytes).first { $0.fieldNumber == 5 })
            let inner = WlocRewriter.parseFields(loc.valueBytes)
            #expect(readSigned(inner, 1) == WlocRewriter.coordToInt(-33.0))
            #expect(readSigned(inner, 2) == WlocRewriter.coordToInt(151.0))
        }
    }

    @Test func wlocCoordToIntMatchesAppleFixedPoint() async throws {
        #expect(WlocRewriter.coordToInt(0.0) == 0)
        #expect(WlocRewriter.coordToInt(1.0) == 100_000_000)
        #expect(WlocRewriter.coordToInt(-122.00902) == -12_200_902_000)
    }

}
