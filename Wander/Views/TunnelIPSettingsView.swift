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

    /// Experiment, default OFF. Written straight through to UserDefaults (not via Save) because it is
    /// independent of the three address fields above.
    @AppStorage(UserDefaults.Keys.useIPv6TunnelLoopback) private var useIPv6Loopback = false

    /// Observed so the "restart to apply" row appears the moment the toggle and the RUNNING provider
    /// disagree. The provider only reads its options at start, so until it is restarted the app keeps
    /// dialing the family the provider actually has.
    @ObservedObject private var tunnel = WanderTunnel.shared

    /// What a tunnel started right now would be numbered with. Held in state and refreshed on
    /// appear rather than recomputed in `body`: it costs a `getifaddrs` call, and SwiftUI evaluates
    /// `body` far more often than the interface list changes.
    @State private var ipv6Plan: DeviceConnectionContext.PlannedIPv6Loopback?

    /// True when the preference has been changed out from under a live tunnel.
    private var ipv6ChangePending: Bool {
        guard WanderTunnel.isSupported else { return false }
        guard tunnel.status == .connected || tunnel.status == .connecting else { return false }
        return useIPv6Loopback != tunnel.startedIPv6Loopback
    }

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
                    // Goes through TunnelIPPlanner rather than WiFiSubnet.suggestTunnelIPs(): the old
                    // helper returned the PARENT interface's own netmask, so on a /22 Wi-Fi it told
                    // iOS the tunnel owned the identical prefix en0 already owns and the route for the
                    // fake address was ambiguous. The planner returns a /30 around the pair, which wins
                    // longest-prefix-match, and — new — falls back to the Personal Hotspot subnet when
                    // Wi-Fi is off, the only non-utun IPv4 subnet with room on a cellular-only phone.
                    Button {
                        switch TunnelIPPlanner.planFromCurrentInterfaces() {
                        case .success(let plan):
                            deviceIP = plan.deviceIP; tunnelIP = plan.fakeIP; subnetMask = plan.mask
                            saved = false
                            detectMessage = plan.source == .personalHotspot
                                ? L("tunnelip.detect.ok.hotspot",
                                    fallback: "Wi-Fi is off, so these came from your Personal Hotspot subnet (\(plan.parentCIDR) on \(plan.parentName)). The mask covers only \(plan.deviceIP) and \(plan.fakeIP). Keep a device connected to the hotspot — iOS shuts it down after about 90 seconds with nobody attached, and these addresses go with it.")
                                : L("tunnelip.detect.ok",
                                    fallback: "Suggested from \(plan.parentName) (\(plan.parentCIDR)). The mask \(plan.mask) covers only \(plan.deviceIP) and \(plan.fakeIP), so just those two addresses go to the tunnel and the rest of your network keeps using \(plan.parentName). Enter the same two IPs in LocalDevVPN.")
                        case .failure(let refusal):
                            detectMessage = L("tunnelip.detect.fail", fallback: refusal.message)
                        }
                    } label: {
                        Label(L("tunnelip.detect", fallback: "Detect subnet & suggest IPs"),
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
                    Toggle(L("tunnelip.ipv6.toggle", fallback: "Try IPv6 tunnel (experiment)"),
                           isOn: $useIPv6Loopback)
                        .disabled(!WanderTunnel.isSupported)
                    if useIPv6Loopback {
                        ipv6PlanRows
                    }
                    // The tunnel reads this setting only when it starts, so changing it while the
                    // tunnel is up does nothing until it is restarted. Until then the app keeps
                    // dialing whatever the running tunnel actually has, so nothing is wasted or
                    // broken in the meantime — but the user should be told, and given the button,
                    // instead of being left to read it in a footer.
                    if ipv6ChangePending {
                        Button {
                            tunnel.restart()
                        } label: {
                            Label(L("tunnelip.ipv6.restart",
                                    fallback: "Restart tunnel to apply"),
                                  systemImage: "arrow.clockwise")
                        }
                        .tint(Wander.accent)
                    }
                } header: {
                    Text(L("tunnelip.ipv6.header", fallback: "Cellular (experimental)"))
                } footer: {
                    if WanderTunnel.isSupported {
                        Text(L("tunnelip.ipv6.footer",
                               fallback: "Some carriers give your phone only an IPv6 address on cellular, and the tunnel then won't start unless you toggle Airplane Mode. This tries the tunnel over IPv6 first, then falls back to the normal way, so nothing is taken away if it fails. It is an experiment and it is not known yet whether iOS accepts it — if the tunnel stops connecting, turn this back off. It only applies to Wander's own built-in tunnel (Settings → Wander Tunnel → Connect), not to LocalDevVPN, and the tunnel has to be restarted for a change here to take effect."))
                    } else {
                        Text(L("tunnelip.ipv6.unsupported",
                               fallback: "Needs Wander's own built-in tunnel, which this install isn't signed for. Only a certificate install (not a free Apple ID sideload) can run it."))
                    }
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
            // Refreshed on appear and whenever the toggle is flipped, NOT in `body`: it costs a
            // getifaddrs call and SwiftUI re-evaluates `body` far more often than a phone changes
            // network. Only computed while the experiment is on, so nothing is spent when it is off.
            .onAppear { refreshIPv6Plan() }
            .onChange(of: useIPv6Loopback) { _, _ in refreshIPv6Plan() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("action.done", fallback: "Done")) { dismiss() }
                }
            }
        }
    }

    private func refreshIPv6Plan() {
        ipv6Plan = useIPv6Loopback ? DeviceConnectionContext.plannedIPv6Loopback() : nil
    }

    /// Shows the addresses the IPv6 experiment will actually aim at, and where they came from.
    ///
    /// WHY THIS IS NOT TWO CONSTANTS ANY MORE. It used to print a fixed pair of private addresses
    /// (fd00:…::1 / ::2). Those belong to no interface, and "belongs to no interface" is exactly what
    /// makes the current tunnel address get rejected in the first place — so the experiment was
    /// aimed at an address that could never be accepted. The pair is now carved out of the mobile
    /// network's own address range, which is the one range on a phone with Wi-Fi off that is both
    /// real and unused. The owner needs to SEE which one it picked, because on a phone with no such
    /// range it silently falls back to the old fixed pair and the test would mean something different.
    @ViewBuilder
    private var ipv6PlanRows: some View {
        let plan = ipv6Plan ?? DeviceConnectionContext.plannedIPv6Loopback()
        HStack(alignment: .firstTextBaseline) {
            Text(L("tunnelip.ipv6.tunnel_address", fallback: "Tunnel address"))
            Spacer()
            Text("\(plan.interfaceAddress)/\(plan.prefixLength)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        HStack(alignment: .firstTextBaseline) {
            Text(L("tunnelip.ipv6.dials", fallback: "Wander dials"))
            Spacer()
            Text(plan.targetAddress)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        if let cellular = plan.cellular {
            Text(L("tunnelip.ipv6.derived",
                   fallback: "Taken from \(cellular.parentName)'s mobile-network range \(cellular.parentCIDR). The tunnel claims only \(cellular.routeFirstAddress)–\(cellular.routeLastAddress) — four addresses — so everything else on cellular keeps working exactly as it does now."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(L("tunnelip.ipv6.fallback",
                   fallback: "This phone has no usable mobile-network IPv6 range right now, so the old fixed address is being used instead. That address belongs to no interface, which is the reason the experiment failed before — turn cellular data on and reopen this screen to check again."))
                .font(.caption).foregroundStyle(.orange)
        }
        // The running tunnel keeps whatever it was started with. Saying so beats letting the owner
        // read the row above and assume it is live.
        if let live = tunnel.startedIPv6Target, live != plan.targetAddress {
            Text(L("tunnelip.ipv6.live_differs",
                   fallback: "The tunnel that is running is still dialling \(live). Restart it to move to the address above."))
                .font(.caption).foregroundStyle(.secondary)
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
        useIPv6Loopback = false   // the experiment is part of "defaults" too
        saved = true
    }
}

#Preview {
    TunnelIPSettingsView()
}
