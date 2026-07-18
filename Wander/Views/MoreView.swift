//
//  MoreView.swift
//  Wander
//
//  The "More" tab — a real, organized hub that REPLACES iOS's auto-generated 2-row overflow.
//  Each secondary FEATURE screen has exactly ONE home here (config stays in Settings, advanced /
//  diagnostic screens stay under Tools), so nothing double-shows. Geofences lives here (a feature
//  screen), not in Settings.
//
//  Each row opens its screen as a sheet. Every destination brings its OWN navigation chrome, so
//  presenting them modally avoids the nested-stack "lost back button" problem; swipe-down dismisses.
//

import SwiftUI

struct MoreView: View {
    @State private var route: MoreRoute?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.account)
                }
                Section(L("more.section.spots", fallback: "Spots & planning")) {
                    row(.places)
                    row(.schedule)
                    row(.itinerary)
                    row(.geofences)
                }
                Section(L("more.section.maps", fallback: "Maps & tools")) {
                    row(.offlineMaps)
                    row(.backup)
                    row(.tools)
                }
                Section(L("more.section.features", fallback: "Features")) {
                    row(.adventureSync)
                    row(.matchIP)
                }
                Section {
                    row(.whatsNew)
                    row(.community)
                    row(.reportBug)
                    row(.settings)
                }
            }
            .navigationTitle(L("tab.more", fallback: "More"))
        }
        .sheet(item: $route) { $0.destination }
    }

    private func row(_ route: MoreRoute) -> some View {
        Button {
            self.route = route
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.title).foregroundStyle(.primary)
                    Text(route.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: route.icon)
            }
        }
    }
}

/// The secondary screens reachable from More, presented as sheets.
private enum MoreRoute: String, Identifiable {
    case account, places, schedule, itinerary, geofences, offlineMaps, backup, tools,
         adventureSync, matchIP, whatsNew, community, reportBug, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .account:       return L("more.account", fallback: "Account")
        case .places:        return L("tab.places", fallback: "Places")
        case .schedule:      return L("tab.schedule", fallback: "Schedule")
        case .itinerary:     return L("tab.itinerary", fallback: "Itinerary")
        case .geofences:     return L("more.geofences", fallback: "Geofences")
        case .offlineMaps:   return L("more.offline_maps", fallback: "Offline maps")
        case .backup:        return L("settings.backup.header", fallback: "Backup")
        case .tools:         return L("more.tools", fallback: "Tools")
        case .adventureSync: return L("settings.adventuresync.header", fallback: "Adventure Sync")
        case .matchIP:       return L("more.match_ip", fallback: "Match your IP")
        case .whatsNew:      return L("whatsnew.title", fallback: "What's New")
        case .community:     return L("settings.community.header", fallback: "Community")
        case .reportBug:     return L("more.report_bug", fallback: "Report a bug")
        case .settings:      return L("tab.settings", fallback: "Settings")
        }
    }

    var subtitle: String {
        switch self {
        case .account:       return "Sign in, create an account, log out or delete"
        case .places:        return "Saved & recent spots"
        case .schedule:      return "Be at a place during set hours"
        case .itinerary:     return "Timed schedule of stops (Pro)"
        case .geofences:     return "Resume real GPS when you actually arrive"
        case .offlineMaps:   return "Download regions for offline use"
        case .backup:        return "Back up & restore your data"
        case .tools:         return "Device info, app expiry & developer tools"
        case .adventureSync: return "Write simulated steps to Apple Health (Pro)"
        case .matchIP:       return "Line your IP up with your spoofed country"
        case .whatsNew:      return "See what changed in this version"
        case .community:     return "Star on GitHub & join our Discord"
        case .reportBug:     return "Something broken or an idea? Tell us"
        case .settings:      return "Configure Wander"
        }
    }

    var icon: String {
        switch self {
        case .account:       return "person.crop.circle"
        case .places:        return "star.fill"
        case .schedule:      return "calendar.badge.clock"
        case .itinerary:     return "calendar.day.timeline.left"
        case .geofences:     return "mappin.and.ellipse"
        case .offlineMaps:   return "square.and.arrow.down.on.square"
        case .backup:        return "externaldrive.badge.timemachine"
        case .tools:         return "wrench.and.screwdriver"
        case .adventureSync: return "figure.walk.motion"
        case .matchIP:       return "network.badge.shield.half.filled"
        case .whatsNew:      return "sparkles"
        case .community:     return "bubble.left.and.bubble.right.fill"
        case .reportBug:     return "ladybug.fill"
        case .settings:      return "gearshape.fill"
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .account:       AccountView()
        case .places:        PlacesView()
        case .schedule:      ScheduleView()
        case .itinerary:     ItineraryQueueView()
        case .geofences:     NavigationStack { GeofenceListView() }
        case .offlineMaps:   OfflineMapsSheet()
        case .backup:        BackupView()
        case .tools:         ToolsView()
        case .adventureSync: AdventureSyncView()
        case .matchIP:       MatchIPView()
        case .whatsNew:      WhatsNewView()
        case .community:     CommunityView()
        case .reportBug:     ReportBugView()
        case .settings:      SettingsView()
        }
    }
}

/// Account hub reachable from More → Account. Signed-out: a clear entry to sign in / create an
/// account. Signed-in: who you're signed in as, plus Log out and Delete account (server-side wipe
/// via the Worker /account/delete). Account management lives here — its one obvious home — instead
/// of being buried in Settings.
struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = WanderProAccount.shared
    @State private var showSignIn = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Form {
                if account.isSignedIn {
                    Section {
                        Label(account.email ?? "Signed in", systemImage: "person.crop.circle.fill")
                        if account.isPro {
                            Label("Wander Pro", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                    } header: {
                        Text("Signed in")
                    }

                    Section {
                        Button {
                            account.signOut()
                        } label: {
                            Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete account", systemImage: "trash")
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text("Deleting removes your account and all its data (saved places, sync, Pro link) and can't be undone.")
                    }
                } else {
                    Section {
                        Button {
                            showSignIn = true
                        } label: {
                            Label("Sign in or create account", systemImage: "person.badge.key")
                        }
                        .tint(Wander.brand)
                    } footer: {
                        Text("A free Wander account saves your places, syncs across your devices, and unlocks Pro if you've already bought it.")
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showSignIn) {
                WanderAccountSignInView()
            }
            .alert("Delete account?", isPresented: $showDeleteConfirm) {
                Button("Delete account", role: .destructive) {
                    isDeleting = true
                    Task {
                        await account.deleteAccount()
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes your Wander account and everything tied to it — saved places, sync, and your Pro link. It can't be undone.\n\nIf you pay for a subscription, deleting your account does NOT cancel billing — cancel it first at wanderspoofer.com.")
            }
        }
    }
}
