//
//  CooldownGuardView.swift
//  Wander
//
//  A compact, persistent "safe to catch/spin" countdown chip. After a big teleport,
//  Niantic games apply a distance-based soft-ban cooldown: catching/spinning during it
//  can wipe rewards. We can't gate PoGo's in-app taps (server-side, no hook), so this is
//  pure GUIDANCE — a live MM:SS timer, visible across every tab, that tells the user how
//  long to WAIT before interacting. Teleporting and walking stay free.
//
//  Reads the single source of truth on SimulationSession (fed by the existing PoGoCooldown
//  curve on every confirmed teleport). Hidden the moment the cooldown clears.
//

import SwiftUI

struct CooldownGuardView: View {
    @ObservedObject private var session = SimulationSession.shared

    var body: some View {
        if session.cooldownActive {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .font(.caption)
                Text(L("cooldown.chip", fallback: "Safe to catch/spin in")
                     + " " + timeString(session.cooldownRemaining))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Wander.brand, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .allowsHitTesting(false)
            .accessibilityLabel(
                L("cooldown.chip.a11y",
                  fallback: "Soft-ban cooldown — wait before catching or spinning")
                + " " + timeString(session.cooldownRemaining)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    CooldownGuardView()
}
