// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

@MainActor
final class LocalStorePinnedTabTransferTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    func testSpaceTransferPreservesPersistedFieldsAndDeletesSourceAtomically() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        let createdDate = Date(timeIntervalSince1970: 100)
        let updatedDate = Date(timeIntervalSince1970: 200)
        let lastSeen = Date(timeIntervalSince1970: 300)
        try insertPinned(
            in: store,
            guid: "source-pin",
            profileId: "Default",
            spaceId: "space-a",
            title: "Source",
            url: "https://origin.example",
            createdDate: createdDate,
            updatedDate: updatedDate,
            configure: { model in
                model.favicon = Data([1, 2, 3])
                model.overrideTitle = "Override"
                model.isOpenned = true
                model.isCreatedByChromium = true
                model.needUpdateMetaData = true
                model.source = TabSource.arc.rawValue
                model.secondaryUrl = URL(string: "https://secondary.example")
                model.secondaryTitle = "Secondary"
                model.lastSeen = lastSeen
                model.pinLineageId = "source-lineage"
            }
        )

        let result = try await store.transferPinnedTab(
            guid: "source-pin",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let copied = try XCTUnwrap(store.getAllPinnedTabs(for: "Default", spaceId: "space-b").first)
        XCTAssertEqual(result.guidMapping["source-pin"], copied.guid)
        XCTAssertNotEqual(copied.guid, "source-pin")
        XCTAssertEqual(copied.title, "Source")
        XCTAssertEqual(copied.url.absoluteString, "https://origin.example")
        XCTAssertEqual(copied.favicon, Data([1, 2, 3]))
        XCTAssertEqual(copied.overrideTitle, "Override")
        XCTAssertTrue(copied.isOpenned)
        XCTAssertTrue(copied.isCreatedByChromium)
        XCTAssertTrue(copied.needUpdateMetaData)
        XCTAssertEqual(copied.source, TabSource.arc.rawValue)
        XCTAssertEqual(copied.secondaryUrl?.absoluteString, "https://secondary.example")
        XCTAssertEqual(copied.secondaryTitle, "Secondary")
        XCTAssertEqual(copied.createdDate, createdDate)
        XCTAssertEqual(copied.lastSeen, lastSeen)
        XCTAssertEqual(copied.pinLineageId, "source-lineage")
        XCTAssertEqual(copied.profileId, "Default")
        XCTAssertEqual(copied.spaceId, "space-b")
    }

    func testSpaceTransferMovesWholeSplitAndNormalizesPartnerGuids() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0,
            configure: { $0.splitPartnerGuid = "right" }
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].guid, result.guidMapping["left"])
        XCTAssertEqual(target[1].guid, result.guidMapping["right"])
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    func testLivePartnerHintTransfersPairBeforePersistedLinksAreWritten() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "left",
            profileId: "Default",
            spaceId: "space-a",
            title: "Left",
            url: "https://left.example",
            index: 0
        )
        try insertPinned(
            in: store,
            guid: "right",
            profileId: "Default",
            spaceId: "space-a",
            title: "Right",
            url: "https://right.example",
            index: 1
        )

        let result = try await store.transferPinnedTab(
            guid: "left",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            partnerGuidHint: "right",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(target.count, 2)
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    func testSharedProfileOwnerReordersWithoutReplacingPhysicalGuid() async throws {
        let store = try makeStoreWithSpaces()
        for (index, guid) in ["a", "b", "c"].enumerated() {
            try insertPinned(
                in: store,
                guid: guid,
                profileId: "Default",
                spaceId: nil,
                title: guid.uppercased(),
                url: "https://\(guid).example",
                index: index
            )
        }

        let result = try await store.transferPinnedTab(
            guid: "a",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2
        )
        drainMainQueue()

        XCTAssertEqual(result.guidMapping, ["a": "a"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["b", "c", "a"]
        )

        let rawGapResult = try await store.transferPinnedTab(
            guid: "b",
            sourceProfileId: "Default",
            sourceSpaceId: "space-a",
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 2,
            destinationIndexIncludesSourceUnit: true
        )
        drainMainQueue()

        XCTAssertEqual(rawGapResult.guidMapping, ["b": "b"])
        XCTAssertEqual(
            store.getAllPinnedTabs(for: "Default", spaceId: "space-b").map(\.guid),
            ["c", "b", "a"]
        )
    }

    func testNormalSplitCreationUsesTargetSpaceOwnerAndPersistsPair() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        let result = try await store.createPinnedTabsForCrossWindowDrop(
            [
                PinnedTabCreationInput(
                    tabId: 10,
                    title: "Left",
                    url: "https://left.example",
                    partnerTabId: 11
                ),
                PinnedTabCreationInput(
                    tabId: 11,
                    title: "Right",
                    url: "https://right.example",
                    partnerTabId: 10
                ),
            ],
            targetProfileId: "Default",
            targetSpaceId: "space-b",
            destinationIndex: 0
        )
        drainMainQueue()

        XCTAssertTrue(result.isSplit)
        XCTAssertTrue(store.getAllPinnedTabs(for: "Default", spaceId: "space-a").isEmpty)
        let target = store.getAllPinnedTabs(for: "Default", spaceId: "space-b")
        XCTAssertEqual(
            target.map(\.guid),
            [try XCTUnwrap(result.guidByTabId[10]), try XCTUnwrap(result.guidByTabId[11])]
        )
        XCTAssertEqual(target[0].splitPartnerGuid, target[1].guid)
        XCTAssertEqual(target[1].splitPartnerGuid, target[0].guid)
    }

    // MARK: - 作用域迁移的合并键（R-M3-3-16）

    // CASE 2b.1 —— `contentSignature(for:)` 今天是 `(title, url, favicon)`，而
    // `mergeCandidates` 只在签名相等时才合并同 lineage 的两份副本。D9 让 favicon 留在
    // 设备本地并各自回填，所以两台机器对同一条 pin 合法地持有不同的 favicon 字节——于是
    // 同一次账户级作用域变更在 A 上合出 1 行、在 B 上合出 2 行，两台机器的 pin 数量从此
    // 不同，且各自都认为自己是对的。
    func testScopeMigrationMergesLineageAcrossDifferingFaviconBytes() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "p1",
            profileId: "Default",
            spaceId: "space-a",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = Data([0x1])
            }
        )
        try insertPinned(
            in: store,
            guid: "p2",
            profileId: "Default",
            spaceId: "space-b",
            title: "Shared",
            url: "https://shared.example",
            configure: { model in
                model.pinLineageId = "L"
                model.favicon = nil
            }
        )

        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()

        let merged = store.getAllPinnedTabs(for: "Default").filter { $0.pinLineageId == "L" }
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - updateActivePinnedTabThrowing / removeActivePinnedTabThrowing

    // CASE 2b.2 —— 「guid 不在当前作用域」是 fail-closed 的设计、不是 bug，但对同步层
    // 必须可见：引擎会把一次没发生的写当成落地并写下基线。
    func testUpdateActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.updateActivePinnedTabThrowing(
                guid: "space-b-pin",
                url: URL(string: "https://edited.example"),
                title: "Edited"
            )
        }
    }

    // CASE 2b.3 —— 与 2b.2 是两个不同的入口，各测一次（§4.9 穷举的是「两个
    // `…ActivePinnedTab` 各一条」）。
    func testRemoveActivePinnedTabThrowingRejectsARowOutsideTheActiveScope() async throws {
        let store = try await makeStoreWithAnInactiveSpaceBPin()

        await assertThrows(.rowNotInActiveScope) {
            try await store.removeActivePinnedTabThrowing(guid: "space-b-pin")
        }
    }

    // CASE 2b.4
    func testRemoveActivePinnedTabThrowingThrowsWhenTheRowIsMissing() async throws {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)

        await assertThrows(.rowNotFound) {
            try await store.removeActivePinnedTabThrowing(guid: "no-such-guid")
        }
    }

    // 一条属于 `space-b` 的 pin，在一次以 `space-a` 为 preferred 的作用域变更之后被留成
    // 作用域外的备份行：`migratePinnedTabs` 保留源行、另建新的 Profile 形状物理行，所以
    // 一个在这次交接期间排好队的 UI 动作仍然会带着旧 guid 打过来。
    private func makeStoreWithAnInactiveSpaceBPin() async throws -> LocalStore {
        let store = try makeStoreWithSpaces()
        try await store.changePinnedTabScope(to: .space)
        try insertPinned(
            in: store,
            guid: "space-b-pin",
            profileId: "Default",
            spaceId: "space-b",
            title: "B",
            url: "https://b.example"
        )
        try await store.changePinnedTabScope(
            to: .profile,
            preferredProfileId: "Default",
            preferredSpaceId: "space-a"
        )
        drainMainQueue()
        return store
    }

    private func assertThrows(_ expected: LocalStoreWriteError,
                              file: StaticString = #filePath,
                              line: UInt = #line,
                              _ block: () async throws -> Void) async {
        do {
            try await block()
            XCTFail("Expected \(expected) to be thrown.", file: file, line: line)
        } catch let error as LocalStoreWriteError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeStoreWithSpaces() throws -> LocalStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(
            account: Account(userID: UUID().uuidString),
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: "Default"))
        context.insert(SpaceModel(
            spaceId: "space-a",
            profileId: "Default",
            name: "A",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 0
        ))
        context.insert(SpaceModel(
            spaceId: "space-b",
            profileId: "Default",
            name: "B",
            colorHex: "#000000",
            iconName: "star",
            sortOrder: 1
        ))
        try context.save()
        return store
    }

    private func insertPinned(
        in store: LocalStore,
        guid: String,
        profileId: String,
        spaceId: String?,
        title: String,
        url: String,
        index: Int = 0,
        createdDate: Date = Date(),
        updatedDate: Date = Date(),
        configure: (TabDataModel) -> Void = { _ in }
    ) throws {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProfileModel>()).first(where: {
                $0.profileId == profileId
            })
        )
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: createdDate,
            updatedDate: updatedDate
        )
        model.dataType = .pinnedTab
        model.profile = profile
        model.profileId = profileId
        model.spaceId = spaceId
        model.pinLineageId = guid
        configure(model)
        context.insert(model)
        try context.save()
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
