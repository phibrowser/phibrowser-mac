// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Account-scoped persistence of the local-profile-id -> global profile UUID
/// mapping, stored as one codable dictionary in AccountUserDefaults.
final class AccountProfileSyncMappingStore: ProfileSyncMappingStore {
    static let defaultsKey = "sync.profileGlobalUuids"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) {
        self.defaults = defaults
    }

    func globalUuid(forProfileId profileId: String) -> String? { allMappings()[profileId] }

    func setGlobalUuid(_ uuid: String, forProfileId profileId: String) {
        var map = allMappings()
        map[profileId] = uuid
        defaults.set(map, forCodableKey: Self.defaultsKey)
    }

    func allMappings() -> [String: String] {
        defaults.codableValue(forKey: Self.defaultsKey) ?? [:]
    }
}
