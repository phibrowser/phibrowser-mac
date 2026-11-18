// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Durable record of a reset request this Mac made while it is not set up for sync (docs/sync.md,
/// "Starting over from a Mac that is not set up for sync"). Written before the request is sent,
/// so a lost response or a restart still finds the operation; while it exists the setup window
/// lands on the waiting page and Settings → Sync shows **Start over pending**.
///
/// `executeAfter` and `joinRequestId` are nil until the server has answered the request: the
/// waiting page and the Settings row show the date from here without a network call, and an
/// approval opens the join request named here.
struct SyncResetRequestJournal: Codable, Equatable {
    static let currentVersion = 1

    let v: Int
    let operationId: UUID
    /// The device key the request was made under. Cancel and execute send it; the server
    /// refuses them from any other key.
    let deviceKeyID: String
    let createdAtMs: Int64
    var executeAfterMs: Int64?
    var joinRequestId: String?

    init(operationId: UUID, deviceKeyID: String, createdAt: Date,
         executeAfter: Date? = nil, joinRequestId: String? = nil) {
        self.v = Self.currentVersion
        self.operationId = operationId
        self.deviceKeyID = deviceKeyID
        self.createdAtMs = Self.milliseconds(createdAt)
        self.executeAfterMs = executeAfter.map(Self.milliseconds)
        self.joinRequestId = joinRequestId
    }

    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1000) }
    var executeAfter: Date? { executeAfterMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }

    /// The same request with the server's answer recorded.
    func confirmed(executeAfter: Date, joinRequestId: String) -> SyncResetRequestJournal {
        var copy = self
        copy.executeAfterMs = Self.milliseconds(executeAfter)
        copy.joinRequestId = joinRequestId
        return copy
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

enum SyncResetRequestJournalError: Error { case writeFailed }

/// Reads, writes and clears the journal through two closures over the account defaults key
/// `sync.resetRequest`, the shape `SyncPairingLocalResetMarkerStore` uses, so the store stays
/// testable without an account. It lives in the same account defaults as `sync.pairingEnrollment`.
///
/// Cleared when the server answers a terminal status (approved, denied, blocked, expired,
/// cancelled, executed, gone) or a definitive refusal of the request. Kept on transport errors and
/// on sign-out: the request lives on the server regardless. An account switch needs no clearing:
/// another account never reads this account's defaults.
struct SyncResetRequestJournalStore {
    static let defaultsKey = "sync.resetRequest"

    private let readData: () -> Data?
    private let writeData: (Data?) -> Bool

    /// `writeData(nil)` removes the key. Both closures report persistence the way
    /// `AccountUserDefaults.set(_:forKey:)` does.
    init(readData: @escaping () -> Data?, writeData: @escaping (Data?) -> Bool) {
        self.readData = readData
        self.writeData = writeData
    }

    /// The journal, or nil when there is none, it cannot be decoded or it has an unknown version.
    func load() -> SyncResetRequestJournal? {
        guard let data = readData(),
              let journal = try? JSONDecoder().decode(SyncResetRequestJournal.self, from: data),
              journal.v == SyncResetRequestJournal.currentVersion else { return nil }
        return journal
    }

    func save(_ journal: SyncResetRequestJournal) throws {
        guard writeData(try JSONEncoder().encode(journal)) else {
            throw SyncResetRequestJournalError.writeFailed
        }
    }

    /// Removes the journal whatever it holds. Idempotent. Returns false when the removal could not
    /// be persisted.
    @discardableResult
    func clear() -> Bool {
        guard readData() != nil else { return true }
        return writeData(nil)
    }
}
