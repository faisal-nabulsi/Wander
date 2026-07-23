//
//  MainTabView.swift
//  Wander
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import Foundation

private enum ExternalLocationAction: Identifiable {
    case simulate(URL, Double, Double)
    case clear

    var id: String {
        switch self {
        case .simulate(let url, _, _):
            return "simulate-\(url.absoluteString)"
        case .clear:
            return "clear-location"
        }
    }

    var title: String {
        switch self {
        case .simulate:
            return "Simulate Location?"
        case .clear:
            return "Clear Location?"
        }
    }

    var message: String {
        switch self {
        case .simulate(_, let latitude, let longitude):
            return String(format: "An external link wants to set the simulated location to %.6f, %.6f.", latitude, longitude)
        case .clear:
            return "An external link wants to clear the simulated location."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .simulate:
            return "Set Location"
        case .clear:
            return "Clear Location"
        }
    }
}

/// The single, mutually-exclusive plain alert currently on screen. SwiftUI presents only one
/// `.alert` at a time, so when two used to arm together (e.g. a snap-back landing while the cellular
/// tip is up) one was silently dropped. We funnel every plain alert through ONE `.alert(item:)`
/// driven by this enum, with a priority order (see `ActiveAlert.priority`), and re-present the next
/// still-armed alert when the current one dismisses — so nothing is lost, they queue instead.
///
/// The external-location request stays on its own `.confirmationDialog` (different control style).
private enum ActiveAlert: Int, Identifiable {
    // Ordered high→low priority. 2FA is mid-operation + time-sensitive; the sign-in-needed alert is a
    // direct response to a tap; snap-back / resume are recovery; the cellular tip is pure coaching.
    case twoFactor
    case appleSignIn
    case snapBack
    case resume
    case cellularTip

    var id: Int { rawValue }
    /// Lower rawValue == higher priority (declaration order above).
    var priority: Int { rawValue }
}

struct MainTabView: View {
    @AppStorage("primaryTabSelection") private var selection: String = AppFeature.location.id
    // The floating red "panic" stop button can be hidden from Settings → Safety. Defaults on so
    // existing users keep the always-available revert-to-real-GPS control.
    @AppStorage("panicButtonEnabled") private var panicButtonEnabled = true
    // What's New: the last build whose changelog we've shown, so the card auto-pops exactly once
    // after each update — and NOT on a fresh install (seeded silently the first time).
    @AppStorage("lastWhatsNewBuild") private var lastWhatsNewBuild = 0
    @State private var showWhatsNew = false
    @State private var detachedFeature: AppFeature?
    @State private var didSetInitialHome = false
    @State private var pendingLocationAction: ExternalLocationAction?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openExternalURL

    @ObservedObject private var setupChecker = SetupChecker.shared
    @State private var showSetup = false
    @State private var didRunSetupCheck = false

    @ObservedObject private var gate = RemoteGate.shared
    // Apple-ID account singleton — observed so the OTA re-sign's 2FA prompt can surface from the
    // update banner and launch-time auto-install (not just from Settings/login). Without this,
    // tapping "Update ready" asks Apple for a 2FA code with nowhere on screen to enter it.
    @ObservedObject private var wanderAccount = WanderAccount.shared
    @State private var twoFactorCode = ""
    @State private var showAppleSignInNeeded = false

    // Single-slot presentation for all mutually-exclusive plain alerts (see `ActiveAlert`). The
    // per-alert source flags below still own the actual state (2FA continuations, resume target,
    // snap-back coordinate, cellular latch); this just decides which one is on screen right now so
    // two never fight to present and drop one.
    @State private var activeAlert: ActiveAlert?
    @ObservedObject private var license = License.shared
    @ObservedObject private var session = SimulationSession.shared
    @ObservedObject private var updater = WanderUpdater.shared
    @ObservedObject private var tunnel = WanderTunnel.shared
    @State private var bannerVisible = false
    @State private var bannerHideWork: DispatchWorkItem?

    // Panic button confirmation toast.
    @State private var panicToastVisible = false
    @State private var panicToastHideWork: DispatchWorkItem?

    // Reboot-aware recovery: a spoof session that ended WITHOUT a clean Stop (app/tunnel died or the
    // phone rebooted mid-session). Offered as a one-tap resume at launch — NOT resumed automatically.
    @State private var pendingResume: SimulationSession.ResumeTarget?
    @State private var didCheckPendingResume = false
    // Gentle in-session snap-back recovery — shown ONLY after SnapBackWatcher detects a real
    // bounce-back (never proactively).
    @ObservedObject private var snapBack = SimulationSession.shared.snapBack
    // Tunnel/DDI heartbeat — drives the health chip + best-effort self-heal + memory nudge.
    @ObservedObject private var tunnelHealth = TunnelHealthMonitor.shared

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(AppFeature.mainTabs) { feature in
                    feature.destination
                        .tabItem { Label(feature.title, systemImage: feature.systemImage) }
                        .tag(feature.id)
                }
            }
            .onAppear {
                ensureSelectionIsValid()
                if !didSetInitialHome {
                    selection = AppFeature.location.id
                    didSetInitialHome = true
                }
                if !didRunSetupCheck {
                    didRunSetupCheck = true
                    setupChecker.check()
                }
                gate.refresh()
                maybeShowWhatsNew()
                // Reboot-aware recovery: if the last run ended without a clean Stop (app/tunnel death
                // or a reboot mid-session), offer a one-tap resume. Checked once per launch; never
                // auto-resumes. Skipped if a session is somehow already active.
                if !didCheckPendingResume {
                    didCheckPendingResume = true
                    if !session.isActive {
                        pendingResume = session.pendingResumeTarget()
                    }
                }
                // Present whatever alert is armed at launch (e.g. a pending reboot-resume) through the
                // single-slot queue. onChange handlers cover every change after this.
                syncActiveAlert()
            }
            .onChange(of: setupChecker.hasRunOnce) { _, ran in
                // After the first launch check, nudge the setup sheet only if something's missing.
                if ran && !setupChecker.allReady { showSetup = true }
            }
            .sheet(isPresented: $showSetup) {
                SetupChecklistView()
            }
            .sheet(isPresented: $showWhatsNew) {
                WhatsNewView()
            }
            .fullScreenCover(isPresented: Binding(get: { gate.locked && !license.isLicensed }, set: { _ in })) {
                PaywallView()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    SimulationSession.shared.rescheduleIfActive()
                    gate.refresh()
                    License.shared.refresh()   // re-check so an expired subscription re-locks
                    if session.isActive { flashBanner() }
                }
            }
            .tint(Color(red: 0.094, green: 0.373, blue: 0.647))   // Wander brand blue
            .onOpenURL { url in
                handleURL(url)
            }
            .confirmationDialog(
                pendingLocationAction?.title ?? "External Location Request",
                isPresented: Binding(
                    get: { pendingLocationAction != nil },
                    set: { isPresented in
                        if !isPresented {
                            pendingLocationAction = nil
                        }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingLocationAction
            ) { action in
                Button(action.confirmationTitle, role: .destructive) {
                    performLocationAction(action)
                    pendingLocationAction = nil
                }
                Button(L("action.cancel", fallback: "Cancel"), role: .cancel) {
                    pendingLocationAction = nil
                }
            } message: { action in
                Text(action.message)
            }
            .sheet(item: $detachedFeature) { feature in
                NavigationStack {
                    feature.destination
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L("action.close", fallback: "Close")) {
                                    detachedFeature = nil
                                }
                            }
                        }
                }
            }
            // Hidden while the low-memory nudge is up (both are top banners) so they don't stack.
            .overlay(alignment: .top) { if !tunnelHealth.memoryPressureWarning { spoofingBanner } }
            .overlay(alignment: .bottomTrailing) { if panicButtonEnabled { panicButton } }
            .overlay(alignment: .top) { panicToast }
            .overlay(alignment: .top) { updateBanner }
            // Persistent soft-ban countdown chip — guidance only, visible across every tab while a
            // cooldown runs, sitting just above the tab bar so it never covers the map controls.
            .overlay(alignment: .bottom) {
                CooldownGuardView()
                    .padding(.bottom, 62)
            }
            // Persistent tunnel heartbeat chip — placed bottom-LEADING (opposite the panic button on
            // bottom-trailing, and clear of the bottom-CENTER cooldown chip) so the three never stack.
            .overlay(alignment: .bottomLeading) {
                TunnelHealthChip()
                    .padding(.leading, 16)
                    .padding(.bottom, 66)
            }
            // Non-blocking "low memory may drop the tunnel" nudge while spoofing.
            .overlay(alignment: .top) { TunnelMemoryWarningBanner() }
            .animation(.easeInOut(duration: 0.25), value: session.cooldownActive)
            .animation(.easeInOut(duration: 0.25), value: bannerVisible)
            .animation(.easeInOut(duration: 0.25), value: panicToastVisible)
            .animation(.easeInOut(duration: 0.25), value: updater.available != nil)
            .animation(.easeInOut(duration: 0.25), value: session.isActive)
            .animation(.easeInOut(duration: 0.25), value: tunnelHealth.state)
            .animation(.easeInOut(duration: 0.25), value: tunnelHealth.memoryPressureWarning)
            .onChange(of: snapBack.didBounceBack) { _, bounced in
                // The opp-5 snap-back watcher just detected a real bounce-back. That's a strong signal
                // the tunnel dropped, so kick a best-effort reconnect alongside the recovery prompt.
                // Honest: this only TRIES — it never claims to have fixed it.
                if bounced { tunnelHealth.attemptReconnectNow() }
            }
            .onChange(of: session.isActive) { _, active in
                if active { flashBanner() } else { withAnimation { bannerVisible = false } }
            }
            .onChange(of: tunnel.status) { _, status in
                // The tunnel is usually still connecting at launch when the first auto-install
                // attempt runs; retry the silent install the moment it connects.
                if status == .connected {
                    // A silent auto-install re-sign runs at the root (no sheet), so claim the 2FA
                    // prompt for the root before it can raise one — but NOT while an interactive 2FA
                    // prompt is already open, or reassigning the presenter would dismiss it mid-entry
                    // (the "vanishing 2FA prompt" class). Skip both the claim and the install then.
                    if !wanderAccount.awaiting2FA {
                        wanderAccount.twoFactorPresenter = .system
                        Task { await WanderUpdater.shared.autoInstallIfAvailable() }
                    }
                }
            }
            .onChange(of: updater.latestManifest?.build) { _, _ in
                maybeShowWhatsNew()
            }
            .modifier(consolidatedAlerts)
        }
    }

    /// Bundles the single consolidated plain-alert presentation (see `ActiveAlert`) plus the source
    /// flags that feed it. Extracted from `body` into its own expression so the big modifier chain
    /// type-checks in reasonable time. Each alert's exact copy + actions is preserved; on dismiss the
    /// current one clears its own source flag and `syncActiveAlert` re-presents the next still-armed
    /// alert (queueing, never clobbering) so two arming together no longer drops one.
    private var consolidatedAlerts: some ViewModifier {
        ConsolidatedAlertsModifier(
            // Single consolidated presentation. The item binding hides the 2FA case (SwiftUI's `Alert`
            // value type can't host a TextField), which the dedicated 2FA `.alert(isPresented:)` handles.
            itemBinding: consolidatedAlertBinding,
            alertBuilder: { consolidatedAlert(for: $0) },
            twoFactorBinding: Binding(
                get: { wanderAccount.twoFactorPrompt(for: .system).wrappedValue && activeAlert == .twoFactor },
                set: { presented in
                    if !presented {
                        wanderAccount.twoFactorPrompt(for: .system).wrappedValue = false
                        if activeAlert == .twoFactor { activeAlert = nil }
                        syncActiveAlert()
                    }
                }
            ),
            twoFactorCode: $twoFactorCode,
            onSubmitTwoFactor: {
                wanderAccount.submitTwoFactorCode(twoFactorCode.trimmingCharacters(in: .whitespaces))
                twoFactorCode = ""
                if activeAlert == .twoFactor { activeAlert = nil }
                syncActiveAlert()
            },
            onCancelTwoFactor: {
                wanderAccount.submitTwoFactorCode(nil)
                twoFactorCode = ""
                if activeAlert == .twoFactor { activeAlert = nil }
                syncActiveAlert()
            },
            // Re-pick the highest-priority still-armed alert whenever any source flag changes.
            cellularTip: session.showCellularTip,
            resumeSavedAt: pendingResume?.savedAt,
            snapBackBounced: snapBack.didBounceBack,
            awaiting2FA: wanderAccount.awaiting2FA,
            presenter: wanderAccount.twoFactorPresenter,
            appleSignIn: showAppleSignInNeeded,
            onSync: { syncActiveAlert() }
        )
    }

    /// Item binding for the single consolidated `.alert(item:)`. Hides the 2FA case (SwiftUI's `Alert`
    /// value type can't host a TextField, so `.twoFactor` is presented by the dedicated
    /// `.alert(isPresented:)`), keeping exactly ONE alert on screen for that case (never two).
    private var consolidatedAlertBinding: Binding<ActiveAlert?> {
        Binding(
            get: { activeAlert == .twoFactor ? nil : activeAlert },
            set: { newValue in
                // SwiftUI calls this with nil when the alert is dismissed. Don't force `activeAlert`
                // to nil here (a button action may have already cleared its source flag AND promoted
                // the next queued alert — clobbering it would drop that alert, the exact bug we fix).
                // Instead recompute from the live source flags: the dismissed alert's flag is now
                // clear, so syncActiveAlert() presents the next still-armed alert (or nil). The 2FA
                // case is mapped to nil by `get`, so ignore nils while it's the active alert.
                if newValue == nil && activeAlert != .twoFactor { syncActiveAlert() }
            }
        )
    }

    /// Build the `Alert` for the given case. Each alert's exact copy + actions is preserved from the
    /// old chained `.alert`s; each dismissal clears its own source flag and calls `syncActiveAlert`
    /// so the next still-armed alert is presented instead of being dropped.
    private func consolidatedAlert(for alert: ActiveAlert) -> Alert {
        switch alert {
        case .cellularTip:
            // One-time-per-session coaching tip: spoofing was just started while on cellular.
            // Advisory only — spoofing already started; this never blocks it. Shown at most once per
            // app session (see SimulationSession.didShowCellularTip); reappears next launch.
            return Alert(
                title: Text(L("tip.cellular.title", fallback: "Heads up: you're on cellular")),
                message: Text(L("tip.cellular.body", fallback: "On cellular your real area can still leak — even with a VPN. For the most believable spoof, connect to Wi-Fi or turn on Airplane Mode.")),
                dismissButton: .cancel(Text(L("action.ok", fallback: "Got it"))) {
                    session.showCellularTip = false
                    syncActiveAlert()
                }
            )

        case .resume:
            // Reboot-aware recovery: offer to resume a spoof that ended without a clean Stop. One tap
            // re-teleports via the NORMAL teleport path (re-mounts the tunnel) — never automatic.
            let coord = pendingResume?.coordinate
            let body = coord.map {
                String(format: L("resume.body",
                                 fallback: "Wander stopped without a clean Stop last time — a reboot or the app closing clears the spoof. Resume at %.4f, %.4f?"),
                        $0.latitude, $0.longitude)
            } ?? ""
            return Alert(
                title: Text(L("resume.title", fallback: "Resume your spoof?")),
                message: Text(body),
                primaryButton: .default(Text(L("resume.action", fallback: "Resume"))) {
                    if let coord { session.resume(to: coord) }
                    pendingResume = nil
                    syncActiveAlert()
                },
                secondaryButton: .cancel(Text(L("resume.dismiss", fallback: "Not now"))) {
                    session.dismissPendingResume()
                    pendingResume = nil
                    syncActiveAlert()
                }
            )

        case .snapBack:
            // Gentle snap-back recovery — shown ONLY after an ACTUAL detected bounce-back (the device's
            // real location drifted away from the spoofed target while spoofing). Offers a one-tap
            // re-teleport plus a community-reported (not guaranteed) reboot suggestion.
            let target = session.lastTeleportCoordinate
            let message = Text(L("snapback.body",
                                 fallback: "Your device pulled back toward your real location. Tap Re-teleport to jump back.\n\nCommunity-reported for iOS 26 (not guaranteed): if it keeps snapping back, restart your iPhone — iOS 26 holds a cached location that toggles no longer clear. Wander will put you back here when you reopen it."))
            let cancel = Alert.Button.cancel(Text(L("action.ok", fallback: "OK"))) {
                snapBack.reset()
                syncActiveAlert()
            }
            guard let target else {
                return Alert(
                    title: Text(L("snapback.title", fallback: "Location snapped back")),
                    message: message,
                    dismissButton: cancel
                )
            }
            return Alert(
                title: Text(L("snapback.title", fallback: "Location snapped back")),
                message: message,
                primaryButton: .default(Text(L("snapback.reteleport", fallback: "Re-teleport"))) {
                    // Only re-teleport when the Map teleport HOLD owns the stream. A movement mode
                    // (walk/route/itinerary) holds suppressResends=true and self-heals via its own inject
                    // loop — routing `resume` (→ .teleportToRequested → startResendLoop, which flips
                    // suppressResends=false) through it while it's still writing would create a SECOND
                    // writer and re-trigger Error 12. Movement modes disarm this watcher on start, so this
                    // guard is just a belt-and-suspenders against a race.
                    if !LocationSimulationCommandQueue.suppressResends {
                        session.resume(to: target)
                    } else {
                        snapBack.reset()
                    }
                    syncActiveAlert()
                },
                secondaryButton: cancel
            )

        case .appleSignIn:
            return Alert(
                title: Text(L("update.needs_apple_id.title", fallback: "Sign in to install")),
                message: Text(L("update.needs_apple_id.body", fallback: "To install the update, first sign in to your Apple ID in More → Settings → Sign in to Apple ID, then tap the update again.")),
                dismissButton: .cancel(Text(L("action.ok", fallback: "OK"))) {
                    showAppleSignInNeeded = false
                    syncActiveAlert()
                }
            )

        case .twoFactor:
            // Unreachable: `.twoFactor` is presented by the dedicated `.alert(isPresented:)` (it needs a
            // TextField, which `Alert` can't hold) and is mapped to nil by `consolidatedAlertBinding`.
            return Alert(title: Text(""))
        }
    }

    /// Pick the highest-priority currently-armed plain alert and route it through the single
    /// `.alert(item:)` slot. Called whenever any source flag changes and after each dismissal so a
    /// second alert that armed while the first was up gets presented next instead of being dropped.
    /// Never demotes: if the alert on screen is still armed we leave it be until it dismisses.
    private func syncActiveAlert() {
        // Build the set of alerts that WANT to show, from their real source flags.
        var armed: [ActiveAlert] = []
        if wanderAccount.awaiting2FA && wanderAccount.twoFactorPresenter == .system { armed.append(.twoFactor) }
        if showAppleSignInNeeded { armed.append(.appleSignIn) }
        if snapBack.didBounceBack { armed.append(.snapBack) }
        if pendingResume != nil { armed.append(.resume) }
        if session.showCellularTip { armed.append(.cellularTip) }

        // If the one on screen is still armed, don't disturb it — let it finish.
        if let current = activeAlert, armed.contains(current) { return }

        // Highest-priority armed alert (lowest priority value), or nil if none.
        let next = armed.min(by: { $0.priority < $1.priority })

        // Swapping one alert straight for another in the SAME runloop turn (the just-dismissed one →
        // the next queued one) can make SwiftUI drop the new presentation. Clear first, then present
        // the next on the following turn so the queued alert reliably shows.
        if activeAlert != nil, next != nil, activeAlert != next {
            activeAlert = nil
            DispatchQueue.main.async { [self] in
                // Re-check on the next turn in case flags changed meanwhile.
                if activeAlert == nil { syncActiveAlert() }
            }
            return
        }
        activeAlert = next
    }

    /// Always-available safety control (FREE): instantly stops ALL spoofing and reverts
    /// the device to its real GPS, from anywhere in the app. Reuses the global stop path.
    private var panicButton: some View {
        Button(role: .destructive) {
            panicStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.red, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        }
        .accessibilityLabel(L("panic.accessibility", fallback: "Panic — stop all spoofing"))
        .padding(.trailing, 18)
        .padding(.bottom, 66)   // sit above the tab bar
    }

    /// Brief confirmation shown after a panic stop.
    @ViewBuilder private var panicToast: some View {
        if panicToastVisible {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                Text(localized: "toast.stopped_real_gps", fallback: "Stopped — real GPS restored")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.red, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.top, 52)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Reverts to real GPS immediately and flashes a confirmation. Fail-safe: even if no
    /// simulation is running, stopAll() is a harmless clear.
    private func panicStop() {
        SimulationSession.shared.stopAll()
        panicToastHideWork?.cancel()
        withAnimation { panicToastVisible = true }
        let work = DispatchWorkItem { withAnimation { panicToastVisible = false } }
        panicToastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Show the "keep Wander open" pill briefly, then fade it out so it never sits on the
    /// map controls. Re-flashed whenever spoofing starts or the app returns to the foreground.
    private func flashBanner() {
        bannerHideWork?.cancel()
        withAnimation { bannerVisible = true }
        let work = DispatchWorkItem { withAnimation { bannerVisible = false } }
        bannerHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    @ViewBuilder private var spoofingBanner: some View {
        if session.isActive && bannerVisible {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.caption)
                Text(localized: "banner.spoofing_active", fallback: "Spoofing active — keep Wander open")
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(red: 0.094, green: 0.373, blue: 0.647), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.horizontal, 24)
            .padding(.top, 52)   // clear the inline nav bar; sits over the empty top of the map
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Global, tappable "Update ready" banner — surfaces an available OTA update from ANYWHERE
    /// (not just Settings), so the user doesn't have to dig into Settings to update. Hidden while
    /// spoofing (the spoof banner owns the top) and during the panic toast.
    @ViewBuilder private var updateBanner: some View {
        if updater.available != nil && !session.isActive && !panicToastVisible {
            Button {
                installUpdateFromBanner()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: updater.isBusy ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                        .font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(updater.isBusy ? "Updating Wander…"
                                            : L("update.banner", fallback: "Update ready — tap to install"))
                            .font(.caption.weight(.semibold))
                        if updater.isBusy && !updater.status.isEmpty {
                            Text(updater.status).font(.caption2).opacity(0.9).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if !updater.isBusy {
                        Image(systemName: "chevron.right").font(.caption2).opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(red: 0.094, green: 0.373, blue: 0.647), in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(updater.isBusy)
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Install the pending update from the banner. Reuses the exact pipeline the Settings button
    /// uses; requires the Apple ID to be signed in (Settings) — otherwise it says so.
    private func installUpdateFromBanner() {
        // The re-sign runs here on the root tab (no sheet up), so the root owns the 2FA prompt.
        wanderAccount.twoFactorPresenter = .system
        Task {
            guard WanderAccount.shared.isSignedIn else {
                // Before, this only set the tiny banner subtitle, so tapping the "Update ready" banner
                // felt like nothing happened. Surface a clear alert telling the user to sign in first.
                showAppleSignInNeeded = true
                return
            }
            do { try await updater.installUpdate() }
            catch { updater.status = "❌ \((error as NSError).localizedDescription)" }
        }
    }

    /// Present the "What's New" changelog once per new build. On a FRESH install (lastWhatsNewBuild
    /// == 0) seed silently so the very first launch doesn't pop it; only real UPDATES pop it.
    private func maybeShowWhatsNew() {
        guard updater.currentBuildNotes != nil else { return }
        if lastWhatsNewBuild == 0 {
            lastWhatsNewBuild = updater.currentBuild
        } else if lastWhatsNewBuild < updater.currentBuild {
            lastWhatsNewBuild = updater.currentBuild
            showWhatsNew = true
        }
    }

    private func ensureSelectionIsValid() {
        let ids = AppFeature.mainTabs.map { $0.id }
        if ids.contains(selection) {
            return
        }
        selection = AppFeature.location.id
    }

    private func handleURL(_ url: URL) {
        guard let host = url.host()?.lowercased() else { return }

        switch host {
        case "simulate-location", "set-location":
            confirmSimulatedLocation(from: url)
        case "location", "location-simulation":
            if coordinate(from: url) == nil {
                openFeature(id: AppFeature.location.id)
            } else {
                confirmSimulatedLocation(from: url)
            }
        case "clear-location", "stop-location":
            pendingLocationAction = .clear
        // wander:// deep links for Shortcuts/automations. teleport/reset run DIRECTLY (no confirm) —
        // the user built the shortcut on purpose, and one-tap is the whole point. In gs-loc mode
        // simulate/clear route through GslocMode (proxy push), so these are PoGo-safe.
        case "teleport":
            simulateLocation(from: url)
        case "reset":
            clearSimulatedLocation()
        case "connect":
            if let u = URL(string: "shadowrocket://connect") { openExternalURL(u) }
        case "open":
            break   // opening the app is the whole effect
        default:
            break
        }
    }

    private func openFeature(id: String) {
        guard let feature = AppFeature(rawValue: id) else {
            return
        }

        if AppFeature.mainTabs.contains(feature) {
            selection = feature.id
        } else {
            detachedFeature = feature
        }
    }

    private func confirmSimulatedLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "Invalid Location URL",
                message: "Use stikdebug://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "Invalid Coordinates",
                message: "Latitude must be between -90 and 90. Longitude must be between -180 and 180.",
                showOk: true
            )
            return
        }

        pendingLocationAction = .simulate(url, coordinate.latitude, coordinate.longitude)
    }

    private func performLocationAction(_ action: ExternalLocationAction) {
        switch action {
        case .simulate(let url, _, _):
            simulateLocation(from: url)
        case .clear:
            clearSimulatedLocation()
        }
    }

    private func simulateLocation(from url: URL) {
        guard let coordinate = coordinate(from: url) else {
            showAlert(
                title: "Invalid Location URL",
                message: "Use stikdebug://simulate-location?lat=37.3349&lon=-122.0090",
                showOk: true
            )
            return
        }

        guard coordinateIsValid(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            showAlert(
                title: "Invalid Coordinates",
                message: "Latitude must be between -90 and 90. Longitude must be between -180 and 180.",
                showOk: true
            )
            return
        }

        let pairingFile = PairingFileStore.prepareURL()
        guard FileManager.default.fileExists(atPath: pairingFile.path) || GslocMode.enabled else {
            showAlert(
                title: "Pairing File Required",
                message: "Import a pairing file before simulating location from a URL.",
                showOk: true
            )
            return
        }

        LocationSimulationCommandQueue.shared.async {
            let code = simulate_location(
                DeviceConnectionContext.targetIPAddress,
                coordinate.latitude,
                coordinate.longitude,
                pairingFile.path
            )

            DispatchQueue.main.async {
                if code == 0 {
                    BackgroundLocationManager.shared.requestStart()
                    LogManager.shared.addInfoLog(
                        String(format: "Simulated location from URL: %.6f, %.6f", coordinate.latitude, coordinate.longitude)
                    )
                } else {
                    showAlert(
                        title: "Location Simulation Failed",
                        message: "Couldn't simulate location from URL (error \(code)). Make sure LocalDevVPN is connected and Developer Mode is ON (Settings → Privacy & Security → Developer Mode). On cellular with no Wi‑Fi? Connect LocalDevVPN first, then turn Airplane Mode ON (you can turn it back OFF after) — that usually fixes it.",
                        showOk: true
                    )
                }
            }
        }
    }

    private func clearSimulatedLocation() {
        LocationSimulationCommandQueue.shared.async {
            let code = clear_simulated_location()
            DispatchQueue.main.async {
                if code == 0 {
                    BackgroundLocationManager.shared.requestStop()
                    LogManager.shared.addInfoLog("Cleared simulated location from URL")
                } else {
                    showAlert(
                        title: "Clear Location Failed",
                        message: "Could not clear simulated location from URL (error \(code)).",
                        showOk: true
                    )
                }
            }
        }
    }

    private func coordinate(from url: URL) -> (latitude: Double, longitude: Double)? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func queryValue(_ names: [String]) -> String? {
            for name in names {
                if let value = queryItems.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value {
                    return value
                }
            }
            return nil
        }

        if let latitudeText = queryValue(["lat", "latitude"]),
           let longitudeText = queryValue(["lon", "lng", "long", "longitude"]),
           let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
           let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (latitude, longitude)
        }

        let coordinateText = queryValue(["coordinate", "coordinates", "coords", "q", "ll"])
            ?? components?.path
            ?? ""
        let values = numbers(in: coordinateText)
        guard values.count >= 2 else { return nil }
        return (values[0], values[1])
    }

    private func coordinateIsValid(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }

    private func numbers(in text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}

/// Self-contained modifier that applies the consolidated plain-alert presentation. Everything it
/// needs is threaded in as plain values / bindings / closures, so it type-checks independently of
/// `MainTabView.body` (splitting the large chain that otherwise blows the type-checker's budget).
/// It carries NO presentation logic of its own — the `Alert`s are built by `MainTabView` and the
/// dismissals route back through the `onSync` closure (`syncActiveAlert`).
private struct ConsolidatedAlertsModifier: ViewModifier {
    let itemBinding: Binding<ActiveAlert?>
    let alertBuilder: (ActiveAlert) -> Alert
    let twoFactorBinding: Binding<Bool>
    let twoFactorCode: Binding<String>
    let onSubmitTwoFactor: () -> Void
    let onCancelTwoFactor: () -> Void

    // Source-flag snapshots: any change re-picks the highest-priority still-armed alert via onSync.
    let cellularTip: Bool
    let resumeSavedAt: Date?
    let snapBackBounced: Bool
    let awaiting2FA: Bool
    let presenter: WanderAccount.TwoFactorPresenter
    let appleSignIn: Bool
    let onSync: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(item: itemBinding) { alert in alertBuilder(alert) }
            // The 2FA prompt needs a TextField, which SwiftUI's `Alert` value type can't hold, so it
            // stays a `.alert(isPresented:)` with a ViewBuilder. It's gated on BOTH the account's
            // per-context binding AND activeAlert == .twoFactor (folded into `twoFactorBinding`), so it
            // presents through the same single-slot queue and never overlaps another alert.
            .alert("Two-Factor Code", isPresented: twoFactorBinding) {
                TextField("6-digit code", text: twoFactorCode)
                    .keyboardType(.numberPad)
                Button("Submit") { onSubmitTwoFactor() }
                Button("Cancel", role: .cancel) { onCancelTwoFactor() }
            } message: {
                Text("Enter the 6-digit code Apple sent to your trusted device. No popup? Get it from Settings → your name → Sign-In & Security → Get Verification Code.")
            }
            // Feed the single-slot presenter from each alert's own source flag.
            .onChange(of: cellularTip) { _, _ in onSync() }
            .onChange(of: resumeSavedAt) { _, _ in onSync() }
            .onChange(of: snapBackBounced) { _, _ in onSync() }
            .onChange(of: awaiting2FA) { _, _ in onSync() }
            .onChange(of: presenter) { _, _ in onSync() }
            .onChange(of: appleSignIn) { _, _ in onSync() }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
