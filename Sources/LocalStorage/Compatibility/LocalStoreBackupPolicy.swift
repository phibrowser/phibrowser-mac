// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct LocalStoreBackupContext {
    let activeStoreFormatVersion: Int
    let currentStoreFormatVersion: Int
    let existingBackups: [LocalStoreBackupRecord]
}

struct LocalStoreBackupPolicy {
    let shouldBackupBeforeOpening: (LocalStoreBackupContext) -> Bool

    init(shouldBackupBeforeOpening: @escaping (LocalStoreBackupContext) -> Bool) {
        self.shouldBackupBeforeOpening = shouldBackupBeforeOpening
    }

    static let never = LocalStoreBackupPolicy { _ in false }

    static let beforeSchemaUpgrade = LocalStoreBackupPolicy { context in
        context.activeStoreFormatVersion < context.currentStoreFormatVersion
    }
}
