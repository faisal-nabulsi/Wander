//
//  GlobeSheet.swift
//  Wander
//
//  3D globe teleport (FREE) — mirrors StreetViewSheet.swift, but instead of building
//  HTML locally it embeds the already-hosted globe.gl page at
//  https://wanderspoofer.com/globe/ in a WKWebView (exactly like the Street View WebView
//  loads remote JS). The page delivers a tapped coordinate to the host via a
//  `wanderGlobe` script message ({lat,lng}); the host teleports through the app's existing
//  simulate flow (the `.teleportToRequested` notification that LocationSimulationView
//  already handles) and dismisses the sheet.
//
//  Needs internet: the page pulls globe.gl from a CDN, same as Street View pulls the Maps JS.
//

import SwiftUI
import WebKit
import CoreLocation

// MARK: - WKWebView wrapper

/// A `WKWebView` that loads the hosted 3D globe and forwards tap coordinates to the host.
private struct GlobeWebView: UIViewRepresentable {
    /// Called on the main actor with the tapped coordinate.
    let onPick: (CLLocationCoordinate2D) -> Void
    /// Toggled true when the page fails to load (offline / CDN unreachable), so the sheet can
    /// show a calm "needs internet" note over the blank WebView instead of a white void.
    @Binding var loadFailed: Bool
    /// Bumping this triggers a reload (used by the "Try again" button).
    let reloadToken: Int

    /// The hosted globe.gl page (do NOT rebuild — just embed the URL).
    private static let globeURL = URL(string: "https://wanderspoofer.com/globe/")!

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, loadFailed: $loadFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        // The page calls window.webkit.messageHandlers.wanderGlobe.postMessage({lat,lng}).
        configuration.userContentController.add(context.coordinator, name: "wanderGlobe")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.load(URLRequest(url: Self.globeURL, timeoutInterval: 20))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // A change in reloadToken means the user asked to retry — clear the failure flag and reload.
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.load(URLRequest(url: Self.globeURL, timeoutInterval: 20))
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Break the retain cycle the message handler otherwise holds on the web view.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "wanderGlobe")
    }

    /// Receives the `wanderGlobe` messages the page posts and extracts {lat,lng}, and observes
    /// navigation so a failed load surfaces a calm note rather than a blank screen.
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onPick: (CLLocationCoordinate2D) -> Void
        private let loadFailed: Binding<Bool>
        var lastReloadToken = 0

        init(onPick: @escaping (CLLocationCoordinate2D) -> Void, loadFailed: Binding<Bool>) {
            self.onPick = onPick
            self.loadFailed = loadFailed
        }

        // MARK: WKNavigationDelegate — offline / CDN-unreachable handling

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if loadFailed.wrappedValue { loadFailed.wrappedValue = false }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            loadFailed.wrappedValue = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadFailed.wrappedValue = true
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "wanderGlobe",
                  let body = message.body as? [String: Any] else { return }

            // Accept either numbers or numeric strings for lat/lng.
            func number(_ value: Any?) -> Double? {
                if let d = value as? Double { return d }
                if let n = value as? NSNumber { return n.doubleValue }
                if let s = value as? String { return Double(s) }
                return nil
            }

            guard let lat = number(body["lat"]),
                  let lng = number(body["lng"]) ?? number(body["lon"]) ?? number(body["long"]),
                  (-90.0...90.0).contains(lat),
                  (-180.0...180.0).contains(lng) else { return }

            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            DispatchQueue.main.async { [onPick] in
                onPick(coordinate)
            }
        }
    }
}

// MARK: - Sheet

/// A full-screen sheet showing the 3D globe. Tapping the globe teleports to the tapped
/// coordinate (reusing the app's existing simulate flow) and dismisses.
struct GlobeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var loadFailed = false
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            ZStack {
                GlobeWebView(onPick: { coordinate in
                    teleport(to: coordinate)
                }, loadFailed: $loadFailed, reloadToken: reloadToken)

                if loadFailed {
                    offlineNote
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .background(Color(red: 0.05, green: 0.05, blue: 0.06))
            .navigationTitle(L("globe.title", fallback: "Globe"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
    }

    /// Shown over the (blank) WebView when the globe can't load — offline or the CDN is
    /// unreachable. One calm message plus a retry, never a white void.
    private var offlineNote: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L("globe.offline",
                   fallback: "The 3D globe needs an internet connection to load."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("action.try_again", fallback: "Try again")) {
                reloadToken += 1
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
    }

    /// Reuse the existing teleport path: LocationSimulationView listens for
    /// `.teleportToRequested` and runs the same simulate flow (applySelection + simulate).
    private func teleport(to coordinate: CLLocationCoordinate2D) {
        SavedPlacesStore.recordRecent(coordinate, name: "Globe pick")
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        dismiss()
    }
}
