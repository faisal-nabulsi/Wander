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

/// Localizes the paywall's DISPLAYED prices to the visitor's currency via the Worker /pricing/geo
/// endpoint (live FX, cached daily). Display only — checkout charges the real amount in the local
/// currency via Lemon Squeezy. Everyone pays the same value; it's just shown natively. Falls back
/// to the USD strings until/unless the fetch succeeds.
@MainActor
final class PriceLocalizer: ObservableObject {
    @Published var lifetime = WanderSales.lifetimePrice
    @Published var yearly = WanderSales.yearlyPrice
    @Published var yearlyNote = WanderSales.yearlyNote
    @Published var monthly = WanderSales.monthlyPrice

    private var loaded = false

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = URL(string: "https://wander-payments.wanderlocation.workers.dev/pricing/geo") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        Task { @MainActor [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let currency = obj["currency"] as? String, currency != "USD",
                      let rate = obj["rate"] as? Double, rate > 0 else { return }
                let fmt = NumberFormatter()
                fmt.numberStyle = .currency
                fmt.currencyCode = currency
                fmt.locale = Locale.current
                func money(_ usd: Double) -> String? { fmt.string(from: NSNumber(value: usd * rate)) }
                guard let self else { return }
                if let v = money(80) { self.lifetime = v }
                if let v = money(36) { self.yearly = v + "/yr" }
                if let v = money(3.99) { self.monthly = v + "/mo" }
                if let v = money(3) { self.yearlyNote = v + "/mo, billed yearly" }
            } catch { /* keep the USD fallback */ }
        }
    }
}

struct PaywallView: View {
    /// When set, the paywall is a dismissable trial-limit sheet with a Close button.
    /// When nil, it's the non-dismissable remote kill-switch cover.
    var onClose: (() -> Void)? = nil

    @ObservedObject private var gate = RemoteGate.shared
    @ObservedObject private var license = License.shared
    @ObservedObject private var trial = TrialManager.shared
    @State private var showAccountSignIn = false
    @StateObject private var prices = PriceLocalizer()

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
                    Text(localized: "paywall.title", fallback: "Wander Pro")
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
        .task { prices.load() }
    }

    private var headline: String {
        if !isTrial && !gate.message.isEmpty { return gate.message }
        if isTrial {
            return L("paywall.headline_trial", fallback: "You've used up your free trial. Unlock Wander Pro for unlimited teleports, joystick, and routes.")
        }
        return L("paywall.headline_locked", fallback: "Wander now requires Wander Pro to spoof your location. Get Pro at wanderspoofer.com, then sign in to unlock.")
    }

    private var trialSummary: some View {
        VStack(spacing: 6) {
            usageRow(L("paywall.teleports", fallback: "Teleports"), trial.teleportsUsed, TrialManager.maxTeleports)
            usageRow(L("paywall.joystick", fallback: "Joystick"), trial.joystickSecondsUsed / 60, TrialManager.maxJoystickSeconds / 60, unit: " min")
            usageRow(L("paywall.routes", fallback: "Routes"), trial.routesUsed, TrialManager.maxRoutes)
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
                Text(localized: "paywall.choose_plan", fallback: "Choose a plan").font(.headline).foregroundStyle(.white)
                planRow(L("paywall.plan.lifetime", fallback: "Lifetime"), prices.lifetime, L("paywall.plan.lifetime_note", fallback: "one-time, never expires"))
                planRow(L("paywall.plan.yearly", fallback: "Yearly"), prices.yearly, prices.yearlyNote)
                planRow(L("paywall.plan.monthly", fallback: "Monthly"), prices.monthly, "")
                Text(localized: "paywall.buy_hint", fallback: "Buy Wander Pro at wanderspoofer.com, then sign in below — your Pro unlocks on iPhone, Android, and desktop, and survives reinstalls.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }

            // Primary action: buy Pro on the website (secure checkout, links to the account).
            if let url = URL(string: WanderSales.siteURL) {
                Link(destination: url) {
                    Text(localized: "paywall.get_pro", fallback: "Get Wander Pro")
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
                Text(localized: "paywall.already_bought", fallback: "Already bought? Sign in to unlock")
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
