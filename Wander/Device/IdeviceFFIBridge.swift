//
//  IdeviceFFIBridge.swift
//  Wander
//
//  Created by Stephen on 2026/3/30.
//

import Foundation
import UIKit
import idevice

private enum IdeviceBridge {
    static let processQueue = DispatchQueue(label: "com.stikdebug.processInspector", qos: .userInitiated)

    static func makeError(
        domain: String = "StikDebug",
        code: Int = -1,
        message: String
    ) -> NSError {
        NSError(
            domain: domain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func string(from cString: UnsafePointer<CChar>?) -> String? {
        guard let cString else { return nil }
        return String(validatingUTF8: cString)
    }

    static func consumeFFIError(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String,
        domain: String = "StikDebug"
    ) -> NSError {
        guard let ffiError else {
            return makeError(domain: domain, message: fallback)
        }

        let code = Int(ffiError.pointee.code)
        let message = string(from: ffiError.pointee.message) ?? fallback
        idevice_error_free(ffiError)
        return makeError(domain: domain, code: code, message: message)
    }

    static func mappedFileData(atPath path: String, description: String) throws -> Data {
        let url = URL(fileURLWithPath: path)

        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else {
                throw makeError(message: "\(description) is empty")
            }
            return data
        } catch let error as NSError {
            throw makeError(code: error.code, message: "Failed to read \(description): \(error.localizedDescription)")
        }
    }

    static func uint64Value(from plist: plist_t?, fieldName: String) throws -> UInt64 {
        guard let plist else {
            throw makeError(message: "\(fieldName) was not returned by lockdownd")
        }

        var value: UInt64 = 0
        plist_get_uint_val(plist, &value)

        guard value != 0 else {
            throw makeError(message: "Failed to decode \(fieldName)")
        }

        return value
    }

    static func withTunnelHandles<T>(
        for context: JITEnableContext,
        _ body: (OpaquePointer, OpaquePointer) throws -> T
    ) throws -> T {
        let handles = try activeTunnelHandles(for: context)
        return try body(handles.adapter, handles.handshake)
    }

    static func connectClient(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?
    ) throws -> OpaquePointer {
        var client: OpaquePointer?
        if let ffiError = connect(&client) {
            throw consumeFFIError(ffiError, fallback: fallback, domain: domain)
        }

        guard let client else {
            throw makeError(domain: domain, message: missingClientMessage)
        }

        return client
    }

    static func withConnectedClient<T>(
        fallback: String,
        missingClientMessage: String,
        domain: String = "StikDebug",
        connect: (UnsafeMutablePointer<OpaquePointer?>) -> UnsafeMutablePointer<IdeviceFfiError>?,
        cleanup: (OpaquePointer) -> Void,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let client = try connectClient(
            fallback: fallback,
            missingClientMessage: missingClientMessage,
            domain: domain,
            connect: connect
        )
        defer { cleanup(client) }
        return try body(client)
    }

    static func plistDictionaries(adapter: OpaquePointer, handshake: OpaquePointer) throws -> [[String: Any]] {
        try withConnectedClient(
            fallback: "Failed to connect to installation proxy",
            missingClientMessage: "Installation proxy client was not created",
            connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
            cleanup: { installation_proxy_client_free($0) }
        ) { client in
            var rawApps: UnsafeMutableRawPointer?
            var count = 0
            if let ffiError = installation_proxy_get_apps(client, nil, nil, 0, &rawApps, &count) {
                throw consumeFFIError(ffiError, fallback: "Failed to fetch installed apps")
            }

            guard let rawApps, count > 0 else { return [] }

            let apps = rawApps.assumingMemoryBound(to: plist_t?.self)
            defer {
                for index in 0..<count {
                    plist_free(apps[index])
                }
                idevice_data_free(
                    rawApps.assumingMemoryBound(to: UInt8.self),
                    UInt(count * MemoryLayout<plist_t?>.stride)
                )
            }

            var dictionaries: [[String: Any]] = []
            dictionaries.reserveCapacity(count)

            for index in 0..<count {
                var binaryPlist: UnsafeMutablePointer<CChar>?
                var binaryLength: UInt32 = 0
                let app = apps[index]

                guard plist_to_bin(app, &binaryPlist, &binaryLength) == PLIST_ERR_SUCCESS,
                      let binaryPlist,
                      binaryLength > 0 else {
                    continue
                }

                let data = Data(bytes: binaryPlist, count: Int(binaryLength))
                plist_mem_free(binaryPlist)

                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any] else {
                    continue
                }

                dictionaries.append(dictionary)
            }

            return dictionaries
        }
    }

    static func appName(from dictionary: [String: Any]) -> String {
        if let displayName = dictionary["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let name = dictionary["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        return "Unknown"
    }

    static func hasGetTaskAllow(_ dictionary: [String: Any]) -> Bool {
        guard let entitlements = dictionary["Entitlements"] as? [String: Any] else {
            return false
        }

        if let flag = entitlements["get-task-allow"] as? Bool {
            return flag
        }

        if let flag = entitlements["get-task-allow"] as? NSNumber {
            return flag.boolValue
        }

        return false
    }

    static func isHiddenSystemApp(_ dictionary: [String: Any]) -> Bool {
        guard let applicationType = dictionary["ApplicationType"] as? String,
              applicationType == "System" || applicationType == "HiddenSystemApp" else {
            return false
        }

        if let isHidden = dictionary["IsHidden"] as? Bool, isHidden {
            return true
        }

        if let isHidden = dictionary["IsHidden"] as? NSNumber, isHidden.boolValue {
            return true
        }

        guard let tags = dictionary["SBAppTags"] as? [String] else {
            return false
        }

        return tags.contains("hidden") || tags.contains("hidden-system-app")
    }

    static func appDictionary(
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        requireGetTaskAllow: Bool,
        filter: (([String: Any]) -> Bool)? = nil
    ) throws -> [String: String] {
        let dictionaries = try plistDictionaries(adapter: adapter, handshake: handshake)
        var result: [String: String] = [:]
        result.reserveCapacity(dictionaries.count)

        for dictionary in dictionaries {
            if requireGetTaskAllow && !hasGetTaskAllow(dictionary) {
                continue
            }

            if let filter, !filter(dictionary) {
                continue
            }

            guard let bundleID = dictionary["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else {
                continue
            }

            result[bundleID] = appName(from: dictionary)
        }

        return result
    }

    static func activeTunnelHandles(for context: JITEnableContext) throws -> (adapter: OpaquePointer, handshake: OpaquePointer) {
        try context.ensureTunnel()

        guard let adapterHandle = context.adapterHandle,
              let handshakeHandle = context.handshakeHandle else {
            throw makeError(message: "Tunnel is not connected")
        }

        return (adapterHandle, handshakeHandle)
    }
}

extension JITEnableContext {
    func getMountedDeviceCount() throws -> Int {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { client in
                var devices: UnsafeMutablePointer<plist_t?>?
                var deviceCount = 0
                if let ffiError = image_mounter_copy_devices(client, &devices, &deviceCount) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch mounted devices")
                }

                if let devices {
                    for index in 0..<deviceCount {
                        plist_free(devices[index])
                    }
                    idevice_data_free(
                        UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                        UInt(deviceCount * MemoryLayout<plist_t?>.stride)
                    )
                }

                return deviceCount
            }
        }
    }

    /// Directly asks the device whether Developer Mode is enabled — the same thing desktop
    /// tools (pymobiledevice3, iGo) do via lockdownd's DeveloperModeStatus. Works with NO DDI
    /// mounted and Dev Mode off, and never starts a simulation. Returns true if enabled.
    func getDeveloperModeStatus() throws -> Bool {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { client in
                var status: Int32 = 0
                if let ffiError = image_mounter_query_developer_mode_status(client, &status) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query Developer Mode status")
                }
                return status == 1
            }
        }
    }

    /// Reliable "is the personalized DDI mounted?" probe for iOS 17+, where
    /// image_mounter_copy_devices wrongly reports 0. The DTServiceHub RSD service is only
    /// advertised once the DDI is mounted, so its availability is the mount signal.
    func isDeveloperServiceAvailable() throws -> Bool {
        try IdeviceBridge.withTunnelHandles(for: self) { _, handshake in
            var available = false
            if let ffiError = rsd_service_available(handshake, "com.apple.instruments.dtservicehub", &available) {
                throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query developer services")
            }
            return available
        }
    }

    /// Query the device's UDID over lockdown (needed to register the device with Apple before
    /// signing — a free provisioning profile requires the device to be registered).
    func getDeviceUDID() throws -> String {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var plist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueDeviceID", nil, &plist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueDeviceID")
                }
                guard let plistValue = plist else {
                    throw NSError(domain: "sign", code: -1, userInfo: [NSLocalizedDescriptionKey: "No UDID returned"])
                }
                defer { plist_free(plistValue) }

                var cString: UnsafeMutablePointer<CChar>?
                plist_get_string_val(plistValue, &cString)
                defer { if let cString { plist_mem_free(cString) } }

                guard let cString, let udid = String(validatingUTF8: cString), !udid.isEmpty else {
                    throw NSError(domain: "sign", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't read device UDID"])
                }
                return udid
            }
        }
    }

    func mountPersonalDDI(withImagePath imagePath: String, trustcachePath: String, manifestPath: String) throws {
        let imageData = try IdeviceBridge.mappedFileData(atPath: imagePath, description: "developer disk image")
        let trustcacheData = try IdeviceBridge.mappedFileData(atPath: trustcachePath, description: "developer disk image trust cache")
        let manifestData = try IdeviceBridge.mappedFileData(atPath: manifestPath, description: "developer disk image manifest")

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            let uniqueChipID = try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) },
                cleanup: { lockdownd_client_free($0) }
            ) { lockdownClient in
                var uniqueChipIDPlist: plist_t?
                if let ffiError = lockdownd_get_value(lockdownClient, "UniqueChipID", nil, &uniqueChipIDPlist) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to query UniqueChipID")
                }

                defer {
                    if let uniqueChipIDPlist {
                        plist_free(uniqueChipIDPlist)
                    }
                }

                return try IdeviceBridge.uint64Value(from: uniqueChipIDPlist, fieldName: "UniqueChipID")
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to image mounter",
                missingClientMessage: "Image mounter client was not created",
                connect: { image_mounter_connect_rsd(adapter, handshake, $0) },
                cleanup: { image_mounter_free($0) }
            ) { imageMounterClient in
                let ffiError = imageData.withUnsafeBytes { imageBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                    trustcacheData.withUnsafeBytes { trustcacheBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                        manifestData.withUnsafeBytes { manifestBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                            image_mounter_mount_personalized_with_callback_rsd(
                                imageMounterClient,
                                adapter,
                                handshake,
                                imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                                imageData.count,
                                trustcacheBuffer.bindMemory(to: UInt8.self).baseAddress,
                                trustcacheData.count,
                                manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                                manifestData.count,
                                nil,
                                uniqueChipID,
                                progressCallback,
                                nil
                            )
                        }
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to mount personalized DDI")
                }
            }
        }
    }

    func fetchAllProfiles() throws -> [Data] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                var profilePointers: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
                var profileLengths: UnsafeMutablePointer<Int>?
                var profileCount = 0

                if let ffiError = misagent_copy_all(misagentClient, &profilePointers, &profileLengths, &profileCount) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to fetch provisioning profiles",
                        domain: "profiles"
                    )
                }

                defer {
                    if let profilePointers, let profileLengths {
                        misagent_free_profiles(profilePointers, profileLengths, profileCount)
                    }
                }

                guard let profilePointers, let profileLengths else { return [] }

                var result: [Data] = []
                result.reserveCapacity(profileCount)

                for index in 0..<profileCount {
                    guard let bytes = profilePointers[index] else { continue }
                    result.append(Data(bytes: bytes, count: profileLengths[index]))
                }

                return result
            }
        }
    }

    func removeProfile(withUUID uuid: String) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                if let ffiError = misagent_remove(misagentClient, uuid) {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to remove provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    func addProfile(_ profile: Data) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to misagent",
                missingClientMessage: "Misagent client was not created",
                domain: "profiles",
                connect: { misagent_connect_rsd(adapter, handshake, $0) },
                cleanup: { misagent_client_free($0) }
            ) { misagentClient in
                let ffiError = profile.withUnsafeBytes { rawBuffer in
                    misagent_install(
                        misagentClient,
                        rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                        profile.count
                    )
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(
                        ffiError,
                        fallback: "Failed to add provisioning profile",
                        domain: "profiles"
                    )
                }
            }
        }
    }

    /// The on-device half of a self-refresh: stage an IPA over AFC, then upgrade-install it
    /// in place — over the SAME rppairing tunnel + (adapter, handshake) the misagent calls
    /// already use successfully on iOS 26.5. Signing (AltSign) happens off-device beforehand.
    func stageAndUpgradeIPA(atPath ipaPath: String, bundleID: String) throws {
        let ipaData = try Data(contentsOf: URL(fileURLWithPath: ipaPath), options: .mappedIfSafe)
        let stagingDir = "PublicStaging"
        let remotePath = "\(stagingDir)/\(bundleID).ipa"

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            // 1) AFC — stage the IPA into PublicStaging/<bundleID>.ipa
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to AFC",
                missingClientMessage: "AFC client was not created",
                domain: "install",
                connect: { afc_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { afc_client_free($0) }
            ) { afcClient in
                _ = afc_make_directory(afcClient, stagingDir)   // fine if it already exists

                var fileHandle: OpaquePointer?
                if let ffiError = afc_file_open(afcClient, remotePath, AfcWrOnly, &fileHandle) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to open staging file", domain: "install")
                }
                guard let fileHandle else {
                    throw NSError(domain: "install", code: -1, userInfo: [NSLocalizedDescriptionKey: "AFC file handle was not created"])
                }
                defer { afc_file_close(fileHandle) }

                // Stream the IPA in 1 MB chunks so large payloads write cleanly over the tunnel.
                let chunkSize = 1 << 20
                try ipaData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                    var offset = 0
                    while offset < ipaData.count {
                        let n = min(chunkSize, ipaData.count - offset)
                        if let ffiError = afc_file_write(fileHandle, base + offset, n) {
                            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to write staged IPA", domain: "install")
                        }
                        offset += n
                    }
                }
            }

            // 2) installation_proxy — upgrade-install from the staged path
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to installation proxy",
                missingClientMessage: "Installation proxy client was not created",
                domain: "install",
                connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
                cleanup: { installation_proxy_client_free($0) }
            ) { instClient in
                let options = plist_new_dict()
                defer { plist_free(options) }
                plist_dict_set_item(options, "CFBundleIdentifier", plist_new_string(bundleID))

                if let ffiError = installation_proxy_upgrade(instClient, remotePath, options) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install/upgrade app", domain: "install")
                }
            }
        }
    }

    /// Recursively push a (signed) .app bundle into PublicStaging over AFC, then upgrade-install
    /// it — the install half of self-refresh. Handles a directory (walks + recreates the tree)
    /// instead of a single .ipa file, over the same rppairing tunnel.
    func stageAndUpgradeAppBundle(atLocalPath localAppPath: String, bundleID: String) throws {
        let fm = FileManager.default
        let localAppURL = URL(fileURLWithPath: localAppPath)
        let appName = localAppURL.lastPathComponent
        let stagingRoot = "PublicStaging"
        let remoteAppDir = "\(stagingRoot)/\(appName)"

        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to AFC",
                missingClientMessage: "AFC client was not created",
                domain: "install",
                connect: { afc_client_connect_rsd(adapter, handshake, $0) },
                cleanup: { afc_client_free($0) }
            ) { afcClient in
                _ = afc_make_directory(afcClient, stagingRoot)
                _ = afc_make_directory(afcClient, remoteAppDir)

                guard let enumerator = fm.enumerator(at: localAppURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
                    throw NSError(domain: "install", code: -1, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the app bundle"])
                }

                // Compute the relative path via components on the symlink-resolved URLs, so
                // /var vs /private/var normalization can't corrupt the remote path.
                let baseComponents = localAppURL.resolvingSymlinksInPath().pathComponents
                func relativePath(_ url: URL) -> String? {
                    let comps = url.resolvingSymlinksInPath().pathComponents
                    guard comps.count > baseComponents.count else { return nil }
                    return comps[baseComponents.count...].joined(separator: "/")
                }

                var dirRels: [String] = []
                var fileEntries: [(rel: String, url: URL)] = []
                for case let fileURL as URL in enumerator {
                    guard let rel = relativePath(fileURL) else { continue }
                    let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDir { dirRels.append(rel) } else { fileEntries.append((rel, fileURL)) }
                }

                // Create directories shallow-first so every file has an existing parent.
                for rel in dirRels.sorted(by: { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }) {
                    _ = afc_make_directory(afcClient, "\(remoteAppDir)/\(rel)")
                }

                for entry in fileEntries {
                    let remotePath = "\(remoteAppDir)/\(entry.rel)"
                    let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
                    var fileHandle: OpaquePointer?
                    if let ffiError = afc_file_open(afcClient, remotePath, AfcWrOnly, &fileHandle) {
                        let inner = IdeviceBridge.consumeFFIError(ffiError, fallback: "open", domain: "install")
                        throw NSError(domain: "install", code: 106, userInfo: [NSLocalizedDescriptionKey: "AFC open '\(entry.rel)': \(inner.localizedDescription)"])
                    }
                    guard let fileHandle else {
                        throw NSError(domain: "install", code: -1, userInfo: [NSLocalizedDescriptionKey: "AFC handle nil: \(entry.rel)"])
                    }

                    let chunkSize = 1 << 20
                    var writeError: Error?
                    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                        var offset = 0
                        while offset < data.count {
                            let n = min(chunkSize, data.count - offset)
                            if let ffiError = afc_file_write(fileHandle, base + offset, n) {
                                writeError = IdeviceBridge.consumeFFIError(ffiError, fallback: "AFC write failed: \(entry.rel)", domain: "install")
                                return
                            }
                            offset += n
                        }
                    }
                    afc_file_close(fileHandle)
                    if let writeError { throw writeError }
                }
            }

            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to installation proxy",
                missingClientMessage: "Installation proxy client was not created",
                domain: "install",
                connect: { installation_proxy_connect_rsd(adapter, handshake, $0) },
                cleanup: { installation_proxy_client_free($0) }
            ) { instClient in
                let options = plist_new_dict()
                defer { plist_free(options) }
                plist_dict_set_item(options, "CFBundleIdentifier", plist_new_string(bundleID))
                plist_dict_set_item(options, "PackageType", plist_new_string("Developer"))

                if let ffiError = installation_proxy_upgrade(instClient, remoteAppDir, options) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to install signed app", domain: "install")
                }
            }
        }
    }

    func fetchProcessList() throws -> [NSDictionary] {
        try IdeviceBridge.processQueue.sync {
            try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
                try IdeviceBridge.withConnectedClient(
                    fallback: "Unable to open AppService",
                    missingClientMessage: "AppService client was not created",
                    connect: { app_service_connect_rsd(adapter, handshake, $0) },
                    cleanup: { app_service_free($0) }
                ) { appService in
                    var processes: UnsafeMutablePointer<ProcessTokenC>?
                    var count = UInt(0)
                    if let ffiError = app_service_list_processes(appService, &processes, &count) {
                        throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to list processes")
                    }

                    defer {
                        if let processes {
                            app_service_free_process_list(processes, count)
                        }
                    }

                    guard let processes else { return [] }

                    var result: [NSDictionary] = []
                    result.reserveCapacity(Int(count))

                    for index in 0..<Int(count) {
                        let process = processes[index]
                        var dictionary: [String: Any] = ["pid": NSNumber(value: process.pid)]
                        if let executableURL = IdeviceBridge.string(from: process.executable_url) {
                            dictionary["path"] = executableURL
                        }
                        result.append(dictionary as NSDictionary)
                    }

                    return result
                }
            }
        }
    }

    func sendSignal(_ signal: Int32, toProcessWithPID pid: Int32) throws {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Unable to open AppService",
                missingClientMessage: "AppService client was not created",
                connect: { app_service_connect_rsd(adapter, handshake, $0) },
                cleanup: { app_service_free($0) }
            ) { appService in
                var response: UnsafeMutablePointer<SignalResponseC>?
                let ffiError = app_service_send_signal(appService, UInt32(pid), UInt32(signal), &response)
                defer {
                    if let response {
                        app_service_free_signal_response(response)
                    }
                }

                if let ffiError {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to send signal \(signal) to process")
                }
            }
        }
    }

    func killProcess(withPID pid: Int32) throws {
        try sendSignal(Int32(SIGKILL), toProcessWithPID: pid)
    }

    func getAppList() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: true
            )
        }
    }

    func getAllApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false
            )
        }
    }

    func getHiddenSystemApps() throws -> [String: String] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.appDictionary(
                adapter: adapter,
                handshake: handshake,
                requireGetTaskAllow: false,
                filter: IdeviceBridge.isHiddenSystemApp
            )
        }
    }

    func getSideloadedApps() throws -> [NSDictionary] {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.plistDictionaries(adapter: adapter, handshake: handshake)
                .filter { $0["ProfileValidated"] != nil }
                .map { $0 as NSDictionary }
        }
    }

    func getAppIcon(withBundleId bundleId: String) throws -> UIImage {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.withConnectedClient(
                fallback: "Failed to connect to SpringBoard Services",
                missingClientMessage: "SpringBoard Services client was not created",
                connect: { springboard_services_connect_rsd(adapter, handshake, $0) },
                cleanup: { springboard_services_free($0) }
            ) { client in
                var rawIconData: UnsafeMutableRawPointer?
                var rawIconLength = 0
                if let ffiError = springboard_services_get_icon(client, bundleId, &rawIconData, &rawIconLength) {
                    throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to get app icon")
                }

                guard let rawIconData, rawIconLength > 0 else {
                    throw IdeviceBridge.makeError(message: "App icon data was empty")
                }

                defer { free(rawIconData) }

                let data = Data(bytes: rawIconData, count: rawIconLength)
                guard let image = UIImage(data: data) else {
                    throw IdeviceBridge.makeError(message: "Failed to decode app icon image")
                }

                return image
            }
        }
    }

    func ideviceInfoInit() throws -> OpaquePointer {
        try IdeviceBridge.withTunnelHandles(for: self) { adapter, handshake in
            try IdeviceBridge.connectClient(
                fallback: "Failed to connect to lockdownd",
                missingClientMessage: "Lockdownd client was not created",
                domain: "profiles",
                connect: { lockdownd_connect_rsd(adapter, handshake, $0) }
            )
        }
    }

    func ideviceInfoGetXML(withLockdownClient lockdownClient: OpaquePointer?) throws -> UnsafeMutablePointer<CChar>? {
        guard let lockdownClient else { return nil }

        var plistObject: plist_t?
        if let ffiError = lockdownd_get_value(lockdownClient, nil, nil, &plistObject) {
            throw IdeviceBridge.consumeFFIError(ffiError, fallback: "Failed to fetch device info")
        }

        guard let plistObject else {
            return nil
        }

        defer { plist_free(plistObject) }

        var xml: UnsafeMutablePointer<CChar>?
        var xmlLength: UInt32 = 0
        guard plist_to_xml(plistObject, &xml, &xmlLength) == PLIST_ERR_SUCCESS,
              let xml,
              xmlLength > 0 else {
            throw IdeviceBridge.makeError(message: "Failed to serialize device info plist")
        }

        return xml
    }
}

func FetchDeviceProcessList(_ error: NSErrorPointer) -> [NSDictionary]? {
    do {
        return try JITEnableContext.shared.fetchProcessList()
    } catch let nsError as NSError {
        error?.pointee = nsError
        return nil
    }
}

func KillDeviceProcess(_ pid: Int32, _ error: NSErrorPointer) -> Bool {
    do {
        try JITEnableContext.shared.killProcess(withPID: pid)
        return true
    } catch let nsError as NSError {
        error?.pointee = nsError
        return false
    }
}

struct ProcessInfoEntry: Identifiable {
    let pid: Int
    private let rawPath: String
    let bundleID: String?
    let name: String?

    init?(dictionary: NSDictionary) {
        guard let pidNumber = dictionary["pid"] as? NSNumber else { return nil }
        pid = pidNumber.intValue
        rawPath = dictionary["path"] as? String ?? "Unknown"
        bundleID = dictionary["bundleID"] as? String
        name = dictionary["name"] as? String
    }

    static func currentEntries(_ error: NSErrorPointer = nil) -> [ProcessInfoEntry] {
        let entries = FetchDeviceProcessList(error) ?? []
        return entries.compactMap(Self.init(dictionary:))
    }

    var id: Int { pid }

    var executablePath: String {
        rawPath.replacingOccurrences(of: "file://", with: "")
    }

    var displayName: String {
        if let name, !name.isEmpty {
            return name
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        if let component = executablePath.split(separator: "/").last {
            return String(component)
        }
        return "Process \(pid)"
    }

    var stableIdentifier: String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return displayName
    }
}

@objcMembers
final class CMSDecoderHelper: NSObject {
    static func decodeCMSData(_ cmsData: Data) throws -> Data {
        guard !cmsData.isEmpty else {
            throw IdeviceBridge.makeError(
                domain: NSCocoaErrorDomain,
                code: NSURLErrorBadURL,
                message: "Invalid or empty CMS payload"
            )
        }

        let xmlStart = Data("<?xml".utf8)
        let plistEnd = Data("</plist>".utf8)
        let binaryMagic = Data("bplist00".utf8)

        if let startRange = cmsData.range(of: xmlStart),
           let endRange = cmsData.range(of: plistEnd, options: [], in: startRange.lowerBound..<cmsData.endIndex) {
            return cmsData[startRange.lowerBound..<endRange.upperBound]
        }

        if let binaryRange = cmsData.range(of: binaryMagic) {
            return cmsData[binaryRange.lowerBound..<cmsData.endIndex]
        }

        throw IdeviceBridge.makeError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            message: "Unable to extract plist from CMS payload"
        )
    }
}

private enum LocationSimulationStatus {
    static let ok: Int32 = 0
    static let invalidIP: Int32 = 1
    static let pairingRead: Int32 = 2
    static let providerCreate: Int32 = 3
    static let remoteServer: Int32 = 9
    static let locationSimulation: Int32 = 10
    static let locationSet: Int32 = 11
    static let locationClear: Int32 = 12
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

enum LocationSimulationCommandQueue {
    static let shared = DispatchQueue(label: "com.stik.location-sim", qos: .userInitiated)

    /// Suppresses queued "hold"/resend re-injections while a Stop/Clear is in progress, so a resend
    /// that was already enqueued can't run AFTER the clear and re-freeze the fake location (which made
    /// Stop appear to do nothing). Set true synchronously by every stop path; reset false when a new
    /// simulation starts. Lock-guarded since it's read on this queue and written on the main thread.
    private static let suppressLock = NSLock()
    private static var _suppressResends = false
    static var suppressResends: Bool {
        get { suppressLock.lock(); defer { suppressLock.unlock() }; return _suppressResends }
        set { suppressLock.lock(); _suppressResends = newValue; suppressLock.unlock() }
    }
}

/// Bounded TCP reachability probe to the developer-tunnel endpoint (ip:49152). The location FFI
/// (tunnel_create_rppairing / location_simulation_set / _clear) has NO timeout and hangs forever on
/// a dead tunnel (e.g. LocalDevVPN dropped) — which would wedge the serial LocationSimulationCommandQueue
/// so even Stop/Panic's clear could never run. We probe first and fail fast instead. Mirrors
/// JITEnableContext.isTunnelEndpointReachable.
private func _isSimEndpointReachable(_ deviceIP: String = DeviceConnectionContext.targetIPAddress,
                                     timeoutSeconds: Double = 3) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(49152).bigEndian
    guard deviceIP.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return false }
    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    if rc == 0 { return true }
    if errno != EINPROGRESS { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, Int32(max(timeoutSeconds, 0.1) * 1000)) > 0 else { return false }
    var soError: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 else { return false }
    return soError == 0
}


func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    // Fail fast on a dead tunnel so the un-timeout-able FFI below can't hang and wedge the queue.
    if !_isSimEndpointReachable(deviceIP) {
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }
    if let locationSimulation = LocationSimulationState.locationSimulation {
        if let ffiError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(ffiError)
            LocationSimulationState.cleanup()
        } else {
            DeviceReadiness.markSimulationSucceeded()
            return LocationSimulationStatus.ok
        }
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(49152).bigEndian

    let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    guard inetResult == 1 else {
        return LocationSimulationStatus.invalidIP
    }

    var pairingHandle: OpaquePointer?
    let pairingError = pairingFile.withCString { rp_pairing_file_read($0, &pairingHandle) }
    if let pairingError {
        idevice_error_free(pairingError)
        return LocationSimulationStatus.pairingRead
    }

    guard let pairingHandle else {
        return LocationSimulationStatus.pairingRead
    }

    defer { rp_pairing_file_free(pairingHandle) }

    let providerError = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            tunnel_create_rppairing(
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.stride),
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }
    }

    if let providerError {
        idevice_error_free(providerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.providerCreate
    }

    let remoteServerError = remote_server_connect_rsd(
        LocationSimulationState.adapter,
        LocationSimulationState.handshake,
        &LocationSimulationState.remoteServer
    )
    if let remoteServerError {
        idevice_error_free(remoteServerError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.remoteServer
    }

    let locationSimulationError = location_simulation_new(
        LocationSimulationState.remoteServer,
        &LocationSimulationState.locationSimulation
    )
    if let locationSimulationError {
        idevice_error_free(locationSimulationError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSimulation
    }

    LocationSimulationState.remoteServer = nil

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        idevice_error_free(locationSetError)
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationSet
    }

    DeviceReadiness.markSimulationSucceeded()
    return LocationSimulationStatus.ok
}

func clear_simulated_location() -> Int32 {
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        return LocationSimulationStatus.locationClear
    }
    // Don't call the un-timeout-able clear over a dead tunnel (it would hang the serial queue). If
    // unreachable, drop the handle — the device can't be cleared until the tunnel returns, but the
    // app stays responsive and Stop/teleport work again once it's back.
    if !_isSimEndpointReachable() {
        LocationSimulationState.cleanup()
        return LocationSimulationStatus.locationClear
    }

    let ffiError = location_simulation_clear(locationSimulation)
    LocationSimulationState.cleanup()

    if let ffiError {
        idevice_error_free(ffiError)
        return LocationSimulationStatus.locationClear
    }

    return LocationSimulationStatus.ok
}
