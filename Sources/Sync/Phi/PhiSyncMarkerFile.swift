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
// engine's in-memory mirror writes through with rollback on failure in persistMarkerState. Two writers share
// the file (the engine actor and `SyncKeyController` on the main actor), so every read-modify-write goes
// through `PhiSyncMarkerStore.update`, which holds a per-file lock across load, mutation and save.

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
    /// The account reset's operation UUID, written by `SyncKeyController` before the reset
    /// request so a crash, timeout or lost response retries with the same UUID. Optional for
    /// compatibility with existing format-1 files. Unlike the two fields above it is written
    /// while the engine still runs, so the engine carries it forward from disk on every save
    /// rather than from its mirror (`PhiSyncEngine.saveMarkerFile`).
    var resetOperationId: UUID?
}

/// Class-bound like PhiOwnedItemStateStore: the engine retains one instance across rounds and must observe
/// fake-state mutations in tests.
///
/// Every read-modify-write MUST use `update`: the engine actor and `SyncKeyController` (main actor) both write
/// this file, and a plain `load()` then `save(_:)` lets the other writer's save land in between and lose a
/// field. Plain `save(_:)` is only for a whole-file write by a single owner (the legacy migration, tests).
protocol PhiSyncMarkerStore: AnyObject {
    /// Unreadable files return empty marker/birthday state without writing back.
    func load() -> PhiSyncMarkerFile
    /// True means persisted, consumed by §2.5 item 4's third flag site (Task 2b).
    @discardableResult func save(_ file: PhiSyncMarkerFile) -> Bool
    /// Loads, mutates and saves under one lock, so no other `update` (or `save`) on the same file interleaves.
    /// Returns the save's result; a failed save leaves the file as it was.
    @discardableResult func update(_ mutate: (inout PhiSyncMarkerFile) -> Void) -> Bool
    /// Self-revocation (§4.4) deletes the file rather than saving empty state.
    func deleteFile()
}

/// Account marker.json, with the same three-method shape as FileOwnedItemStateStore.
final class FilePhiSyncMarkerStore: PhiSyncMarkerStore {
    /// Exposed for tests asserting unreadable-load paths never write back.
    let fileURL: URL
    /// One lock per file, shared by every instance for the same URL. The coordinator hands one instance to
    /// both the controller and the engine today; a per-URL lock keeps `update` atomic even if a second
    /// instance for the same file appears later.
    private let lock: NSLock

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.lock = Self.locks.lock(for: fileURL)
    }

    private static let locks = LockTable()

    private final class LockTable {
        private let guardLock = NSLock()
        private var locks: [URL: NSLock] = [:]
        func lock(for url: URL) -> NSLock {
            let key = url.standardizedFileURL
            guardLock.lock()
            defer { guardLock.unlock() }
            if let existing = locks[key] { return existing }
            let created = NSLock()
            locks[key] = created
            return created
        }
    }

    /// Missing files, undecodable bytes and old format versions all return empty without writing. Replacing
    /// unreadable state with a valid empty file would hide real loss. §10 recovery requires empty plus no
    /// writeback so next pull replays from nil marker. Keep one guard because all three cases share this
    /// result.
    func load() -> PhiSyncMarkerFile {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveLocked(file)
    }

    @discardableResult
    func update(_ mutate: (inout PhiSyncMarkerFile) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var file = loadLocked()
        mutate(&file)
        return saveLocked(file)
    }

    private func loadLocked() -> PhiSyncMarkerFile {
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
    private func saveLocked(_ file: PhiSyncMarkerFile) -> Bool {
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
        lock.lock()
        defer { lock.unlock() }
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
    private let lock = NSLock()

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

    @discardableResult
    func update(_ mutate: (inout PhiSyncMarkerFile) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var file = load()
        mutate(&file)
        return save(file)
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
