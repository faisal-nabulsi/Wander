//
//  WanderTunnel.swift
//  Wander
//
//  App-side controller for Wander's bundled on-device tunnel (the TunnelProv
//  network extension). Configures + starts/stops an NETunnelProviderManager so
//  Wander no longer needs the separate LocalDevVPN app.
//
//  Tunnel design (from LocalDevVPN): device IP 10.7.0.0, fake IP 10.7.0.1.
//  Wander's engine already targets 10.7.0.1, so no change to the connection code.
//

import Foundation
import NetworkExtension

final class WanderTunnel: ObservableObject {
    static let shared = WanderTunnel()

    enum Status: String {
        case disconnected, connecting, connected, error
        var title: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .error: return "Error"
            }
        }
    }

    @Published var status: Status = .disconnected
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private var providerBundleId: String {
        (Bundle.main.bundleIdentifier ?? "com.stik.stikdebug") + ".TunnelProv"
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let conn = note.object as? NEVPNConnection,
                  conn == self.manager?.connection else { return }
            self.update(conn.status)
        }
        load()
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.lastError = msg; self.status = .error }
    }

    private func load() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self else { return }
            let mine = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleId
            }
            self.manager = mine
            if let s = mine?.connection.status { self.update(s) }
        }
    }

    func toggle() {
        (status == .connected || status == .connecting) ? stop() : start()
    }

    /// True when a tunnel interface exists that isn't ours — i.e. LocalDevVPN, Shadowrocket, or a real VPN
    /// is up. Used to keep auto-start from stealing iOS's single VPN slot out from under the user.
    ///
    /// utun0 always exists on iOS, so a bare "any utun" test is useless — it would report a VPN forever.
    /// Require a tunnel interface carrying an actual IPv4 address, which a live tunnel has and the idle
    /// system utun does not. Only consulted when OUR tunnel is not already connected/connecting, so a
    /// running Wander tunnel never blocks itself.
    static func foreignVPNInterfaceActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        var found = false
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = ptr.pointee.ifa_name else { continue }
            let name = String(cString: raw)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tap") else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (ptr.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            found = true
            break
        }
        return found
    }

    /// Bring the tunnel up if it isn't, and resolve only once it can actually carry traffic.
    ///
    /// WHY: nothing in the app restarted this tunnel if the VPN itself died — `TunnelHealthMonitor`
    /// re-asserted the last teleport but never touched `WanderTunnel`, so a dropped VPN left a silently
    /// dead session the user had to notice and fix by hand.
    ///
    /// Readiness is the endpoint probe, NOT a fixed sleep: `.connected` only means iOS started the
    /// provider, and injecting before the loopback route is installed fails. `isTunnelSimEndpointReachable()`
    /// is the already-shipped bounded TCP probe to ip:49152, which is exactly the thing that has to work.
    ///
    /// `.reasserting` is treated as UP on purpose. iOS reports it during a normal network change; calling
    /// start() then would bounce a tunnel that is about to recover and kill the live, connection-scoped
    /// DVT session with it — the bug class this app just spent a long night fixing.
    @discardableResult
    func ensureStarted(timeout: TimeInterval = 12) async -> Bool {
        // Opt-in only. start() sets isEnabled + saves, which takes iOS's single VPN slot away from
        // whatever the user actually chose (LocalDevVPN, Shadowrocket, a real VPN).
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel) else { return false }
        // gs-loc needs Shadowrocket to hold that slot; stealing it would break PoGo mode outright.
        guard !GslocMode.enabled else { return false }

        // Someone else's tunnel is already doing the job — leave it alone.
        //
        // iOS runs ONE VPN at a time, and start() sets isEnabled + saves, which DISCONNECTS whatever is
        // currently connected. If LocalDevVPN is up and carrying the loopback, starting ours would tear
        // down a working tunnel and take the spoof with it — strictly worse than doing nothing.
        if isTunnelSimEndpointReachable() { return true }

        // Even when the endpoint isn't answering, another VPN may be mid-handshake or briefly stalled
        // (exactly what a network transition looks like). Claiming the slot then would kill a tunnel that
        // was about to recover. Only start ours when no foreign tunnel interface is present at all.
        if Self.foreignVPNInterfaceActive(), status != .connected, status != .connecting {
            return false
        }

        if status != .connected && status != .connecting { start() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Fail fast on the free-sideload case rather than burning the whole timeout: the NE
            // entitlement is stripped there, so the tunnel can never come up and LocalDevVPN is the path.
            if status == .error { return false }
            if isTunnelSimEndpointReachable() { return true }
        }
        return false
    }

    func start() {
        DispatchQueue.main.async { self.lastError = nil }
        setStatus(.connecting)
        ensureManager { [weak self] mgr in
            guard let self else { return }
            guard let mgr else { self.fail("No VPN config (entitlement likely not granted at sign time)"); return }
            mgr.isEnabled = true
            mgr.saveToPreferences { err in
                if let err { self.fail("save: \(err.localizedDescription)"); return }
                mgr.loadFromPreferences { _ in
                    do {
                        // Configurable so the tunnel can move onto the phone's Wi-Fi subnet on iOS 26.4+
                        // (Apple drops the default 10.7.0.x loopback address there). Defaults preserve the
                        // pre-26.4 behavior. Note: TunnelProv's "TunnelDeviceIP" option = the interface IP
                        // (our tunnelInterfaceIP key), "TunnelFakeIP" = the peer Wander connects to (our
                        // targetDeviceIP key). See Wander/Views/TunnelIPSettingsView.swift.
                        let d = UserDefaults.standard
                        let interfaceIP = d.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
                        let fakeIP = DeviceConnectionContext.targetIPAddress
                        let mask = d.string(forKey: UserDefaults.Keys.tunnelSubnetMask) ?? "255.255.255.0"
                        try mgr.connection.startVPNTunnel(options: [
                            "TunnelDeviceIP": interfaceIP as NSObject,
                            "TunnelFakeIP": fakeIP as NSObject,
                            "TunnelSubnetMask": mask as NSObject,
                        ])
                    } catch {
                        self.fail("start: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func stop() {
        setStatus(.disconnected)
        manager?.connection.stopVPNTunnel()
    }

    private func ensureManager(_ completion: @escaping (NETunnelProviderManager?) -> Void) {
        if let m = manager { completion(m); return }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self else { completion(nil); return }
            if let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleId
            }) {
                self.manager = existing
                completion(existing)
                return
            }
            let m = NETunnelProviderManager()
            m.localizedDescription = "Wander Tunnel"
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleId
            proto.serverAddress = "Wander on-device tunnel"
            m.protocolConfiguration = proto
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err {
                    DispatchQueue.main.async { self.lastError = "config: \(err.localizedDescription)" }
                    completion(nil); return
                }
                self.manager = m
                completion(m)
            }
        }
    }

    private func update(_ s: NEVPNStatus) {
        switch s {
        case .connected: setStatus(.connected)
        case .connecting, .reasserting: setStatus(.connecting)
        case .disconnecting, .disconnected, .invalid: setStatus(.disconnected)
        @unknown default: setStatus(.error)
        }
    }
}
