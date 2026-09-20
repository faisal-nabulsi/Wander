//
//  TunnelManager.swift
//  Wander
//

import Foundation

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var isConnected = false

    private var isStarting = false
    /// When the in-flight start began, so a hung one can be detected and superseded.
    private var startedAt: Date?
    /// A start that hasn't returned in this long is treated as wedged, not in-progress.
    private static let startStallTimeout: TimeInterval = 25

    private init() {}

    func markDisconnected() {
        runOnMain {
            self.isConnected = false
        }
    }

    /// Longest absence after which cached tunnel handles are no longer assumed to have survived.
    ///
    /// The thing this whole path exists to repair is iOS suspending the app and reclaiming the socket
    /// under the DVT connection (TN2277). That needs a REAL suspension. A hop to Settings, Shortcuts
    /// or the game and straight back is not one, and rebuilding after it throws away a working tunnel
    /// for nothing. Deliberately short, because the safe direction of error here is "rebuild anyway":
    /// a needless rebuild wastes a second, a skipped rebuild can strand the handles until relaunch.
    private static let assumeTunnelSurvivesBackground: TimeInterval = 15

    // ─────────────────────────────────────────────────────────────────────────────────────────────
    //  FOREGROUND REFRESH — the app came forward after a real `.background`.
    //
    //  This used to be a bare `startTunnelInBackground(showErrorUI: false)`, i.e. an UNCONDITIONAL
    //  new tunnel dial on every single return to the app. It is inherited from the JIT app this was
    //  built on, where it was the product; here it is a background chore for Device Info, the app
    //  list, the setup checklist and the DDI auto-mount. It is NOT what keeps a spoof alive — the
    //  live session runs on its own tunnel with its own handles (see `LocationSimulationState`), and
    //  nothing here can reach it.
    //
    //  Three things were wrong with firing it unconditionally:
    //
    //   1. ON CELLULAR IT CANNOT SUCCEED. `remotepairingdeviced` marks its own listeners
    //      deny-cellular, and the kernel skips a restricted socket in the port lookup, so the SYN
    //      draws an instant RST. Measured, not inferred. A dial that cannot connect cannot refresh
    //      anything, so on mobile data this was a guaranteed-failing connect on every app switch —
    //      in the flagship flow (spoof running, user in the game, tabbing back and forth). Build 148
    //      already made exactly this call for `TunnelHealthMonitor`; this is the same answer for the
    //      last automatic new-connect that was still firing on cellular.
    //
    //   2. A SUCCESSFUL dial REPLACES the cached handles, and other threads hold those as raw
    //      pointers across FFI calls — including on the location serial queue. That is a real race
    //      (now retired-not-freed in `JITEnableContext`, but the cheapest fix is to not churn the
    //      handles when nothing asked for it).
    //
    //   3. Returning to the app is the WORST moment to dial. Build 127 fired a reconnect on every
    //      foreground and wedged the un-timeout-able RSD handshake, because coming back is exactly
    //      when the user has just toggled Airplane Mode in Control Center and the network is
    //      mid-transition. That was reverted in build 128 (see the note in MainTabView); this is the
    //      same trigger one layer down.
    //
    //  So the dial is now gated on EVIDENCE that it is both possible and needed, and every decision
    //  writes one line to the log so the answer is readable instead of guessable.
    //
    //  What is deliberately NOT changed: `start()` itself. Cellular Mode, the Intents helper and the
    //  Try Again button all go through it and still get an unconditional rebuild, which is correct —
    //  those are cases where a person, or a sequence that knows what it is doing, asked for one.
    // ─────────────────────────────────────────────────────────────────────────────────────────────
    @MainActor
    func refreshAfterForeground(backgroundedFor interval: TimeInterval) {
        let away = interval.isFinite ? "\(Int(interval))s" : "unknown"

        // The two cheap, decisive questions come FIRST, ahead of the pairing-file check, because that
        // check runs `prepareURL()` — synchronous filesystem work (mkdir + a legacy-path migration) on
        // the MAIN thread, on every single return to the app. In the two flows below the answer is no
        // regardless of what is on disk, so the disk should not be touched to learn that.

        // (1) Cellular: refused by construction. Note this leaves the cached handles EXACTLY as they
        // were, which is also what the failing dial did — it threw before reaching the swap — so this
        // is strictly the removal of wasted work, not a change of state.
        if NetworkReachability.isOnCellularSnapshot {
            LogManager.shared.addInfoLog("[tunnel] foreground (away \(away)): skipped redial — on mobile data, a new connection to the pairing listener is refused by iOS")
            return
        }

        // (2) A live spoof does not use these handles, and swapping them mid-session is pure risk for
        // zero benefit. Recovery during a session belongs to TunnelHealthMonitor, which knows how to
        // do it without adding a second writer.
        if SimulationSession.shared.isActive {
            LogManager.shared.addInfoLog("[tunnel] foreground (away \(away)): skipped redial — spoof active, the live session runs on its own tunnel")
            return
        }

        // (3) No pairing file means there is nothing to dial with; `start()` would bail anyway, silently.
        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else { return }

        // (4) Handles are still cached and the app was not away long enough for iOS to have taken the
        // socket. Nothing to repair.
        if JITEnableContext.shared.hasTunnelHandles, interval < Self.assumeTunnelSurvivesBackground {
            LogManager.shared.addInfoLog("[tunnel] foreground (away \(away)): skipped redial — tunnel handles still cached, too brief to have been reclaimed")
            return
        }

        let reason = JITEnableContext.shared.hasTunnelHandles
            ? "handles may be stale after a real suspension"
            : "no tunnel handles cached"
        LogManager.shared.addInfoLog("[tunnel] foreground (away \(away)): rebuilding — \(reason)")
        start(showErrorUI: false)
    }

    func start(showErrorUI: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.start(showErrorUI: showErrorUI)
            }
            return
        }

        let pairingFileURL = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            isConnected = false
            return
        }

        // `isStarting` is cleared in finishStart(), which only runs once startTunnel() RETURNS. That call
        // can hang indefinitely (un-timeout-able RSD handshake over a half-open socket during a network
        // change — exactly what Airplane Mode toggling produces). When it hung, this latch stayed true and
        // every later start() returned silently: the tunnel could never come back even once conditions
        // were good again, so the UI sat on "reconnecting…" until the app was force-quit. Treat a latch
        // older than the stall window as stale and let the new attempt through.
        if isStarting, let since = startedAt, Date().timeIntervalSince(since) > Self.startStallTimeout {
            LogManager.shared.addWarningLog("Tunnel start appears wedged (\(Int(Date().timeIntervalSince(since)))s) — allowing a fresh attempt")
            isStarting = false
        }

        guard !isStarting else {
            return
        }

        // PRE-FLIGHT: refuse a dial whose destination is an address THIS DEVICE already owns.
        //
        // `remotepairingd` resets any connection sourced from a device-owned address, and when the
        // target IS one of our interface addresses the kernel picks that same address as the source
        // — so the dial is a device-owned-source dial by construction and can never succeed. It
        // surfaces as errno 54 ECONNRESET, which reads like a network fault and is not one.
        //
        // This is not hypothetical: three users hit it on iOS 26.5.2 after setting LocalDevVPN's
        // Device IP to the same value as its Tunnel IP. The old error copy invited exactly that by
        // naming a single address. Catching it here turns a permanent, self-inflicted dead end into
        // one sentence that names the fix, BEFORE we burn a connect attempt on it.
        if let conflict = Self.targetIsOwnAddress(DeviceConnectionContext.targetIPAddress) {
            let msg = "LocalDevVPN's Tunnel IP (\(DeviceConnectionContext.targetIPAddress)) is also your device's own \(conflict) address, so Wander would be dialling itself and iOS refuses that. In LocalDevVPN set Device IP to \(DeviceConnectionContext.defaultDeviceIPAddress) and Tunnel IP to \(DeviceConnectionContext.defaultTargetIPAddress) — they must be different — then reconnect."
            LogManager.shared.addErrorLog("Tunnel pre-flight: target \(DeviceConnectionContext.targetIPAddress) is this device's own \(conflict) address — refusing to dial. \(msg)")
            isConnected = false
            isStarting = false
            if showErrorUI {
                showAlert(title: "Tunnel IP is your own address",
                          message: msg,
                          showOk: true,
                          showTryAgain: false) { _ in }
            }
            return
        }

        isStarting = true
        startedAt = Date()

        DispatchQueue.global(qos: .userInteractive).async { [showErrorUI] in
            let result: Result<Void, NSError>
            do {
                try JITEnableContext.shared.startTunnel()
                result = .success(())
            } catch {
                result = .failure(error as NSError)
            }

            DispatchQueue.main.async {
                self.finishStart(result, showErrorUI: showErrorUI)
            }
        }
    }

    private func finishStart(_ result: Result<Void, NSError>, showErrorUI: Bool) {
        isStarting = false

        switch result {
        case .success:
            isConnected = true
            LogManager.shared.addInfoLog("Tunnel connected successfully")
            mountDeveloperDiskImageIfNeeded()
        case .failure(let error):
            isConnected = false
            handleStartFailure(error, showErrorUI: showErrorUI)
        }
    }

    private func mountDeveloperDiskImageIfNeeded() {
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        guard FileManager.default.fileExists(atPath: trustcachePath),
              !MountingProgress.shared.coolisMounted,
              MountingProgress.shared.mountingThread == nil else {
            return
        }
        MountingProgress.shared.pubMount()
    }

    private func handleStartFailure(_ error: NSError, showErrorUI: Bool) {
        LogManager.shared.addErrorLog(tunnelConnectionLogMessage(for: error))
        guard showErrorUI else {
            return
        }

        if error.code == -9 {
            handleInvalidPairingFile()
            return
        }

        showAlert(
            title: "Connection Error",
            message: tunnelConnectionAlertMessage(for: error),
            showOk: false,
            showTryAgain: true
        ) { shouldTryAgain in
            if shouldTryAgain {
                startTunnelInBackground()
            }
        }
    }

    private func handleInvalidPairingFile() {
        LogManager.shared.addInfoLog("Pairing file reported invalid; keeping existing file")

        showAlert(
            title: "Invalid Pairing File",
            message: "The pairing file may be invalid or expired. You can import a new pairing file to replace it.",
            showOk: true,
            showTryAgain: false,
            primaryButtonText: "Select New File"
        ) { _ in
            NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
        }
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

private func tunnelConnectionLogMessage(for error: NSError) -> String {
    let target = "\(DeviceConnectionContext.targetIPAddress):49152"
    return "Tunnel connection failed for \(target): \(error.localizedDescription) (Domain: \(error.domain), Code: \(error.code), Raw: \(String(describing: error)))"
}

private func tunnelConnectionAlertMessage(for error: NSError) -> String {
    let targetIP = DeviceConnectionContext.targetIPAddress
    let rawMessage = error.localizedDescription
    let lowercasedMessage = rawMessage.lowercased()

    let likelyCause: String
    let recoverySteps: [String]

    if error.code == 48 || lowercasedMessage.contains("address already in use") || lowercasedMessage.contains("port already in use") {
        likelyCause = "A port needed for the tunnel is already in use."
        recoverySteps = [
            "Close other JIT, debugging, proxy, or VPN apps that may be using the tunnel.",
            "Disconnect and reconnect LocalDevVPN.",
            "Restart Wander, then try again.",
            "If it keeps happening, reboot the device to clear the stuck port."
        ]
    } else if error.code == 54 || lowercasedMessage.contains("connection reset") {
        // ECONNRESET here is NOT a network fault, and saying it is has cost real support hours.
        // The daemon ACCEPTED the TCP connection, read our opening request, and only THEN sent a RST
        // — a decision made after accept(), i.e. a POLICY rejection (see RpDialDiagnosis
        // `looksLikeSourceAddressRejection` and RpPairingHandshakeProbe `.resetAfterRequest`).
        // A route/VPN problem cannot produce that shape; it fails at connect, not after the request.
        //
        // The two things the device rejects us over are Developer Mode being OFF and pairing
        // material it will not accept. Developer Mode leads because it is the common case AND
        // because the checklist cannot detect it: `checkDeveloperMode()` asks the device THROUGH the
        // tunnel, so a device that refuses the tunnel also refuses the question — the row reads
        // "Can't check yet" and the user is never told the real cause. Leading with LocalDevVPN here
        // sent people down a Wi-Fi/IP rabbit hole for a setting three taps away in Settings.
        // MEASURED CAUSE (user report, build 153, iOS 26.5.2): the two tunnel addresses had been
        // collapsed onto ONE. The RPPairing probe showed `10.7.0.1:49152 -> RESET, SOURCE 10.7.0.1`
        // — dialling the target FROM the target, because LocalDevVPN's Device IP had been set to
        // 10.7.0.1 as well. remotepairingd refuses a device-owned source, so that configuration can
        // never connect; it is loopback wearing a tunnel's clothes.
        //
        // THE OLD COPY HERE CAUSED THAT. It said "make sure LocalDevVPN is using the default
        // 10.7.0.1 address" — naming ONE address when there are two, and naming the one that must
        // NOT be the interface. Users dutifully set Device IP to 10.7.0.1 and locked themselves out
        // permanently; one wrote in saying he had changed both "to match". Always name both, and
        // always say they must differ.
        likelyCause = "Your device refused the developer connection. The usual cause is LocalDevVPN's two addresses being set to the same value — they must be different."
        recoverySteps = [
            "In LocalDevVPN, set Device IP to \(DeviceConnectionContext.defaultDeviceIPAddress) and Tunnel IP to \(DeviceConnectionContext.defaultTargetIPAddress). They must NOT be the same — Wander dials the Tunnel IP, so if the interface also owns it, your device is dialling itself and refuses the connection.",
            "Or just open Wander → Settings → Tunnel IP → Reset to defaults, then restart the tunnel, and make LocalDevVPN match those two values.",
            "Reconnect LocalDevVPN, then try again.",
            "Still failing? Turn ON Settings → Privacy & Security → Developer Mode and restart your iPhone. (No Developer Mode row? It only appears after a developer-signed app has asked for it.)",
            "Still failing after that? Select a fresh pairing file.",
            "No Wi-Fi? Turn on Airplane Mode, then connect LocalDevVPN (the loopback tunnel works with no network)."
        ]
    } else if error.code == -18 || lowercasedMessage.contains("parse target ip") {
        likelyCause = "The configured target IP address is not valid."
        recoverySteps = [
            "Open Settings and check the target IP address.",
            "Use the default \(DeviceConnectionContext.defaultTargetIPAddress)."
        ]
    } else if lowercasedMessage.contains("timed out") || lowercasedMessage.contains("timeout") {
        likelyCause = "The app could not reach the device before the connection timed out."
        recoverySteps = [
            "Confirm Wi-Fi and LocalDevVPN are both connected.",
            "Wake and unlock the target device.",
            "Confirm LocalDevVPN is exposing the device at \(targetIP)."
        ]
    } else if lowercasedMessage.contains("network is unreachable") || lowercasedMessage.contains("no route") {
        likelyCause = "The VPN route to the device is not available."
        recoverySteps = [
            "Disconnect and reconnect LocalDevVPN.",
            "Confirm iOS shows the VPN indicator.",
            "On Wi-Fi, switch it off and on. No Wi-Fi? Turn on Airplane Mode, then connect LocalDevVPN — the loopback tunnel needs no network."
        ]
    } else {
        likelyCause = "The tunnel could not be created."
        recoverySteps = [
            "Confirm Wi-Fi and LocalDevVPN are connected — or, with no Wi-Fi, turn on Airplane Mode then connect LocalDevVPN.",
            "Wake and unlock the target device.",
            "Reconnect LocalDevVPN, then try again."
        ]
    }

    let steps = recoverySteps.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    return """
    \(likelyCause)

    Target: \(targetIP):49152
    Expected LocalDevVPN IP: \(DeviceConnectionContext.defaultTargetIPAddress)

    Try this:
    \(steps)

    Technical details:
    Code \(error.code): \(rawMessage)
    """
}

extension TunnelManager {
    /// The interface name that already owns `target`, or nil when nothing does.
    ///
    /// Compares raw bytes rather than strings so "10.7.0.1" and "010.007.000.001" cannot disagree,
    /// and skips DOWN interfaces — a stale address on an interface that is not up cannot be the
    /// source the kernel picks.
    static func targetIsOwnAddress(_ target: String) -> String? {
        guard let parsed = WiFiSubnet.parseAddress(target) else { return nil }
        for iface in WiFiSubnet.allAddresses() {
            guard iface.family == parsed.family,
                  iface.flags & UInt32(IFF_UP) != 0,
                  iface.addressBytes == parsed.bytes else { continue }
            return iface.name
        }
        return nil
    }
}
