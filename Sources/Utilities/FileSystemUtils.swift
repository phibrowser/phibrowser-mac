// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
@objc final class FileSystemUtils: NSObject {
    static let defaultBundleId = "com.phibrowser.Mac"
    static let groupId = "group.com.phibrowser.shared"
    static let teamId = "87DQ3HMK5G"
    static let bundleId = Bundle.main.infoDictionary?[kCFBundleIdentifierKey as String] as? String ?? defaultBundleId
    @objc static func applicationSupportDirctory() -> String {
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
