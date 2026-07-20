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
    // App-wide appearance override (System / Light / Dark), set in Settings.
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        AppBootstrapper.configure()
        // Install crash handlers ASAP so a crash anywhere after this is captured + auto-reported.
        CrashReporter.install()
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
            // Apply the user's appearance override at the root so it covers the
            // entire UI. `nil` follows the system setting.
            .preferredColorScheme(appearance.colorScheme)
            // Re-render the whole tree when the language changes so every view
            // that reads through L(...) picks up the new bundle immediately.
            .id(localization.currentLanguage)
            .task {
                // If we crashed last run, quietly ship that report to support now.
                CrashReporter.sendPendingIfAny()
                // Arm the in-app scheduler: turns on the keep-alive if any schedule is armed,
                // (re)schedules start-time notifications, and evaluates the current window.
                await MainActor.run { ScheduleManager.shared.startup() }
                await MainActor.run { WanderAccount.shared.restoreSession() }
                // Reboot-aware recovery: touch the session singleton at launch so its persisted
                // "was spoofing" state is ready. If the last run ended WITHOUT a clean Stop (the
                // app/tunnel died or the phone rebooted mid-session), MainTabView reads
                // `pendingResumeTarget()` on appear and offers a gentle one-tap resume — which
                // re-teleports via the EXISTING teleport path (never automatic, never a DDI remount).
                await MainActor.run { _ = SimulationSession.shared.pendingResumeTarget() }
                // Restore the OPTIONAL Wander-account Pro state (Firebase). Touching the
                // singleton loads the cached isPro from the Keychain and kicks off a background
                // entitlement re-check; folds into License.isLicensed so the gates honor it.
                await MainActor.run { _ = WanderProAccount.shared }
                // Register THIS install against the account's 5-device cap (server-enforced),
                // while online. Fully fail-safe — on any error it keeps the cached registration
                // so a paying user is never locked out offline. No-ops when not signed in.
                await WanderDeviceActivation.shared.activate()
                // OPT-IN, PRO-ONLY saved-places sync. No-ops unless the toggle is on, the user is
                // Pro, and a Wander account is signed in. Fully fail-safe (see SavedPlacesSync).
                await MainActor.run {
                    SavedPlacesSync.shared.syncIfEnabled()
                    SavedRoutesSync.shared.syncIfEnabled()
                }
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
            // Re-evaluate schedules the moment we return to the foreground so any window we
            // crossed while suspended is corrected immediately.
            ScheduleManager.shared.handleForeground()
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
