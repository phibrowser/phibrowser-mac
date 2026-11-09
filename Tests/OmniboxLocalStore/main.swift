import Foundation
import SwiftData

typealias TabDataModel = TabDataModelSchemaV14.TabDataModel
typealias ProfileModel = TabDataModelSchemaV14.ProfileModel
typealias BrowserDataSettingsModel = TabDataModelSchemaV14.BrowserDataSettingsModel
enum TabDataType: Int { case tab, pinnedTab, bookmark, bookmarkFolder }
enum PinnedTabScope: String { case space, profile, app }
enum LocalStoreWriteError: Error { case storeUnavailable }
func AppLogError(_ message: String) { fatalError(message) }
func AppLogDebug(_ message: @autoclosure () -> String) {}

/* PRODUCTION_ACTOR */

// Only account/configuration/UI setup is replaced. The actor, FIFO drain and
// read/write/selection methods below are extracted from shipping LocalStore.
final class LocalStore {
    static let willCloseNotification = Notification.Name("LocalStore.willClose")
    static let omniboxNativeDataWillChangeNotification =
        Notification.Name("LocalStore.omniboxNativeDataWillChange")
    private var container: ModelContainer?
    private var writeActor: LocalStoreActor?
    private var writeJobContinuation: AsyncStream<() async -> Void>.Continuation?
    private let omniboxReadAdmission = OmniboxReadAdmission()

    init() throws {
        let container = try ModelContainer(for: Schema(TabDataModelSchemaV14.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        self.container = container
        writeActor = LocalStoreActor(modelContainer: container)
        /* PRODUCTION_FIFO */
    }

    @MainActor private func releaseStoreForAccountDirectoryRemoval() {
        writeActor = nil
        container = nil
    }

    /* PRODUCTION_METHODS */
    /* PRODUCTION_SCOPE */
}

@main
enum OmniboxLocalStoreTests {
    enum Refusal: Error { case expected, stale }

    @MainActor
    static func main() async throws {
        let store = try LocalStore()
        let coordinator: OmniboxNativeQueryCoordinator<UInt64> = store.makeOmniboxQueryCoordinator()
        let first = try await epoch(store, coordinator)
        let second = try await epoch(store, coordinator)
        precondition(first == second, "A read must not advance write authority")
        do {
            _ = try await store.performBackgroundWriteAndWaitThrowing(precondition: {
                throw Refusal.expected
            }, { _ -> Bool in fatalError("A refused write must not enter its body") })
            fatalError("Expected precondition refusal")
        } catch Refusal.expected {}
        let afterRefusal = try await epoch(store, coordinator)
        precondition(afterRefusal == first + 1,
                     "A failed precondition must still invalidate older selections")
        await store.performBackgroundWriteAndWait { _ in }
        let afterNoOp = try await epoch(store, coordinator)
        precondition(afterNoOp == afterRefusal + 1)

        var dispatched = false
        do {
            let _: Bool = try await store.performOmniboxSelection(
                ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max),
                validate: { _, current in
                    guard current == first else { throw Refusal.stale }
                    return true
                }, dispatch: { _ in dispatched = true; return true })
            fatalError("Old authority must not dispatch")
        } catch Refusal.stale {}
        precondition(!dispatched)

        let cancelledAfterValidation = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
        do {
            let _: Bool = try await store.performOmniboxSelection(ticket: cancelledAfterValidation,
                validate: { _, _ in
                    cancelledAfterValidation.cancel()
                    return true
                }, dispatch: { _ in
                    fatalError("Cancellation after validation must prevent MainActor dispatch")
                })
            fatalError("Expected cancellation at dispatch boundary")
        } catch OmniboxNativeQueryError.cancelled {}

        let accepted: Bool = try await store.performOmniboxSelection(
            ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max),
            validate: { _, current in
                precondition(current == afterNoOp)
                return true
            }, dispatch: { _ in
                dispatched = true
                store.performBackgroundWrite { _ in }
                return true
            })
        precondition(accepted && dispatched)
        let afterSelection = try await epoch(store, coordinator)
        precondition(afterSelection == afterNoOp + 1,
                     "Selection must not save/advance epoch; its queued follow-up write must")
        try await scopedSnapshot(store)
        let _: Bool = try await store.performFinalBackgroundOperationAndClose { _ in true }
        do {
            _ = try await epoch(store, coordinator)
            fatalError("Closed store must reject read")
        } catch OmniboxNativeQueryError.unavailable {}
        print("OmniboxLocalStore: read/write/selection/close integration passed")
    }

    @MainActor
    static func epoch(_ store: LocalStore,
                      _ coordinator: OmniboxNativeQueryCoordinator<UInt64>) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { continuation in
            coordinator.submit(ticket: OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max),
                read: { try await store.readForOmnibox { _, epoch in epoch } },
                completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }

    @MainActor
    static func scopedSnapshot(_ store: LocalStore) async throws {
        await store.performBackgroundWriteAndWait { context in
            let a = ProfileModel(profileId: "A")
            let b = ProfileModel(profileId: "B")
            context.insert(a)
            context.insert(b)
            let fixtures: [(String, ProfileModel?, String?, TabDataType)] = [
                ("bookmark", a, "S", TabDataType.bookmark),
                ("foreign-bookmark", b, "S", .bookmark),
                ("other-space", a, "T", .bookmark),
                ("pin", a, "S", .pinnedTab),
                ("profile-pin", a, nil, .pinnedTab),
                ("app-pin", nil, nil, .pinnedTab),
                ("split-left", a, "S", .pinnedTab),
                ("split-right", a, "S", .pinnedTab)
            ]
            for (id, profile, space, type) in fixtures {
                let row = TabDataModel(title: id, guid: id, index: 0,
                    url: URL(string: "https://example.com/\(id)")!, favicon: nil,
                    createdDate: Date(), updatedDate: Date())
                context.insert(row)
                row.profile = profile
                row.profileId = profile?.profileId
                row.spaceId = space
                row.type = type.rawValue
                if id == "split-left" { row.splitPartnerGuid = "split-right" }
            }
        }
        let coordinator: OmniboxNativeQueryCoordinator<OmniboxNativeSearchSnapshot> = store.makeOmniboxQueryCoordinator()
        let storedScopeSnapshot: OmniboxNativeSearchSnapshot = try await withCheckedThrowingContinuation { continuation in
            let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
            coordinator.submit(ticket: ticket, read: {
                try await store.readOmniboxSnapshot(profileID: "A", spaceID: "S", ticket: ticket)
            }, completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
        precondition(storedScopeSnapshot.pinScope == "profile")
        precondition(storedScopeSnapshot.pins.entities.map(\.entityID) == ["profile-pin"])
        let snapshot = try await snapshot(store, coordinator, pinScope: .space)
        precondition(snapshot.bookmarks.entities.map(\.entityID) == ["bookmark"])
        precondition(snapshot.pins.entities.map(\.entityID) == ["pin"],
                     "Both halves of a one-way split must be excluded")
        precondition(snapshot.bookmarks.status == .complete && snapshot.pins.status == .complete,
                     "Foreign scope records must not consume native candidate budget")
        let profile = try await self.snapshot(store, coordinator, pinScope: .profile)
        precondition(profile.pins.entities.map(\.entityID) == ["profile-pin"])
        let app = try await self.snapshot(store, coordinator, pinScope: .app)
        precondition(app.pins.entities.map(\.entityID) == ["app-pin"])
        let selected = snapshot.pins.entities[0]
        let selectionTicket = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
        let validated = try await store.performOmniboxSelection(ticket: selectionTicket,
            validate: { context, epoch in
                try OmniboxNativeSnapshotReader.validate(selected, expectedEpoch: snapshot.mutationEpoch,
                    expectedPinScope: snapshot.pinScope, context: context, profileID: "A", spaceID: "S",
                    pinScope: .space, epoch: epoch, ticket: selectionTicket)
            }, dispatch: { $0 })
        precondition(validated == selected)
        do {
            let _: OmniboxNativeEntity = try await store.performOmniboxSelection(ticket: selectionTicket,
                validate: { context, epoch in
                    try OmniboxNativeSnapshotReader.validate(selected, expectedEpoch: snapshot.mutationEpoch,
                        expectedPinScope: snapshot.pinScope, context: context, profileID: "B", spaceID: "S",
                        pinScope: .space, epoch: epoch, ticket: selectionTicket)
                }, dispatch: { _ in fatalError("Foreign scoped selection must never dispatch") })
            fatalError("Expected foreign scope refusal")
        } catch OmniboxNativeQueryError.unavailable {}
        await store.performBackgroundWriteAndWait { context in
            let profiles = try! context.fetch(FetchDescriptor<ProfileModel>())
            let row = TabDataModel(title: "Extra", guid: "extra", index: 0,
                url: URL(string: "https://example.com/extra")!, favicon: nil,
                createdDate: Date(), updatedDate: Date())
            context.insert(row)
            row.profile = profiles.first { $0.profileId == "A" }
            row.spaceId = "S"
            row.type = TabDataType.bookmark.rawValue
        }
        let overflow = try await self.snapshot(store, coordinator, pinScope: .space)
        precondition(overflow.bookmarks.status == .limitExceeded && overflow.bookmarks.entities.isEmpty,
                     "An incomplete kind must not publish its first N records")
        precondition(overflow.pins.status == .complete && overflow.pins.entities.count == 1,
                     "One kind's budget must not consume the other kind's quota")
        let afterUnrelatedWrite = try await store.performOmniboxSelection(ticket: selectionTicket,
            validate: { context, epoch in
                try OmniboxNativeSnapshotReader.validate(selected, expectedEpoch: snapshot.mutationEpoch,
                    expectedPinScope: snapshot.pinScope, context: context, profileID: "A", spaceID: "S",
                    pinScope: .space, epoch: epoch, ticket: selectionTicket)
            }, dispatch: { $0 })
        precondition(afterUnrelatedWrite == selected, "An unrelated write must not make a valid row stale")
        let tiny = try await self.snapshot(store, coordinator, pinScope: .space,
            limits: .init(candidatesPerKind: 1024, bytesPerKind: 1))
        precondition(tiny.bookmarks.status == .limitExceeded && tiny.pins.status == .limitExceeded)
        let full = try await self.snapshot(store, coordinator, pinScope: .space,
            limits: .init(candidatesPerKind: 1024, bytesPerKind: 512 * 1024))
        let exactPinBytes = try JSONEncoder().encode(full.pins).count
        let exact = try await self.snapshot(store, coordinator, pinScope: .space,
            limits: .init(candidatesPerKind: 1024, bytesPerKind: exactPinBytes))
        precondition(exact.pins.status == .complete)
        let short = try await self.snapshot(store, coordinator, pinScope: .space,
            limits: .init(candidatesPerKind: 1024, bytesPerKind: exactPinBytes - 1))
        precondition(short.pins.status == .limitExceeded && short.pins.entities.isEmpty)

        let metadataTicket = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
        let decorated = try full.withRuntimeMetadata(ticket: metadataTicket) { entity in
            (entity.kind == .pin, entity.kind == .pin ? "https://example.com/current" : nil)
        }
        precondition(decorated.pins.entities.first?.isOpen == true)
        precondition(decorated.pins.entities.first?.currentURL == "https://example.com/current")
        precondition(decorated.pins.entities.first?.url == full.pins.entities.first?.url,
                     "Runtime metadata cannot replace the persisted action target")
        let activePin = full.pins.entities.first?.entityID
        let excluded = full.excluding(entityID: activePin)
        precondition(excluded.pins.entities.count == full.pins.entities.count - 1 &&
                     !excluded.pins.entities.contains { $0.entityID == activePin },
                     "The focused entity is not offered")
        precondition(excluded.bookmarks.entities.count == full.bookmarks.entities.count)
        let metadataOverflow = try full.withRuntimeMetadata(ticket: metadataTicket) { entity in
            (entity.kind == .pin, entity.kind == .pin ? String(repeating: "x", count: 512 * 1024) : nil)
        }
        precondition(metadataOverflow.pins.status == .limitExceeded && metadataOverflow.pins.entities.isEmpty)
        precondition(metadataOverflow.bookmarks.status == .complete,
                     "Post-decoration overflow remains isolated to its kind")
        let cancelledMetadata = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
        do {
            _ = try full.withRuntimeMetadata(ticket: cancelledMetadata) { _ in
                cancelledMetadata.cancel()
                return (false, nil)
            }
            fatalError("Cancelled metadata must not publish a partial snapshot")
        } catch OmniboxNativeQueryError.cancelled {}
    }

    @MainActor
    static func snapshot(_ store: LocalStore,
                         _ coordinator: OmniboxNativeQueryCoordinator<OmniboxNativeSearchSnapshot>,
                         pinScope: PinnedTabScope,
                         limits: OmniboxNativeSnapshotReader.Limits = .init(candidatesPerKind: 1, bytesPerKind: 512 * 1024)
    ) async throws -> OmniboxNativeSearchSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            let ticket = OmniboxQueryTicket(deadlineUptimeNanoseconds: UInt64.max)
            coordinator.submit(ticket: ticket, read: {
                try await store.readForOmnibox { context, epoch in
                    try OmniboxNativeSnapshotReader.read(context: context, profileID: "A", spaceID: "S",
                        pinScope: pinScope, epoch: epoch, ticket: ticket,
                        limits: limits)
                }
            }, completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
        }
    }
}
