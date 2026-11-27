// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation
@objc final class FileSystemUtils: NSObject {
    static let defaultBundleId = "com.phibrowser.Mac"
    static let groupId = "group.com.phibrowser.shared"
    static let teamId = "87DQ3HMK5G"
    static let bundleId = Bundle.main.infoDictionary?[kCFBundleIdentifierKey as String] as? String ?? defaultBundleId

    static func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Resolve before logging, account binding, or Chromium startup. Both sides
    /// must use the same root: a temporary Chromium profile paired with the real
    /// native account overwrites that account's Space/window restore mapping.
    @objc static let launchUserDataDirectory: String? = resolveLaunchUserDataDirectory(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment,
        temporaryDirectory: NSTemporaryDirectory(),
        launchIdentifier: UUID().uuidString)

    static func resolveLaunchUserDataDirectory(
        arguments: [String],
        environment: [String: String],
        temporaryDirectory: String,
        launchIdentifier: String
    ) -> String? {
        var override: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { break }
            if argument.hasPrefix("--user-data-dir=") {
                override = String(argument.dropFirst("--user-data-dir=".count))
            } else if argument == "--user-data-dir" {
                override = ""
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") {
                    index += 1
                    override = arguments[index]
                }
            }
            index += 1
        }
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL.path
        }
        let isTestLaunch = arguments.contains("-uitest")
            || ["XCTestConfigurationFilePath", "XCTestBundlePath"].contains {
                !(environment[$0] ?? "").isEmpty
            }
        guard isTestLaunch else { return nil }
        return URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent("PhiTests-\(launchIdentifier)", isDirectory: true).path
    }

    @objc static func applicationSupportDirctory() -> String {
        if let launchUserDataDirectory { return launchUserDataDirectory }
        let paths = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true)
        let cacheDirectory = paths[0]
        let bundleId = bundleId
        
        return ((cacheDirectory as NSString)
            .appendingPathComponent(bundleId) as NSString) as String
    }
    
    static func cacheDirctory() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let cacheDirectory = paths[0]
        let bundleId = bundleId
        
        return ((cacheDirectory as NSString)
            .appendingPathComponent(bundleId) as NSString) as String
    }
    
    static func plistPath() -> String {
        let paths = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)
        let prefDirectory = (paths[0] as NSString).appendingPathComponent("Preferences")
        let bundleId = bundleId
        return prefDirectory.appending("/\(bundleId).plist")
    }
    
    static func phiBrowserDataDirectory() -> String {
        return (applicationSupportDirctory() as NSString)
            .appendingPathComponent("Phi")
    }
    
    static func sharedContainerURL() -> URL? {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) {
            return url
        }
        return nil
    }

    static func sharedContainerApplicationSupportURL(createIfNeeded: Bool = true) -> URL? {
        guard let containerURL = sharedContainerURL() else { return nil }
        let appSupportURL = containerURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        if createIfNeeded {
            do {
                try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            } catch {
                return nil
            }
        }
        return appSupportURL
    }
}
