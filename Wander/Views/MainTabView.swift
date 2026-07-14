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
    @State private var detachedFeature: AppFeature?
    @State private var didSetInitialHome = false
    @State private var pendingLocationAction: ExternalLocationAction?
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject private var setupChecker = SetupChecker.shared
    @State private var showSetup = false
    @State private var didRunSetupCheck = false

    @ObservedObject private var gate = RemoteGate.shared
    @ObservedObject private var license = License.shared
    @ObservedObject private var session = SimulationSession.shared
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
            }
            .onChange(of: setupChecker.hasRunOnce) { _, ran in
                // After the first launch check, nudge the setup sheet only if something's missing.
                if ran && !setupChecker.allReady { showSetup = true }
            }
            .sheet(isPresented: $showSetup) {
                SetupChecklistView()
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
            .overlay(alignment: .bottomTrailing) { panicButton }
            .overlay(alignment: .top) { panicToast }
            .animation(.easeInOut(duration: 0.25), value: bannerVisible)
            .animation(.easeInOut(duration: 0.25), value: panicToastVisible)
            .onChange(of: session.isActive) { _, active in
                if active { flashBanner() } else { withAnimation { bannerVisible = false } }
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
