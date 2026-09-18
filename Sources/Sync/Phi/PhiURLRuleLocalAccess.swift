// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// 一条本机规则行的值快照。**绝不是 model 对象**：SwiftData 就地刷新同一批实例，按对象
/// 比较的去重会吞掉真实字段编辑（`LocalStore+Space.swift:431-452`、`LocalStore.swift:536-540`
/// 两处都为此栽过跟头）。与 `PhiLocalBookmark`（`PhiBookmarkLocalAccess.swift`）同款：住在
/// `Sources/Sync/Phi/`、**不依赖 `LocalStorage`**，所以同步层可以在没有 SwiftData 的测试
/// 进程里整体构造。协议 `PhiURLRuleLocalAccess` 与 `AccountPhiURLRuleAccess` 由 Task 8
/// 追加进同一个文件（M3-3 PR2 的形状：值类型先于生产实现）。
struct PhiLocalURLRule: Equatable {
    /// 本机物理行的 id（`SpaceURLRule.id`）。落地的每一个操作都按它定位。
    var id: String
    /// 账户级 uuid（小写，`SpaceURLRule.syncId`）。插入点铸造（R-M3-4a-23），所以对一条活行
    /// **实际恒非 nil**；类型仍是可选，因为 V11 之前的历史行要经 backfill 才拿到它。
    var syncId: String?
    /// 目标 Space 的本机 id；Incognito 目标是裸前缀 `SpaceManager.incognitoRuleTargetId`。
    var spaceId: String
    var host: String
    /// nil = 匹配任意路径（线上是 `""`）；`"/"` = 只匹配根。两者是**不同的值**（§8.1）。
    var pathPrefix: String?
    var askBeforeRouting: Bool
    /// 桶内稠密下标（§8.3）；线上只有 `rank`，两者由 `URLRuleKind.rankToSortOrder` 投影。
    var sortOrder: Int
    var createdDate: Date
    /// nil = 从未改过内容组，无基线投影的内容组戳退回 `createdDate`（R-M3-4a-12）。
    var contentUpdatedDate: Date?
    /// R-M3-4a-73：§8.2 的无基线分支取 `targetUpdatedDate ?? createdDate`。
    var targetUpdatedDate: Date?
    /// 软删标记（R-M3-4a-41）。`allURLRulesIncludingDeleted()` 交回软删行，调用方靠它分辨。
    var deletedDate: Date?
    /// R-M3-4a-65 的用户编辑信号。kind 适配（Task 7）**一处都不读**（读点穷举为二，都在
    /// 8b-1 / 8b-3）。
    var pendingLocalEdit: Bool
    /// R-M3-4a-71 的合并伙伴。**本机状态、不上线、不进实体、不进签名**；kind 适配不读不写。
    var mergePartnerSyncId: String?
}
