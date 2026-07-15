//
//  OfflineMapView.swift
//  Wander
//
//  A UIViewRepresentable wrapping a MapLibre Native `MLNMapView`, rendering a Protomaps
//  vector basemap (basemap v4) out of a PMTiles archive via MapLibre's built-in `pmtiles://`
//  protocol (native since MapLibre iOS 6.10). This fully replaces the old MKMapView +
//  MKTileOverlay OSM raster path.
//
//  This view is intentionally small and self-contained: it does NOT touch the shipping
//  SwiftUI Map in MapSelectionView. A long-press drops/moves the selection and reports the
//  coordinate up through a @Binding; the selection shows as a single annotation.
//
//  The map style is loaded from the bundled `protomaps-basemap-v4.json`, with its vector
//  source URL rewritten at runtime to `pmtiles://<OfflineMapConfig.pmTilesURL>` so we can
//  point at our own archive without editing the JSON.
//

import SwiftUI
import MapKit
import MapLibre

struct OfflineMapView: UIViewRepresentable {
    /// The currently-selected coordinate (long-press to set). Nil until the user picks a spot.
    @Binding var selectedCoordinate: CLLocationCoordinate2D?

    /// The region the map should show. The parent updates this to fit saved regions, etc.
    @Binding var region: MKCoordinateRegion

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: OfflineMapStyle.localStyleURL())
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.logoView.isHidden = false      // keep MapLibre attribution visible (OSM/Protomaps)
        mapView.setCenter(region.center,
                          zoomLevel: OfflineMapStyle.zoomLevel(for: region),
                          animated: false)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.35
        mapView.addGestureRecognizer(longPress)

        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // Re-center only when the parent moved the region meaningfully (avoids fighting the
        // user's own panning while they browse).
        if context.coordinator.shouldApplyRegion(region) {
            mapView.setCenter(region.center,
                              zoomLevel: OfflineMapStyle.zoomLevel(for: region),
                              animated: true)
        }

        context.coordinator.syncAnnotation(for: selectedCoordinate, on: mapView)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let parent: OfflineMapView
        private var selectionAnnotation: MLNPointAnnotation?
        private var lastAppliedRegion: MKCoordinateRegion?

        init(_ parent: OfflineMapView) {
            self.parent = parent
        }

        // MARK: MLNMapViewDelegate

        /// Let MapLibre render the default marker for our single selection pin.
        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            true
        }

        // MARK: Long-press to pick

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let mapView = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            // Report up on the main actor via the binding.
            DispatchQueue.main.async {
                self.parent.selectedCoordinate = coordinate
            }
        }

        /// Adds/moves/removes the single selection annotation to match the binding.
        func syncAnnotation(for coordinate: CLLocationCoordinate2D?, on mapView: MLNMapView) {
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
                let annotation = MLNPointAnnotation()
                annotation.coordinate = coordinate
                annotation.title = L("offline.map.selected_pin", fallback: "Selected")
                mapView.addAnnotation(annotation)
                selectionAnnotation = annotation
            }
        }

        /// Only re-apply the parent's region when it has changed by more than a tiny epsilon,
        /// so programmatic recentering doesn't stomp on the user's manual panning.
        func shouldApplyRegion(_ requested: MKCoordinateRegion) -> Bool {
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
