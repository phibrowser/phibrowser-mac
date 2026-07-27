// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreData
import Foundation
import SwiftData

// Stores written by SwiftData builds (format <= 9) are converted to the Core
// Data store (format 10) exactly once, by reading the old store through
// SwiftData — running its V1...V9 migration plan — and copying every row into
// a freshly built Core Data store that atomically replaces the old file.
// SwiftData requires macOS 14, which is fine: every store that predates the
// Core Data move was written by an app whose floor was macOS 14. On macOS
// 12/13 only fresh (format 10) stores can exist.

enum LocalStoreLegacyImportError: LocalizedError {
    case swiftDataUnavailable

    var errorDescription: String? {
        switch self {
        case .swiftDataUnavailable:
            return "This local store was written by a Phi version that requires macOS 14 to convert."
        }
    }
}

enum LocalStoreLegacyImport {
    /// Converts the SwiftData store in `storeDirectory` to the Core Data
    /// format in place. Throws without touching the store when conversion is
    /// impossible; the caller decides how to surface that.
    static func convertStore(at storeDirectory: URL, storeFilename: String) throws {
        guard #available(macOS 14, *) else {
            throw LocalStoreLegacyImportError.swiftDataUnavailable
        }
        let storeURL = storeDirectory.appendingPathComponent(storeFilename)
        let payload = try LegacyStoreReader.read(storeURL: storeURL)

        let importURL = storeDirectory.appendingPathComponent("LocalStore-import.sqlite")
        try destroyStoreFiles(at: importURL)
        try writeConvertedStore(payload, to: importURL)

        // Swap files directly instead of `replacePersistentStore`: the old
        // store was opened by SwiftData with persistent-history tracking, and
        // replace/destroy would reopen it without that option, get forced
        // into read-only mode, and fail. The pre-upgrade compatibility backup
        // already exists, and the import store is written with a DELETE
        // journal so it is a single file.
        try destroyStoreFiles(at: storeURL)
        try FileManager.default.moveItem(at: importURL, to: storeURL)
        try destroyStoreFiles(at: importURL)
        AppLogInfo("[LocalStore] Converted legacy SwiftData store at \(storeURL.path) (\(payload.tabs.count) tabs, \(payload.profiles.count) profiles, \(payload.spaces.count) spaces)")
    }

    private static func destroyStoreFiles(at storeURL: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private static func writeConvertedStore(_ payload: LegacyStorePayload, to url: URL) throws {
        let container = NSPersistentContainer(name: "LocalStoreImport", managedObjectModel: LocalStoreSchema.model)
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        // DELETE journal keeps the converted store a single file so the swap
        // above is one rename with no -wal/-shm leftovers.
        description.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError {
            throw loadError
        }

        let context = container.newBackgroundContext()
        var writeError: Error?
        context.performAndWait {
            do {
                var tabsByGuid: [String: TabDataModel] = [:]
                var profilesById: [String: ProfileModel] = [:]

                for legacy in payload.profiles {
                    let profile = ProfileModel(
                        insertInto: context,
                        guid: legacy.guid,
                        profileId: legacy.profileId,
                        displayName: legacy.displayName
                    )
                    profilesById[legacy.profileId] = profile
                }

                for legacy in payload.tabs {
                    let tab = TabDataModel(
                        insertInto: context,
                        title: legacy.title,
                        guid: legacy.guid,
                        index: legacy.index,
                        url: legacy.url,
                        favicon: legacy.favicon,
                        createdDate: legacy.createdDate,
                        updatedDate: legacy.updatedDate
                    )
                    tab.type = legacy.type
                    tab.overrideTitle = legacy.overrideTitle
                    tab.isOpenned = legacy.isOpenned
                    tab.isCreatedByChromium = legacy.isCreatedByChromium
                    tab.needUpdateMetaData = legacy.needUpdateMetaData
                    tab.spaceId = legacy.spaceId
                    tab.profileId = legacy.profileId
                    tab.source = legacy.source
                    tab.secondaryUrl = legacy.secondaryUrl
                    tab.secondaryTitle = legacy.secondaryTitle
                    tab.splitPartnerGuid = legacy.splitPartnerGuid
                    tab.lastSeen = legacy.lastSeen
                    tab.pinLineageId = legacy.pinLineageId
                    tab.isPinnedTabDormant = legacy.isPinnedTabDormant
                    tabsByGuid[legacy.guid] = tab
                }

                for legacy in payload.tabs {
                    guard let tab = tabsByGuid[legacy.guid] else { continue }
                    if let parentGuid = legacy.parentGuid {
                        tab.parent = tabsByGuid[parentGuid]
                    }
                    if let relatedProfileId = legacy.relatedProfileId {
                        tab.profile = profilesById[relatedProfileId]
                    }
                }

                for legacy in payload.profiles {
                    guard let rootGuid = legacy.bookmarkRootGuid else { continue }
                    profilesById[legacy.profileId]?.bookmarkRoot = tabsByGuid[rootGuid]
                }

                for legacy in payload.spaces {
                    let space = SpaceModel(
                        insertInto: context,
                        spaceId: legacy.spaceId,
                        profileId: legacy.profileId,
                        name: legacy.name,
                        colorHex: legacy.colorHex,
                        iconName: legacy.iconName,
                        sortOrder: legacy.sortOrder,
                        createdDate: legacy.createdDate,
                        updatedDate: legacy.updatedDate
                    )
                    if let rootGuid = legacy.bookmarkRootGuid {
                        space.bookmarkRoot = tabsByGuid[rootGuid]
                    }
                }

                for legacy in payload.rules {
                    _ = SpaceURLRule(
                        insertInto: context,
                        id: legacy.id,
                        spaceId: legacy.spaceId,
                        host: legacy.host,
                        pathPrefix: legacy.pathPrefix,
                        askBeforeRouting: legacy.askBeforeRouting,
                        sortOrder: legacy.sortOrder,
                        createdDate: legacy.createdDate
                    )
                }

                if let legacy = payload.settings {
                    _ = BrowserDataSettingsModel(
                        insertInto: context,
                        id: legacy.id,
                        pinnedTabScopeRawValue: legacy.pinnedTabScopeRawValue
                    )
                }

                try context.save()
            } catch {
                writeError = error
            }
        }
        if let writeError {
            throw writeError
        }
    }
}

// MARK: - Legacy payload

struct LegacyStorePayload {
    struct Tab {
        let guid: String
        let title: String
        let index: Int
        let url: URL
        let favicon: Data?
        let createdDate: Date
        let updatedDate: Date
        let type: Int
        let overrideTitle: String?
        let isOpenned: Bool
        let isCreatedByChromium: Bool
        let needUpdateMetaData: Bool
        let spaceId: String?
        let profileId: String?
        let source: Int
        let secondaryUrl: URL?
        let secondaryTitle: String?
        let splitPartnerGuid: String?
        let lastSeen: Date?
        let pinLineageId: String?
        let isPinnedTabDormant: Bool
        let parentGuid: String?
        let relatedProfileId: String?
    }

    struct Profile {
        let guid: String
        let profileId: String
        let displayName: String?
        let bookmarkRootGuid: String?
    }

    struct Space {
        let spaceId: String
        let profileId: String
        let name: String
        let colorHex: String
        let iconName: String
        let sortOrder: Int
        let createdDate: Date
        let updatedDate: Date
        let bookmarkRootGuid: String?
    }

    struct Rule {
        let id: String
        let spaceId: String
        let host: String
        let pathPrefix: String?
        let askBeforeRouting: Bool
        let sortOrder: Int
        let createdDate: Date
    }

    struct Settings {
        let id: String
        let pinnedTabScopeRawValue: String
    }

    let tabs: [Tab]
    let profiles: [Profile]
    let spaces: [Space]
    let rules: [Rule]
    let settings: Settings?
}

// MARK: - SwiftData reader

@available(macOS 14, *)
private enum LegacyStoreReader {
    /// Opens the SwiftData store (running the V1...V9 migration plan) and
    /// snapshots every row into plain values. The container is torn down when
    /// this function returns, before the caller replaces the store file.
    static func read(storeURL: URL) throws -> LegacyStorePayload {
        let configuration = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: TabDataModelSchemaV9.TabDataModel.self,
            TabDataModelSchemaV9.ProfileModel.self,
            TabDataModelSchemaV9.SpaceModel.self,
            TabDataModelSchemaV9.SpaceURLRule.self,
            TabDataModelSchemaV9.BrowserDataSettingsModel.self,
            migrationPlan: TabDataModelMigrationPlan.self,
            configurations: configuration
        )
        let context = ModelContext(container)

        let tabs = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.TabDataModel>()).map {
            LegacyStorePayload.Tab(
                guid: $0.guid,
                title: $0.title,
                index: $0.index,
                url: $0.url,
                favicon: $0.favicon,
                createdDate: $0.createdDate,
                updatedDate: $0.updatedDate,
                type: $0.type,
                overrideTitle: $0.overrideTitle,
                isOpenned: $0.isOpenned,
                isCreatedByChromium: $0.isCreatedByChromium,
                needUpdateMetaData: $0.needUpdateMetaData,
                spaceId: $0.spaceId,
                profileId: $0.profileId,
                source: $0.source,
                secondaryUrl: $0.secondaryUrl,
                secondaryTitle: $0.secondaryTitle,
                splitPartnerGuid: $0.splitPartnerGuid,
                lastSeen: $0.lastSeen,
                pinLineageId: $0.pinLineageId,
                isPinnedTabDormant: $0.isPinnedTabDormant,
                parentGuid: $0.parent?.guid,
                relatedProfileId: $0.profile?.profileId
            )
        }
        let profiles = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.ProfileModel>()).map {
            LegacyStorePayload.Profile(
                guid: $0.guid,
                profileId: $0.profileId,
                displayName: $0.displayName,
                bookmarkRootGuid: $0.bookmarkRoot?.guid
            )
        }
        let spaces = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.SpaceModel>()).map {
            LegacyStorePayload.Space(
                spaceId: $0.spaceId,
                profileId: $0.profileId,
                name: $0.name,
                colorHex: $0.colorHex,
                iconName: $0.iconName,
                sortOrder: $0.sortOrder,
                createdDate: $0.createdDate,
                updatedDate: $0.updatedDate,
                bookmarkRootGuid: $0.bookmarkRoot?.guid
            )
        }
        let rules = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.SpaceURLRule>()).map {
            LegacyStorePayload.Rule(
                id: $0.id,
                spaceId: $0.spaceId,
                host: $0.host,
                pathPrefix: $0.pathPrefix,
                askBeforeRouting: $0.askBeforeRouting,
                sortOrder: $0.sortOrder,
                createdDate: $0.createdDate
            )
        }
        let settings = try context.fetch(
            FetchDescriptor<TabDataModelSchemaV9.BrowserDataSettingsModel>()
        ).first.map {
            LegacyStorePayload.Settings(
                id: $0.id,
                pinnedTabScopeRawValue: $0.pinnedTabScopeRawValue
            )
        }

        return LegacyStorePayload(
            tabs: tabs,
            profiles: profiles,
            spaces: spaces,
            rules: rules,
            settings: settings
        )
    }
}

// MARK: - SwiftData migration plan (V1...V9)

@available(macOS 14, *)
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
            TabDataModelSchemaV8.self,
            TabDataModelSchemaV9.self,
        ]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9]
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

    /// Additive: introduces optional `displayName` on `ProfileModel` so Phi
    /// user-data backups can preserve Chromium profile labels. No data
    /// movement required — existing profiles start with nil.
    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: TabDataModelSchemaV7.self,
        toVersion: TabDataModelSchemaV8.self
    )

    /// Existing pinned tabs are profile-scoped. Give each one a stable
    /// logical identity and materialize the default preference alongside the
    /// schema upgrade so later scope changes can migrate atomically.
    static let migrateV8toV9 = MigrationStage.custom(
        fromVersion: TabDataModelSchemaV8.self,
        toVersion: TabDataModelSchemaV9.self,
        willMigrate: { _ in },
        didMigrate: { context in
            let pinnedRaw = TabDataType.pinnedTab.rawValue
            let tabs = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.TabDataModel>())
            for tab in tabs where tab.type == pinnedRaw && tab.pinLineageId == nil {
                tab.pinLineageId = tab.guid
            }

            let settings = try context.fetch(FetchDescriptor<TabDataModelSchemaV9.BrowserDataSettingsModel>())
            if settings.isEmpty {
                context.insert(TabDataModelSchemaV9.BrowserDataSettingsModel())
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
