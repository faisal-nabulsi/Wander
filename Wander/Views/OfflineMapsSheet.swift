//
//  OfflineMapsSheet.swift
//  Wander
//
//  The Offline Maps screen (parity with the Android osmdroid offline flow). Free feature.
//
//  What it does, all self-contained (it never touches the shipping SwiftUI Map):
//    - Shows an OfflineMapView (UIKit MKMapView + WanderTileOverlay rendering OSM tiles).
//    - "Download this area": pick a zoom depth, see the tile-count + MB estimate (with a
//      warning when it's large), a progress bar while downloading, and a Cancel.
//    - Lists saved offline regions with their sizes, each swipe-to-delete.
//    - Shows total cache size + "Delete all".
//    - "Teleport here" on the long-pressed coordinate, using the SAME low-level simulate
//      path every other mode uses, so the global banner / Stop / panic all apply.
//
//  Presented like the app's other sheets (StreetViewSheet / GlobeSheet).
//

import SwiftUI
import MapKit

struct OfflineMapsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reachability = NetworkReachability.shared
    /// Turns the saved rows from coordinates into places. Observed so a row renames itself the
    /// moment the shared geocoder answers, without this screen polling anything.
    @ObservedObject private var placeLabels = PlaceLabelService.shared

    private let store = OfflineTileStore.shared

    /// THE LIVE CAMERA, kept in step with the map by `onRegionChange`.
    ///
    /// It used to be a one-way write: the sheet handed the map a hardcoded San Francisco and never
    /// heard back, so this stayed at San Francisco forever while the user panned. Two bugs fell out
    /// of that, both reported. Anything that re-rendered the sheet — finishing a download, toggling
    /// offline preview — ran `updateUIView`, which saw the map sitting somewhere this value had
    /// never heard of and "corrected" the camera back to San Francisco. And "Download this area"
    /// downloaded THIS region, not the one on screen, which is why every saved row was named
    /// "37.775, -122.419". Keep the two in step and both symptoms go away at the source.
    @State private var region = OfflineMapsSheet.initialRegion()
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var cacheOnly = false

    /// What the tile overlay can actually draw right now, and the delayed commit that keeps a
    /// mid-pan flicker from flashing a warning.
    @State private var coverage: WanderTileOverlay.Coverage = .exact
    @State private var coverageCommit: Task<Void, Never>?

    /// Bumped after a delete so the map re-asks for its tiles. Without it MapKit keeps drawing the
    /// tiles it already has and a delete looks like it did nothing.
    @State private var tileReloadToken = 0

    // Download configuration + progress.
    @State private var downloadDepth = 2              // extra zoom levels above the current view.
    @State private var estimate: OfflineDownloadEstimate?
    @State private var isDownloading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var progressDone = 0
    @State private var progressTotal = 0

    // Saved regions + cache size.
    @State private var savedRegions: [OfflineRegion] = []
    @State private var totalCacheBytes: Int64 = 0

    // Alerts.
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showDeleteAllConfirm = false

    private var pairingPath: String {
        PairingFileStore.prepareURL().path
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingPath)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                OfflineMapView(
                    selectedCoordinate: $selectedCoordinate,
                    region: $region,
                    cacheOnly: cacheOnly,
                    tileReloadToken: tileReloadToken,
                    onRegionChange: { moved, _ in
                        // Track the user's pan/zoom. The second argument is the lifted-crosshair
                        // drop point, which this screen doesn't use — it long-presses to select and
                        // draws the BARE crosshair, so there is no lift to honour.
                        trackCamera(moved)
                    },
                    onCoverageChange: { noteCoverage($0) },
                    // This screen floats no style control of its own, so the map draws one.
                    // (MapSelectionView does have one and therefore leaves this off.)
                    showsStyleSwitcher: true
                )
                .ignoresSafeArea()
                // Deliberately the bare crosshair, NOT `wanderMapCrosshair`: this is a SHEET, so
                // the tab bar and home indicator that MapModeChrome's lift reserves room for
                // aren't below it, and its card is content-sized rather than the canonical panel.
                // Borrowing the modes' lift here would aim ~50pt off. If this screen ever grows a
                // fixed panel, move it onto `wanderMapPanel()` + `wanderMapCrosshair()` together —
                // the two only stay in step because they come from the same number.
                .overlay(alignment: .center) {
                    if selectedCoordinate == nil { MapCrosshair() }
                }

                VStack(spacing: 8) {
                    if !reachability.isOnline {
                        offlinePill
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    coverageNotice
                    Spacer()
                    controlCard
                }
                .padding(.top, 8)
                .animation(.easeInOut(duration: 0.25), value: reachability.isOnline)
            }
            .navigationTitle(L("offline.maps.title", fallback: "Offline Maps"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.done", fallback: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $cacheOnly) {
                        Image(systemName: cacheOnly ? "wifi.slash" : "wifi")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(L("offline.maps.cache_only", fallback: "Offline preview"))
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button(L("common.ok", fallback: "OK"), role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .confirmationDialog(
                L("offline.maps.delete_all.confirm", fallback: "Delete all offline maps?"),
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button(L("offline.maps.delete_all", fallback: "Delete All"), role: .destructive) {
                    deleteAll()
                }
                Button(L("common.cancel", fallback: "Cancel"), role: .cancel) { }
            }
            .onAppear {
                refreshSavedRegions()
                refreshEstimate(for: region)
            }
            // The geocoder answers later and out of band; adopt names as they land.
            .onChange(of: placeLabels.labels.count) { _, _ in adoptResolvedNames() }
            .onDisappear {
                // Don't cancel a live teleport — but a half-finished *download* is fine to stop.
                downloadTask?.cancel()
                coverageCommit?.cancel()
            }
        }
    }

    // MARK: - Control card

    private var controlCard: some View {
        WanderCard {
            VStack(spacing: 12) {
                if let coordinate = selectedCoordinate {
                    selectionControls(coordinate)
                    Divider()
                }

                downloadControls

                if !savedRegions.isEmpty {
                    Divider()
                    savedRegionsList
                }
            }
        }
    }

    @ViewBuilder
    private func selectionControls(_ coordinate: CLLocationCoordinate2D) -> some View {
        Text(String(format: "%.5f,  %.5f", coordinate.latitude, coordinate.longitude))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)

        WanderPrimaryButton(
            title: L("offline.maps.teleport_here", fallback: "Teleport here"),
            icon: Wander.Icon.teleport
        ) {
            teleport(to: coordinate)
        }
        .disabled(!pairingExists)

        if !pairingExists {
            Text(L("offline.maps.pairing_needed",
                   fallback: "Import a pairing file in Settings to teleport."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        if isDownloading {
            VStack(spacing: 8) {
                ProgressView(
                    value: Double(progressDone),
                    total: Double(max(progressTotal, 1))
                )
                Text(L("offline.maps.downloading",
                       fallback: "Downloading \(progressDone) / \(progressTotal) tiles…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    cancelDownload()
                } label: {
                    Label(L("common.cancel", fallback: "Cancel"), systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        } else {
            VStack(spacing: 10) {
                HStack {
                    Text(L("offline.maps.detail", fallback: "Detail"))
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $downloadDepth) {
                        Text(L("offline.maps.depth.low", fallback: "Standard")).tag(1)
                        Text(L("offline.maps.depth.medium", fallback: "Detailed")).tag(2)
                        Text(L("offline.maps.depth.high", fallback: "Max")).tag(3)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 240)
                    .onChange(of: downloadDepth) { _, _ in refreshEstimate(for: region) }
                }

                if let estimate {
                    Text(estimateText(estimate))
                        .font(.caption)
                        .foregroundStyle(estimate.isLarge ? .orange : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if estimate.isLarge {
                        Label(
                            L("offline.maps.large_warning",
                              fallback: "That's a large download — it may take a while and use a lot of storage."),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                WanderPrimaryButton(
                    title: L("offline.maps.download_area", fallback: "Download this area"),
                    icon: "square.and.arrow.down"
                ) {
                    startDownload()
                }
            }
        }
    }

    /// Height cap for the saved-maps list once it's long enough to scroll. Keeps the control card
    /// (and the map behind it) visible no matter how many regions are saved.
    private let savedListMaxHeight: CGFloat = 220

    private var savedRegionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("offline.maps.saved", fallback: "Saved maps"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalCacheBytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // Short lists render inline; long lists scroll inside a fixed-height box so the card
            // can't grow until it covers the whole map. Header + Delete-all stay pinned.
            if savedRegions.count > 4 {
                ScrollView { savedRegionRows }
                    .frame(height: savedListMaxHeight)
            } else {
                savedRegionRows
            }

            Button(role: .destructive) {
                showDeleteAllConfirm = true
            } label: {
                Label(L("offline.maps.delete_all", fallback: "Delete all"), systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
    }

    private var savedRegionRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(savedRegions) { saved in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rowTitle(for: saved))
                            .font(.subheadline)
                        Text("\(saved.tileCount) tiles • \(ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        region = saved.region
                    } label: {
                        Image(systemName: "location.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("offline.maps.go_to_region", fallback: "Show on map"))

                    Button(role: .destructive) {
                        delete(saved)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L("common.delete", fallback: "Delete"))
                }
            }
        }
    }

    // MARK: - "What am I actually looking at"

    /// Explains a map that is blurry or empty, INSTEAD of leaving the user staring at MapKit's
    /// cream grid. The overlay replaces Apple's base map, so a tile it can't produce is a hole
    /// through to nothing — indistinguishable, on screen, from the app being broken.
    @ViewBuilder
    private var coverageNotice: some View {
        switch coverage {
        case .exact:
            EmptyView()
        case .approximate:
            noticePill(
                icon: "square.stack.3d.down.right",
                text: L("offline.maps.coverage.approximate",
                        fallback: "Lower-detail saved tiles — zoom out, or download this area")
            )
        case .none:
            noticePill(
                icon: "square.dashed",
                text: reachability.isOnline && !cacheOnly
                    ? L("offline.maps.coverage.none.online",
                        fallback: "No map tiles here yet — they're still loading")
                    : L("offline.maps.coverage.none",
                        fallback: "Nothing saved for this area — zoom out, or download it while online")
            )
        }
    }

    private func noticePill(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Commit a coverage verdict. Good news lands immediately; a warning waits, because a pan
    /// legitimately shows empty edge tiles for a moment and a banner that blinks on every gesture
    /// is worse than the thing it's warning about.
    private func noteCoverage(_ reported: WanderTileOverlay.Coverage) {
        coverageCommit?.cancel()
        guard reported != .exact else {
            withAnimation(.easeInOut(duration: 0.2)) { coverage = .exact }
            return
        }
        coverageCommit = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { coverage = reported }
        }
    }

    private var offlinePill: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash").font(.caption2)
            Text(L("offline.badge", fallback: "Offline — showing saved maps"))
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }

    // MARK: - Camera

    /// The map moved. Keep `region` in step so nothing later "corrects" the camera back to a stale
    /// value, refresh the estimate against what is genuinely on screen, and remember where we were
    /// for the next time this sheet opens.
    private func trackCamera(_ moved: MKCoordinateRegion) {
        guard CLLocationCoordinate2DIsValid(moved.center) else { return }
        region = moved
        // Estimate against `moved` explicitly rather than re-reading `region`: the estimate must
        // describe what is on screen, and passing it removes any doubt about read-after-write.
        refreshEstimate(for: moved)
        Self.rememberCamera(moved)
    }

    /// Where the map opens, best available first. The hardcoded city is the LAST resort — it used
    /// to be the only rule, which is why a screen the owner had panned to another county kept
    /// announcing itself as San Francisco.
    ///
    /// Nothing here is main-actor isolated, so it can run in the `@State` initialiser and the map
    /// is built already pointing the right way — no visible jump on the first frame.
    static func initialRegion() -> MKCoordinateRegion {
        // 1. Where the app's map actually is: the live/last spoof target, as SimulationSession
        //    persists it on every confirmed teleport (and clears on a clean Stop).
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "resume.wasSpoofing") {
            let coordinate = CLLocationCoordinate2D(
                latitude: defaults.double(forKey: "resume.lat"),
                longitude: defaults.double(forKey: "resume.lng")
            )
            if CLLocationCoordinate2DIsValid(coordinate), coordinate.latitude != 0 || coordinate.longitude != 0 {
                return neighbourhood(around: coordinate)
            }
        }

        // 2. Where this sheet was left last time.
        if let remembered = rememberedCamera() { return remembered }

        // 3. The newest thing the user actually saved — by definition an area they care about.
        if let newest = OfflineTileStore.shared.loadRegions().first { return newest.region }

        // 4. The device's own last fix, if the app already holds permission. Never prompts.
        if let fix = MapLocationAuthWatcher.shared.lastKnownLocation {
            return neighbourhood(around: fix.coordinate)
        }

        // 5. Nothing to go on.
        return fallbackRegion
    }

    private static let fallbackRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )

    /// A download-sized window around a point: wide enough that "Download this area" is a useful
    /// amount of map, tight enough that the estimate isn't hundreds of megabytes.
    private static func neighbourhood(around coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)
    }

    private static let cameraKey = "offlineMaps.lastCamera"

    /// The widest camera worth restoring, in degrees (~550 km — a large metro region).
    ///
    /// MEASURED, and the reason this cap exists at all: a user who pinches all the way out leaves
    /// the camera at a world view, and restoring that put the screen back on the empty grid every
    /// time the sheet opened. Worse, MapKit stops asking the overlay for tiles once the map is
    /// zoomed out past the world — verified with a trace on `loadTile`, which logged nothing at
    /// all at that camera — so the substitution and the "nothing saved here" notice never even got
    /// a chance to run. A world view is also not a downloadable area, so it is never the right
    /// thing to reopen on.
    private static let maxRememberedSpan: CLLocationDegrees = 5

    private static func rememberCamera(_ region: MKCoordinateRegion) {
        guard region.span.latitudeDelta <= maxRememberedSpan,
              region.span.longitudeDelta <= maxRememberedSpan else { return }
        UserDefaults.standard.set(
            [region.center.latitude, region.center.longitude,
             region.span.latitudeDelta, region.span.longitudeDelta],
            forKey: cameraKey
        )
    }

    private static func rememberedCamera() -> MKCoordinateRegion? {
        guard let stored = UserDefaults.standard.array(forKey: cameraKey) as? [Double],
              stored.count == 4 else { return nil }
        let center = CLLocationCoordinate2D(latitude: stored[0], longitude: stored[1])
        guard CLLocationCoordinate2DIsValid(center), stored[2] > 0, stored[3] > 0 else { return nil }
        // Clamp on the way out too, so a value written by an older build can't strand the map.
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min(stored[2], maxRememberedSpan),
                longitudeDelta: min(stored[3], maxRememberedSpan)
            )
        )
    }

    // MARK: - Estimate

    /// Maps a visible map region + chosen depth into a min/max zoom range for the store.
    private func zoomRange(for region: MKCoordinateRegion) -> (min: Int, max: Int) {
        // Approximate the map's current zoom from the longitude span.
        let span = max(region.span.longitudeDelta, 0.0001)
        let approxZoom = Int((log2(360.0 / span)).rounded())
        let baseZoom = min(max(approxZoom, 1), OfflineTileStore.maxZoomCap)
        let maxZoom = min(baseZoom + downloadDepth, OfflineTileStore.maxZoomCap)
        // Start TWO levels below, not one. One pinch out past the saved floor is the single
        // easiest way to land on an empty screen, and two levels down is only ~1/16th the tiles of
        // the base level — the cheapest insurance in the whole feature.
        let minZoom = max(baseZoom - 2, 1)
        return (minZoom, maxZoom)
    }

    private func refreshEstimate(for region: MKCoordinateRegion) {
        let range = zoomRange(for: region)
        estimate = store.estimate(region: region, minZoom: range.min, maxZoom: range.max)
    }

    private func estimateText(_ estimate: OfflineDownloadEstimate) -> String {
        let size = ByteCountFormatter.string(fromByteCount: estimate.approximateBytes, countStyle: .file)
        return L("offline.maps.estimate",
                 fallback: "≈ \(estimate.tileCount) tiles • about \(size)")
    }

    // MARK: - Download

    private func startDownload() {
        // One snapshot of the camera, used for the estimate, the download and the row name — so
        // all three describe the same ground even if the map moves while this runs.
        let snapshot = region
        refreshEstimate(for: snapshot)

        guard reachability.isOnline else {
            alert(
                L("offline.download.offline.title", fallback: "You're offline"),
                L("offline.download.no_connection",
                  fallback: "Connect to Wi‑Fi or cellular, then download this area.")
            )
            return
        }

        let range = zoomRange(for: snapshot)
        let name = regionName(for: snapshot)

        isDownloading = true
        progressDone = 0
        progressTotal = store.estimate(region: snapshot, minZoom: range.min, maxZoom: range.max).tileCount

        downloadTask = Task {
            do {
                _ = try await store.downloadRegion(
                    name: name,
                    region: snapshot,
                    minZoom: range.min,
                    maxZoom: range.max
                ) { done, total in
                    Task { @MainActor in
                        progressDone = done
                        progressTotal = total
                    }
                }
                await MainActor.run {
                    isDownloading = false
                    downloadTask = nil
                    refreshSavedRegions()
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadTask = nil
                    // A partial region is still usable — keep whatever landed on disk.
                    refreshSavedRegions()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadTask = nil
                    refreshSavedRegions()
                    if let offlineError = error as? OfflineTileError, case .offline = offlineError {
                        alert(
                            L("offline.download.offline.title", fallback: "You're offline"),
                            error.localizedDescription
                        )
                    } else {
                        alert(
                            L("offline.download.failed.title", fallback: "Download interrupted"),
                            L("offline.download.failed.body",
                              fallback: "Some tiles couldn't be fetched. Anything downloaded is still available offline.")
                        )
                    }
                }
            }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        refreshSavedRegions()
    }

    /// The name a new save is written with: the place if the shared geocoder already knows it,
    /// coordinates if it doesn't. Either way the row gets renamed later by `adoptResolvedNames`,
    /// so this only has to be a reasonable first answer.
    private func regionName(for region: MKCoordinateRegion) -> String {
        placeLabels.label(for: region.center)?.title
            ?? String(format: "%.3f, %.3f", region.center.latitude, region.center.longitude)
    }

    // MARK: - Saved regions

    private func refreshSavedRegions() {
        savedRegions = store.loadRegions()
        // Ask for the names we don't have. `resolve` is cheap, idempotent and heavily rate-limited
        // inside the service, so calling it for every row on every refresh is fine.
        for saved in savedRegions where saved.placeName == nil {
            placeLabels.resolve(saved.region.center)
        }
        adoptResolvedNames()
        Task.detached(priority: .utility) {
            let bytes = store.totalCacheBytes()
            await MainActor.run { totalCacheBytes = bytes }
        }
    }

    /// Write any names the geocoder has answered with into the manifest, so the list still reads as
    /// places the next time it's opened — which, for offline maps, is usually with no connection.
    /// Self-limiting: a row with a `placeName` is never looked at again.
    private func adoptResolvedNames() {
        var adopted = false
        for saved in savedRegions where saved.placeName == nil {
            guard let label = placeLabels.label(for: saved.region.center) else { continue }
            store.setPlaceName(label.title, forRegionID: saved.id)
            adopted = true
        }
        if adopted { savedRegions = store.loadRegions() }
    }

    /// What one saved row is called. A place if we have one; the stored name otherwise — never a
    /// spinner and never a guess, matching how the rest of the app degrades.
    private func rowTitle(for saved: OfflineRegion) -> String {
        let place = saved.placeName ?? placeLabels.label(for: saved.region.center)?.title
        guard saved.isAutoRow else { return place ?? saved.name }
        // The rolling cache says what it is first, then where — it isn't something the user chose
        // to save, and three lines reading "Recently viewed (auto)" told them nothing at all.
        let rolling = L("offline.maps.auto_row", fallback: "Recently viewed")
        return place.map { "\(rolling) · \($0)" } ?? rolling
    }

    private func delete(_ saved: OfflineRegion) {
        store.deleteRegion(saved)
        refreshSavedRegions()
        // Make the freed tiles visible, not just the smaller number in the header.
        tileReloadToken += 1
    }

    private func deleteAll() {
        store.deleteAll()
        refreshSavedRegions()
        tileReloadToken += 1
    }

    // MARK: - Teleport (same low-level path as every other mode)

    private func teleport(to coordinate: CLLocationCoordinate2D) {
        guard pairingExists else {
            alert(
                L("offline.maps.pairing_needed.title", fallback: "Pairing needed"),
                L("offline.maps.pairing_needed",
                  fallback: "Import a pairing file in Settings, then try again.")
            )
            return
        }
        // Route through the SHARED teleport path (like every other teleport entry point) instead of a
        // bespoke simulate_location inject: post .teleportToRequested, which the Map screen handles by
        // selecting the coordinate and calling simulate() — that runs noteTeleport (cooldown + snap-back
        // arm) AND startResendLoop with proper suppressResends handling. A bare inject here had no
        // resend loop (the fix decayed) and no single-writer gating, so it competed as a stray writer
        // during a movement session. Dismiss so the resulting teleport is visible on the Map tab.
        UserDefaults.standard.set(AppFeature.location.id, forKey: "primaryTabSelection")
        NotificationCenter.default.post(
            name: .teleportToRequested,
            object: nil,
            userInfo: ["lat": coordinate.latitude, "lng": coordinate.longitude]
        )
        dismiss()
    }

    private func alert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
