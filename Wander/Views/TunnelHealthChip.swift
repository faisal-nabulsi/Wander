//
//  TunnelHealthChip.swift
//  Wander
//
//  A small, persistent heartbeat pill for the on-device tunnel connection — the #1 thing users need
//  to see at a glance, since a silent tunnel drop is what makes the location "snap back" to real GPS.
//
//    • green  dot + "Tunnel: connected"
//    • yellow dot + "Tunnel: unstable"      (best-effort reconnect may be running)
//    • red    dot + "Tunnel: disconnected"
//
//  Only shown while a simulation is active. When the tunnel is UNHEALTHY the pill becomes tappable and
//  offers Reconnect (re-assert last target via the existing teleport path) + Stop (→ real GPS,
//  reusing SimulationSession.stopAll). Copy is honest: "trying to reconnect…", never "fixed".
//
//  Placed on the OPPOSITE side from the soft-ban cooldown chip (which sits bottom-center) so the two
//  persistent chips never overlap — this one hugs the bottom-leading edge above the tab bar.
//

import SwiftUI

struct TunnelHealthChip: View {
    @ObservedObject private var session = SimulationSession.shared
    @ObservedObject private var monitor = TunnelHealthMonitor.shared

    @State private var showActions = false

    var body: some View {
        if session.isActive {
            chip
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .confirmationDialog(
                    L("tunnel.actions.title", fallback: "Tunnel connection"),
                    isPresented: $showActions,
                    titleVisibility: .visible
                ) {
                    if session.lastTeleportCoordinate != nil {
                        Button(L("tunnel.action.reconnect", fallback: "Try to reconnect")) {
                            monitor.attemptReconnectNow()
                        }
                    }
                    Button(L("tunnel.action.stop", fallback: "Stop — return to real GPS"), role: .destructive) {
                        // Reuse the single global stop path (reverts to real GPS). Never duplicated.
                        SimulationSession.shared.stopAll()
                    }
                    Button(L("action.cancel", fallback: "Cancel"), role: .cancel) { }
                } message: {
                    Text(L("tunnel.actions.body",
                           fallback: "The connection Wander injects location through looks unhealthy, so your location may snap back to real GPS. You can try to reconnect, or stop and return to real GPS."))
                }
        }
    }

    @ViewBuilder private var chip: some View {
        let content = HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5))
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(pillTint, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .accessibilityLabel(accessibilityLabel)

        if monitor.state.isHealthy {
            // Healthy: purely informational, non-interactive so it never eats map taps.
            content.allowsHitTesting(false)
        } else {
            // Unhealthy: tappable to open Reconnect / Stop.
            Button { showActions = true } label: { content }
                .buttonStyle(.plain)
        }
    }

    private var dotColor: Color {
        switch monitor.state {
        case .connected: return .green
        case .unstable: return .yellow
        case .disconnected: return .red
        }
    }

    /// A faint tint behind the frosted material so red/yellow reads as urgent at a glance.
    private var pillTint: Color {
        switch monitor.state {
        case .connected: return Color.black.opacity(0.35)
        case .unstable: return Color.orange.opacity(0.55)
        case .disconnected: return Color.red.opacity(0.6)
        }
    }

    private var label: String {
        if monitor.isReconnecting {
            return L("tunnel.chip.reconnecting", fallback: "Tunnel: reconnecting…")
        }
        switch monitor.state {
        case .connected: return L("tunnel.chip.connected", fallback: "Tunnel: connected")
        case .unstable: return L("tunnel.chip.unstable", fallback: "Tunnel: unstable")
        case .disconnected: return L("tunnel.chip.disconnected", fallback: "Tunnel: disconnected")
        }
    }

    private var accessibilityLabel: String {
        switch monitor.state {
        case .connected: return L("tunnel.chip.a11y.connected", fallback: "Tunnel connected")
        case .unstable: return L("tunnel.chip.a11y.unstable", fallback: "Tunnel unstable — tap for options")
        case .disconnected: return L("tunnel.chip.a11y.disconnected", fallback: "Tunnel disconnected — tap for options")
        }
    }
}

/// Transient, non-blocking banner shown while spoofing when iOS reports memory pressure — the tunnel
/// (a network extension) can be reclaimed under low memory, so we nudge the user to free some up.
/// Advisory only: it never blocks spoofing and auto-clears.
struct TunnelMemoryWarningBanner: View {
    @ObservedObject private var session = SimulationSession.shared
    @ObservedObject private var monitor = TunnelHealthMonitor.shared

    var body: some View {
        if session.isActive && monitor.memoryPressureWarning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                Text(L("tunnel.memory.banner",
                       fallback: "Low memory can drop the tunnel — close some background apps"))
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.orange, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.horizontal, 24)
            .padding(.top, 52)
            .onTapGesture { monitor.clearMemoryWarning() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

#Preview {
    TunnelHealthChip()
}
