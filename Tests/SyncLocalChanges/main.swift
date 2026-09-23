import Foundation
import CoreData
import SwiftData
import Combine

// Compile the production publishers against a real, isolated Core Data store. The
// snapshot seam substitutes only the app's SwiftData model fetches, avoiding Phi launch.
struct TabDataModel { static let entityName = "TabDataModel" }
struct BrowserDataSettingsModel { static let entityName = "BrowserDataSettingsModel" }
struct SpaceURLRule { static let entityName = "SpaceURLRule" }
enum TabDataType: Int { case tab, pinnedTab, bookmark, bookmarkFolder }

final class LocalStore {
    static let changeSignalDebounce = 0.15
    let mainContext: NSManagedObjectContext?
    init() throws {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = TabDataModel.entityName
        entity.managedObjectClassName = "NSManagedObject"
        entity.properties = ["type", "title", "lastSeen", "favicon", "updatedDate"].map { name in
            let field = NSAttributeDescription()
            field.name = name
            field.attributeType = name == "type" ? .integer64AttributeType : .stringAttributeType
            field.isOptional = name != "title"
            return field
        }
        model.entities = [entity]
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        mainContext = context
    }
    func snapshot(_ type: TabDataType) -> [String]? {
        let request = NSFetchRequest<NSManagedObject>(entityName: TabDataModel.entityName)
        request.predicate = NSPredicate(format: "type == %d", type.rawValue)
        return try? mainContext!.fetch(request).map { $0.value(forKey: "title") as? String ?? "" }.sorted()
    }
    func bookmarkChangeSnapshot() -> [String]? { snapshot(.bookmark) }
    func pinnedTabChangeSnapshot() -> [String]? { snapshot(.pinnedTab) }
    func urlRuleChangeSnapshot() -> [String]? { [] }
    /* PRODUCTION_PUBLISHERS */
}
/* PRODUCTION_SAVE_EVIDENCE */

@main struct SyncLocalChangesTests {
    @MainActor static func main() throws {
        for kind in [TabDataType.bookmark, .pinnedTab] {
            try run(kind)
        }
        try runSwiftDataEvidence()
        print("PASS: local-only writes stay silent; real edits invalidate before debounce; reversions drain")
    }

    @MainActor static func run(_ kind: TabDataType) throws {
        let store = try LocalStore()
        let context = store.mainContext!
        let row = NSEntityDescription.insertNewObject(forEntityName: TabDataModel.entityName, into: context)
        row.setValue(kind.rawValue, forKey: "type")
        row.setValue("Original", forKey: "title")
        try context.save()
        var invalidations = 0
        var rounds = 0
        let callback = { invalidations += 1 }
        let publisher = kind == .bookmark
            ? store.bookmarkChangesPublisher(onChangeDetected: callback)
            : store.pinnedTabChangesPublisher(onChangeDetected: callback)
        let subscription = publisher.sink { rounds += 1 }
        defer { subscription.cancel() }

        for field in ["lastSeen", "favicon", "updatedDate"] {
            row.setValue("local", forKey: field)
            try context.save()
        }
        drain(0.3)
        check(invalidations == 0, "\(kind): local-only saves must not mark sync pending (got \(invalidations))")
        check(rounds == 0, "\(kind): local-only saves must not schedule work")

        row.setValue(nil, forKey: "title")
        do {
            try context.save()
            check(false, "Fixture must reject a missing required title")
        } catch { context.rollback() }
        drain(0.02)
        check(invalidations == 0, "\(kind): failed writes must not invalidate sync")

        row.setValue("First edit", forKey: "title")
        try context.save()
        drain(0.02)
        check(invalidations == 1, "\(kind): real edit must invalidate before debounce")
        check(rounds == 0, "\(kind): expensive work must remain debounced")
        row.setValue("Second edit", forKey: "title")
        try context.save()
        drain(0.02)
        check(invalidations == 2, "\(kind): later save must invalidate a round started since the first edit")
        drain(0.3)
        check(rounds == 1, "\(kind): edit burst must schedule one round")

        row.setValue("Temporary edit", forKey: "title")
        try context.save()
        row.setValue("Second edit", forKey: "title")
        try context.save()
        drain(0.3)
        check(rounds == 2, "\(kind): edit then revert must drain its early pending invalidation")
    }

    /// The real current SwiftData schema must expose the same field names as the
    /// Core Data evidence reader; this also catches notification timing assumptions.
    @MainActor static func runSwiftDataEvidence() throws {
        let container = try ModelContainer(for: TabDataModelSchemaV13.TabDataModel.self,
            TabDataModelSchemaV13.ProfileModel.self, TabDataModelSchemaV13.SpaceModel.self,
            TabDataModelSchemaV13.SpaceURLRule.self, TabDataModelSchemaV13.BrowserDataSettingsModel.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let row = TabDataModelSchemaV13.TabDataModel(title: "Original", guid: "bookmark", index: 0,
            url: URL(string: "https://example.com")!, favicon: nil, createdDate: Date(), updatedDate: Date())
        row.type = TabDataType.bookmark.rawValue
        context.insert(row)
        try context.save()
        let evidence = SyncSaveEvidence { object in
            object.entity.name == TabDataModel.entityName ? SyncSaveEvidence.bookmarkFields : nil
        }
        var saves: [Bool] = []
        let subscription = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .compactMap { evidence.consume($0) }
            .sink { saves.append($0) }
        defer { subscription.cancel() }
        row.lastSeen = Date()
        row.updatedDate = Date()
        try context.save()
        row.favicon = Data([1, 2, 3])
        try context.save()
        row.title = "Changed"
        row.lastSeen = Date()
        try context.save()
        check(saves == [false, false, true], "SwiftData must distinguish local-only saves from mixed content edits")
        let rule = TabDataModelSchemaV13.SpaceURLRule(spaceId: "space", host: "example.com", sortOrder: 0)
        context.insert(rule)
        try context.save()
        let ruleEvidence = SyncSaveEvidence { object in
            object.entity.name == SpaceURLRule.entityName ? SyncSaveEvidence.ruleFields : nil
        }
        var ruleSaves: [Bool] = []
        let ruleSubscription = NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave)
            .compactMap { ruleEvidence.consume($0) }
            .sink { ruleSaves.append($0) }
        defer { ruleSubscription.cancel() }
        rule.pendingLocalEdit = true
        rule.mergePartnerSyncId = "partner"
        try context.save()
        rule.host = "new.example.com"
        try context.save()
        check(ruleSaves == [false, true], "URL-rule bookkeeping must not invalidate sync; routing edits must")

        context.delete(row)
        try context.save()
        check(saves.last == true, "SwiftData deletion must invalidate sync immediately")
    }

    @MainActor static func drain(_ duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
    static func check(_ passed: Bool, _ message: String) {
        guard passed else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
