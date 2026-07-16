//
//  StreetViewSheet.swift
//  Wander
//
//  Street View teleport. The Google Maps key is NO LONGER bundled in the app — it lives as a
//  Cloudflare Worker secret. On open, this sheet asks the Worker (POST /streetview/key,
//  authenticated with the account's Firebase idToken) for the key; the Worker returns it ONLY
//  to a Pro account that is under the daily cap. So a free user never receives the key, the
//  per-user/day quota caps the paid Maps API bill, and the key never ships in the binary.
//
//  The panorama itself is still a dependency-light WKWebView loading the Maps JS API (no
//  GoogleMaps SDK / SPM / CocoaPods), exactly like the desktop build — only the key's origin
//  changed (server-fetched instead of bundled).
//

import SwiftUI
import WebKit
import CoreLocation

// MARK: - Server-side key provider (Pro + quota gated)

/// The result of asking the Worker for the Street View key.
enum StreetViewAccess: Equatable {
    case key(String)            // authorized — render the panorama
    case proRequired            // 403 — Pro-only feature
    case dailyLimit(String)     // 429 — used today's allowance
    case unavailable(String)    // 503 / transport / other, with a friendly message

    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// Ask the Worker for the Maps key. Pro-only + quota-capped, enforced server-side.
    static func fetchKey() async -> StreetViewAccess {
        guard await NetworkReachability.shared.isOnline else {
            return .unavailable("Street View needs an internet connection.")
        }
        // Same idToken path the trial/AI/sync features use. No sign-in → not Pro → upsell.
        guard let token = await WanderProAccount.shared.currentIdToken() else {
            return .proRequired
        }
        var out = await post(idToken: token)
        // A 401 means the short-lived idToken expired mid-flight — mint a fresh one, retry once.
        if out.status == 401, let fresh = await WanderProAccount.shared.refreshedIdToken() {
            out = await post(idToken: fresh)
        }
        return out.access
    }

    private static func post(idToken: String) async -> (access: StreetViewAccess, status: Int) {
        guard let url = URL(string: "\(baseURL)/streetview/key"),
              let httpBody = try? JSONSerialization.data(withJSONObject: ["idToken": idToken]) else {
            return (.unavailable("Couldn't build the Street View request."), -1)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch status {
            case 200:
                if let key = (obj?["key"] as? String), !key.isEmpty {
                    return (.key(key), 200)
                }
                return (.unavailable("Street View is temporarily unavailable."), 200)
            case 403: return (.proRequired, 403)
            case 429: return (.dailyLimit("You've reached today's Street View limit — try again tomorrow."), 429)
            case 401: return (.unavailable("Please sign in again."), 401)
            case 503: return (.unavailable("Street View isn't available right now."), 503)
            default:  return (.unavailable("Street View is temporarily unavailable."), status)
            }
        } catch {
            return (.unavailable("Couldn't reach Street View — check your connection."), -1)
        }
    }
}

// MARK: - WKWebView wrapper

/// A `WKWebView` that renders a Google StreetViewPanorama for a single coordinate.
private struct StreetViewWebView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let apiKey: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        // Load over a stable base URL so the Maps key's HTTP-referrer restriction can match.
        webView.loadHTMLString(html(for: coordinate, apiKey: apiKey),
                               baseURL: URL(string: "https://wanderspoofer.com"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Builds the self-contained HTML that loads the Maps JS API and shows the panorama.
    private func html(for coordinate: CLLocationCoordinate2D, apiKey: String) -> String {
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        let keyJS = jsString(apiKey)

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: #0d0d0f; }
          #pano { position: absolute; inset: 0; }
          #msg {
            position: absolute; inset: 0; display: none;
            align-items: center; justify-content: center;
            padding: 24px; box-sizing: border-box; text-align: center;
            color: #e8e8ea; font: 16px/1.4 -apple-system, system-ui, sans-serif;
          }
        </style>
        </head>
        <body>
          <div id="pano"></div>
          <div id="msg">Loading Street View…</div>
          <script>
            var LAT = \(lat), LNG = \(lng);
            var panoEl = document.getElementById('pano');
            var msgEl = document.getElementById('msg');

            function showMessage(text) {
              panoEl.style.display = 'none';
              msgEl.textContent = text;
              msgEl.style.display = 'flex';
            }

            window.init = function() {
              try {
                var svc = new google.maps.StreetViewService();
                var pano = new google.maps.StreetViewPanorama(panoEl, {
                  addressControl: false,
                  fullscreenControl: false,
                  motionTrackingControl: false,
                  zoomControl: true
                });
                svc.getPanorama({ location: { lat: LAT, lng: LNG }, radius: 120 }, function(data, status) {
                  if (status === google.maps.StreetViewStatus.OK && data && data.location) {
                    try {
                      pano.setPano(data.location.pano);
                      pano.setVisible(true);
                    } catch (e) {}
                    msgEl.style.display = 'none';
                    panoEl.style.display = 'block';
                  } else {
                    showMessage('No Street View imagery near here — try a road or a built-up area.');
                  }
                });
              } catch (e) {
                showMessage('Street View failed to load — check the Maps API key restrictions.');
              }
            };

            (function() {
              var loaded = false;
              var timeout = setTimeout(function() {
                if (!loaded) {
                  showMessage('Street View needs an internet connection — check your connection and try again.');
                }
              }, 15000);
              var priorInit = window.init;
              window.init = function() {
                loaded = true;
                clearTimeout(timeout);
                if (priorInit) { priorInit(); }
              };

              var s = document.createElement('script');
              s.src = 'https://maps.googleapis.com/maps/api/js?key=' + encodeURIComponent(\(keyJS)) + '&callback=init';
              s.async = true;
              s.defer = true;
              s.onerror = function() {
                clearTimeout(timeout);
                showMessage('Could not load Google Maps — check the key and your connection.');
              };
              document.head.appendChild(s);
            })();
          </script>
        </body>
        </html>
        """
    }

    /// Encodes a Swift string as a JS string literal (handles quotes/backslashes safely).
    private func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value]))
            .flatMap { String(data: $0, encoding: .utf8) }
        if let data, data.hasPrefix("["), data.hasSuffix("]") {
            return String(data.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - Sheet

/// A sheet showing the Street View panorama for `coordinate`. The Maps key is fetched from the
/// Worker on appear (Pro + quota gated); a "Teleport here" action reuses the app's simulate flow.
struct StreetViewSheet: View {
    let coordinate: CLLocationCoordinate2D

    @Environment(\.dismiss) private var dismiss
    /// nil while the key request is in flight; set once the Worker responds.
    @State private var access: StreetViewAccess?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)

                WanderCard {
                    VStack(spacing: 10) {
                        Text(String(format: "%.5f,  %.5f", coordinate.latitude, coordinate.longitude))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)

                        WanderPrimaryButton(title: "Teleport here", icon: Wander.Icon.teleport) {
                            teleport()
                        }
                    }
                }
            }
            .background(.regularMaterial)
            .navigationTitle("Street View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if access == nil { access = await StreetViewAccess.fetchKey() }
        }
    }

    @ViewBuilder private var content: some View {
        switch access {
        case .none:
            ProgressView("Loading Street View…")
        case .key(let key):
            StreetViewWebView(coordinate: coordinate, apiKey: key)
        case .proRequired:
            statusView("Street View is a Wander Pro feature.", systemImage: "lock.fill")
        case .dailyLimit(let message), .unavailable(let message):
            statusView(message, systemImage: "exclamationmark.triangle")
        }
    }

    private func statusView(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
    }

    /// Reuse the existing teleport path (LocationSimulationView handles `.teleportToRequested`).
    private func teleport() {
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        dismiss()
    }
}
