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
    }
}
