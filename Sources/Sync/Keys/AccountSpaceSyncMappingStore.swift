// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 本地 `spaceId` -> 账户级同步 uuid 的持久化口（D6 / M3-2b §2.1），
/// `ProfileSyncMappingStore` 的 Space 侧对应物**减去全部密码学**：Space 没有
/// per-entity 信封，铸造是一次纯本地写。
///
/// **不变量（§2.4）：本地 `spaceId` 永不被改写；syncUuid 永不写进任何本地行。**
/// 这张表是两个空间之间唯一的桥；`Sources/LocalStorage/**` 与 `SpaceManager` 对它
/// 一无所知。
protocol SpaceSyncMappingStore {
    func syncUuid(forSpaceId spaceId: String) -> String?
    func setSyncUuid(_ uuid: String, forSpaceId spaceId: String)
    /// `[localSpaceId: syncUuid]`
    func allMappings() -> [String: String]
    /// 删一行：本地行没了（本地删除 -> tombstone `.applied`，或 30 天清理），
    /// 留着只会让下一次反查交出一个不存在的 spaceId（§2.3）。
    func removeMapping(forSpaceId spaceId: String)
    /// 整表写空：自撤销（§2.3）。绝不是部分写，也绝不绕过这个 store 直写
    /// `AccountUserDefaults`。
    func removeAllMappings()
}

/// 账户 plist 里的那张表，与 `sync.profileGlobalUuids` 并排。
/// `AccountUserDefaults` 写 `users/<userID>/defaults/account_defaults.plist`，
/// 所以它**天然按账户隔离**：切账户不需要任何清理。
final class AccountSpaceSyncMappingStore: SpaceSyncMappingStore {
    static let defaultsKey = "sync.spaceGlobalUuids"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) {
        self.defaults = defaults
    }

    func syncUuid(forSpaceId spaceId: String) -> String? { allMappings()[spaceId] }

    func setSyncUuid(_ uuid: String, forSpaceId spaceId: String) {
        var map = allMappings()
        map[spaceId] = uuid
        defaults.set(map, forCodableKey: Self.defaultsKey)
    }

    func allMappings() -> [String: String] {
        defaults.codableValue(forKey: Self.defaultsKey) ?? [:]
    }

    func removeMapping(forSpaceId spaceId: String) {
        var map = allMappings()
        guard map.removeValue(forKey: spaceId) != nil else { return }
        defaults.set(map, forCodableKey: Self.defaultsKey)
    }

    func removeAllMappings() {
        defaults.set([String: String](), forCodableKey: Self.defaultsKey)
    }
}
