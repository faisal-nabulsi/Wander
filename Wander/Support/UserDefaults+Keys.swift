//
//  UserDefaults+Keys.swift
//  Wander
//

import Foundation

extension UserDefaults {
    enum Keys {
        /// Forces the app to treat the current device as TXM-capable so scripts always run.
        static let txmOverride = "overrideTXMForScripts"
        /// Requires confirmation before external links can enable JIT.
        static let confirmExternalJITRequests = "confirmExternalJITRequests"
        static let bundleScriptMap = "BundleScriptMap"
        static let defaultScriptName = "DefaultScriptName"
        static let defaultScriptNameValue = ""
        /// The fake/peer IP Wander CONNECTS TO (LocalDevVPN's "Tunnel IP"). Default 10.7.0.1.
        /// Opt-in: let Wander start and revive its OWN NE tunnel instead of relying on an external helper.
        /// Off by default — starting our tunnel claims iOS's single VPN slot from whatever the user chose
        /// (LocalDevVPN, Shadowrocket, a real VPN), and on free-sideload builds the NE entitlement is
        /// stripped so it can never come up at all.
        static let useOwnTunnel = "useOwnTunnel"

        static let targetDeviceIP = "TunnelDeviceIP"
        /// The interface/device IP Wander's OWN packet tunnel assigns (LocalDevVPN's "Device IP"),
        /// used only on the paid TunnelProv path. Default 10.7.0.0.
        static let tunnelInterfaceIP = "TunnelInterfaceIP"
        /// Subnet mask for the tunnel addresses. Default 255.255.255.0.
        static let tunnelSubnetMask = "TunnelSubnetMask"
        /// EXPERIMENT, default OFF: run the whole developer-tunnel loopback over IPv6 (ULA) instead of
        /// IPv4, so an IPv6-only cellular carrier doesn't need the Airplane Mode toggle. Only has any
        /// effect together with `useOwnTunnel` on a build signed with the Network Extension
        /// entitlement — LocalDevVPN/StosVPN are IPv4-only. Every dial still falls back to IPv4.
        static let useIPv6TunnelLoopback = "UseIPv6TunnelLoopback"

        /// Opt-in, default OFF: bring Wander's OWN tunnel back DOWN a grace period after the user
        /// deliberately stops spoofing, so the VPN slot isn't held while nothing is using it.
        /// Only meaningful together with `useOwnTunnel` — we never stop a tunnel we didn't start.
        static let tunnelAutoDisconnectWhenIdle = "tunnelAutoDisconnectWhenIdle"
        /// How long to wait after a deliberate stop before dropping the tunnel, in SECONDS.
        /// Raw seconds, never a menu index: the choices offered are a UI decision that may change,
        /// and an ordinal would silently re-point an existing user's setting at a different length.
        /// Unset (0) reads as `TunnelIdleDisconnect.defaultDelay` (30 s).
        static let tunnelAutoDisconnectDelay = "tunnelAutoDisconnectDelaySeconds"
    }
}
