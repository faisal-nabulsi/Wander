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
                await WanderUpdater.shared.check()
                await downloadMissingDeveloperDiskImageFiles()
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
