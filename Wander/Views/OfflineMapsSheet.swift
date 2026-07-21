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

    private let store = OfflineTileStore.shared

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var cacheOnly = false

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
                    cacheOnly: cacheOnly
                )
                .ignoresSafeArea()
                .overlay(alignment: .center) {
                    if selectedCoordinate == nil { MapCrosshair() }
                }

                VStack(spacing: 8) {
                    if !reachability.isOnline {
                        offlinePill
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
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
                refreshEstimate()
            }
            .onDisappear {
                // Don't cancel a live teleport — but a half-finished *download* is fine to stop.
                downloadTask?.cancel()
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
                    .onChange(of: downloadDepth) { _, _ in refreshEstimate() }
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
                        Text(saved.name)
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

    // MARK: - Estimate

    /// Maps the current visible map region + chosen depth into a min/max zoom range for the store.
    private func currentZoomRange() -> (min: Int, max: Int) {
        // Approximate the map's current zoom from the longitude span.
        let span = max(region.span.longitudeDelta, 0.0001)
        let approxZoom = Int((log2(360.0 / span)).rounded())
        let baseZoom = min(max(approxZoom, 1), OfflineTileStore.maxZoomCap)
        let maxZoom = min(baseZoom + downloadDepth, OfflineTileStore.maxZoomCap)
        // Start a couple levels below so panning out still has tiles.
        let minZoom = max(baseZoom - 1, 1)
        return (minZoom, maxZoom)
    }

    private func refreshEstimate() {
        let range = currentZoomRange()
        estimate = store.estimate(region: region, minZoom: range.min, maxZoom: range.max)
    }

    private func estimateText(_ estimate: OfflineDownloadEstimate) -> String {
        let size = ByteCountFormatter.string(fromByteCount: estimate.approximateBytes, countStyle: .file)
        return L("offline.maps.estimate",
                 fallback: "≈ \(estimate.tileCount) tiles • about \(size)")
    }

    // MARK: - Download

    private func startDownload() {
        // Refresh against the region actually on screen right now.
        refreshEstimate()

        guard reachability.isOnline else {
            alert(
                L("offline.download.offline.title", fallback: "You're offline"),
                L("offline.download.no_connection",
                  fallback: "Connect to Wi‑Fi or cellular, then download this area.")
            )
            return
        }

        let range = currentZoomRange()
        let snapshot = region
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

    /// A friendly default name from the region center (rounded coordinates).
    private func regionName(for region: MKCoordinateRegion) -> String {
        String(format: "%.3f, %.3f", region.center.latitude, region.center.longitude)
    }

    // MARK: - Saved regions

    private func refreshSavedRegions() {
        savedRegions = store.loadRegions()
        Task.detached(priority: .utility) {
            let bytes = store.totalCacheBytes()
            await MainActor.run { totalCacheBytes = bytes }
        }
    }

    private func delete(_ saved: OfflineRegion) {
        store.deleteRegion(saved)
        refreshSavedRegions()
    }

    private func deleteAll() {
        store.deleteAll()
        refreshSavedRegions()
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
