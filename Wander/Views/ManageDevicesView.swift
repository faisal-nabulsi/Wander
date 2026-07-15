//
//  ManageDevicesView.swift
//  Wander
//
//  Manage the devices signed into a Wander Pro account against the 5-device cap (server-enforced;
//  see WanderDeviceActivation). Two ways in:
//   • From Settings — a Pro user reviews / prunes their devices any time.
//   • Automatically surfaced when THIS device is over the cap (`atLimit && !registered`): the
//     device isn't unlocked, and removing another device here frees a slot this device can claim.
//
//  Each row shows the device name, platform, and last-seen, marks "This device", and offers a
//  Remove button that POSTs /account/devices/remove and refreshes. Removing a device other than
//  this one immediately re-runs activate() to claim the freed slot, flipping this device to Pro.
//

import SwiftUI

struct ManageDevicesView: View {
    /// When true, the screen is being shown BECAUSE this device is over the cap — we show the
    /// "this device isn't unlocked; remove one to free a slot" explainer up top.
    var overLimitContext: Bool = false

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var activation = WanderDeviceActivation.shared
    @ObservedObject private var account = WanderProAccount.shared

    @State private var pendingRemoval: WanderDeviceInfo?
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            Form {
                if overLimitContext && !activation.registered {
                    Section {
                        Label {
                            Text("This device isn't unlocked. Your Wander Pro account is at its limit of \(activation.limit) devices. Remove one below to free a slot for this \(UIDevice.current.model).")
                                .font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .listRowBackground(Color.orange.opacity(0.12))
                }

                Section {
                    if activation.devices.isEmpty {
                        HStack {
                            if activation.isWorking { ProgressView().controlSize(.small) }
                            Text(activation.isWorking ? "Loading devices…" : "No devices yet.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(activation.devices) { device in
                            deviceRow(device)
                        }
                    }
                } header: {
                    Text("Devices (\(activation.devices.count)/\(activation.limit))")
                } footer: {
                    Text("Wander Pro works on up to \(activation.limit) devices. Remove a device to sign it out and free a slot — you can re-add it later by opening Wander on it.")
                }

                if !errorText.isEmpty {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Manage Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(activation.isWorking)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await activation.activate() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(activation.isWorking)
                }
            }
            .task {
                // Refresh the list on open (fail-safe: keeps the cached list on error).
                await activation.activate()
            }
            .confirmationDialog(
                pendingRemoval.map { "Remove \"\($0.name)\"?" } ?? "Remove device?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRemoval
            ) { device in
                Button("Remove", role: .destructive) {
                    remove(device)
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: { device in
                Text(device.isThisDevice
                     ? "This signs THIS device out of Wander Pro. You can re-add it later."
                     : "This signs \"\(device.name)\" out of Wander Pro and frees a slot.")
            }
        }
    }

    @ViewBuilder
    private func deviceRow(_ device: WanderDeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: device.platform))
                .font(.title3)
                .foregroundStyle(device.isThisDevice ? Wander.brand : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.body.weight(.medium))
                    if device.isThisDevice {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Wander.brand.opacity(0.15), in: Capsule())
                            .foregroundStyle(Wander.brand)
                    }
                }
                HStack(spacing: 4) {
                    Text(device.platformLabel)
                    if let seen = device.lastSeenText {
                        Text("•")
                        Text("Last seen \(seen)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                pendingRemoval = device
            } label: {
                Text("Remove").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(activation.isWorking)
        }
        .padding(.vertical, 2)
    }

    private func icon(for platform: String) -> String {
        switch platform.lowercased() {
        case "ios":     return "iphone"
        case "android": return "candybarphone"
        case "mac":     return "laptopcomputer"
        case "windows": return "pc"
        default:        return "desktopcomputer"
        }
    }

    private func remove(_ device: WanderDeviceInfo) {
        errorText = ""
        Task {
            // Remove, then (if it wasn't this device) claim the freed slot for this device.
            let ok: Bool
            if device.isThisDevice {
                ok = await activation.removeDevice(device.deviceId)
            } else {
                _ = await activation.removeThenReactivate(device.deviceId)
                ok = true
                // If this device is now registered, we're unlocked — close out of the over-limit
                // flow so the user drops straight into the app.
                if overLimitContext && activation.registered {
                    dismiss()
                }
            }
            if !ok {
                errorText = "Couldn't update your devices. Check your connection and try again."
            }
            pendingRemoval = nil
        }
    }
}

#Preview {
    ManageDevicesView(overLimitContext: true)
}
