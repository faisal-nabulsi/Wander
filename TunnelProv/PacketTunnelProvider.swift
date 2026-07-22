//
//  PacketTunnelProvider.swift
//  TunnelProv
//
//  On-device loopback tunnel for reaching the device's own developer services.
//  Ported from LocalDevVPN (github.com/StephenDev0/LocalDevVPN, by Stossy11) —
//  a small NEPacketTunnelProvider that swaps src/dst between the device IP and a
//  fake IP so traffic loops back to localhost. No external servers, no data leaves
//  the device. Lets Wander run its own tunnel instead of a separate app.
//

import NetworkExtension

class PacketTunnelProvider: NEPacketTunnelProvider {
    var tunnelDeviceIp: String = "10.7.0.0"
    var tunnelFakeIp: String = "10.7.0.1"
    var tunnelSubnetMask: String = "255.255.255.0"

    private var deviceIpValue: UInt32 = 0
    private var fakeIpValue: UInt32 = 0

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let deviceIp = options?["TunnelDeviceIP"] as? String { tunnelDeviceIp = deviceIp }
        if let fakeIp = options?["TunnelFakeIP"] as? String { tunnelFakeIp = fakeIp }
        if let mask = options?["TunnelSubnetMask"] as? String { tunnelSubnetMask = mask }

        deviceIpValue = ipToUInt32(tunnelDeviceIp)
        fakeIpValue = ipToUInt32(tunnelFakeIp)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIp)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIp], subnetMasks: [tunnelSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: tunnelDeviceIp, subnetMask: tunnelSubnetMask)]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        // Declare an IPv6 presence on the tunnel interface too. WHY: on an IPv6-only cellular carrier
        // (pdp_ip0 has no IPv4 — increasingly common), an IPv4-only NEPacketTunnelProvider can't bind
        // to the underlying interface, so the loopback route fails to install and the user must toggle
        // Airplane Mode to force iOS to rebuild the interface (Apple DTS, Developer Forums 670367).
        // Declaring a ULA address + a single host route (default EXCLUDED, so we never capture real
        // IPv6 internet traffic) is the intended fix to make the interface valid on IPv6-only carriers.
        // NOTE: UNVERIFIED on-device as of 2026-07-22 — plausible per the Apple mechanism, not yet
        // proven to remove the airplane toggle. Inert on Wi-Fi/dual-stack. Only runs on paid accounts
        // (this NE is stripped on free-sideload re-sign). See memory wander-tunnel-cellular-ipv6.
        let ipv6 = NEIPv6Settings(addresses: ["fd00:7761:6e64:7272::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route(destinationAddress: "fd00:7761:6e64:7272::1", networkPrefixLength: 128)]
        ipv6.excludedRoutes = [.default()]
        settings.ipv6Settings = ipv6

        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { return completionHandler(error) }
            self.setPackets()
            completionHandler(nil)
        }
    }

    func setPackets() {
        packetFlow.readPackets { [self] packets, protocols in
            let fakeip = self.fakeIpValue
            let deviceip = self.deviceIpValue
            var modified = packets
            for i in modified.indices where protocols[i].int32Value == AF_INET && modified[i].count >= 20 {
                modified[i].withUnsafeMutableBytes { bytes in
                    guard let ptr = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
                    let src = UInt32(bigEndian: ptr[3])
                    let dst = UInt32(bigEndian: ptr[4])
                    if src == deviceip { ptr[3] = fakeip.bigEndian }
                    if dst == fakeip { ptr[4] = deviceip.bigEndian }
                }
            }
            self.packetFlow.writePackets(modified, withProtocols: protocols)
            setPackets()
        }
    }

    private func ipToUInt32(_ ipString: String) -> UInt32 {
        let c = ipString.split(separator: ".")
        guard c.count == 4, let b1 = UInt32(c[0]), let b2 = UInt32(c[1]), let b3 = UInt32(c[2]), let b4 = UInt32(c[3]) else { return 0 }
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }
}
