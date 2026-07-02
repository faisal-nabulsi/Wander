//
//  WanderStyle.swift
//  Wander
//
//  Shared design language so Teleport / Joystick / Route feel like one app:
//  a floating control card, a consistent center crosshair for placing points,
//  one brand color, and a single set of icons.
//

import SwiftUI

enum Wander {
    static let brand = Color(red: 0.094, green: 0.373, blue: 0.647)   // #185FA5

    enum Icon {
        static let teleport = "mappin.and.ellipse"
        static let joystick = "dpad.fill"
        static let route = "car.fill"
        static let settings = "gearshape.fill"
        static let setHere = "mappin"
        static let simulate = "location.fill"
        static let stop = "stop.fill"
        static let play = "play.fill"
        static let pause = "pause.fill"
        static let add = "plus.circle.fill"
        static let clear = "trash"
        static let search = "magnifyingglass"
    }
}

/// A floating, rounded, translucent control panel that sits over a full-bleed map.
struct WanderCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
    }
}

/// The center placement crosshair — the one consistent "you'll drop it here" indicator.
struct MapCrosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Wander.brand.opacity(0.9), lineWidth: 3).frame(width: 26, height: 26)
            Circle().fill(Wander.brand).frame(width: 6, height: 6)
            Rectangle().fill(Wander.brand.opacity(0.9)).frame(width: 2, height: 12).offset(y: -22)
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
        .allowsHitTesting(false)
    }
}

/// Consistent primary action button used across all modes.
struct WanderPrimaryButton: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        .tint(role == .destructive ? .red : Wander.brand)
        .controlSize(.large)
    }
}
