// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct LocalStoreCompatibilityConfiguration {
    static let defaultManifestFilename = "LocalStoreCompatibility.json"
    static let defaultBackupsDirectoryName = "CompatibilityBackups"

    let currentStoreFormatVersion: Int
    let readableStoreFormatVersions: ClosedRange<Int>
    /// Format assumed for an existing store that predates manifests when the
    /// bundle build number maps to no specific version. Defaults to
    /// `currentStoreFormatVersion`; `LocalStore` pins it to the last SwiftData
    /// format because a Core Data (format 10+) store always has a manifest.
    let legacyFallbackStoreFormatVersion: Int
    let storeFilename: String
    let manifestFilename: String
    let backupsDirectoryName: String
    let backupPolicy: LocalStoreBackupPolicy
    let dateProvider: () -> Date
    let idProvider: () -> String
    let bundleBuildNumberProvider: () -> Int?

    init(
        currentStoreFormatVersion: Int,
        readableStoreFormatVersions: ClosedRange<Int>,
        legacyFallbackStoreFormatVersion: Int? = nil,
        storeFilename: String,
        manifestFilename: String = Self.defaultManifestFilename,
        backupsDirectoryName: String = Self.defaultBackupsDirectoryName,
        backupPolicy: LocalStoreBackupPolicy = .beforeSchemaUpgrade,
        dateProvider: @escaping () -> Date = Date.init,
        idProvider: @escaping () -> String = { UUID().uuidString },
        bundleBuildNumberProvider: @escaping () -> Int? = Self.currentBundleBuildNumber
    ) {
        self.currentStoreFormatVersion = currentStoreFormatVersion
        self.readableStoreFormatVersions = readableStoreFormatVersions
        self.legacyFallbackStoreFormatVersion = legacyFallbackStoreFormatVersion ?? currentStoreFormatVersion
        self.storeFilename = storeFilename
        self.manifestFilename = manifestFilename
        self.backupsDirectoryName = backupsDirectoryName
        self.backupPolicy = backupPolicy
        self.dateProvider = dateProvider
        self.idProvider = idProvider
        self.bundleBuildNumberProvider = bundleBuildNumberProvider
    }

    func canReadStoreFormatVersion(_ version: Int) -> Bool {
        readableStoreFormatVersions.contains(version)
    }

    func legacyStoreFormatVersionForCurrentBundle() -> Int {
        guard let buildNumber = bundleBuildNumberProvider() else {
            return legacyFallbackStoreFormatVersion
        }

        if buildNumber >= 585 {
            return 5
        }

        if buildNumber >= 494 {
            return 3
        }

        return legacyFallbackStoreFormatVersion
    }

    private static func currentBundleBuildNumber() -> Int? {
        guard let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return Int(buildNumber)
    }
}
