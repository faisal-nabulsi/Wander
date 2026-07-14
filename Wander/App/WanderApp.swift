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
    // In-app language switcher. Injected at the root so a language change
    // republishes and re-renders the whole UI live (no relaunch).
    @StateObject private var localization = LocalizationManager.shared

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
            .environmentObject(localization)
            // Re-render the whole tree when the language changes so every view
            // that reads through L(...) picks up the new bundle immediately.
            .id(localization.currentLanguage)
            .task {
                await MainActor.run { WanderAccount.shared.restoreSession() }
                // Restore the OPTIONAL Wander-account Pro state (Firebase). Touching the
                // singleton loads the cached isPro from the Keychain and kicks off a background
                // entitlement re-check; folds into License.isLicensed so the gates honor it.
                await MainActor.run { _ = WanderProAccount.shared }
                // OPT-IN, PRO-ONLY saved-places sync. No-ops unless the toggle is on, the user is
                // Pro, and a Wander account is signed in. Fully fail-safe (see SavedPlacesSync).
                await MainActor.run { SavedPlacesSync.shared.syncIfEnabled() }
                await WanderUpdater.shared.check()
                // Auto-install a newer build the moment it's found — same pipeline as the
                // manual Settings button, no tap. Fires at most once per launch; falls back to
                // an in-app "Update ready — tap to install" prompt if it can't run unattended.
                await WanderUpdater.shared.autoInstallIfAvailable()
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
