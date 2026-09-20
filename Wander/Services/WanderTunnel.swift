//
//  WanderTunnel.swift
//  Wander
//
//  App-side controller for Wander's bundled on-device tunnel (the TunnelProv
//  network extension). Configures + starts/stops an NETunnelProviderManager so
//  Wander no longer needs the separate LocalDevVPN app.
//
//  Tunnel design (from LocalDevVPN): device IP 10.7.0.0, fake IP 10.7.0.1.
//  Wander's engine already targets 10.7.0.1, so no change to the connection code.
//

import Foundation
import NetworkExtension

/// The "disconnect the tunnel once nothing is spoofing" preference, and the grace delays offered
/// for it. Kept next to the tunnel it governs rather than in the settings screen, because the
/// scheduler below reads the same values at fire time and the two must never drift.
enum TunnelIdleDisconnect {
    /// The delays offered in Settings, in seconds. A short list of sensible lengths beats a free
    /// text field here: the only interesting question is "long enough to re-pin without paying a
    /// restart" vs "short enough to actually free the slot".
    static let choices: [Double] = [10, 30, 60, 300, 900]

    /// 30 s. Long enough that the common "clear the pin, choose a different spot" flow never pays a
    /// tunnel restart, short enough that the VPN slot doesn't sit claimed all evening.
    static let defaultDelay: Double = 30

    /// Whether the user asked for the tunnel to come back down after a deliberate stop. Off until
    /// they say otherwise — nothing in this app tears a tunnel down on its own by default.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: UserDefaults.Keys.tunnelAutoDisconnectWhenIdle)
    }

    /// The configured grace delay. An unset (0), negative or non-finite value reads as the default
    /// rather than as "zero" — a 0 s delay would drop the tunnel the instant a pin was cleared,
    /// which is precisely what the grace period exists to prevent. Capped at an hour so a corrupted
    /// preference can't arm a timer that outlives any plausible session.
    static var delaySeconds: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: UserDefaults.Keys.tunnelAutoDisconnectDelay)
        guard stored.isFinite, stored > 0 else { return defaultDelay }
        return min(stored, 60 * 60)
    }

    /// Label for one choice. Falls back to a raw seconds count so a value stored by a future (or
    /// older) build still reads as something, instead of showing an empty row.
    static func label(for seconds: Double) -> String {
        switch seconds {
        case 10:  return L("settings.tunnel.auto_disconnect.delay.10s", fallback: "10 seconds")
        case 30:  return L("settings.tunnel.auto_disconnect.delay.30s", fallback: "30 seconds")
        case 60:  return L("settings.tunnel.auto_disconnect.delay.1m", fallback: "1 minute")
        case 300: return L("settings.tunnel.auto_disconnect.delay.5m", fallback: "5 minutes")
        case 900: return L("settings.tunnel.auto_disconnect.delay.15m", fallback: "15 minutes")
        default:  return "\(Int(seconds))s"
        }
    }
}

final class WanderTunnel: ObservableObject {
    static let shared = WanderTunnel()

    enum Status: String {
        case disconnected, connecting, connected, error
        var title: String {
            switch self {
            case .disconnected: return "Not connected"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .error: return "Error"
            }
        }
    }

    @Published var status: Status = .disconnected
    @Published var lastError: String?

    // MARK: - Capability (can this install run the tunnel AT ALL?)

    /// Whether THIS install's signature actually grants the Network Extension entitlement — i.e.
    /// whether `start()` can ever succeed.
    ///
    /// WHY it's answered up front: on the normal free-Apple-ID sideload the re-signer STRIPS
    /// `com.apple.developer.networking.networkextension`, so the bundled TunnelProv extension is
    /// never usable and `NETunnelProviderManager` can't save a config. The app used to discover this
    /// reactively — offer the feature, fail, then apologise in a footer. Reading our own embedded
    /// provisioning profile tells us before we offer anything.
    ///
    /// Cached with `static let` because it CANNOT change while the process lives: the profile is part
    /// of the signed bundle. The file is read at most once, lazily, on first access.
    ///
    /// Fails SAFE in every direction. A missing profile, unreadable bytes, an unexpected CMS wrapper,
    /// a malformed plist or an entitlement value of a shape we didn't predict all report "not
    /// supported". Nothing on this path throws, force-unwraps, or traps.
    static let isSupported: Bool = detectPacketTunnelEntitlement()

    /// The entitlement that gates `NEPacketTunnelProvider`.
    private static let packetTunnelEntitlementKey = "com.apple.developer.networking.networkextension"
    private static let packetTunnelEntitlementValue = "packet-tunnel-provider"

    private static func detectPacketTunnelEntitlement() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let plistData = embeddedPlist(in: data),
              let root = (try? PropertyListSerialization.propertyList(from: plistData,
                                                                     options: [],
                                                                     format: nil)) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any]
        else { return false }

        // The value is normally an array of provider types, but tolerate a bare string too rather
        // than reporting "unsupported" on a shape we merely didn't expect.
        let raw = entitlements[packetTunnelEntitlementKey]
        let providers: [String]
        if let list = raw as? [Any] { providers = list.compactMap { $0 as? String } }
        else if let single = raw as? String { providers = [single] }
        else { return false }

        return providers.contains { $0.contains(packetTunnelEntitlementValue) }
    }

    /// Pulls the XML plist payload out of a `.mobileprovision` file.
    ///
    /// The file is CMS/PKCS#7-signed, but the plist inside is stored as plain UTF-8 XML, so the
    /// payload can be sliced out by locating the `<?xml` … `</plist>` span. Deliberately NOT parsed
    /// with a crypto/CMS library: we are reading OUR OWN bundle to answer a UI question, not
    /// verifying a signature (iOS already did that before it launched us), and pulling in a
    /// dependency for this would be all cost.
    ///
    /// Searches for the LAST `</plist>` so a nested occurrence inside the payload can't truncate it.
    private static func embeddedPlist(in data: Data) -> Data? {
        let opening = Data("<?xml".utf8)
        let closing = Data("</plist>".utf8)
        guard let start = data.range(of: opening),
              let end = data.range(of: closing,
                                   options: .backwards,
                                   in: start.lowerBound..<data.endIndex)
        else { return nil }
        return data.subdata(in: start.lowerBound..<end.upperBound)
    }

    // NOTE (deliberate, do not "restore"): there is NO fresh-install default that turns
    // `useOwnTunnel` on. Auto-connect stays OFF until the user asks for it in Settings, on every
    // install, entitlement or not. iOS runs ONE VPN at a time, so defaulting this on would have a
    // fresh cert install silently claim the slot the user may be holding for LocalDevVPN,
    // Shadowrocket (gs-loc/PoGo mode needs it) or a real VPN. `isSupported` above decides whether to
    // OFFER the switch; it must never decide to flip it.

    // MARK: - What the RUNNING provider was actually started with

    /// The address family of the loopback the live provider was configured with, mirrored so the app
    /// side can dial the family the provider actually has instead of the one the preference wants.
    ///
    /// `PacketTunnelProvider` reads `TunnelIPv6Loopback` ONCE, in `startTunnel(options:)`. The
    /// preference can be flipped at any time. Without this mirror the two disagree the moment the
    /// toggle is touched with the tunnel up, and every inject pays for a v6 attempt that a v4-only
    /// provider can never answer.
    ///
    /// Backed by UserDefaults rather than memory alone so it survives the app being killed while the
    /// tunnel keeps running, and so it can be read off the main thread (`@Published var` cannot).
    private static let startedIPv6LoopbackKey = "WanderTunnelStartedIPv6Loopback"

    /// The ADDRESSES the live provider was started with, mirrored for exactly the same reason as the
    /// flag above. These are no longer constants: `CellularIPv6Suggester` derives them from the
    /// carrier prefix the phone had at start time, and that prefix rotates. Re-deriving at dial time
    /// would eventually dial a peer the live tunnel has no route for, which is the drift this mirror
    /// exists to prevent.
    private static let startedIPv6InterfaceKey = "WanderTunnelStartedIPv6Interface"
    private static let startedIPv6TargetKey = "WanderTunnelStartedIPv6Target"

    /// Thread-safe read for the dial path. False whenever our tunnel isn't up.
    static var providerStartedWithIPv6Loopback: Bool {
        UserDefaults.standard.bool(forKey: startedIPv6LoopbackKey)
    }

    /// The peer address the live provider was numbered with, or nil when our tunnel isn't up (or was
    /// started by a build that predates this). Empty strings read as nil so a half-written
    /// preference can never become an address the dial path tries to parse.
    static var startedIPv6TargetAddress: String? { nonEmpty(startedIPv6TargetKey) }
    /// The tunnel interface's own address on the live provider. Diagnostics only.
    static var startedIPv6InterfaceAddress: String? { nonEmpty(startedIPv6InterfaceKey) }

    private static func nonEmpty(_ key: String) -> String? {
        let stored = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    /// Same value, observable, for the settings UI's "restart to apply" notice.
    @Published private(set) var startedIPv6Loopback: Bool =
        UserDefaults.standard.bool(forKey: WanderTunnel.startedIPv6LoopbackKey)

    /// The peer the live provider is numbered with, observable, so the settings screen can show what
    /// is running next to what a restart would change it to.
    @Published private(set) var startedIPv6Target: String? = WanderTunnel.startedIPv6TargetAddress

    /// Record what the provider was started with. Passing `nil` addresses (or `false`) CLEARS them,
    /// so a stopped tunnel can never leave an address behind for the dial path to follow.
    private func setStartedIPv6Loopback(_ value: Bool,
                                        addresses: DeviceConnectionContext.PlannedIPv6Loopback? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: Self.startedIPv6LoopbackKey)
        if value, let addresses {
            defaults.set(addresses.interfaceAddress, forKey: Self.startedIPv6InterfaceKey)
            defaults.set(addresses.targetAddress, forKey: Self.startedIPv6TargetKey)
        } else {
            defaults.removeObject(forKey: Self.startedIPv6InterfaceKey)
            defaults.removeObject(forKey: Self.startedIPv6TargetKey)
        }
        let target = (value ? addresses?.targetAddress : nil)
        DispatchQueue.main.async {
            self.startedIPv6Loopback = value
            self.startedIPv6Target = target
        }
    }

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    private var providerBundleId: String {
        (Bundle.main.bundleIdentifier ?? "com.stik.stikdebug") + ".TunnelProv"
    }

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let conn = note.object as? NEVPNConnection,
                  conn == self.manager?.connection else { return }
            self.update(conn.status)
        }
        load()
    }

    private func setStatus(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.lastError = msg; self.status = .error }
        // Capture the interface state AT the failure. Which interfaces exist (and which subnets the
        // tunnel address does or doesn't sit inside) is the whole question on cellular, and asking
        // afterwards gets a different answer. Throttled internally — this can be reached in a retry loop.
        NetworkInterfaceDump.logOnFailure(reason: "tunnel start failed: \(msg)")
    }

    private func load() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self else { return }
            let mine = managers?.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleId
            }
            self.manager = mine
            if let s = mine?.connection.status {
                self.update(s)
            } else {
                // No config of ours exists at all, so nothing of ours is running — don't let a
                // recorded family survive from a previous launch.
                self.setStartedIPv6Loopback(false)
            }
        }
    }

    func toggle() {
        // Either direction, this is the user taking manual control of the tunnel, which outranks a
        // disconnect we scheduled on their behalf. Connecting and then having our timer drop it 20 s
        // later would be indistinguishable from a bug.
        cancelAutoDisconnect()
        (status == .connected || status == .connecting) ? stop() : start()
    }

    // MARK: - Auto-disconnect once nothing is spoofing
    //
    // Opt-in (`tunnelAutoDisconnectWhenIdle`), and armed from exactly TWO places, both of them a
    // deliberate stop: `SimulationSession.stopAll()` (the global Stop) and
    // `SimulationSession.markStopped()` (the Map tab's two Stop buttons, i.e. how a teleport
    // session ends). Both arm under the same two conditions — a human asked, and something was
    // actually running (see `SimulationSession.StopSource`).
    //
    // `markStopped()` does NOT broadcast `.stopSimulationRequested`, so it stands nobody down and
    // the other writers keep injecting straight through it. That is survivable ONLY because arming
    // is a request rather than a decision: `fireAutoDisconnect` below re-asks
    // `LocationSessionActivity.mayHoldOpenSession` on the location queue, and a writer still
    // injecting has pushed the recorded last write past that stop's clear, so the tunnel is left
    // up. Removing that guard would make the `markStopped()` arm unsafe again.
    //
    // There is no idle timer, no lifecycle hook and no inferred-idle path here. Do not add one:
    // freeing the transport under a live session reverts the device to real GPS, which is the
    // regression class this app has shipped twice (build 84's probe-triggered cleanup, build 124's
    // orphaned sessions).
    //
    // The pending-disconnect state is LOCK-GUARDED, not main-thread-only: `cancelAutoDisconnect()`
    // is now called from `start()` and from every location write (`LocationSimulationCommandQueue
    // .submit`), and those run on whatever queue their caller was on. A cancel that had to hop to
    // main would no longer be ordered before the FFI enqueue it exists to protect, which is the
    // whole point of it.

    private let autoDisconnectLock = NSLock()

    /// The one pending disconnect. Exactly one, ever: scheduling supersedes rather than stacks, so
    /// two timers can never race to stop the same tunnel. Guarded by `autoDisconnectLock`.
    private var autoDisconnectWork: DispatchWorkItem?

    /// Bumped by every cancel and every new schedule. Everything downstream carries the value it was
    /// created with and does nothing if it no longer matches, which closes the windows a plain
    /// `DispatchWorkItem.cancel()` cannot: the wait for the location queue to drain at arm time, the
    /// hop onto the main actor at fire time, and the SECOND drain the fire path makes before it
    /// commits. Guarded by `autoDisconnectLock`.
    private var autoDisconnectGeneration = 0

    /// How far past its deadline a pending disconnect may run and still be honoured. See
    /// `fireAutoDisconnect` for why anything beyond this is dropped rather than obeyed.
    private static let autoDisconnectOverdueTolerance: TimeInterval = 5

    /// Cancel any pending auto-disconnect.
    ///
    /// Called when the user starts spoofing again, when they work the tunnel by hand, when the
    /// setting is switched off underneath a pending timer, at the top of `start()`, and — the
    /// important one — before EVERY location write is enqueued. Safe from any thread.
    func cancelAutoDisconnect() {
        autoDisconnectLock.lock()
        autoDisconnectGeneration &+= 1
        let work = autoDisconnectWork
        autoDisconnectWork = nil
        autoDisconnectLock.unlock()
        work?.cancel()
    }

    /// The current cancellation token. Anything that captured an older one has been superseded.
    private var currentAutoDisconnectGeneration: Int {
        autoDisconnectLock.lock(); defer { autoDisconnectLock.unlock() }
        return autoDisconnectGeneration
    }

    /// Arm the grace-delayed disconnect after a deliberate stop.
    ///
    /// ORDERING — the reason this is not just an `asyncAfter`. `stopAll()` clears the device location
    /// ASYNCHRONOUSLY, on the serial `LocationSimulationCommandQueue`. The tunnel is the transport
    /// that clear rides on, so stopping it first would pull the socket out from under an in-flight
    /// clear and leave exactly the orphaned session this codebase has already been burned by. The
    /// fix is structural, not temporal: we hop through that same serial queue, so the grace timer is
    /// not even ARMED until every command queued ahead of us (the clear itself) has returned. A
    /// 10-second delay is therefore just as correct as a 15-minute one — correctness never depends
    /// on the delay outrunning the clear.
    ///
    /// Fails safe in the pathological case: if the location queue were wedged, the timer is simply
    /// never armed and the tunnel stays up. Leaving a tunnel connected costs the user a VPN slot;
    /// tearing it down at the wrong moment costs them their spoof.
    ///
    /// The SAME drain is repeated at fire time (see `fireAutoDisconnect`). Draining here only proves
    /// the queue was clear when the timer started; the delay in between is exactly when a new
    /// teleport shows up.
    func scheduleAutoDisconnectWhenIdle() {
        // Supersede first, synchronously, so two stops in quick succession leave one pending
        // disconnect rather than two.
        cancelAutoDisconnect()
        let generation = currentAutoDisconnectGeneration

        guard Self.isSupported,
              TunnelIdleDisconnect.isEnabled,
              UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel)
        else { return }

        LocationSimulationCommandQueue.shared.async {
            DispatchQueue.main.async { [weak self] in
                self?.armAutoDisconnect(generation: generation)
            }
        }
    }

    /// Start the grace timer, now that the location work has drained. Main thread.
    private func armAutoDisconnect(generation: Int) {
        // The user started spoofing again (or took the tunnel by hand) while the queue was draining.
        // `cancel()` can't reach this — the work item doesn't exist yet — so the token does.
        guard generation == currentAutoDisconnectGeneration else { return }
        guard TunnelIdleDisconnect.isEnabled,
              UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel)
        else { return }

        let delay = TunnelIdleDisconnect.delaySeconds
        // WALL-CLOCK deadline, recorded here, checked at fire time. `DispatchQueue.main.asyncAfter`
        // is NOT discarded while the app is suspended — an overdue block runs immediately on the
        // next foreground — so the fire path has to be able to tell "my delay elapsed" from "the app
        // was away for twenty minutes and this is the backlog landing".
        let deadline = Date().addingTimeInterval(delay)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fireAutoDisconnect(generation: generation, deadline: deadline) }
        }
        autoDisconnectLock.lock()
        autoDisconnectWork = work
        autoDisconnectLock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The timer fired. RE-CHECK everything — the state captured when this was scheduled is minutes
    /// old and any of it may have changed. Anything unexpected means do nothing at all: not stopping
    /// a tunnel is always the safe answer.
    ///
    /// The last two checks are the ones that matter, and they are made AFTER a hop through the
    /// serial location queue rather than before it:
    ///
    ///   * The hop DRAINS the queue. When our block runs there, every location command enqueued
    ///     before it — including a teleport whose un-timeout-able DVT rebuild is still going — has
    ///     already returned. This is the half of the fix that no delay length could buy: it is FIFO,
    ///     not timing.
    ///   * Work enqueued AFTER our hop is covered by the generation token, because
    ///     `LocationSimulationCommandQueue.submit` cancels the pending disconnect BEFORE it enqueues
    ///     anything. So a writer that starts mid-drain has already invalidated us by the time we
    ///     come back to main to commit.
    ///
    /// Together those remove the window rather than narrow it: there is no interleaving in which the
    /// tunnel is stopped while a command is queued, running, or holding an open session handle.
    @MainActor
    private func fireAutoDisconnect(generation: Int, deadline: Date) {
        // Superseded between the work item firing and this landing on the main actor (that hop is
        // not covered by `cancel()`). Checked BEFORE clearing the handle, so a newer pending
        // disconnect isn't wiped by a stale one. The generation is deliberately NOT bumped here —
        // the drain below still has to be able to notice a writer arriving underneath it.
        guard generation == currentAutoDisconnectGeneration else { return }
        // The work item has ALREADY run by the time we are here, so the handle is dead whatever we
        // decide below — clearing it now is bookkeeping, not policy. What used to make that a bug
        // was the bail-outs further down silently throwing the disconnect away; the one bail that is
        // genuinely transient (work still on the location queue) now re-arms itself instead. See it
        // below.
        autoDisconnectLock.lock()
        autoDisconnectWork = nil
        autoDisconnectLock.unlock()

        // OVERDUE ⇒ DROP. A suspended app's main queue is not discarded: whatever was due while we
        // were away runs the instant we come back. Honouring it would mean the user reopens Wander
        // and the tunnel drops in their face, attributed to a grace delay that expired while the
        // phone was in their pocket. The user's model is "N seconds after I stop, if I haven't
        // started again" — not "the next time I open the app". Dropping costs a VPN slot until the
        // next stop; honouring costs a tunnel at the exact moment someone is about to use it.
        guard Date() <= deadline.addingTimeInterval(Self.autoDisconnectOverdueTolerance) else {
            LogManager.shared.addInfoLog("Tunnel: auto-disconnect was overdue (app was suspended) — dropping it, leaving the tunnel up")
            return
        }

        guard TunnelIdleDisconnect.isEnabled else { return }
        // Never stop a tunnel the user didn't ask us to run.
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel) else { return }
        // Only ever stop a tunnel that is actually up. Calling stop() on a connecting one would
        // abort a start the user just asked for; on a disconnected one it's a pointless state write.
        guard status == .connected else { return }
        // Kept as an ADDITIONAL guard, not as the last line of defence — `isActive` is false for the
        // whole of a teleport's rebuild, so it cannot be trusted to mean "nothing is happening".
        guard !SimulationSession.shared.isActive else { return }

        LocationSimulationCommandQueue.shared.async {
            // On the serial queue: nothing else is touching the FFI right now, and every command
            // queued ahead of us has finished and recorded itself.
            let holdsSession = LocationSessionActivity.mayHoldOpenSession
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A writer arrived while we were draining — `submit` bumped the token before its FFI
                // was enqueued, so this is exact, not a race we hope to win.
                guard generation == self.currentAutoDisconnectGeneration else { return }
                guard TunnelIdleDisconnect.isEnabled,
                      UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel),
                      self.status == .connected,
                      !SimulationSession.shared.isActive
                else { return }
                guard !LocationSessionActivity.isWriteInFlight else {
                    // TRANSIENT, so RE-ARM instead of discarding. A queue that has work on it will
                    // drain — most often this is a stop's own echo (`stopAll()` re-broadcasts and a
                    // second clear is enqueued through `submitClear`, which by design does not
                    // cancel us). Simply returning would throw the disconnect away until the user
                    // performed another qualifying stop, i.e. the feature would silently not work
                    // for anyone whose stop echoed. `scheduleAutoDisconnectWhenIdle()` supersedes
                    // this generation, waits for the queue to drain again, and re-checks every
                    // guard from scratch. It cannot spin: a real writer goes through `submit`,
                    // which cancels, so the re-armed timer dies at its generation check.
                    LogManager.shared.addInfoLog("Tunnel: a location command is in flight — re-arming the disconnect")
                    self.scheduleAutoDisconnectWhenIdle()
                    return
                }
                guard !holdsSession else {
                    // NOT transient — a handle stays open until something clears it, so re-arming
                    // here would just retry forever against a state only a stop can change. The
                    // next deliberate stop arms again, which is exactly when we want to look.
                    LogManager.shared.addInfoLog("Tunnel: a location session handle may still be open — leaving the tunnel up")
                    return
                }
                LogManager.shared.addInfoLog("Tunnel: no simulation running — disconnecting after the grace delay")
                self.stop()
            }
        }
    }

    /// True when a tunnel interface exists that isn't ours — i.e. LocalDevVPN, Shadowrocket, or a real VPN
    /// is up. Used to keep auto-start from stealing iOS's single VPN slot out from under the user.
    ///
    /// utun0 always exists on iOS, so a bare "any utun" test is useless — it would report a VPN forever.
    /// Require a tunnel interface carrying an actual IPv4 address, which a live tunnel has and the idle
    /// system utun does not. Only consulted when OUR tunnel is not already connected/connecting, so a
    /// running Wander tunnel never blocks itself.
    static func foreignVPNInterfaceActive() -> Bool {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return false }
        defer { freeifaddrs(addrs) }
        var found = false
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let raw = ptr.pointee.ifa_name else { continue }
            let name = String(cString: raw)
            guard name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tap") else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard (ptr.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            found = true
            break
        }
        return found
    }

    /// Bring the tunnel up if it isn't, and resolve only once it can actually carry traffic.
    ///
    /// WHY: nothing in the app restarted this tunnel if the VPN itself died — `TunnelHealthMonitor`
    /// re-asserted the last teleport but never touched `WanderTunnel`, so a dropped VPN left a silently
    /// dead session the user had to notice and fix by hand.
    ///
    /// Readiness is the endpoint probe, NOT a fixed sleep: `.connected` only means iOS started the
    /// provider, and injecting before the loopback route is installed fails. `isTunnelSimEndpointReachable()`
    /// is the already-shipped bounded TCP probe to ip:49152, which is exactly the thing that has to work.
    ///
    /// `.reasserting` is treated as UP on purpose. iOS reports it during a normal network change; calling
    /// start() then would bounce a tunnel that is about to recover and kill the live, connection-scoped
    /// DVT session with it — the bug class this app just spent a long night fixing.
    @discardableResult
    func ensureStarted(timeout: TimeInterval = 12) async -> Bool {
        // FIRST STATEMENT, for the same reason it is the first statement of `start()` — and it is
        // NOT covered by that one. Every path below can skip `start()` entirely (the endpoint
        // already answers, or the status is already .connected/.connecting), and this function then
        // polls for up to `timeout` seconds. A disconnect armed before we got here would fire
        // squarely inside that poll, tearing down the very tunnel a mode is waiting on. Cancelling
        // here means "somebody wants this tunnel up" regardless of which branch we take. Safe from
        // any thread.
        cancelAutoDisconnect()
        // Opt-in only. start() sets isEnabled + saves, which takes iOS's single VPN slot away from
        // whatever the user actually chose (LocalDevVPN, Shadowrocket, a real VPN).
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.useOwnTunnel) else { return false }
        // gs-loc needs Shadowrocket to hold that slot; stealing it would break PoGo mode outright.
        guard !GslocMode.enabled else { return false }

        // Someone else's tunnel is already doing the job — leave it alone.
        //
        // iOS runs ONE VPN at a time, and start() sets isEnabled + saves, which DISCONNECTS whatever is
        // currently connected. If LocalDevVPN is up and carrying the loopback, starting ours would tear
        // down a working tunnel and take the spoof with it — strictly worse than doing nothing.
        //
        // ⚠️ ASK THE CHEAP, CELLULAR-SAFE QUESTION FIRST. This function defined "usable" as "I can open
        // a NEW connection to it", and on mobile data that can never be true even for a session that is
        // carrying traffic right now (`SO_RESTRICT_DENY_CELLULAR` on the pairing listener — the wall is
        // on connection BIRTH only). So every cellular caller burned the full 12 s timeout, logged an
        // interface dump, and was told the tunnel was down while the spoof was live. A confirmed inject
        // from the device is the better evidence, and it is the same test `TunnelHealthMonitor` uses.
        if TunnelInjectStatus.hasRecentConfirmedSuccess() { return true }
        if isTunnelSimEndpointReachable() { return true }

        // Even when the endpoint isn't answering, another VPN may be mid-handshake or briefly stalled
        // (exactly what a network transition looks like). Claiming the slot then would kill a tunnel that
        // was about to recover. Only start ours when no foreign tunnel interface is present at all.
        if Self.foreignVPNInterfaceActive(), status != .connected, status != .connecting {
            return false
        }

        if status != .connected && status != .connecting { start() }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            // Fail fast on the free-sideload case rather than burning the whole timeout: the NE
            // entitlement is stripped there, so the tunnel can never come up and LocalDevVPN is the path.
            if status == .error { return false }   // fail() already dumped the interfaces
            if isTunnelSimEndpointReachable() { return true }
        }
        NetworkInterfaceDump.logOnFailure(
            reason: "endpoint never became reachable within \(Int(timeout))s (status \(status.rawValue))")
        return false
    }

    func start() {
        // FIRST STATEMENT, deliberately. The Settings/gs-loc buttons, `restart()` and `toggle()`
        // all come through here, and a disconnect scheduled before any of them must not be allowed
        // to undo the start that follows. The `status == .connected` guard at fire time is NOT
        // enough on its own: `.connected` goes true before the endpoint can carry traffic, so a
        // stale timer could land squarely inside that window. Safe from any thread.
        //
        // This does NOT cover `ensureStarted()`, which reaches us only on one of its branches — it
        // cancels for itself, at its own first statement.
        cancelAutoDisconnect()
        DispatchQueue.main.async { self.lastError = nil }
        setStatus(.connecting)
        ensureManager { [weak self] mgr in
            guard let self else { return }
            // No guessing any more — `isSupported` read the entitlement out of our own profile.
            guard let mgr else {
                self.fail(Self.isSupported
                          ? "Couldn't create the VPN configuration"
                          : "This install isn't signed with the Network Extension entitlement")
                return
            }
            mgr.isEnabled = true
            // Push the two saved-preference routing levers onto the profile BEFORE the save below.
            // Both default OFF, so this is a no-op on an untouched install. It has to happen here and
            // not in ensureManager's new-manager branch: that branch only runs when no profile exists,
            // so anyone who has ever started the tunnel would keep the old values forever.
            // Apple documents enforceRoutes as superseding the system routing table — which is what
            // claims a tunnel address that sits inside a physical interface's subnet.
            TunnelRoutePolicy.applyRoutePolicy(to: mgr)
            mgr.saveToPreferences { err in
                if let err { self.fail("save: \(err.localizedDescription)"); return }
                mgr.loadFromPreferences { _ in
                    do {
                        // Configurable so the tunnel can move onto the phone's Wi-Fi subnet on iOS 26.4+
                        // (Apple drops the default 10.7.0.x loopback address there). Defaults preserve the
                        // pre-26.4 behavior. Note: TunnelProv's "TunnelDeviceIP" option = the interface IP
                        // (our tunnelInterfaceIP key), "TunnelFakeIP" = the peer Wander connects to (our
                        // targetDeviceIP key). See Wander/Views/TunnelIPSettingsView.swift.
                        let d = UserDefaults.standard
                        let interfaceIP = d.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0"
                        let fakeIP = DeviceConnectionContext.targetIPAddress
                        let mask = d.string(forKey: UserDefaults.Keys.tunnelSubnetMask) ?? "255.255.255.0"
                        // Experimental all-IPv6 loopback, opt-in and default off. When off, the
                        // provider receives false and configures itself exactly as it did before.
                        //
                        // Recorded BEFORE the call, and cleared again if the call throws, so the
                        // app-side dial can only ever ask for the family this provider was actually
                        // configured with. Reading the preference at dial time instead is what let
                        // the two drift apart. Note this reads the *ForOwnTunnel* gate, not
                        // `isIPv6LoopbackEnabled` — the latter asks what the running provider has,
                        // which is precisely the value being established here.
                        let ipv6Enabled = DeviceConnectionContext.isIPv6LoopbackRequestedForOwnTunnel
                        // WHERE THE v6 PAIR IS DECIDED — once, here, from one interface snapshot.
                        //
                        // The shipped experiment hardcoded a ULA, which belongs to no interface and
                        // therefore fails the placement half of the believed lockdownd rule by
                        // construction. `plannedIPv6Loopback()` carves the pair out of the CARRIER's
                        // routable /64 instead, which is the only prefix on a cellular-only phone
                        // that is both non-utun and unowned. It falls back to the old ULA when there
                        // is no such prefix, so nothing is taken away.
                        //
                        // Derived at START, not at dial time, because the carrier prefix rotates and
                        // the provider reads these options exactly once. The pair is recorded on the
                        // line below so the dial path follows the LIVE tunnel rather than a fresh
                        // guess. With the experiment off this whole block is nil and the options are
                        // byte-for-byte what they were.
                        let ipv6Plan = ipv6Enabled ? DeviceConnectionContext.plannedIPv6Loopback() : nil
                        self.setStartedIPv6Loopback(ipv6Enabled, addresses: ipv6Plan)
                        if let ipv6Plan {
                            LogManager.shared.addInfoLog(
                                "Tunnel: IPv6 experiment ON — interface \(ipv6Plan.interfaceAddress), dialling \(ipv6Plan.targetAddress), /\(ipv6Plan.prefixLength) · \(ipv6Plan.sourceLabel)")
                        }
                        try mgr.connection.startVPNTunnel(options: [
                            "TunnelDeviceIP": interfaceIP as NSObject,
                            "TunnelFakeIP": fakeIP as NSObject,
                            "TunnelSubnetMask": mask as NSObject,
                            "TunnelIPv6Loopback": NSNumber(value: ipv6Enabled),
                            "TunnelDeviceIPv6": (ipv6Plan?.interfaceAddress
                                                 ?? DeviceConnectionContext.defaultTunnelInterfaceIPv6) as NSObject,
                            "TunnelFakeIPv6": (ipv6Plan?.targetAddress
                                               ?? DeviceConnectionContext.defaultTargetIPv6Address) as NSObject,
                            "TunnelIPv6PrefixLength": NSNumber(value: ipv6Plan?.prefixLength
                                                               ?? DeviceConnectionContext.defaultTunnelIPv6PrefixLength),
                        ])
                    } catch {
                        self.setStartedIPv6Loopback(false)
                        self.fail("start: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func stop() {
        setStatus(.disconnected)
        setStartedIPv6Loopback(false)
        manager?.connection.stopVPNTunnel()
    }

    /// Stop then start, so a changed loopback family actually reaches the provider — it only reads its
    /// options in `startTunnel(options:)`.
    ///
    /// Only ever called from an explicit button the user taps in Tunnel IP settings. Nothing restarts
    /// the tunnel automatically: a spontaneous teardown is exactly the thing that kills a live,
    /// connection-scoped DVT session, and the health monitor's reconnect logic is not to be raced.
    func restart() {
        // Same reasoning as `toggle()`: this only ever runs because the user tapped Restart, and a
        // disconnect we scheduled must not undo a tunnel they just explicitly asked to come back up.
        cancelAutoDisconnect()
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
        }
    }

    private func ensureManager(_ completion: @escaping (NETunnelProviderManager?) -> Void) {
        if let m = manager { completion(m); return }
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            guard let self else { completion(nil); return }
            if let existing = managers?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.providerBundleId
            }) {
                self.manager = existing
                completion(existing)
                return
            }
            let m = NETunnelProviderManager()
            m.localizedDescription = "Wander Tunnel"
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleId
            proto.serverAddress = "Wander on-device tunnel"
            m.protocolConfiguration = proto
            m.isEnabled = true
            m.saveToPreferences { err in
                if let err {
                    DispatchQueue.main.async { self.lastError = "config: \(err.localizedDescription)" }
                    completion(nil); return
                }
                self.manager = m
                completion(m)
            }
        }
    }

    private func update(_ s: NEVPNStatus) {
        switch s {
        case .connected: setStatus(.connected)
        case .connecting, .reasserting: setStatus(.connecting)
        case .disconnecting, .disconnected, .invalid:
            setStatus(.disconnected)
            // The provider is gone, so whatever family it had is gone with it. Clearing here (rather
            // than only in stop()) also covers the tunnel dying on its own and the app relaunching
            // into a dead tunnel — load() routes the current status through here.
            setStartedIPv6Loopback(false)
        @unknown default:
            setStatus(.error)
            setStartedIPv6Loopback(false)
        }
    }
}
