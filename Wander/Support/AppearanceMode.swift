//
//  AppearanceMode.swift
//  Wander
//
//  App-wide appearance override (System / Light / Dark). Persisted via
//  @AppStorage("appearance") and applied at the app root through
//  `.preferredColorScheme`.
//

import SwiftUI

/// User-selectable color scheme override. Backed by a raw String so it
/// round-trips through @AppStorage.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    /// The `ColorScheme` to force, or `nil` to follow the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return L("settings.appearance.system", fallback: "System")
        case .light: return L("settings.appearance.light", fallback: "Light")
        case .dark: return L("settings.appearance.dark", fallback: "Dark")
        }
    }
}
