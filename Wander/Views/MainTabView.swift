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

    @ObservedObject private var setupChecker = SetupChecker.shared
    @State private var showSetup = false
    @State private var didRunSetupCheck = false

    @ObservedObject private var gate = RemoteGate.shared
    // Apple-ID account singleton — observed so the OTA re-sign's 2FA prompt can surface from the
    // update banner and launch-time auto-install (not just from Settings/login). Without this,
    // tapping "Update ready" asks Apple for a 2FA code with nowhere on screen to enter it.
    @ObservedObject private var wanderAccount = WanderAccount.shared
    @State private var twoFactorCode = ""
    @ObservedObject private var license = License.shared
    @ObservedObject private var session = SimulationSession.shared
    @ObservedObject private var updater = WanderUpdater.shared
    @ObservedObject private var tunnel = WanderTunnel.shared
    @State private var bannerVisible = false
    @State private var bannerHideWork: DispatchWorkItem?

    // Panic button confirmation toast.
    @State private var panicToastVisible = false
    @State private var panicToastHideWork: DispatchWorkItem?

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
            .overlay(alignment: .top) { spoofingBanner }
            .overlay(alignment: .bottomTrailing) { if panicButtonEnabled { panicButton } }
            .overlay(alignment: .top) { panicToast }
            .overlay(alignment: .top) { updateBanner }
            .animation(.easeInOut(duration: 0.25), value: bannerVisible)
            .animation(.easeInOut(duration: 0.25), value: panicToastVisible)
            .animation(.easeInOut(duration: 0.25), value: updater.available != nil)
            .onChange(of: session.isActive) { _, active in
                if active { flashBanner() } else { withAnimation { bannerVisible = false } }
            }
            .onChange(of: tunnel.status) { _, status in
                // The tunnel is usually still connecting at launch when the first auto-install
                // attempt runs; retry the silent install the moment it connects.
                if status == .connected {
                    Task { await WanderUpdater.shared.autoInstallIfAvailable() }
                }
            }
            .onChange(of: updater.latestManifest?.build) { _, _ in
                maybeShowWhatsNew()
            }
            // One-time-per-session coaching tip: spoofing was just started while on cellular.
            // Advisory only — spoofing already started; this never blocks it. Shown at most once
            // per app session (see SimulationSession.didShowCellularTip); reappears next launch.
            .alert(
                L("tip.cellular.title", fallback: "Heads up: you're on cellular"),
                isPresented: $session.showCellularTip
            ) {
                Button(L("action.ok", fallback: "Got it"), role: .cancel) {
                    session.showCellularTip = false
                }
            } message: {
                Text(localized: "tip.cellular.body", fallback: "On cellular your real area can still leak — even with a VPN. For the most believable spoof, connect to Wi-Fi or turn on Airplane Mode.")
            }
            // Apple-ID 2FA prompt for the OTA re-sign. The update banner and launch-time
            // auto-install kick the re-sign from HERE (not Settings), so without this alert the
            // code Apple sends has nowhere to go and the update stalls. Settings and the login
            // view carry their own copy for their own flows; the flag is transient (cleared on
            // submit/cancel) so these never fight to present.
            .alert("Two-Factor Code", isPresented: $wanderAccount.awaiting2FA) {
                TextField("6-digit code", text: $twoFactorCode)
                    .keyboardType(.numberPad)
                Button("Submit") {
                    wanderAccount.submitTwoFactorCode(twoFactorCode.trimmingCharacters(in: .whitespaces))
                    twoFactorCode = ""
                }
                Button("Cancel", role: .cancel) {
                    wanderAccount.submitTwoFactorCode(nil)
                    twoFactorCode = ""
                }
            } message: {
                Text("Enter the 6-digit code Apple sent to your trusted device. No popup? Get it from Settings → your name → Sign-In & Security → Get Verification Code.")
            }
        }
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
        Task {
            guard WanderAccount.shared.isSignedIn else {
                updater.status = "Sign in to your Apple ID in Settings, then tap again."
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
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
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
                        message: "Could not simulate location from URL (error \(code)). Make sure the device is connected and the DDI is mounted.",
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

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
