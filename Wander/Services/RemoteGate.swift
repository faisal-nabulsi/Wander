//
//  RemoteGate.swift
//  Wander
//
//  Remote kill-switch. The app fetches a small config.json the developer controls;
//  when `locked` is true, Wander shows the paywall and blocks spoofing for everyone
//  who doesn't hold a valid license — including already-installed copies. Dormant
//  (locked=false) until the developer flips it.
//

import Foundation

@MainActor
final class RemoteGate: ObservableObject {
    static let shared = RemoteGate()

    @Published private(set) var locked: Bool
    @Published private(set) var message: String

    private static let configURL = URL(string: "https://raw.githubusercontent.com/faisal-nabulsi/Wander/main/config.json")!
    private static let lockedKey = "wander.gate.locked"
    private static let msgKey = "wander.gate.message"

    private init() {
        // Start from the last value we saw, so the lock survives offline launches.
        locked = UserDefaults.standard.bool(forKey: Self.lockedKey)
        message = UserDefaults.standard.string(forKey: Self.msgKey) ?? ""
    }

    func refresh() {
        var req = URLRequest(url: Self.configURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data, let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return }
            DispatchQueue.main.async {
                self.locked = cfg.locked
                self.message = cfg.message ?? ""
                UserDefaults.standard.set(cfg.locked, forKey: Self.lockedKey)
                UserDefaults.standard.set(self.message, forKey: Self.msgKey)
            }
        }.resume()
    }

    private struct Config: Decodable {
        let locked: Bool
        let message: String?
    }
}
