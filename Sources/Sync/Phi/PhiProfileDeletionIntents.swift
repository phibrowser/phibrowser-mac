// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The durable record of local Profile deletions whose tombstone has not committed yet
/// (docs/sync.md, "Profile deletion and rename"): account profile uuid -> local profile id.
///
/// Written before the Chromium deletion starts, so losing the mapping, the process or the Space
/// table cannot lose the deletion. The main actor only adds entries (and removes one again when
/// the Chromium deletion fails); the engine removes an entry, through `PhiProfileLocalAccess`,
/// once the tombstone has committed or the deletion turned out not to need one.
protocol PhiProfileDeletionIntentStore: AnyObject {
    func load() -> [String: String]
    /// False when persistence failed; the previous value is still what `load` returns.
    @discardableResult func save(_ intents: [String: String]) -> Bool
}

/// The journal in the account plist, next to `sync.phiSpaces` and `sync.profileGlobalUuids`.
final class AccountProfileDeletionIntentStore: PhiProfileDeletionIntentStore {
    static let defaultsKey = "sync.profileDeletionIntents"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) { self.defaults = defaults }

    func load() -> [String: String] {
        defaults.codableValue(forKey: Self.defaultsKey) ?? [:]
    }

    @discardableResult
    func save(_ intents: [String: String]) -> Bool {
        defaults.set(intents, forCodableKey: Self.defaultsKey)
    }
}

enum PhiProfileDeletionError: Error {
    /// The deletion intent could not be persisted; nothing was deleted.
    case intentNotSaved
}
