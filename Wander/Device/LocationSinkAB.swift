//
//  LocationSinkAB.swift
//  Wander
//
//  DOES THE SINK DECIDE THE FLAG? One measurement, run once, on the phone.
//
//  ── THE QUESTION ─────────────────────────────────────────────────────────────────────────────────
//  Pokémon GO's "Failed to detect location (12)" was traced to iOS's own
//  `CLLocation.sourceInformation.isSimulatedBySoftware`. PoGo re-labels a flagged fix as COMPUTED
//  rather than MEASURED, and its watchdog then errors for want of a measured location. Wander's
//  injection reads TRUE on iOS 26, so it always trips. gs-loc dodges this by making locationd COMPUTE
//  the fix from poisoned Wi-Fi data (no flag is ever attached), but gs-loc is indoor-only and
//  teleport-only.
//
//  The last untested hypothesis: locationd may have MORE THAN ONE simulation-ingestion sink, and
//  WHICH SINK you land in — not any field on the wire — may decide whether the fix is stamped.
//  Two developer-tunnel location services exist:
//
//    (a) com.apple.instruments.server.services.LocationSimulation — the DVT/instruments service,
//        reached via remote_server_connect_rsd + location_simulation_new. THIS IS WANDER'S PATH.
//    (b) com.apple.dt.simulatelocation — the sibling BINARY-PROTOCOL lockdown service, reached via
//        idevice_tcp_provider_new + lockdown_location_simulation_connect. NEVER TESTED ON iOS 26.
//
//  Every FALSE report in the wild is iOS 17/18; every TRUE report is iOS 26. The parsimonious read is
//  that Apple tightened this between 18 and 26 and the angle is closed — but the decisive same-build
//  A/B has never been run, and "probably" is not a measurement.
//
//  ── THE CONSTRUCTOR EXISTS ───────────────────────────────────────────────────────────────────────
//  The sibling sink is reachable in-process, with no pymobiledevice3 and no host tunnel:
//      idevice_pairing_file_read(path)            → IdevicePairingFile
//      idevice_tcp_provider_new(addr, pf, label)  → IdeviceProviderHandle   (pf is CONSUMED)
//      lockdown_location_simulation_connect(prov) → LocationSimulationServiceHandle
//      lockdown_location_simulation_set/_clear/_free
//  All four lockdown_* symbols are exported by the vendored libidevice_ffi.a (verified with `nm`).
//
//  ⚠️ THE HEADER SAYS "iOS 16 AND BELOW" about this API, and that is the single most likely outcome
//  of this test: on iOS 17+ the developer-disk-image services moved off lockdownd and onto RSD, so
//  lockdownd's StartService may simply not know the name any more. That is a RESULT, not a failure —
//  it is why step 0 enumerates the RSD service list first, so a refused connect can be told apart
//  from a service that does not exist on this build.
//
//  ── WHAT IT READS ────────────────────────────────────────────────────────────────────────────────
//  The LIVE `didUpdateLocations` delegate feed, via the existing `LocationDiagnostic` reader — NOT
//  `CLLocationManager.location`. That distinction is load-bearing: Developer Forums thread 741248 is
//  the stale-cached-property confound that has produced bogus FALSE readings in the field. This file
//  does not contain a second location reader; it drives the one Wander already ships.
//
//  ── CONTROLS ─────────────────────────────────────────────────────────────────────────────────────
//  A sink that silently did nothing would report the PREVIOUS fix's flags and look like a clean
//  FALSE. So each leg must prove it moved the device before its flag is trusted:
//    • leg A moves from the real fix to TARGET,
//    • the clear between the legs must be seen to REVERT the device away from TARGET,
//    • leg B must then move it back to TARGET again.
//  If the revert is never observed, leg B's flags are printed but its verdict is WITHHELD, because at
//  that point "the lockdown sink worked" and "leg A's fix was still standing" are indistinguishable.
//  `isProducedByAccessory` is printed beside it, because a FALSE that merely trades one readable flag
//  for another is not a win.
//
//  ── SAFETY ───────────────────────────────────────────────────────────────────────────────────────
//  • Refuses to start while a simulation is active (single-writer discipline, OTA 92) or while gs-loc
//    mode is on, so it can never race the map's hold-resend or the gs-loc keep-alive.
//  • Every FFI call that has no timeout of its own runs on a detached thread under a bounded wait. On
//    a timeout the handles are DELIBERATELY LEAKED rather than freed — the thread may still hold them
//    and a double-free is a crash, whereas one leaked dead session costs nothing.
//  • Both sinks are cleared on every exit path, including every error and every abort.
//

import Foundation
import CoreLocation
import idevice

// MARK: - Bounded FFI runner

/// Runs a no-timeout FFI call on a detached thread and waits at most `timeoutSeconds` for it.
///
/// Mirrors `_boundedSet` in IdeviceFFIBridge.swift and exists for the same reason: `tunnel_create_rppairing`,
/// `lockdown_location_simulation_connect` and friends can block forever against a half-dead tunnel, and a
/// diagnostic that hangs the app is worse than no diagnostic. On a timeout the caller gets `nil` and MUST
/// leak whatever the thread may still be touching.
private final class BoundedFFIBox<V>: @unchecked Sendable {
    var value: V?
}

private func boundedFFI<T>(_ timeoutSeconds: Double, _ body: @escaping () -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    // `body` writes this from the detached thread and we read it only after the semaphore says the
    // thread is done, so the ordering is established by the semaphore itself.
    let box = BoundedFFIBox<T>()
    Thread.detachNewThread {
        box.value = body()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut { return nil }
    return box.value
}

/// Reads an FFI error's code + message BEFORE freeing it, then frees it. A failure site that frees
/// without looking is how "error 3" cost days during the cellular investigation.
private func consumeFFIError(_ error: UnsafeMutablePointer<IdeviceFfiError>?) -> String? {
    guard let error else { return nil }
    let code = error.pointee.code
    let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? "(no message)"
    idevice_error_free(error)
    return "ffi_code=\(code) msg=\(message)"
}

// MARK: - One leg's result

/// Everything one sink produced, in the shape the report prints.
struct LocationSinkReading: Sendable {
    /// Human name of the sink, e.g. "DVT (instruments)".
    let sink: String
    /// What the underlying service is called on the wire.
    let serviceName: String
    /// Did the inject call itself report success?
    let injectAccepted: Bool
    /// Free text about the inject call — the FFI error string, or the status code.
    let injectDetail: String
    /// Did the LIVE delegate feed actually land on the target coordinate? nil = never determined.
    let movedToTarget: Bool?
    /// Why `movedToTarget` is what it is, in one clause.
    let movementDetail: String
    /// "true" / "false" / "nil" / "—" (never read).
    let isSimulatedBySoftware: String
    let isProducedByAccessory: String
    /// The undocumented CLLocation `type` ivar, read crash-safely by `LocationDiagnostic`.
    let privateType: String
    /// The cached-property cross-check, so a disagreement with the live feed is visible.
    let cachedIsSimulated: String
    /// Horizontal accuracy of the fix the flags were read from, for context.
    let horizontalAccuracy: String

    /// True only when the flags may be believed: the sink accepted the write AND the device was seen
    /// to move to the target because of it.
    var isTrustworthy: Bool { injectAccepted && movedToTarget == true }
}

// MARK: - The runner

/// Drives the A/B. Lives on the main actor because it owns the CoreLocation reader; every FFI call is
/// pushed off it.
@MainActor
final class LocationSinkABRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    @Published private(set) var report = ""

    /// THE reader. Not a second one — the same `LocationDiagnostic` the Location Diagnostic screen
    /// uses, which subscribes to `didUpdateLocations` and exposes the live fix plus its flags.
    private let diagnostic = LocationDiagnostic()

    // Tolerances. Generous on purpose: the question is "did the device jump continents", not "how
    // precise is the fix".
    private let arrivedWithinMetres: CLLocationDistance = 2_000
    private let revertedBeyondMetres: CLLocationDistance = 20_000

    // MARK: Public entry

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        report = ""
        defer { isRunning = false }

        var lines: [String] = []
        func say(_ text: String) {
            lines.append(text)
            report = lines.joined(separator: "\n")
        }
        func step(_ text: String) {
            progress = text
            SpoofTrace.log("[sink A/B] \(text)")
        }

        say("LOCATION SINK A/B — does the ingestion sink decide isSimulatedBySoftware?")
        say("Reader: LIVE didUpdateLocations delegate feed (NOT the cached .location property).")
        say("\(ProcessInfo.processInfo.operatingSystemVersionString) · \(Self.timestamp())")
        say("")

        // ── PRECONDITIONS ────────────────────────────────────────────────────────────────────────
        // Checked on the main actor, before anything is dialled, because every one of them is a
        // reason the ANSWER would be wrong rather than merely a reason the run would fail.
        if GslocMode.enabled {
            say("ABORTED — gs-loc mode is ON.")
            say("gs-loc steers network location through the proxy and runs a 5 s keep-alive that would")
            say("fight both sinks. Turn PoGo (gs-loc) mode OFF and run this again.")
            progress = ""
            return
        }
        if SimulationSession.shared.isActive {
            say("ABORTED — a simulation is already running.")
            say("Two writers to one location is the OTA-92 bug. Press Stop, then run this again.")
            progress = ""
            return
        }

        let pairingURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingURL.path) else {
            say("ABORTED — no pairing file. Import one in Settings first.")
            progress = ""
            return
        }
        let pairingPath = pairingURL.path
        let deviceIP = DeviceConnectionContext.targetIPAddress

        // ── STEP 0: baseline fix ─────────────────────────────────────────────────────────────────
        step("Waiting for a real location fix…")
        diagnostic.start()
        defer { diagnostic.stop() }

        guard let baseline = await waitForAnyFix(deadline: 25) else {
            say("ABORTED — no location fix arrived in 25 s.")
            say("Location Services must be ON for Wander with Precise location. Nothing was injected.")
            progress = ""
            return
        }
        let baselineCoord = CLLocation(latitude: baseline.lat, longitude: baseline.lng)
        say("BASELINE (before anything was injected)")
        say("  \(fmt(baseline.lat)), \(fmt(baseline.lng))  ·  hAcc \(String(format: "%.0f m", baseline.horizontalAccuracy))")
        say("  isSimulatedBySoftware=\(baseline.isSimulatedBySoftware)  isProducedByAccessory=\(baseline.isProducedByAccessory)  type=\(baseline.privateType)")
        say("")

        // ONE coordinate for both legs, so the comparison isolates the sink and nothing else. Picked
        // to be unambiguously far from wherever the phone is, because "did it move" is the control
        // this whole test rests on.
        let target = Self.farTarget(from: baselineCoord)
        say("TARGET (identical for both legs): \(fmt(target.coordinate.latitude)), \(fmt(target.coordinate.longitude)) — \(Self.targetName(target))")
        say("  \(String(format: "%.0f", baselineCoord.distance(from: target) / 1000)) km from the baseline fix.")
        say("")

        // ── STEP 0.5: what does this build even advertise? ───────────────────────────────────────
        // Runs BEFORE any session exists, and frees everything it opens. If the lockdown leg later
        // refuses, this is what says whether the service is missing or merely moved.
        step("Enumerating the device's RSD service list…")
        say(await Self.serviceInventory(deviceIP: deviceIP, pairingPath: pairingPath))
        // The inventory opens an rppairing session and closes it again, and remotepairingd has been
        // seen to refuse a NEW connect for a moment after one goes away (the `os error 61` in the
        // cellular investigation). Leg A is the control for this entire test, so it gets a quiet
        // couple of seconds rather than being handed a door that is still swinging shut.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        say("")

        // ── LEG A: the CURRENT path (DVT / instruments) ───────────────────────────────────────────
        step("Leg A — injecting via the DVT path Wander ships…")
        let legA = await runDVTLeg(deviceIP: deviceIP, pairingPath: pairingPath, target: target)
        say(Self.render(legA))
        say("")

        // ── CLEAR + REVERT CHECK ─────────────────────────────────────────────────────────────────
        // The control that makes leg B readable at all.
        step("Clearing the DVT fix and waiting for the device to revert…")
        let clearCode = await onLocationQueue { clear_simulated_location() }
        let reverted = await waitForFix(deadline: 35) { fix in
            CLLocation(latitude: fix.lat, longitude: fix.lng).distance(from: target) > self.revertedBeyondMetres
        }
        if reverted != nil {
            say("CLEAR: device reverted away from the target (\(Self.clearWords(clearCode))). Leg B is readable.")
        } else {
            say("CLEAR: device did NOT revert within 35 s (\(Self.clearWords(clearCode))).")
            say("  Leg B's flags will still be printed, but its verdict is WITHHELD — a fix still parked")
            say("  on the target cannot tell \"the lockdown sink worked\" apart from \"leg A is standing\".")
        }
        say("")

        // ── LEG B: the sibling path (lockdown / com.apple.dt.simulatelocation) ────────────────────
        step("Leg B — injecting via the lockdown sibling service…")
        let legB = await runLockdownLeg(deviceIP: deviceIP,
                                        pairingPath: pairingPath,
                                        target: target,
                                        revertObserved: reverted != nil)
        say(Self.render(legB))
        say("")

        // ── RESTORE ──────────────────────────────────────────────────────────────────────────────
        // Belt and braces. Leg B already tore its own handle down on every path it can return from,
        // and the DVT side was already cleared above — both calls here are idempotent, and running
        // them anyway is cheaper than reasoning about which path got here.
        step("Restoring — clearing both sinks…")
        let finalClear = await onLocationQueue { clear_simulated_location() }
        await offMain { LockdownLocationSink.teardown() }
        say("RESTORE: DVT \(Self.clearWords(finalClear)); lockdown handle freed. No spoof left running.")
        say("")

        // ── VERDICT ──────────────────────────────────────────────────────────────────────────────
        say(Self.decision(legA: legA, legB: legB, revertObserved: reverted != nil))
        progress = ""
    }

    // MARK: - Leg A: the DVT path Wander ships

    private func runDVTLeg(deviceIP: String, pairingPath: String, target: CLLocation) async -> LocationSinkReading {
        // The PRODUCTION funnel, deliberately: the point of leg A is to measure what Wander actually
        // does, not a re-implementation that might differ. `simulate_location` builds/reuses the same
        // cached DVT session every teleport uses.
        var code = await onLocationQueue {
            simulate_location(deviceIP, target.coordinate.latitude, target.coordinate.longitude, pairingPath)
        }
        var detail = "simulate_location returned 0 (ok)."
        // ONE retry, and only here. Leg A is the control the whole comparison rests on, and the most
        // likely reason for a first-attempt failure is a transient refused connect rather than a real
        // fault. A retry on leg B would be a different thing entirely — it would let a flaky sink look
        // like a working one — so leg B gets exactly one attempt.
        if code != 0 {
            SpoofTrace.log("[sink A/B] leg A first attempt failed with \(code) — retrying once")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            code = await onLocationQueue {
                simulate_location(deviceIP, target.coordinate.latitude, target.coordinate.longitude, pairingPath)
            }
            detail = "simulate_location returned 0 (ok) on the SECOND attempt; the first was refused."
        }
        guard code == 0 else {
            return LocationSinkReading(
                sink: "A · DVT (instruments) — Wander's current path",
                serviceName: "com.apple.instruments.server.services.LocationSimulation",
                injectAccepted: false,
                injectDetail: "simulate_location returned status \(code) (0 = ok) on both attempts. Nothing was injected — check the tunnel chip.",
                movedToTarget: false,
                movementDetail: "not attempted — the inject itself failed",
                isSimulatedBySoftware: "—", isProducedByAccessory: "—",
                privateType: "—", cachedIsSimulated: "—", horizontalAccuracy: "—")
        }

        let arrival = await waitForFix(deadline: 30) { fix in
            CLLocation(latitude: fix.lat, longitude: fix.lng).distance(from: target) <= self.arrivedWithinMetres
        }
        return Self.reading(sink: "A · DVT (instruments) — Wander's current path",
                            service: "com.apple.instruments.server.services.LocationSimulation",
                            accepted: true,
                            injectDetail: detail,
                            arrival: arrival,
                            missDetail: "no fix within \(Int(arrivedWithinMetres)) m of the target arrived in 30 s")
    }

    // MARK: - Leg B: the lockdown sibling

    private func runLockdownLeg(deviceIP: String,
                                pairingPath: String,
                                target: CLLocation,
                                revertObserved: Bool) async -> LocationSinkReading {
        let sinkName = "B · LOCKDOWN sibling (never tested on iOS 26)"
        let service = "com.apple.dt.simulatelocation"

        let outcome = await offMain {
            LockdownLocationSink.inject(deviceIP: deviceIP,
                                        pairingPath: pairingPath,
                                        latitude: target.coordinate.latitude,
                                        longitude: target.coordinate.longitude)
        }

        guard outcome.accepted else {
            return LocationSinkReading(
                sink: sinkName, serviceName: service,
                injectAccepted: false,
                injectDetail: outcome.detail,
                movedToTarget: false,
                movementDetail: "not attempted — the sink could not be reached",
                isSimulatedBySoftware: "—", isProducedByAccessory: "—",
                privateType: "—", cachedIsSimulated: "—", horizontalAccuracy: "—")
        }

        let arrival = await waitForFix(deadline: 30) { fix in
            CLLocation(latitude: fix.lat, longitude: fix.lng).distance(from: target) <= self.arrivedWithinMetres
        }
        var result = Self.reading(sink: sinkName,
                                  service: service,
                                  accepted: true,
                                  injectDetail: outcome.detail,
                                  arrival: arrival,
                                  missDetail: "no fix within \(Int(arrivedWithinMetres)) m of the target arrived in 30 s")

        // The withheld case: arriving on target proves nothing if we never saw the device leave it.
        if arrival != nil && !revertObserved {
            result = LocationSinkReading(
                sink: result.sink, serviceName: result.serviceName,
                injectAccepted: result.injectAccepted, injectDetail: result.injectDetail,
                movedToTarget: nil,
                movementDetail: "UNVERIFIABLE — the device never left the target after the clear, so landing on it again is not evidence this sink did anything",
                isSimulatedBySoftware: result.isSimulatedBySoftware,
                isProducedByAccessory: result.isProducedByAccessory,
                privateType: result.privateType,
                cachedIsSimulated: result.cachedIsSimulated,
                horizontalAccuracy: result.horizontalAccuracy)
        }

        // Always tear the lockdown session down, whatever happened above.
        await offMain { LockdownLocationSink.teardown() }
        return result
    }

    // MARK: - Waiting on the LIVE delegate feed

    /// Waits for the NEXT delegate callback (any fix at all).
    private func waitForAnyFix(deadline seconds: Double) async -> LocationDiagnostic.Reading? {
        await waitForFix(deadline: seconds) { _ in true }
    }

    /// Polls the live reader until a NEW delegate callback satisfies `matches`, or the deadline passes.
    ///
    /// Deliberately requires a callback newer than the one in hand (`updates` strictly increases), so a
    /// stale fix that already happened to satisfy the predicate can never answer for a sink that did
    /// nothing. `LocationDiagnostic.updates` is incremented once per `didUpdateLocations`.
    private func waitForFix(deadline seconds: Double,
                            matches: @escaping (LocationDiagnostic.Reading) -> Bool) async -> LocationDiagnostic.Reading? {
        let startingUpdates = diagnostic.updates
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if diagnostic.updates > startingUpdates, let reading = diagnostic.reading, matches(reading) {
                return reading
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    // MARK: - Off-actor helpers

    /// Runs blocking work off the main actor.
    private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated) { body() }.value
    }

    /// Runs work on the SERIAL location command queue — the same queue every production inject uses —
    /// so leg A cannot interleave with anything else that writes location.
    private func onLocationQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - Formatting

    private func fmt(_ value: Double) -> String { String(format: "%.6f", value) }

    /// Words for `clear_simulated_location`'s status code, because a bare number on a clear reads
    /// like a failure whether or not it is one. Re-mapped in build 151, when the clear stopped being
    /// gated on a reachability probe: 12 now means the DEVICE answered with an error (the one case
    /// where it may still be simulating), 13 is no longer produced by this path at all, and 14 is the
    /// new "we sent the stop and haven't heard back".
    private static func clearWords(_ code: Int32) -> String {
        switch code {
        case 0:  return "clear ok"
        case 12: return "the device refused the clear — it may still be simulating"
        case 13: return "tunnel was unreachable, local handle dropped"
        case 14: return "clear was sent but did not come back in time"
        default: return "clear status \(code)"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func reading(sink: String,
                                service: String,
                                accepted: Bool,
                                injectDetail: String,
                                arrival: LocationDiagnostic.Reading?,
                                missDetail: String) -> LocationSinkReading {
        guard let arrival else {
            return LocationSinkReading(
                sink: sink, serviceName: service,
                injectAccepted: accepted, injectDetail: injectDetail,
                movedToTarget: false, movementDetail: missDetail,
                isSimulatedBySoftware: "—", isProducedByAccessory: "—",
                privateType: "—", cachedIsSimulated: "—", horizontalAccuracy: "—")
        }
        return LocationSinkReading(
            sink: sink, serviceName: service,
            injectAccepted: accepted, injectDetail: injectDetail,
            movedToTarget: true,
            movementDetail: "the live delegate feed landed on the target",
            isSimulatedBySoftware: arrival.isSimulatedBySoftware,
            isProducedByAccessory: arrival.isProducedByAccessory,
            privateType: arrival.privateType,
            cachedIsSimulated: arrival.cachedIsSimulated,
            horizontalAccuracy: String(format: "%.0f m", arrival.horizontalAccuracy))
    }

    private static func render(_ r: LocationSinkReading) -> String {
        var out = [String]()
        out.append("SINK \(r.sink)")
        out.append("  service            \(r.serviceName)")
        out.append("  inject accepted    \(r.injectAccepted ? "YES" : "NO") — \(r.injectDetail)")
        switch r.movedToTarget {
        case .some(true):  out.append("  location moved     YES — \(r.movementDetail)")
        case .some(false): out.append("  location moved     NO — SINK DID NOT TAKE EFFECT (\(r.movementDetail))")
        case .none:        out.append("  location moved     UNKNOWN — \(r.movementDetail)")
        }
        out.append("  isSimulatedBySoftware   \(r.isSimulatedBySoftware)")
        out.append("  isProducedByAccessory   \(r.isProducedByAccessory)")
        out.append("  private type / cached   \(r.privateType) / \(r.cachedIsSimulated)")
        out.append("  horizontal accuracy     \(r.horizontalAccuracy)")
        if !r.isTrustworthy {
            out.append("  ⚠️ VERDICT WITHHELD for this row — the flags above are not evidence about this sink.")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - The decision rule, printed so the result interprets itself

    private static func decision(legA: LocationSinkReading,
                                 legB: LocationSinkReading,
                                 revertObserved: Bool) -> String {
        var out = [String]()
        out.append("── DECISION RULE (read this against the two rows above) ──")
        out.append("DVT=TRUE, LOCKDOWN=FALSE (accessory still false) -> THE SINK MATTERS. Switching Wander's")
        out.append("  injection to the lockdown service would clear Error 12 over a tunnel that HOLDS, which")
        out.append("  beats gs-loc outright.")
        out.append("BOTH TRUE -> the DVT-flag angle is closed on iOS 26; gs-loc remains the only path and the")
        out.append("  search is over.")
        out.append("LOCKDOWN unreachable -> the sibling sink does not exist on this build; same conclusion as")
        out.append("  BOTH TRUE, reached one step earlier.")
        out.append("")
        out.append("── WHAT THIS RUN SAYS ──")

        guard legA.isTrustworthy else {
            out.append("INCONCLUSIVE. Leg A (the path Wander ships) did not produce a trusted fix, so there is")
            out.append("no control to compare against. Fix the tunnel and re-run: \(legA.injectAccepted ? legA.movementDetail : legA.injectDetail)")
            return out.joined(separator: "\n")
        }

        guard legB.injectAccepted else {
            out.append("LOCKDOWN SINK UNREACHABLE on this build. \(legB.injectDetail)")
            out.append("Wander's DVT fix read isSimulatedBySoftware=\(legA.isSimulatedBySoftware) in the same run.")
            out.append("")
            // The measured values stay OUT of the localizable string on purpose — a translated key
            // that swallowed the numbers would turn a measurement into a slogan.
            out.append(L("sinkab.verdict.unreachable",
                         fallback: "In plain words: the sibling service could not be opened at all, so it cannot be the way out. Cross-check the RSD service list printed above. If com.apple.dt.simulatelocation is not in it, the service does not exist on this build and the hypothesis is closed. If it IS in the list, it moved to RSD, and this FFI exports no way to reach it there — nothing turns an adapter stream into an IdeviceHandle — which is a tooling limit rather than a platform one."))
            return out.joined(separator: "\n")
        }

        guard legB.isTrustworthy else {
            out.append("LOCKDOWN ROW WITHHELD. The sink accepted the write but its effect could not be proven")
            out.append("(\(legB.movementDetail)).")
            out.append(revertObserved
                       ? "Re-run once the tunnel is steadier — the flags below the withheld row are not evidence."
                       : "Re-run somewhere the device can get a real fix quickly, so the clear is seen to revert.")
            return out.joined(separator: "\n")
        }

        let a = legA.isSimulatedBySoftware
        let b = legB.isSimulatedBySoftware
        if a == "true" && b == "false" && legB.isProducedByAccessory != "true" {
            out.append(L("sinkab.verdict.sinkmatters",
                         fallback: "THE SINK MATTERS. The same coordinate read isSimulatedBySoftware=true through the DVT service and false through the lockdown sibling, with isProducedByAccessory still false. Switching Wander's injection to the lockdown service is now a real candidate for clearing Pokémon GO's Error 12 over a tunnel that holds — which would beat gs-loc outright, since it keeps movement and works outdoors. This run is a MEASUREMENT, not a migration: the switch is a separate, deliberate decision."))
        } else if a == "true" && b == "false" {
            out.append("HALF A WIN, NOT A WIN. isSimulatedBySoftware went false through the lockdown sink, but")
            out.append("isProducedByAccessory came back \(legB.isProducedByAccessory) — one readable flag was traded")
            out.append("for another, and an anti-cheat that reads either one is unchanged.")
        } else if a == b {
            out.append("BOTH SINKS AGREE — isSimulatedBySoftware=\(a) through each of them.")
            out.append(L("sinkab.verdict.bothsame",
                         fallback: "Which service the coordinate arrives through does not change how iOS stamps the fix on this build, so the DVT-flag angle is closed. gs-loc remains the only path that produces an unflagged fix, and the search for a tunnel-side fix is over."))
        } else {
            out.append("UNEXPECTED COMBINATION: DVT=\(a), LOCKDOWN=\(b). Copy this whole report before")
            out.append("re-running — a reversed result is more interesting than either expected one.")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Target selection

    /// A fixed, far-away coordinate, chosen so "did the device move" is never a judgement call. Two
    /// candidates on opposite sides of the planet; whichever is further from the phone wins, so the
    /// test still works for someone standing next to one of them.
    private static func farTarget(from baseline: CLLocation) -> CLLocation {
        let colosseum = CLLocation(latitude: 41.890210, longitude: 12.492231)
        let tokyoTower = CLLocation(latitude: 35.658581, longitude: 139.745433)
        return baseline.distance(from: colosseum) >= baseline.distance(from: tokyoTower) ? colosseum : tokyoTower
    }

    private static func targetName(_ target: CLLocation) -> String {
        target.coordinate.longitude < 100 ? "Colosseum, Rome" : "Tokyo Tower, Tokyo"
    }

    // MARK: - Step 0.5: RSD service inventory

    /// Asks the device which services its developer tunnel advertises, and reports whether either
    /// location service is among them.
    ///
    /// This is what lets a refused lockdown connect be READ. Runs before any session exists and frees
    /// the adapter and handshake it opens, so it cannot collide with leg A. Bounded, because
    /// `tunnel_create_rppairing` has no timeout of its own.
    nonisolated private static func serviceInventory(deviceIP: String, pairingPath: String) async -> String {
        await Task.detached(priority: .userInitiated) {
            RsdServiceInventory.summarize(deviceIP: deviceIP, pairingPath: pairingPath)
        }.value
    }
}

// MARK: - The lockdown sink itself

/// The sibling ingestion path: `com.apple.dt.simulatelocation`, reached over lockdownd rather than
/// over the DVT/instruments channel.
///
/// State is file-private and single-threaded by construction: only `LocationSinkABRunner` calls in,
/// and only from a detached task, one call at a time.
enum LockdownLocationSink {

    struct Outcome: Sendable {
        let accepted: Bool
        let detail: String
    }

    /// lockdownd's own TCP port. `idevice_tcp_provider_new` takes only an address and dials whatever
    /// port the service it is asked for lives on, so this is here for the reachability probe.
    private static let lockdowndPort: UInt16 = 62078

    private nonisolated(unsafe) static var provider: OpaquePointer?
    private nonisolated(unsafe) static var handle: OpaquePointer?

    /// Connect to the sibling service and set one coordinate. Never blocks longer than its bounds.
    static func inject(deviceIP: String, pairingPath: String, latitude: Double, longitude: Double) -> Outcome {
        teardown()

        // Fail fast rather than hand an un-timeout-able FFI call a dead endpoint.
        let probe = EndpointProbe.probe(deviceIP, port: lockdowndPort, timeoutSeconds: 4)
        SpoofTrace.log("[sink A/B] lockdownd probe \(probe.logLine)")
        guard probe.isReachable else {
            return Outcome(accepted: false,
                           detail: "lockdownd at \(probe.destination) did not answer (\(probe.outcome.label), errno \(probe.errnoValue) \(probe.errnoName)). On iOS 17+ the developer services moved off lockdownd, so this is the expected shape of a closed door — check the RSD list above.")
        }

        // The lockdown provider needs the CLASSIC pair record type, not the RemotePairing one the DVT
        // path reads. Same file on disk; different reader.
        var pairingFile: OpaquePointer?
        if let detail = consumeFFIError(pairingPath.withCString { idevice_pairing_file_read($0, &pairingFile) }) {
            return Outcome(accepted: false, detail: "idevice_pairing_file_read failed: \(detail). The stored file is a RemotePairing record; the lockdown provider may not accept it.")
        }
        guard let pairingFile else {
            return Outcome(accepted: false, detail: "idevice_pairing_file_read returned no handle and no error.")
        }

        guard let address = DeviceConnectionContext.makeSocketAddress(deviceIP, port: lockdowndPort) else {
            idevice_pairing_file_free(pairingFile)
            return Outcome(accepted: false, detail: "\(deviceIP) is not a usable IPv4/IPv6 literal.")
        }

        // ⚠️ `idevice_tcp_provider_new` CONSUMES the pairing file — it must never be freed or reused
        // after this call, whether it succeeded or not.
        var newProvider: OpaquePointer?
        let providerDetail = address.withSockaddr { pointer, _ in
            consumeFFIError(idevice_tcp_provider_new(pointer, pairingFile, "WanderSinkAB", &newProvider))
        }
        if let providerDetail {
            return Outcome(accepted: false, detail: "idevice_tcp_provider_new failed: \(providerDetail)")
        }
        guard let newProvider else {
            return Outcome(accepted: false, detail: "idevice_tcp_provider_new returned no handle and no error.")
        }
        provider = newProvider

        // THE CALL THE WHOLE HYPOTHESIS RESTS ON. Bounded: lockdownd's StartService can sit there.
        var connected: OpaquePointer?
        let connectDetail = boundedFFI(20.0) { () -> String? in
            consumeFFIError(lockdown_location_simulation_connect(newProvider, &connected))
        }
        guard let connectDetail else {
            // Timed out. The detached thread may still be inside the FFI holding `newProvider`, so we
            // must NOT free it — leak one dead provider rather than risk a use-after-free.
            provider = nil
            return Outcome(accepted: false, detail: "lockdown_location_simulation_connect did not return within 20 s. Handles deliberately leaked (the FFI thread may still hold them); nothing was injected.")
        }
        if let text = connectDetail {
            teardown()
            return Outcome(accepted: false, detail: "lockdown_location_simulation_connect failed: \(text). This is the expected result if com.apple.dt.simulatelocation no longer exists on iOS 26.")
        }
        guard let connected else {
            teardown()
            return Outcome(accepted: false, detail: "lockdown_location_simulation_connect returned no handle and no error.")
        }
        handle = connected

        // The lockdown protocol carries the coordinate as decimal STRINGS, not doubles — one of the
        // few places the two sinks differ on the wire.
        let latitudeText = String(format: "%.6f", latitude)
        let longitudeText = String(format: "%.6f", longitude)
        let setDetail = boundedFFI(15.0) { () -> String? in
            latitudeText.withCString { latitudePointer in
                longitudeText.withCString { longitudePointer in
                    consumeFFIError(lockdown_location_simulation_set(connected, latitudePointer, longitudePointer))
                }
            }
        }
        guard let setDetail else {
            // Same leak-not-free discipline as above.
            provider = nil
            handle = nil
            return Outcome(accepted: false, detail: "lockdown_location_simulation_set did not return within 15 s. Handles deliberately leaked.")
        }
        if let text = setDetail {
            teardown()
            return Outcome(accepted: false, detail: "lockdown_location_simulation_set failed: \(text)")
        }

        return Outcome(accepted: true, detail: "lockdown_location_simulation_connect + _set both returned success against \(probe.destination).")
    }

    /// Clears and frees whatever this sink is holding. Safe to call any number of times, including
    /// when nothing is open.
    static func teardown() {
        if let handle {
            // Bounded, because a clear against a half-dead lockdownd blocks exactly like a set does.
            _ = boundedFFI(10.0) { consumeFFIError(lockdown_location_simulation_clear(handle)) }
            lockdown_location_simulation_free(handle)
            self.handle = nil
        }
        if let provider {
            idevice_provider_free(provider)
            self.provider = nil
        }
    }
}

// MARK: - RSD service inventory

/// Reads the developer tunnel's advertised service list. Read-only: it opens a tunnel, asks for the
/// list, prints it, and frees everything.
enum RsdServiceInventory {

    /// The two names this whole investigation is about.
    private static let dvtService = "com.apple.instruments.server.services.LocationSimulation"
    private static let lockdownService = "com.apple.dt.simulatelocation"

    static func summarize(deviceIP: String, pairingPath: String) -> String {
        var out = ["RSD SERVICE INVENTORY (which location services this build advertises)"]

        let probe = EndpointProbe.probe(deviceIP, timeoutSeconds: 4)
        guard probe.isReachable else {
            out.append("  skipped — developer tunnel at \(probe.destination) did not answer (\(probe.outcome.label)).")
            return out.joined(separator: "\n")
        }

        var pairingHandle: OpaquePointer?
        if let detail = consumeFFIError(pairingPath.withCString { rp_pairing_file_read($0, &pairingHandle) }) {
            out.append("  skipped — rp_pairing_file_read failed: \(detail)")
            return out.joined(separator: "\n")
        }
        guard let pairingHandle else {
            out.append("  skipped — rp_pairing_file_read returned no handle.")
            return out.joined(separator: "\n")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        guard let address = DeviceConnectionContext.makeSocketAddress(deviceIP) else {
            out.append("  skipped — \(deviceIP) is not a usable address literal.")
            return out.joined(separator: "\n")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let tunnelDetail = boundedFFI(25.0) { () -> String? in
            address.withSockaddr { pointer, length in
                consumeFFIError(tunnel_create_rppairing(pointer, length, "WanderSinkAB",
                                                        pairingHandle, nil, nil, &adapter, &handshake))
            }
        }
        guard let tunnelDetail else {
            // Leak rather than free: the FFI thread may still be inside the call. This is why the
            // inventory runs BEFORE any session exists — a leak here cannot corrupt one.
            out.append("  skipped — tunnel_create_rppairing did not return within 25 s (handles leaked, nothing injected).")
            return out.joined(separator: "\n")
        }
        if let text = tunnelDetail {
            out.append("  skipped — tunnel_create_rppairing failed: \(text)")
            return out.joined(separator: "\n")
        }
        defer {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
        }
        guard let handshake else {
            out.append("  skipped — tunnel_create_rppairing returned no handshake.")
            return out.joined(separator: "\n")
        }

        var services: UnsafeMutablePointer<CRsdServiceArray>?
        if let detail = consumeFFIError(rsd_get_services(handshake, &services)) {
            out.append("  rsd_get_services failed: \(detail)")
            return out.joined(separator: "\n")
        }
        guard let services else {
            out.append("  rsd_get_services returned no list.")
            return out.joined(separator: "\n")
        }
        defer { rsd_free_services(services) }

        var names: [String] = []
        var interesting: [String] = []
        let count = services.pointee.count
        if let base = services.pointee.services {
            for index in 0..<count {
                let entry = base[index]
                guard let raw = entry.name, let name = String(validatingUTF8: raw) else { continue }
                names.append(name)
                if name == dvtService || name == lockdownService {
                    let entitlement = entry.entitlement.flatMap { String(validatingUTF8: $0) } ?? "(none)"
                    interesting.append("    \(name)  port \(entry.port)  xpc=\(entry.uses_remote_xpc)  entitlement=\(entitlement)")
                }
            }
        }

        out.append("  \(count) services advertised.")
        out.append("  \(dvtService): \(names.contains(dvtService) ? "PRESENT" : "ABSENT")")
        out.append("  \(lockdownService): \(names.contains(lockdownService) ? "PRESENT" : "ABSENT")")
        out.append(contentsOf: interesting)
        out.append("  Read this WITH leg B: 'lockdown service ABSENT everywhere' closes the hypothesis;")
        out.append("  'PRESENT here but leg B refused' means it moved to RSD and this FFI exports no way")
        out.append("  to reach it there — there is no call that turns an adapter stream into an IdeviceHandle.")
        return out.joined(separator: "\n")
    }
}
