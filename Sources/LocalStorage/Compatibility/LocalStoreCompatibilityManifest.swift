// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct LocalStoreCompatibilityManifest: Codable, Equatable {
    static let currentManifestVersion = 1

    var manifestVersion: Int
    var activeStoreFormatVersion: Int
    var backups: [LocalStoreBackupRecord]

    init(
        manifestVersion: Int = Self.currentManifestVersion,
        activeStoreFormatVersion: Int,
        backups: [LocalStoreBackupRecord]
    ) {
        self.manifestVersion = manifestVersion
        self.activeStoreFormatVersion = activeStoreFormatVersion
        self.backups = backups
    }
}

struct LocalStoreBackupRecord: Codable, Equatable {
    let id: String
    let storeFormatVersion: Int
    let directoryName: String
    let createdAt: Date
    let createdBeforeUpgradingToStoreFormatVersion: Int
}
