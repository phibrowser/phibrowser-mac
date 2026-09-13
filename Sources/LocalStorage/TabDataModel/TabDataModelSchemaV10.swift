// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// Modification record:
/// - V10 adds the two account-sync columns bookmark sync needs on the row
///   itself: `TabDataModel.syncId` (the account-level identity) and
///   `TabDataModel.contentUpdatedDate` (the last user content edit). Both are
///   optional, so the stage is lightweight and no data moves.
///
/// All five models are re-declared even though only `TabDataModel` changes: a
/// `VersionedSchema` must list every model of the store, and copying only the
/// changed one is the most common way this kind of migration goes wrong.
enum TabDataModelSchemaV10: VersionedSchema {
    static var versionIdentifier = Schema.Version(10, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProfileModel.self, TabDataModel.self, SpaceModel.self, SpaceURLRule.self, BrowserDataSettingsModel.self]
    }

    @Model
    final class ProfileModel {
        var guid: String
        @Attribute(.unique) var profileId: String
        var displayName: String?

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

        init(id: String = UUID().uuidString,
             spaceId: String,
             host: String,
             pathPrefix: String? = nil,
             askBeforeRouting: Bool = false,
             sortOrder: Int,
             createdDate: Date = Date()) {
            self.id = id
            self.spaceId = spaceId
            self.host = host
            self.pathPrefix = pathPrefix
            self.askBeforeRouting = askBeforeRouting
            self.sortOrder = sortOrder
            self.createdDate = createdDate
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
