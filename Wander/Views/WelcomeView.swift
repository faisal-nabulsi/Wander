//
//  WelcomeView.swift
//  Wander
//
//  First-launch onboarding: a friendly landing screen with the Wander brand and a quick tour
//  of the modes, gated behind a "Get Started" button so the app doesn't drop straight into
//  the map.
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Wander.brand.opacity(0.16), Color.blue.opacity(0.04)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 12)

                VStack(spacing: 16) {
                    Image("WanderLogo")
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: Wander.brand.opacity(0.25), radius: 12, y: 6)

                    VStack(spacing: 6) {
                        Text("Welcome to Wander")
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("Your location, anywhere.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 18) {
                    feature(icon: Wander.Icon.teleport, title: "Teleport",
                            detail: "Drop a pin anywhere and be there instantly.")
                    feature(icon: Wander.Icon.joystick, title: "Joystick",
                            detail: "Walk around in real time with a live joystick.")
                    feature(icon: Wander.Icon.route, title: "Routes",
                            detail: "Drive a path with realistic speed and stops.")
                }

                Spacer(minLength: 12)

                WanderPrimaryButton(title: "Get Started", icon: "arrow.right.circle.fill") {
                    onGetStarted()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Wander.brand)
                .frame(width: 46, height: 46)
                .background(Wander.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {})
}
