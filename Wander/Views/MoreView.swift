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
//  WHY THIS SCREEN LOOKS DIFFERENT NOW: it used to be five `List` sections holding 13 rows of
//  IDENTICAL visual weight — "Places" (used daily) and "Report a bug" (used once, ever) were the
//  same size, same colour, same everything. Half the app's best features were effectively hidden in
//  a wall of grey rows. The fix is weight, not renaming: the four things people actually open every
//  session are big tiles at the top, the things you go READ or CONFIGURE are medium rows, and the
//  utilities are a compact list at the bottom in a quieter tint. Nothing moved tabs and nothing was
//  renamed — every route that existed before still exists here.
//

import SwiftUI

// MARK: - Hub icon vocabulary
//
// Folded out of the 30-odd inline `systemImage:` literals that used to live in this file and
// SettingsView. Adding them to `Wander.Icon` (rather than another private list) is the point: one
// concept, one glyph, everywhere it appears.
extension Wander.Icon {
    // Hub destinations
    static let account = "person.crop.circle"
    static let accountActive = "person.crop.circle.fill"
    static let places = "star.fill"
    static let schedule = "calendar.badge.clock"
    static let itinerary = "calendar.day.timeline.left"
    static let geofence = "mappin.and.ellipse"
    static let offlineMaps = "square.and.arrow.down.on.square"
    static let backup = "externaldrive.badge.timemachine"
    static let tools = "wrench.and.screwdriver"
    static let timeline = "clock.arrow.circlepath"
    /// Adventure Sync specifically: writing simulated STEPS to Health. Not "movement in
    /// general" — the believable-pace toggle is `motionRealism`.
    static let adventureSync = "figure.walk.motion"
    static let matchIP = "network.badge.shield.half.filled"
    static let whatsNew = "sparkles"
    static let community = "bubble.left.and.bubble.right.fill"
    /// The repo itself. Deliberately the code brackets and NOT a star: `places` (saved
    /// favourites) already owns `star.fill`, and "Star Wander on GitHub" sitting next to a
    /// starred place would make the same glyph mean two unrelated things.
    static let github = "chevron.left.forwardslash.chevron.right"
    static let reportBug = "ladybug.fill"

    // Shared chrome / concepts used across the hub and Settings
    static let disclosure = "chevron.right"
    static let signIn = "person.badge.key"
    static let signOut = "rectangle.portrait.and.arrow.right"
    static let removeAccount = "person.badge.minus"
    static let locked = "lock.fill"
    /// "This account HAS Pro" — the badge on an entitlement you already own.
    static let pro = "checkmark.seal.fill"
    /// "Get Pro" — the upsell. Deliberately NOT `pro`: one glyph must not mean both "you have
    /// it" and "you don't", or the badge stops being a badge.
    static let proUpgrade = "crown.fill"
    /// Signed in to an *Apple ID* (the sideload/self-refresh identity), as opposed to a Wander
    /// account (`accountActive`) or a Pro entitlement (`pro`). Three different identities that
    /// were all wearing the seal.
    static let appleID = "person.crop.circle.badge.checkmark"
    static let update = "arrow.down.circle.fill"
    static let refresh = "arrow.clockwise"
    static let resign = "checkmark.seal"
    /// Installing something onto the device (an app update). Restoring a backup FILE is
    /// `restore` — the arrows point the same way but the nouns are unrelated.
    static let install = "square.and.arrow.down"
    static let restore = "arrow.down.doc"
    static let export = "square.and.arrow.up"
    static let help = "questionmark.circle"
    static let tunnelConnected = "checkmark.shield.fill"
    static let tunnelDown = "shield.slash"
    static let heartbeat = "waveform.path.ecg"
    static let sync = "arrow.triangle.2.circlepath"
    static let syncRoutes = "point.topleft.down.to.point.bottomright.curvepath"
    static let appearance = "circle.lefthalf.filled"
    static let language = "globe"
    static let speed = "speedometer"
    static let panic = "exclamationmark.octagon"
    static let reminder = "bell.badge"
    /// Believable pace + curved path while moving. A footprint trail, not the Adventure Sync
    /// walker, so "how movement looks" and "steps written to Health" stay distinguishable.
    static let motionRealism = "shoeprints.fill"
    static let drift = "dot.radiowaves.left.and.right"
    static let smoothJump = "arrow.up.right.circle"
    static let coarse = "location.circle"
    static let sharing = "person.2.wave.2"
    static let checklist = "checklist"
    static let pairing = "doc.badge.plus"
    static let devices = "iphone.and.arrow.forward"
    static let vpnDownload = "arrow.down.circle"
    static let cable = "cable.connector.horizontal"
    static let stabilizer = "point.3.connected.trianglepath.dotted"
    static let diagnostic = "scope"
    static let gsloc = "antenna.radiowaves.left.and.right"
    static let wand = "wand.and.stars"
    static let shortcuts = "square.stack.3d.up.fill"
    static let loopback = "arrow.triangle.2.circlepath.circle"
    static let network = "network"
    static let stopCircle = "stop.circle"
    static let externalLink = "arrow.up.right.square"
    static let sparkle = "sparkle"
    static let getStarted = "arrow.right.circle.fill"
}

struct MoreView: View {
    @State private var route: MoreRoute?
    @ObservedObject private var account = WanderProAccount.shared

    private let tileColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    accountCard

                    group(L("more.section.spots", fallback: "Spots & planning"), emphasis: .primary) {
                        LazyVGrid(columns: tileColumns, spacing: 12) {
                            ForEach(MoreRoute.everyday) { tile($0) }
                        }
                    }

                    group(L("more.section.features", fallback: "Features"), emphasis: .primary) {
                        card { rows(MoreRoute.features) }
                    }

                    // NOT "Maps & tools": Offline maps was promoted into the tile grid above, so
                    // this group holds Tools, Backup, What's New, Community and Report a bug —
                    // no maps at all. Filing "Report a bug" under a maps heading is exactly the
                    // scannability failure this screen was rebuilt to fix. The old key was never
                    // in any .strings table, so retiring it costs no translations.
                    group(L("more.section.utilities", fallback: "Help & utilities"), emphasis: .secondary) {
                        card { compactRows(MoreRoute.utilities) }
                    }

                    settingsRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .background(Wander.canvas.ignoresSafeArea())
            .navigationTitle(L("tab.more", fallback: "More"))
        }
        .sheet(item: $route) { $0.destination }
    }

    // MARK: - Account

    /// The one card at the top of the screen, because "who am I signed in as / do I have Pro"
    /// is the question this hub answers before any of its rows matter.
    private var accountCard: some View {
        Button {
            open(.account)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: account.isSignedIn ? Wander.Icon.accountActive : Wander.Icon.account)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Wander.accent)
                    .frame(width: 46, height: 46)
                    .background(Wander.accent.opacity(0.12), in: Circle())
                    .wanderSymbolAccent(on: account.isSignedIn)

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.isSignedIn
                         ? (account.email ?? L("more.account.signed_in", fallback: "Signed in"))
                         : L("more.account.sign_in", fallback: "Sign in to Wander"))
                        .wanderLabel()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(account.isSignedIn
                         ? MoreRoute.account.subtitle
                         : L("more.account.sign_in.detail", fallback: "Save your places and sync across devices"))
                        .wanderDetail()
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                if account.isPro {
                    Text(verbatim: "PRO")
                        .font(.wanderNumeric(.caption2, weight: .bold))
                        .foregroundStyle(Wander.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Wander.accent.opacity(0.14), in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }

                Image(systemName: Wander.Icon.disclosure)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Wander.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Wander.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(MorePressStyle())
        .wanderAnimation(WanderMotion.layout, on: account.isPro)
    }

    // MARK: - Building blocks

    private enum GroupEmphasis { case primary, secondary }

    /// A titled group. The header carries the weight difference between "features you open" and
    /// "utilities you occasionally need" — same content, different loudness.
    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      emphasis: GroupEmphasis,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if emphasis == .primary {
                Text(title).wanderTitle()
            } else {
                Text(title).wanderDetail()
            }
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Wander.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Wander.hairline, lineWidth: 0.5)
            )
    }

    /// The everyday four: big enough to hit without looking, with the icon carrying the tile.
    private func tile(_ route: MoreRoute) -> some View {
        Button {
            open(route)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: route.icon)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Wander.accent)
                    .frame(width: 42, height: 42)
                    .background(Wander.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.title).wanderLabel()
                    Text(route.subtitle)
                        .wanderDetail()
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(14)
            .background(Wander.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Wander.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(MorePressStyle())
    }

    @ViewBuilder
    private func rows(_ routes: [MoreRoute]) -> some View {
        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
            Button {
                open(route)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: route.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Wander.accent)
                        .frame(width: 32, height: 32)
                        .background(Wander.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.title).wanderLabel()
                        Text(route.subtitle)
                            .wanderDetail()
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: Wander.Icon.disclosure)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(MorePressStyle())

            if index < routes.count - 1 {
                Divider().padding(.leading, 60)
            }
        }
    }

    /// Utilities: one line, muted glyph, no explanation. You already know what Backup is; the
    /// point of this list is that it stops competing with Places for attention.
    @ViewBuilder
    private func compactRows(_ routes: [MoreRoute]) -> some View {
        ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
            Button {
                open(route)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: route.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                    Text(route.title).wanderBody()
                    Spacer(minLength: 8)
                    Image(systemName: Wander.Icon.disclosure)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(MorePressStyle())

            if index < routes.count - 1 {
                Divider().padding(.leading, 52)
            }
        }
    }

    /// Settings sits on its own, below everything: it's a destination people look for by name,
    /// so it gets a full-width row rather than being the 13th identical entry in a list.
    private var settingsRow: some View {
        Button {
            open(.settings)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: Wander.Icon.settings)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Wander.accent)
                    .frame(width: 32, height: 32)
                    .background(Wander.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(MoreRoute.settings.title).wanderLabel()
                    Text(MoreRoute.settings.subtitle).wanderDetail()
                }
                Spacer(minLength: 8)
                Image(systemName: Wander.Icon.disclosure)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Wander.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Wander.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(MorePressStyle())
    }

    /// One place to open a destination, so the "you tapped something" haptic can't drift between
    /// tiles and rows. Fired imperatively (not via `.wanderFeedback(on:)`) so dismissing a sheet —
    /// which also changes `route` — stays silent.
    private func open(_ route: MoreRoute) {
        WanderFeedback.selection.play()
        self.route = route
    }
}

/// A press that answers instantly. Deliberately tiny — a hub of cards that squashed hard would
/// read as a toy, and this screen is opened dozens of times a day.
private struct MorePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(WanderMotion.quick, value: configuration.isPressed)
    }
}

/// The secondary screens reachable from More, presented as sheets.
private enum MoreRoute: String, Identifiable, CaseIterable {
    case account, places, schedule, itinerary, geofences, offlineMaps, backup, tools,
         timeline, adventureSync, matchIP, whatsNew, community, reportBug, settings
    var id: String { rawValue }

    /// Opened most sessions — these get the tiles.
    static let everyday: [MoreRoute] = [.places, .schedule, .geofences, .offlineMaps]
    /// Opened deliberately, and worth a sentence of explanation — medium rows.
    static let features: [MoreRoute] = [.itinerary, .timeline, .adventureSync, .matchIP]
    /// Occasional utilities — compact, muted, no explanation.
    static let utilities: [MoreRoute] = [.tools, .backup, .whatsNew, .community, .reportBug]

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
        case .timeline:      return L("timeline.title", fallback: "Timeline")
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
        case .timeline:      return "Where you appeared to be — private to this device"
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
        case .account:       return Wander.Icon.account
        case .places:        return Wander.Icon.places
        case .schedule:      return Wander.Icon.schedule
        case .itinerary:     return Wander.Icon.itinerary
        case .geofences:     return Wander.Icon.geofence
        case .offlineMaps:   return Wander.Icon.offlineMaps
        case .backup:        return Wander.Icon.backup
        case .tools:         return Wander.Icon.tools
        case .timeline:      return Wander.Icon.timeline
        case .adventureSync: return Wander.Icon.adventureSync
        case .matchIP:       return Wander.Icon.matchIP
        case .whatsNew:      return Wander.Icon.whatsNew
        case .community:     return Wander.Icon.community
        case .reportBug:     return Wander.Icon.reportBug
        case .settings:      return Wander.Icon.settings
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
        // ⚠️ CROSS-TASK DEPENDENCY — `SpoofTimelineView` lives in Wander/Views/TimelineView.swift,
        // which is owned by a DIFFERENT task in this wave (and is still untracked in git). This is
        // the only reference to it from the hub, so it is also the only way a user can reach the
        // feature. If that task is dropped or reverted, MoreView stops compiling: delete this case
        // and the `.timeline` entries in `MoreRoute` (the enum case, `title`, `subtitle`, `icon`,
        // and its slot in `MoreRoute.features`) and nothing else needs to change.
        //
        // Wrapped like Geofences: the screen supplies a title and a toolbar menu but no stack of its
        // own, and swipe-down dismisses the sheet (see the file header).
        case .timeline:      NavigationStack { SpoofTimelineView() }
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
                        Label(account.email ?? "Signed in", systemImage: Wander.Icon.accountActive)
                            .font(.wanderLabel)
                        if account.isPro {
                            Label("Wander Pro", systemImage: Wander.Icon.pro)
                                .font(.wanderLabel)
                                .foregroundStyle(Wander.good)
                        }
                    } header: {
                        Text("Signed in")
                    }

                    Section {
                        Button {
                            account.signOut()
                        } label: {
                            Label("Log out", systemImage: Wander.Icon.signOut)
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            if isDeleting {
                                Label("Deleting account…", systemImage: Wander.Icon.clear)
                                    .wanderSymbolActive(true)
                            } else {
                                Label("Delete account", systemImage: Wander.Icon.clear)
                            }
                        }
                        .disabled(isDeleting)
                    } footer: {
                        Text("Deleting removes your account and all its data (saved places, sync, Pro link) and can't be undone.")
                            .font(.wanderDetail)
                    }
                } else {
                    Section {
                        Button {
                            showSignIn = true
                        } label: {
                            Label("Sign in or create account", systemImage: Wander.Icon.signIn)
                                .font(.wanderLabel)
                        }
                    } footer: {
                        Text("A free Wander account saves your places, syncs across your devices, and unlocks Pro if you've already bought it.")
                            .font(.wanderDetail)
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
            // Signing in / out is a state change the user just caused — the one place in this
            // screen a haptic is honest.
            .wanderFeedback(.success, on: account.isSignedIn)
        }
    }
}
