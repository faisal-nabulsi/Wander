//
//  WanderSigner.swift
//  Wander
//
//  Step 3 of self-refresh: with a signed-in Apple ID (WanderAccount), obtain a
//  certificate + App ID + provisioning profile, then re-sign a .app bundle in place.
//  The resigned bundle id is `<base>.<teamID>` so it upgrades the installed copy in place.
//  (Packaging + on-device install of the signed .app is wired separately.)
//

import Foundation
import AltSign

extension WanderAccount {

    enum SignError: LocalizedError {
        case notSignedIn
        case noTeam
        case noPrivateKey
        case twoFactorTimedOut
        case sessionExpired
        case networkUnavailable
        case step(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in to an Apple ID."
            case .noTeam: return "No development team found on this Apple ID."
            case .noPrivateKey: return "Certificate came back without a usable private key."
            case .twoFactorTimedOut: return "Two-factor code wasn't entered in time."
            case .sessionExpired: return "Apple sign-in expired — sign in again."
            case .networkUnavailable: return "Couldn't reach Apple — check your connection and try again."
            case .step(let s): return s
            }
        }
    }

    /// Full re-sign of a .app bundle in place. Returns the resigned bundle id on success.
    /// `interactive` is forwarded to `ensureAuthenticated`: an automatic (launch-time) refresh
    /// passes `false` so a 2FA prompt can't hang unattended (see `WanderAccount`).
    func resignAppBundle(at appURL: URL, baseBundleID: String, interactive: Bool = true, progress: @MainActor @escaping (String) -> Void) async throws -> String {
        // Establish a live Apple session on demand (reuses a cached token, or re-auths —
        // prompting 2FA only if Apple insists). This is why "signed in" can be offline.
        await progress("Signing in to Apple…")
        let (account, session) = try await ensureAuthenticated(interactive: interactive)

        await progress("Fetching team…")
        let team = try await fetchFirstTeam(account: account, session: session)

        await progress("Preparing certificate…")
        let certificate = try await obtainCertificate(team: team, session: session)
        guard certificate.p12Data() != nil else {
            throw SignError.step("Certificate P12 unavailable (data: \(certificate.data != nil), key: \(certificate.privateKey != nil))")
        }

        let resignedBundleID = "\(baseBundleID).\(team.identifier)"

        await progress("Registering App ID…")
        let appID = try await obtainAppID(name: "Wander", bundleID: resignedBundleID, team: team, session: session)

        await progress("Registering device…")
        let udid = try await Task.detached(priority: .userInitiated) {
            try JITEnableContext.shared.getDeviceUDID()
        }.value
        await registerDeviceIgnoringErrors(udid: udid, team: team, session: session)

        await progress("Fetching provisioning profile…")
        let profile = try await obtainProfile(appID: appID, team: team, session: session)

        await progress("Signing…")
        try setBundleIdentifier(resignedBundleID, at: appURL)
        try await performSign(appURL: appURL, team: team, certificate: certificate, profiles: [profile])

        return resignedBundleID
    }

    // MARK: - Async bridges over AltSign's completion-handler API

    private func fetchFirstTeam(account: ALTAccount, session: ALTAppleAPISession) async throws -> ALTTeam {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.sharedAPI.fetchTeams(for: account, session: session) { teams, error in
                if let team = teams?.first {
                    continuation.resume(returning: team)
                } else {
                    continuation.resume(throwing: error ?? SignError.noTeam)
                }
            }
        }
    }

    /// Get a certificate whose private key we hold. Try to create one; if the account's cert
    /// slots are full, revoke existing certs and retry (this is why a throwaway Apple ID is
    /// gentler — revoking invalidates other apps signed on this account).
    private func obtainCertificate(team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTCertificate {
        func fetchAll() async -> [ALTCertificate] {
            await withCheckedContinuation { continuation in
                ALTAppleAPI.sharedAPI.fetchCertificates(for: team, session: session) { certs, _ in
                    continuation.resume(returning: certs ?? [])
                }
            }
        }
        func add() async throws -> ALTCertificate {
            try await withCheckedThrowingContinuation { continuation in
                ALTAppleAPI.sharedAPI.addCertificate(machineName: "Wander", to: team, session: session) { cert, error in
                    if let cert {
                        continuation.resume(returning: cert)
                    } else {
                        continuation.resume(throwing: error ?? SignError.step("Failed to create certificate"))
                    }
                }
            }
        }

        var newCert: ALTCertificate
        do {
            newCert = try await add()
        } catch {
            // Hit the cert limit — revoke existing certs then retry once.
            for cert in await fetchAll() {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    ALTAppleAPI.sharedAPI.revoke(cert, for: team, session: session) { ok, _ in
                        continuation.resume(returning: ok)
                    }
                }
            }
            newCert = try await add()
        }

        guard let privateKey = newCert.privateKey else { throw SignError.noPrivateKey }

        // addCertificate returns the cert WITHOUT its certContent (.data), which p12Data() needs.
        // Fetch the full cert list and re-attach our private key to the matching entry.
        if newCert.data != nil { return newCert }

        let all = await fetchAll()
        let match = all.first(where: { !$0.serialNumber.isEmpty && $0.serialNumber == newCert.serialNumber && $0.data != nil })
            ?? all.first(where: { $0.data != nil })
        guard let full = match else {
            throw SignError.step("Created a certificate but couldn't retrieve its data (serial \(newCert.serialNumber))")
        }
        full.privateKey = privateKey
        return full
    }

    private func obtainAppID(name: String, bundleID: String, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTAppID {
        let existing: [ALTAppID] = await withCheckedContinuation { continuation in
            ALTAppleAPI.sharedAPI.fetchAppIDs(for: team, session: session) { ids, _ in
                continuation.resume(returning: ids ?? [])
            }
        }
        if let match = existing.first(where: { $0.bundleIdentifier == bundleID }) {
            return match
        }
        return try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.sharedAPI.addAppID(withName: name, bundleIdentifier: bundleID, team: team, session: session) { appID, error in
                if let appID {
                    continuation.resume(returning: appID)
                } else {
                    continuation.resume(throwing: error ?? SignError.step("Failed to register App ID (free accounts allow 10 per 7 days)"))
                }
            }
        }
    }

    /// Register this device with Apple so the provisioning profile includes it. Already-registered
    /// is fine (Apple returns an error we ignore), so this is safe to call every refresh.
    private func registerDeviceIgnoringErrors(udid: String, team: ALTTeam, session: ALTAppleAPISession) async {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<ALTDevice?, Never>) in
            ALTAppleAPI.sharedAPI.registerDevice(name: "Wander", identifier: udid, type: .iPhone, team: team, session: session) { device, _ in
                continuation.resume(returning: device)
            }
        }
    }

    private func obtainProfile(appID: ALTAppID, team: ALTTeam, session: ALTAppleAPISession) async throws -> ALTProvisioningProfile {
        try await withCheckedThrowingContinuation { continuation in
            ALTAppleAPI.sharedAPI.fetchProvisioningProfile(for: appID, deviceType: .iPhone, team: team, session: session) { profile, error in
                if let profile {
                    continuation.resume(returning: profile)
                } else {
                    continuation.resume(throwing: error ?? SignError.step("Failed to fetch provisioning profile"))
                }
            }
        }
    }

    private func performSign(appURL: URL, team: ALTTeam, certificate: ALTCertificate, profiles: [ALTProvisioningProfile]) async throws {
        let signer = ALTSigner(team: team, certificate: certificate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = signer.signApp(at: appURL, provisioningProfiles: profiles) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? SignError.step("Signing failed"))
                }
            }
        }
    }

    private func setBundleIdentifier(_ bundleID: String, at appURL: URL) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let dict = NSMutableDictionary(contentsOf: infoURL) else {
            throw SignError.step("Couldn't read the app's Info.plist")
        }
        dict["CFBundleIdentifier"] = bundleID
        if !dict.write(to: infoURL, atomically: true) {
            throw SignError.step("Couldn't update the app's bundle identifier")
        }
    }
}
