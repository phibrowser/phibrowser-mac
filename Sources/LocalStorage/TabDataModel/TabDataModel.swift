// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import Foundation

typealias TabDataModel = TabDataModelSchemaV7.TabDataModel
typealias ProfileModel = TabDataModelSchemaV7.ProfileModel
typealias SpaceModel = TabDataModelSchemaV7.SpaceModel
typealias SpaceURLRule = TabDataModelSchemaV7.SpaceURLRule

extension TabDataModel: CustomStringConvertible {
    var description: String {
        return "Tab title: \(title), guid: \(guid)"
    }
}

enum TabDataModelMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            TabDataModelSchemaV1.self,
            TabDataModelSchemaV2.self,
            TabDataModelSchemaV3.self,
            TabDataModelSchemaV4.self,
            TabDataModelSchemaV5.self,
            TabDataModelSchemaV6.self,
            TabDataModelSchemaV7.self,
        ]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7]
    }

    nonisolated(unsafe) static var v1TypeMapping: [String: Int] = [:]

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: TabDataModelSchemaV1.self,
        toVersion: TabDataModelSchemaV2.self,
        willMigrate: { context in
            let descriptor = FetchDescriptor<TabDataModelSchemaV1.TabDataModel>()
            let oldTabs = try context.fetch(descriptor)
            var mapping: [String: Int] = [:]
            for tab in oldTabs {
                if tab.isPinned {
                    mapping[tab.guid] = TabDataType.pinnedTab.rawValue
                } else if tab.isBookmark && tab.isFolder {
                    mapping[tab.guid] = TabDataType.bookmarkFolder.rawValue
                } else if tab.isBookmark {
                    mapping[tab.guid] = TabDataType.bookmark.rawValue
                } else {
                    mapping[tab.guid] = TabDataType.tab.rawValue
                }
            }
            v1TypeMapping = mapping
            try context.save()
        },
        didMigrate: { context in
            let mapping = v1TypeMapping
            guard !mapping.isEmpty else { return }
            let descriptor = FetchDescriptor<TabDataModelSchemaV2.TabDataModel>()
            let newTabs = try context.fetch(descriptor)
            for tab in newTabs {
                if let rawType = mapping[tab.guid] {
                    tab.type = rawType
                }
            }
            v1TypeMapping = [:]
            try context.save()
        }
    )

    /// Additive: introduces optional `secondaryUrl` for split-view bookmarks.
    /// No data movement required — SwiftData fills the new column with nil.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: TabDataModelSchemaV3.self,
        toVersion: TabDataModelSchemaV4.self
    )

    /// Additive: introduces optional `splitPartnerGuid` so pinned splits
    /// survive restarts. No data movement required.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: TabDataModelSchemaV4.self,
        toVersion: TabDataModelSchemaV5.self
    )

    /// Additive: introduces optional `lastSeen` for persisted last-opened
    /// tracking on pinned tabs and bookmarks. No data movement required.
    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: TabDataModelSchemaV5.self,
        toVersion: TabDataModelSchemaV6.self
    )

    /// Adds `SpaceModel` and `SpaceURLRule` (schema-level additive) AND
    /// backfills every existing *bookmark* row where `spaceId == nil` to the
    /// well-known default space id. Only bookmarks are scoped per-Space (see
    /// the `SpaceModel` doc in `TabDataModelSchemaV7`): pinned tabs are
    /// per-profile and ordinary/open tabs are unscoped, so both keep
    /// `spaceId == nil` and are left untouched. Once backfilled, the bookmark
    /// queries can filter by `spaceId` without a nil-equivalence rule, and new
    /// spaces remain cleanly isolated from pre-Spaces data. `SpaceURLRule`
    /// starts as an empty table; SpaceManager populates rows when the user
    /// adds routing rules.
    static let migrateV6toV7 = MigrationStage.custom(
        fromVersion: TabDataModelSchemaV6.self,
        toVersion: TabDataModelSchemaV7.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let descriptor = FetchDescriptor<TabDataModelSchemaV7.TabDataModel>()
            let tabs = try context.fetch(descriptor)
            // Mirrors `LocalStore.defaultSpaceId`; intentionally hard-coded here
            // so the migration is self-contained (app-level constants are not
            // guaranteed to be linked at migration time).
            let defaultSpaceId = "default-space"
            // Restrict to bookmark kinds: pinned tabs (per-profile) and
            // ordinary/open tabs (unscoped) never read `spaceId`, and the
            // `SpaceModel` doc requires their `spaceId` to stay nil. Tagging
            // them would falsify that invariant and pull them into
            // `deleteTaggedRows` / `deleteSpaceCascade(spaceId:)`.
            let bookmarkKinds: Set<Int> = [TabDataType.bookmark.rawValue,
                                           TabDataType.bookmarkFolder.rawValue]
            for tab in tabs where tab.spaceId == nil && bookmarkKinds.contains(tab.type) {
                tab.spaceId = defaultSpaceId
            }
            try context.save()
        }
    )

    static let migrateV2toV3 = MigrationStage.custom(
        fromVersion: TabDataModelSchemaV2.self,
        toVersion: TabDataModelSchemaV3.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let profileDescriptor = FetchDescriptor<TabDataModelSchemaV3.ProfileModel>()
            let existingProfiles = try context.fetch(profileDescriptor)
            let defaultProfile: TabDataModelSchemaV3.ProfileModel
            if let existingProfile = existingProfiles.first(where: { $0.profileId == LocalStore.defaultProfileId }) {
                defaultProfile = existingProfile
            } else {
                let createdProfile = TabDataModelSchemaV3.ProfileModel(profileId: LocalStore.defaultProfileId)
                context.insert(createdProfile)
                defaultProfile = createdProfile
            }

            let tabDescriptor = FetchDescriptor<TabDataModelSchemaV3.TabDataModel>()
            let tabs = try context.fetch(tabDescriptor)
            for tab in tabs {
                tab.profile = defaultProfile
                tab.profileId = LocalStore.defaultProfileId
            }

            let bookmarkFolderRaw = TabDataType.bookmarkFolder.rawValue
            if let bookmarkRoot = tabs.first(where: {
                $0.type == bookmarkFolderRaw &&
                $0.parent == nil
            }) {
                defaultProfile.bookmarkRoot = bookmarkRoot
            }

            try context.save()
        }
    )
}



enum TabDataType: Int {
    case tab = 0
    case pinnedTab = 1
    case bookmark = 2
    case bookmarkFolder = 3
}

enum TabSource: Int {
    case phi = 0
    case chromium = 1
    case safari = 2
    case arc = 3
}

extension TabDataModel {
    var dataType: TabDataType {
        get { TabDataType(rawValue: type) ?? .tab }
        set { type = newValue.rawValue }
    }

    var tabSource: TabSource {
        get { TabSource(rawValue: source) ?? .phi }
        set { source = newValue.rawValue }
    }
}
