// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreData
import Foundation

// The local store runs on Core Data so the app can deploy to macOS 12; the
// entity shapes mirror SwiftData Schema V9 exactly (store format 9). Stores
// written by SwiftData builds are converted once by `LocalStoreLegacyImport`
// (store format 10 marks a Core Data store — see `LocalStore`).

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

/// Common surface for the local-store entities: a stable entity name plus a
/// typed fetch-request builder so call sites stay one-liners.
protocol LocalStoreFetchable: NSManagedObject {
    static var entityName: String { get }
}

extension LocalStoreFetchable {
    static func request(
        _ predicate: NSPredicate? = nil,
        sortBy: [NSSortDescriptor] = [],
        limit: Int = 0
    ) -> NSFetchRequest<Self> {
        let request = NSFetchRequest<Self>(entityName: entityName)
        request.predicate = predicate
        if !sortBy.isEmpty {
            request.sortDescriptors = sortBy
        }
        if limit > 0 {
            request.fetchLimit = limit
        }
        return request
    }
}

// The convenience initializers below come in two flavors: `insertInto:` inserts
// the new row immediately, while the context-free variants create a DETACHED
// object (`insertInto: nil`) — used for stand-ins that are never persisted
// (e.g. SpaceManager's Incognito Spaces and optimistic strip placeholders)
// and by tests that insert explicitly. A detached object can still be handed
// to `NSManagedObjectContext.insert(_:)` later. The inserting label is NOT
// `context:` on purpose — that call would silently resolve to the inherited
// `NSManagedObject.init(context:)`, which skips these initializers' stored
// defaults (a save-time validation failure waiting to happen).

@objc(ProfileModel)
final class ProfileModel: NSManagedObject, LocalStoreFetchable {
    @NSManaged var guid: String
    @NSManaged var profileId: String
    @NSManaged var displayName: String?

    @NSManaged var tabs: Set<TabDataModel>
    @NSManaged var bookmarkRoot: TabDataModel?

    convenience init(
        insertInto context: NSManagedObjectContext,
        guid: String = UUID().uuidString,
        profileId: String,
        displayName: String? = nil
    ) {
        self.init(entity: Self.entity(in: context), insertInto: context)
        self.guid = guid
        self.profileId = profileId
        self.displayName = displayName
    }

    convenience init(
        guid: String = UUID().uuidString,
        profileId: String,
        displayName: String? = nil
    ) {
        self.init(entity: LocalStoreSchema.entity(Self.entityName), insertInto: nil)
        self.guid = guid
        self.profileId = profileId
        self.displayName = displayName
    }

    static let entityName = "ProfileModel"
}

@objc(TabDataModel)
final class TabDataModel: NSManagedObject, LocalStoreFetchable {
    @NSManaged var guid: String
    @NSManaged var title: String
    @NSManaged var index: Int
    @NSManaged var url: URL
    @NSManaged var favicon: Data?
    @NSManaged var createdDate: Date
    @NSManaged var updatedDate: Date
    @NSManaged var type: Int
    @NSManaged var overrideTitle: String?
    @NSManaged var isOpenned: Bool
    @NSManaged var isCreatedByChromium: Bool
    @NSManaged var needUpdateMetaData: Bool
    @NSManaged var spaceId: String?
    @NSManaged var profileId: String?
    @NSManaged var source: Int
    @NSManaged var secondaryUrl: URL?
    @NSManaged var secondaryTitle: String?
    @NSManaged var splitPartnerGuid: String?
    @NSManaged var lastSeen: Date?
    /// Stable logical identity shared by copies of the same pinned tab.
    /// `guid` remains the unique physical record id used by Chromium.
    @NSManaged var pinLineageId: String?
    /// True only for a Profile-owned pinned row that could not be projected
    /// when the store moved to Space scope because that Profile had no
    /// Space. Unlike an ordinary inactive migration backup, this row still
    /// carries live data and must participate in the next scope migration.
    @NSManaged var isPinnedTabDormant: Bool

    @NSManaged var parent: TabDataModel?
    @NSManaged var children: Set<TabDataModel>
    @NSManaged var profile: ProfileModel?

    convenience init(
        insertInto context: NSManagedObjectContext,
        title: String,
        guid: String,
        index: Int,
        url: URL,
        favicon: Data?,
        createdDate: Date,
        updatedDate: Date
    ) {
        self.init(entity: Self.entity(in: context), insertInto: context)
        self.title = title
        self.guid = guid
        self.index = index
        self.url = url
        self.favicon = favicon
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    convenience init(
        title: String,
        guid: String,
        index: Int,
        url: URL,
        favicon: Data?,
        createdDate: Date,
        updatedDate: Date
    ) {
        self.init(entity: LocalStoreSchema.entity(Self.entityName), insertInto: nil)
        self.title = title
        self.guid = guid
        self.index = index
        self.url = url
        self.favicon = favicon
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    override var description: String {
        "Tab title: \(title), guid: \(guid)"
    }

    static let entityName = "TabDataModel"
}

/// A user-facing browsing context bound to exactly one Chromium profile.
/// Bookmarks remain per-Space. Pinned-tab ownership is selected globally
/// for this local store and encoded on each pinned row as follows:
/// - Space: both `profileId` and `spaceId` are set.
/// - Profile: `profileId` is set and `spaceId` is nil.
/// - App: both fields are nil.
@objc(SpaceModel)
final class SpaceModel: NSManagedObject, LocalStoreFetchable {
    @NSManaged var spaceId: String
    @NSManaged var profileId: String
    @NSManaged var name: String
    @NSManaged var colorHex: String
    @NSManaged var iconName: String
    @NSManaged var sortOrder: Int
    @NSManaged var createdDate: Date
    @NSManaged var updatedDate: Date

    @NSManaged var bookmarkRoot: TabDataModel?

    convenience init(
        insertInto context: NSManagedObjectContext,
        spaceId: String = UUID().uuidString,
        profileId: String,
        name: String,
        colorHex: String,
        iconName: String,
        sortOrder: Int,
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.init(entity: Self.entity(in: context), insertInto: context)
        self.spaceId = spaceId
        self.profileId = profileId
        self.name = name
        self.colorHex = colorHex
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.createdDate = createdDate
        self.updatedDate = updatedDate
    }

    convenience init(
        spaceId: String = UUID().uuidString,
        profileId: String,
        name: String,
        colorHex: String,
        iconName: String,
        sortOrder: Int,
        createdDate: Date = Date(),
        updatedDate: Date = Date()
    ) {
        self.init(entity: LocalStoreSchema.entity(Self.entityName), insertInto: nil)
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

@objc(SpaceURLRule)
final class SpaceURLRule: NSManagedObject, LocalStoreFetchable {
    @NSManaged var id: String
    @NSManaged var spaceId: String
    @NSManaged var host: String
    @NSManaged var pathPrefix: String?
    @NSManaged var askBeforeRouting: Bool
    @NSManaged var sortOrder: Int
    @NSManaged var createdDate: Date

    convenience init(
        insertInto context: NSManagedObjectContext,
        id: String = UUID().uuidString,
        spaceId: String,
        host: String,
        pathPrefix: String? = nil,
        askBeforeRouting: Bool = false,
        sortOrder: Int,
        createdDate: Date = Date()
    ) {
        self.init(entity: Self.entity(in: context), insertInto: context)
        self.id = id
        self.spaceId = spaceId
        self.host = host
        self.pathPrefix = pathPrefix
        self.askBeforeRouting = askBeforeRouting
        self.sortOrder = sortOrder
        self.createdDate = createdDate
    }

    convenience init(
        id: String = UUID().uuidString,
        spaceId: String,
        host: String,
        pathPrefix: String? = nil,
        askBeforeRouting: Bool = false,
        sortOrder: Int,
        createdDate: Date = Date()
    ) {
        self.init(entity: LocalStoreSchema.entity(Self.entityName), insertInto: nil)
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
@objc(BrowserDataSettingsModel)
final class BrowserDataSettingsModel: NSManagedObject, LocalStoreFetchable {
    @NSManaged var id: String
    @NSManaged var pinnedTabScopeRawValue: String

    convenience init(
        insertInto context: NSManagedObjectContext,
        id: String = BrowserDataSettingsModel.singletonId,
        pinnedTabScopeRawValue: String = "profile"
    ) {
        self.init(entity: Self.entity(in: context), insertInto: context)
        self.id = id
        self.pinnedTabScopeRawValue = pinnedTabScopeRawValue
    }

    convenience init(
        id: String = BrowserDataSettingsModel.singletonId,
        pinnedTabScopeRawValue: String = "profile"
    ) {
        self.init(entity: LocalStoreSchema.entity(Self.entityName), insertInto: nil)
        self.id = id
        self.pinnedTabScopeRawValue = pinnedTabScopeRawValue
    }

    static let entityName = "BrowserDataSettingsModel"
    static let singletonId = "browser-data-settings"
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

private extension LocalStoreFetchable {
    /// Resolves the entity description from the context's model rather than
    /// the process-wide `NSManagedObject.entity()` lookup, which is ambiguous
    /// when more than one container (main store, backups, tests) is alive.
    static func entity(in context: NSManagedObjectContext) -> NSEntityDescription {
        guard let entity = NSEntityDescription.entity(forEntityName: entityName, in: context) else {
            fatalError("Missing Core Data entity \(entityName)")
        }
        return entity
    }
}

// MARK: - Programmatic model

/// Builds the `NSManagedObjectModel` for the local store in code. A single
/// shared instance backs every container in the process (main store, backup
/// imports, tests) so entity descriptions never become ambiguous.
enum LocalStoreSchema {
    static let model: NSManagedObjectModel = makeModel()

    /// Entity lookup against the shared model, for creating detached objects
    /// outside any context.
    static func entity(_ name: String) -> NSEntityDescription {
        guard let entity = model.entitiesByName[name] else {
            fatalError("Missing Core Data entity \(name)")
        }
        return entity
    }

    private static func makeModel() -> NSManagedObjectModel {
        let profile = NSEntityDescription()
        profile.name = ProfileModel.entityName
        profile.managedObjectClassName = NSStringFromClass(ProfileModel.self)

        let tab = NSEntityDescription()
        tab.name = TabDataModel.entityName
        tab.managedObjectClassName = NSStringFromClass(TabDataModel.self)

        let space = NSEntityDescription()
        space.name = SpaceModel.entityName
        space.managedObjectClassName = NSStringFromClass(SpaceModel.self)

        let urlRule = NSEntityDescription()
        urlRule.name = SpaceURLRule.entityName
        urlRule.managedObjectClassName = NSStringFromClass(SpaceURLRule.self)

        let settings = NSEntityDescription()
        settings.name = BrowserDataSettingsModel.entityName
        settings.managedObjectClassName = NSStringFromClass(BrowserDataSettingsModel.self)

        // TabDataModel relationships.
        let tabParent = NSRelationshipDescription()
        tabParent.name = "parent"
        tabParent.destinationEntity = tab
        tabParent.minCount = 0
        tabParent.maxCount = 1
        tabParent.isOptional = true
        tabParent.deleteRule = .nullifyDeleteRule

        let tabChildren = NSRelationshipDescription()
        tabChildren.name = "children"
        tabChildren.destinationEntity = tab
        tabChildren.minCount = 0
        tabChildren.maxCount = 0
        tabChildren.isOptional = true
        tabChildren.deleteRule = .cascadeDeleteRule

        tabParent.inverseRelationship = tabChildren
        tabChildren.inverseRelationship = tabParent

        let tabProfile = NSRelationshipDescription()
        tabProfile.name = "profile"
        tabProfile.destinationEntity = profile
        tabProfile.minCount = 0
        tabProfile.maxCount = 1
        tabProfile.isOptional = true
        tabProfile.deleteRule = .nullifyDeleteRule

        let profileTabs = NSRelationshipDescription()
        profileTabs.name = "tabs"
        profileTabs.destinationEntity = tab
        profileTabs.minCount = 0
        profileTabs.maxCount = 0
        profileTabs.isOptional = true
        profileTabs.deleteRule = .nullifyDeleteRule

        tabProfile.inverseRelationship = profileTabs
        profileTabs.inverseRelationship = tabProfile

        let profileBookmarkRoot = NSRelationshipDescription()
        profileBookmarkRoot.name = "bookmarkRoot"
        profileBookmarkRoot.destinationEntity = tab
        profileBookmarkRoot.minCount = 0
        profileBookmarkRoot.maxCount = 1
        profileBookmarkRoot.isOptional = true
        profileBookmarkRoot.deleteRule = .nullifyDeleteRule

        let spaceBookmarkRoot = NSRelationshipDescription()
        spaceBookmarkRoot.name = "bookmarkRoot"
        spaceBookmarkRoot.destinationEntity = tab
        spaceBookmarkRoot.minCount = 0
        spaceBookmarkRoot.maxCount = 1
        spaceBookmarkRoot.isOptional = true
        spaceBookmarkRoot.deleteRule = .nullifyDeleteRule

        tab.properties = [
            attribute("guid", .stringAttributeType),
            attribute("title", .stringAttributeType),
            attribute("index", .integer64AttributeType, defaultValue: 0),
            attribute("url", .URIAttributeType),
            attribute("favicon", .binaryDataAttributeType, optional: true),
            attribute("createdDate", .dateAttributeType),
            attribute("updatedDate", .dateAttributeType),
            attribute("type", .integer64AttributeType, defaultValue: 0),
            attribute("overrideTitle", .stringAttributeType, optional: true),
            attribute("isOpenned", .booleanAttributeType, defaultValue: false),
            attribute("isCreatedByChromium", .booleanAttributeType, defaultValue: false),
            attribute("needUpdateMetaData", .booleanAttributeType, defaultValue: false),
            attribute("spaceId", .stringAttributeType, optional: true),
            attribute("profileId", .stringAttributeType, optional: true),
            attribute("source", .integer64AttributeType, defaultValue: 0),
            attribute("secondaryUrl", .URIAttributeType, optional: true),
            attribute("secondaryTitle", .stringAttributeType, optional: true),
            attribute("splitPartnerGuid", .stringAttributeType, optional: true),
            attribute("lastSeen", .dateAttributeType, optional: true),
            attribute("pinLineageId", .stringAttributeType, optional: true),
            attribute("isPinnedTabDormant", .booleanAttributeType, defaultValue: false),
            tabParent,
            tabChildren,
            tabProfile,
        ]

        profile.properties = [
            attribute("guid", .stringAttributeType),
            attribute("profileId", .stringAttributeType),
            attribute("displayName", .stringAttributeType, optional: true),
            profileTabs,
            profileBookmarkRoot,
        ]
        profile.uniquenessConstraints = [["profileId"]]

        space.properties = [
            attribute("spaceId", .stringAttributeType),
            attribute("profileId", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("colorHex", .stringAttributeType),
            attribute("iconName", .stringAttributeType),
            attribute("sortOrder", .integer64AttributeType, defaultValue: 0),
            attribute("createdDate", .dateAttributeType),
            attribute("updatedDate", .dateAttributeType),
            spaceBookmarkRoot,
        ]
        space.uniquenessConstraints = [["spaceId"]]

        urlRule.properties = [
            attribute("id", .stringAttributeType),
            attribute("spaceId", .stringAttributeType),
            attribute("host", .stringAttributeType),
            attribute("pathPrefix", .stringAttributeType, optional: true),
            attribute("askBeforeRouting", .booleanAttributeType, defaultValue: false),
            attribute("sortOrder", .integer64AttributeType, defaultValue: 0),
            attribute("createdDate", .dateAttributeType),
        ]
        urlRule.uniquenessConstraints = [["id"]]

        settings.properties = [
            attribute("id", .stringAttributeType),
            attribute("pinnedTabScopeRawValue", .stringAttributeType),
        ]
        settings.uniquenessConstraints = [["id"]]

        let model = NSManagedObjectModel()
        model.entities = [profile, tab, space, urlRule, settings]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        if let defaultValue {
            attribute.defaultValue = defaultValue
        }
        return attribute
    }
}
