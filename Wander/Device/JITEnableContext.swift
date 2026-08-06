//
//  JITEnableContext.swift
//  Wander
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import idevice
import Darwin

typealias LogFunc = (String?) -> Void
typealias DebugAppCallback = (_ pid: Int32, _ debugProxy: OpaquePointer?, _ remoteServer: OpaquePointer?, _ semaphore: DispatchSemaphore) -> Void
typealias SyslogLineHandler = (String) -> Void
typealias SyslogErrorHandler = (NSError?) -> Void

final class JITEnableContext {
    static let shared = JITEnableContext()

    private struct TunnelHandles {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?

        mutating func free() {
            if let handshake {
                rsd_handshake_free(handshake)
                self.handshake = nil
            }
            if let adapter {
                adapter_free(adapter)
                self.adapter = nil
            }
        }
    }

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?

    private let tunnelLock = NSLock()
    private var tunnelConnecting = false

    /// How long a second caller will wait to join an in-flight tunnel creation before giving up. Must
    /// stay well under the user's patience: a wedged creation should surface as a retryable error, never
    /// as a permanently stuck "reconnecting…".
    static let tunnelJoinTimeout: TimeInterval = 12
    private var tunnelSemaphore: DispatchSemaphore?
    private var lastTunnelError: NSError?

    private let syslogQueue = DispatchQueue(label: "com.stik.syslogrelay.queue")
    private var syslogStreaming = false
    private var syslogClient: OpaquePointer?
    private var syslogLineHandler: SyslogLineHandler?
    private var syslogErrorHandler: SyslogErrorHandler?

    var adapterHandle: OpaquePointer? { adapter }
    var handshakeHandle: OpaquePointer? { handshake }

    private init() {
        let logURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idevice_log.txt")

        // Rotate at launch: the FFI logger only ever APPENDS to this file, so over weeks of use it
        // would grow unbounded and eat a power user's storage. Above a 5 MB cap, drop it so a fresh,
        // bounded log starts. (Bug-report diagnostics use the in-memory LogManager, not this file.)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value, size > 5_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }

        var path = Array(logURL.path.utf8CString)
        path.withUnsafeMutableBufferPointer { buffer in
            _ = idevice_init_logger(Info, Debug, buffer.baseAddress)
        }
    }

    deinit {
        stopSyslogRelay()
        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }
    }

    private func makeError(_ message: String, code: Int = -1) -> NSError {
        NSError(
            domain: "StikDebug",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func nsString(from cString: UnsafePointer<CChar>?, fallback: String) -> String {
        guard let cString, let string = String(validatingUTF8: cString) else {
            return fallback
        }
        return string
    }

    private func error(from ffiError: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let ffiError else {
            return makeError(fallback)
        }
        let message = nsString(from: ffiError.pointee.message, fallback: fallback)
        let error = makeError(message, code: Int(ffiError.pointee.code))
        idevice_error_free(ffiError)
        return error
    }

    private func routeLog(_ message: String) {
        if message.localizedCaseInsensitiveContains("error") {
            LogManager.shared.addErrorLog(message)
        } else if message.localizedCaseInsensitiveContains("warning") {
            LogManager.shared.addWarningLog(message)
        } else if message.localizedCaseInsensitiveContains("debug") {
            LogManager.shared.addDebugLog(message)
        } else {
            LogManager.shared.addInfoLog(message)
        }
    }

    private func emitLog(_ message: String, logger: LogFunc?) {
        routeLog(message)
        logger?(message)
    }

    private func getPairingFile() throws -> OpaquePointer {
        let pairingFileURL = PairingFileStore.prepareURL()

        guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            throw makeError("Pairing file not found!", code: -17)
        }

        var pairingFile: OpaquePointer?
        let ffiError = pairingFileURL.path.withCString { path in
            rp_pairing_file_read(path, &pairingFile)
        }

        if let ffiError {
            throw error(from: ffiError, fallback: "Failed to read pairing file!")
        }

        guard let pairingFile else {
            throw makeError("Failed to read pairing file!", code: -17)
        }

        return pairingFile
    }

    /// Bounded TCP reachability probe to the device tunnel endpoint (10.7.0.1:49152), so we can
    /// fail fast when the VPN is down. `tunnel_create_rppairing` has NO timeout and would
    /// otherwise hang, holding `tunnelConnecting` and blocking every later attempt — which is
    /// why the setup checklist stayed stuck on X even after the VPN came back.
    ///
    /// Family-agnostic: it probes whatever address it is handed, IPv4 or IPv6. That matters because
    /// this probe runs BEFORE the FFI call and a failure here gates the whole attempt — a hardcoded
    /// AF_INET probe would fail an IPv6 dial before the IPv6 dial was ever tried, and the result would
    /// read as "IPv6 doesn't work" when the v6 path was never reached.
    ///
    /// The socket work now lives in `EndpointProbe` so the REASON survives: this used to return a bare
    /// Bool, and every caller then reported the same "Can't reach the device tunnel" whether a daemon
    /// had refused the connection (packets flow — policy), no route existed (packets never left the
    /// phone — routing), or the SYN vanished (blackhole). Those have completely different fixes. The
    /// Bool contract, the 3 s default and the semantics ("true only on a completed handshake") are
    /// unchanged; the detail is written alongside it, not returned through it.
    private func isTunnelEndpointReachable(address: String = DeviceConnectionContext.targetIPAddress,
                                           timeoutSeconds: Double = 3) -> Bool {
        let result = EndpointProbe.probe(address, timeoutSeconds: timeoutSeconds)
        EndpointProbeLog.record(result, context: "tunnel dial pre-probe:")
        return result.isReachable
    }

    /// Dials the developer tunnel, trying each candidate address in turn.
    ///
    /// With the IPv6 experiment OFF — the default — `dialTargets()` returns exactly one element (the
    /// same IPv4 address as before), so this runs the identical single attempt and throws the identical
    /// error. With it ON, IPv6 is tried FIRST and IPv4 is still tried after it, so a user can never end
    /// up worse off than the shipping path.
    private func createTunnel(hostname: String) throws -> TunnelHandles {
        let targets = DeviceConnectionContext.dialTargets()
        var lastError: Error = makeError("Can't reach the device tunnel — connect the VPN and try again.", code: -19)

        for target in targets {
            do {
                let handles = try createTunnelAttempt(hostname: hostname, target: target)
                if targets.count > 1 {
                    SpoofTrace.log("tunnel dial OK over \(target.familyLabel) (\(target.address))")
                }
                return handles
            } catch {
                lastError = error
                if targets.count > 1 {
                    SpoofTrace.log("tunnel dial FAILED over \(target.familyLabel) (\(target.address)): \(error.localizedDescription)")
                }
            }
        }

        throw lastError
    }

    private func createTunnelAttempt(hostname: String, target: DeviceConnectionContext.DialTarget) throws -> TunnelHandles {
        // Fail fast when the VPN/tunnel route is down (see isTunnelEndpointReachable) so the
        // un-timeout-able native call below never hangs and wedges future attempts.
        // The bound travels with the candidate: IPv4 keeps the shipping 3s, the speculative IPv6 leg
        // gets a tighter one so adding it can't stretch the caller's overall budget (see
        // DialTarget.probeTimeoutSeconds).
        guard isTunnelEndpointReachable(address: target.address,
                                        timeoutSeconds: target.probeTimeoutSeconds) else {
            throw makeError("Can't reach the device tunnel — connect the VPN and try again.", code: -19)
        }
        let pairingFile = try getPairingFile()
        defer { rp_pairing_file_free(pairingFile) }

        // sockaddr_in for an IPv4 literal, sockaddr_in6 for an IPv6 one, each with its own exact
        // socklen — which is what the FFI's generic `const idevice_sockaddr *` + socklen pair is for.
        guard let endpoint = DeviceConnectionContext.makeSocketAddress(target.address) else {
            throw makeError("Failed to parse target IP address.", code: -18)
        }

        var tunnel = TunnelHandles()
        let ffiError = hostname.withCString { hostname in
            endpoint.withSockaddr { pointer, length in
                tunnel_create_rppairing(
                    pointer,
                    length,
                    hostname,
                    pairingFile,
                    nil,
                    nil,
                    &tunnel.adapter,
                    &tunnel.handshake
                )
            }
        }

        if let ffiError {
            // Free whatever the failed call still managed to hand back before throwing. The FFI can
            // populate one handle and then fail on the other, and the pre-existing code path dropped
            // those on the floor. That leaked once per failed inject; with a retry loop above it, it
            // would leak once per candidate. Same treatment as the incomplete-handles branch below.
            var partialTunnel = tunnel
            partialTunnel.free()
            throw error(from: ffiError, fallback: "Failed to create tunnel")
        }

        guard tunnel.adapter != nil, tunnel.handshake != nil else {
            var incompleteTunnel = tunnel
            incompleteTunnel.free()
            throw makeError("Tunnel was created without valid handles")
        }

        return tunnel
    }

    func startTunnel() throws {
        tunnelLock.lock()
        if tunnelConnecting {
            let waitSemaphore = tunnelSemaphore
            tunnelLock.unlock()

            if let waitSemaphore {
                // BOUNDED. The in-flight creation can hang (the RSD handshake below is un-timeout-able
                // and a half-open socket during a network transition — e.g. Airplane Mode toggling —
                // never returns). An unbounded wait here blocked EVERY later attempt forever, which is
                // what left the tunnel permanently "reconnecting…" until the app was force-quit.
                if waitSemaphore.wait(timeout: .now() + Self.tunnelJoinTimeout) == .timedOut {
                    throw makeError("Tunnel is still connecting — try again in a moment.", code: -20)
                }
                waitSemaphore.signal()
            }

            if let lastTunnelError {
                throw lastTunnelError
            }
            return
        }

        tunnelConnecting = true
        let completionSemaphore = DispatchSemaphore(value: 0)
        tunnelSemaphore = completionSemaphore
        tunnelLock.unlock()

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        var finalError: NSError?

        defer {
            tunnelLock.lock()
            tunnelConnecting = false
            tunnelSemaphore = nil
            lastTunnelError = finalError
            tunnelLock.unlock()
            completionSemaphore.signal()
        }

        do {
            let newTunnel = try createTunnel(hostname: "StikDebug")
            newAdapter = newTunnel.adapter
            newHandshake = newTunnel.handshake
        } catch let tunnelError as NSError {
            finalError = tunnelError
            throw tunnelError
        }

        if let handshake {
            rsd_handshake_free(handshake)
        }
        if let adapter {
            adapter_free(adapter)
        }

        adapter = newAdapter
        handshake = newHandshake
    }

    func ensureTunnel() throws {
        if adapter == nil || handshake == nil {
            try startTunnel()
        }
    }

    /// Tear down the cached tunnel handles so the next `ensureTunnel()` builds a fresh tunnel.
    /// Needed when a probe finds the tunnel dead (e.g. the VPN dropped): otherwise the handles
    /// stay non-nil and `ensureTunnel()` keeps reusing the dead tunnel even after the VPN is
    /// back. Safe — `simulate_location` builds its own tunnel and doesn't use these handles.
    func invalidateTunnel() {
        tunnelLock.lock()
        defer { tunnelLock.unlock() }
        guard !tunnelConnecting else { return }   // don't free mid-creation
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        adapter = nil
        handshake = nil
        lastTunnelError = nil
    }

    private func withFreshDebugTunnel<T>(
        hostname: String,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        var tunnel = try createTunnel(hostname: hostname)
        defer { tunnel.free() }

        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            throw makeError("Tunnel is not connected")
        }

        return try body(adapter, handshake)
    }

    private struct DebugSession {
        var remoteServer: OpaquePointer?
        var debugProxy: OpaquePointer?

        mutating func free() {
            if let debugProxy {
                debug_proxy_free(debugProxy)
                self.debugProxy = nil
            }
            if let remoteServer {
                remote_server_free(remoteServer)
                self.remoteServer = nil
            }
        }
    }

    private final class DebugHeartbeatKeepAlive {
        private static let defaultInterval: UInt64 = 2
        private static let maxInterval: UInt64 = 3

        private let queue = DispatchQueue(label: "com.stikdebug.debug-heartbeat", qos: .utility)
        private let stateLock = NSLock()
        private let startupSemaphore = DispatchSemaphore(value: 0)
        private let stoppedSemaphore = DispatchSemaphore(value: 0)
        private let logger: LogFunc?
        private let makeClient: () throws -> (client: OpaquePointer, tunnel: TunnelHandles)
        private let errorBuilder: (UnsafeMutablePointer<IdeviceFfiError>?, String) -> NSError
        private var startupError: NSError?
        private var client: OpaquePointer?
        private var tunnel: TunnelHandles?
        private var stopRequested = false

        init(
            logger: LogFunc?,
            makeClient: @escaping () throws -> (client: OpaquePointer, tunnel: TunnelHandles),
            errorBuilder: @escaping (UnsafeMutablePointer<IdeviceFfiError>?, String) -> NSError
        ) {
            self.logger = logger
            self.makeClient = makeClient
            self.errorBuilder = errorBuilder
        }

        func start() throws {
            startupError = nil
            queue.async { [weak self] in
                self?.run()
            }

            startupSemaphore.wait()
            if let startupError {
                throw startupError
            }
        }

        func stop() {
            stateLock.lock()
            stopRequested = true
            stateLock.unlock()
            _ = stoppedSemaphore.wait(timeout: .now() + .seconds(Int(Self.maxInterval + 1)))
        }

        private func shouldStop() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return stopRequested
        }

        private func log(_ message: String) {
            logger?(message)
        }

        private func run() {
            do {
                let resources = try makeClient()
                client = resources.client
                tunnel = resources.tunnel
                startupError = nil
            } catch let error as NSError {
                startupError = error
                startupSemaphore.signal()
                stoppedSemaphore.signal()
                return
            }

            defer {
                if let client {
                    heartbeat_client_free(client)
                    self.client = nil
                }
                if var tunnel = tunnel {
                    tunnel.free()
                    self.tunnel = nil
                }
                stoppedSemaphore.signal()
            }

            startupSemaphore.signal()

            var interval = Self.defaultInterval

            while !shouldStop(), let client {
                var suggestedInterval: UInt64 = 0
                let ffiError = heartbeat_get_marco(client, interval, &suggestedInterval)

                if shouldStop() {
                    break
                }

                if let ffiError {
                    let heartbeatError = errorBuilder(ffiError, "Debug heartbeat failed")
                    let description = heartbeatError.localizedDescription

                    if description.contains("HeartbeatTimeout") {
                        interval = Self.defaultInterval
                        continue
                    }

                    if description.contains("HeartbeatSleepyTime") {
                        log("Debug heartbeat stopped: device entered SleepyTime")
                        break
                    }

                    log("Debug heartbeat warning: \(description)")
                    interval = Self.defaultInterval
                    continue
                }

                interval = min(max(suggestedInterval, 1), Self.maxInterval)

                if let ffiError = heartbeat_send_polo(client) {
                    let heartbeatError = errorBuilder(ffiError, "Failed to reply to heartbeat")
                    log("Debug heartbeat warning: \(heartbeatError.localizedDescription)")
                    interval = Self.defaultInterval
                }
            }
        }
    }

    private func connectDebugSession(adapter: OpaquePointer, handshake: OpaquePointer) throws -> DebugSession {
        var session = DebugSession()

        if let ffiError = remote_server_connect_rsd(adapter, handshake, &session.remoteServer) {
            throw error(from: ffiError, fallback: "Failed to connect remote server")
        }

        if let ffiError = debug_proxy_connect_rsd(adapter, handshake, &session.debugProxy) {
            session.free()
            throw error(from: ffiError, fallback: "Failed to connect debug proxy")
        }

        return session
    }

    private func withConnectedDebugSession<T>(
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        try withFreshDebugTunnel(hostname: "StikDebugDebug") { adapter, handshake in
            var session = try connectDebugSession(adapter: adapter, handshake: handshake)
            defer { session.free() }

            guard let remoteServer = session.remoteServer,
                  let debugProxy = session.debugProxy else {
                throw makeError("Debug session was not created")
            }

            return try body(remoteServer, debugProxy)
        }
    }

    private func withConnectedRemoteServer<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        try ensureTunnel()
        guard let adapter, let handshake else {
            throw makeError("Tunnel is not connected")
        }

        var remoteServer: OpaquePointer?
        if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            throw error(from: ffiError, fallback: "Failed to connect remote server")
        }

        guard let remoteServer else {
            throw makeError("Remote server handle was not created")
        }

        defer { remote_server_free(remoteServer) }
        return try body(remoteServer)
    }

    private func withProcessControl<T>(
        remoteServer: OpaquePointer,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var processControl: OpaquePointer?
        if let ffiError = process_control_new(remoteServer, &processControl) {
            throw error(from: ffiError, fallback: "Failed to open process control")
        }

        guard let processControl else {
            throw makeError("Process control handle was not created")
        }

        defer { process_control_free(processControl) }
        return try body(processControl)
    }

    private func connectHeartbeatKeepAlive(logger: LogFunc?) throws -> DebugHeartbeatKeepAlive {
        return DebugHeartbeatKeepAlive(
            logger: logger,
            makeClient: { [weak self] in
                guard let self else {
                    throw NSError(
                        domain: "StikDebug",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Debug heartbeat context is unavailable"]
                    )
                }

                var tunnel = try self.createTunnel(hostname: "StikDebugHeartbeat")
                guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
                    tunnel.free()
                    throw self.makeError("Tunnel is not connected")
                }

                var heartbeatClient: OpaquePointer?
                if let ffiError = heartbeat_connect_rsd(adapter, handshake, &heartbeatClient) {
                    tunnel.free()
                    throw self.error(from: ffiError, fallback: "Failed to connect debug heartbeat")
                }

                guard let heartbeatClient else {
                    tunnel.free()
                    throw self.makeError("Heartbeat client was not created")
                }

                return (client: heartbeatClient, tunnel: tunnel)
            },
            errorBuilder: { [weak self] ffiError, fallback in
                self?.error(from: ffiError, fallback: fallback) ?? NSError(
                    domain: "StikDebug",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: fallback]
                )
            }
        )
    }

    private func sendDebugCommand(_ command: String, debugProxy: OpaquePointer) throws -> String? {
        guard let commandHandle = debugserver_command_new(command, nil, 0) else {
            throw makeError("Failed to create debugserver command: \(command)")
        }

        var response: UnsafeMutablePointer<CChar>?
        let ffiError = debug_proxy_send_command(debugProxy, commandHandle, &response)
        debugserver_command_free(commandHandle)

        if let ffiError {
            if let response {
                idevice_string_free(response)
            }
            throw error(from: ffiError, fallback: "Debugserver command failed: \(command)")
        }

        defer {
            if let response {
                idevice_string_free(response)
            }
        }

        guard let response else { return nil }
        return String(cString: response)
    }

    private func runDebugServerCommand(
        pid: Int32,
        debugProxy: OpaquePointer,
        remoteServer: OpaquePointer,
        logger: LogFunc?,
        callback: DebugAppCallback?
    ) {
        debug_proxy_send_ack(debugProxy)
        debug_proxy_send_ack(debugProxy)

        do {
            let response = try sendDebugCommand("QStartNoAckMode", debugProxy: debugProxy) ?? "<nil>"
            emitLog("QStartNoAckMode result = \(response)", logger: logger)
        } catch {
            emitLog(error.localizedDescription, logger: logger)
        }

        debug_proxy_set_ack_mode(debugProxy, 0)

        if let callback {
            let keepAlive: DebugHeartbeatKeepAlive?
            do {
                let heartbeat = try connectHeartbeatKeepAlive(logger: logger)
                try heartbeat.start()
                keepAlive = heartbeat
                emitLog("Debug heartbeat keepalive started", logger: logger)
            } catch {
                keepAlive = nil
                emitLog("Warning: failed to start debug heartbeat keepalive: \(error.localizedDescription)", logger: logger)
            }
            defer {
                keepAlive?.stop()
                if keepAlive != nil {
                    emitLog("Debug heartbeat keepalive stopped", logger: logger)
                }
            }

            let semaphore = DispatchSemaphore(value: 0)
            callback(pid, debugProxy, remoteServer, semaphore)
            semaphore.wait()

            var breakByte: UInt8 = 0x03
            if let ffiError = debug_proxy_send_raw(debugProxy, &breakByte, 1) {
                emitLog(error(from: ffiError, fallback: "Failed to interrupt target").localizedDescription, logger: logger)
            }
            usleep(500)
        } else {
            let attachCommand = "vAttach;\(String(UInt32(pid), radix: 16))"
            do {
                let response = try sendDebugCommand(attachCommand, debugProxy: debugProxy) ?? "<nil>"
                emitLog("Attach response: \(response)", logger: logger)
            } catch {
                emitLog(error.localizedDescription, logger: logger)
            }
        }

        do {
            let response = try sendDebugCommand("D", debugProxy: debugProxy)
            if let response {
                emitLog("Detach response: \(response)", logger: logger)
            }
        } catch {
            emitLog(error.localizedDescription, logger: logger)
        }
    }

    func debugApp(withBundleID bundleID: String, logger: LogFunc?, jsCallback: DebugAppCallback?) -> Bool {
        runDebugSession(logger: logger, callback: jsCallback) { remoteServer in
            try withProcessControl(remoteServer: remoteServer) { processControl in
                var pid: UInt64 = 0
                let ffiError = bundleID.withCString { bundleID in
                    process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, true, false, &pid)
                }

                if let ffiError {
                    throw error(from: ffiError, fallback: "Failed to launch app")
                }

                return Int32(pid)
            }
        }
    }

    func debugApp(withPID pid: Int32, logger: LogFunc?, jsCallback: DebugAppCallback?) -> Bool {
        runDebugSession(logger: logger, callback: jsCallback) { _ in pid }
    }

    func launchAppWithoutDebug(_ bundleID: String, logger: LogFunc?) -> Bool {
        do {
            let pid = try withConnectedRemoteServer { remoteServer in
                try withProcessControl(remoteServer: remoteServer) { processControl in
                    var pid: UInt64 = 0
                    let ffiError = bundleID.withCString { bundleID in
                        process_control_launch_app(processControl, bundleID, nil, 0, nil, 0, false, true, &pid)
                    }

                    if let ffiError {
                        throw error(from: ffiError, fallback: "Failed to launch app")
                    }

                    return pid
                }
            }

            emitLog("Launched app (PID \(pid))", logger: logger)
            return true
        } catch {
            emitLog(error.localizedDescription, logger: logger)
            return false
        }
    }

    func startSyslogRelay(handler: @escaping SyslogLineHandler, onError: @escaping SyslogErrorHandler) {
        do {
            try ensureTunnel()
        } catch let nsError as NSError {
            onError(nsError)
            return
        } catch {
            onError(makeError(error.localizedDescription))
            return
        }

        guard !syslogStreaming else { return }

        syslogStreaming = true
        syslogLineHandler = handler
        syslogErrorHandler = onError

        syslogQueue.async { [weak self] in
            guard let self else { return }
            guard let adapter = self.adapter, let handshake = self.handshake else {
                self.handleSyslogFailure(self.makeError("Tunnel is not connected"))
                return
            }

            var client: OpaquePointer?
            if let ffiError = syslog_relay_connect_rsd(adapter, handshake, &client) {
                self.handleSyslogFailure(self.error(from: ffiError, fallback: "Failed to connect to syslog relay"))
                return
            }

            self.syslogClient = client

            while self.syslogStreaming, let client = self.syslogClient {
                var message: UnsafeMutablePointer<CChar>?
                let ffiError = syslog_relay_next(client, &message)
                if let ffiError {
                    if let message {
                        idevice_string_free(message)
                    }
                    self.handleSyslogFailure(self.error(from: ffiError, fallback: "Syslog relay read failed"))
                    break
                }

                guard let message else {
                    continue
                }

                let line = String(cString: message)
                idevice_string_free(message)

                if let handler = self.syslogLineHandler {
                    DispatchQueue.main.async {
                        handler(line)
                    }
                }
            }

            if let client = self.syslogClient {
                syslog_relay_client_free(client)
            }

            self.syslogClient = nil
            self.syslogStreaming = false
            self.syslogLineHandler = nil
            self.syslogErrorHandler = nil
        }
    }

    func stopSyslogRelay() {
        guard syslogStreaming else { return }

        syslogStreaming = false
        syslogLineHandler = nil
        syslogErrorHandler = nil

        syslogQueue.async { [weak self] in
            guard let self else { return }
            if let syslogClient = self.syslogClient {
                syslog_relay_client_free(syslogClient)
                self.syslogClient = nil
            }
        }
    }

    private func runDebugSession(
        logger: LogFunc?,
        callback: DebugAppCallback?,
        pidProvider: (OpaquePointer) throws -> Int32
    ) -> Bool {
        do {
            try withConnectedDebugSession { remoteServer, debugProxy in
                let pid = try pidProvider(remoteServer)
                runDebugServerCommand(
                    pid: pid,
                    debugProxy: debugProxy,
                    remoteServer: remoteServer,
                    logger: logger,
                    callback: callback
                )
            }

            emitLog("Debug session completed", logger: logger)
            return true
        } catch {
            emitLog(error.localizedDescription, logger: logger)
            return false
        }
    }

    private func handleSyslogFailure(_ error: NSError) {
        syslogStreaming = false
        if let syslogClient {
            syslog_relay_client_free(syslogClient)
            self.syslogClient = nil
        }

        let errorHandler = syslogErrorHandler
        syslogLineHandler = nil
        syslogErrorHandler = nil

        if let errorHandler {
            DispatchQueue.main.async {
                errorHandler(error)
            }
        }
    }
}
