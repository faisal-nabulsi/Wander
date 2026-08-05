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
//  It also carries two affordances the SwiftUI map already had and this one didn't:
//
//    * a LAYER SWITCHER (standard / satellite / hybrid), OPT-IN via `showsStyleSwitcher`.
//      Satellite is the fastest way to check that a chosen spot is a street and not a rooftop,
//      a lake or a motorway median. It reads and writes the SAME "mapStyleMode" preference the
//      online map uses, so the choice is one app-wide setting rather than a per-surface
//      surprise — which is also why it defaults to OFF: a host that floats its own control over
//      this map (MapSelectionView) would otherwise show two live controls for one stored value.
//      Note that Apple's satellite/hybrid imagery is a NETWORK resource; with no connection the
//      cached tiles keep drawing and the menu says why.
//
//    * the REPORTED-LOCATION DOT. While a spoof is running, CoreLocation hands this app the
//      spoofed position like any other app, so the dot is live confirmation that the spoof
//      took — not the user's true position. Every string here says so.
//

import SwiftUI
import MapKit
import CoreLocation

/// Reads — and only reads — the app's location authorization, and tells anyone who cares when it
/// changes.
///
/// Two reasons this is a shared singleton rather than a manager per map:
///   * Creating a CLLocationManager never prompts; only `requestWhenInUseAuthorization` does, and
///     nothing here ever calls it. The dot is a passenger on permission the app already holds.
///   * `authorizationStatus` is a snapshot. Without the delegate, a user who granted permission in
///     another sheet while a map was on screen kept a disabled dot until SwiftUI happened to
///     re-render. The delegate turns that into a push.
final class MapLocationAuthWatcher: NSObject, CLLocationManagerDelegate {
    static let shared = MapLocationAuthWatcher()

    /// Posted whenever CoreLocation reports an authorization change. Observers re-read `status`.
    static let didChange = Notification.Name("WanderMapLocationAuthDidChange")

    private let manager = CLLocationManager()

    private override init() {
        super.init()
        // Setting the delegate makes CoreLocation deliver the current status immediately, which
        // is exactly the priming call we want.
        manager.delegate = self
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    var isAuthorized: Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

struct OfflineMapView: UIViewRepresentable {
    /// The currently-selected coordinate (long-press to set). Nil until the user picks a spot.
    @Binding var selectedCoordinate: CLLocationCoordinate2D?

    /// The region the map should show. The parent updates this to fit saved regions, etc.
    @Binding var region: MKCoordinateRegion

    /// When true, the overlay serves only cached tiles (offline preview) — no network.
    var cacheOnly: Bool

    /// Reports the map's region as the user pans, so the parent's center-crosshair placement
    /// ("Set pin here") keeps working while this offline map is the active surface.
    var onRegionChange: ((MKCoordinateRegion) -> Void)?

    /// Draw the floating layer button on the map itself.
    ///
    /// OPT-IN, and off by default, because a host may already float its own style control over
    /// this map: MapSelectionView does exactly that (its own menu, top-trailing, as a ZStack
    /// sibling), so a default-on button here would put two live style controls on one screen.
    /// They'd also disagree — the host's picker writes the SELECTED mode while this map can only
    /// render the EFFECTIVE one — which is worse than a missing button. A host with no control of
    /// its own (OfflineMapsSheet) passes true.
    ///
    /// When shown it sits top-LEADING, so even a host that opts in on top of its own trailing
    /// control gets two reachable buttons rather than one under the other.
    var showsStyleSwitcher: Bool

    /// The app-wide map imagery preference, shared with the online map so switching here is
    /// not a second, divergent setting.
    @AppStorage("mapStyleMode") private var mapStyleModeRaw = MapStyleMode.standard.rawValue

    /// Whether to draw the reported-location dot. Persisted so a user who finds it noisy
    /// (or who doesn't want it in a screen recording) only turns it off once.
    @AppStorage("offlineMapShowsReportedLocation") private var showsReportedLocation = true

    init(
        selectedCoordinate: Binding<CLLocationCoordinate2D?>,
        region: Binding<MKCoordinateRegion>,
        cacheOnly: Bool,
        onRegionChange: ((MKCoordinateRegion) -> Void)? = nil,
        showsStyleSwitcher: Bool = false
    ) {
        self._selectedCoordinate = selectedCoordinate
        self._region = region
        self.cacheOnly = cacheOnly
        self.onRegionChange = onRegionChange
        self.showsStyleSwitcher = showsStyleSwitcher
    }

    private var mapStyleMode: MapStyleMode {
        MapStyleMode(rawValue: mapStyleModeRaw) ?? .standard
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.setRegion(region, animated: false)

        context.coordinator.applyStyle(mapStyleMode, cacheOnly: cacheOnly, on: mapView)
        context.coordinator.applyUserLocation(showsReportedLocation, on: mapView)
        context.coordinator.startObservingAuthorization(on: mapView)

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.35
        mapView.addGestureRecognizer(longPress)

        if showsStyleSwitcher {
            context.coordinator.installStyleButton(on: mapView)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Imagery + tile overlay in one place: which of the two draws the ground depends on
        // the chosen style, so they can't be decided independently.
        context.coordinator.applyStyle(mapStyleMode, cacheOnly: cacheOnly, on: mapView)
        context.coordinator.applyUserLocation(showsReportedLocation, on: mapView)
        context.coordinator.refreshStyleButton()

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

        /// What is actually on screen right now, which is not always what the user picked:
        /// satellite and hybrid are Apple's imagery and need the network, so offline they
        /// fall back to the cached tiles. Tracking the EFFECTIVE mode is what stops
        /// updateUIView from tearing the map down and rebuilding it on every redraw.
        private var appliedMode: MapStyleMode?
        private var appliedCacheOnly: Bool?
        private var styleButton: UIButton?
        private weak var mapView: MKMapView?
        private var authObserver: NSObjectProtocol?

        init(_ parent: OfflineMapView) {
            self.parent = parent
        }

        deinit {
            if let authObserver {
                NotificationCenter.default.removeObserver(authObserver)
            }
        }

        /// Watch for the user granting (or revoking) location permission while this map is on
        /// screen — from another sheet, or from Settings and back. Without this the dot and its
        /// menu entry stayed disabled until something else happened to trigger a redraw.
        func startObservingAuthorization(on mapView: MKMapView) {
            guard authObserver == nil else { return }
            authObserver = NotificationCenter.default.addObserver(
                forName: MapLocationAuthWatcher.didChange,
                object: nil,
                queue: .main
            ) { [weak self, weak mapView] _ in
                guard let self, let mapView else { return }
                self.applyUserLocation(self.parent.showsReportedLocation, on: mapView)
                self.refreshStyleButton()
            }
        }

        // MARK: Style

        /// Satellite/hybrid draw Apple's imagery, which is a network resource. In cache-only
        /// preview, or with no internet, that would be an empty grid — so the cached tiles
        /// stay on and the menu says why.
        static func imageryAvailable(cacheOnly: Bool) -> Bool {
            !cacheOnly && NetworkReachability.hasInternetSnapshot
        }

        private static func effectiveMode(_ mode: MapStyleMode, cacheOnly: Bool) -> MapStyleMode {
            guard mode != .standard else { return .standard }
            return imageryAvailable(cacheOnly: cacheOnly) ? mode : .standard
        }

        func applyStyle(_ mode: MapStyleMode, cacheOnly: Bool, on mapView: MKMapView) {
            self.mapView = mapView
            let effective = Self.effectiveMode(mode, cacheOnly: cacheOnly)
            guard effective != appliedMode || cacheOnly != appliedCacheOnly else { return }

            switch effective {
            case .standard:
                mapView.preferredConfiguration = MKStandardMapConfiguration()
                // Swap in a FRESH overlay instance rather than flipping the flag on the
                // existing one: MapKit keeps the tiles it already rendered online and won't
                // re-request them for the same overlay object (even after a remove/re-add),
                // so the offline toggle looked like it did nothing. A brand-new instance
                // forces loadTile for every visible tile again.
                if let old = overlay {
                    mapView.removeOverlay(old)
                }
                let fresh = WanderTileOverlay()
                fresh.cacheOnly = cacheOnly
                mapView.addOverlay(fresh, level: .aboveLabels)
                overlay = fresh

            case .satellite, .hybrid:
                // The tile overlay declares canReplaceMapContent, so it hides Apple's imagery
                // completely. It has to come off for satellite to be visible at all.
                if let old = overlay {
                    mapView.removeOverlay(old)
                    overlay = nil
                }
                mapView.preferredConfiguration = effective == .satellite
                    ? MKImageryMapConfiguration()
                    : MKHybridMapConfiguration()
            }

            appliedMode = effective
            appliedCacheOnly = cacheOnly
            refreshStyleButton()
        }

        // MARK: Reported-location dot

        /// True only when the app ALREADY holds location permission. Never requests it: a map
        /// that pops a system prompt the moment it appears is a map that gets denied, and the
        /// dot is a nicety, not a reason to spend the app's one shot at that alert.
        static var hasLocationPermission: Bool {
            MapLocationAuthWatcher.shared.isAuthorized
        }

        func applyUserLocation(_ wanted: Bool, on mapView: MKMapView) {
            let shouldShow = wanted && Self.hasLocationPermission
            if mapView.showsUserLocation != shouldShow {
                mapView.showsUserLocation = shouldShow
            }
        }

        /// Name the dot for what it actually is. While a spoof is active CoreLocation reports
        /// the SPOOFED position to every app including this one, so this is "where the system
        /// says you are" — useful precisely because it confirms the spoof took.
        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            userLocation.title = L("offline.map.user_dot.title",
                                   fallback: "Where your device reports you are")
            userLocation.subtitle = L("offline.map.user_dot.subtitle",
                                      fallback: "Follows your spoof while one is running")
        }

        // MARK: Floating layer button

        func installStyleButton(on mapView: MKMapView) {
            self.mapView = mapView
            guard styleButton == nil else { return }

            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tintColor = UIColor(Wander.brand)
            button.backgroundColor = .clear
            button.showsMenuAsPrimaryAction = true
            button.accessibilityLabel = L("map.style.title", fallback: "Map style")

            // Same visual language as the SwiftUI floating controls: a material chip with a
            // hairline border, 44pt so it clears the tap-target minimum.
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.isUserInteractionEnabled = false
            blur.layer.cornerRadius = 12
            blur.layer.cornerCurve = .continuous
            blur.clipsToBounds = true
            blur.layer.borderWidth = 0.5
            blur.layer.borderColor = UIColor.label.withAlphaComponent(0.06).cgColor
            button.insertSubview(blur, at: 0)

            mapView.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                button.topAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.topAnchor, constant: 8),
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
                blur.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                blur.topAnchor.constraint(equalTo: button.topAnchor),
                blur.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])

            styleButton = button
            refreshStyleButton()
        }

        /// Rebuild the icon and the menu. Cheap, and it has to happen on every update: whether
        /// satellite is even reachable depends on connectivity, which changes under us.
        ///
        /// The icon shows the SELECTED mode, not the effective one, and adds a "slash" tint when
        /// the selection can't currently be drawn. Showing the effective mode instead made this
        /// button silently contradict any other control bound to the same preference: pick
        /// Satellite offline and the other control flips to the globe while this one stayed on
        /// `map.fill`, so the two disagreed about a single stored value. Reporting the selection
        /// plus "not available right now" is one consistent story, and the menu subtitle already
        /// says why.
        func refreshStyleButton() {
            guard let button = styleButton else { return }
            let selected = parent.mapStyleMode
            let effective = Self.effectiveMode(selected, cacheOnly: parent.cacheOnly)
            let unavailable = effective != selected

            let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            button.setImage(UIImage(systemName: selected.symbol, withConfiguration: configuration), for: .normal)
            // Dimmed + a spoken suffix rather than a different glyph: the shape stays the one the
            // user chose, and VoiceOver gets the reason in words.
            button.tintColor = unavailable
                ? UIColor(Wander.brand).withAlphaComponent(0.45)
                : UIColor(Wander.brand)
            button.accessibilityLabel = unavailable
                ? "\(L("map.style.title", fallback: "Map style")): \(selected.label) — "
                    + L("map.style.needs_connection", fallback: "Satellite imagery needs a connection")
                : "\(L("map.style.title", fallback: "Map style")): \(selected.label)"
            button.menu = buildMenu(selected: selected)
        }

        private func buildMenu(selected: MapStyleMode) -> UIMenu {
            let imagery = Self.imageryAvailable(cacheOnly: parent.cacheOnly)

            let styleActions: [UIAction] = MapStyleMode.allCases.map { mode in
                let unavailable = mode != .standard && !imagery
                let action = UIAction(
                    title: mode.label,
                    image: UIImage(systemName: mode.symbol),
                    attributes: unavailable ? [.disabled] : [],
                    state: mode == selected ? .on : .off
                ) { [weak self] _ in
                    self?.selectStyle(mode)
                }
                if unavailable {
                    // Say why it's greyed out, in the place the user is looking.
                    action.subtitle = L("map.style.needs_connection",
                                        fallback: "Satellite imagery needs a connection")
                } else if mode == .standard {
                    action.subtitle = L("map.style.standard.offline_note",
                                        fallback: "Works offline from downloaded tiles")
                }
                return action
            }

            let dotAllowed = Self.hasLocationPermission
            let dotOn = parent.showsReportedLocation && dotAllowed
            let dotAction = UIAction(
                title: L("offline.map.user_dot.toggle", fallback: "Reported location dot"),
                image: UIImage(systemName: "location.fill"),
                attributes: dotAllowed ? [] : [.disabled],
                state: dotOn ? .on : .off
            ) { [weak self] _ in
                self?.toggleReportedLocation()
            }
            dotAction.subtitle = dotAllowed
                ? L("offline.map.user_dot.explainer",
                    fallback: "Where your device reports you are — your spoof, not your real spot")
                : L("offline.map.user_dot.no_permission",
                    fallback: "Turn on Location Services for Wander to use this")

            return UIMenu(children: [
                UIMenu(title: L("map.style.title", fallback: "Map style"),
                       options: [.displayInline],
                       children: styleActions),
                UIMenu(title: "", options: [.displayInline], children: [dotAction])
            ])
        }

        private func selectStyle(_ mode: MapStyleMode) {
            // Write through the same @AppStorage key the online map uses. SwiftUI observes
            // UserDefaults, so this re-runs updateUIView; applying it here too means the map
            // changes on the same frame as the tap instead of one hop later.
            parent.mapStyleModeRaw = mode.rawValue
            if let mapView {
                applyStyle(mode, cacheOnly: parent.cacheOnly, on: mapView)
            }
            refreshStyleButton()
        }

        private func toggleReportedLocation() {
            let wanted = !parent.showsReportedLocation
            parent.showsReportedLocation = wanted
            if let mapView {
                applyUserLocation(wanted, on: mapView)
            }
            refreshStyleButton()
        }

        // MARK: MKMapViewDelegate

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
