import AppIntents
import Foundation
import CoreLocation
import MapKit

// MARK: - Installed App Entity

struct InstalledAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Installed App",
        numericFormat: "\(placeholder: .int) apps"
    )
    static var defaultQuery = InstalledAppQuery()

    var id: String // bundle ID
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(id)")
    }
}

struct InstalledAppQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [InstalledAppEntity] {
        let allApps = (try? JITEnableContext.shared.getAppList()) ?? [:]
        return identifiers.compactMap { bundleID in
            guard let name = allApps[bundleID] else { return nil }
            return InstalledAppEntity(id: bundleID, displayName: name)
        }
    }

    func entities(matching string: String) async throws -> [InstalledAppEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        let lower = string.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(lower) ||
            $0.id.lowercased().contains(lower)
        }
    }

    func suggestedEntities() async throws -> [InstalledAppEntity] {
        await ensureTunnel()
        let allApps = (try? JITEnableContext.shared.getAppList()) ?? [:]
        return allApps.map { InstalledAppEntity(id: $0.key, displayName: $0.value) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Running Process Entity

struct RunningProcessEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Running Process",
        numericFormat: "\(placeholder: .int) processes"
    )
    static var defaultQuery = RunningProcessQuery()

    // Use a stable identifier (bundleID or name) so the entity survives PID changes
    var id: String
    var pid: Int
    var displayName: String
    var bundleID: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if let bundleID, !bundleID.isEmpty {
            subtitle = "\(bundleID) — PID \(pid)"
        } else {
            subtitle = "PID \(pid)"
        }
        return DisplayRepresentation(title: "\(displayName)", subtitle: "\(subtitle)")
    }

    /// Resolve the current PID for this process by re-fetching the process list.
    func resolveCurrentPID() -> Int? {
        var err: NSError?
        let entries = ProcessInfoEntry.currentEntries(&err)
        for item in entries {
            // Match by bundle ID first (most stable), then by name
            if let myBundle = bundleID, !myBundle.isEmpty, item.bundleID == myBundle {
                return item.pid
            }
            if item.displayName == displayName {
                return item.pid
            }
        }
        return nil
    }
}

struct RunningProcessQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RunningProcessEntity] {
        // Always fetch fresh so PIDs are current
        await ensureTunnel()
        let all = try fetchProcessEntities()
        let idSet = Set(identifiers)
        return all.filter { idSet.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RunningProcessEntity] {
        let all = try await suggestedEntities()
        guard !string.isEmpty else { return all }
        let lower = string.lowercased()
        return all.filter {
            $0.displayName.lowercased().contains(lower) ||
            ($0.bundleID?.lowercased().contains(lower) ?? false) ||
            "\($0.pid)".contains(string)
        }
    }

    func suggestedEntities() async throws -> [RunningProcessEntity] {
        await ensureTunnel()
        return try fetchProcessEntities()
    }

    private func fetchProcessEntities() throws -> [RunningProcessEntity] {
        var err: NSError?
        let entries = ProcessInfoEntry.currentEntries(&err)
        if let err { throw err }

        return entries.map { entry in
            RunningProcessEntity(
                id: entry.stableIdentifier,
                pid: entry.pid,
                displayName: entry.displayName,
                bundleID: entry.bundleID
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

// MARK: - Enable JIT Intent

struct EnableJITIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Enable JIT"
    static var description = IntentDescription(
        "Enables JIT compilation for an installed app using StikDebug.",
        categoryName: "StikDebug"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(title: "App", description: "The app to enable JIT for",
               requestValueDialog: "Which app would you like to enable JIT for?")
    var app: InstalledAppEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Enable JIT for \(\.$app)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let bundleID = app?.id else {
            return .result(value: "Select an app to enable JIT for.")
        }

        await ensureTunnel()

        var scriptData: Data? = nil
        var scriptName: String? = nil
        if let preferred = ScriptStore.preferredScript(for: bundleID) {
            scriptData = preferred.data
            scriptName = preferred.name
        }

        var callback: DebugAppCallback? = nil
        if ProcessInfo.processInfo.hasTXM, let sd = scriptData {
            let name = scriptName ?? bundleID
            callback = { pid, debugProxyHandle, remoteServerHandle, semaphore in
                let model = RunJSViewModel(
                    pid: Int(pid),
                    debugProxy: debugProxyHandle,
                    remoteServer: remoteServerHandle,
                    semaphore: semaphore
                )
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .intentJSScriptReady,
                        object: nil,
                        userInfo: ["model": model, "scriptData": sd, "scriptName": name]
                    )
                }
                do { try model.runScript(data: sd, name: name) }
                catch {
                    semaphore.signal()
                    LogManager.shared.addErrorLog("Script error: \(error.localizedDescription)")
                }
            }
        }

        let logger: LogFunc = { message in
            if let message { LogManager.shared.addInfoLog(message) }
        }

        let target = app?.displayName ?? bundleID
        let success = JITEnableContext.shared.debugApp(withBundleID: bundleID, logger: logger, jsCallback: callback)

        if success {
            LogManager.shared.addInfoLog("JIT enabled for \(target) via Shortcut")
            return .result(value: "Successfully enabled JIT for \(target).")
        } else {
            LogManager.shared.addErrorLog("Failed to enable JIT for \(target) via Shortcut")
            return .result(value: "Failed to enable JIT for \(target).")
        }
    }
}

// MARK: - Kill Process Intent

struct KillProcessIntent: AppIntent {
    static var title: LocalizedStringResource = "Kill Process"
    static var description = IntentDescription(
        "Terminates a running process on the device using StikDebug.",
        categoryName: "StikDebug"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Process", description: "The process to terminate",
               requestValueDialog: "Which process would you like to kill?")
    var process: RunningProcessEntity?

    @Parameter(title: "Process ID", description: "A specific PID to kill instead of selecting a process")
    var pid: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Kill \(\.$process)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let targetPID: Int
        let targetName: String

        if let pid {
            targetPID = pid
            targetName = "PID \(pid)"
            await ensureTunnel()
        } else if let process {
            await ensureTunnel()

            // Always re-resolve to get the current PID — the stored one may be stale
            guard let resolved = process.resolveCurrentPID() else {
                return .result(value: "\(process.displayName) is no longer running.")
            }
            targetPID = resolved
            targetName = process.displayName
        } else {
            return .result(value: "Select a process or provide a PID.")
        }

        var err: NSError?
        let success = KillDeviceProcess(Int32(targetPID), &err)

        if success {
            LogManager.shared.addInfoLog("Killed \(targetName) via Shortcut")
            return .result(value: "Successfully killed \(targetName).")
        } else {
            let reason = err?.localizedDescription ?? "Unknown error"
            LogManager.shared.addErrorLog("Failed to kill \(targetName) via Shortcut: \(reason)")
            return .result(value: "Failed to kill \(targetName): \(reason)")
        }
    }
}

// MARK: - Wander: Teleport + Stop spoofing (Shortcuts / Siri)

/// Shared helpers for the Wander location App Intents.
enum WanderLocationIntent {
    /// Resolve free text to a coordinate: accepts "lat, lng", an address, or a place name.
    static func resolveCoordinate(from text: String) async -> CLLocationCoordinate2D? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "lat, lng" (or "lat lng" / "lat; lng").
        if let literal = literalCoordinate(in: trimmed) { return literal }
        // Geocode the address / place name.
        if let placemarks = try? await CLGeocoder().geocodeAddressString(trimmed),
           let loc = placemarks.first?.location {
            return loc.coordinate
        }
        // Fall back to a local search (handles POI names Apple geocoding misses).
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = trimmed
        if let resp = try? await MKLocalSearch(request: req).start(),
           let item = resp.mapItems.first {
            return item.placemark.coordinate
        }
        return nil
    }

    /// The "lat, lng" branch of `resolveCoordinate`, lifted out so callers can also ask the OTHER
    /// question it answers: was this text a bare coordinate, or a place someone named?
    ///
    /// It is the SAME code path, not a second parser, so the two answers can never disagree.
    static func literalCoordinate(in text: String) -> CLLocationCoordinate2D? {
        let nums = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { ",; ".contains($0) })
            .compactMap { Double($0) }
        guard nums.count >= 2, (-90...90).contains(nums[0]), (-180...180).contains(nums[1]) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: nums[0], longitude: nums[1])
    }

    /// What a teleport should be filed under in Recents.
    ///
    /// A Shortcut teleport used to record whatever text it was handed, so the Cellular Mode shortcut
    /// — which passes the pin as `"40.68922, -74.04446"`, because that is the format `TeleportIntent`
    /// parses — filled the Recents list with raw coordinate strings while the identical teleport
    /// tapped on the map recorded "Pinned location". Same action, two names, one list.
    ///
    /// A named place still keeps its name: "Louvre Museum" in Recents is strictly better than
    /// "Pinned location", and it is what the user typed. Only the coordinate case is renamed, which
    /// is exactly the case the map path covers.
    static func recentsName(for text: String) -> String {
        literalCoordinate(in: text) == nil
            ? text
            // The literal the map path uses (`MapSelectionView.performSimulateInner`). Deliberately
            // NOT run through `L()` here: matching means matching, and that call site records the
            // unlocalized string.
            : "Pinned location"
    }

    /// Why a teleport ended the way it did, so the intent can say something the user can act on.
    /// A bare `Bool` could not tell "the trial is used up" from "the tunnel is down", and those two
    /// need opposite advice.
    enum TeleportOutcome {
        case ok
        /// The free trial's teleport for today is spent and there is no license. Same gate as the
        /// Simulate button; see `CellularModeRun.isAllowedToStart`.
        case notLicensed
        case failed
    }

    /// Bring up the tunnel, then simulate the coordinate through the same path the app uses.
    /// Requires a pairing file (set up once in Settings).
    ///
    /// ⚠️ THE BOOKKEEPING BLOCK AT THE END IS NOT OPTIONAL. It exists so that a Shortcut teleport is
    /// indistinguishable, to everything downstream, from a teleport the user tapped on the map:
    ///
    ///  • `noteTeleport` — was MISSING. `started()` alone marks the session active but never records
    ///    WHERE, so `SimulationSession.lastTeleportCoordinate` stayed nil or, worse, held a stale
    ///    point from an earlier manual teleport. `TunnelHealthMonitor`'s self-heal re-asserts exactly
    ///    that coordinate, so a Shortcut teleport followed by a self-heal moved the user back to the
    ///    previous destination. It also drives the soft-ban cooldown, the reboot-resume target and
    ///    the snap-back watcher, none of which armed for this path.
    ///  • the trial charge — was MISSING, so Shortcuts was an unmetered door to a metered feature.
    ///  • the warm hold — the map's 4 s re-assert is what keeps a stationary fix alive. The manual
    ///    path arms it directly (`startResendLoop`); a cross-module writer arms it by posting
    ///    `.holdLocationRequested`, which is what walk/route already do when they park.
    ///  • the stop-generation guard — a Stop landing while the FFI was in flight would otherwise be
    ///    silently undone by this success handler re-arming everything.
    static func teleport(to coord: CLLocationCoordinate2D, name: String) async -> TeleportOutcome {
        // Gate BEFORE any work: charging for a teleport we then refuse to make, or making one we
        // never charge for, are the two ways this drifts from the Simulate button.
        let allowed = await MainActor.run { CellularModeRun.isAllowedToStart }
        guard allowed else { return .notLicensed }
        // Captured before the FFI runs, exactly as `MapSelectionView.performSimulateInner` does.
        let stopGen = await MainActor.run { SimulationSession.shared.stopGeneration }
        await ensureTunnel()
        // And Wander's OWN tunnel, if the user runs one. `ensureTunnel()` above drives the DVT
        // heartbeat, not the VPN carrying it, so a Shortcut teleport arriving after the tunnel
        // auto-disconnected had nothing to inject through. No-ops unless the user opted in.
        if TunnelStartGate.isNeeded { await WanderTunnel.shared.ensureStarted() }
        let path = PairingFileStore.prepareURL().path
        // gs-loc mode injects through the proxy, not the dev tunnel — no pairing file needed.
        guard FileManager.default.fileExists(atPath: path) || GslocMode.enabled else { return .failed }
        let code: Int32 = await withCheckedContinuation { cont in
            LocationSimulationCommandQueue.submit {
                let c = simulate_location_logged(DeviceConnectionContext.targetIPAddress,
                                                 coord.latitude, coord.longitude, path,
                                                 source: .shortcut)
                cont.resume(returning: c)
            }
        }
        guard code == 0 else { return .failed }
        await MainActor.run {
            // A Stop/Panic landed while this was in flight — don't revive the hold loop or claim a
            // session the user just ended. Same guard, same reason, as the map's teleport.
            guard SimulationSession.shared.stopGeneration == stopGen else { return }
            // Order mirrors `MapSelectionView.performSimulateInner`: arm the warm hold, then mark the
            // session, then record the destination, then charge.
            NotificationCenter.default.post(
                name: .holdLocationRequested,
                object: nil,
                userInfo: ["lat": coord.latitude, "lng": coord.longitude]
            )
            SimulationSession.shared.started()
            SimulationSession.shared.noteTeleport(to: coord)
            SavedPlacesStore.recordRecent(coord, name: name)
            BackgroundLocationManager.shared.requestStart()
            if !License.shared.isLicensed { TrialManager.shared.chargeTeleport() }
            LogManager.shared.addInfoLog(String(format: "Teleported via Shortcut to %.5f, %.5f", coord.latitude, coord.longitude))
        }
        return .ok
    }
}

struct TeleportIntent: AppIntent {
    static var title: LocalizedStringResource = "Teleport to Place"
    static var description = IntentDescription(
        "Sets your simulated GPS location to an address, place name, or coordinates.",
        categoryName: "Wander")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Place",
               description: "An address, a place name, or \"lat, lng\" coordinates",
               requestValueDialog: "Where do you want to teleport?")
    var place: String

    static var parameterSummary: some ParameterSummary {
        Summary("Teleport to \(\.$place)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let coord = await WanderLocationIntent.resolveCoordinate(from: place) else {
            return .result(value: "Couldn't find “\(place)”. Try a full address or \"lat, lng\".")
        }
        // If a Cellular Mode run is outstanding, this is the pin it was asked for — file it against
        // the marker so the recovery banner's "Try again" retries the right place for a run that
        // started outside the app (where nothing else knows the destination). A no-op when no marker
        // is live, so an everyday Shortcut teleport on Wi-Fi neither arms nor touches anything.
        await MainActor.run { CellularModeRun.shared.noteRequestedCoordinate(coord) }
        switch await WanderLocationIntent.teleport(to: coord,
                                                  name: WanderLocationIntent.recentsName(for: place)) {
        case .ok:
            return .result(value: "Teleported to \(place).")
        case .notLicensed:
            return .result(value: L("intent.teleport.trial_used",
                                    fallback: "Today's free teleport is already used. Open Wander to go Pro for unlimited teleports."))
        case .failed:
            return .result(value: "Couldn't teleport — make sure your device is connected and a pairing file is imported (Settings).")
        }
    }
}

// MARK: - Start Wander's own tunnel (the action Cellular Mode sequences around)

/// Brings Wander's OWN tunnel up and does NOT return until the loopback can actually carry a
/// location.
///
/// WHY IT EXISTS. iOS gives an app no API for Airplane Mode — only Shortcuts can toggle it — and the
/// cellular sequence has to interleave `airplane ON → tunnel up → teleport → airplane OFF`. That
/// interleave is only possible if the tunnel step is an action a Shortcut can WAIT on, which is
/// exactly what an App Intent is and a `wander://` deep link is not (a link fires and returns
/// immediately, so the shortcut would have to guess a delay and would toggle the radio back on
/// underneath a half-built session).
///
/// The behaviour it exists to exploit (confirmed on device, build 139): lockdownd refuses the
/// developer-tunnel connection while the device has cellular and NO Wi-Fi *at connect time*, but it
/// does not re-evaluate an already-ESTABLISHED session. So Airplane Mode is needed for the moment
/// the connection is made and nothing more.
///
/// ⚠️ EVERY GUARD IN `ensureStarted()` IS KEPT. Nothing here re-implements, bypasses or relaxes one.
/// The checks below run only so that the cases where `ensureStarted()` deliberately returns false in
/// silence — gs-loc owns the VPN slot, the entitlement was stripped, the user never opted in —
/// arrive as a sentence someone can act on instead of a bare "failed". Wander never takes iOS's
/// single VPN slot from LocalDevVPN, Shadowrocket or a real VPN, and this intent is not an exception
/// to that.
struct StartTunnelIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Wander Tunnel"
    static var description = IntentDescription(
        "Brings Wander's own on-device tunnel up, and waits until it can actually carry a location.",
        categoryName: "Wander")

    /// TRUE on purpose. `TunnelConnectionHelpView` step 1 is "keep Wander in the foreground while the
    /// tunnel connects" — that is this app's own shipped advice, and claiming the VPN slot from a
    /// background-launched process is exactly the case it warns about. The Shortcut keeps running
    /// after the app comes forward, so the airplane-off step still fires.
    static var openAppWhenRun: Bool = true

    /// "This action is running inside a Cellular Mode run, so the radio is OFF right now."
    ///
    /// THE SAFETY NET'S ONLY WAY IN FROM OUTSIDE THE APP. The stranding marker used to be armed by
    /// the two Cellular Mode buttons in Wander and nowhere else, so a run started from the Shortcuts
    /// app, Siri, the Action Button, Control Center or an automation armed nothing — and an
    /// interrupted one of those left the phone in Airplane Mode with the app silent, while shipped
    /// copy promised recovery. Running the shortcut from outside Wander is the MAIN path, not an
    /// edge case, so the marker is armed here: the shortcut always runs this action, wherever it was
    /// launched from, and it runs it immediately after Airplane Mode goes on.
    ///
    /// It is a parameter rather than an unconditional arm because "Start Wander Tunnel" is also a
    /// perfectly ordinary action on its own, on Wi-Fi, with no airplane involvement anywhere — and
    /// arming a stranding marker for THAT would hand the user a recovery banner for a phone nobody
    /// stranded, which is worse than the bug it fixes.
    ///
    /// `false` by default, so a shortcut built before this parameter existed keeps behaving exactly
    /// as it does today: it decodes as off and this action arms nothing on its own account.
    /// `CellularModeRun.armForTunnelIntent` covers most of those stale copies anyway, by noticing
    /// that the phone has no transport at all at the moment the action runs — see its doc comment
    /// for what that second signal can and cannot see.
    @Parameter(title: "Cellular Mode run",
               description: "Switch this on in the Wander Cellular Mode shortcut, where Airplane Mode has just been turned on. It lets Wander notice if the run is interrupted before Airplane Mode goes back off. Leave it off when running this action on its own.",
               default: false)
    var cellularMode: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Start the Wander tunnel") {
            \.$cellularMode
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // ── 0. ARM THE STRANDING MARKER, BEFORE ANY DECISION IS TAKEN. ───────────────────────────
        // Deliberately ahead of every early return below: whether this action then finds the tunnel
        // already up, refuses because gs-loc owns the VPN slot, or bails on a missing entitlement,
        // the radio is ALREADY off by the time we are asked, and the shortcut still has an
        // Airplane-Mode-OFF step left to reach. What the tunnel decides has no bearing on whether
        // this phone can be stranded.
        await MainActor.run { CellularModeRun.shared.armForTunnelIntent(declaredCellularRun: cellularMode) }

        // ── 1. ALREADY USABLE ⇒ done. ────────────────────────────────────────────────────────────
        // Checked FIRST, and deliberately before the entitlement check: on a free sideload
        // `isSupported` is false while LocalDevVPN may be carrying the loopback perfectly well, and
        // telling that user "this install can't run a tunnel" would be alarming AND wrong. This is
        // also the idempotent no-op the sequence needs — running the shortcut twice costs nothing.
        if isTunnelSimEndpointReachable() {
            // Same first statement, same reason, as `ensureStarted()`: somebody wants this tunnel up.
            // Without it a disconnect armed by an earlier Stop could fire during the teleport that
            // follows this action in the Cellular Mode shortcut. Safe from any thread.
            WanderTunnel.shared.cancelAutoDisconnect()
            return .result(value: L("intent.tunnel.already_up",
                                    fallback: "The tunnel is already up — nothing to do."))
        }

        // ── 2. gs-loc owns the VPN slot. ─────────────────────────────────────────────────────────
        // Starting ours would disconnect Shadowrocket and break PoGo mode outright. Refuse loudly.
        if GslocMode.enabled {
            return .result(value: L("intent.tunnel.gsloc",
                                    fallback: "PoGo (gs-loc) mode is on, so Shadowrocket is holding iOS's single VPN slot. Wander won't take it. Turn gs-loc mode off first if you want Wander's own tunnel."))
        }

        // ── 3. No Network Extension entitlement on this signature. ───────────────────────────────
        // The free-Apple-ID re-signer strips it, so the bundled tunnel can NEVER come up here. Say so
        // instead of burning `ensureStarted()`'s 12-second timeout and reporting something vague.
        guard WanderTunnel.isSupported else {
            return .result(value: L("intent.tunnel.unsupported",
                                    fallback: "This install isn't signed with the Network Extension entitlement, so Wander can't run its own tunnel. Connect LocalDevVPN instead (Airplane Mode ON first, connect, then Airplane Mode OFF), then teleport."))
        }

        // ── 4. The user never opted in. ──────────────────────────────────────────────────────────
        // Nothing in this app claims the VPN slot until it is asked to, and an App Intent is not a
        // back door around that.
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel) else {
            return .result(value: L("intent.tunnel.opt_in",
                                    fallback: "Wander's own tunnel is switched off. Turn on Settings → Tunnel → “Connect automatically”, then run this again."))
        }

        // ── 5. The real work. ────────────────────────────────────────────────────────────────────
        // `ensureStarted()` polls the loopback rather than trusting `.connected`, which is the whole
        // reason it is reused here: `.connected` only means iOS started the provider, and injecting
        // before the route is installed fails. Do NOT replace this with a sleep.
        let ok = await WanderTunnel.shared.ensureStarted()
        if ok {
            return .result(value: L("intent.tunnel.up", fallback: "Tunnel is up and carrying traffic."))
        }

        // Diagnose the refusal AFTER the fact, so the guard order inside `ensureStarted()` stays the
        // single source of truth for the decision and this is only ever narration.
        if WanderTunnel.foreignVPNInterfaceActive() {
            return .result(value: L("intent.tunnel.foreign",
                                    fallback: "Another VPN is already holding iOS's single VPN slot, so Wander left it alone. Disconnect that VPN (or use it to carry the tunnel) and try again."))
        }
        let reason = await MainActor.run { WanderTunnel.shared.lastError }
        if let reason, !reason.isEmpty {
            return .result(value: L("intent.tunnel.failed_reason",
                                    fallback: "Couldn't bring Wander's tunnel up: ") + reason)
        }
        return .result(value: L("intent.tunnel.failed",
                                fallback: "Couldn't bring Wander's tunnel up in time. On cellular with no Wi-Fi, turn Airplane Mode ON before this step — that's what lets the tunnel connect."))
    }
}

struct StopSpoofingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Location Spoofing"
    static var description = IntentDescription(
        "Reverts to your real GPS location.", categoryName: "Wander")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await ensureTunnel()
        await MainActor.run { SimulationSession.shared.stopAll() }
        return .result(value: "Stopped — real GPS restored.")
    }
}

// MARK: - Shortcuts Provider

struct StikDebugShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnableJITIntent(),
            phrases: [
                "Enable JIT for \(\.$app) with \(.applicationName)",
                "Enable JIT for \(\.$app) using \(.applicationName)",
                "Enable JIT for \(\.$app) in \(.applicationName)",
                "\(.applicationName) enable JIT for \(\.$app)",
                "\(.applicationName) enable JIT",
                "Use \(.applicationName) to enable JIT for \(\.$app)",
                "Use \(.applicationName) to enable JIT"
            ],
            shortTitle: "Enable JIT",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: KillProcessIntent(),
            phrases: [
                "Kill \(\.$process) with \(.applicationName)",
                "Kill \(\.$process) using \(.applicationName)",
                "Kill \(\.$process) in \(.applicationName)",
                "\(.applicationName) kill \(\.$process)",
                "\(.applicationName) kill process",
                "Use \(.applicationName) to kill \(\.$process)",
                "Use \(.applicationName) to stop \(\.$process)"
            ],
            shortTitle: "Kill Process",
            systemImageName: "xmark.circle.fill"
        )
        AppShortcut(
            intent: TeleportIntent(),
            phrases: [
                // NOTE: App Shortcut phrases can only interpolate AppEntity/AppEnum params, not the
                // free-text String `place` — so the destination is asked via requestValueDialog.
                "Teleport with \(.applicationName)",
                "\(.applicationName) teleport",
                "Set my location with \(.applicationName)",
                "Change my location with \(.applicationName)",
                "Fake my location with \(.applicationName)"
            ],
            shortTitle: "Teleport",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: StartTunnelIntent(),
            phrases: [
                "Start the \(.applicationName) tunnel",
                "Connect the \(.applicationName) tunnel",
                "\(.applicationName) start tunnel",
                "\(.applicationName) connect tunnel",
                "Use \(.applicationName) to start the tunnel"
            ],
            shortTitle: "Start Tunnel",
            systemImageName: "cable.connector.horizontal"
        )
        AppShortcut(
            intent: StopSpoofingIntent(),
            phrases: [
                "Stop spoofing with \(.applicationName)",
                "Stop faking my location with \(.applicationName)",
                "Revert my location with \(.applicationName)",
                "\(.applicationName) stop spoofing"
            ],
            shortTitle: "Stop Spoofing",
            systemImageName: "stop.circle.fill"
        )
    }
}

// MARK: - Shared Tunnel Helper

func ensureTunnel() async {
    await MainActor.run {
        markTunnelDisconnected()
        startTunnelInBackground(showErrorUI: false)
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
