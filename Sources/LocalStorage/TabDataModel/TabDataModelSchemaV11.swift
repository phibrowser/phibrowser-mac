// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// Modification record:
/// - V11 adds the six `SpaceURLRule` account-sync columns M3-4a needs on the
///   row itself (`syncId`, `contentUpdatedDate`, `targetUpdatedDate`,
///   `deletedDate`, `pendingLocalEdit`, `mergePartnerSyncId`) and the two
///   `ProfileModel` columns M3-4b will use (`syncId`, `createdDate`). Every
///   new column is optional or carries a default, so the stage is lightweight
///   at the schema level; `migrateV10toV11` additionally backfills
///   `SpaceURLRule.syncId` in its `didMigrate` closure.
///
/// Why M3-4b's two `ProfileModel` columns ship in V11 instead of waiting for
/// their own V12: one migration instead of two.
/// `LocalStoreBackupPolicy.beforeSchemaUpgrade` copies the whole
/// `LocalStore.sqlite` plus its `-wal` / `-shm` sidecars on every format bump,
/// and bookmark favicons are inlined as PNG bytes on the bookmark rows, so two
/// back-to-back bumps would leave three equally large copies of the store on
/// disk — while `Compatibility/README.md` forbids folding "delete old backups"
/// into a schema change. In M3-4a the two columns are dead: nothing reads or
/// writes them and `nil` is their only value.
///
/// All five models are re-declared even though only two change: a
/// `VersionedSchema` must list every model of the store, and copying only the
/// changed ones is the most common way this kind of migration goes wrong.
enum TabDataModelSchemaV11: VersionedSchema {
    static var versionIdentifier = Schema.Version(11, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProfileModel.self, TabDataModel.self, SpaceModel.self, SpaceURLRule.self, BrowserDataSettingsModel.self]
    }

    @Model
    final class ProfileModel {
        var guid: String
        @Attribute(.unique) var profileId: String
        var displayName: String?
        /// M3-4b 的账户级 Profile 身份。M3-4a 只声明，不读不写。
        var syncId: String?
        /// M3-4b 的 Profile 创建时刻。M3-4a 只声明，不读不写。
        var createdDate: Date?

        @Relationship(inverse: \TabDataModel.profile)
        var tabs: [TabDataModel] = []

        @Relationship
        var bookmarkRoot: TabDataModel?

        init(guid: String = UUID().uuidString, profileId: String, displayName: String? = nil) {
            self.guid = guid
            self.profileId = profileId
            self.displayName = displayName
        }

        static let entityName = "ProfileModel"
    }

    @Model
    final class TabDataModel {
        var guid: String
        var title: String
        var index: Int
        var url: URL
        var favicon: Data?
        var createdDate: Date
        var updatedDate: Date
        var type: Int = 0
        var overrideTitle: String?
        var isOpenned = false
        var isCreatedByChromium = false
        var needUpdateMetaData = false
        var spaceId: String?
        var profileId: String?
        var source: Int = 0
        var secondaryUrl: URL?
        var secondaryTitle: String?
        var splitPartnerGuid: String?
        var lastSeen: Date?
        /// Stable logical identity shared by copies of the same pinned tab.
        /// `guid` remains the unique physical record id used by Chromium.
        var pinLineageId: String?
        /// True only for a Profile-owned pinned row that could not be projected
        /// when the store moved to Space scope because that Profile had no
        /// Space. Unlike an ordinary inactive migration backup, this row still
        /// carries live data and must participate in the next scope migration.
        var isPinnedTabDormant = false
        /// 账户级同步身份（M3-3）。nil = 这一行还没上过账户。小写 uuid；与本地 `guid`
        /// （大写、每设备、克隆即重铸）是两个命名空间。
        ///
        /// **为什么住在行上而不是一张映射表里**（与 M3-2b 的 Space 侧有意分歧）：
        /// 1. 规模。`AccountSpaceSyncMappingStore` 每铸一个 uuid 就重写整张字典，而
        ///    `AccountUserDefaults.set` 每次都把整个 plist 重新序列化并原子落盘。Space
        ///    一个账户几条到几十条，书签一棵树上千条——同一个机制在这里是 O(n) 次全
        ///    plist 重写。
        /// 2. 书签行本来就没有被外部按 id 引用：父子是 SwiftData `@Relationship`，不是
        ///    按 guid 的外键；`SpaceModel.bookmarkRoot` 是关系指针不是 id。M3-2b 那条
        ///    「本地 id 永不被改写」是为了保护被引用的 Space id，书签行没有这个约束，
        ///    多一列不会波及任何既有读者。
        /// 3. Space 的映射层继续只服务 Space。书签通过它做 `space_uuid` ↔ 本地
        ///    `spaceId` 的翻译，不再造第二份反查。
        ///
        /// 结构性收益：`syncId` 与行本身在同一个事务里写入，落地路径没有第二次写可以
        /// 失败——不会出现「建完行之后写身份失败、行成了孤儿、每次重试再插一条」。
        var syncId: String?
        /// 用户对内容的最后一次编辑（标题 / URL / 拆分字段）。nil = 从未改过内容，
        /// 比较戳退回 `createdDate`。
        ///
        /// 只由共享的更新 body（书签的 `updateBookmarkBody`、pin 的编辑路径）在真的改了
        /// 内容字段时写；**打开（`updateLastSeen`）、favicon 回填（`updateTabFavicon`）、
        /// 稠密 index 重排（`normalizeIndexes`）、跨 Space 重打标签
        /// （`retagBookmarkSubtree`）一律不碰它**。
        ///
        /// **为什么不复用 `updatedDate`**：那三条非编辑路径会把 `updatedDate` 往前推，而
        /// 字段级合并要拿一个本机时间戳去和对端的编辑时间比。用 `updatedDate` 的话，一次
        /// 「打开」就能让本机一个没人动过的旧标题赢下对端刚做的改名；更糟的是
        /// `normalizeIndexes` 会在一次拖动里把整个文件夹的兄弟全部重新盖戳，于是加入期间
        /// 的一次拖动就能把那个文件夹里所有标题与 URL 回退成本机的值。改掉那三条路径不是
        /// 选项——`bookmarksPublisher` 与导出器都依赖 `updatedDate` 的现有语义。
        var contentUpdatedDate: Date?

        @Relationship(inverse: \TabDataModel.children)
        var parent: TabDataModel?

        @Relationship(deleteRule: .cascade)
        var children: [TabDataModel] = []

        var profile: ProfileModel?

        init(title: String, guid: String, index: Int, url: URL, favicon: Data?, createdDate: Date, updatedDate: Date) {
            self.title = title
            self.guid = guid
            self.index = index
            self.url = url
            self.favicon = favicon
            self.createdDate = createdDate
            self.updatedDate = updatedDate
        }

        static let entityName = "TabDataModel"
    }

    /// A user-facing browsing context bound to exactly one Chromium profile.
    /// Bookmarks remain per-Space. Pinned-tab ownership is selected globally
    /// for this local store and encoded on each pinned row as follows:
    /// - Space: both `profileId` and `spaceId` are set.
    /// - Profile: `profileId` is set and `spaceId` is nil.
    /// - App: both fields are nil.
    @Model
    final class SpaceModel {
        @Attribute(.unique) var spaceId: String
        var profileId: String
        var name: String
        var colorHex: String
        var iconName: String
        var sortOrder: Int
        var createdDate: Date
        var updatedDate: Date

        @Relationship
        var bookmarkRoot: TabDataModel?

        init(spaceId: String = UUID().uuidString,
             profileId: String,
             name: String,
             colorHex: String,
             iconName: String,
             sortOrder: Int,
             createdDate: Date = Date(),
             updatedDate: Date = Date()) {
            self.spaceId = spaceId
            self.profileId = profileId
            self.name = name
            self.colorHex = colorHex
            self.iconName = iconName
            self.sortOrder = sortOrder
            self.createdDate = createdDate
            self.updatedDate = updatedDate
        }

        static let entityName = "SpaceModel"
    }

    @Model
    final class SpaceURLRule {
        @Attribute(.unique) var id: String
        var spaceId: String
        var host: String
        var pathPrefix: String?
        var askBeforeRouting: Bool = false
        var sortOrder: Int
        var createdDate: Date

        /// 账户级同步身份（M3-4a）。**在 `LocalStore` 的插入点铸造**（R-M3-4a-23），
        /// 所以一条活行上它实际恒非 nil；`String?` 是为了让 V11 保持 lightweight。
        /// 小写 uuid；与本地 `id`（本机主键）是两个命名空间。
        var syncId: String?

        /// **内容组**（`host` / `pathPrefix` / `askBeforeRouting`，**三个成员**）的 LWW 戳。
        /// 本地编辑写 `now`（R-M3-4a-11），入站落地写**远端那一个**（R-M3-4a-20）。
        /// `sortOrder` 与 `spaceId` 的变化**都不写**它。
        var contentUpdatedDate: Date?

        /// **目标**（`spaceId`）自己的 LWW 戳，线上对应 `target_updated_at_ms`
        /// （R-M3-4a-40 / R-M3-4a-48）。它是 `locationStamp` 的本机来源：一次改目标写
        /// `now`，一次改名 / 改路径 / 改排序都不写。入站落地同样写远端那一个。
        var targetUpdatedDate: Date?

        /// 软删标记（R-M3-4a-41）。三条本机删除路径（编辑器删除集、agent 的
        /// `urlRules.delete`、Space 级联）都在**造成删除的那一个 SwiftData 事务**里写
        /// `deletedDate = now`，于是「行已删、删除意图没落盘」在结构上不存在。
        /// **入站 tombstone 落地是硬删。** 软删行只对同步可见（R-M3-4a-51）：默认读口
        /// 一律过滤它，唯一看得见它的是显式命名的第二读口
        /// `allURLRulesIncludingDeleted()`（Task 8 产出）。
        var deletedDate: Date?

        /// 用户编辑信号（R-M3-4a-65，语义整条见 spec §8.4.5 的 M4）。**只有用户可见的
        /// 写路径置位它**；**每一条删除与引擎的每一次写一律不置位**（稠密化、归一化、
        /// 收敛的内容组吸收与软删、落地、认领 re-key、Space 级联的两个入口）。清位只有
        /// 发布段那两处、都自愈。默认 `false`：一条升级前就存在的行按定义没有待发布的
        /// 用户编辑。
        var pendingLocalEdit: Bool = false

        /// 合并伙伴（R-M3-4a-71 / RR8-4）。**本机状态、不上线**：收敛在软删败者的**同一次
        /// 行写、同一个事务**里写它，或者作为一次纯提示写在每一个非锚点成员的行上；让位
        /// 时按它查找 W。**记在行上而不是游标里是硬要求**：两个 store 没有共同事务，而
        /// 游标写允许失败（R-M3-4a-16），「行已软删、指针没落盘」一旦发生就补不回来。
        var mergePartnerSyncId: String?

        // 六个新参数全部带默认值，于是 V10 时代的每一个构造点一个字不改就继续编译；
        // 插入点（Task 5）显式传 `syncId`。
        init(id: String = UUID().uuidString,
             spaceId: String,
             host: String,
             pathPrefix: String? = nil,
             askBeforeRouting: Bool = false,
             sortOrder: Int,
             createdDate: Date = Date(),
             syncId: String? = nil,
             contentUpdatedDate: Date? = nil,
             targetUpdatedDate: Date? = nil,
             deletedDate: Date? = nil,
             pendingLocalEdit: Bool = false,
             mergePartnerSyncId: String? = nil) {
            self.id = id
            self.spaceId = spaceId
            self.host = host
            self.pathPrefix = pathPrefix
            self.askBeforeRouting = askBeforeRouting
            self.sortOrder = sortOrder
            self.createdDate = createdDate
            self.syncId = syncId
            self.contentUpdatedDate = contentUpdatedDate
            self.targetUpdatedDate = targetUpdatedDate
            self.deletedDate = deletedDate
            self.pendingLocalEdit = pendingLocalEdit
            self.mergePartnerSyncId = mergePartnerSyncId
        }

        static let entityName = "SpaceURLRule"
    }

    /// Store-wide browser-data preferences whose changes must be committed in
    /// the same transaction as the data migration they trigger.
    @Model
    final class BrowserDataSettingsModel {
        @Attribute(.unique) var id: String
        var pinnedTabScopeRawValue: String

        init(id: String = "browser-data-settings", pinnedTabScopeRawValue: String = "profile") {
            self.id = id
            self.pinnedTabScopeRawValue = pinnedTabScopeRawValue
        }

        static let entityName = "BrowserDataSettingsModel"
        static let singletonId = "browser-data-settings"
    }
}
