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
                        try mgr.connection.startVPNTunnel(options: [
                            "TunnelDeviceIP": "10.7.0.0" as NSObject,
                            "TunnelFakeIP": "10.7.0.1" as NSObject,
                            "TunnelSubnetMask": "255.255.255.0" as NSObject,
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
