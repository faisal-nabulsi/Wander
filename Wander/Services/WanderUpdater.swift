//
//  WanderUpdater.swift
//  Wander
//
//  In-app OTA updates over the self-refresh pipeline. The app checks a small manifest
//  (update.json) you publish; if a newer build exists it downloads that version's UNSIGNED
//  .ipa, re-signs it with the user's Apple ID (AltSign, same as self-refresh), and installs
//  it over the tunnel — so everyone on an old version updates themselves, no computer.
//
//  Requirements to install mirror self-refresh: signed in to an Apple ID + tunnel connected.
//

import Foundation
import AltSign

@MainActor
final class WanderUpdater: ObservableObject {
    static let shared = WanderUpdater()

    struct Manifest: Decodable {
        let build: Int
        let version: String
        let payloadURL: String
        let notes: String?
    }

    @Published private(set) var available: Manifest?
    @Published private(set) var isBusy = false
    @Published var status: String = ""

    private static let manifestURL = URL(string: "https://raw.githubusercontent.com/faisal-nabulsi/Wander/main/update.json")!

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Fetch the manifest; record whether a newer build than this one is published.
    func check() async {
        var req = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return   // no manifest / offline == no update
        }
        available = (m.build > currentBuild) ? m : nil
    }

    /// Download the new version's IPA, re-sign it with the user's Apple ID, and self-install
    /// it over the tunnel. The app is killed + replaced by the new build (same as self-refresh).
    func installUpdate() async throws {
        guard let m = available else { throw UpdateError.step("No update available.") }
        guard let url = URL(string: m.payloadURL) else { throw UpdateError.step("The update URL is invalid.") }
        isBusy = true
        defer { isBusy = false }

        let work = URL.documentsDirectory.appendingPathComponent("update-work", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        status = "Downloading v\(m.version)…"
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdateError.step("Download failed (HTTP \(http.statusCode)).")
        }
        let ipa = work.appendingPathComponent("update.ipa")
        try? FileManager.default.removeItem(at: ipa)
        try FileManager.default.moveItem(at: tmp, to: ipa)

        status = "Unpacking…"
        let appURL = try FileManager.default.unzipAppBundle(at: ipa, toDirectory: work)
        // Strip the inert TunnelProv.appex (paid-only NE) → simple single-app sign.
        try? FileManager.default.removeItem(at: appURL.appendingPathComponent("PlugIns"))

        status = "Signing with your Apple ID…"
        let bundleID = try await WanderAccount.shared.resignAppBundle(
            at: appURL,
            baseBundleID: "com.stik.stikdebug",
            progress: { [weak self] s in self?.status = s }
        )

        status = "Installing update over the tunnel…"
        try await Task.detached(priority: .userInitiated) {
            try JITEnableContext.shared.stageAndUpgradeAppBundle(atLocalPath: appURL.path, bundleID: bundleID)
        }.value
        status = "✅ Update installed — Wander will relaunch."
    }

    enum UpdateError: LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }
}
