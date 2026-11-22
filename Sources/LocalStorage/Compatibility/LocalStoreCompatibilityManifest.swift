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
    /// `storeFormatVersion` of a quarantined store. No app can read format 0,
    /// so preflight never restores a quarantined store.
    static let unrecognisedStoreFormatVersion = 0

    let id: String
    let storeFormatVersion: Int
    let directoryName: String
    let createdAt: Date
    let createdBeforeUpgradingToStoreFormatVersion: Int
    /// SHA-256 of the backed-up store files. Nil for backups written before
    /// digests existed.
    var contentDigest: String?
    /// True when the files were moved aside because their schema matched no
    /// known store format, rather than copied before an upgrade.
    var isQuarantinedUnrecognisedStore: Bool?
}
