//
//  WiFiSubnet.swift
//  Wander
//
//  Reads the phone's own Wi-Fi (en0) IPv4 address + netmask and suggests two tunnel IPs on that
//  subnet. WHY: iOS 26.4 changed lockdownd to DROP the developer tunnel's default loopback address
//  (10.7.0.0 / 10.7.0.1), so on 26.4+ the tunnel won't connect until its IPs are moved onto the
//  phone's real Wi-Fi subnet (the SideStore/StikDebug fix). This turns "read your router config and
//  pick a free IP" into one tap. Best-effort: it assumes a typical home /24 and picks high host
//  addresses (.240/.241) that are usually outside the DHCP pool — the user can edit if either collides.
//

import Foundation

enum WiFiSubnet {
    /// The device's IPv4 address + netmask on the Wi-Fi interface (en0), if connected to Wi-Fi.
    static func currentIPv4() -> (ip: String, netmask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: cur.pointee.ifa_name) == "en0",
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0 else { continue }

            let ip = Self.numericHost(sa, len: socklen_t(sa.pointee.sa_len))
            guard !ip.isEmpty else { continue }
            var mask = "255.255.255.0"
            if let nm = cur.pointee.ifa_netmask {
                let m = Self.numericHost(nm, len: socklen_t(nm.pointee.sa_len))
                if !m.isEmpty { mask = m }
            }
            return (ip, mask)
        }
        return nil
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>, len: socklen_t) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: host)
    }

    /// Suggest a (deviceIP, fakeIP, mask) triple on the current Wi-Fi subnet, or nil if not on Wi-Fi.
    /// Picks two high host addresses (.240 / .241 within the masked network) that are usually free in a
    /// home DHCP range. Tuned for the common case where the final octet is the host part (a /24 home LAN).
    static func suggestTunnelIPs() -> (device: String, fake: String, mask: String)? {
        guard let (ip, mask) = currentIPv4() else { return nil }
        let ipP = ip.split(separator: ".").compactMap { UInt8($0) }
        let mP = mask.split(separator: ".").compactMap { UInt8($0) }
        guard ipP.count == 4, mP.count == 4, mP[3] != 255 else { return nil }
        let net = (0..<4).map { ipP[$0] & mP[$0] }
        let base = "\(net[0]).\(net[1]).\(net[2])"
        return ("\(base).240", "\(base).241", mask)
    }

    /// Validate a dotted-quad IPv4 string.
    static func isValidIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }
}
