// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct SiteMemoryRemovalResult: Decodable, Sendable {
    struct Deleted: Decodable, Sendable {
        let observations: Int
        let browserMemoryEntries: Int
        let ingestEvents: Int
        let tabSummaries: Int
        let galaxyNodes: Int
        let galaxyEdges: Int
    }
    struct Updated: Decodable, Sendable {
        let galaxyNodes: Int
        let galaxyEdges: Int
    }
    let ok: Bool
    let host: String
    let deleted: Deleted
    let updated: Updated
}

struct SiteMemoryService: Sendable {
    let accountID: String
    let settings: SiteMemorySettingsStore

    @MainActor
    static func currentAccount() throws -> SiteMemoryService {
        guard let account = AccountController.shared.account else {
            throw SiteMemoryError.accountUnavailable
        }
        let root = Account.uiTestStoreDirectoryURL ?? account.userDataStorage
        return SiteMemoryService(accountID: account.userID, settings: SiteMemorySettingsStore(
            fileURL: root.appendingPathComponent("defaults/site_memory.json")))
    }

    func collectionEnabled(for host: String, profileID: String) throws -> Bool {
        try settings.collectionEnabled(for: host, profileID: profileID)
    }

    func setCollectionEnabled(_ enabled: Bool, for host: String, profileID: String) throws {
        try settings.setCollectionEnabled(enabled, for: host, profileID: profileID)
    }

    /// Deletes server memory only. The capture owner must fence its pending
    /// events before calling this and invalidate its read cache after success.
    /// Uses UDS unless Sentinel explicitly selects legacy local HTTP.
    func removeMemories(for host: String, profileID: String) async throws -> SiteMemoryRemovalResult {
        try await ServiceBrokerExtensionProtocol.shared.removeSiteMemories(
            host: host, profileID: profileID, accountID: accountID)
    }
}
