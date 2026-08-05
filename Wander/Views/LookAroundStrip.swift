//
//  LookAroundStrip.swift
//  Wander
//
//  A compact street-level preview of the pin, using Apple's own Look Around.
//
//  Why this exists: before teleporting somewhere, the single most useful question
//  is "what does this place actually look like?" — a pin in the middle of a lake,
//  a motorway or a private car park is the difference between a believable spoof
//  and an obvious one. Until now the only answer was StreetViewSheet, which is a
//  Google WKWebView, Pro-gated, and spends Worker API quota on every open.
//
//  Look Around costs nothing. It is native MapKit, needs no API key, no network
//  credential of ours and no paywall, so it goes to FREE users. Google Street View
//  stays exactly where it is as the Pro fallback for the (many) places Apple has
//  no coverage for.
//
//  The strip's most important behaviour is what it does when there is NO scene:
//  it disappears. Most coordinates on Earth have no Look Around imagery. That is
//  the normal case, not a failure, and an error row saying so on nine pins out of
//  ten would be noise the user can do nothing about.
//

import SwiftUI
import MapKit
import CoreLocation

struct LookAroundStrip: View {
    let coordinate: CLLocationCoordinate2D

    /// Height of the preview. Deliberately short: the map is the product and this
    /// card already competes with it for vertical space.
    var height: CGFloat = 96

    @State private var scene: MKLookAroundScene?
    /// Which coordinate `scene` belongs to, so a stale scene can never be shown
    /// beside a pin that has since moved.
    @State private var loadedKey: String?
    @State private var isLoading = false

    private var key: String {
        String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
    }

    var body: some View {
        Group {
            if let scene, loadedKey == key {
                LookAroundPreview(
                    initialScene: scene,
                    allowsNavigation: true,
                    showsRoadLabels: true,
                    badgePosition: .bottomTrailing
                )
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                )
                .accessibilityLabel(L("map.look_around.a11y",
                                      fallback: "Look Around preview of the pinned location"))
            } else if isLoading, loadedKey != key {
                // A short, quiet placeholder rather than a spinner: on a coordinate
                // with no coverage this row is about to vanish, and a spinner that
                // resolves into nothing reads as a failure.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: height)
                    .overlay(
                        Text(L("map.look_around.loading", fallback: "Checking street view…"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    )
                    .accessibilityHidden(true)
            }
        }
        .task(id: key) { await load(for: key) }
    }

    /// Ask MapKit whether it has a scene here. A nil scene and a thrown error are
    /// treated identically — both mean "nothing to show", and neither is worth
    /// telling the user about.
    private func load(for requestedKey: String) async {
        // Drop the previous pin's imagery immediately; showing Paris beside a Tokyo
        // pin for the half-second the request takes would be a lie about the target.
        if loadedKey != requestedKey {
            scene = nil
        }
        isLoading = true
        defer { isLoading = false }

        let request = MKLookAroundSceneRequest(coordinate: coordinate)
        let resolved = try? await request.scene

        // The pin can move while the request is in flight; only the latest wins.
        guard !Task.isCancelled, requestedKey == key else { return }
        scene = resolved
        loadedKey = requestedKey
    }
}
