//
//  StabilizerBetaView.swift
//  Wander
//
//  "Long-distance stabilizer (Beta)" — an OPTIONAL, off-by-default, EXPERIMENTAL feature.
//
//  When a user teleports far (>~20 km), iOS pulls their reported location back toward reality
//  using Apple's Wi-Fi/cell lookup, causing drift/reset on big jumps. This screen installs an iOS
//  DNS configuration profile that routes the device's DNS through Wander's server, which blocks
//  Apple's location-lookup host — so the correction can't fire and a far teleport holds steady.
//
//  iOS constraint: an app CANNOT silently install a configuration profile, and iOS will NOT install
//  an app-opened local .mobileconfig. The profile must be DOWNLOADED VIA SAFARI, then installed from
//  Settings. So all this screen does is: ask the Worker for a short-lived Safari-openable link
//  (POST /doh/profile-link with the account's Firebase idToken — the SAME idToken machinery the
//  Street View / AI / directions features use) and open it in Safari. iOS then shows the install flow.
//
//  This is OFF by default: nothing installs or changes unless the user opens this screen and taps
//  Install. It does NOT fix Pokémon GO "Error 12" — that's covered by LocationErrorHelpView.
//
//  The DoH link/token is NEVER stored, logged, or displayed — the app only opens the returned URL.
//

import SwiftUI
import UIKit

// MARK: - Worker link provider (signed-in gated)

/// The result of asking the Worker for a short-lived Safari-openable profile link.
enum StabilizerLink: Equatable {
    case link(URL)              // 200 — open this in Safari to download the profile
    case notSignedIn           // 401 / no idToken — the user must sign in first
    case unavailable(String)    // 500 / 503 / transport / other, with a friendly message

    /// REUSE the same Worker base URL constant used across the app's authenticated calls.
    private static let baseURL = "https://wander-payments.wanderlocation.workers.dev"

    /// Ask the Worker for a fresh Safari-openable profile link. Requires a signed-in user (idToken).
    /// The token is obtained via the shared `WanderProAccount` machinery and never surfaced.
    static func fetch() async -> StabilizerLink {
        guard await NetworkReachability.shared.isOnline else {
            return .unavailable(L("stabilizer.error.offline",
                                  fallback: "You need an internet connection to set this up."))
        }
        // Same idToken path the Street View / AI / sync features use. No sign-in → prompt to sign in.
        guard let token = await WanderProAccount.shared.currentIdToken() else {
            return .notSignedIn
        }
        var out = await post(idToken: token)
        // A 401 means the short-lived idToken expired mid-flight — mint a fresh one, retry once.
        if out.status == 401, let fresh = await WanderProAccount.shared.refreshedIdToken() {
            out = await post(idToken: fresh)
        }
        return out.result
    }

    private static func post(idToken: String) async -> (result: StabilizerLink, status: Int) {
        guard let url = URL(string: "\(baseURL)/doh/profile-link"),
              let httpBody = try? JSONSerialization.data(withJSONObject: ["idToken": idToken]) else {
            return (.unavailable(L("stabilizer.error.build",
                                   fallback: "Couldn't build the request. Please try again.")), -1)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = httpBody
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch status {
            case 200:
                if let link = (obj?["url"] as? String), let parsed = URL(string: link) {
                    return (.link(parsed), 200)
                }
                return (.unavailable(L("stabilizer.error.unavailable",
                                       fallback: "Not available right now — please try again later.")), 200)
            case 401: return (.notSignedIn, 401)
            case 503: return (.unavailable(L("stabilizer.error.unavailable",
                                             fallback: "Not available right now — please try again later.")), 503)
            default:  return (.unavailable(L("stabilizer.error.unavailable",
                                             fallback: "Not available right now — please try again later.")), status)
            }
        } catch {
            return (.unavailable(L("stabilizer.error.network",
                                   fallback: "Couldn't reach Wander — check your connection and try again.")), -1)
        }
    }
}

// MARK: - Screen

struct StabilizerBetaView: View {
    @Environment(\.dismiss) private var dismiss

    /// True while the profile link request is in flight.
    @State private var isFetching = false
    /// A friendly error to show inline, if the last attempt failed.
    @State private var errorMessage: String?
    /// Set once Safari has been handed the download, so we can show the "Next steps" card.
    @State private var didOpenSafari = false
    /// True when the fetch reported no signed-in user, so we surface a sign-in pointer.
    @State private var needsSignIn = false

    /// Presents the app's existing sign-in flow.
    @State private var showProSignIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    explanationCard
                    warningCard
                    installCard
                    if didOpenSafari { nextStepsCard }
                    removeCard
                    errorHint
                }
                .padding()
            }
            .navigationTitle(L("stabilizer.title", fallback: "Long-distance stabilizer (Beta)"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Color.blue.opacity(0.07).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showProSignIn) {
            WanderAccountSignInView(onSuccess: {
                showProSignIn = false
                needsSignIn = false
                errorMessage = nil
            })
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.largeTitle)
                .foregroundStyle(Wander.brand)
            Text(L("stabilizer.intro",
                   fallback: "Experimental. Helps a FAR teleport hold steady instead of drifting back."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Plain-language explanation

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("stabilizer.what.header", fallback: "What this does"),
                  systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(L("stabilizer.what.body",
                   fallback: "When you teleport a long way (more than about 20 km), iOS sometimes pulls your location back toward where you really are — using nearby Wi-Fi and cell towers — so a far spot drifts or snaps back.\n\nThis feature installs a DNS profile that routes your DNS through Wander's server, which blocks Apple's location-lookup service. With that lookup blocked, iOS can't correct you, so a far teleport holds steady. It's for far-teleport DRIFT only."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Warning block (caution style)

    private var warningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("stabilizer.warning.header", fallback: "Read this first"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.orange)

            warningRow(L("stabilizer.warning.beta",
                         fallback: "Beta & experimental — may not help on every device or iOS version."))
            warningRow(L("stabilizer.warning.dns",
                         fallback: "While installed, ALL your DNS goes through Wander's server. It can affect Apple services (iCloud, Maps, App Store, Find My)."))
            warningRow(L("stabilizer.warning.off",
                         fallback: "Turn it OFF when you're done."))
            warningRow(L("stabilizer.warning.error12",
                         fallback: "This does NOT fix 'Error 12'. For that, see the Error 12 help (Settings → Help → Location not detected)."))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Install

    private var installCard: some View {
        VStack(spacing: 12) {
            if needsSignIn {
                Label(L("stabilizer.signin.needed",
                        fallback: "Sign in to your Wander account to set this up."),
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)

                WanderPrimaryButton(title: L("stabilizer.signin.button", fallback: "Sign in"),
                                    icon: "person.badge.key") {
                    showProSignIn = true
                }
            } else if isFetching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L("stabilizer.install.fetching", fallback: "Preparing profile…"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else {
                WanderPrimaryButton(title: L("stabilizer.install.button", fallback: "Install profile"),
                                    icon: "square.and.arrow.down") {
                    Task { await install() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Next steps (after Safari opens)

    private var nextStepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("stabilizer.next.header", fallback: "Next steps"),
                  systemImage: "list.number")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Wander.brand)

            Text(L("stabilizer.next.body",
                   fallback: "Safari is downloading the profile. Then:\n\n1. Settings → Profile Downloaded → Install (iOS may ask for your passcode).\n\n2. After installing: Settings → General → VPN & Device Management → DNS → make sure 'Wander Long-Distance Stabilizer' is selected.\n\n3. Then toggle Location Services off for about 3 seconds and back on."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Wander.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Wander.brand.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Turn it off / remove

    private var removeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("stabilizer.remove.header", fallback: "Turn it off / remove"),
                  systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(L("stabilizer.remove.body",
                   fallback: "Settings → General → VPN & Device Management → tap 'Wander Long-Distance Stabilizer (Beta)' → Remove Profile.\n\nRemove it whenever you're not using far teleports — it routes all your DNS through Wander's server, so leaving it on can affect Apple services."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Inline error

    @ViewBuilder private var errorHint: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Flow

    /// Fetch the short-lived Safari link, then open it so Safari downloads the profile.
    /// The link/token is never stored, logged, or displayed — we only hand the URL to Safari.
    private func install() async {
        guard !isFetching else { return }
        isFetching = true
        errorMessage = nil
        needsSignIn = false
        defer { isFetching = false }

        switch await StabilizerLink.fetch() {
        case .link(let url):
            // Open in SAFARI (not an in-app browser) so iOS downloads the .mobileconfig and shows
            // the install flow. An app-opened local profile would NOT install — this must be Safari.
            await UIApplication.shared.open(url)
            didOpenSafari = true
        case .notSignedIn:
            needsSignIn = true
        case .unavailable(let message):
            errorMessage = message
        }
    }
}

#Preview {
    StabilizerBetaView()
}
