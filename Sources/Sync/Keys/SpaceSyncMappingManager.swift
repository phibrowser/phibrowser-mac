// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// `alreadyMapped` 与 `ProfileKeyManagerError.alreadyMapped`（ProfileKeyManager.swift:5-10）
/// 是同一条防线：它不是失败，是**拒绝铸造**——调用方把一次瞬时查表失败当成了「没有
/// 映射」，再铸一个就等于把账户里那条实体丢掉，两台设备从此永久分叉。
enum SpaceSyncMappingError: Error, Equatable {
    case alreadyMapped
    /// 该 syncUuid 已被另一个本地 Space 认领：单射性由写入口保证，不靠事后 tie-break 补救。
    case syncUuidAlreadyClaimed
    /// 默认 Space 的身份是常量，不存映射行（R-D6-2）。
    case defaultSpaceIsImplicit
    /// 这个 `SyncKeyController` 根本没有映射层（`spaceKeys == nil`）。失败方向是
    /// 「一条都不发布」，由 §9.3 的 `unmapped=<n>` 暴露——绝不是「用一张内存表凑合」。
    case mappingLayerUnavailable
}

/// 本地 `spaceId` <-> 账户级 syncUuid 的翻译层（D6 §2.1）。`ProfileKeyManager` 的
/// 类比物，无 api、无 keyManager。
///
/// **不变量（§2.4）：本地 `spaceId` 永不被改写；syncUuid 永不写进任何本地行。**
/// （spec §2.4 要求这两句进**两个**文件的头注释；另一份在
/// `AccountSpaceSyncMappingStore.swift` 的协议注释上。这里是唯一会把两个空间的字符串
/// 同时拿在手里的类型，读者在这里最容易把它们混起来。）
///
/// **默认 Space 的处理是「两个 resolver 里的常量分支」，不是一行映射（R-D6-2）。**
/// 理由是自撤销：`removeAllMappings()` 会把整表写空，一行
/// `"default-space" -> "default-space"` 会被一起删掉，而重新加入时若有任何一条路径
/// 先于重新播种去查表，默认 Space 就会被当成「没有映射」而在 snapshot 里被 `continue`
/// 掉——账户里那条 `default-space` 实体从此再也收不到这台机器的更新。常量分支让它
/// 不可摧毁，代价是每个 resolver 一个 `if`，两处，都在本文件里。
@MainActor
final class SpaceSyncMappingManager {
    private let store: any SpaceSyncMappingStore

    init(store: any SpaceSyncMappingStore) {
        self.store = store
    }

    /// 出站翻译。默认 Space 直接给常量，不查表。
    func syncUuid(forSpaceId spaceId: String) -> String? {
        if spaceId == LocalStore.defaultSpaceId { return SyncableSpaces.defaultSpaceUuid }
        return store.syncUuid(forSpaceId: spaceId)
    }

    /// 入站翻译。命中多条时取字典序最小者并记一条 warn（诊断，不是修复；单射性由
    /// `map(spaceId:toSyncUuid:)` 保证）。形状照 `ProfileKeyManager.localProfileId`
    /// （ProfileKeyManager.swift:183-192）。
    func localSpaceId(forSyncUuid uuid: String) -> String? {
        if uuid == SyncableSpaces.defaultSpaceUuid { return LocalStore.defaultSpaceId }
        let matches = store.allMappings().filter { $0.value == uuid }.keys.sorted()
        if matches.count > 1 {
            AppLogWarn("[phi-sync] \(matches.count) local Spaces map to one account Space; taking the lexicographically smallest")
        }
        return matches.first
    }

    /// 向导的「作为新 Space 加入」，以及 §3.2 的懒铸造。
    /// **绝不复用本地 spaceId**：本地 id 是 `UUID().uuidString`（大写，
    /// SpaceManager.swift:960），syncUuid 一律小写，于是两者混用在日志与 plist 里
    /// 肉眼可辨。
    func mintSyncUuid(forSpaceId spaceId: String) throws -> String {
        guard spaceId != LocalStore.defaultSpaceId else {
            throw SpaceSyncMappingError.defaultSpaceIsImplicit
        }
        guard store.syncUuid(forSpaceId: spaceId) == nil else {
            throw SpaceSyncMappingError.alreadyMapped
        }
        let uuid = UUID().uuidString.lowercased()
        store.setSyncUuid(uuid, forSpaceId: spaceId)
        return uuid
    }

    /// 向导的「对应到账户已有 Space」。三道闸：默认 Space、已有映射、该 uuid 已被
    /// 别的本地 Space 认领。
    func map(spaceId: String, toSyncUuid uuid: String) throws {
        guard spaceId != LocalStore.defaultSpaceId else {
            throw SpaceSyncMappingError.defaultSpaceIsImplicit
        }
        guard store.syncUuid(forSpaceId: spaceId) == nil else {
            throw SpaceSyncMappingError.alreadyMapped
        }
        guard !store.allMappings().values.contains(uuid) else {
            throw SpaceSyncMappingError.syncUuidAlreadyClaimed
        }
        store.setSyncUuid(uuid, forSpaceId: spaceId)
    }

    /// 引擎在首次 snapshot 前对每个同步合格 Space 调一次（R-D6-7 的懒铸造）。
    @discardableResult
    func ensureMapped(spaceId: String) throws -> String {
        if let uuid = syncUuid(forSpaceId: spaceId) { return uuid }
        return try mintSyncUuid(forSpaceId: spaceId)
    }

    /// 默认 Space 是 no-op（本来就没有行）。
    func removeMapping(forSpaceId spaceId: String) {
        store.removeMapping(forSpaceId: spaceId)
    }

    func removeAllMappings() {
        store.removeAllMappings()
    }

    func allMappings() -> [String: String] {
        store.allMappings()
    }
}
