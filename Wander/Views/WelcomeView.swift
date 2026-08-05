//
//  WelcomeView.swift
//  Wander
//
//  First-launch onboarding: a friendly landing screen with the Wander brand and a quick tour
//  of the modes, gated behind a "Get Started" button so the app doesn't drop straight into
//  the map.
//
//  Shown ONCE. `onGetStarted` is what persists that (WanderApp's `hasSeenWelcome`), so this view
//  stays dumb — it renders and reports the tap, it doesn't decide whether it should appear.
//
//  This is the first thing anyone sees, so it carries the type scale explicitly: ONE display line
//  ("Welcome to Wander"), label-weight mode names, detail underneath. The three modes fade in one
//  after another on a quick spring — the only place in the app where staged motion is worth it,
//  because there is nothing to interrupt and it teaches the app's rhythm.
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: () -> Void

    @State private var revealed = false

    private struct Mode: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let detail: String
    }

    private let modes: [Mode] = [
        Mode(icon: Wander.Icon.teleport, title: "Teleport",
             detail: "Drop a pin anywhere and be there instantly."),
        Mode(icon: Wander.Icon.joystick, title: "Joystick",
             detail: "Walk around in real time with a live joystick."),
        Mode(icon: Wander.Icon.route, title: "Routes",
             detail: "Drive a path with realistic speed and stops.")
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Wander.accent.opacity(0.18), Wander.canvas],
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
                        .scaleEffect(revealed ? 1 : 0.88)
                        .opacity(revealed ? 1 : 0)

                    VStack(spacing: 6) {
                        Text("Welcome to Wander")
                            .wanderDisplay()
                            .multilineTextAlignment(.center)
                        Text("Your location, anywhere.")
                            .font(.wanderTitle)
                            .foregroundStyle(.secondary)
                    }
                    .opacity(revealed ? 1 : 0)
                }

                VStack(spacing: 18) {
                    ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                        feature(mode)
                            .opacity(revealed ? 1 : 0)
                            .offset(y: revealed ? 0 : 14)
                            .animation(WanderMotion.layout.delay(0.08 * Double(index + 1)),
                                       value: revealed)
                    }
                }

                Spacer(minLength: 12)

                WanderPrimaryButton(title: "Get Started", icon: Wander.Icon.getStarted) {
                    WanderFeedback.success.play()
                    onGetStarted()
                }
                .opacity(revealed ? 1 : 0)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .animation(WanderMotion.layout, value: revealed)
        .onAppear { revealed = true }
    }

    private func feature(_ mode: Mode) -> some View {
        HStack(spacing: 16) {
            Image(systemName: mode.icon)
                .font(.title2)
                .foregroundStyle(Wander.accent)
                .frame(width: 46, height: 46)
                .background(Wander.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.title).wanderLabel()
                Text(mode.detail).wanderDetail()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {})
}
