// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Durable record that the user confirmed "replace this Mac's data with the account" and the setup
/// sequence has started removing local data (docs/sync.md, "Replacing this Mac's data at pairing").
/// While it exists, setup resumes that choice instead of offering a merge that would union the
/// leftovers of a partial reset into the account.
///
/// It lives under its own account-scoped key rather than in `sync.pairingEnrollment`: that record
/// is rebuilt on every write and `beginEnrollment` would drop any field added to it.
struct SyncPairingLocalResetMarker: Codable, Equatable {
    static let currentVersion = 1

    let v: Int
    /// The device key the reset was confirmed under. A marker from another key (the device was
    /// removed and re-joined) is ignored.
    let deviceKeyID: String
    /// The local Profiles the user chose to delete; every other local Profile is kept.
    let deleteProfileIds: Set<String>
    let startedAtMs: Int64

    init(deviceKeyID: String, deleteProfileIds: Set<String>, startedAtMs: Int64) {
        self.v = Self.currentVersion
        self.deviceKeyID = deviceKeyID
        self.deleteProfileIds = deleteProfileIds
        self.startedAtMs = startedAtMs
    }
}

enum SyncPairingLocalResetMarkerError: Error { case writeFailed }

/// Reads, writes and clears the marker through two closures over the account defaults key
/// `sync.pairingLocalReset`, the same shape `SyncPairingEnrollment` uses for its record, so the
/// store stays testable without an account.
///
/// Cleared by: successful enrollment completion (`ProfilePairingGate.completeEnrollment`), the
/// confirmed local sync cleanup (`SyncKeyController.clearLocalSyncState`, used by device removal
/// and reconfiguration). An account switch needs no clearing: the key lives in that account's own
/// defaults, so another account never reads it. Deferring setup ("Finish later") never clears it.
struct SyncPairingLocalResetMarkerStore {
    static let defaultsKey = "sync.pairingLocalReset"

    private let readData: () -> Data?
    private let writeData: (Data?) -> Bool

    /// `writeData(nil)` removes the key. Both closures report persistence the way
    /// `AccountUserDefaults.set(_:forKey:)` does.
    init(readData: @escaping () -> Data?, writeData: @escaping (Data?) -> Bool) {
        self.readData = readData
        self.writeData = writeData
    }

    /// The marker for `deviceKeyID`, or nil when there is none, it cannot be decoded, it has an
    /// unknown version, or it was written under another device key.
    func load(deviceKeyID: String) -> SyncPairingLocalResetMarker? {
        guard !deviceKeyID.isEmpty, let data = readData(),
              let marker = try? JSONDecoder().decode(SyncPairingLocalResetMarker.self, from: data),
              marker.v == SyncPairingLocalResetMarker.currentVersion,
              marker.deviceKeyID == deviceKeyID else { return nil }
        return marker
    }

    func save(_ marker: SyncPairingLocalResetMarker) throws {
        guard writeData(try JSONEncoder().encode(marker)) else {
            throw SyncPairingLocalResetMarkerError.writeFailed
        }
    }

    /// Removes the marker whatever it holds. Idempotent. Returns false when the removal could not
    /// be persisted.
    @discardableResult
    func clear() -> Bool {
        guard readData() != nil else { return true }
        return writeData(nil)
    }
}
