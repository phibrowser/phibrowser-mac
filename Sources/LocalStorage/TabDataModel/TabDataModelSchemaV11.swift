// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// Modification record:
/// - V10 adds a generic icon identifier to tab data. Bookmark folders use it
///   first, while the field remains available to other tab kinds later.
/// - V10 stores the optional split layout for split bookmarks and pinned
///   split rows so stacked arrangements survive closing and reopening.
/// - V11 adds the two account-sync columns bookmark sync needs on the row
///   itself: `TabDataModel.syncId` (the account-level identity) and
///   `TabDataModel.contentUpdatedDate` (the last user content edit). Both are
///   optional, so the stage is lightweight and no data moves.
///
/// All five models are re-declared even though only `TabDataModel` changes: a
/// `VersionedSchema` must list every model of the store, and copying only the
/// changed one is the most common way this kind of migration goes wrong.
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
        /// Raw split layout (`vertical` side-by-side, `horizontal` stacked).
        /// Nil keeps existing records compatible and defaults to side-by-side.
        var layout: String?
        var lastSeen: Date?
        /// Stable resource identifier. Bookmark folders currently consume it;
        /// other tab kinds retain the default until they add icon support.
        var icon = "default"
        /// Stable logical identity shared by copies of the same pinned tab.
        /// `guid` remains the unique physical record id used by Chromium.
        var pinLineageId: String?
        /// True only for a Profile-owned pinned row that could not be projected
        /// when the store moved to Space scope because that Profile had no
        /// Space. Unlike an ordinary inactive migration backup, this row still
        /// carries live data and must participate in the next scope migration.
        var isPinnedTabDormant = false
        /// Account sync identity (M3-3), nil before publication. Lowercase UUID in a separate namespace from
        /// the uppercase, per-device local GUID reminted by cloning.
        ///
        /// Store identity on the row rather than a mapping table, unlike M3-2b Spaces: bookmark trees can have
        /// thousands of rows, while AccountSpaceSyncMappingStore rewrites its dictionary and entire account
        /// plist per UUID. Bookmark parent/root references are SwiftData relationships rather than GUID
        /// foreign keys, so adding a column does not threaten externally referenced local IDs. The existing
        /// Space mapping alone translates space_uuid ↔ local spaceId.
        ///
        /// Persist identity with the row in one transaction, avoiding orphan rows and duplicate inserts when a
        /// second identity write fails.
        var syncId: String?
        /// Last user content edit (title, URL or split fields); nil means never edited, falling back to
        /// createdDate for comparison. Shared bookmark/pin update bodies write it only when content changes.
        /// Opening (updateLastSeen), favicon backfill, dense index normalization and cross-Space retagging
        /// never touch it.
        ///
        /// Do not reuse updatedDate: those non-edit operations advance it, allowing a stale local title to
        /// beat a peer rename or a drag to roll back every sibling's title/URL. Preserve updatedDate's
        /// existing semantics required by publishers and export.
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
