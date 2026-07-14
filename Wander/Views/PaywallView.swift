//
//  PaywallView.swift
//  Wander
//
//  Two roles:
//   • Trial sheet (onClose set) — a dismissable "you've used your free [mode]" prompt.
//   • Remote kill-switch cover (onClose nil) — non-dismissable, shown when RemoteGate locks.
//  Either way, unlock Wander Pro by buying at wanderspoofer.com and signing into your account.
//

import SwiftUI

enum WanderSales {
    static let siteURL = "https://wanderspoofer.com/pricing/"
    static let contactEmail = "faisalnab25@gmail.com"

    static let lifetimePrice = "$80"
    static let yearlyPrice = "$36/yr"
    static let yearlyNote = "$3/mo, billed yearly"
    static let monthlyPrice = "$3.99/mo"
}

struct PaywallView: View {
    /// When set, the paywall is a dismissable trial-limit sheet with a Close button.
    /// When nil, it's the non-dismissable remote kill-switch cover.
    var onClose: (() -> Void)? = nil

    @ObservedObject private var gate = RemoteGate.shared
    @ObservedObject private var license = License.shared
    @ObservedObject private var trial = TrialManager.shared
    @State private var showAccountSignIn = false

    private var isTrial: Bool { onClose != nil }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Wander.brand, Color(red: 0.05, green: 0.22, blue: 0.4)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    if let onClose {
                        HStack {
                            Spacer()
                            Button { onClose() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }

                    Image(systemName: "lock.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.white)
                        .padding(.top, isTrial ? 0 : 36)
                    Text("Wander Pro")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text(headline)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    if isTrial { trialSummary }

                    unlockCard

                    Spacer(minLength: 12)
                }
                .padding(.vertical, 20)
            }
        }
        .interactiveDismissDisabled(onClose == nil)
    }

    private var headline: String {
        if !isTrial && !gate.message.isEmpty { return gate.message }
        if isTrial {
            return "You've used up your free trial. Unlock Wander Pro for unlimited teleports, joystick, and routes."
        }
        return "Wander now requires Wander Pro to spoof your location. Get Pro at wanderspoofer.com, then sign in to unlock."
    }

    private var trialSummary: some View {
        VStack(spacing: 6) {
            usageRow("Teleports", trial.teleportsUsed, TrialManager.maxTeleports)
            usageRow("Joystick", trial.joystickSecondsUsed / 60, TrialManager.maxJoystickSeconds / 60, unit: " min")
            usageRow("Routes", trial.routesUsed, TrialManager.maxRoutes)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.9))
        .padding(14)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 28)
    }

    private func planRow(_ name: String, _ price: String, _ note: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.subheadline.weight(.semibold))
                if !note.isEmpty {
                    Text(note).font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            Text(price).font(.subheadline.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private func usageRow(_ label: String, _ used: Int, _ maximum: Int, unit: String = "") -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(min(used, maximum))/\(maximum)\(unit) used")
                .monospacedDigit()
        }
    }

    private var unlockCard: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("Choose a plan").font(.headline).foregroundStyle(.white)
                planRow("Lifetime", WanderSales.lifetimePrice, "one-time, never expires")
                planRow("Yearly", WanderSales.yearlyPrice, WanderSales.yearlyNote)
                planRow("Monthly", WanderSales.monthlyPrice, "")
                Text("Buy Wander Pro at wanderspoofer.com, then sign in below — your Pro unlocks on iPhone, Android, and desktop, and survives reinstalls.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            // Primary action: buy Pro on the website (secure checkout, links to the account).
            if let url = URL(string: WanderSales.siteURL) {
                Link(destination: url) {
                    Text("Get Wander Pro")
                        .font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Wander.brand)
                .controlSize(.large)
            }

            // Already purchased → sign into the Wander account that holds Pro
            // (bought on wanderspoofer.com or via Android). This is the only unlock path in-app.
            Button {
                showAccountSignIn = true
            } label: {
                Text("Already bought? Sign in to unlock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .underline()
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $showAccountSignIn) {
            WanderAccountSignInView(onSuccess: {
                // Account is now Pro → License recomputed. Dismiss the paywall if it's dismissable.
                onClose?()
            })
        }
    }
}

#Preview {
    PaywallView(onClose: {})
}
