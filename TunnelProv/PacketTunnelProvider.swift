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
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    var tunnelDeviceIp: String = "10.7.0.0"
    var tunnelFakeIp: String = "10.7.0.1"
    var tunnelSubnetMask: String = "255.255.255.0"

    private var deviceIpValue: UInt32 = 0
    private var fakeIpValue: UInt32 = 0

    // Watches the UNDERLYING network so the tunnel can be re-established when it changes.
    //
    // WHY: this tunnel's settings are bound to the interface that existed when it started. Turning
    // Airplane Mode off re-attaches cellular and iOS rebuilds the interfaces underneath us — the loopback
    // route silently stops working, every connection through it is RST, and nothing here ever re-applies
    // the settings. The tunnel stays "connected" while carrying nothing, which is why a spoof set in
    // Airplane Mode died the moment cellular came back and could not be rebuilt afterwards.
    //
    // Re-applying the same NEPacketTunnelNetworkSettings makes iOS reinstall the addresses and routes on
    // the NEW interface. `reasserting` tells the system we are mid-recovery so it doesn't treat the gap
    // as a failure.
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.wander.tunnelprov.path")
    private var lastPathSummary: String = ""
    private var currentSettings: NEPacketTunnelNetworkSettings?

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

        currentSettings = settings

        setTunnelNetworkSettings(settings) { error in
            guard error == nil else { return completionHandler(error) }
            self.setPackets()
            self.startPathMonitoring()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        pathMonitor.cancel()
        completionHandler()
    }

    /// Re-apply the tunnel settings whenever the underlying network changes (cellular <-> Wi-Fi, and
    /// crucially the Airplane-Mode-off re-attach). Without this the tunnel survives as an object while its
    /// routes are dead on the new interface.
    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Summarise the path so we only react to REAL changes, not every duplicate callback — a
            // needless re-apply would tear down live connections for no reason.
            let summary = "\(path.status)|" + path.availableInterfaces.map { "\($0.type)\($0.name)" }.joined(separator: ",")
            guard summary != self.lastPathSummary else { return }
            let isFirst = self.lastPathSummary.isEmpty
            self.lastPathSummary = summary
            guard !isFirst else { return }   // the initial callback is just the current state
            guard path.status == .satisfied else { return }  // wait until there IS a usable path
            self.reapplySettings()
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func reapplySettings() {
        guard let settings = currentSettings else { return }
        reasserting = true
        // Clearing first (nil) forces iOS to drop the stale interface configuration before we reinstall
        // it; re-applying on top of a stale config is a no-op on some iOS versions.
        setTunnelNetworkSettings(nil) { [weak self] _ in
            guard let self else { return }
            self.setTunnelNetworkSettings(settings) { [weak self] _ in
                guard let self else { return }
                self.reasserting = false
                // The read loop is bound to the old flow; restart it so packets flow on the new interface.
                self.setPackets()
            }
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
