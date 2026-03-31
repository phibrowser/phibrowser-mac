// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import Foundation

typealias TabDataModel = TabDataModelSchemaV3.TabDataModel
typealias ProfileModel = TabDataModelSchemaV3.ProfileModel

extension TabDataModel: CustomStringConvertible {
    var description: String {
        return "Tab title: \(title), guid: \(guid)"
    }
}

enum TabDataModelMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TabDataModelSchemaV1.self, TabDataModelSchemaV2.self, TabDataModelSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
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

            if let bookmarkRoot = tabs.first(where: {
                $0.dataType == .bookmarkFolder &&
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

