// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import Phi

@MainActor
final class SpaceStoreLifetimeTests: XCTestCase {
    private var accounts: [Account] = []
    private var directories: [URL] = []
    private var subscriptions = Set<AnyCancellable>()
    private var previousBoundAccount: Any?

    override func setUp() {
        previousBoundAccount = UserDefaults.standard.object(forKey: SpaceManager.lastBoundAccountUserIDKey)
    }

    override func tearDown() async throws {
        subscriptions.removeAll()
        for account in accounts { try await account.localStorage.closeForAccountDirectoryRemoval() }
        accounts.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        UserDefaults.standard.set(previousBoundAccount, forKey: SpaceManager.lastBoundAccountUserIDKey)
    }

    func testRetainedPresentationAndRoutingRemainReadableAfterTerminalClose() async throws {
        let account = try makeAccount(name: "Guest")
        let store = account.localStorage
        let space = try XCTUnwrap(store.getAllSpaces().first)
        let rules = store.getAllURLRules()
        // The callbacks deliberately retain the production read API's output.
        let binding = Binding(get: { space.name }, set: { _ in })
        let geometry = SpacesStripGeometry()
        let layout: (CGRect) -> Void = { geometry.pipFrames[space.spaceId] = $0 }

        try await store.closeForAccountDirectoryRemoval()
        XCTAssertNil(store.getMainContext())
        XCTAssertEqual(binding.wrappedValue, "Guest")
        XCTAssertEqual(space.profileId, "Guest-profile")
        layout(CGRect(x: 1, y: 2, width: 24, height: 24))
        XCTAssertEqual(geometry.pipFrames[LocalStore.defaultSpaceId]?.width, 24)
        XCTAssertEqual(URLRouter.resolve(url: URL(string: "https://guest.example")!, rules: rules),
                       LocalStore.defaultSpaceId)
    }

    func testSameStoreUpdatesObservableObjectAndTargetStoreReplacesIt() async throws {
        let source = try makeAccount(name: "Guest")
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: source)
        let original = try XCTUnwrap(manager.spaces.first)
        let initialDelivery = expectation(description: "Initial store subscription")
        manager.$spaces.dropFirst().prefix(1).sink { _ in initialDelivery.fulfill() }.store(in: &subscriptions)
        await fulfillment(of: [initialDelivery], timeout: 5)
        subscriptions.removeAll()

        let changed = expectation(description: "Observable Space changes")
        original.$content.dropFirst().filter { $0.name == "Renamed" }.prefix(1)
            .sink { _ in changed.fulfill() }.store(in: &subscriptions)
        source.localStorage.updateSpace(spaceId: original.spaceId, name: "Renamed")
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertTrue(manager.spaces.first === original)
        XCTAssertEqual(original.name, "Renamed")

        try await source.localStorage.closeForAccountDirectoryRemoval()
        let target = try makeAccount(name: "Target")
        manager.bind(to: target)
        let replacement = try XCTUnwrap(manager.spaces.first)
        XCTAssertEqual(original.spaceId, replacement.spaceId)
        XCTAssertFalse(original === replacement)
        XCTAssertEqual(original.name, "Renamed")
        XCTAssertEqual(replacement.name, "Target")
        XCTAssertEqual(replacement.profileId, "Target-profile")
        XCTAssertEqual(manager.allRules.first?.host, "target.example")
    }

    func testReopenedAccountUsesNewPresentationAndRejectsRetiredActions() async throws {
        let account = try makeAccount(name: "Guest")
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: account)
        let original = try XCTUnwrap(manager.spaces.first)
        try await account.localStorage.closeForAccountDirectoryRemoval()
        // Rollback can reopen the same directory on the same Account instance.
        let reopened = LocalStore(account: account, storeDirectoryURL: directories[0],
                                  presentsCompatibilityAlerts: false)
        account.localStorage = reopened
        manager.bind(to: account)
        let replacement = try XCTUnwrap(manager.spaces.first)
        XCTAssertFalse(original === replacement)
        XCTAssertNotEqual(original.storeIdentifier, replacement.storeIdentifier)
        XCTAssertEqual(replacement.name, "Guest")
        XCTAssertFalse(manager.acceptsStoreAction(from: original.storeIdentifier))
        XCTAssertTrue(manager.acceptsStoreAction(from: replacement.storeIdentifier))
    }

    func testEmptyTargetImmediatelyReplacesOldSpacesAndRules() async throws {
        let source = try makeAccount(name: "Guest")
        let target = try makeAccount(name: nil)
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: source)
        XCTAssertFalse(manager.spaces.isEmpty)
        XCTAssertFalse(manager.allRules.isEmpty)
        try await source.localStorage.closeForAccountDirectoryRemoval()
        manager.bind(to: target)
        XCTAssertTrue(manager.spaces.isEmpty)
        XCTAssertTrue(manager.allRules.isEmpty)
        XCTAssertEqual(manager.storeIdentifier, target.localStorage.identifier)
    }

    func testOldActionsCannotModifySameIDInReplacementStore() async throws {
        let source = try makeAccount(name: "Guest")
        let target = try makeAccount(name: "Target")
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: source)
        let oldSpace = try XCTUnwrap(manager.spaces.first)
        try await source.localStorage.closeForAccountDirectoryRemoval()
        XCTAssertFalse(manager.acceptsStoreAction(from: oldSpace.storeIdentifier))
        manager.bind(to: target)
        manager.renameSpace(spaceId: oldSpace.spaceId, to: "Stale write",
                            expectedStoreIdentifier: oldSpace.storeIdentifier)
        do {
            try await manager.applyRuleEdits(upserts: [], deletedIds: ["rule"],
                                             expectedStoreIdentifier: oldSpace.storeIdentifier)
            XCTFail("Expected the retired store action to be rejected.")
        } catch {
            XCTAssertEqual(error as? LocalStoreWriteError, .storeUnavailable)
        }
        try await flush(target.localStorage)
        XCTAssertEqual(target.localStorage.getAllSpaces().first?.name, "Target")
        XCTAssertEqual(target.localStorage.getAllURLRules().first?.host, "target.example")

        manager.renameSpace(spaceId: oldSpace.spaceId, to: "Current write",
                            expectedStoreIdentifier: target.localStorage.identifier)
        try await flush(target.localStorage)
        XCTAssertEqual(target.localStorage.getAllSpaces().first?.name, "Current write")
    }

    func testQueuedSourceSaveCannotReplaceNewAccountPresentation() async throws {
        let source = try makeAccount(name: "Guest")
        let target = try makeAccount(name: "Target")
        let manager = SpaceManager(observeAccountChanges: false)
        manager.bind(to: source)
        let ready = expectation(description: "Source subscription installed")
        manager.$spaces.dropFirst().prefix(1).sink { _ in ready.fulfill() }.store(in: &subscriptions)
        await fulfillment(of: [ready], timeout: 5)
        subscriptions.removeAll()

        let context = try XCTUnwrap(source.localStorage.getMainContext())
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<SpaceModel>()).first)
        row.name = "Queued old value"
        try context.save() // Queues the source publisher's receive(on:) work.
        manager.bind(to: target)
        let targetReady = expectation(description: "Target subscription installed")
        manager.$spaces.dropFirst().prefix(1).sink { _ in targetReady.fulfill() }.store(in: &subscriptions)
        await fulfillment(of: [targetReady], timeout: 5)
        XCTAssertEqual(manager.spaces.map(\.name), ["Target"])
        XCTAssertTrue(manager.spaces.allSatisfy { $0.storeIdentifier == target.localStorage.identifier })
    }

    func testClosedStorePublishersCompleteAndIgnoreOtherStoreSaves() async throws {
        let source = try makeAccount(name: "Guest")
        let target = try makeAccount(name: "Target")
        var spaceDeliveries = 0
        var ruleDeliveries = 0
        var completed = 0
        source.localStorage.spacesPublisher().sink(receiveCompletion: { _ in completed += 1 },
            receiveValue: { _ in spaceDeliveries += 1 }).store(in: &subscriptions)
        source.localStorage.urlRulesPublisher().sink(receiveCompletion: { _ in completed += 1 },
            receiveValue: { _ in ruleDeliveries += 1 }).store(in: &subscriptions)
        try await source.localStorage.closeForAccountDirectoryRemoval()
        XCTAssertEqual(completed, 2)
        let before = (spaceDeliveries, ruleDeliveries)
        target.localStorage.updateSpace(spaceId: LocalStore.defaultSpaceId, name: "Changed")
        try await flush(target.localStorage)
        XCTAssertEqual(spaceDeliveries, before.0)
        XCTAssertEqual(ruleDeliveries, before.1)
    }

    private func makeAccount(name: String?) throws -> Account {
        let account = Account(userID: "space-lifetime-test-\(UUID().uuidString)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        directories.append(account.userDataStorage)
        let store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        accounts.append(account)
        if let name {
            let context = try XCTUnwrap(store.getMainContext())
            context.insert(SpaceModel(spaceId: LocalStore.defaultSpaceId, profileId: "\(name)-profile",
                                      name: name, colorHex: "#123456", iconName: "circle", sortOrder: 0))
            context.insert(SpaceURLRule(spaceId: LocalStore.defaultSpaceId,
                                        host: "\(name.lowercased()).example", sortOrder: 0))
            try context.save()
        }
        return account
    }

    private func flush(_ store: LocalStore) async throws {
        _ = try await store.performBackgroundWriteAndWaitThrowing { _ in true }
    }
}
