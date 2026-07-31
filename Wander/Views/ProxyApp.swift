//
//  ProxyApp.swift
//  Wander
//
//  The set of third-party proxy apps that can host the Wander gs-loc rewrite. gs-loc mode needs a proxy
//  app that can MITM Apple's Wi-Fi-location lookup and run our rewrite script; historically we only
//  supported Shadowrocket, which forced users who already own Loon / Quantumult X / Stash to buy a second
//  app. This enum is the single source of truth that parameterizes the setup wizard (and the Spoof Doctor's
//  Rung-1 advice) per app: which file to import, where to get the app, and the app-specific CA-trust path.
//
//  Everything here is DATA, not behavior — the wizard reads these fields to render its steps. Deep links
//  are best-effort (private schemes change between app versions), so the wizard always shows a copy-link +
//  a manual path alongside them; a wrong/none deep link degrades to "paste it yourself", never a dead end.
//

import Foundation

enum ProxyApp: String, CaseIterable, Identifiable {
    case shadowrocket
    case loon
    case quantumultX
    case stash

    var id: String { rawValue }

    /// The worker serves each app's import file under this common prefix. Code against this contract —
    /// the files don't need to resolve during development.
    static let importBase = "https://wander-payments.wanderlocation.workers.dev/gsloc/"

    /// Shadowrocket stays the default/recommended: it's the one we've field-tested end-to-end.
    static let recommended: ProxyApp = .shadowrocket

    var title: String {
        switch self {
        case .shadowrocket: return "Shadowrocket"
        case .loon: return "Loon"
        case .quantumultX: return "Quantumult X"
        case .stash: return "Stash"
        }
    }

    var isRecommended: Bool { self == Self.recommended }

    // MARK: App Store

    /// itms-apps deep link to the app's App Store page. IDs verified against the public App Store, but
    /// worth re-confirming on device (Apple occasionally re-issues listings).
    var appStoreURL: String {
        switch self {
        case .shadowrocket: return "itms-apps://apps.apple.com/app/id932747118"
        case .loon: return "itms-apps://apps.apple.com/app/id1373567447"
        case .quantumultX: return "itms-apps://apps.apple.com/app/id1443988620"
        case .stash: return "itms-apps://apps.apple.com/app/id1596063349"
        }
    }

    // MARK: Import (the Wander rewrite for this app)

    /// The filename the worker serves for this app's rewrite. One import per app.
    var importFileName: String {
        switch self {
        case .shadowrocket: return "wander.sgmodule"
        case .loon: return "wander.plugin"
        case .quantumultX: return "wander.qx.conf"
        case .stash: return "wander.stoverride"
        }
    }

    /// Full https URL the user imports into the proxy app.
    var importURL: String { Self.importBase + importFileName }

    /// What this app calls the thing being imported — used in the step copy ("Import the Wander module").
    var moduleNoun: String {
        switch self {
        case .shadowrocket: return "module"
        case .loon: return "plugin"
        case .quantumultX: return "rewrite"
        case .stash: return "override"
        }
    }

    /// Best-effort deep link that opens the app straight onto its import sheet. `nil` for apps with no
    /// reliable rewrite-import scheme (the wizard falls back to copy-link + manual path). The raw https URL
    /// is appended verbatim, matching the shipped Shadowrocket behavior (no extra percent-encoding).
    func importDeepLink() -> String? {
        switch self {
        case .shadowrocket: return "shadowrocket://install?module=\(importURL)"
        case .loon: return "loon://import?plugin=\(importURL)"
        case .stash: return "stash://install-override?url=\(importURL)"
        // Quantumult X has no dependable one-tap rewrite-import scheme — add it as a remote resource by hand.
        case .quantumultX: return nil
        }
    }

    /// Where to paste the copied link inside the app, when the deep link doesn't land.
    var importManualPath: String {
        switch self {
        case .shadowrocket:
            return "In Shadowrocket: Configuration → Modules → + → paste the link."
        case .loon:
            return "In Loon: Plugin → Install → From URL → paste the link."
        case .quantumultX:
            return "In Quantumult X: Settings → the rewrite/resource list → add the link as a remote resource."
        case .stash:
            return "In Stash: Override → + → Install from URL → paste the link."
        }
    }

    // MARK: HTTPS decryption + certificate

    /// How to turn on HTTPS Decryption (MITM) and generate + install the CA certificate INSIDE this app.
    /// The iOS-side trust toggle is a separate, deliberately-gated step (see `caTrustHint`).
    var httpsDecryptionHint: String {
        switch self {
        case .shadowrocket:
            return "In Shadowrocket: Configuration → tap the ⓘ → HTTPS Decryption → Certificate → Generate, then Install. iOS then shows \u{201C}Profile Downloaded\u{201D} — open Settings and install it. IMPORTANT: in that same HTTPS Decryption panel, also turn ON \u{201C}MitM over HTTP/2\u{201D} — Apple's location lookup runs over HTTP/2, and without this Shadowrocket decrypts the traffic but can't rewrite it, so the spoof silently does nothing."
        case .loon:
            return "In Loon: General → HTTPS Decryption (MitM) → turn it on (and make sure HTTP/2 decryption is enabled), then Certificate → Generate and Install. iOS then shows \u{201C}Profile Downloaded\u{201D} — open Settings and install it."
        case .quantumultX:
            return "In Quantumult X: Settings → MITM → Generate the CA certificate, Install it, and add your hostname. (Quantumult X handles HTTP/2 automatically.) iOS then shows \u{201C}Profile Downloaded\u{201D} — open Settings and install it."
        case .stash:
            return "In Stash: MitM → Generate and Install the CA certificate, and enable MitM for the hostname (make sure HTTP/2 MitM is enabled too). iOS then shows \u{201C}Profile Downloaded\u{201D} — open Settings and install it."
        }
    }

    /// The certificate's name as it appears in iOS's trust list — differs per app.
    var certificateName: String { title }

    /// The app-specific iOS Certificate-Trust-Settings instruction. The Settings path is common; the cert
    /// name is what changes.
    var caTrustHint: String {
        "Settings › General › About › Certificate Trust Settings → turn ON the \(certificateName) certificate."
    }

    // MARK: Spoof Doctor — Rung 1 tailored fix

    /// The exact "your proxy isn't intercepting" fix, in this app's own vocabulary. Rung 1 of the Doctor.
    var interceptionFixHint: String {
        switch self {
        case .shadowrocket:
            return "In Shadowrocket, set Global Routing → Config (not Direct), make sure the Wander module is enabled, and turn the top toggle on to Connect."
        case .loon:
            return "In Loon, make sure the Wander plugin is enabled and HTTPS Decryption (MitM) is on, then Connect from the Dashboard."
        case .quantumultX:
            return "In Quantumult X, make sure the Wander rewrite resource is added and enabled, MITM is on, and the proxy is connected."
        case .stash:
            return "In Stash, make sure the Wander override and MitM are enabled, then Connect."
        }
    }

    // MARK: Beta one-import accelerator (Shadowrocket only)

    /// Only Shadowrocket ships the full-config accelerator (a `.conf` that also flips HTTPS Decryption on).
    /// The other apps have a single import contract, so they don't show the beta card.
    var supportsConfigAccelerator: Bool { self == .shadowrocket }

    /// The full-config file (carries \u{201C}MITM enable = true\u{201D}), for the Shadowrocket beta accelerator.
    var configURL: String? {
        supportsConfigAccelerator ? Self.importBase + "wander.conf" : nil
    }

    /// Deep link that imports the full config in one shot (Shadowrocket only).
    func configDeepLink() -> String? {
        guard let configURL else { return nil }
        return "shadowrocket://config/add/\(configURL)"
    }
}
