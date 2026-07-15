//
//  OfflineMapsSheet.swift
//  Wander
//
//  The Offline Maps screen (parity with the Android osmdroid offline flow). Free feature.
//
//  Reworked onto MapLibre Native + a Protomaps PMTiles vector basemap:
//    - Shows an OfflineMapView (MLNMapView rendering the Protomaps basemap v4 vector style,
//      served from a PMTiles archive via MapLibre's pmtiles:// protocol).
//    - "Download this area": pick a zoom depth, then hand the visible bbox + zoom range to
//      MapLibre's offline packs (MLNOfflineStorage). A progress bar tracks the pack download
//      with a Cancel.
//    - Lists saved offline packs with their sizes, each with delete.
//    - Shows total cache size + "Delete all".
//    - "Teleport here" on the long-pressed coordinate, using the SAME low-level simulate
//      path every other mode uses, so the global banner / Stop / panic all apply.
//
//  It never touches the shipping SwiftUI Map. Presented like the app's other sheets.
//

import SwiftUI
import MapKit

struct OfflineMapsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reachability = NetworkReachability.shared

    private let packStore = OfflineMapPackStore.shared

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(
            latitude: OfflineMapConfig.defaultCenterLatitude,
            longitude: OfflineMapConfig.defaultCenterLongitude
        ),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
    )
    @State private var selectedCoordinate: CLLocationCoordinate2D?

    // Download configuration + progress.
    @State private var downloadDepth = 2              // extra zoom levels above the current view.
    @State private var isDownloading = false
    @State private var downloadBytes: Int64 = 0
    @State private var progressCompleted: UInt64 = 0
    @State private var progressExpected: UInt64 = 0

    // Saved packs + cache size.
    @State private var savedPacks: [OfflineMapPack] = []
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
                    region: $region
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
                refreshSavedPacks()
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

                if !savedPacks.isEmpty {
                    Divider()
                    savedPacksList
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
                if progressExpected > 0 {
                    ProgressView(
                        value: Double(progressCompleted),
                        total: Double(max(progressExpected, 1))
                    )
                    Text(L("offline.maps.downloading",
                           fallback: "Downloading map data… \(ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(L("offline.maps.preparing", fallback: "Preparing download…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                }

                Text(L("offline.maps.vector_note",
                       fallback: "Saves the visible area as a compact vector map for offline use."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WanderPrimaryButton(
                    title: L("offline.maps.download_area", fallback: "Download this area"),
                    icon: "square.and.arrow.down"
                ) {
                    startDownload()
                }
            }
        }
    }

    private var savedPacksList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("offline.maps.saved", fallback: "Saved maps"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: totalCacheBytes, countStyle: .file))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(savedPacks) { saved in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(saved.name)
                            .font(.subheadline)
                        Text(ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file))
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

    // MARK: - Zoom range

    /// Maps the current visible map region + chosen depth into a min/max zoom range for the pack.
    private func currentZoomRange() -> (min: Double, max: Double) {
        let baseZoom = OfflineMapStyle.zoomLevel(for: region)
        let maxZoom = min(baseZoom + Double(downloadDepth), OfflineMapPackStore.maxZoomCap)
        let minZoom = max(baseZoom - 1, 0)
        return (minZoom, min(maxZoom, OfflineMapPackStore.maxZoomCap))
    }

    // MARK: - Download

    private func startDownload() {
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
        downloadBytes = 0
        progressCompleted = 0
        progressExpected = 0

        packStore.downloadRegion(
            name: name,
            region: snapshot,
            minZoom: range.min,
            maxZoom: range.max,
            progress: { bytes, completed, expected in
                Task { @MainActor in
                    downloadBytes = bytes
                    progressCompleted = completed
                    progressExpected = expected
                }
            },
            completion: { result in
                Task { @MainActor in
                    isDownloading = false
                    refreshSavedPacks()
                    if case .failure(let error) = result {
                        alert(
                            L("offline.download.failed.title", fallback: "Download interrupted"),
                            error.localizedDescription
                        )
                    }
                }
            }
        )
    }

    private func cancelDownload() {
        // Cancelling mid-download = removing the just-created pack (the newest one).
        if let newest = packStore.loadPacks().first {
            packStore.delete(newest) {
                Task { @MainActor in
                    isDownloading = false
                    refreshSavedPacks()
                }
            }
        } else {
            isDownloading = false
        }
        refreshSavedPacks()
    }

    /// A friendly default name from the region center (rounded coordinates).
    private func regionName(for region: MKCoordinateRegion) -> String {
        String(format: "%.3f, %.3f", region.center.latitude, region.center.longitude)
    }

    // MARK: - Saved packs

    private func refreshSavedPacks() {
        savedPacks = packStore.loadPacks()
        totalCacheBytes = packStore.totalBytes()
    }

    private func delete(_ saved: OfflineMapPack) {
        packStore.delete(saved) {
            Task { @MainActor in refreshSavedPacks() }
        }
    }

    private func deleteAll() {
        packStore.deleteAll {
            Task { @MainActor in refreshSavedPacks() }
        }
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
        let path = pairingPath
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        LocationSimulationCommandQueue.shared.async {
            _ = simulate_location(DeviceConnectionContext.targetIPAddress, lat, lng, path)
        }
        SimulationSession.shared.started()
    }

    private func alert(_ title: String, _ message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}
