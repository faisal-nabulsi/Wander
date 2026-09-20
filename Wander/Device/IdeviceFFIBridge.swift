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

/// Verbose trace of the location-injection path, written to the in-app Console log.
///
/// WHY THIS EXISTS: five attempted fixes for "the spoof reverts ~2 minutes after Airplane Mode goes off"
/// all failed, because every diagnosis was inferred from symptoms rather than observed. The confusing part
/// is that the injects keep SUCCEEDING while the device reports the real location — so success codes are
/// not evidence the fix is being honoured. This traces what the session actually does across the network
/// transition so the failure can be READ instead of guessed at. Timestamps are what matter: correlate the
/// moment the map snaps back with what this path was doing.
enum SpoofTrace {
    /// Master switch for the lines that MATTER — every session teardown, every rebuild, every late
    /// write outcome. These fire on transitions, not on a timer, so they cost nothing on a healthy
    /// session and they are the only record of how a spoof died. Leave this ON.
    static var enabled = true

    /// The per-tick chatter, split out and OFF by default.
    ///
    /// The old comment on `enabled` said "turn OFF before shipping widely — it writes a line every ~4s
    /// hold tick", and it was never turned off. That is ~900 entries an hour appended to a main-thread
    /// `@Published` array, hitting `LogManager`'s 4000-entry cap in about four and a half hours and
    /// then trimming continuously — steady allocation and main-thread churn for the entire life of
    /// exactly the long background sessions this release is trying to protect.
    ///
    /// Switching the whole trace off was the wrong answer, because it is also the only diagnostic that
    /// can prove what killed a session. So the tick lines go quiet and the transitions stay. Flip this
    /// to true when you need a blow-by-blow of a single hold.
    static var verbose = false

    static func log(_ message: String) {
        guard enabled else { return }
        LogManager.shared.addInfoLog("[spoof] \(message)")
    }

    /// A line that fires on the 4 s hold tick. Silent unless `verbose`.
    static func tick(_ message: String) {
        guard verbose else { return }
        LogManager.shared.addInfoLog("[spoof] \(message)")
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
    /// The developer-tunnel endpoint did not answer the bounded reachability probe, so NO
    /// un-timeout-able FFI call was attempted. One source of truth — see `LocationSimulationOutcome`.
    static let tunnelUnreachable: Int32 = LocationSimulationOutcome.tunnelUnreachable
    /// A stop was SENT but has not come back inside its bound. Deliberately distinct from
    /// `tunnelUnreachable`, which means the opposite thing (nothing was ever sent).
    static let clearStalled: Int32 = LocationSimulationOutcome.clearStalled
    /// A stop could NOT be sent yet because a write was still out on the detached FFI thread. The
    /// session is kept and the clear is owed — see `LocationSimulationState.clearOwed`.
    static let clearDeferred: Int32 = LocationSimulationOutcome.clearDeferred
}

/// The public half of the status codes: the one thing the UI is allowed to ask about a raw code, and
/// the words it says when the answer is yes.
///
/// WHY IT EXISTS. Every failure used to arrive as an opaque number that the UI rendered as
/// "…(error 3)" plus a paragraph of guesses (LocalDevVPN? Developer Mode? Airplane Mode?). "The
/// tunnel is not connected" is not a guess — it is a bounded TCP probe's answer, established before
/// anything was dialled — and it deserves to reach the user as such.
///
/// THE COPY DELIBERATELY OPENS WITH THE CHIP'S OWN WORDS ("Tunnel: disconnected"), so the sentence
/// the user reads in the alert is the same sentence they can see on the pill at the bottom of the
/// map. Two different vocabularies for one condition is how a user concludes they have two problems.
enum LocationSimulationOutcome {
    /// A location write / clear was refused because the tunnel endpoint (ip:49152) did not answer.
    static let tunnelUnreachable: Int32 = 13

    /// A stop WAS issued on the live session but did not report back inside its bound. It is not
    /// `tunnelUnreachable` (which means nothing was dialled and nothing was sent) and it is not
    /// `locationClear` (which means the device answered with an error). Kept separate because those
    /// three want three different sentences: "nothing to stop", "your device refused", "we asked and
    /// haven't heard back".
    static let clearStalled: Int32 = 14

    /// A stop that was NOT sent, because a location write was still outstanding on the detached FFI
    /// thread and the library is not safe to call twice on one handle. The session is KEPT and the
    /// clear is owed: it goes out by itself the moment that write comes back. Distinct from all three
    /// codes above because it is the only one where nothing has left the phone AND nothing has been
    /// given up on.
    static let clearDeferred: Int32 = 15

    /// Did this code mean "the tunnel is not connected"?
    static func isTunnelUnreachable(_ code: Int32) -> Bool { code == tunnelUnreachable }

    /// Did this code mean "the stop went out but has not been confirmed"?
    static func isClearStalled(_ code: Int32) -> Bool { code == clearStalled }

    /// Did this code mean "the stop has not gone out yet, and will"?
    static func isClearDeferred(_ code: Int32) -> Bool { code == clearDeferred }

    static var stopStalledTitle: String {
        L("stop.stalled.title", fallback: "Stop sent")
    }

    /// The stop is on the wire and the answer is simply late. Say that, and give the one instruction
    /// that resolves it if it never lands — deliberately NOT phrased as a failure, because on a
    /// healthy-but-slow tunnel this resolves itself a second later.
    ///
    /// ⚠️ TAKES THE TRANSPORT, for the same reason `tunnelDownMessage` does. The old single string
    /// told everybody to "turn Airplane Mode on and then off, and tap Stop again". On Wi-Fi that
    /// names the wrong problem entirely (the fix there is to reconnect LocalDevVPN), and on cellular
    /// it is worse than wrong: this path has already DROPPED the session handle, so tapping Stop
    /// again has nothing to send over and iOS will not let a replacement session be born on mobile
    /// data. The only sequence that can work there is a Cellular Mode run, which is exactly what the
    /// app-wide alert offers.
    static func stopStalledMessage(onCellular: Bool) -> String {
        if onCellular {
            return L("stop.stalled.message.cellular",
                     fallback: "Wander told your device to stop simulating, but your device hasn't confirmed it yet. Wander has stopped everything on its side. If your location doesn't go back to normal within a few seconds, use Cellular Mode to clear it — on mobile data that is the only way to reach your device again.")
        }
        return L("stop.stalled.message",
                 fallback: "Wander told your device to stop simulating, but your device hasn't confirmed it yet. Wander has stopped everything on its side. If your location doesn't go back to normal within a few seconds, check that the tunnel is connected and tap Stop again.")
    }

    /// ══ NOTHING WAS SENT, AND THAT IS THE HONEST WORD FOR IT. ══
    ///
    /// This is `stopStalledMessage`'s opposite and it must never borrow its copy: "Wander told your
    /// device to stop simulating" would be a straight untruth here. A write is still outstanding on
    /// the FFI thread, so the stop is queued behind it rather than lost — Wander sends it itself when
    /// that write comes back, and the user does not have to do anything.
    static var stopDeferredTitle: String {
        L("stop.deferred.title", fallback: "Finishing the last update first")
    }

    static var stopDeferredMessage: String {
        L("stop.deferred.message",
          fallback: "Wander has stopped on its side, but it couldn't send the stop to your device yet — the previous location update hasn't come back. Wander will send it automatically as soon as that finishes. If your location hasn't gone back to normal in a minute, tap Stop again.")
    }

    static var stopRefusedTitle: String {
        L("stop.refused.title", fallback: "Your device is still showing the fake location")
    }

    /// ⚠️ THE DEVICE, NOT WANDER, IS THE ONE STILL HOLDING THE FIX HERE, and the copy has to say so —
    /// this is the one stop outcome where the user walks away believing they are back on real GPS
    /// while they are not.
    ///
    /// On cellular the honest instruction is the Airplane cycle and nothing else: the session that
    /// carried the stop is now dead, and `remotepairingdeviced` marks its own listeners deny-cellular,
    /// so no amount of retrying opens a replacement while mobile data is the only transport.
    static func stopRefusedMessage(onCellular: Bool) -> String {
        if onCellular {
            return L("stop.refused.message.cellular",
                     fallback: "Wander stopped on its side, but your device refused the stop and is still reporting the simulated location. You're on mobile data with no Wi-Fi, so Wander can't open a new connection to fix it in place — Cellular Mode turns Airplane Mode on just long enough to reconnect, clears the location, then turns it back off.")
        }
        return L("stop.refused.message",
                 fallback: "Wander stopped on its side, but your device refused the stop and is still reporting the simulated location. Check that the tunnel is connected, then tap Stop again.")
    }

    static var tunnelDownTitle: String {
        L("tunnel.down.title", fallback: "Tunnel: disconnected")
    }

    /// ⚠️ THE ADVICE DEPENDS ON THE TRANSPORT, and getting this wrong is worse than saying nothing.
    ///
    /// This used to be one string telling everybody to connect LocalDevVPN and wait for the chip to
    /// read "Tunnel: connected". On mobile data with no Wi-Fi that instruction is not merely unhelpful,
    /// it is FALSE: the tunnel is already connected, reconnecting it changes nothing, and the actual
    /// fix — an Airplane Mode cycle — was never mentioned. That is the most common cellular failure in
    /// the app, so the single most common failure message was confidently sending people the wrong way.
    ///
    /// WHY THE AIRPLANE CYCLE IS THE ANSWER THERE, in one line: `remotepairingdeviced` marks its own
    /// listeners deny-cellular, so iOS refuses to open a NEW connection to them while the only
    /// transport is cellular. An ESTABLISHED session survives the toggle back, which is why one cycle
    /// at the start buys a whole session and why nothing in the app can substitute for it.
    static var tunnelDownMessage: String {
        // One question, asked through the app's existing NWPathMonitor flag (which reads the
        // UNDERLYING transport, so Wander's own utun can't fool it into saying Wi-Fi).
        if NetworkReachability.isOnCellularSnapshot {
            return L("tunnel.down.message.cellular",
                     fallback: "Wander couldn't reach the connection it injects location through, so nothing was sent to your device. You're on mobile data with no Wi-Fi, and iOS refuses to open this connection on cellular — reconnecting the tunnel won't help. Turn Airplane Mode ON, start the spoof, then turn Airplane Mode back OFF: the connection survives the switch. Cellular Mode does exactly that for you.")
        }
        return L("tunnel.down.message",
                 fallback: "Wander couldn't reach the connection it injects location through, so nothing was sent to your device. Connect LocalDevVPN (or turn on Wander's own tunnel in Settings), wait for the chip to read \"Tunnel: connected\", then try again.")
    }

    /// Title + body for "the spoof you had is gone", as distinct from "it never started".
    static var sessionLostTitle: String {
        L("spoof.lost.title", fallback: "Spoof stopped")
    }

    /// ⚠️ TAKES THE TRANSPORT AS AN ARGUMENT — IT MUST NOT RE-READ IT.
    ///
    /// This was a computed property that asked `NetworkReachability` at RENDER time, and it was
    /// wrong: the recovery button is chosen from the transport recorded when the session DIED, so the
    /// two could disagree and the alert would offer "Run Cellular Mode" above a paragraph telling the
    /// user to check their tunnel. Caught on screen — the sim reports Wi-Fi, so a loss recorded as
    /// cellular rendered the Wi-Fi copy under the cellular button.
    ///
    /// The transport genuinely can change between the death and the moment the user reads this (they
    /// walk out of Wi-Fi range; the alert waits while the phone is in a pocket), and the message is
    /// the half that carries the instructions. One recorded fact, both halves.
    static func sessionLostMessage(onCellular: Bool) -> String {
        if onCellular {
            return L("spoof.lost.message.cellular",
                     fallback: "Your device stopped accepting the simulated location, so it's back on real GPS. On mobile data iOS won't let Wander open a new connection, so this can't be fixed in place — Cellular Mode turns Airplane Mode on just long enough to reconnect, sets your spot again, then turns it back off.")
        }
        return L("spoof.lost.message",
                 fallback: "Your device stopped accepting the simulated location, so it's back on real GPS. Check that the tunnel is connected, then start again.")
    }

    /// Used when a location command has not reported back at all — we know the queue is waiting on
    /// the transport, but not that the transport is definitively gone, so the wording says so.
    static var tunnelStalledTitle: String {
        L("tunnel.stalled.title", fallback: "Tunnel: not responding")
    }

    static var tunnelStalledMessage: String {
        L("tunnel.stalled.message",
          fallback: "Wander is still waiting on the connection it injects location through, so your location hasn't been sent. The controls are unlocked again so you can Stop or retry. Check that LocalDevVPN (or Wander's own tunnel) is connected.")
    }
}

private enum LocationSimulationState {
    static var adapter: OpaquePointer?
    static var handshake: OpaquePointer?
    static var remoteServer: OpaquePointer?
    static var locationSimulation: OpaquePointer?

    /// The endpoint the LIVE session was actually established over.
    ///
    /// Without this, nothing downstream can tell which address family is carrying the session, and the
    /// code has to guess — which is how the clear path ended up probing IPv4 for a session running on
    /// IPv6 and silently refusing to clear it. Recorded at the one moment it is known for certain (the
    /// successful rebuild) and torn down with the session.
    ///
    /// Lock-protected because the health monitor reads it from a utility queue while the serial
    /// LocationSimulationCommandQueue writes it; a `String` is not a word-sized atomic value.
    private static let liveTargetLock = NSLock()
    private static var _liveTarget: DeviceConnectionContext.DialTarget?
    static var liveTarget: DeviceConnectionContext.DialTarget? {
        get { liveTargetLock.lock(); defer { liveTargetLock.unlock() }; return _liveTarget }
        set { liveTargetLock.lock(); _liveTarget = newValue; liveTargetLock.unlock() }
    }

    /// Why the session was torn down, recorded at the ONE place that can know it.
    ///
    /// WHY THIS EXISTS. There are nine `cleanup()` call sites and, from outside, every one of them
    /// produced the identical observable outcome: the handle is gone and the device is back on real
    /// GPS. So "the user's spoof died" could never be attributed — a write that came back a real FFI
    /// error, a user switching to gs-loc mid-session, and a normal Stop were indistinguishable after
    /// the fact, and so were a jetsam and a force-quit. Two shipped regressions in this area were both
    /// diagnosed from symptoms because this fact was never written down.
    ///
    /// ⚠️ OBSERVATION ONLY, same rule as `LocationSessionProbeState`. Nothing may branch spoofing
    /// behaviour on this value.
    enum TeardownReason: String {
        /// A bounded write came back an actual FFI error inside its bound. Involuntary.
        case writeFailed = "write returned an error"
        /// A write we had stopped waiting on came back an error later. Involuntary, and the most
        /// likely honest death for a backgrounded user.
        case lateWriteFailed = "late write returned an error"
        /// A rebuild leg failed. No live session was lost — this is a failed resurrection.
        case rebuildFailed = "rebuild leg failed"
        /// The user switched into gs-loc mode while a DVT session was live.
        case gslocModeSwitch = "switched to gs-loc mode"
        /// Stop, and the device came back with an error rather than taking the stop. Closing path,
        /// but the one where the device may still be holding the fix.
        case clearFailed = "stop, device refused the clear"
        /// Stop, and the clear did not come back inside its bound — so the handle was DROPPED, not
        /// freed (the detached FFI thread may still be using it). Closing path.
        case clearStalled = "stop, clear did not come back"
        /// Stop, normally. Closing path.
        case cleared = "stop"
    }

    private static let teardownLock = NSLock()
    private static var _lastTeardown: (reason: TeardownReason, at: Date)?
    static var lastTeardown: (reason: TeardownReason, at: Date)? {
        teardownLock.lock(); defer { teardownLock.unlock() }; return _lastTeardown
    }

    static func cleanup(reason: TeardownReason) {
        noteTeardown(reason)
        cleanup()
    }

    /// Record WHY without freeing anything.
    ///
    /// Split out of `cleanup(reason:)` for the one caller that must not free: a stop whose clear
    /// stalled has to drop its references rather than release them (the detached FFI thread may still
    /// be using the pointers), and it still deserves to say what happened. Everything the reason is
    /// used for is observation, so recording it separately from the free is safe by construction.
    static func noteTeardown(_ reason: TeardownReason) {
        // Only record when something was actually torn down; the rebuild legs call this against a
        // half-built session and would otherwise drown out the real deaths.
        guard locationSimulation != nil || liveTarget != nil else { return }
        teardownLock.lock()
        _lastTeardown = (reason, Date())
        teardownLock.unlock()
        SpoofTrace.log("SESSION TORN DOWN — \(reason.rawValue)")
    }

    static func cleanup() {
        // The count describes ONE handle's refusals. Whatever happens next gets a fresh one.
        resetFailedClearCount()
        liveTarget = nil
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

    // A bounded write timed out but the session is NOT presumed dead: the detached FFI thread is still
    // blocked on it, and during a network transition a perfectly healthy loopback write can take many
    // seconds (TCP retransmit backoff while the interface is rebuilt). We keep the session, skip issuing
    // further writes until that one lands (the FFI is not safe to call concurrently on one handle), and
    // let the OUTCOME decide the session's fate. This is what build 50 effectively did — it never threw
    // away an established channel on a transient — and why airplane-off used to survive.
    /// True while a write is still out on the detached thread. A stalled write must not be mistaken for a
    /// dead session — that mistake is what broke surviving Airplane-Mode-off.
    private static let writeLock = NSLock()
    private static var _writeInFlight = false
    static var writeInFlight: Bool {
        get { writeLock.lock(); defer { writeLock.unlock() }; return _writeInFlight }
        set { writeLock.lock(); _writeInFlight = newValue; writeLock.unlock() }
    }

    /// ══ A STOP THE USER ASKED FOR THAT WE HAVE NOT MANAGED TO DELIVER YET. ══
    ///
    /// `clearOwed` — Stop arrived while a write was still out on the detached FFI thread. The library
    /// is not safe to call twice on one handle, so the clear could not be issued THEN; this is the
    /// note that says it still must be. `_boundedSet`'s late-outcome callback honours it the instant
    /// the write comes back, which is the only moment the handle becomes free. Without it, that Stop
    /// was simply dropped on the floor — the owner-reported symptom, with a different trigger.
    ///
    /// `clearUnconfirmed` — a clear WAS issued but never came back inside its bound, so the handle
    /// had to be dropped rather than freed. Nothing else in the process can tell that state from "we
    /// have no session because nothing is running", and conflating them is what made a second Stop
    /// return a fabricated `ok`.
    ///
    /// Both are plain observed facts, set and read on the serial location queue and the FFI thread,
    /// so they carry the same lock as the rest of this state.
    private static let stopFlagsLock = NSLock()
    private static var _clearOwed = false
    private static var _clearUnconfirmed = false

    static var clearOwed: Bool {
        get { stopFlagsLock.lock(); defer { stopFlagsLock.unlock() }; return _clearOwed }
        set { stopFlagsLock.lock(); _clearOwed = newValue; stopFlagsLock.unlock() }
    }

    /// Read-and-clear, so the late-write callback and a concurrent Stop cannot both act on one debt.
    static func takeClearOwed() -> Bool {
        stopFlagsLock.lock(); defer { stopFlagsLock.unlock() }
        let owed = _clearOwed
        _clearOwed = false
        return owed
    }

    static var clearUnconfirmed: Bool {
        get { stopFlagsLock.lock(); defer { stopFlagsLock.unlock() }; return _clearUnconfirmed }
        set { stopFlagsLock.lock(); _clearUnconfirmed = newValue; stopFlagsLock.unlock() }
    }

    /// How many times in a row the device has answered a clear with an error over the CURRENT handle.
    /// The first failure keeps the session so a second Stop can retry for free (an FFI error is not
    /// proof the channel is dead, and on cellular no replacement can be born); the second frees it, so
    /// a genuinely dead handle is not retried forever. Zeroed whenever a session is established or
    /// released, so it can never carry over into a new one.
    private static var _failedClearCount = 0

    static var failedClearCount: Int {
        stopFlagsLock.lock(); defer { stopFlagsLock.unlock() }
        return _failedClearCount
    }

    static func noteFailedClear() {
        stopFlagsLock.lock(); _failedClearCount += 1; stopFlagsLock.unlock()
    }

    static func resetFailedClearCount() {
        stopFlagsLock.lock(); _failedClearCount = 0; stopFlagsLock.unlock()
    }

    /// Drop our references WITHOUT freeing them — used only when a bounded write TIMED OUT and the
    /// detached FFI thread may still be using the pointers. Leaks one dead session; the alternative is a
    /// use-after-free. The next inject rebuilds, which is what actually restores the spoof.
    static func dropReferencesUnsafeToFree() {
        resetFailedClearCount()
        liveTarget = nil
        locationSimulation = nil
        remoteServer = nil
        handshake = nil
        adapter = nil
    }

}

/// A READ-ONLY window onto the live DVT session, for diagnostics that live outside this file.
///
/// WHY IT EXISTS. The one question that could not be answered from source — "when the transport
/// changed under an established session, was the session still held?" — had no way to be written
/// down. Everything else in the app INFERS session liveness from write history
/// (`LocationSessionActivity.mayHoldOpenSession`, a causal test over inject/clear ordering); nothing
/// reported the fact itself. Two shipped regressions in this area (build 84, build 124) were both
/// diagnosed from symptoms because this fact was never in the log.
///
/// Backed by `liveTarget`, which is lock-protected and set/cleared with the session — assigned at the
/// one successful rebuild, nil'd by `cleanup()` — so it is safe to read from any thread and it is the
/// same fact the write funnel acts on.
///
/// ⚠️ OBSERVATION ONLY. Nothing may branch spoofing behaviour on this. A probe that ACTS is precisely
/// the shape of the build-84 and build-124 bugs; this exists so the next such question can be read
/// out of a log instead of guessed at.
enum LocationSessionProbeState {
    /// True while an FFI location-simulation session handle is open in this process.
    static var isSessionHeld: Bool { LocationSimulationState.liveTarget != nil }

    /// Which address family is carrying the live session ("IPv4"/"IPv6"), or nil when none is held.
    static var liveFamilyLabel: String? { LocationSimulationState.liveTarget?.familyLabel }

    /// True while a bounded write is still out on the detached FFI thread. A stall here is NOT a dead
    /// session — see `_simulate_location` — but knowing a write was mid-flight across a transport
    /// change is half of reading what happened.
    static var isWriteInFlight: Bool { LocationSimulationState.writeInFlight }

    /// Why the last session teardown happened, and when. See `LocationSimulationState.TeardownReason`.
    static var lastTeardownReason: String? { LocationSimulationState.lastTeardown?.reason.rawValue }

    /// True when the last teardown was something that happened TO us rather than something a person
    /// asked for. This is the class that costs a cellular user an Airplane Mode toggle, so it is the
    /// class worth telling them about.
    static var lastTeardownWasInvoluntary: Bool {
        switch LocationSimulationState.lastTeardown?.reason {
        case .writeFailed, .lateWriteFailed: return true
        default: return false
        }
    }
}

/// Arbitrates the race between a bounded write's caller giving up and the detached FFI thread finishing,
/// so the session is freed exactly once, by whichever side is last — never twice (crash) and never zero
/// times (the leak that broke airplane-off recovery).
private final class BoundedSetHandoff {
    private let lock = NSLock()
    private var callerGaveUp = false
    private var threadFinished = false

    /// Caller timed out. Returns true if the thread ALREADY finished, meaning the caller must free.
    func markCallerGaveUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        callerGaveUp = true
        return threadFinished
    }

    /// Thread finished. Returns true if the caller had already given up, meaning the thread must free.
    func markThreadFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        threadFinished = true
        return callerGaveUp
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
    private static var _lastStreamClaimAt: Date?
    static var suppressResends: Bool {
        get { suppressLock.lock(); defer { suppressLock.unlock() }; return _suppressResends }
        set {
            suppressLock.lock()
            _suppressResends = newValue
            if newValue { _lastStreamClaimAt = Date() }
            suppressLock.unlock()
        }
    }

    /// ══ "IS A MOVEMENT ENGINE WRITING RIGHT NOW?" — DERIVED, NOT DECLARED. ══
    ///
    /// The Route and Joystick engines each own the location stream while they run, and each says so by
    /// setting `suppressResends = true` — not once, but on EVERY TICK (`WalkModeView.step`,
    /// `RouteModeView`'s playback loop), because a cross-tab teleport may re-enable the map's resend
    /// at any moment. That re-assertion is already a heartbeat; this just timestamps it.
    ///
    /// It exists for one question, asked by one caller: Cellular Mode's deferred hand-off. A run takes
    /// about thirty seconds and the closure that starts the drive or the walk is stashed at TAP time,
    /// so between the tap and the start the user can switch tabs and begin the OTHER engine by hand.
    /// Both would then write the stream — the two-writer backward jump that produces Pokémon GO's
    /// "Failed to detect location (12)" (OTA 92). Nothing else could see across the two tabs: each
    /// engine's `isDriving`/`isWalking` is `@State` private to its own view.
    ///
    /// ⚠️ IT IS A VETO, NOT A GATE, and the distinction is why this is safe. Only the hand-off asks;
    /// the ordinary Drive and Start buttons are untouched. And it EXPIRES: the stop paths also set
    /// `suppressResends = true` (deliberately — see the property above), so the flag alone would read
    /// "a writer is running" forever after any Stop. The timestamp is what makes a finished run stop
    /// claiming the stream a few seconds later, with no latch anybody has to remember to release.
    static func movementWriterActive(within seconds: TimeInterval = 6) -> Bool {
        suppressLock.lock(); defer { suppressLock.unlock() }
        guard _suppressResends, let at = _lastStreamClaimAt else { return false }
        return Date().timeIntervalSince(at) <= seconds
    }
}

/// Bounded TCP reachability probe to the developer-tunnel endpoint (ip:49152). The location FFI
/// (tunnel_create_rppairing / location_simulation_set / _clear) has NO timeout and hangs forever on
/// a dead tunnel (e.g. LocalDevVPN dropped) — which would wedge the serial LocationSimulationCommandQueue
/// so even Stop/Panic's clear could never run. We probe first and fail fast instead. Mirrors
/// JITEnableContext.isTunnelEndpointReachable.
///
/// Family-agnostic: probes whatever address it is handed (IPv4 or IPv6), because with the opt-in IPv6
/// loopback the address being dialled may be a ULA. A hardcoded AF_INET probe would fail the gate
/// before the v6 dial was ever attempted.
///
/// The socket work lives in `EndpointProbe`, which CAPTURES the failure reason (errno number, its
/// symbolic name, strerror's text) and logs it in the `[spoof]` style. This function's contract is
/// deliberately untouched — same default address, same 3 s default bound, same "true only on a
/// completed handshake" Bool — because it gates the real dial path and this change is diagnostics
/// only. `EndpointProbe.probe` is also the ONLY place the errno is read, in the statement right after
/// the syscall, which is what keeps the reported number from being a stale one.
private func _isSimEndpointReachable(_ deviceIP: String = DeviceConnectionContext.targetIPAddress,
                                     timeoutSeconds: Double = 3) -> Bool {
    let result = EndpointProbe.probe(deviceIP, timeoutSeconds: timeoutSeconds)
    EndpointProbeLog.record(result, context: "sim endpoint:")
    return result.isReachable
}

/// Public, lightly-bounded reachability probe used by TunnelHealthMonitor's light poll. Wraps the
/// private `_isSimEndpointReachable` TCP probe (ip:49152) so the health chip can classify "down"
/// (endpoint unreachable) without hammering the real inject FFI. Runs off the main thread by callers.
func isTunnelSimEndpointReachable() -> Bool {
    // A LIVE session has exactly one answer, and it is not "either family": the session is carried by
    // one family, and only that family can say whether it is still up. Answering "reachable" because
    // the OTHER family happens to respond is how a dead IPv6 session would read green on a dual-stack
    // device — TunnelHealthMonitor feeds this straight into `reachable`, so its `!reachable` branch
    // would never fire and the chip would only recover via the slower consecutive-failure threshold.
    if let live = LocationSimulationState.liveTarget {
        return _isSimEndpointReachable(live.address)
    }

    // No session yet (e.g. WanderTunnel.ensureStarted polling for the loopback to come up). Here the
    // question really is "can ANY family carry a dial", so try the candidates. IPv4 is probed FIRST
    // (see reachabilityProbeTargets) and the v6 leg carries the tighter bound, so with the experiment
    // off this is the identical single 3s probe that shipped, and with it on the common case still
    // returns on the first probe.
    for target in DeviceConnectionContext.reachabilityProbeTargets()
    where _isSimEndpointReachable(target.address, timeoutSeconds: target.probeTimeoutSeconds) {
        return true
    }
    return false
}

/// Thread-safe record of recent inject outcomes, fed by every `simulate_location` call regardless of
/// which mode/queue drove it. TunnelHealthMonitor reads this (plus a light reachability poll) to
/// classify tunnel health as connected / unstable / disconnected. Deliberately tiny + lock-guarded:
/// it's written on the serial location queue and read on the main thread.
enum TunnelInjectStatus {
    private static let lock = NSLock()
    private static var _lastSuccessAt: Date?
    private static var _lastFailureAt: Date?
    /// Consecutive inject failures since the last success. Reset to 0 on any success.
    private static var _consecutiveFailures = 0

    /// ── SOFT SUCCESS vs CONFIRMED SUCCESS, and why the difference is load-bearing ────────────────
    ///
    /// `_simulate_location` deliberately returns `ok` on two paths where the write has NOT landed: a
    /// write still in flight on the detached thread, and a bounded write that timed out (kept on
    /// purpose — that is the build-52 behaviour airplane-off survival depends on). Those are the right
    /// return values for the INJECT path, because a stall is not a dead session.
    ///
    /// They are the wrong input for a HEALTH claim. The classifier is about to let a recent success
    /// outrank an unreachable probe, and it may only do that on evidence that the device really took
    /// the coordinate. So the two soft paths mark themselves, and the classifier treats a soft success
    /// as "unknown" rather than as proof. Without this, a permanently-blocked FFI write would read as
    /// a healthy green session forever — a fabricated signal, which is exactly what this file's
    /// header promises never to produce.
    private static var _pendingSoft = false
    private static var _lastSuccessWasSoft = false

    /// Called by the soft-ok paths in `_simulate_location`, immediately before the `record(success:)`
    /// that follows them on the same (serial) queue.
    static func markNextSuccessSoft() {
        lock.lock(); defer { lock.unlock() }
        _pendingSoft = true
    }

    static func record(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if success { _lastSuccessWasSoft = _pendingSoft }
        _pendingSoft = false
        if success {
            _lastSuccessAt = now
            _consecutiveFailures = 0
        } else {
            _lastFailureAt = now
            _consecutiveFailures += 1
        }
    }

    /// Immutable snapshot for the health classifier. Read on the main thread.
    struct Snapshot {
        let lastSuccessAt: Date?
        let lastFailureAt: Date?
        let consecutiveFailures: Int
        /// See `markNextSuccessSoft`. True when the most recent success was a stall we chose to keep,
        /// not a confirmed landing — so it may not be used as proof the session is alive.
        let lastSuccessWasSoft: Bool
    }

    static var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(lastSuccessAt: _lastSuccessAt,
                        lastFailureAt: _lastFailureAt,
                        consecutiveFailures: _consecutiveFailures,
                        lastSuccessWasSoft: _lastSuccessWasSoft)
    }

    /// ══ "THE SESSION WE HAVE IS CARRYING TRAFFIC" — THE ANSWER A REACHABILITY PROBE CANNOT GIVE. ══
    ///
    /// Every place in the app that asked "is the tunnel usable?" asked it by opening a NEW connection
    /// to the pairing listener. On mobile data that question has a fixed answer and it is the wrong
    /// one: `remotepairingdeviced` marks its own listeners `SO_RESTRICT_DENY_CELLULAR`, XNU's port
    /// lookup SKIPS restricted sockets, and the SYN draws an instant RST. The wall is on connection
    /// BIRTH only — an ESTABLISHED session keeps working on cellular indefinitely — so a live spoof
    /// and a dead tunnel are indistinguishable to that probe.
    ///
    /// This is the other half of the evidence, and it is strictly better evidence: the device itself
    /// returning success for a real `location_simulation_set` on the handle we already hold.
    /// `TunnelHealthMonitor.apply` was fixed in build 148 to let exactly this outrank the probe; this
    /// makes the same test available to the start paths, which were still probe-only.
    ///
    /// ⚠️ CONFIRMED SUCCESSES ONLY. A soft success is a write still in flight or one that timed out
    /// and was deliberately kept — neither has landed, and treating either as proof would fabricate a
    /// green signal for a permanently-blocked write. A non-zero consecutive-failure count also
    /// disqualifies it: whatever was working has stopped since.
    static func hasRecentConfirmedSuccess(within seconds: TimeInterval = 20) -> Bool {
        let snap = snapshot
        guard snap.consecutiveFailures == 0, !snap.lastSuccessWasSoft, let at = snap.lastSuccessAt else {
            return false
        }
        return Date().timeIntervalSince(at) <= seconds
    }

    /// Clear history — called when a session starts so a stale failure from a prior run doesn't paint
    /// the chip red the instant a fresh spoof begins.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _lastSuccessAt = nil
        _lastFailureAt = nil
        _consecutiveFailures = 0
        _pendingSoft = false
        _lastSuccessWasSoft = false
    }

    /// ══ FORGET THE FAILURES, KEEP THE PROOF. ══
    ///
    /// `reset()` is called from `TunnelHealthMonitor.startMonitoring()`, which is called from
    /// `SimulationSession.started()`, which every teleport calls — INCLUDING the teleport inside a
    /// Cellular Mode run. So the full reset wiped the confirmed inject that the teleport had recorded
    /// microseconds earlier: the one piece of evidence that outranks a reachability probe, destroyed
    /// by the very flow that produced it. Everything downstream then fell back to
    /// `isTunnelSimEndpointReachable()`, which is FALSE BY CONSTRUCTION on mobile data, and refused to
    /// start the drive Cellular Mode had just built a healthy session for.
    ///
    /// What `startMonitoring` actually needs is stated in its own comment — "so a failure from a
    /// previous run can't paint the chip red". That is the failure history, and only the failure
    /// history. A success from the last few seconds is a true fact about the transport whichever
    /// session recorded it, and every reader of it is already time-bounded
    /// (`hasRecentConfirmedSuccess(within:)`), so keeping it cannot make anything stale.
    static func resetFailures() {
        lock.lock(); defer { lock.unlock() }
        _lastFailureAt = nil
        _consecutiveFailures = 0
        _pendingSoft = false
    }
}


func simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    // EXPERIMENTAL PoGo (gs-loc) mode: bypass the dev tunnel entirely and hand the coordinate to the
    // user's proxy-side gs-loc rewriter, which produces a fix that reads isSimulatedBySoftware=false
    // (no Error 12). Every teleport/walk/route path funnels through here, so this one gate re-routes
    // them all. See GslocMode. (Off by default; only useful with the proxy + module set up.)
    if GslocMode.enabled {
        GslocMode.push(latitude: latitude, longitude: longitude)
        // HONEST, NOT OPTIMISTIC. `push` is asynchronous and returns Void, so this call site cannot know
        // whether THIS write reached the proxy — and it must not wait, because it runs on the serial
        // location command queue where a block would wedge Stop and Panic. So we record the LAST KNOWN
        // outcome: it lags by one write, which is exactly the property that makes it free. This line used
        // to hardcode `success: true`, which meant a teleport that never left the device was recorded
        // identically to one that landed.
        TunnelInjectStatus.record(success: GslocMode.lastPushOutcome.looksAccepted)
        // DUAL ENGINE WAS REMOVED 2026-08-10 — the hypothesis is DISPROVEN, not untested.
        //
        // The idea was that gs-loc could anchor Apple's network location while the DVT tunnel supplied
        // smooth movement, letting Pokémon GO accept a moving fix. A controlled on-device A/B killed it:
        // holding the location constant at one coordinate (both sources agreeing), the tunnel's presence
        // ALONE decided the outcome — flag TRUE → Error 12; stop the tunnel, same coordinate, flag FALSE
        // → PoGo works. Error 12 tracks `isSimulatedBySoftware`, so pairing the tunnel with anything is
        // pointless: the tunnel IS the rejected thing.
        //
        // It was also actively harmful. Falling through ran the DVT inject too, and when the tunnel was
        // down (the normal state in gs-loc mode, since Shadowrocket holds iOS's single VPN slot) its
        // failure became this function's return value — turning a SUCCESSFUL gs-loc push into a reported
        // teleport failure.
        return LocationSimulationStatus.ok
    }
    let code = _simulate_location(deviceIP, latitude, longitude, pairingFile)
    // Record every inject outcome (0 = ok) for the tunnel health chip. Cheap, thread-safe, and the
    // ONLY place that sees every real inject regardless of which mode/queue triggered it — so the
    // health classifier reads genuine success/failure history, not just a synthetic reachability poll.
    TunnelInjectStatus.record(success: code == LocationSimulationStatus.ok)
    return code
}


/// The one write funnel for the spoof TIMELINE — a pure pass-through around `simulate_location`.
///
/// Wander is a remote control that forgets: it writes a coordinate into the device and keeps nothing,
/// so nobody can check whether the story their location tells holds together. This is where the
/// record comes from, and it sits HERE because nearly every mode — teleport, walk, route, itinerary,
/// schedule, Shortcuts, and the gs-loc re-route inside `simulate_location` above — already funnels
/// through that one function. One wrapper covers nine of the ten write sites; nine call sites logging
/// themselves would not.
///
/// ⚠️ IT IS NOT LITERALLY EVERY WRITE, and pretending otherwise would be the kind of comment that
/// costs someone an afternoon. `GslocControlView`'s "Re-teleport to last spot" button calls
/// `GslocMode.push` DIRECTLY, bypassing `simulate_location` entirely, so this wrapper cannot see it.
/// That site logs itself with an explicit `SpoofTimelineRecorder.record(source: .gsloc)`. Any future
/// caller of `GslocMode.push` has the same obligation.
///
/// ⚠️ READ BEFORE EDITING. This file took eight fixes to stabilise (root cause: iOS suspending the
/// app and reclaiming the socket — Apple TN2277) and the injection path below is finally correct.
/// This wrapper is bound by a hard contract, and anything that breaks it is a spoof bug, not a
/// logging bug:
///
///   * PURE PASS-THROUGH. It returns exactly what `simulate_location` returned, unchanged, on every
///     path. It has no failure mode of its own and no branch on the ledger's behaviour.
///   * NEVER THROWS. Nothing in it can throw, so no caller needs `try` and no error can escape.
///   * NO LATENCY ON THE CALLING QUEUE. `simulate_location` runs on the SERIAL location command
///     queue; a blocked call there wedges Stop and Panic. `SpoofTimelineRecorder.record` does two
///     float checks, takes a timestamp, and hands off to its own utility queue — no lock the caller
///     can contend on, no file I/O, no UserDefaults read, no geocoding, no main-actor hop.
///   * RETAINS NOTHING. Only three `Double`s and an enum cross the hand-off. Nothing that could keep
///     an FFI handle, a session or a device object alive is captured.
///   * FAILS INVISIBLY. If every part of the ledger is broken — disk full, directory gone, decoder
///     confused — the spoof is unaffected, because nothing on the inject path ever reads a result
///     back from it.
///
/// The logging is DELIBERATELY after the call, not around it: the recorded row includes whether the
/// inject was accepted, and a run of rejected rows is exactly the "my spoof looked live but wasn't"
/// story the timeline exists to expose.
@discardableResult
func simulate_location_logged(_ deviceIP: String,
                              _ latitude: Double,
                              _ longitude: Double,
                              _ pairingFile: String,
                              source: SpoofFixSource = .other) -> Int32 {
    let code = simulate_location(deviceIP, latitude, longitude, pairingFile)
    // On the gs-loc path the return code says nothing: that branch always reports `.ok` because the push
    // is asynchronous and the caller must not block on it. Reading `code` alone therefore made EVERY
    // gs-loc row `accepted: true` by construction — the one thing this ledger exists to disprove. Use the
    // last known push outcome there instead (it lags by one write, and `.unknown` counts as accepted so a
    // fresh session isn't painted amber).
    let accepted = GslocMode.enabled
        ? GslocMode.lastPushOutcome.looksAccepted
        : code == LocationSimulationStatus.ok
    SpoofTimelineRecorder.record(latitude: latitude,
                                 longitude: longitude,
                                 source: source,
                                 accepted: accepted)
    return code
}


/// Read an FFI error's real code + message. MUST be called BEFORE idevice_error_free — the whole reason
/// "error 3" was uninformative for days is that every failure site freed the error without ever looking
/// inside it, discarding the one string that says what actually went wrong.
private func _ffiDetail(_ err: UnsafeMutablePointer<IdeviceFfiError>?) -> String {
    guard let err else { return "(no error object)" }
    let code = err.pointee.code
    let msg = err.pointee.message.flatMap { String(validatingUTF8: $0) } ?? "(no message)"
    return "ffi_code=\(code) msg=\(msg)"
}

private enum BoundedSetResult { case ok, failed, timedOut }

/// Run `location_simulation_set` on the CACHED handle with a hard timeout. The FFI itself has no
/// timeout and can block forever on a genuinely dead tunnel, so we run it on a detached thread and
/// bound the wait — the serial command queue is never wedged. A live loopback write returns in
/// milliseconds, so a timeout means the session is really gone (not merely new-connects-refused).
/// The timeout is generous ON PURPOSE. A healthy loopback write returns in milliseconds, but while iOS
/// rebuilds the interfaces (exactly what turning Airplane Mode off does) an equally healthy write can sit
/// in TCP retransmit backoff for several seconds. The old 2s bound misread that as "session dead" and
/// discarded a channel that was still perfectly good — which is why the spoof stopped surviving
/// airplane-off. We only need the bound so the serial command queue can't wedge; it is not a liveness
/// test. `onLateOutcome(success:)` fires if the write lands AFTER we stopped waiting — that outcome, not
/// the timeout, is what decides whether the session is really gone.
private func _boundedSet(_ sim: OpaquePointer, _ latitude: Double, _ longitude: Double,
                         timeoutSeconds: Double = 8,
                         onLateOutcome: ((Bool) -> Void)? = nil) -> BoundedSetResult {
    let sem = DispatchSemaphore(value: 0)
    let handoff = BoundedSetHandoff()
    var setError: UnsafeMutablePointer<IdeviceFfiError>?
    Thread.detachNewThread {
        setError = location_simulation_set(sim, latitude, longitude)
        let callerGaveUp = handoff.markThreadFinished()
        sem.signal()
        if callerGaveUp {
            // Nobody is waiting on us any more, so we own the result. Report whether the write actually
            // landed; the caller kept the session alive pending exactly this answer.
            let ok = setError == nil
            if let err = setError { idevice_error_free(err); setError = nil }
            onLateOutcome?(ok)
        }
    }
    if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        // ── THE BOUNDARY RACE, AND WHAT IT ACTUALLY MEANS ────────────────────────────────────────
        // `markCallerGaveUp()` returning TRUE means the detached thread had ALREADY finished when we
        // stopped waiting (that is the arbiter's whole contract — see `BoundedSetHandoff`). So this
        // is not a stall at all: the write is done, its result is sitting in `setError`, and the
        // lock inside the handoff is the happens-before edge that makes reading it safe.
        //
        // The old code reported that as `.timedOut` anyway and never freed the error. Both were
        // wrong in the same direction: it leaked one `IdeviceFfiError` per occurrence, and it made a
        // completed write look like a stall, which downstream records as a SOFT success — a green
        // signal for something that had a real, knowable answer. Report the real one.
        //
        // ⚠️ `onLateOutcome` IS DELIBERATELY NOT CALLED HERE. It is the LATE path's handler — it
        // clears the in-flight latch and, on a failure, enqueues a `cleanup()` on the serial location
        // queue. Firing it while we are still ON that queue and about to return `.failed` would queue
        // a free that lands AFTER the caller's own rebuild, tearing down the session it just built.
        // Returning the real result instead hands the outcome to the caller's own `.ok`/`.failed`
        // arms, which already do the right thing synchronously.
        if handoff.markCallerGaveUp() {
            let landed = setError == nil
            if let err = setError { idevice_error_free(err); setError = nil }
            return landed ? .ok : .failed
        }
        return .timedOut
    }
    if let err = setError { idevice_error_free(err); return .failed }
    return .ok
}

/// The same bound, around `location_simulation_clear`. A literal mirror of `_boundedSet` on purpose —
/// same semaphore, same `BoundedSetHandoff` arbiter, same detached thread, same "on timeout you MUST
/// NOT free the handle" contract — because the constraint is identical: the FFI has no timeout of its
/// own and a blocking call made directly on `LocationSimulationCommandQueue` would wedge the serial
/// queue that Stop and Panic ride on.
///
/// THE BOUND IS THE SAME 8 s, AND THAT IS NOT A COPY-PASTE. The reason `_boundedSet` is generous — a
/// healthy loopback write can sit in TCP retransmit backoff for seconds while iOS rebuilds interfaces,
/// which is exactly what Airplane-Mode-off does — applies to a clear word for word. Nothing the user
/// can see waits on this: the local half of Stop is synchronous and has already completed by the time
/// this runs (see `MapSelectionView.clear()` and `SimulationSession.stopAll()`).
///
/// `onLateOutcome(landed:)` fires if the clear comes back after we stopped waiting. It is for the LOG
/// ONLY — by then the caller has dropped its references without freeing them, so this closure owns
/// nothing and must free nothing.
private func _boundedClear(_ sim: OpaquePointer,
                           timeoutSeconds: Double = 8,
                           onLateOutcome: ((Bool) -> Void)? = nil) -> BoundedSetResult {
    let sem = DispatchSemaphore(value: 0)
    let handoff = BoundedSetHandoff()
    var clearError: UnsafeMutablePointer<IdeviceFfiError>?
    Thread.detachNewThread {
        clearError = location_simulation_clear(sim)
        let callerGaveUp = handoff.markThreadFinished()
        sem.signal()
        if callerGaveUp {
            let ok = clearError == nil
            if let err = clearError { idevice_error_free(err); clearError = nil }
            onLateOutcome?(ok)
        }
    }
    if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        // Same boundary race as `_boundedSet`, resolved the same way: `markCallerGaveUp()` returning
        // true means the thread is KNOWN FINISHED, so the clear's real answer is in hand, freeing the
        // error object is safe, and the handle is safe to free too. Reporting `.timedOut` there cost
        // us a leaked `IdeviceFfiError` AND a leaked session (the `.timedOut` arm drops the adapter,
        // the RSD handshake and the simulation handle without freeing them) for a stop that had
        // actually completed.
        if handoff.markCallerGaveUp() {
            let landed = clearError == nil
            if let err = clearError { idevice_error_free(err); clearError = nil }
            return landed ? .ok : .failed
        }
        return .timedOut
    }
    if let err = clearError { idevice_error_free(err); return .failed }
    return .ok
}

private func _simulate_location(_ deviceIP: String, _ latitude: Double, _ longitude: Double, _ pairingFile: String) -> Int32 {
    // ── A SLOW WRITE IS NOT A DEAD SESSION ───────────────────────────────────────────────────────
    // Build 52 — the last version where a spoof survived Airplane Mode being turned off — called
    // location_simulation_set() with NO deadline at all. During the cellular re-attach that write simply
    // BLOCKS (TCP retransmitting while iOS rebuilds its interfaces) and then COMPLETES a few seconds
    // later. Same session, coordinate delivered, spoof intact. That is the entire reason it worked.
    //
    // Every version since killed it on a stopwatch: build 124 at 2s, and my own "restore" at 8s. Both
    // discarded a perfectly healthy session mid-stall, and the rebuild that followed then had to open a
    // NEW connection at exactly the moment the loopback is refusing them — which is the
    // `connect: Connection refused (os error 61)` in the device log. The timeout is the cause; the
    // refused rebuild is only its consequence.
    //
    // So: the write runs on a detached thread (build 84's real concern was that a blocked FFI call wedges
    // the serial command queue and Stop/Panic can never run — that stays fixed, the queue is never
    // blocked). But a write still in flight NO LONGER means failure. We keep the session, report a soft
    // status, and let the hold loop try again. ONLY a write that comes back an actual ERROR tears the
    // session down and rebuilds.
    if LocationSimulationState.writeInFlight {
        // Still waiting on the previous write. Do not start a second concurrent write on the same handle
        // (the FFI is not safe for that) and do not tear anything down.
        SpoofTrace.tick("  write still in flight — holding session, no rebuild")
        // SOFT. We are reporting ok without a landing (see TunnelInjectStatus.markNextSuccessSoft).
        TunnelInjectStatus.markNextSuccessSoft()
        return LocationSimulationStatus.ok
    }
    if let sim = LocationSimulationState.locationSimulation {
        LocationSimulationState.writeInFlight = true
        let result = _boundedSet(sim, latitude, longitude, onLateOutcome: { landed in
            SpoofTrace.log("  LATE write outcome: \(landed ? "LANDED — session alive, spoof held" : "ERROR — session dead")")
            LocationSimulationState.writeInFlight = false
            // ══ THE STOP THE USER ALREADY ASKED FOR, DELIVERED AT THE FIRST MOMENT IT CAN BE. ══
            //
            // A Stop that arrived while this write was outstanding could not be issued then — the FFI
            // is not safe to call twice on one handle — so it was recorded as owed. THIS is the
            // instant the handle becomes free again, and it is the only one: nothing else in the
            // process is watching for it. Read-and-clear so a concurrent Stop cannot double-issue.
            let owed = LocationSimulationState.takeClearOwed()
            if !landed {
                // A genuine error (not a stall). The thread has returned so freeing is safe; the next
                // inject rebuilds.
                LocationSimulationCommandQueue.shared.async {
                    LocationSimulationState.cleanup(reason: .lateWriteFailed)
                    if owed {
                        // The stop is now undeliverable: the session it would have ridden is gone and
                        // on cellular no replacement can be born. This is exactly the case the
                        // failed-stop report exists for, and it is the ONE path where the device is
                        // very likely still holding our fix with nobody having been told.
                        SpoofTrace.log("STOP: the owed clear cannot be delivered — the late write failed")
                        if NetworkReachability.isOnCellularSnapshot {
                            SpoofLossReporter.noteStopDidNotClear(
                                LocationSimulationState.TeardownReason.lateWriteFailed.rawValue)
                        }
                    }
                    // TELL SOMEBODY. This is the single most likely honest death for a backgrounded
                    // user, and until now it freed the session in silence: the hold loop's next tick
                    // rebuilt or failed, and nothing anywhere raised a word. See SpoofLossReporter.
                    SpoofLossReporter.noteSessionLost(LocationSimulationState.TeardownReason.lateWriteFailed.rawValue)
                }
            } else if owed {
                // The write landed, so the session is alive and the handle is ours again. Send the
                // stop. Enqueued on the serial location queue rather than run here, because we are on
                // a detached FFI thread and every other FFI call in this file is made from that queue.
                LocationSimulationCommandQueue.shared.async {
                    SpoofTrace.log("STOP: the write came back — delivering the clear that was owed")
                    let code = clear_simulated_location()
                    LogManager.shared.addInfoLog("[spoof] deferred stop delivered: clear returned \(code)")
                    LocationSessionActivity.noteSessionClosed()
                }
            }
        })
        SpoofTrace.tick("  cached-handle set -> \(result)")
        switch result {
        case .ok:
            LocationSimulationState.writeInFlight = false
            // A landed write means this session is the one the device is acting on, so any earlier
            // stop we never got confirmation for is moot: whatever fix it failed to clear has just
            // been overwritten, and a Stop from here will ride THIS session. Clearing the flag keeps
            // the "we owe you an unconfirmed stop" state from outliving the thing it described.
            LocationSimulationState.clearUnconfirmed = false
            DeviceReadiness.markSimulationSucceeded()
            return LocationSimulationStatus.ok
        case .failed:
            LocationSimulationState.writeInFlight = false
            LocationSimulationState.cleanup(reason: .writeFailed)   // real error → fall through and rebuild
        case .timedOut:
            // STILL RUNNING. Keep the session — this is the case build 52 survived and every later
            // version broke. Report ok so nothing upstream treats a stall as a lost spoof.
            SpoofTrace.log("  write still running — KEEPING session (build-52 behaviour)")
            // SOFT, for the same reason as the in-flight branch above: ok, but nothing has landed.
            TunnelInjectStatus.markNextSuccessSoft()
            return LocationSimulationStatus.ok
        }
    }

    SpoofTrace.log("  REBUILDING session (tunnel_create_rppairing -> remote_server -> location_simulation_new)")

    // Candidate endpoints, in dial order. Default (IPv6 experiment off) this is EXACTLY one element —
    // the caller's IPv4 address — so the loop below runs the identical single attempt, in the same
    // order, with the same cleanup and the same return codes as before. With the experiment on, IPv6 is
    // tried first and IPv4 is still tried after it, so the working path is never taken away.
    //
    // `deviceIP` (the caller's argument) stays the IPv4 candidate rather than being replaced, so a user
    // who moved the tunnel onto their Wi-Fi subnet on iOS 26.4+ keeps that address.
    let dialTargets = DeviceConnectionContext.dialTargets(ipv4Address: deviceIP)

    // Parsed BEFORE the pairing file is read, so an unusable address still returns `invalidIP` at the
    // same point in the sequence it always did.
    let endpoints = dialTargets.compactMap { target -> (DeviceConnectionContext.DialTarget, DeviceConnectionContext.SocketAddress)? in
        guard let endpoint = DeviceConnectionContext.makeSocketAddress(target.address) else { return nil }
        return (target, endpoint)
    }
    guard !endpoints.isEmpty else {
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

    // One pass per candidate endpoint. `pairing_file` is BORROWED by the FFI, not consumed (see
    // idevice.h), so the same handle is safe to reuse across attempts.
    var established = false
    var failureStatus = LocationSimulationStatus.providerCreate

    for entry in endpoints {
        let (target, endpoint) = entry
        let attemptLabel = endpoints.count > 1 ? " [\(target.familyLabel) \(target.address)]" : ""

        // ── THE GATE THAT KEEPS THE SERIAL QUEUE ALIVE ───────────────────────────────────────────
        // `tunnel_create_rppairing` has NO timeout. Against a route that BLACKHOLES the SYN — which
        // is exactly what a half-dead LocalDevVPN or a tunnel that was just auto-disconnected looks
        // like — it sits in TCP retransmit for over a minute, wedging this serial queue and with it
        // every Stop and Panic that has to ride it. So probe first, always, and fail fast instead.
        //
        // ⚠️ THIS USED TO BE GUARDED ON `index < endpoints.count - 1`, i.e. it ran only for a
        // candidate that still had a fallback behind it. With the IPv6 experiment off there is
        // exactly ONE candidate, so `0 < 0` was false and the probe never ran at all — the single
        // shipping path, taken by every LocalDevVPN user, dialled a dead tunnel completely unbounded.
        // That is the wedge behind "Simulate goes grey and Stop does nothing". The bound still comes
        // from the target itself so the speculative v6 leg keeps its tighter one (see
        // DialTarget.probeTimeoutSeconds); the cost on a HEALTHY tunnel is one loopback TCP connect
        // that completes in microseconds.
        //
        // ── DIAL LEGIBILITY (the whole reason this reads the full probe result, not a Bool) ───────
        // That bounded connect()'s errno is the SINGLE decisive signal for a cellular device test:
        //   • NO ROUTE / errno 51 ENETUNREACH → the v6 route still isn't installed — routing is still
        //     broken, the experiment did NOT move the needle.
        //   • REFUSED / errno 61 ECONNREFUSED → the route works and the port refused the SYN — a
        //     DIFFERENT and more interesting result (we now reach the device; the refusal is pairing
        //     policy, the same gate as the airplane-OFF errno-61).
        //   • CONNECTED → the handshake port answered; the real pairing dial (below) follows and, if it
        //     also succeeds, the spoof holds.
        // `_isSimEndpointReachable` throws that errno onto a SEPARATE, 30 s-throttled line. Here we call
        // `EndpointProbe.probe` directly so the full result is in hand: the throttled health-style line
        // is still recorded for the chip, and — ONLY when the opt-in added a second candidate, so the
        // shipping single-IPv4 path logs byte-for-byte as before — one extra un-throttled line ties the
        // family + address + outcome + errno to the exact attempt that produced them. The gate itself is
        // unchanged: dial iff the handshake port answered.
        let probe = EndpointProbe.probe(target.address, timeoutSeconds: target.probeTimeoutSeconds)
        EndpointProbeLog.record(probe, context: "sim endpoint:")
        if endpoints.count > 1 {
            let errnoSuffix = probe.errnoValue != 0 ? " errno \(probe.errnoValue) \(probe.errnoName)" : ""
            SpoofTrace.log("  dial attempt \(target.familyLabel) \(probe.destination) → \(probe.outcome.label)\(errnoSuffix) after \(probe.elapsedMilliseconds) ms")
        }
        if !probe.isReachable {
            SpoofTrace.log("  rebuild: endpoint unreachable\(attemptLabel) — no dial attempted")
            // Distinct from `providerCreate`: nothing was dialled, and the reason is one the UI can
            // state plainly instead of printing a number. A later candidate that gets FURTHER than
            // this overwrites it with its own, more specific failure.
            failureStatus = LocationSimulationStatus.tunnelUnreachable
            continue
        }

        let providerError = endpoint.withSockaddr { pointer, length in
            tunnel_create_rppairing(
                pointer,
                length,
                "StikDebugLocation",
                pairingHandle,
                nil,
                nil,
                &LocationSimulationState.adapter,
                &LocationSimulationState.handshake
            )
        }

        if let providerError {
            SpoofTrace.log("  rebuild FAILED at tunnel_create_rppairing\(attemptLabel): " + _ffiDetail(providerError))
            idevice_error_free(providerError)
            SpoofTrace.log("  rebuild: tunnel_create_rppairing FAILED")
            LocationSimulationState.cleanup(reason: .rebuildFailed)
            failureStatus = LocationSimulationStatus.providerCreate
            continue
        }

        // The SECOND hop is a separate listener and a separate gamble: after pairing, the FFI asks the
        // device to open a fresh TCP listener and dials it, inheriting the family of the first dial. So
        // a failure here (rather than above) means the dynamically created listener, not remotepairingd,
        // is the one that isn't answering on this family — worth being able to tell apart in the log.
        let remoteServerError = remote_server_connect_rsd(
            LocationSimulationState.adapter,
            LocationSimulationState.handshake,
            &LocationSimulationState.remoteServer
        )
        if let remoteServerError {
            SpoofTrace.log("  rebuild FAILED at remote_server_connect_rsd\(attemptLabel): " + _ffiDetail(remoteServerError))
            idevice_error_free(remoteServerError)
            SpoofTrace.log("  rebuild: remote_server_connect_rsd FAILED")
            LocationSimulationState.cleanup(reason: .rebuildFailed)
            failureStatus = LocationSimulationStatus.remoteServer
            continue
        }

        let locationSimulationError = location_simulation_new(
            LocationSimulationState.remoteServer,
            &LocationSimulationState.locationSimulation
        )
        if let locationSimulationError {
            SpoofTrace.log("  rebuild FAILED at location_simulation_new\(attemptLabel): " + _ffiDetail(locationSimulationError))
            idevice_error_free(locationSimulationError)
            SpoofTrace.log("  rebuild: location_simulation_new FAILED")
            LocationSimulationState.cleanup(reason: .rebuildFailed)
            failureStatus = LocationSimulationStatus.locationSimulation
            continue
        }

        LocationSimulationState.remoteServer = nil
        // The one point where the carrying family is known for certain. Everything that later has to
        // act on the LIVE session — the clear path's reachability gate, the health chip — reads this
        // instead of re-deriving it from a preference that may since have changed.
        LocationSimulationState.liveTarget = target
        if endpoints.count > 1 {
            SpoofTrace.log("  rebuild: session established over \(target.familyLabel) (\(target.address))")
        }
        established = true
        break
    }

    guard established else {
        return failureStatus
    }

    let locationSetError = location_simulation_set(
        LocationSimulationState.locationSimulation,
        latitude,
        longitude
    )
    if let locationSetError {
        SpoofTrace.log("  rebuild FAILED at location_simulation_set(first): " + _ffiDetail(locationSetError))
        idevice_error_free(locationSetError)
        SpoofTrace.log("  rebuild: first location_simulation_set FAILED")
        LocationSimulationState.cleanup(reason: .rebuildFailed)
        return LocationSimulationStatus.locationSet
    }

    SpoofTrace.log("  rebuild OK — NEW session established")
    // Same reasoning as the cached-handle `.ok` arm: a live session with a landed fix supersedes any
    // stop we never got confirmation for.
    LocationSimulationState.clearUnconfirmed = false
    DeviceReadiness.markSimulationSucceeded()
    return LocationSimulationStatus.ok
}

func clear_simulated_location() -> Int32 {
    // In gs-loc mode there's no dev-tunnel simulation to clear — Stop means "tell the proxy to pass the
    // real location through." Fire the reset and report success (the dev tunnel isn't in play).
    if GslocMode.enabled {
        GslocMode.reset()
        // Drop any dev-tunnel handle left over from switching modes mid-spoof, so it can't linger in
        // our state. cleanup() only frees the local handle (no un-timeout-able device call), so it's
        // safe with LocalDevVPN off. (The device's own DVT fix can only be cleared with the tunnel up
        // — so the guidance is to Stop before switching modes.)
        if LocationSimulationState.locationSimulation != nil {
            LocationSimulationState.cleanup(reason: .gslocModeSwitch)
        }
        return LocationSimulationStatus.ok
    }
    guard let locationSimulation = LocationSimulationState.locationSimulation else {
        // ⚠️ TWO DIFFERENT STATES REACH THIS LINE AND THEY MUST NOT SHARE AN ANSWER.
        //
        // The ordinary one: nothing is open, because nothing is running or a previous Stop completed.
        // `ok` is the truthful answer to "is anything of ours still simulating", and it is why this
        // stopped returning `locationClear` (12) — a second Stop tap, or a Stop with nothing running,
        // used to pop "Clear Failed (error 12)" at a user who had done nothing wrong.
        //
        // The other one: a clear WAS issued, never came back inside its bound, and the handle had to
        // be DROPPED rather than freed (the detached FFI thread may still be dereferencing it). We
        // have no session and no confirmation that the device took the stop. Answering `ok` there is
        // a fabricated success — the user taps Stop a second time, sees a clean silent stop, and
        // walks away while the device may still be reporting the simulated location. Say the same
        // thing we said the first time instead, so the recovery the UI offers stays on screen.
        if LocationSimulationState.clearUnconfirmed {
            SpoofTrace.log("STOP: no session handle, and the last clear was never confirmed — reporting stalled, not ok")
            return LocationSimulationStatus.clearStalled
        }
        return LocationSimulationStatus.ok
    }

    // ══ WHY THIS NO LONGER ASKS A PROBE FOR PERMISSION TO STOP. DO NOT PUT THE GATE BACK. ══
    //
    // Until build 151 this function opened with a bounded TCP probe to the pairing listener and, if
    // the probe failed, freed the local handle and returned WITHOUT ever sending the stop. The
    // comment that stood here argued that was safe on two grounds. One of them was wrong and one of
    // them is still true, so read both before touching this.
    //
    // WRONG: "this is the CLOSING path, so the session is ending either way". On mobile data that
    // probe is FALSE BY CONSTRUCTION and has nothing to do with the session's health.
    // `remotepairingdeviced` applies `SO_RESTRICT_DENY_CELLULAR` to its own listeners and XNU's port
    // lookup skips restricted sockets, so a new connect draws an instant RST — while the session we
    // ALREADY HOLD keeps working indefinitely, because the wall is on connection BIRTH only. That is
    // the whole premise of Cellular Mode. So the guaranteed-false probe was the sole decider on every
    // cellular Stop: Wander freed the handle, reported a clean stop, and the device — which was never
    // told anything — carried on reporting the fake location. That is the owner-reported bug this
    // change fixes, and restoring the gate re-creates it exactly.
    //
    // ALSO WRONG, AND THE REASON THE ABOVE WENT UNNOTICED: the old comment asserted "the DVT location
    // session is connection-scoped: with the transport gone the device is not holding our fix any
    // more". Nothing in this codebase has ever measured that, and the protocol argues against it —
    // `stopLocationSimulation` is an explicit RPC that the ancestors of this library (libimobiledevice
    // `idevicesetlocation reset`, pymobiledevice3 `simulate-location clear`) issue from a brand-new
    // connection, which is not a verb a self-reverting service would need. Treat "closing the channel
    // clears the fix" as UNPROVEN and never as a reason to skip the stop.
    //
    // STILL TRUE, AND STILL THE BINDING CONSTRAINT: `location_simulation_clear` has NO timeout of its
    // own. Called inline on `LocationSimulationCommandQueue` against a genuinely dead tunnel it blocks
    // in TCP retransmit for over a minute and wedges the one serial queue that Stop and Panic ride on
    // — a control that ends something must never be the thing that stops working. That constraint is
    // now met STRUCTURALLY rather than by refusing to call at all: `_boundedClear` runs the FFI on a
    // detached thread and bounds the wait, exactly as `_boundedSet` does for the inject path. The
    // queue is occupied for at most the bound, never forever.
    //
    // So the order is the same one `_simulate_location` uses: act on the CACHED HANDLE first, and let
    // the real outcome — not a probe's opinion — decide what happens to the session.

    // ══ ONE WRITER AT A TIME — BUT WAITING IS NOT THE SAME AS GIVING UP. DO NOT SHORTEN THIS. ══
    //
    // The FFI is not safe to call concurrently on a single handle, and `_simulate_location` may have
    // left a write out on a detached thread (`.timedOut` keeps the session on purpose — that is the
    // build-52 behaviour airplane-off survival depends on). So a clear genuinely cannot be issued at
    // this instant.
    //
    // WHAT THE FIRST VERSION OF THIS DID, AND WHY IT WAS THE ORIGINAL BUG WEARING A NEW HAT: it
    // dropped the references and returned `clearStalled`. That reads as a stop that went out, and
    // NOTHING went out. Worse, dropping the handle meant no LATER Stop could send one either — the
    // guard above would find no session and report a clean success — so a single stalled hold write
    // permanently converted every Stop into a lie. The window is not rare: it is open for as long as
    // a wedged write takes to return, and a wedged write is the documented common case on cellular
    // (TCP retransmit while iOS rebuilds interfaces).
    //
    // WHAT IT DOES NOW, in the order the constraints allow:
    //   1. WAIT, bounded, for the write to come back. Nothing user-visible is waiting on us — Stop's
    //      local half is synchronous and has already completed (see `MapSelectionView.clear()` and
    //      `SimulationSession.stopAll()`) — and the bound is the same 8 s `_boundedClear` may occupy
    //      this queue for anyway, so the serial queue's worst case is unchanged in kind.
    //   2. If it comes back, fall through and CLEAR over the same live handle. This is the common
    //      outcome and it is a real, delivered stop.
    //   3. If it does not, KEEP the session (the thread still owns those pointers) and record the
    //      stop as OWED. `_boundedSet`'s late-outcome callback issues it the moment the write lands.
    //      Nothing is dropped, so a later Stop still has a handle to send over as well.
    if LocationSimulationState.writeInFlight {
        SpoofTrace.log("STOP: a write is still in flight — waiting for the handle before clearing")
        let deadline = Date().addingTimeInterval(8)
        while LocationSimulationState.writeInFlight, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if LocationSimulationState.writeInFlight {
            SpoofTrace.log("STOP: the write is still out — the clear is OWED and will be sent when it returns")
            LocationSimulationState.clearOwed = true
            // Deliberately NOT `noteTeardown` and NOT `dropReferencesUnsafeToFree`: nothing has been
            // torn down, and the session is exactly what the owed clear needs.
            return LocationSimulationStatus.clearDeferred
        }
        SpoofTrace.log("STOP: the write came back — clearing over the same session")
    }

    let result = _boundedClear(locationSimulation, onLateOutcome: { landed in
        // LOG ONLY. By the time this can run the caller has already dropped its references without
        // freeing them, so this closure owns nothing — freeing here would be the use-after-free the
        // drop exists to avoid.
        SpoofTrace.log("  LATE clear outcome: \(landed ? "LANDED — the device took the stop" : "ERRORED")")
    })
    SpoofTrace.log("STOP: bounded clear -> \(result)")

    switch result {
    case .ok:
        // A delivered stop settles any earlier one we never got confirmation for: whatever fix that
        // one failed to clear, the device has now been told to stop simulating. Leaving the flag set
        // would make the NEXT Stop-with-nothing-running report `clearStalled` at a user whose device
        // is demonstrably clear.
        LocationSimulationState.clearUnconfirmed = false
        LocationSimulationState.cleanup(reason: .cleared)
        return LocationSimulationStatus.ok

    case .failed:
        // ══ AN ERRORED CLEAR IS NOT PROOF THE SESSION IS DEAD — SO DON'T THROW IT AWAY FIRST. ══
        //
        // The detached thread has returned, so freeing WOULD be safe. It was also, until now, what we
        // did: `cleanup(reason: .clearFailed)` released the adapter, the RSD handshake and the
        // simulation handle on the very first error. That handle was irreplaceable. On mobile data a
        // replacement session cannot be BORN at all (`SO_RESTRICT_DENY_CELLULAR` on the pairing
        // listener), so freeing it converted "the device refused one clear" into "nothing in this
        // process can ever ask again" — and the user's obvious next move, tapping Stop a second time,
        // then found no handle and got a fabricated clean stop.
        //
        // `location_simulation_clear` returning an FFI error can just as easily be a transient RPC
        // error over a live channel. So the FIRST failure keeps the session and reports honestly; a
        // second Stop re-issues the clear over the same handle for free. Only when the retry fails
        // too do we conclude the session really is gone and free it, which is also what stops a
        // genuinely dead handle from being retried forever.
        //
        // `clearUnconfirmed` is armed either way: whatever happens to our local handle, the DEVICE was
        // never confirmed to have taken the stop, and a later Stop with no handle must not answer
        // `ok` to that.
        LocationSimulationState.clearUnconfirmed = true
        LocationSimulationState.noteFailedClear()
        if LocationSimulationState.failedClearCount >= 2 {
            SpoofTrace.log("STOP: second failed clear — releasing the session")
            LocationSimulationState.cleanup(reason: .clearFailed)
        } else {
            // Deliberately NOT `noteTeardown`: nothing was torn down, and that record is read as
            // "this is how the last session died".
            SpoofTrace.log("STOP: the device refused the clear — KEEPING the session so a second Stop can retry")
        }
        if NetworkReachability.isOnCellularSnapshot {
            SpoofLossReporter.noteStopDidNotClear(
                LocationSimulationState.TeardownReason.clearFailed.rawValue)
        }
        return LocationSimulationStatus.locationClear

    case .timedOut:
        // THE DETACHED THREAD MAY STILL BE DEREFERENCING THIS HANDLE, so it must not be freed. Drop
        // the references instead: that leaks exactly one dead session (a tunnel adapter plus an RSD
        // handshake) and the alternative is a use-after-free crash. Same trade, same reason, as
        // `_simulate_location`'s stalled-write path.
        //
        // The probe survives ONLY here, and only as after-the-fact attribution for the log — it
        // decides nothing. "The stop didn't come back AND the endpoint is refusing new connections"
        // reads very differently from "the stop didn't come back on a tunnel that answers".
        let probeAddress = LocationSimulationState.liveTarget?.address
            ?? DeviceConnectionContext.targetIPAddress
        let alsoUnreachable = !_isSimEndpointReachable(probeAddress, timeoutSeconds: 1)
        SpoofTrace.log("STOP: clear did not come back in time (endpoint \(alsoUnreachable ? "also unreachable" : "still answering"))")
        // ⚠️ ARM THIS BEFORE DROPPING THE HANDLE, AND NEVER REMOVE IT. Dropping the references is
        // forced (the detached FFI thread may still be dereferencing them), and it leaves this process
        // with no session AND no confirmation that the device took the stop. The guard at the top of
        // this function cannot tell that state from the ordinary "nothing is running", and it answers
        // `ok` to the ordinary one — so without this flag a second Stop reported a clean, silent,
        // fabricated success over a device that may still be simulating. The flag exists for exactly
        // this line; it was declared and read but never set, which made the guard's whole
        // two-states-one-answer defence dead code.
        LocationSimulationState.clearUnconfirmed = true
        LocationSimulationState.noteTeardown(.clearStalled)
        LocationSimulationState.dropReferencesUnsafeToFree()
        return LocationSimulationStatus.clearStalled
    }
}
