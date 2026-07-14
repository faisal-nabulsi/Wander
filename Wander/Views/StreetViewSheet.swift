//
//  StreetViewSheet.swift
//  Wander
//
//  Street View teleport — mirrors the desktop app (wander-desktop/src/templates/map.html):
//  a WKWebView loads the Google Maps JavaScript API and creates a StreetViewPanorama at
//  the selected coordinate. Tapping "Teleport here" reuses the app's existing teleport flow
//  (the `.teleportToRequested` notification that LocationSimulationView already handles),
//  so there is no duplicated simulate_location logic here.
//
//  Dependency-light by design: no GoogleMaps SDK, no SPM/CocoaPods — just a WKWebView
//  loading remote JS, exactly like the desktop build.
//

import SwiftUI
import WebKit
import CoreLocation

// MARK: - Maps API key configuration

/// Reads the Google Maps JavaScript API key from a gitignored config file bundled with the app.
/// Mirrors the desktop app's pattern: `Resources/config.json` -> `{ "google_maps_key": "..." }`.
/// A committed `config.example.json` documents the shape; the real `config.json` is gitignored.
enum WanderMapsConfig {
    private struct Payload: Decodable {
        let google_maps_key: String?
    }

    /// The configured key, trimmed. Empty string when unset (which HIDES the Street View entry point).
    static let googleMapsKey: String = {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return ""
        }
        return (payload.google_maps_key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// True only when a non-blank key is available.
    static var hasGoogleMapsKey: Bool { !googleMapsKey.isEmpty }
}

// MARK: - WKWebView wrapper

/// A `WKWebView` that renders a Google StreetViewPanorama for a single coordinate.
private struct StreetViewWebView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let apiKey: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Enable JavaScript (Google Maps JS API requires it).
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

    func updateUIView(_ webView: WKWebView, context: Context) {
        // The sheet is presented per-selection, so the coordinate is fixed for a given
        // presentation. Nothing to update here.
    }

    /// Builds the self-contained HTML that loads the Maps JS API and shows the panorama.
    /// Mirrors the desktop app's Street View block (getPanorama + StreetViewPanorama).
    private func html(for coordinate: CLLocationCoordinate2D, apiKey: String) -> String {
        // JSON-encode values so they are safely embedded in the JS source.
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

            // Called by the Google Maps script tag once the API has loaded.
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
              // Safety net for flaky/offline networks where a stalled script never fires onerror:
              // if the Maps API hasn't invoked our callback within 15s, show the offline note
              // instead of spinning on "Loading Street View…" forever.
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
        // JSONSerialization gives us `["..."]`; strip the array brackets to get the literal.
        if let data, data.hasPrefix("["), data.hasSuffix("]") {
            return String(data.dropFirst().dropLast())
        }
        return "\"\""
    }
}

// MARK: - Sheet

/// A sheet showing the Street View panorama for `coordinate`, with a "Teleport here" action
/// that reuses the app's existing simulate flow via `.teleportToRequested`.
struct StreetViewSheet: View {
    let coordinate: CLLocationCoordinate2D

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StreetViewWebView(coordinate: coordinate, apiKey: WanderMapsConfig.googleMapsKey)
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
    }

    /// Reuse the existing teleport path: LocationSimulationView listens for `.teleportToRequested`
    /// and runs the same `simulate_location(...)` flow (applySelection + simulate).
    private func teleport() {
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        dismiss()
    }
}
