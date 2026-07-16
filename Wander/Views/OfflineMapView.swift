//
//  OfflineMapView.swift
//  Wander
//
//  A UIViewRepresentable wrapping a UIKit MKMapView so we can host an MKTileOverlay —
//  SwiftUI's native Map can't do that. The overlay (WanderTileOverlay) renders OSM tiles
//  from the on-disk cache, replacing Apple's base map entirely.
//
//  This view is intentionally small and self-contained: it does NOT touch the shipping
//  SwiftUI Map in MapSelectionView. A long-press drops/moves the selection and reports the
//  coordinate up through a @Binding; the selection shows as a single annotation.
//

import SwiftUI
import MapKit

struct OfflineMapView: UIViewRepresentable {
    /// The currently-selected coordinate (long-press to set). Nil until the user picks a spot.
    @Binding var selectedCoordinate: CLLocationCoordinate2D?

    /// The region the map should show. The parent updates this to fit saved regions, etc.
    @Binding var region: MKCoordinateRegion

    /// When true, the overlay serves only cached tiles (offline preview) — no network.
    var cacheOnly: Bool

    /// Reports the map's region as the user pans, so the parent's center-crosshair placement
    /// ("Set pin here") keeps working while this offline map is the active surface.
    var onRegionChange: ((MKCoordinateRegion) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.setRegion(region, animated: false)

        let overlay = WanderTileOverlay()
        overlay.cacheOnly = cacheOnly
        mapView.addOverlay(overlay, level: .aboveLabels)
        context.coordinator.overlay = overlay

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.35
        mapView.addGestureRecognizer(longPress)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        // Keep the overlay's offline mode in sync with the toggle.
        if context.coordinator.overlay?.cacheOnly != cacheOnly {
            context.coordinator.overlay?.cacheOnly = cacheOnly
            // Force a re-render so blank/real tiles swap when the mode flips.
            if let overlay = context.coordinator.overlay {
                mapView.removeOverlay(overlay)
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }

        // Re-center only when the parent moved the region meaningfully (avoids fighting the
        // user's own panning while they browse).
        if context.coordinator.shouldApplyRegion(region, on: mapView) {
            mapView.setRegion(region, animated: true)
        }

        context.coordinator.syncAnnotation(for: selectedCoordinate, on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OfflineMapView
        var overlay: WanderTileOverlay?
        private var selectionAnnotation: MKPointAnnotation?
        private var lastAppliedRegion: MKCoordinateRegion?

        init(_ parent: OfflineMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // User panned/zoomed: report the region up (and mark it applied so this write-back
            // doesn't bounce back through updateUIView as a re-center).
            lastAppliedRegion = mapView.region
            let region = mapView.region
            DispatchQueue.main.async { self.parent.onRegionChange?(region) }
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            // Report up on the main actor via the binding.
            DispatchQueue.main.async {
                self.parent.selectedCoordinate = coordinate
            }
        }

        /// Adds/moves/removes the single selection annotation to match the binding.
        func syncAnnotation(for coordinate: CLLocationCoordinate2D?, on mapView: MKMapView) {
            guard let coordinate else {
                if let existing = selectionAnnotation {
                    mapView.removeAnnotation(existing)
                    selectionAnnotation = nil
                }
                return
            }
            if let existing = selectionAnnotation {
                if existing.coordinate.latitude != coordinate.latitude ||
                    existing.coordinate.longitude != coordinate.longitude {
                    existing.coordinate = coordinate
                }
            } else {
                let annotation = MKPointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = L("offline.map.selected_pin", fallback: "Selected")
                mapView.addAnnotation(annotation)
                selectionAnnotation = annotation
            }
        }

        /// Only re-apply the parent's region when it has changed by more than a tiny epsilon,
        /// so programmatic recentering doesn't stomp on the user's manual panning.
        func shouldApplyRegion(_ requested: MKCoordinateRegion, on mapView: MKMapView) -> Bool {
            guard let last = lastAppliedRegion else {
                lastAppliedRegion = requested
                return false
            }
            let epsilon = 0.00001
            let changed =
                abs(last.center.latitude - requested.center.latitude) > epsilon ||
                abs(last.center.longitude - requested.center.longitude) > epsilon ||
                abs(last.span.latitudeDelta - requested.span.latitudeDelta) > epsilon ||
                abs(last.span.longitudeDelta - requested.span.longitudeDelta) > epsilon
            if changed {
                lastAppliedRegion = requested
            }
            return changed
        }
    }
}
