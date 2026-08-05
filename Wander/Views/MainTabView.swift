//
//  MainTabView.swift
//  Wander
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI
import Foundation
import CoreLocation
import MapKit
import UIKit

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
    // A share link (wander://share… / https://wanderspoofer.com/go…) that has been decoded but NOT
    // acted on. Import always stops here first: a link from a stranger silently moving someone's
    // location is unacceptable, so nothing happens until the user taps one of the buttons.
    @State private var pendingShareImport: WanderSharePayload?
    // Raised when a link asks for a Pro-only verb (route / itinerary) on a free install. Same
    // response the tabs give — the paywall, not a dead-end alert — because a link is another door
    // into the same feature, not a different product.
    @State private var showLinkPaywall = false
    // Read only to phrase an imported route's length in the unit the user already reads elsewhere.
    @AppStorage("useMph") private var useMph = false
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

    // The "Update ready" banner sits over the top of every screen until it's tapped, which gets in the
    // way while you're actually using the app. Auto-hide it after a few seconds — the update is still
    // available in Settings, and a NEW version re-shows it (see the onChange below).
    @State private var updateBannerAutoHidden = false
    private let updateBannerVisibleSeconds: TimeInterval = 10
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
                // A quick action tapped from a COLD start is delivered before any view exists, so it
                // waits in `pending` for the first screen that can run it. (A warm tap arrives while
                // we're already on screen and comes through the notification below instead.)
                runPendingQuickAction()
                WanderQuickActions.refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: WanderQuickActions.requested)) { note in
                if let url = note.userInfo?["url"] as? URL {
                    WanderQuickActions.pending = nil
                    handleURL(url)
                }
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
            .sheet(isPresented: $showLinkPaywall) {
                PaywallView(onClose: { showLinkPaywall = false })
            }
            .fullScreenCover(isPresented: Binding(get: { gate.locked && !license.isLicensed }, set: { _ in })) {
                PaywallView()
            }
            .onChange(of: scenePhase) { _, phase in
                // Refresh the Home-screen quick actions on the way OUT, which is Apple's advice and
                // also the only moment that matters: the icon can't be long-pressed until we've left.
                if phase == .background { WanderQuickActions.refresh() }
                if phase == .active {
                    SimulationSession.shared.rescheduleIfActive()
                    gate.refresh()
                    License.shared.refresh()   // re-check so an expired subscription re-locks
                    if session.isActive {
                        flashBanner()
                        // NOTE (build 128): a foreground `tunnelHealth.attemptReconnectNow()` used to fire
                        // here (build 127). REVERTED — returning to the app is precisely when the network
                        // is mid-transition (the user just toggled Airplane Mode in Control Center), and
                        // kicking a tunnel start into that window is what wedged the un-timeout-able RSD
                        // handshake, leaving the tunnel stuck "reconnecting…" until a force-quit. Recovery
                        // is now driven by the health poll once the endpoint is genuinely reachable again,
                        // which is the only safe time to rebuild.
                    }
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
            // Share-link import preview. Deliberately the SAME control style as the external-location
            // confirm above — this is the same class of event (something outside the app asking to do
            // something with your location) and it gets the same explicit gate. Note that NO button
            // here teleports: the spot's action previews it on the map, and the user presses Simulate
            // there, exactly as a tapped saved Place behaves.
            .confirmationDialog(
                shareImportTitle,
                isPresented: Binding(
                    get: { pendingShareImport != nil },
                    set: { isPresented in
                        if !isPresented { pendingShareImport = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingShareImport
            ) { payload in
                switch payload {
                case .spot(let spot):
                    Button(L("share.import.save_place", fallback: "Save to Places")) {
                        saveImportedSpot(spot)
                        pendingShareImport = nil
                    }
                    Button(L("share.import.show_map", fallback: "Show on map")) {
                        previewImportedSpot(spot)
                        pendingShareImport = nil
                    }
                case .route(let route):
                    Button(L("share.import.save_route", fallback: "Save to Routes")) {
                        saveImportedRoute(route)
                        pendingShareImport = nil
                    }
                }
                Button(L("action.cancel", fallback: "Cancel"), role: .cancel) {
                    pendingShareImport = nil
                }
            } message: { payload in
                Text(shareImportMessage(for: payload))
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
            .onChange(of: updater.available?.build) { _, newBuild in
                // A newly-discovered update gets its own 10s on screen; don't let a previous
                // auto-hide swallow it silently.
                guard newBuild != nil else { return }
                updateBannerAutoHidden = false
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(updateBannerVisibleSeconds * 1_000_000_000))
                    // Keep it up while an install is actually running — hiding mid-update looks broken.
                    if !updater.isBusy { withAnimation(.easeInOut(duration: 0.25)) { updateBannerAutoHidden = true } }
                }
            }
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
            // re-teleport, then the Location-Services flush; the reboot is the escalation, not the advice.
            let target = session.lastTeleportCoordinate
            let message = Text(L("snapback.body",
                                 fallback: "Your device pulled back toward your real location. Tap Re-teleport to jump back.\n\nIf it keeps snapping back: turn Location Services off, leave it off a full ~10 seconds, then back on — the wait is what makes iOS let go of its cached location, and a quick flick usually doesn't. Still snapping back after that? Then restart your iPhone; Wander will put you back here when you reopen it."))
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
        if updater.available != nil && !session.isActive && !panicToastVisible && !updateBannerAutoHidden {
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
        // The rest of the engine, exposed to Shortcuts. These run DIRECTLY for the same reason
        // teleport/reset do: they're fired by a shortcut the user built on purpose, and a wander://
        // link can already put you anywhere on earth via `teleport`, so making the MOVEMENT verbs
        // confirm-gated would buy no safety the current design doesn't already give away. What stays
        // gated is the class of link that arrives from SOMEONE ELSE — `share` below, and the legacy
        // stikdebug hosts above — which is the line the existing code actually draws.
        case "route":
            startSavedRoute(from: url)
        case "walk", "joystick":
            startHeadingWalk(from: url)
        case "itinerary":
            startSavedItinerary()
        case "preset", "game":
            setGamePreset(from: url)
        // PANIC only ever moves you back to your REAL GPS, so it needs no gate at all — same posture
        // as the always-available red Stop button whose code it reuses. (Deliberately NOT aliased to
        // "stop": `stop-location` above is the legacy confirm-gated clear, and two verbs one letter
        // apart with different safety postures is how someone gets surprised.)
        case "panic":
            panicStop()
        case "status":
            reportStatus(to: url)
        // Callbacks a Wander shortcut returns to (x-success/x-error/x-cancel). These just confirm the
        // shortcut ran + keep the "installed" flag honest; the OS action already happened in the shortcut.
        case "ping-ok", "flushed", "warmstarted", "primed", "verified", "swapped", "vpnconnected":
            ShortcutRunner.ready = true
        case "shortcut-missing":
            ShortcutRunner.ready = false
        case "cancel", "error":
            break
        // A shared spot/route. UNLIKE teleport/reset above this is NOT run directly: those come from
        // a shortcut the user built themselves, whereas a share link arrives from someone else.
        case "share":
            presentSharedLink(url)
        default:
            // The web form of the same link (https://wanderspoofer.com/go?…) arrives with the DOMAIN
            // as its host, so it can't be a `case` above. It's the form people actually paste into
            // chat, so it has to land in exactly the same place.
            if WanderShareLink.isShareURL(url) { presentSharedLink(url) }
        }
    }

    // MARK: - Shortcuts automation verbs
    //
    // Everything below is reached from `handleURL` — including the Home-screen quick actions, which
    // carry a wander:// link and are replayed through the same switch (see `WanderQuickActions`), so
    // there is exactly ONE dispatch table for links rather than two that can drift apart.
    //
    // These functions only PARSE and GATE. The engine work lives in `WanderLinkAutomation` because a
    // route runs for minutes while `MainTabView` is a struct SwiftUI may re-create at any moment.

    /// Case-insensitive query lookup, matching `coordinate(from:)`'s tolerance for the several
    /// spellings people actually type into a Shortcut. Empty values read as absent.
    private func linkValue(_ names: [String], in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in names {
            guard let raw = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// A flag written the way people actually write flags in a URL.
    private func linkFlag(_ names: [String], in url: URL) -> Bool {
        guard let raw = linkValue(names, in: url)?.lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    /// Speed for the movement verbs. Given bare, it's in the unit the user already reads everywhere
    /// else in the app (km/h, or mph when "useMph" is on), so `speed=6` means the same thing the
    /// joystick slider would show them. `unit=mps|kmh|mph` overrides that for a shortcut that wants
    /// to be explicit. Returns nil (⇒ "you pick") rather than a bogus 0 for junk input.
    private func linkSpeedMps(in url: URL) -> Double? {
        guard let raw = linkValue(["speed", "pace"], in: url),
              let value = Double(raw), value > 0 else { return nil }
        switch (linkValue(["unit", "units"], in: url) ?? "").lowercased() {
        case "mps", "m/s", "ms": return value
        case "kmh", "km/h", "kph": return value / 3.6
        case "mph": return SpeedFormat.toMps(value, useMph: true)
        default: return SpeedFormat.toMps(value, useMph: useMph)
        }
    }

    /// Heading in degrees (0 = north, 90 = east) or a compass point, because "walk north" is the
    /// natural thing to put in a Shortcut and forcing people to look up 315 isn't automation.
    private func linkHeadingDegrees(in url: URL) -> Double? {
        guard let raw = linkValue(["heading", "bearing", "direction", "course"], in: url) else { return nil }
        if let degrees = Double(raw) { return degrees }
        switch raw.lowercased() {
        case "n", "north": return 0
        case "ne", "northeast": return 45
        case "e", "east": return 90
        case "se", "southeast": return 135
        case "s", "south": return 180
        case "sw", "southwest": return 225
        case "w", "west": return 270
        case "nw", "northwest": return 315
        default: return nil
        }
    }

    /// The trial gate for the verbs whose TAB offers a trial — today that's the joystick only
    /// (`WalkModeView.start` is `!isLicensed && !canUse(.joystick) ⇒ paywall`). A link draws down the
    /// SAME allowance a tapped run does, so automation can't be used to walk around the paywall.
    private func linkTrialAllows(_ mode: SimMode) -> Bool {
        if License.shared.isLicensed { return true }
        if TrialManager.shared.canUse(mode) { return true }
        showLinkPaywall = true
        return false
    }

    /// The gate for the verbs their tab makes strictly Pro — saved routes (`runSavedRoute` opens with
    /// a bare `!isLicensed ⇒ paywall`) and the whole Itinerary feature (`gateOrPaywall`). Neither
    /// offers a trial, so neither may get one here: a link is another door into the same feature, and
    /// routing it through `canUse(.route)` handed free users three Pro runs a month.
    private func linkProAllows() -> Bool {
        if License.shared.isLicensed { return true }
        showLinkPaywall = true
        return false
    }

    /// `wander://route?name=<saved route>[&speed=12][&loop=1]` — plays a route the user already
    /// saved on the Route tab. Matched by NAME (that's what a shortcut can carry), exactly first,
    /// then by a contains match so "morning" finds "Morning loop".
    private func startSavedRoute(from url: URL) {
        guard let wanted = linkValue(["name", "route", "q"], in: url) else {
            showAlert(
                title: L("link.route.needs_name.title", fallback: "Which route?"),
                message: L("link.route.needs_name.body", fallback: "Use wander://route?name=Morning%20loop — the name has to match a route saved on the Route tab."),
                showOk: true
            )
            return
        }
        // A fresh store instance reloads from UserDefaults in its init, so a route saved seconds ago
        // on another screen is already visible here (same reason `saveImportedRoute` makes one).
        let routes = SavedRoutesStore().routes
        let match = routes.first { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            ?? routes.first { $0.name.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        guard let route = match else {
            // Name the routes that DO exist: the usual cause is a rename or a stray space in the
            // shortcut, and a bare "not found" leaves the user guessing which.
            let known = routes.prefix(6).map(\.name).joined(separator: ", ")
            showAlert(
                title: L("link.route.missing.title", fallback: "No route by that name"),
                message: routes.isEmpty
                    ? L("link.route.missing.empty", fallback: "You haven't saved any routes yet. Build one on the Route tab and save it, then use its name here.")
                    : String(format: L("link.route.missing.body", fallback: "Nothing saved is called “%@”. Saved routes: %@"), wanted, known),
                showOk: true
            )
            return
        }
        guard linkProAllows() else { return }
        WanderLinkAutomation.shared.startRoute(route,
                                               speedMps: linkSpeedMps(in: url),
                                               loop: linkFlag(["loop", "repeat"], in: url))
    }

    /// `wander://walk?heading=90&speed=6[&lat=…&lon=…]` — the joystick, hands-free: walk this way,
    /// at this pace, until something stops it. Starts from an explicit coordinate, else wherever the
    /// spoof currently is, else the real fix — the same order of preference the Walk tab offers.
    private func startHeadingWalk(from url: URL) {
        guard let heading = linkHeadingDegrees(in: url) else {
            showAlert(
                title: L("link.walk.needs_heading.title", fallback: "Which way?"),
                message: L("link.walk.needs_heading.body", fallback: "Use wander://walk?heading=90&speed=6 — heading is degrees (0 = north, 90 = east) or a compass point like NE."),
                showOk: true
            )
            return
        }
        let anchor = coordinate(from: url).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            ?? session.lastTeleportCoordinate
            ?? CLLocationManager().location?.coordinate
        guard let anchor, coordinateIsValid(latitude: anchor.latitude, longitude: anchor.longitude) else {
            showAlert(
                title: L("link.walk.needs_start.title", fallback: "Nowhere to walk from"),
                message: L("link.walk.needs_start.body", fallback: "Teleport somewhere first, or pass a start point: wander://walk?heading=90&speed=6&lat=37.33&lon=-122.03"),
                showOk: true
            )
            return
        }
        guard linkTrialAllows(.joystick) else { return }
        // No speed given ⇒ the joystick's own default, so the two doors behave the same.
        let speed = linkSpeedMps(in: url) ?? 6_000.0 / 3_600.0
        WanderLinkAutomation.shared.startWalk(from: anchor, headingDegrees: heading, speedMps: speed)
    }

    /// `wander://itinerary` — run the saved itinerary queue top to bottom.
    private func startSavedItinerary() {
        let steps = ItineraryStore().steps
        guard !steps.isEmpty else {
            showAlert(
                title: L("link.itinerary.empty.title", fallback: "Itinerary is empty"),
                message: L("link.itinerary.empty.body", fallback: "Add some stops on the Itinerary screen first — this verb runs the queue you've already built."),
                showOk: true
            )
            return
        }
        guard linkProAllows() else { return }
        WanderLinkAutomation.shared.startItinerary(steps: steps)
    }

    /// `wander://preset?game=pokemongo` — switch the game context that drives the cooldown curve and
    /// the speed guardrail. Changes a setting only; it never moves the location, so there's nothing
    /// here to gate.
    private func setGamePreset(from url: URL) {
        guard let raw = linkValue(["game", "preset", "name"], in: url),
              let preset = gamePreset(named: raw) else {
            showAlert(
                title: L("link.preset.unknown.title", fallback: "Unknown game"),
                message: L("link.preset.unknown.body", fallback: "Use wander://preset?game=pokemongo, mhnow, pikmin or ingress."),
                showOk: true
            )
            return
        }
        // Same key the PoGo tab's @AppStorage is bound to, so every screen picks the change up live.
        UserDefaults.standard.set(preset.rawValue, forKey: "pogoGamePreset")
        LogManager.shared.addInfoLog("Game preset set to \(preset.title) from a link")
    }

    /// Accepts what a person would actually type, not just the enum's raw value. Punctuation and
    /// case are stripped first so "Pokémon GO", "pokemon-go" and "pogo" all land in the same place.
    private func gamePreset(named raw: String) -> GamePreset? {
        let key = raw.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        switch key {
        case "pokemongo", "pokemon", "pogo", "go": return .pokemonGo
        case "monsterhunternow", "monsterhunter", "mhnow", "mhn": return .monsterHunterNow
        case "pikminbloom", "pikmin", "bloom": return .pikminBloom
        case "ingress": return .ingress
        default: return GamePreset(rawValue: raw)   // the exact raw value still works
        }
    }

    /// `wander://status?x-success=<callback>` — hand the current state back to the calling Shortcut
    /// so it can BRANCH on it ("if spoofing is false, teleport first"). Uses the same x-callback-url
    /// convention `ShortcutRunner` already speaks, just in the other direction: we append the answer
    /// as query parameters to the caller's x-success URL and open it.
    private func reportStatus(to url: URL) {
        guard let successRaw = linkValue(["x-success", "xsuccess", "callback"], in: url),
              var callback = URLComponents(string: successRaw) else {
            // A status call with nowhere to answer to just opens the app. Never an error dialog for
            // something the user can't see, and never a crash.
            LogManager.shared.addInfoLog("wander://status called without an x-success callback")
            return
        }
        // The callback carries the user's spoofed coordinates and Pro state, and `wander://` fires
        // from any web page or QR code with no iOS confirmation — so an unchecked x-success is a
        // one-tap exfiltration of where someone is pretending to be. Only the Shortcuts app can be
        // answered: that's the entire point of an x-callback-url, and it can't leave the device.
        // (This file already assumes a link from a stranger is hostile — it's why `share` parks in a
        // preview instead of acting.)
        guard callbackSchemeIsTrusted(callback.scheme) else {
            LogManager.shared.addInfoLog("wander://status refused a non-Shortcuts callback: \(callback.scheme ?? "none")")
            return
        }
        callback.queryItems = (callback.queryItems ?? []) + statusQueryItems()
        guard let answer = callback.url else { return }
        openExternalURL(answer)
    }

    /// The only schemes `status` will answer to. `shortcuts://` is what a Shortcut's own
    /// "x-callback" URL uses; `shortcuts-production://` is the form Shortcuts hands out when it
    /// builds the callback for you. Anything web-facing (or unknown) is refused.
    private func callbackSchemeIsTrusted(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return ["shortcuts", "shortcuts-production"].contains(scheme)
    }

    /// The read-back itself. Deliberately flat strings — a Shortcut compares text, so "true"/"false"
    /// and plain numbers are worth more here than a nested payload it would have to parse.
    private func statusQueryItems() -> [URLQueryItem] {
        let preset = GamePreset(rawValue: UserDefaults.standard.string(forKey: "pogoGamePreset") ?? "") ?? .pokemonGo
        var items = [
            URLQueryItem(name: "spoofing", value: session.isActive ? "true" : "false"),
            URLQueryItem(name: "activity", value: WanderLinkAutomation.shared.activity.rawValue),
            URLQueryItem(name: "tunnel", value: tunnel.status.rawValue),
            URLQueryItem(name: "health", value: tunnelHealthWord),
            URLQueryItem(name: "cooldown", value: String(Int(session.cooldownRemaining.rounded()))),
            URLQueryItem(name: "game", value: preset.rawValue),
            URLQueryItem(name: "gsloc", value: GslocMode.enabled ? "true" : "false"),
            URLQueryItem(name: "pro", value: license.isLicensed ? "true" : "false"),
        ]
        // The live point of a link-driven run first — mid-route the last teleport is the START line,
        // not where we are. Only when we actually have one: an absent parameter is easier for a
        // Shortcut to test than a "0, 0" that reads like a real place in the Gulf of Guinea.
        if let coordinate = WanderLinkAutomation.shared.currentCoordinate ?? session.lastTeleportCoordinate {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.6f", coordinate.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.6f", coordinate.longitude)))
        }
        return items
    }

    /// The health chip's three states as a word a Shortcut can compare.
    private var tunnelHealthWord: String {
        switch tunnelHealth.state {
        case .connected: return "connected"
        case .unstable: return "unstable"
        case .disconnected: return "disconnected"
        }
    }

    /// Run a Home-screen quick action by replaying the wander:// link it carries through the normal
    /// handler — quick actions are links, not a second command set.
    private func runPendingQuickAction() {
        guard let url = WanderQuickActions.pending else { return }
        WanderQuickActions.pending = nil
        handleURL(url)
    }

    // MARK: - Share-link import

    /// Decode a share link and PARK it in `pendingShareImport` for the preview dialog. Never acts.
    /// A link that can't be read is reported with the decoder's own human message rather than a
    /// generic failure, so the sharer can be told what to re-send.
    private func presentSharedLink(_ url: URL) {
        do {
            // A PASTED link arrives pre-decoded through the hand-off slot (its payload is far too
            // large to travel in a URL); a TAPPED one carries its own query. Both land here, so the
            // preview and confirmation below are the same code either way.
            if let handedOff = try WanderShareLink.handedOffPayload(from: url) {
                pendingShareImport = handedOff
                return
            }
            pendingShareImport = try WanderShareLink.payload(from: url)
        } catch {
            showAlert(
                title: L("share.import.failed", fallback: "Can't read that link"),
                message: error.localizedDescription,
                showOk: true
            )
        }
    }

    private var shareImportTitle: String {
        switch pendingShareImport {
        case .route: return L("share.import.route_title", fallback: "Imported route")
        default: return L("share.import.spot_title", fallback: "Imported spot")
        }
    }

    /// The preview itself: everything the user needs to judge the link BEFORE committing to it —
    /// its name, and for a route how many points it has and how far it runs.
    private func shareImportMessage(for payload: WanderSharePayload) -> String {
        switch payload {
        case .spot(let spot):
            let coords = String(format: "%.5f, %.5f", spot.coordinate.latitude, spot.coordinate.longitude)
            guard let name = spot.name else { return coords }
            return "\(name)\n\(coords)"
        case .route(let route):
            let meters = WanderShareLink.totalDistanceMeters(route.coordinates)
            let summary = String(format: L("share.import.route_summary", fallback: "%d points • %@"),
                                 route.coordinates.count, shareDistanceText(meters))
            guard let name = route.name else { return summary }
            return "\(name)\n\(summary)"
        }
    }

    /// Mirrors RouteModeView's distance phrasing so an imported route reads in the same unit the
    /// user already sees while building one.
    private func shareDistanceText(_ meters: Double) -> String {
        if useMph {
            let miles = meters / 1609.34
            return miles < 0.1 ? "\(Int(meters * 3.28084)) ft" : String(format: "%.1f mi", miles)
        }
        return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : "\(Int(meters)) m"
    }

    /// Append an imported spot to the shared `locationBookmarks` store the Places tab and the
    /// Teleport bookmarks both read, then post `.placesDidChange` so every live view reloads.
    /// (Written here rather than through SavedPlacesStore, which is a read/delete/update store with
    /// no public add — adding one is a change to a file this work doesn't own.)
    private func saveImportedSpot(_ spot: WanderSharedSpot) {
        let key = "locationBookmarks"
        var bookmarks: [LocationBookmark] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) {
            bookmarks = decoded
        }
        let fallbackName = String(format: "%.4f, %.4f", spot.coordinate.latitude, spot.coordinate.longitude)
        bookmarks.append(LocationBookmark(
            name: spot.name ?? fallbackName,
            latitude: spot.coordinate.latitude,
            longitude: spot.coordinate.longitude,
            updatedAt: Date()   // stamp for the multi-device sync newest-wins merge
        ))
        guard let encoded = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
        NotificationCenter.default.post(name: .placesDidChange, object: nil)
        LogManager.shared.addInfoLog("Imported a shared place from a link")
    }

    /// Center + pin the imported spot on the Teleport map WITHOUT moving — the user presses Simulate
    /// there. Same notification a tapped saved Place uses, so imported and saved spots behave alike.
    private func previewImportedSpot(_ spot: WanderSharedSpot) {
        selection = AppFeature.location.id
        NotificationCenter.default.post(
            name: .previewLocationRequested,
            object: nil,
            userInfo: ["lat": spot.coordinate.latitude, "lng": spot.coordinate.longitude]
        )
    }

    private func saveImportedRoute(_ route: WanderSharedRoute) {
        // A fresh store instance reloads from UserDefaults in its init, so this can't persist a
        // stale in-memory array over routes another screen saved while this dialog was up.
        SavedRoutesStore().add(name: route.name ?? "", coordinates: route.coordinates)
        LogManager.shared.addInfoLog("Imported a shared route (\(route.coordinates.count) points) from a link")
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
                    // Register the teleport with the session exactly as the map's own teleport does
                    // (MapSelectionView.simulate): `started()` marks the session active and takes the
                    // keep-alive (it calls requestStart itself — hence no separate call here), and
                    // `noteTeleport` records the point, applies the app-wide cooldown and arms the
                    // snap-back watcher. Without this a link teleport left the rest of the app
                    // believing nothing was spoofing, so `wander://status` answered spoofing=false
                    // with no lat/lon, and a following `wander://walk` fell through to the REAL fix
                    // and quietly walked the user around their actual neighbourhood.
                    let target = CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                        longitude: coordinate.longitude)
                    SimulationSession.shared.started()
                    SimulationSession.shared.noteTeleport(to: target)
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

/// The engine behind the movement verbs (`wander://route`, `wander://walk`, `wander://itinerary`).
///
/// It lives OUTSIDE the view on purpose: a route plays for minutes and a walk runs until something
/// stops it, while `MainTabView` is a struct SwiftUI is free to re-create on any state change.
///
/// Everything here is deliberately the SAME machinery the tabs drive — `buildPlaybackSamples` for
/// pacing, `HumanizedMotion` for gait, `SpeedGovernor` for the hard ceiling, `ItineraryRunner` for
/// itineraries — so a link-driven run and a tapped run behave identically and there is still only
/// one movement engine to reason about.
@MainActor
final class WanderLinkAutomation {
    static let shared = WanderLinkAutomation()

    /// What the link automation is driving right now. Read back by `wander://status` so a shortcut
    /// can tell "spoofing, parked" from "spoofing, halfway round a route".
    enum Activity: String {
        case idle, route, walk, itinerary
    }

    private(set) var activity: Activity = .idle

    /// Where our run currently is, for the `status` read-back. `SimulationSession.lastTeleportCoordinate`
    /// is the last PARKED point, so it goes stale the moment a walk or route starts moving away from
    /// it — a Shortcut that asked "where am I?" mid-route would otherwise be told the start line.
    private(set) var currentCoordinate: CLLocationCoordinate2D?

    private var playbackTask: Task<Void, Never>?
    /// The deferred arm for the verbs that have no playback task of their own (walk, itinerary).
    /// See `standDownOtherWriters` for why arming can never happen inside the stand-down itself.
    private var armTask: Task<Void, Never>?
    private var walkTimer: Timer?
    private var walkCoordinate: CLLocationCoordinate2D?
    private var walkHeading: Double = 0          // radians, matching the dLat = d·cos(h) convention
    private var walkSpeedMps: Double = 0
    private var walkMotion = HumanizedMotion(context: .autonomous)
    /// Sub-second remainder of the free-trial joystick clock, so a 1 s tick charges exactly 1 s.
    private var walkTrialFraction: TimeInterval = 0
    /// The Itinerary tab's own runner rather than a second implementation of stay/advance timing.
    /// Built per run, not held for the life of the app — see `startItinerary` for why.
    private var itineraryRunner: ItineraryRunner?
    private var stopObserver: NSObjectProtocol?

    /// Bumped every time a global stop is observed. A run that is still being set up (road-routing a
    /// builder route can take seconds of MKDirections round-trips) snapshots this and re-checks it at
    /// every await, so a Stop pressed during set-up cancels the run before it writes its first fix.
    ///
    /// This exists INSTEAD of cancelling the pending task from the stop observer, because the observer
    /// cannot tell a user's Stop from the echo of the stand-down we broadcast ourselves — and that
    /// echo always arrives before a pending arm's first line, so it would cancel every take-over.
    /// Snapshotting the epoch inside the arm reads the echo as history and only later stops as news.
    private var stopEpoch = 0

    /// True while this class holds the background keep-alive.
    ///
    /// Without a hold, iOS suspends the app and reclaims the socket under the DVT connection (Apple
    /// TN2277) — the 1 Hz tick stops and the spoof dies. That matters MORE here than on the tabs: a
    /// Shortcut-driven run is by definition one the user isn't watching, so the app is backgrounded
    /// almost immediately. `WalkModeView` and `RouteModeView` hold exactly the same latch.
    ///
    /// A latch rather than raw requestStart/requestStop calls: there is one entry path but several
    /// exit paths, and unbalanced calls would decrement the shared activity count, possibly releasing
    /// a hold belonging to another active mode.
    private var keepAliveHeld = false

    /// Matches the joystick's own tick, so the humanized gait behaves identically to the tab's.
    private let tickInterval: TimeInterval = 1.0
    /// Pace for a saved route that carries no timing and whose link named no speed. Walking pace:
    /// saved routes are overwhelmingly walking loops, and it's the joystick's default too.
    private let defaultRouteSpeedMps: Double = 6_000.0 / 3_600.0
    /// At or below this the route is being played at human walking pace, so it should follow
    /// footpaths rather than roads when we road-route it. Roughly 9 km/h — a brisk walk.
    private let walkingPaceCeilingMps: Double = 2.5

    private init() {
        // The panic button, every mode's Stop and every stopAll() broadcast this. We MUST honour it —
        // otherwise our next tick would revive the spoof the user just killed (ItineraryRunner keeps
        // the same contract for the same reason).
        //
        // `queue: nil` — i.e. SYNCHRONOUSLY on the poster's thread (always the main actor;
        // `stopAll()` is @MainActor) — is load-bearing. The previous `Task { @MainActor }` hop meant
        // a stand-down we broadcast OURSELVES landed a turn AFTER we had armed the replacement run
        // and tore it straight back down, which is what pushed the first cut into never broadcasting
        // at all and leaving two 1 Hz writers fighting over the queue.
        stopObserver = NotificationCenter.default.addObserver(
            forName: .stopSimulationRequested, object: nil, queue: nil
        ) { [weak self] _ in
            // Guarded rather than asserted: `stopAll()` is the only poster and it's @MainActor, but a
            // future background poster should degrade to a late stand-down, not a crash.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.cancelLocalWork() }
            } else {
                Task { @MainActor in self?.cancelLocalWork() }
            }
        }
    }

    // MARK: - Verbs

    /// Play a saved route, optionally looping. `speedMps == nil` means "use the route's own pace".
    func startRoute(_ route: SavedRoute, speedMps: Double?, loop: Bool) {
        guard pairingFilePath() != nil else { reportMissingPairingFile(); return }
        guard route.coordinates.count > 1 else { reportUnplayableRoute(); return }

        standDownOtherWriters()
        // Everything from here runs on a hop of our own — see `standDownOtherWriters` — and a builder
        // route needs an async road-routing pass before it can be paced at all.
        playbackTask = Task { [weak self] in
            guard let self else { return }
            // Snapshot AFTER the stand-down has fully settled (see `stopEpoch`); from here a change
            // means the user stopped us, and we drop the run rather than start driving anyway.
            let epoch = self.stopEpoch
            let path = await self.drivablePath(for: route, speedMps: speedMps)
            guard !Task.isCancelled, self.stopEpoch == epoch else { return }
            let samples = self.playbackSamples(for: route, path: path, speedMps: speedMps)
            guard samples.count > 1 else { self.reportUnplayableRoute(); return }

            self.armAsSoleWriter(.route)
            if !License.shared.isLicensed { TrialManager.shared.chargeRoute() }
            // Adventure Sync: open a walk window so the drive can be mirrored into Health incrementally
            // (no-op unless the user opted in), exactly as the Route tab does.
            AdventureSyncManager.shared.beginWalk()
            LogManager.shared.addInfoLog("Link automation: playing route '\(route.name)' (\(samples.count) points)\(loop ? ", looping" : "")")

            let clampPreset = self.speedClampPreset()
            repeat {
                var previous: CLLocationCoordinate2D?
                for sample in samples {
                    if Task.isCancelled || self.stopEpoch != epoch { return }
                    var delay = sample.delayFromPrevious
                    // Hold the ACTUAL advance rate at the hard ceiling by stretching the sleep, the
                    // way the Route tab does: a saved route with two far-apart points would otherwise
                    // imply an impossible, ban-triggering jump between them.
                    if let clampPreset, let previous {
                        let stepMeters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                            .distance(from: CLLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude))
                        delay = max(delay, stepMeters / SpeedGovernor.hardCeilingMps(for: clampPreset))
                    }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    if Task.isCancelled || self.stopEpoch != epoch { return }
                    self.sendMoving(sample.coordinate)
                    AdventureSyncManager.shared.recordSimulatedMovement(to: sample.coordinate)
                    self.currentCoordinate = sample.coordinate
                    previous = sample.coordinate
                }
            } while loop && !Task.isCancelled && self.stopEpoch == epoch
            // Only on a NATURAL finish. A cancelled run was stopped by the user (or by panic), and
            // parking + handing the hold back would re-freeze the location they just told us to drop.
            if !Task.isCancelled, self.stopEpoch == epoch {
                self.finishMovement(parkingAt: samples.last?.coordinate)
            }
        }
    }

    /// Walk on a fixed heading at a fixed pace, hands-free, until something stops it.
    func startWalk(from coordinate: CLLocationCoordinate2D, headingDegrees: Double, speedMps: Double) {
        guard pairingFilePath() != nil else { reportMissingPairingFile(); return }

        standDownOtherWriters()
        armTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.armAsSoleWriter(.walk)
            self.walkCoordinate = coordinate
            self.currentCoordinate = coordinate
            self.walkHeading = headingDegrees * .pi / 180
            self.walkSpeedMps = speedMps
            // Hands-free ⇒ the AUTONOMOUS gait (pace wobble, heading drift, the occasional
            // micro-pause), the context auto-walk uses. There's no hand on the stick here to make the
            // trace look human, so the motion engine has to do all of it.
            self.walkMotion = HumanizedMotion(context: .autonomous)
            self.walkTrialFraction = 0
            AdventureSyncManager.shared.beginWalk()
            LogManager.shared.addInfoLog(String(format: "Link automation: walking %.0f° at %.1f m/s", headingDegrees, speedMps))
            // Seed the starting point CLEAN — the first fix of a run is a parked point, and a
            // scattered one would read as a jump away from wherever the user just was.
            self.send(coordinate)
            self.walkTimer = Timer.scheduledTimer(withTimeInterval: self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.walkTick() }
            }
        }
    }

    /// Run the saved itinerary queue through the Itinerary tab's own runner.
    ///
    /// There is deliberately no "already running?" guard on OUR runner: `ItineraryQueueView` owns a
    /// separate `ItineraryRunner` instance, so `isRunning` here could never see a run the user
    /// started from the tab — the guard the first cut had read the wrong object and let a link start
    /// a SECOND itinerary teleporting against the first. The stand-down below is what actually
    /// guarantees one runner, because every `ItineraryRunner` honours `.stopSimulationRequested`
    /// regardless of who owns it.
    func startItinerary(steps: [ItineraryStep]) {
        guard pairingFilePath() != nil else { reportMissingPairingFile(); return }
        standDownOtherWriters()
        armTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.activity = .itinerary
            LogManager.shared.addInfoLog("Link automation: running a \(steps.count)-stop itinerary")
            // ItineraryRunner arms the rest itself (single-writer suppression, snap-back stand-down,
            // session start), so doing it here as well would only duplicate it. We still take the
            // keep-alive: the runner has none of its own, and an unattended itinerary is exactly the
            // case where iOS suspends us and reclaims the socket (TN2277).
            self.holdKeepAlive()
            // A FRESH runner every time, rather than one held for the life of the app. Stopping a
            // running itinerary broadcasts a stop that EVERY live `ItineraryRunner` defers by a
            // main-actor hop before acting on — ours included — so a long-lived instance would be
            // started by the line below and then torn down a turn later by the echo of the very
            // stand-down that made room for it. An instance built after the stand-down has no echo
            // aimed at it. The previous one was already stopped by that same broadcast.
            let runner = ItineraryRunner()
            self.itineraryRunner = runner
            runner.start(steps: steps)
        }
    }

    // MARK: - Walking

    private func walkTick() {
        guard activity == .walk, var coordinate = walkCoordinate else { return }
        // Re-assert single-writer ownership every tick, exactly as the joystick does: a teleport on
        // another tab must not silently re-enable the Map tab's 4 s resend and rubber-band us back to
        // its stale point — the impossible backward jump behind PoGo's "Failed to detect location (12)".
        LocationSimulationCommandQueue.suppressResends = true

        // A link-driven walk draws down the same free-trial joystick allowance a hand-driven one
        // does, so automation can't be used to walk around the paywall.
        if !License.shared.isLicensed {
            walkTrialFraction += tickInterval
            while walkTrialFraction >= 1 {
                TrialManager.shared.addJoystickSeconds(1)
                walkTrialFraction -= 1
            }
            if !TrialManager.shared.canUse(.joystick) {
                SimulationSession.shared.stopAll()   // ends the run through the one global stop path
                return
            }
        }

        let (speed, heading) = walkMotion.next(targetSpeed: walkSpeedMps,
                                               baseHeading: walkHeading,
                                               dt: tickInterval)
        // The always-on hard ceiling (see SpeedGovernor). A shortcut can ask for any speed it likes;
        // this is what stops that being a self-inflicted ban.
        let distance = SpeedGovernor.clampSpeedMps(speed, preset: speedClampPreset()) * tickInterval

        let metersPerDegLat = 111_320.0
        let lonScale = max(cos(coordinate.latitude * .pi / 180), 0.000001)
        coordinate.latitude += (distance * cos(heading)) / metersPerDegLat
        coordinate.longitude += (distance * sin(heading)) / (metersPerDegLat * lonScale)
        walkCoordinate = coordinate            // clean path stays the next-tick anchor
        currentCoordinate = coordinate

        sendMoving(coordinate, movedMeters: distance)
        AdventureSyncManager.shared.recordSimulatedMovement(to: coordinate)
    }

    // MARK: - Pacing

    /// Road-follow a BUILDER route's waypoints before it's played, the way `RouteModeView.runSavedRoute`
    /// does (it re-runs `computeRoute()` on the saved waypoints before `startDrive()`). A builder route
    /// is a handful of pins kilometres apart; interpolating straight between them drives the avatar
    /// through buildings and across water, which is the one thing the whole movement engine exists to
    /// avoid. A RECORDED route is already a dense real-GPS trail, so it is returned untouched — the
    /// Route tab drives those raw for exactly the same reason.
    private func drivablePath(for route: SavedRoute, speedMps: Double?) async -> [CLLocationCoordinate2D] {
        let waypoints = route.coordinates
        guard !route.isRecorded, waypoints.count >= 2 else { return waypoints }

        let legs = zip(waypoints, waypoints.dropFirst()).map { start, end in
            CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        // An already-dense path (an imported GPX saved as a builder route: hundreds of points a few
        // metres apart) IS the road — routing it would be hundreds of MKDirections round-trips to
        // rebuild a line we already have. Only sparse routes have anything to gain.
        guard let longestLeg = legs.max(), longestLeg > 60 else { return waypoints }
        // One network round-trip per leg, unattended. Past a couple of dozen legs that's minutes of
        // throttled MKDirections calls before the first fix moves, so play it as saved and say so
        // rather than leaving the shortcut apparently hung.
        guard legs.count <= 25 else {
            LogManager.shared.addInfoLog("Link automation: '\(route.name)' has \(legs.count) legs — playing the saved waypoints without road routing")
            return waypoints
        }

        // Walking pace ⇒ footpaths, anything faster ⇒ roads. The Route tab reads its on-screen Mode
        // picker for this; a link has no picker, and the pace it's played at is the only honest
        // signal of what the user meant by the route.
        let transport: MKDirectionsTransportType =
            (speedMps ?? defaultRouteSpeedMps) <= walkingPaceCeilingMps ? .walking : .automobile

        var path: [CLLocationCoordinate2D] = []
        for (start, end) in zip(waypoints, waypoints.dropFirst()) {
            if Task.isCancelled { return waypoints }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = transport
            if let response = try? await MKDirections(request: request).calculate(),
               let leg = response.routes.first {
                path.append(contentsOf: polylineCoordinates(leg.polyline))
            } else {
                // No road data for this leg (a hop across water, a private estate). Keep the two raw
                // waypoints instead of dropping the leg — the same fallback `computeRoute()` uses.
                path.append(start)
                path.append(end)
            }
        }
        return path.count > 1 ? path : waypoints
    }

    private func polylineCoordinates(_ polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                   count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return coordinates
    }

    /// A RECORDED route replays at the pace it was really walked — that's the whole point of having
    /// captured the timestamps — unless the link asked for a speed. That pacing comes from
    /// `buildRecordedPlaybackSamples`, the SAME helper the Route tab calls for the identical job:
    /// this used to be re-implemented inline here with a different gap clamp, which is two answers to
    /// one question. Everything else is paced by `buildPlaybackSamples`, as the Route tab's
    /// manual-speed mode is.
    private func playbackSamples(for route: SavedRoute,
                                 path: [CLLocationCoordinate2D],
                                 speedMps: Double?) -> [RoutePlaybackSample] {
        guard path.count > 1 else { return [] }

        if speedMps == nil, route.isRecorded, let stamps = route.timestamps {
            let recorded = buildRecordedPlaybackSamples(coordinates: path, timestamps: stamps)
            if recorded.count > 1 { return recorded }
        }

        return buildPlaybackSamples(
            from: path,
            speedWays: [],
            fallbackSpeedMetersPerSecond: speedMps ?? defaultRouteSpeedMps
        )
    }

    // MARK: - Stream ownership

    /// Tell every OTHER location writer to stand down, then let the caller arm on a hop of its own.
    ///
    /// The previous cut skipped this broadcast entirely, on the theory that a stop we sent ourselves
    /// would come back and kill the run we were starting. That left the real hazard in place: the
    /// other modes do NOT stop by themselves. `RouteModeView.onDisappear` only resets when the session
    /// is idle — and the session is active during a drive — so its playback task keeps running off-tab,
    /// and `WalkModeView`'s timer keeps ticking while its tab is on screen, which a deep link doesn't
    /// change. A link fired mid-drive therefore put two 1 Hz writers on the same serial queue pushing
    /// different coordinates, each re-asserting `suppressResends` so neither could see the other: the
    /// position oscillates, which is the impossible-backward-jump that makes Pokémon GO throw
    /// "Failed to detect location (12)".
    ///
    /// `.stopSimulationRequested` is the only signal those views honour, and they honour it
    /// SYNCHRONOUSLY (SwiftUI's `onReceive` delivers on the posting thread), so they are stood down by
    /// the time this returns. Our own observer is synchronous too, so it lands here rather than after
    /// the new run is armed. `ItineraryRunner` is the exception — it defers its teardown by one
    /// main-actor hop and ends it in `stopAll()`, which broadcasts a SECOND stop and clears the device
    /// location — so callers arm inside a `Task` created AFTER this returns. The main actor runs
    /// unstructured tasks in creation order, so that deferred teardown (and its echo) has completely
    /// finished before the arm's first line runs; the arm then snapshots `stopEpoch` and is looking
    /// only at stops that come from the user.
    private func standDownOtherWriters() {
        // Replacing our OWN pending/running work is deliberate, so it's cancelled here rather than
        // left to the epoch check — a shortcut fired twice should replace its run, not stack two.
        playbackTask?.cancel()
        playbackTask = nil
        armTask?.cancel()
        armTask = nil
        cancelLocalWork()
        NotificationCenter.default.post(name: .stopSimulationRequested, object: nil)
    }

    /// Become the sole location writer, exactly the way `WalkModeView.start()` and
    /// `RouteModeView.startDrive()` do: silence the Map tab's teleport resend, stand the snap-back
    /// watcher down, mark the session active, and take the background keep-alive.
    private func armAsSoleWriter(_ next: Activity) {
        activity = next
        LocationSimulationCommandQueue.suppressResends = true
        // Moving writer now — stand the stationary-teleport snap-back watcher down so legitimately
        // moving away from the last teleport can't false-fire its re-teleport (a second writer).
        SimulationSession.shared.movementModeDidBecomeActiveWriter()
        SimulationSession.shared.started()
        holdKeepAlive()
    }

    /// See `keepAliveHeld`.
    private func holdKeepAlive() {
        guard !keepAliveHeld else { return }
        keepAliveHeld = true
        BackgroundLocationManager.shared.requestStart()
    }

    private func releaseKeepAlive() {
        guard keepAliveHeld else { return }
        keepAliveHeld = false
        BackgroundLocationManager.shared.requestStop()
    }

    /// A movement verb ran to its natural end (a Stop never lands here — that goes through stopAll()).
    /// Park on the final point and hand the warm hold back to the Map tab RE-SEEDED THERE, exactly as
    /// the Route tab and auto-walk do, so the fix stays alive now that our loop has stopped.
    private func finishMovement(parkingAt coordinate: CLLocationCoordinate2D?) {
        playbackTask = nil
        stopWalkTimer()
        activity = .idle
        AdventureSyncManager.shared.endWalk()
        // Our loop is done, so give our hold back. The session is still active — `started()` took a
        // hold of its own that lives until the user stops — so the Map tab's resend keeps the parked
        // fix warm; what we're releasing is only the extra count this run was holding.
        releaseKeepAlive()
        guard let coordinate else { return }
        NotificationCenter.default.post(
            name: .holdLocationRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
    }

    /// A global stop landed (panic, a mode's Stop, a trial cut-off) — drop everything we're driving.
    /// Deliberately does NOT call stopAll() itself: the broadcast we're reacting to came from it, and
    /// re-entering would loop.
    ///
    /// It deliberately does NOT cancel the pending task either — see `stopEpoch`. Bumping the epoch is
    /// how a pending run learns a stop happened, and it's the only version of that check that can tell
    /// "the user pressed Stop" from "the stand-down I just broadcast came back around".
    private func cancelLocalWork() {
        stopEpoch &+= 1
        stopWalkTimer()
        walkCoordinate = nil
        // The run is over and the device is back on real GPS, so there is no position of ours left to
        // report — `status` falls back to the session's last parked teleport.
        currentCoordinate = nil
        if activity != .idle { AdventureSyncManager.shared.endWalk() }
        activity = .idle
        releaseKeepAlive()
    }

    private func stopWalkTimer() {
        walkTimer?.invalidate()
        walkTimer = nil
    }

    // MARK: - Writing

    /// One MOVING fix. Mirrors the Route tab's per-sample write: honour "hold perfectly still" and
    /// the jitter toggle, and scatter the REPORTED point with the receiver-error model when realistic
    /// motion is on — but only when the step is bigger than the noise itself, since below that the
    /// ±2.5 m scatter dominates and reads as jumpy, near-teleport motion (a second Error-12 trigger).
    private func sendMoving(_ coordinate: CLLocationCoordinate2D, movedMeters: Double = .greatestFiniteMagnitude) {
        let frozen = UserDefaults.standard.bool(forKey: LocationPrivacyKeys.frozenHold)
        guard !frozen, UserDefaults.standard.bool(forKey: "jitterEnabled") else {
            send(coordinate)
            return
        }
        let reported = (MotionRealism.isEnabled && movedMeters > 2.5)
            ? HumanizedMotion.gpsNoise(coordinate)
            : LocationJitter.apply(coordinate)
        send(reported)
    }

    /// The single write choke-point for everything this class drives, so single-writer suppression is
    /// re-asserted on every fix (mirrors ItineraryRunner.sendOnce) and nothing can silently re-enable
    /// the Map tab's resend behind our back.
    private func send(_ coordinate: CLLocationCoordinate2D) {
        guard let path = pairingFilePath() else { return }
        // "Approximate location": stable per-session offset. No-op when off.
        let target = CoarseLocation.apply(coordinate)
        LocationSimulationCommandQueue.suppressResends = true
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, target.latitude, target.longitude, path)
        }
    }

    // MARK: - Helpers

    private func pairingFilePath() -> String? {
        let url = PairingFileStore.prepareURL()
        // gs-loc mode injects through the proxy, not the dev tunnel — no pairing file needed.
        return (FileManager.default.fileExists(atPath: url.path) || GslocMode.enabled) ? url.path : nil
    }

    private func reportMissingPairingFile() {
        showAlert(
            title: L("link.needs_pairing.title", fallback: "Pairing file required"),
            message: L("link.needs_pairing.body", fallback: "Import a pairing file in Settings before driving Wander from a shortcut."),
            showOk: true
        )
    }

    private func reportUnplayableRoute() {
        showAlert(
            title: L("link.route.unplayable.title", fallback: "Can't play that route"),
            message: L("link.route.unplayable.body", fallback: "That route doesn't have enough points to move along. Open it on the Route tab and check it."),
            showOk: true
        )
    }

    /// The game context for the hard speed ceiling: the user's selected game only when they've opted
    /// into game-speed guidance, otherwise nil (SpeedGovernor's absolute fallback). Same rule the
    /// Route and Walk tabs apply, so a link run is clamped exactly like a tapped one.
    private func speedClampPreset() -> GamePreset? {
        guard UserDefaults.standard.bool(forKey: "gameSpeedWarn") else { return nil }
        return GamePreset(rawValue: UserDefaults.standard.string(forKey: "pogoGamePreset") ?? "") ?? .pokemonGo
    }
}

/// Home-screen quick actions (long-press the Wander icon).
///
/// Each item carries the SAME `wander://` link the Shortcuts verbs use, in its userInfo, and is
/// replayed through `MainTabView.handleURL` — so a quick action is just a link the OS fires and
/// there is one dispatch table rather than two that can drift apart.
enum WanderQuickActions {
    /// userInfo key holding the wander:// link an item runs.
    static let userInfoURLKey = "wanderURL"
    /// Posted when an item is tapped while the app is already alive.
    static let requested = Notification.Name("wander.quickActionRequested")
    /// An item tapped at COLD launch is delivered before any view exists, so it waits here for the
    /// first screen that can run it.
    static var pending: URL?

    /// Turn a tapped item into the link it carries and hand it to the normal handler.
    static func handle(_ item: UIApplicationShortcutItem) {
        guard let raw = item.userInfo?[userInfoURLKey] as? String,
              let url = URL(string: raw) else { return }
        pending = url
        NotificationCenter.default.post(name: requested, object: nil, userInfo: ["url": url])
    }

    /// Rebuild the item list: the user's first few saved places as one-tap teleports, plus the stop.
    /// iOS shows at most four, so three favourites is the honest ceiling.
    ///
    /// This REPLACES the static item declared in Info.plist. The static one exists to cover the only
    /// window this method can't — a fresh install that has never been launched, where there is no
    /// process to build a list — and it carries the same "wander://panic" link, so the Stop action is
    /// on the long-press menu from the moment the app lands on the Home screen.
    static func refresh() {
        var items: [UIApplicationShortcutItem] = favourites().prefix(3).enumerated().map { index, place in
            UIApplicationShortcutItem(
                // Unique per row: iOS treats `type` as the item's identity, and three items sharing
                // one type is how a menu ends up showing the same entry three times.
                type: "com.wander.quickaction.teleport.\(index)",
                localizedTitle: String(format: L("quickaction.teleport", fallback: "Teleport: %@"), place.name),
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "location.fill"),
                userInfo: [userInfoURLKey: "wander://teleport?lat=\(place.latitude)&lon=\(place.longitude)" as NSString]
            )
        }
        // Always last, always present: the stop is the one action someone needs in a hurry, and it
        // only ever moves you back to your real GPS.
        items.append(UIApplicationShortcutItem(
            type: staticStopItemType,
            localizedTitle: L("quickaction.stop", fallback: "Stop spoofing (real GPS)"),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "stop.fill"),
            userInfo: [userInfoURLKey: "wander://panic" as NSString]
        ))
        UIApplication.shared.shortcutItems = items
    }

    /// Must match `UIApplicationShortcutItemType` of the static entry in Info.plist, so the dynamic
    /// list replaces that entry rather than sitting beside a duplicate of it.
    static let staticStopItemType = "com.wander.quickaction.stop"

    /// The saved places the Teleport bookmarks and the Places tab share, newest first.
    private static func favourites() -> [LocationBookmark] {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return [] }
        return decoded
    }
}

/// Receives Home-screen quick actions. UIKit delivers them to the app/scene delegate, which is the
/// only hook a SwiftUI-lifecycle app has for them — there is no `onOpenURL` equivalent.
///
/// Installed by the one line this needs in `WanderApp`:
///
///     @UIApplicationDelegateAdaptor(WanderQuickActionDelegate.self) private var quickActions
///
/// It exists ONLY to route a tapped item back into `handleURL`; it deliberately implements nothing
/// else, so it can't quietly become a second place where app lifecycle logic lives.
final class WanderQuickActionDelegate: NSObject, UIApplicationDelegate {
    /// Cold launch: the tapped item rides in with the scene's connection options.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { WanderQuickActions.handle(item) }
        // `name: nil` on purpose — there is no UIApplicationSceneManifest in Info.plist, so naming a
        // configuration that isn't declared there is how this throws at launch. Setting only
        // `delegateClass` is the documented way a SwiftUI-lifecycle app gets a scene delegate;
        // SwiftUI still creates and owns the window.
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = WanderQuickActionSceneDelegate.self
        return configuration
    }
}

/// Warm taps (the app was already running) go to the SCENE delegate, not the app delegate — hence
/// this second, deliberately tiny class.
final class WanderQuickActionSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        WanderQuickActions.handle(shortcutItem)
        completionHandler(true)
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
