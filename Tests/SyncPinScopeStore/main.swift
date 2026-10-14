import Foundation
import SwiftData

// Runs the production pin scope generation fence (B-3 stage 1, design 3.3) against a real in-memory
// SwiftData store of the shipping schema: `changePinnedTabScope` with its in-flight count and its
// transaction, `pinScopeGeneration`, and `applyPinSyncBatchThrowing` with its body are sliced from
// LocalStore+PinnedTabScope.swift. The
// row-moving helpers the slices call are stubs: the migration's pin reshaping and the per-op bodies
// other than create are not under test here.
typealias TabDataModel = TabDataModelSchemaV13.TabDataModel
typealias BrowserDataSettingsModel = TabDataModelSchemaV13.BrowserDataSettingsModel
enum TabDataType: Int { case tab = 0, pinnedTab = 1, bookmark = 2, bookmarkFolder = 3 }

/// The production in-flight count's two calls, with the Migration flag recording the count every time
/// `changePinnedTabScope` reads it (the queueing check, then the in-job check).
@MainActor
enum BrowserDataActivity {
    static var runIsInFlight: [Bool] = []
    static var pinScopeJobsInFlight = 0
    static var countAtFlagReads: [Int] = []
    static var migrationRunIsInFlight: Bool {
        countAtFlagReads.append(pinScopeJobsInFlight)
        return runIsInFlight.isEmpty ? false : runIsInFlight.removeFirst()
    }
    static func pinScopeJobDidBegin() { pinScopeJobsInFlight += 1 }
    static func pinScopeJobDidEnd() { pinScopeJobsInFlight -= 1 }
}

/* PRODUCTION_TYPES */

final class LocalStore {
    static let defaultProfileId = "Default"
    static let defaultSpaceId = "default-space"
    let container: ModelContainer
    let pinScopeGenerationCounter = PinScopeGenerationCounter()
    /// Every stubbed row-moving helper the slices reached, in order.
    var helperCalls: [String] = []

    init() throws {
        container = try ModelContainer(for: Schema(TabDataModelSchemaV13.models),
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// The write actor's contract (`LocalStoreWriteActor.performThrowing`): save on return, roll back on
    /// a throw. One fresh context per job, as each job sees the committed store.
    private func perform<Result>(_ block: (ModelContext) throws -> Result) throws -> Result {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let result = try block(context)
            try context.save()
            return result
        } catch {
            context.rollback()
            throw error
        }
    }

    @MainActor
    func performBackgroundWriteAndWaitThrowing<Result>(
        _ block: @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        try perform(block)
    }

    @MainActor
    func performBackgroundWriteAndWaitThrowing<Result>(
        precondition: @escaping @MainActor () throws -> Void,
        _ block: @escaping (ModelContext) throws -> Result
    ) async throws -> Result {
        try precondition()
        return try perform(block)
    }

    // Committed state, read through a fresh context.
    func committedPins() -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        return try! ModelContext(container).fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw }))
    }
    func committedScope() -> PinnedTabScope { try! pinnedTabScope(in: ModelContext(container)) }
}

extension LocalStore {
    /* PRODUCTION_STORE_METHODS */

    // Stubs for the row-moving helpers.
    private func migratePinnedTabs(from sourceScope: PinnedTabScope, to targetScope: PinnedTabScope,
                                   preferredProfileId: String?, preferredSpaceId: String?,
                                   in context: ModelContext) throws {
        helperCalls.append("migrate \(sourceScope.rawValue)->\(targetScope.rawValue)")
    }
    private func refuseIfImportingPins(_ ops: [PinApplyOp], in context: ModelContext) throws {}
    func createPinnedTabBody(guid: String, url: URL, title: String, profileId: String, spaceId: String,
                             index: Int?, lineageId: String?, createdDate: Date?, source: Int,
                             contentUpdatedDate: Date? = nil, in context: ModelContext) throws {
        helperCalls.append("create \(guid)")
        let tab = TabDataModel(title: title, guid: guid, index: index ?? 0, url: url, favicon: nil,
                               createdDate: createdDate ?? Date(), updatedDate: Date())
        tab.type = TabDataType.pinnedTab.rawValue
        tab.profileId = profileId
        tab.spaceId = spaceId
        tab.pinLineageId = lineageId
        tab.source = source
        tab.contentUpdatedDate = contentUpdatedDate
        context.insert(tab)
    }
    private func relineagePinnedTabBody(guid: String, newLineageId: String, in context: ModelContext) throws {
        fatalError("not exercised")
    }
    private func pinnedTabRow(with guid: String, in context: ModelContext) throws -> TabDataModel? {
        fatalError("not exercised")
    }
    private func pinnedTab(_ tab: TabDataModel, belongsTo scope: PinnedTabScope) -> Bool { fatalError("not exercised") }
    private func owner(of tab: TabDataModel, at scope: PinnedTabScope) -> PinnedTabOwner { fatalError("not exercised") }
    private func updateActivePinnedTabBody(guid: String, url: URL?, title: String?, in context: ModelContext) throws {
        fatalError("not exercised")
    }
    private func applyPinSplitPartnerBody(guid: String, partnerLineageId: String?, in context: ModelContext) throws {
        fatalError("not exercised")
    }
    private func clearSplitPartnerBackReferenceBody(of tab: TabDataModel, in context: ModelContext) throws {
        fatalError("not exercised")
    }
    private func removeActivePinnedTabBody(guid: String, in context: ModelContext) throws { fatalError("not exercised") }
}

func create(_ guid: String, profileId: String? = "Default", spaceId: String? = nil) -> PinApplyOp {
    .create(PhiLocalPin(lineageId: "lineage-\(guid)", guid: guid, spaceId: spaceId, profileId: profileId, index: 0,
                        title: guid, url: URL(string: "https://example.com/\(guid)")!,
                        splitPartnerLineageId: nil, source: 0, createdDate: Date(timeIntervalSince1970: 1),
                        contentUpdatedDate: nil, isDormant: false))
}

func expectRefusal(_ body: () async throws -> Void, _ message: String) async {
    do {
        try await body()
        preconditionFailure("\(message): the batch landed")
    } catch let error as LocalStoreWriteError {
        precondition(error == .scopeChangedSinceSample, "\(message): \(error)")
    } catch {
        preconditionFailure("\(message): \(error)")
    }
}

@main
struct PinScopeStoreTests {
    @MainActor
    static func main() async throws {
        try await staleGenerationWritesNothing()
        try await roundTripIsDetected()
        try await sameGenerationOtherScopeWritesNothing()
        try await scopeJobIsCountedInFlight()
    }

    @MainActor
    static func staleGenerationWritesNothing() async throws {
        let store = try LocalStore()
        let sampled = store.pinScopeGeneration
        precondition(sampled == 0 && store.committedScope() == .profile)

        // A migration that changes the row scope moves the generation, in its own transaction.
        try await store.changePinnedTabScope(to: .app)
        precondition(store.pinScopeGeneration == sampled + 1 && store.committedScope() == .app)
        // One that finds the row already there does not.
        try await store.changePinnedTabScope(to: .app)
        precondition(store.pinScopeGeneration == sampled + 1, "a no-op migration must not move the generation")

        // A batch planned at the old generation writes nothing: no helper ran, no row, scope unchanged.
        store.helperCalls = []
        await expectRefusal({
            try await store.applyPinSyncBatchThrowing([create("p1", profileId: nil)], expectedGeneration: sampled,
                                                      expectedScope: .app)
        }, "stale generation")
        precondition(store.helperCalls.isEmpty, "refused before any write: \(store.helperCalls)")
        precondition(store.committedPins().isEmpty && store.committedScope() == .app)

        // Control: the same batch at the current generation lands.
        try await store.applyPinSyncBatchThrowing([create("p1", profileId: nil)],
                                                  expectedGeneration: store.pinScopeGeneration, expectedScope: .app)
        precondition(store.helperCalls == ["create p1"] && store.committedPins().map(\.guid) == ["p1"])

        // A create shaped for another scope is refused at the current generation too (not re-shaped).
        store.helperCalls = []
        await expectRefusal({
            try await store.applyPinSyncBatchThrowing([create("p2", profileId: "Default")],
                                                      expectedGeneration: store.pinScopeGeneration, expectedScope: .app)
        }, "create shaped for profile scope under app scope")
        precondition(store.helperCalls.isEmpty && store.committedPins().map(\.guid) == ["p1"])
        print("PASS store fence: a stale expectedGeneration throws scopeChangedSinceSample and writes nothing; the current one lands; a no-op migration keeps the generation")
    }

    @MainActor
    static func roundTripIsDetected() async throws {
        let store = try LocalStore()
        try await store.changePinnedTabScope(to: .profile)
        let sampledScope = try store.committedScope()
        let sampled = store.pinScopeGeneration

        // X to Y to X between two samples: both scope values match the sample, the generation does not.
        try await store.changePinnedTabScope(to: .space)
        try await store.changePinnedTabScope(to: .profile)
        precondition(store.helperCalls == ["migrate profile->space", "migrate space->profile"], "\(store.helperCalls)")
        precondition(store.committedScope() == sampledScope, "the round trip restores the scope value")
        precondition(store.pinScopeGeneration == sampled + 2, "the round trip moved the generation twice")

        store.helperCalls = []
        await expectRefusal({
            try await store.applyPinSyncBatchThrowing([create("p1")], expectedGeneration: sampled,
                                                      expectedScope: sampledScope)
        }, "round trip")
        precondition(store.helperCalls.isEmpty && store.committedPins().isEmpty)
        print("PASS store fence: a scope round trip X to Y to X between two samples is detected by the generation and the batch writes nothing")
    }

    @MainActor
    static func sameGenerationOtherScopeWritesNothing() async throws {
        // Review round 1 F5 (d'): the round sampled the current generation but rows of another scope
        // (the main context had not merged the migration). The row scope check refuses the batch.
        let store = try LocalStore()
        try await store.changePinnedTabScope(to: .app)
        store.helperCalls = []
        await expectRefusal({
            try await store.applyPinSyncBatchThrowing([.delete(guid: "p-old")],
                                                      expectedGeneration: store.pinScopeGeneration,
                                                      expectedScope: .profile)
        }, "current generation, stale row scope")
        precondition(store.helperCalls.isEmpty && store.committedPins().isEmpty && store.committedScope() == .app)
        // Control: the same generation with the row's own scope lands.
        try await store.applyPinSyncBatchThrowing([create("p1", profileId: nil)],
                                                  expectedGeneration: store.pinScopeGeneration, expectedScope: .app)
        precondition(store.committedPins().map(\.guid) == ["p1"])
        print("PASS store fence: the current generation with a different row scope throws scopeChangedSinceSample and writes nothing")
    }

    @MainActor
    static func scopeJobIsCountedInFlight() async throws {
        // Review round 1 F2/F4: the count is up from the queueing check through the in-job check (the
        // main-to-write-actor hop) and back to zero once the job returns, thrown or not.
        let store = try LocalStore()
        BrowserDataActivity.countAtFlagReads = []
        try await store.changePinnedTabScope(to: .space)
        precondition(BrowserDataActivity.countAtFlagReads == [0, 1],
                     "queueing check before the count, in-job check inside it: \(BrowserDataActivity.countAtFlagReads)")
        precondition(BrowserDataActivity.pinScopeJobsInFlight == 0, "released after the job")

        // A run that starts during the hop: the in-job check refuses, and the count is still released.
        BrowserDataActivity.countAtFlagReads = []
        BrowserDataActivity.runIsInFlight = [false, true]
        do {
            try await store.changePinnedTabScope(to: .app)
            preconditionFailure("the in-job check must refuse")
        } catch let error as LocalStoreWriteError {
            precondition(error == .migrationInFlight)
        }
        precondition(BrowserDataActivity.countAtFlagReads == [0, 1] && BrowserDataActivity.pinScopeJobsInFlight == 0)
        precondition(store.committedScope() == .space)

        // Refused at queueing: never counted.
        BrowserDataActivity.countAtFlagReads = []
        BrowserDataActivity.runIsInFlight = [true]
        do {
            try await store.changePinnedTabScope(to: .app)
            preconditionFailure("the queueing check must refuse")
        } catch let error as LocalStoreWriteError {
            precondition(error == .migrationInFlight)
        }
        precondition(BrowserDataActivity.countAtFlagReads == [0] && BrowserDataActivity.pinScopeJobsInFlight == 0)
        print("PASS store in-flight count: held from the queueing check until the job returns, released on every exit")
    }
}
