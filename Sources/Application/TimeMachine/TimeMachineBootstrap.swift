// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@objc(TimeMachineBootstrap)
final class TimeMachineBootstrap: NSObject {
    @objc static func recoverPendingRestoreIfNeeded() -> Bool {
        TimeMachineStartupRecoveryGate().recoverPendingRestoreIfNeeded()
    }

    @objc static func prepareBackupIfNeeded() {
        guard let currentBuild = Int(SystemUtils.buildNumber) else {
            AppLogError("[TimeMachine] Skipping backup because build number is not an integer: \(SystemUtils.buildNumber)")
            return
        }

        AppLogDebug("[TimeMachine] Checking backup policy for version \(SystemUtils.appVersion) build \(currentBuild).")
        do {
            if let record = try TimeMachineSnapshotManager().prepareBackupIfNeeded(
                currentVersion: SystemUtils.appVersion,
                currentBuild: currentBuild
            ) {
                AppLogInfo("[TimeMachine] Created backup \(record.id.uuidString) for build \(currentBuild).")
            }
        } catch {
            AppLogError("[TimeMachine] Failed to prepare backup: \(error.localizedDescription)")
        }
    }
}
