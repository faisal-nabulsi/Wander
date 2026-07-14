//
//  NetworkReachability.swift
//  Wander
//
//  A tiny, app-wide connectivity flag backed by NWPathMonitor. Purely cosmetic: it lets the UI
//  show a subtle, non-nagging "Offline" hint so the app's calm empty states (a hidden weather
//  card, a globe that can't load, an empty raids board) read as intentional rather than broken.
//
//  It NEVER gates or blocks anything — teleport, joystick, and routes stay fully usable offline.
//  Nothing in the app should branch behaviour on this; it only drives an optional indicator.
//

import Foundation
import Network

@MainActor
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// True once the monitor has seen a satisfied path. Starts `true` so we never flash an
    /// "Offline" hint during the brief moment before the first path update arrives.
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.wander.reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
            }
        }
        monitor.start(queue: queue)
    }
}
