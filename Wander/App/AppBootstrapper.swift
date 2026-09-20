//
//  AppBootstrapper.swift
//  Wander
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        registerDefaultSettings()
        // Drops the pre-rename Cellular Mode flags. Deliberately a REMOVAL and not a migration: the
        // old flags recorded that a user had tapped "I've added it", which is an intention rather than
        // evidence, and everyone holding one is holding the previous shortcut file — the one that
        // cannot identify itself. Carrying them forward would arm a feature whose whole new safety
        // property is that it only arms on proof. See ShortcutRunner.
        ShortcutRunner.migrateCellularModeFlags()
        startConfiguredKeepAliveServices()
        applyDocumentPickerCopyWorkaround()
    }

    private static func registerDefaultSettings() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let enableAdvancedOptions = os.majorVersion >= 19

        UserDefaults.standard.register(defaults: [
            "enableAdvancedOptions": enableAdvancedOptions,
            UserDefaults.Keys.txmOverride: false,
            UserDefaults.Keys.confirmExternalJITRequests: true,
            "keepAliveAudio": true,
            "keepAliveLocation": true,
            // Breathing-jitter (OTA-96): ON by default so startResendLoop re-injects a gently
            // varying fix instead of the frozen perfect point every 4 s. Still opt-out via the
            // "Hold perfectly still" (frozenHold) toggle, which each writer checks before jittering.
            "jitterEnabled": true,
            // "First fix is real" ban-guardrail — OFF by default (hidden flag, no UI toggle yet).
            // Enable only after verifying the real→fake handoff timing on a device; see RealGPSSeeder.
            RealGPSSeeder.enabledKey: false
        ])
    }

    private static func startConfiguredKeepAliveServices() {
        guard UserDefaults.standard.bool(forKey: "keepAliveAudio") else {
            return
        }
        BackgroundAudioManager.shared.start(owner: .userSetting)
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
