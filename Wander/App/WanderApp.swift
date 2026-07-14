//
//  WanderApp.swift
//  Wander
//

import SwiftUI

@main
struct WanderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldAttemptTunnelReconnect = false
    // Transient (not persisted) so the welcome screen shows on every fresh launch.
    @State private var showWelcome = true

    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showWelcome {
                    WelcomeView { withAnimation { showWelcome = false } }
                } else {
                    MainTabView()
                }
            }
            .task {
                await MainActor.run { WanderAccount.shared.restoreSession() }
                // Restore the OPTIONAL Wander-account Pro state (Firebase). Touching the
                // singleton loads the cached isPro from the Keychain and kicks off a background
                // entitlement re-check; folds into License.isLicensed so the gates honor it.
                await MainActor.run { _ = WanderProAccount.shared }
                await WanderUpdater.shared.check()
                await downloadMissingDeveloperDiskImageFiles()
                // Auto self-refresh when the sideload signature is near expiry (signed in +
                // not already refreshing). Silently skips otherwise — see SelfRefreshService.
                await SelfRefreshService.shared.autoRefreshIfNearExpiry()
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            if shouldAttemptTunnelReconnect {
                shouldAttemptTunnelReconnect = false
                startTunnelInBackground(showErrorUI: false)
            }
        default:
            break
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
        } catch {
            await MainActor.run {
                showAlert(
                    title: "An Error has Occurred",
                    message: "[Download DDI Error]: \(error.localizedDescription)",
                    showOk: true
                )
            }
        }
    }
}
