//
//  LocalizationManager.swift
//  Wander
//
//  In-app language switcher. iOS's system localization only re-reads the bundle
//  on relaunch, so Wander keeps its own selected language in UserDefaults and
//  loads the matching `.lproj` bundle at runtime. Views read strings through
//  `L(_:)` / `Text(localized:)`, and because the manager is an ObservableObject
//  injected at the app root, publishing a language change re-renders the whole
//  UI live — no reinstall, no relaunch.
//

import Foundation
import SwiftUI

/// A user-selectable UI language. `.system` follows the device; the rest force a
/// specific `.lproj` bundle regardless of the device language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english        = "en"
    case spanish        = "es"
    case french         = "fr"
    case german         = "de"
    case portugueseBR   = "pt-BR"
    case italian        = "it"
    case japanese       = "ja"
    case korean         = "ko"
    case chineseHans    = "zh-Hans"
    case russian        = "ru"

    var id: String { rawValue }

    /// The `.lproj` folder name inside the app bundle. `nil` for `.system`,
    /// which falls back to the main bundle's own resolution.
    var lprojName: String? {
        switch self {
        case .system: return nil
        default:      return rawValue
        }
    }

    /// The label shown in the picker, written in the language itself (its
    /// endonym) so a Russian speaker recognizes "Русский" at a glance.
    var displayName: String {
        switch self {
        case .system:       return L("language.system")
        case .english:      return "English"
        case .spanish:      return "Español"
        case .french:       return "Français"
        case .german:       return "Deutsch"
        case .portugueseBR: return "Português (Brasil)"
        case .italian:      return "Italiano"
        case .japanese:     return "日本語"
        case .korean:       return "한국어"
        case .chineseHans:  return "简体中文"
        case .russian:      return "Русский"
        }
    }
}

/// Owns the selected language and resolves the `.lproj` bundle to read strings
/// from. Injected via `.environmentObject` at the app root; mutating
/// `currentLanguage` republishes and refreshes every view that reads through it.
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    private static let defaultsKey = "wander.selectedLanguage"

    /// The active language. Persisted immediately and re-resolves the bundle.
    @Published var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: Self.defaultsKey)
            resolveBundle()
        }
    }

    /// The bundle strings are read from. Defaults to `.main`, swapped for the
    /// selected language's `.lproj` when one is chosen and found.
    private var bundle: Bundle = .main

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let saved = AppLanguage(rawValue: raw) {
            currentLanguage = saved
        } else {
            currentLanguage = .system
        }
        resolveBundle()
    }

    private func resolveBundle() {
        guard let lproj = currentLanguage.lprojName,
              let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
              let langBundle = Bundle(path: path) else {
            // `.system`, or the requested `.lproj` isn't bundled — fall back to
            // the main bundle so a missing translation degrades to the device
            // language / English rather than showing raw keys.
            bundle = .main
            return
        }
        bundle = langBundle
    }

    /// Look up `key` in the active language, falling back to `fallback` (or the
    /// key itself) when the translation is missing. The sentinel default lets us
    /// detect a miss and fall through to the main bundle / English.
    func string(for key: String, fallback: String? = nil) -> String {
        let sentinel = "\u{0}__wander_missing__"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        if value != sentinel {
            return value
        }
        // Missing in the selected bundle: try the main bundle (device language /
        // development region) before giving up on the provided fallback.
        let mainValue = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        if mainValue != sentinel {
            return mainValue
        }
        return fallback ?? key
    }
}

/// Global lookup used throughout the UI. Reads from the shared manager so a
/// language change refreshes anything that re-evaluates (which SwiftUI does when
/// the manager republishes).
///
/// - Parameters:
///   - key: the string-table key.
///   - fallback: shown when the key is missing everywhere (defaults to the key).
func L(_ key: String, fallback: String? = nil) -> String {
    LocalizationManager.shared.string(for: key, fallback: fallback)
}

extension String {
    /// Treat the receiver as a localization key and resolve it through the
    /// in-app language manager. Keeps call sites terse: `"tab.settings".loc`.
    var loc: String { L(self) }
}

extension Text {
    /// A `Text` whose content is resolved through the in-app language manager.
    /// Prefer this over `Text("key")` so switching languages updates live.
    init(localized key: String, fallback: String? = nil) {
        self.init(L(key, fallback: fallback))
    }
}
