// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

@objc(TimeMachineBootstrap)
final class TimeMachineBootstrap: NSObject {
    /// Disabled after the 1.6 → 2.0 rollback window closed: the Help menu
    /// entry is hidden and existing backups are purged on launch. Flip back
    /// together with a new rollback policy to re-enable.
    static let isEnabled = false

    @objc static func recoverPendingRestoreIfNeeded() -> Bool {
        TimeMachineStartupRecoveryGate().recoverPendingRestoreIfNeeded()
    }

    @objc static func prepareBackupIfNeeded() {
        guard isEnabled else {
            schedulePurgeAllBackups()
            return
        }

        defer { scheduleCommittedDeletionCleanup() }

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

    private static func scheduleCommittedDeletionCleanup() {
        DispatchQueue.global(qos: .utility).async {
            do {
                try TimeMachineCatalogStore().purgeCommittedDeletionTombstones()
            } catch {
                AppLogError("[TimeMachine] Failed to finish interrupted backup deletion: \(error.localizedDescription)")
            }
        }
    }

    private static func schedulePurgeAllBackups() {
        DispatchQueue.global(qos: .utility).async {
            // A restore that still needs recovery may read its snapshot later;
            // an unreadable journal leaves that unknown, so keep everything.
            guard (try? TimeMachineRestoreJournalStore().pendingJournalsNeedingRecovery())?.isEmpty == true else {
                AppLogWarn("[TimeMachine] Skipping backup purge because restore recovery state is pending or unreadable.")
                return
            }

            let catalogStore = TimeMachineCatalogStore()
            do {
                try catalogStore.purgeCommittedDeletionTombstones()
            } catch {
                AppLogError("[TimeMachine] Failed to finish interrupted backup deletion: \(error.localizedDescription)")
            }

            do {
                for backup in try catalogStore.load().backups {
                    do {
                        try catalogStore.deleteBackup(id: backup.id)
                        AppLogInfo("[TimeMachine] Purged backup \(backup.id.uuidString) because Time Machine is disabled.")
                    } catch {
                        AppLogError("[TimeMachine] Failed to purge backup \(backup.id.uuidString): \(error.localizedDescription)")
                    }
                }
            } catch {
                AppLogError("[TimeMachine] Failed to purge backups: \(error.localizedDescription)")
            }

            do {
                let count = try catalogStore.purgeUncatalogedSnapshots()
                if count > 0 {
                    AppLogInfo("[TimeMachine] Purged \(count) uncataloged snapshots because Time Machine is disabled.")
                }
            } catch {
                AppLogError("[TimeMachine] Failed to purge uncataloged snapshots: \(error.localizedDescription)")
            }
        }
    }
}
