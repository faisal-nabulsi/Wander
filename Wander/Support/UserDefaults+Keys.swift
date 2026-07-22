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
        static let targetDeviceIP = "TunnelDeviceIP"
        /// The interface/device IP Wander's OWN packet tunnel assigns (LocalDevVPN's "Device IP"),
        /// used only on the paid TunnelProv path. Default 10.7.0.0.
        static let tunnelInterfaceIP = "TunnelInterfaceIP"
        /// Subnet mask for the tunnel addresses. Default 255.255.255.0.
        static let tunnelSubnetMask = "TunnelSubnetMask"
    }
}
