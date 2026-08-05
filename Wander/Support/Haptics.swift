//
//  Haptics.swift
//  Wander
//
//  Imperative haptics for code that isn't a SwiftUI view (service callbacks, completion
//  handlers). Inside views prefer `.wanderFeedback(_:on:)` in WanderMotion.swift — the
//  declarative path honours the system's feedback settings and can't double-fire on re-render.
//

import UIKit

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: - Outcome haptics
    //
    // WHY: the app previously only had "a tap happened" feedback, so a spoof going live and a
    // spoof failing felt identical. These three are the *notification* family — they have
    // distinct rhythms, which is what lets users learn a result without looking at the screen.

    /// The thing the user asked for worked: spoof applied, tunnel connected, route saved.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Degraded but still usable: reconnecting, weak accuracy, nearing a limit.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// The action failed or is blocked. Named `failure` (not `error`) to avoid colliding with
    /// Swift's `Error` vocabulary at call sites.
    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
