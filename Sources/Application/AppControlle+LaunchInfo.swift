// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit

extension AppController {
    /// Public read-only launch context exposed to the rest of the app.
    struct LaunchContext {
        let currentVersion: String
        let currentBuild: String
        let previousVersion: String?
        let previousBuild: String?
        let previousLaunchDate: Date?
        let firstLaunchDate: Date
        let launchCount: Int
        let isFirstLaunchEver: Bool
        let isFirstLaunchForVersion: Bool
        let isFirstLaunchForBuild: Bool
        let didUpgrade: Bool
        let didDowngrade: Bool
    }
    
    static private(set) var launchContext: LaunchContext?
    
    private static let launchIOQueue = DispatchQueue(label: "cc.phi.app.launchIO", qos: .utility)
    
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        return v1.compare(v2, options: [.numeric, .caseInsensitive])
    }
    
    func recordLaunchVersion() {
        let info = Bundle.main.infoDictionary ?? [:]
        let currentVersion = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let currentBuild = (info["CFBundleVersion"] as? String) ?? "0"
        
        Self.launchIOQueue.async { [currentVersion, currentBuild] in
            let fm = FileManager.default
            let baseDir = FileSystemUtils.phiBrowserDataDirectory()
            let dirURL = URL(fileURLWithPath: baseDir, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent("launch_info.json", conformingTo: .json)
            
            // Ensure directory exists
            do { try fm.createDirectory(at: dirURL, withIntermediateDirectories: true) } catch { /* ignore */ }
            
            struct LaunchRecord: Codable {
                var lastVersion: String?
                var lastBuild: String?
                var lastLaunchDate: Date?
                var firstLaunchDate: Date?
                var launchCount: Int
                var perVersionCount: [String: Int]
            }
            
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            
            var record: LaunchRecord = {
                guard let data = try? Data(contentsOf: fileURL), let decoded = try? decoder.decode(LaunchRecord.self, from: data) else {
                    return LaunchRecord(lastVersion: nil, lastBuild: nil, lastLaunchDate: nil, firstLaunchDate: nil, launchCount: 0, perVersionCount: [:])
                }
                return decoded
            }()
            
            let previousVersion = record.lastVersion
            let previousBuild = record.lastBuild
            let previousLaunchDate = record.lastLaunchDate
            let now = Date()
            let firstLaunchDate = record.firstLaunchDate ?? now
            
            record.launchCount += 1
            var perVersionCount = record.perVersionCount
            perVersionCount[currentVersion] = (perVersionCount[currentVersion] ?? 0) + 1
            record.perVersionCount = perVersionCount
            
            record.lastVersion = currentVersion
            record.lastBuild = currentBuild
            record.lastLaunchDate = now
            record.firstLaunchDate = firstLaunchDate
            
            let isFirstLaunchEver = (previousVersion == nil && previousBuild == nil)
            let isFirstLaunchForVersion = (previousVersion != currentVersion)
            let isFirstLaunchForBuild = (previousBuild != currentBuild)
            
            var didUpgrade = false
            var didDowngrade = false
            if let pv = previousVersion, pv != currentVersion {
                let cmp = self.compareVersions(currentVersion, pv)
                didUpgrade = (cmp == .orderedDescending)
                didDowngrade = (cmp == .orderedAscending)
            } else if let pb = previousBuild, pb != currentBuild, let prev = Int(pb), let curr = Int(currentBuild) {
                didUpgrade = curr > prev
                didDowngrade = curr < prev
            }
            
            if let data = try? encoder.encode(record) {
                _ = try? data.write(to: fileURL, options: .atomic)
            }
            
            let ctx = LaunchContext(
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                previousVersion: previousVersion,
                previousBuild: previousBuild,
                previousLaunchDate: previousLaunchDate,
                firstLaunchDate: firstLaunchDate,
                launchCount: record.launchCount,
                isFirstLaunchEver: isFirstLaunchEver,
                isFirstLaunchForVersion: isFirstLaunchForVersion,
                isFirstLaunchForBuild: isFirstLaunchForBuild,
                didUpgrade: didUpgrade,
                didDowngrade: didDowngrade
            )
            
            DispatchQueue.main.async {
                Self.launchContext = ctx
                AppLogInfo("LaunchContext => version=\(currentVersion) build=\(currentBuild) prevVersion=\(previousVersion ?? "-") prevBuild=\(previousBuild ?? "-") firstEver=\(isFirstLaunchEver) firstForVersion=\(isFirstLaunchForVersion) firstForBuild=\(isFirstLaunchForBuild) upgraded=\(didUpgrade) downgraded=\(didDowngrade) launchCount=\(record.launchCount) perVersionCount=\(perVersionCount[currentVersion] ?? 0)")
            }
        }
    }
    
    // MARK: - Default Browser Detection
    
    /// Information about the current default browser.
    struct DefaultBrowserInfo {
        /// Display name of the default browser.
        let name: String
        /// Bundle identifier of the default browser.
        let bundleIdentifier: String?
        /// Whether Phi is currently the default browser.
        let isPhiDefault: Bool
    }
    
    /// Returns information about the current default browser for HTTP/HTTPS URLs.
    static func getDefaultBrowserInfo() -> DefaultBrowserInfo {
        guard let url = URL(string: "http://example.com"),
              let defaultAppURL = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() else {
            return DefaultBrowserInfo(name: "Unknown", bundleIdentifier: nil, isPhiDefault: false)
        }
        
        let appURL = defaultAppURL as URL
        
        guard let defaultBundle = Bundle(url: appURL) else {
            let appName = appURL.deletingPathExtension().lastPathComponent
            return DefaultBrowserInfo(name: appName.isEmpty ? "Unknown" : appName, bundleIdentifier: nil, isPhiDefault: false)
        }
        
        let bundleId = defaultBundle.bundleIdentifier
        let phiBundleId = Bundle.main.bundleIdentifier
        let isPhiDefault = (bundleId != nil && bundleId == phiBundleId)
        
        let displayName: String = {
            if let localizedName = defaultBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !localizedName.isEmpty {
                return localizedName
            }
            if let bundleName = defaultBundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !bundleName.isEmpty {
                return bundleName
            }
            return appURL.deletingPathExtension().lastPathComponent
        }()
        
        return DefaultBrowserInfo(name: displayName, bundleIdentifier: bundleId, isPhiDefault: isPhiDefault)
    }
    
    /// Returns whether Phi is currently the default browser.
    static func isPhiDefaultBrowser() -> Bool {
        return getDefaultBrowserInfo().isPhiDefault
    }
    
    /// Returns the display name of the current default browser.
    static func getDefaultBrowserName() -> String {
        return getDefaultBrowserInfo().name
    }
}
