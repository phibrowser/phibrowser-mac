// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// Shared progress marker and store birthday live in account.userDataStorage/sync/marker.json (M3-4a §2.10 /
// R-M3-4a-18), beside the three per-kind cursor files under App Support/Phi/users/<userID>.
//
// They must move out of UserDefaults.standard because user-data import replaces the entire account directory
// (AppController+UserDataBackup.replacePhiUserDataDirectory). A restored database/cursor set with a current
// marker would skip necessary history; missing local rows could then produce tombstones across all five kinds
// and delete account data. Keeping the files together restores a consistent set.
//
// One-time migration clears legacy phi.sync.marker/phi.sync.storeBirthday only after successful file
// persistence; failure keeps them for next launch. legacyMarkerStateKeys remains declared for
// account-switch/self-revocation cleanup.
//
// Engine rounds write this file atomically; confirmed cleanup uses it as a journal before deleting it. The
// engine's in-memory mirror writes through with rollback on failure in persistMarkerState.

/// Contents of users/<sub>/sync/marker.json (§2.10 / R-M3-4a-18), beside cursor tables so whole-directory
/// user-data restore rolls back database and marker together.
struct PhiSyncMarkerFile: Codable, Equatable {
    /// Version 1 is M3-4a's initial format. Older/undecodable files load empty, equivalent to nil marker and
    /// full datatype replay next pull (§10).
    static let currentFormatVersion = 1
    var formatVersion: Int = currentFormatVersion
    /// Opaque DataTypeProgressMarker token. Nil requests full replay. Optional Data distinguishes no marker
    /// from a valid zero-length marker that has advanced.
    var marker: Data?
    /// Server store identity; empty means unknown, matching storedBirthday.
    var storeBirthday: String = ""
    /// Optional for compatibility with existing format-1 files. Retains key rotation
    /// intent if an explicit removal fails partway through local cleanup.
    var removalPending: Bool?
    /// Blocks data rounds without changing marker/birthday until confirmed cleanup.
    var requiresReconfiguration: Bool?
}

/// Class-bound like PhiOwnedItemStateStore: the engine retains one instance across rounds and must observe
/// fake-state mutations in tests.
protocol PhiSyncMarkerStore: AnyObject {
    /// Unreadable files return empty marker/birthday state without writing back.
    func load() -> PhiSyncMarkerFile
    /// True means persisted, consumed by §2.5 item 4's third flag site (Task 2b).
    @discardableResult func save(_ file: PhiSyncMarkerFile) -> Bool
    /// Self-revocation (§4.4) deletes the file rather than saving empty state.
    func deleteFile()
}

/// Account marker.json, with the same three-method shape as FileOwnedItemStateStore.
final class FilePhiSyncMarkerStore: PhiSyncMarkerStore {
    /// Exposed for tests asserting unreadable-load paths never write back.
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Missing files, undecodable bytes and old format versions all return empty without writing. Replacing
    /// unreadable state with a valid empty file would hide real loss. §10 recovery requires empty plus no
    /// writeback so next pull replays from nil marker. Keep one guard because all three cases share this
    /// result.
    func load() -> PhiSyncMarkerFile {
        guard let bytes = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PhiSyncMarkerFile.self, from: bytes),
              decoded.formatVersion >= PhiSyncMarkerFile.currentFormatVersion else {
            return PhiSyncMarkerFile()
        }
        return decoded
    }

    /// Atomically persist the complete file. On failure return false without retry (R-M3-4a-83), letting the
    /// engine roll back its mirror and replay the page next round. Create intermediate directories as for
    /// cursor tables. R12 logs only has_marker and error metadata, never token bytes or birthday.
    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: fileURL, options: .atomic)
            return true
        } catch {
            AppLogError("[phi-sync] marker save failed has_marker=\(file.marker != nil) "
                + "(\(PhiSyncLog.describe(error)))")
            return false
        }
    }

    func deleteFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogWarn("[phi-sync] marker delete failed (\(PhiSyncLog.describe(error)))")
        }
    }
}

/// Fallback for tests/unwired construction when markerStore is nil. Reads/writes the two legacy engine keys
/// and removes empty values, matching pre-M3-4a writeState semantics. Preserves roughly forty existing
/// assertions across four test files. Production always injects FilePhiSyncMarkerStore in the coordinator,
/// guaranteeing directory-scoped markers there.
final class DefaultsBackedPhiSyncMarkerStore: PhiSyncMarkerStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> PhiSyncMarkerFile {
        PhiSyncMarkerFile(marker: defaults.data(forKey: PhiSyncEngine.markerStateKey),
                          storeBirthday: defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey) ?? "",
                          requiresReconfiguration: defaults.object(forKey: "phi.sync.requiresReconfiguration") as? Bool)
    }

    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        write(file.marker, forKey: PhiSyncEngine.markerStateKey)
        write(file.storeBirthday.isEmpty ? nil : file.storeBirthday,
              forKey: PhiSyncEngine.storeBirthdayStateKey)
        write(file.requiresReconfiguration, forKey: "phi.sync.requiresReconfiguration")
        return true
    }

    /// Delete-file semantics here remove both legacy keys, matching their former stateKeys cleanup.
    func deleteFile() {
        for key in PhiSyncEngine.legacyMarkerStateKeys + ["phi.sync.requiresReconfiguration"] { defaults.removeObject(forKey: key) }
    }

    private func write(_ value: Any?, forKey key: String) {
        guard let value else { return defaults.removeObject(forKey: key) }
        defaults.set(value, forKey: key)
    }
}

enum PhiSyncMarkerMigration {
    /// Idempotent one-time migration (R-M3-4a-18). Nonempty file state leaves file and legacy keys untouched;
    /// no legacy values is a no-op; persistence failure retains keys and returns false for retry next launch.
    /// True means migrated this time.
    ///
    /// Detect absence via empty store.load rather than fileExists, which the protocol lacks. Corrupt bytes are
    /// equivalent to nil marker (§10), so legacy values are the remaining source of truth. A bounded residual
    /// case can restore an old marker after failed migration and subsequent empty engine save, requiring explicit
    /// reconfiguration if the server identity changed.
    ///
    /// Run after resetPhiSyncCursorIfAccountChanged, which also clears legacy keys. Otherwise failed migration
    /// followed by an account switch could import the prior account's opaque marker and permanently miss
    /// updates.
    @discardableResult
    static func migrateLegacyMarker(from defaults: UserDefaults,
                                    into store: any PhiSyncMarkerStore) -> Bool {
        let legacyMarker = defaults.data(forKey: PhiSyncEngine.markerStateKey)
        let legacyBirthday = defaults.string(forKey: PhiSyncEngine.storeBirthdayStateKey) ?? ""
        guard legacyMarker != nil || !legacyBirthday.isEmpty else { return false }
        guard store.load() == PhiSyncMarkerFile() else { return false }
        let migrated = PhiSyncMarkerFile(marker: legacyMarker, storeBirthday: legacyBirthday)
        guard store.save(migrated) else {
            // Keep legacy keys as the remaining source of truth and retry next launch.
            AppLogWarn("[phi-sync] legacy marker migration deferred: marker file not written "
                + "has_marker=\(legacyMarker != nil)")
            return false
        }
        for key in PhiSyncEngine.legacyMarkerStateKeys { defaults.removeObject(forKey: key) }
        AppLogInfo("[phi-sync] migrated the legacy marker into the account directory "
            + "has_marker=\(legacyMarker != nil)")
        return true
    }
}
