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
    let storeFilename: String
    let manifestFilename: String
    let backupsDirectoryName: String
    let backupPolicy: LocalStoreBackupPolicy
    let dateProvider: () -> Date
    let idProvider: () -> String

    init(
        currentStoreFormatVersion: Int,
        readableStoreFormatVersions: ClosedRange<Int>,
        storeFilename: String,
        manifestFilename: String = Self.defaultManifestFilename,
        backupsDirectoryName: String = Self.defaultBackupsDirectoryName,
        backupPolicy: LocalStoreBackupPolicy = .beforeSchemaUpgrade,
        dateProvider: @escaping () -> Date = Date.init,
        idProvider: @escaping () -> String = { UUID().uuidString }
    ) {
        self.currentStoreFormatVersion = currentStoreFormatVersion
        self.readableStoreFormatVersions = readableStoreFormatVersions
        self.storeFilename = storeFilename
        self.manifestFilename = manifestFilename
        self.backupsDirectoryName = backupsDirectoryName
        self.backupPolicy = backupPolicy
        self.dateProvider = dateProvider
        self.idProvider = idProvider
    }

    func canReadStoreFormatVersion(_ version: Int) -> Bool {
        readableStoreFormatVersions.contains(version)
    }
}
