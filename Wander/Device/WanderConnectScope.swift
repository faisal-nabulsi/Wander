//
//  WanderConnectScope.swift
//  Wander
//
//  THE ONLY WAY TO BIND THE FFI's SOCKET — and an honest account of what it costs.
//
//  THE PROBLEM, STATED EXACTLY. The developer-tunnel dial is `tunnel_create_rppairing`, whose entire
//  C signature is:
//
//      struct IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr *addr,
//                                                      idevice_socklen_t addr_len,
//                                                      const char *hostname,
//                                                      struct RpPairingFileHandle *pairing_file,
//                                                      const char *(*pin_callback)(void *),
//                                                      void *pin_context,
//                                                      struct AdapterHandle **out_adapter,
//                                                      struct RsdHandshakeHandle **out_handshake);
//                                                      — Wander/idevice/idevice.h:5778
//
//  It takes an ADDRESS. It does not take a file descriptor, a socket, an options struct, or an
//  interface index, and there is no `_from_fd` sibling: `idevice_from_fd` (idevice.h:498) builds the
//  generic lockdown `Idevice`, not an rppairing tunnel, and the only other socket-shaped input in the
//  whole header — `ReadWriteOpaque` — can only be produced by `adapter_connect`, which is a stream
//  INSIDE an already-built tunnel. So the FFI creates and connects the outer socket itself, start to
//  finish, and no argument we pass can reach it.
//
//  ⇒ THE HONEST ANSWER TO "CAN WE BIND THAT SOCKET?" IS: NOT THROUGH THE API. Two things can change
//    that, and nothing else:
//
//    (A) REBUILD THE FFI. `libidevice_ffi.a` is vendored and 97 MB, built from the Rust `idevice`
//        crate. Adding either a `tunnel_create_rppairing_from_fd(int fd, …)` entry point or a
//        `bound_interface_index` parameter is a small change on that side and needs no interposition
//        at all. This is the correct fix and it is the one to make if the measurement below says
//        binding helps.
//
//    (B) INTERPOSE `connect()`. This file. It works because of a fact about how the archive is
//        linked, which was verified rather than assumed:
//
//            $ nm -u libidevice_ffi.a | grep -E '^ +U _(connect|socket|bind|setsockopt)$'
//                 U _bind        (×3)
//                 U _connect     (×3)
//                 U _setsockopt  (×3)
//                 U _socket      (×3)
//
//        Those are UNDEFINED symbols. A static archive cannot resolve them itself; the linker binds
//        them, through the main executable's stubs, to libSystem — and a definition of `_connect`
//        inside the main executable is picked ahead of the dylib's export. So a `connect` we define
//        captures every call from the app image, including the FFI's, and nothing else in the
//        process (other dylibs are bound to libsystem's copy directly, under the two-level
//        namespace).
//
//  WHY IT IS NOT NAMED `connect` TODAY. Because this is the app's ONLY path to the network, and a
//  mistake in it — a `dlsym` that came back nil, a filter that matched too widely — is not a spoof
//  bug, it is a device that cannot talk to anything. The symbol is therefore `wander_bound_connect`:
//  fully compiled, fully type-checked, inert. Making it live is one token, either of:
//
//      • rename the @_cdecl string below from "wander_bound_connect" to "connect", or
//      • add one linker flag and touch no source at all:
//            OTHER_LDFLAGS = $(inherited) -Wl,-alias,_wander_bound_connect,_connect
//
//    Both were link-tested against this project; the alias form is preferred because it leaves the
//    Swift symbol available to call directly in a unit test. VERIFY AFTER FLIPPING IT — the check is
//    two commands, and if they disagree the interposition silently did nothing:
//
//        $ nm -m "$BUILT/Wander.app/Wander" | grep ' _connect$'
//          … (__TEXT,__text) external _connect          ← ours, defined in the image
//        $ nm -u "$BUILT/Wander.app/Wander" | grep ' _connect$'
//          (no output)                                  ← no longer imported from libSystem
//
//  WHAT IT DOES WHEN LIVE. Nothing at all unless armed, and even armed it only touches sockets whose
//  destination port is the developer-tunnel port. Everything else is a straight tail-call to the real
//  `connect` with the same arguments, same return, same errno. On the sockets it does claim, it
//  applies exactly one option — `IP_BOUND_IF` / `IPV6_BOUND_IF`, the interface index, ordinary public
//  SDK constants — and then calls the real `connect` regardless of whether that option was accepted.
//  A refused scope must never turn into a failed dial.
//

import Foundation
import Darwin
import os

// MARK: - The armed policy

/// Process-wide, because the socket we want is not opened on our thread.
///
/// `tunnel_create_rppairing` is a blocking Rust FFI call that drives an async runtime inside itself,
/// so the `connect()` we are trying to reach may be issued from one of its worker threads rather than
/// from the caller's. A thread-local arm would therefore miss the very socket it exists for. The
/// destination-port filter is what keeps a process-wide arm narrow: only 49152 is claimed.
enum WanderConnectScope {

    struct Policy: Sendable, Equatable {
        /// Interface index to scope claimed sockets to. 0 means "armed but no interface" — treated as
        /// disarmed, since binding to index 0 is not a thing.
        var interfaceIndex: UInt32 = 0
        /// Only sockets dialling this destination port are claimed. Host byte order.
        var port: UInt16 = DeviceConnectionContext.developerTunnelPort
        var isArmed: Bool { interfaceIndex != 0 }
    }

    // os_unfair_lock rather than NSLock: when the alias is live this is read on the connect path of
    // every socket in the image, so it must not allocate, must not message-send, and must not be able
    // to re-enter connect(). Allocated once at global init so its address is stable — os_unfair_lock
    // is not safe to copy.
    private static let lock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock_s())
        return pointer
    }()
    private static var policy = Policy()

    static var current: Policy {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return policy
    }

    /// Arm the scope. Returns false (and arms nothing) when the interface could not be resolved, so a
    /// caller can log "the tunnel is not up" rather than silently measuring the unbound path.
    @discardableResult
    static func arm(to interface: ScopedInterface,
                    port: UInt16 = DeviceConnectionContext.developerTunnelPort) -> Bool {
        guard interface.index != 0 else { return false }
        os_unfair_lock_lock(lock)
        policy = Policy(interfaceIndex: interface.index, port: port)
        os_unfair_lock_unlock(lock)
        SpoofTrace.log("  connect scope ARMED → \(interface.label), port \(port)")
        return true
    }

    static func disarm() {
        os_unfair_lock_lock(lock)
        let wasArmed = policy.isArmed
        policy = Policy(interfaceIndex: 0, port: policy.port)
        os_unfair_lock_unlock(lock)
        if wasArmed { SpoofTrace.log("  connect scope DISARMED") }
    }

    /// Run `body` with the scope armed, and disarm on EVERY exit including a throw.
    ///
    /// This is the shape the dial path would use: wrap the `tunnel_create_rppairing` call and nothing
    /// else, so the window in which any socket in the process can be claimed is as short as the dial
    /// itself. See the call-site note in the file header for the exact lines.
    static func withScope<T>(_ interface: ScopedInterface?, _ body: () throws -> T) rethrows -> T {
        guard let interface, arm(to: interface) else { return try body() }
        defer { disarm() }
        return try body()
    }
}

// MARK: - The interposer

/// The real `connect`, resolved once.
///
/// `RTLD_NEXT` is `(void *)-1`; Swift does not import the macro, hence the bitPattern. From the main
/// executable it means "the next image in the search order", i.e. libSystem — which is precisely what
/// we want, and is why this does NOT recurse into ourselves the way `RTLD_DEFAULT` would. The
/// libSystem fallback exists because a nil here, once this is aliased to `connect`, would be an app
/// with no networking at all; belt and braces is cheap for a one-time lookup.
private let realConnect: (@convention(c) (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32)? = {
    let RTLD_NEXT_HANDLE = UnsafeMutableRawPointer(bitPattern: -1)
    if let symbol = dlsym(RTLD_NEXT_HANDLE, "connect") {
        return unsafeBitCast(symbol, to: (@convention(c) (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32).self)
    }
    if let handle = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD),
       let symbol = dlsym(handle, "connect") {
        return unsafeBitCast(symbol, to: (@convention(c) (Int32, UnsafePointer<sockaddr>?, socklen_t) -> Int32).self)
    }
    return nil
}()

/// Destination port of a `sockaddr`, host byte order, or nil for a family we do not filter on.
private func destinationPort(_ addr: UnsafePointer<sockaddr>?, _ length: socklen_t) -> UInt16? {
    guard let addr else { return nil }
    switch Int32(addr.pointee.sa_family) {
    case AF_INET:
        guard length >= socklen_t(MemoryLayout<sockaddr_in>.size) else { return nil }
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt16(bigEndian: $0.pointee.sin_port)
        }
    case AF_INET6:
        guard length >= socklen_t(MemoryLayout<sockaddr_in6>.size) else { return nil }
        return addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            UInt16(bigEndian: $0.pointee.sin6_port)
        }
    default:
        return nil
    }
}

/// `connect(2)`, with an interface scope applied to the one socket we care about.
///
/// CONTRACT, and it is the whole safety argument:
///   • It returns exactly what the real `connect` returned, and leaves `errno` exactly as the real
///     `connect` left it. The `setsockopt` happens BEFORE, so it cannot overwrite the errno a caller
///     is about to read.
///   • It claims a socket only when the scope is armed AND the destination port matches. Every other
///     connect in the image — URLSession, the FFI's inner streams, our own probes — is untouched.
///   • A refused `setsockopt` is logged, not fatal. Failing the dial because the diagnostic option
///     was rejected would be strictly worse than not having it.
///   • If the real `connect` could not be resolved it sets ENOSYS and returns -1 rather than
///     recursing. That path is unreachable in practice and exists so the failure is loud instead of
///     being a stack overflow.
@_cdecl("wander_bound_connect")
public func wander_bound_connect(_ fd: Int32,
                                 _ addr: UnsafePointer<sockaddr>?,
                                 _ length: socklen_t) -> Int32 {
    guard let realConnect else {
        errno = ENOSYS
        return -1
    }

    let policy = WanderConnectScope.current
    guard policy.isArmed,
          let port = destinationPort(addr, length),
          port == policy.port,
          let addr else {
        return realConnect(fd, addr, length)
    }

    var index = Int32(bitPattern: policy.interfaceIndex)
    let isIPv6 = Int32(addr.pointee.sa_family) == AF_INET6
    let level = isIPv6 ? IPPROTO_IPV6 : IPPROTO_IP
    let option = isIPv6 ? IPV6_BOUND_IF : IP_BOUND_IF
    let rc = setsockopt(fd, level, option, &index, socklen_t(MemoryLayout<Int32>.size))
    if rc != 0 {
        let code = errno
        SpoofTrace.log("  connect scope: \(isIPv6 ? "IPV6_BOUND_IF" : "IP_BOUND_IF") REFUSED errno \(code) \(EndpointProbe.errnoName(code)) — dialling unscoped")
    }

    let result = realConnect(fd, addr, length)
    let connectErrno = errno
    // Read the source the kernel picked for the FFI's own socket — the one measurement that has never
    // been taken on the real dial, only on our probes.
    if let source = ScopedEndpointProbe.localAddress(of: fd) {
        SpoofTrace.log("  connect scope: FFI socket sourced from \(source) via \(InterfaceScope.describeOwner(ofAddress: source) ?? "NO INTERFACE HOLDS IT")")
    }
    errno = connectErrno
    return result
}
