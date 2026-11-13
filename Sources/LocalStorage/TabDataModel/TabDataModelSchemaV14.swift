// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// V14 adds the columns that let persisted splits hold three or four panes: `splitPaneGuids` on
/// pinned rows and `splitExtraPanes` on split bookmarks. Both are optional and not backfilled:
/// nil means a pair, stored exactly as before. V13's bookmark location edit date, V10 bookmark
/// icons and split layouts, V11 tab sync fields and V12 rule/profile sync columns are retained.
enum TabDataModelSchemaV14: VersionedSchema {
    static var versionIdentifier = Schema.Version(14, 0, 0)

    static var models: [any PersistentModel.Type] {
        [ProfileModel.self, TabDataModel.self, SpaceModel.self, SpaceURLRule.self, BrowserDataSettingsModel.self]
    }

    @Model
    final class ProfileModel {
        var guid: String
        @Attribute(.unique) var profileId: String
        var displayName: String?
        var syncId: String?
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
        /// Split bookmark of three or four panes: a JSON array of `SplitBookmarkExtraPane` for the
        /// panes after `url` and `secondaryUrl`. Nil for a pair. Local-only: sync and HTML export
        /// see the first two panes.
        var splitExtraPanes: String?
        var splitPartnerGuid: String?
        /// Pinned split of three or four panes: the JSON array of every member's `guid`, carried
        /// by each member. Nil for a solo pin and for a pair, which `splitPartnerGuid` links.
        /// Local-only: sync sees these members as separate pins.
        var splitPaneGuids: String?
        /// Raw split layout (`vertical` side-by-side, `horizontal` stacked).
        /// Nil keeps existing records compatible and defaults to side-by-side.
        var layout: String?
        var lastSeen: Date?
        /// Stable resource identifier for bookmark folders and pinned-tab icon overrides.
        /// Other tab kinds retain the default.
        var icon = "default"
        /// Stable logical identity shared by copies of the same pinned tab.
        /// `guid` remains the unique physical record id used by Chromium.
        var pinLineageId: String?
        /// True only for a Profile-owned pinned row that could not be projected
        /// when the store moved to Space scope because that Profile had no
        /// Space. Unlike an ordinary inactive migration backup, this row still
        /// carries live data and must participate in the next scope migration.
        var isPinnedTabDormant = false
        /// Account identity, separate from the local physical row ID.
        var syncId: String?
        /// Last content edit; opening, favicon updates and reordering do not change it.
        var contentUpdatedDate: Date?
        /// Last local user move of this bookmark's location merge unit (parent and Space
        /// together, §4.3). Reordering inside one parent is rank, not location, and does not
        /// touch it; neither does a landed remote move, nor the Space retag a moved folder
        /// performs on its descendants (R-M3-3-18). Nil means no recorded move.
        var locationUpdatedDate: Date?

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

        var syncId: String?

        var contentUpdatedDate: Date?

        var targetUpdatedDate: Date?

        var deletedDate: Date?

        var pendingLocalEdit: Bool = false

        var mergePartnerSyncId: String?

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
