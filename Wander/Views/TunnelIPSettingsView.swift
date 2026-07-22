//
//  TunnelIPSettingsView.swift
//  Wander
//
//  Lets the user move the developer tunnel onto their Wi-Fi subnet. WHY: iOS 26.4 changed lockdownd
//  to drop the tunnel's default loopback address (10.7.0.0 / 10.7.0.1), so on 26.4+ the tunnel won't
//  connect until its IPs live on the phone's real Wi-Fi subnet (the SideStore/StikDebug fix). The
//  consumer app must connect to whatever "Tunnel IP" LocalDevVPN uses, so these two values must MATCH
//  LocalDevVPN's Device IP / Tunnel IP. "Detect" reads the Wi-Fi subnet and suggests a free pair —
//  something even LocalDevVPN doesn't do. Values persist to the same keys the inject path reads
//  (DeviceConnectionContext.targetIPAddress ← TunnelDeviceIP; WanderTunnel ← TunnelInterfaceIP / mask).
//

import SwiftUI

struct TunnelIPSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var deviceIP: String   // interface IP  → key TunnelInterfaceIP (LocalDevVPN "Device IP")
    @State private var tunnelIP: String   // fake/peer IP  → key TunnelDeviceIP    (LocalDevVPN "Tunnel IP") — Wander connects here
    @State private var subnetMask: String // → key TunnelSubnetMask
    @State private var detectMessage: String?
    @State private var saved = false

    init() {
        let d = UserDefaults.standard
        _deviceIP = State(initialValue: d.string(forKey: UserDefaults.Keys.tunnelInterfaceIP) ?? "10.7.0.0")
        _tunnelIP = State(initialValue: d.string(forKey: UserDefaults.Keys.targetDeviceIP) ?? "10.7.0.1")
        _subnetMask = State(initialValue: d.string(forKey: UserDefaults.Keys.tunnelSubnetMask) ?? "255.255.255.0")
    }

    private var isValid: Bool {
        WiFiSubnet.isValidIPv4(deviceIP) && WiFiSubnet.isValidIPv4(tunnelIP) && WiFiSubnet.isValidIPv4(subnetMask)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L("tunnelip.intro",
                           fallback: "iOS 26.4 changed how the developer tunnel connects — the old default address (10.7.0.1) gets dropped, so the tunnel won't come up. The fix is to move the tunnel onto your Wi-Fi's own subnet. Tap Detect, then enter the SAME two IPs here and in LocalDevVPN's settings. On iOS 26.3 and earlier, leave the defaults."))
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        if let s = WiFiSubnet.suggestTunnelIPs() {
                            deviceIP = s.device; tunnelIP = s.fake; subnetMask = s.mask
                            saved = false
                            detectMessage = L("tunnelip.detect.ok",
                                              fallback: "Suggested from your Wi-Fi subnet. Adjust if either address is already used by another device.")
                        } else {
                            detectMessage = L("tunnelip.detect.fail",
                                              fallback: "Couldn't read your Wi-Fi subnet — join Wi-Fi and try again, or enter the IPs manually.")
                        }
                    } label: {
                        Label(L("tunnelip.detect", fallback: "Detect Wi-Fi subnet & suggest IPs"),
                              systemImage: "wifi")
                    }
                    if let detectMessage {
                        Text(detectMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    ipRow(L("tunnelip.device", fallback: "Device IP"), $deviceIP)
                    ipRow(L("tunnelip.tunnel", fallback: "Tunnel IP"), $tunnelIP)
                    ipRow(L("tunnelip.mask", fallback: "Subnet mask"), $subnetMask)
                } header: {
                    Text(L("tunnelip.addresses", fallback: "Tunnel addresses"))
                } footer: {
                    Text(L("tunnelip.addresses.footer",
                           fallback: "Enter these exact values in LocalDevVPN → Settings too — they must match, or the tunnel won't connect. Default 10.7.0.0 / 10.7.0.1 works on iOS 26.3 and earlier."))
                }

                Section {
                    Button(L("tunnelip.save", fallback: "Save")) { save() }
                        .disabled(!isValid)
                    Button(L("tunnelip.reset", fallback: "Reset to defaults (10.7.0.x)"), role: .destructive) { reset() }
                } footer: {
                    if !isValid {
                        Text(L("tunnelip.invalid", fallback: "Enter valid IPv4 addresses (e.g. 192.168.1.241)."))
                            .foregroundStyle(.red)
                    } else if saved {
                        Text(L("tunnelip.saved", fallback: "Saved. Reconnect the tunnel (and LocalDevVPN) for it to take effect."))
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle(L("tunnelip.title", fallback: "Tunnel IP"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
    }

    private func ipRow(_ label: String, _ binding: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0.0.0.0", text: binding)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 160)
                .foregroundStyle(WiFiSubnet.isValidIPv4(binding.wrappedValue) ? Color.primary : Color.red)
                .onChange(of: binding.wrappedValue) { _, _ in saved = false }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(deviceIP, forKey: UserDefaults.Keys.tunnelInterfaceIP)
        d.set(tunnelIP, forKey: UserDefaults.Keys.targetDeviceIP)
        d.set(subnetMask, forKey: UserDefaults.Keys.tunnelSubnetMask)
        saved = true
    }

    private func reset() {
        deviceIP = "10.7.0.0"; tunnelIP = "10.7.0.1"; subnetMask = "255.255.255.0"
        let d = UserDefaults.standard
        d.removeObject(forKey: UserDefaults.Keys.tunnelInterfaceIP)
        d.removeObject(forKey: UserDefaults.Keys.targetDeviceIP)
        d.removeObject(forKey: UserDefaults.Keys.tunnelSubnetMask)
        saved = true
    }
}

#Preview {
    TunnelIPSettingsView()
}
