//
//  MoreFeatureViews.swift
//  Wander
//
//  Feature screens promoted OUT of Settings into the More tab. The rule: features (things you go
//  DO or read — backup, VPN matching, Adventure Sync, community, What's New) live in More; only
//  configuration (toggles that tune behavior) stays in Settings. Each is a self-contained sheet
//  with its own navigation chrome, matching MoreView's presentation pattern.
//

import SwiftUI
import UniformTypeIdentifiers

private enum MoreFeatureLinks {
    static let vpn = URL(string: "https://wanderspoofer.com/vpn/")!
    static let githubRepo = URL(string: "https://github.com/faisal-nabulsi/Wander")!
    static let discordInvite = URL(string: "https://discord.gg/gfHdsRXUVA")!
    static let geonamesLicense = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
}

// MARK: - What's New (changelog card)

/// Shows the release notes for the CURRENTLY INSTALLED build. Auto-pops once after each update
/// (see MainTabView) and is reachable any time from More — so on a sideloaded app, where there are
/// no App Store release notes, users can actually see what changed.
struct WhatsNewView: View {
    @ObservedObject private var updater = WanderUpdater.shared
    @Environment(\.dismiss) private var dismiss

    /// Split the single notes string into readable bullet lines.
    private var highlights: [String] {
        guard let notes = updater.currentBuildNotes else { return [] }
        return notes
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("whatsnew.title", fallback: "What's New"))
                            .font(.largeTitle.weight(.bold))
                        Text(updater.currentBuildVersionLabel)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if highlights.isEmpty {
                        Text(L("whatsnew.uptodate", fallback: "You're on the latest version — no new notes right now."))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(highlights.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "sparkle")
                                        .font(.caption).foregroundStyle(Wander.brand)
                                    Text(line).font(.body)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 8)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(L("whatsnew.title", fallback: "What's New"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Match your IP (VPN)

struct MatchIPView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Match your IP", systemImage: "network.badge.shield.half.filled")
                            .font(.body.weight(.semibold))
                        Text("Some dating and Pokémon GO-style apps compare your IP address against your GPS location. A VPN in the same region keeps them consistent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Link(destination: MoreFeatureLinks.vpn) {
                            Label("Get a matching VPN", systemImage: "arrow.up.right.square")
                        }
                        .font(.callout.weight(.medium))
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Wander doesn't run a VPN itself — it helps you line your IP up with your spoofed country using any VPN you already trust.")
                }
            }
            .navigationTitle("Match your IP")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Community

struct CommunityView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Link(destination: MoreFeatureLinks.githubRepo) {
                        Label(L("settings.community.star", fallback: "⭐ Star Wander on GitHub"), systemImage: "star.fill")
                    }
                    Link(destination: MoreFeatureLinks.discordInvite) {
                        Label(L("settings.community.discord", fallback: "💬 Join our Discord"), systemImage: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(Color(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255))
                    }
                    // Required CC BY 4.0 credit for the bundled offline place data (GeoNames).
                    Link(destination: MoreFeatureLinks.geonamesLicense) {
                        Text("Offline place data © GeoNames (CC BY 4.0)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Wander is open source. Star the repo on GitHub to help others find it, and join our Discord to share tips and get help.")
                }
            }
            .navigationTitle(L("settings.community.header", fallback: "Community"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Backup / Restore

struct BackupView: View {
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupDocument: WanderBackupDocument?
    @State private var backupResult: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        startBackupExport()
                    } label: {
                        Label(L("settings.backup.back_up", fallback: "Back up my data"), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        backupResult = nil
                        isImportingBackup = true
                    } label: {
                        Label(L("settings.backup.restore", fallback: "Restore from backup"), systemImage: "square.and.arrow.down")
                    }
                    if let msg = backupResult {
                        Label(msg.text, systemImage: msg.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(msg.isError ? .red : .green)
                    }
                } header: {
                    Text(localized: "settings.backup.header", fallback: "Backup")
                } footer: {
                    Text("Exports all your favorites, saved & recorded routes, and teleport history to one file. Restore merges a backup back in — it never deletes what you already have, and re-importing the same file won't create duplicates.")
                }
            }
            .navigationTitle(L("settings.backup.header", fallback: "Backup"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: WanderBackup.suggestedFileName()
        ) { result in
            switch result {
            case .success:
                backupResult = ("Backup saved.", false)
            case .failure(let error):
                backupResult = ("Backup failed: \(error.localizedDescription)", true)
            }
            backupDocument = nil
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImport(result)
        }
    }

    private func startBackupExport() {
        backupResult = nil
        do {
            let data = try WanderBackup.exportData()
            backupDocument = WanderBackupDocument(data: data)
            isExportingBackup = true
        } catch {
            backupResult = ("Couldn't prepare backup: \(error.localizedDescription)", true)
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let envelope = try WanderBackup.decodeEnvelope(data)
                let summary = WanderBackup.restore(envelope)
                if summary.totalAdded == 0 {
                    backupResult = ("Restore complete — everything in that backup was already here.", false)
                } else {
                    backupResult = ("Restored \(summary.totalAdded) item(s): "
                        + "\(summary.bookmarksAdded) favorites, "
                        + "\(summary.routesAdded) routes, "
                        + "\(summary.recentsAdded) recents.", false)
                }
            } catch {
                backupResult = ("Restore failed: \(error.localizedDescription)", true)
            }
        case .failure(let error):
            backupResult = ("Restore failed: \(error.localizedDescription)", true)
        }
    }
}

// MARK: - Adventure Sync (Pro) — mirror simulated walking into Apple Health

struct AdventureSyncView: View {
    @ObservedObject private var license = License.shared
    @ObservedObject private var adventureSync = AdventureSyncManager.shared
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !license.isLicensed {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack {
                                Label(L("settings.adventuresync.toggle", fallback: "Adventure Sync (write steps to Health)"),
                                      systemImage: "figure.walk.motion")
                                Spacer()
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { adventureSync.isEnabled },
                            set: { adventureSync.setEnabled($0) }
                        )) {
                            Label(L("settings.adventuresync.toggle", fallback: "Adventure Sync (write steps to Health)"),
                                  systemImage: "figure.walk.motion")
                        }
                        .tint(Wander.brand)

                        if adventureSync.isEnabled {
                            switch adventureSync.status {
                            case .authorized:
                                Label(L("settings.adventuresync.status.on",
                                        fallback: "Writing steps to Apple Health while you move."),
                                      systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            case .denied:
                                Label(L("settings.adventuresync.status.denied",
                                        fallback: "Health write access is off. Enable it in Settings → Health → Data Access & Devices → Wander."),
                                      systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            case .unavailable:
                                Label(L("settings.adventuresync.status.unavailable",
                                        fallback: "Apple Health isn't available on this install. Writing steps needs a HealthKit-enabled (paid-signing) build."),
                                      systemImage: "xmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            case .idle:
                                Label(L("settings.adventuresync.status.idle",
                                        fallback: "Grant Apple Health write access when prompted to start mirroring steps."),
                                      systemImage: "hourglass")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(localized: "settings.adventuresync.header", fallback: "Adventure Sync")
                        Text(verbatim: "WIP")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                    }
                } footer: {
                    Text(license.isLicensed
                         ? L("settings.adventuresync.footer",
                             fallback: "Best-effort: writes step + walking-distance samples to Apple Health that mirror your simulated walk, so games like Pokémon GO's Adventure Sync can credit the distance. Steps are paced realistically from your actual movement — only while the Joystick or a Route drive is moving. Teleports write nothing. Off by default.")
                         : L("settings.adventuresync.footer_locked",
                             fallback: "Wander Pro mirrors your simulated walk into Apple Health as steps + distance, so fitness-reading games can credit it. Best-effort, paced realistically, off by default."))
                }
            }
            .navigationTitle(L("settings.adventuresync.header", fallback: "Adventure Sync"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(onClose: { showPaywall = false })
        }
    }
}
