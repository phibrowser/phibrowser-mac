// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

/// Modification record:
/// - V9 adds a stable lineage id and dormant-migration state to pinned-tab
///   rows, and persists the selected pinned-tab scope in the local store.
///   Physical pinned rows can then be copied or merged between Space, Profile,
///   and App collections without losing data or the logical identity used by
///   live browser windows.
@available(macOS 14, *)
enum TabDataModelSchemaV9: VersionedSchema {
    static var versionIdentifier = Schema.Version(9, 0, 0)

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
