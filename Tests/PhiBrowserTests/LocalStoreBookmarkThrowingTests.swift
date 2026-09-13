// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

// 书签写入口的 throwing 兄弟（§4.9）。这些用例共同防的是同一件事：
// `performBackgroundWriteAndWaitThrowing` 只在块抛错或 `save()` 抛错时才抛，
// 静默 return 与成功落地在调用方看来一模一样，而引擎会为一次根本没发生的写入
// 落下 `reconciled` / `server` 基线——那条行此后既不会被差分判成删除（它还在），
// 也不会被快照重发（基线说它已同步）。
@MainActor
final class LocalStoreBookmarkThrowingTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - moveBookmarkThrowing

    // CASE 2a.1
    func testMoveBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarkThrowing(guid: "no-such-guid",
                                                 toParentGuid: folder,
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.2
    func testMoveBookmarkThrowingThrowsWhenTargetIsTheRoot() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let rootGuid = try await rootGuid(in: store, spaceId: LocalStore.defaultSpaceId)

        await assertThrows(.rowIsRoot) {
            try await store.moveBookmarkThrowing(guid: rootGuid,
                                                 toParentGuid: folder,
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.3
    func testMoveBookmarkThrowingThrowsWhenTargetParentDoesNotResolve() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarkThrowing(guid: bookmark,
                                                 toParentGuid: "no-such-folder",
                                                 inSpaceId: LocalStore.defaultSpaceId,
                                                 index: 0)
        }
    }

    // CASE 2a.20 —— 一次调用完成重打子树 + 重挂到任意文件夹。既有的两个原语都表达不了
    // 这件事：`moveBookmark` 从行自己身上取 Space，`moveBookmarks` 永远落到目标 Space 的
    // root。而「移动是一次字段变化，不是删+建」是 R-D6-14 ③ 的要求。
    func testMoveBookmarkThrowingRetagsSubtreeAndReparentsIntoAnyFolder() async throws {
        let store = try await makeStoreWithSpaces()
        let source = try await store.createDirectoryThrowing(title: "Source",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: LocalStore.defaultSpaceId)
        let child = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                           title: "Child",
                                                           profileId: Self.profileId,
                                                           parentId: source,
                                                           spaceId: LocalStore.defaultSpaceId)
        let target = try await store.createDirectoryThrowing(title: "Target",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: Self.otherSpaceId)

        try await store.moveBookmarkThrowing(guid: source,
                                             toParentGuid: target,
                                             inSpaceId: Self.otherSpaceId,
                                             index: 0)
        drainMainQueue()

        let movedFolder = try XCTUnwrap(try row(source, in: store))
        let movedChild = try XCTUnwrap(try row(child, in: store))
        XCTAssertEqual(movedFolder.spaceId, Self.otherSpaceId)
        XCTAssertEqual(movedChild.spaceId, Self.otherSpaceId)
        XCTAssertEqual(movedChild.guid, child)
        XCTAssertEqual(movedFolder.parent?.guid, target)
    }

    // MARK: - moveBookmarksThrowing

    // CASE 2a.4 —— 空清单是调用方的 bug，不是一次成功的空操作。
    func testMoveBookmarksThrowingThrowsOnAnEmptyGuidList() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.noCandidateSurvived) {
            try await store.moveBookmarksThrowing(guids: [],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.5
    func testMoveBookmarksThrowingThrowsWhenTargetSpaceIsNotWritable() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.targetNotWritable) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: "no-such-space",
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.6 —— 只有在 body 改走 `existingBookmarkRoot` 之后才可达：用
    // `createIfNeeded: true` 的实现会悄悄重建一个空 root 并「成功」返回。
    func testMoveBookmarksThrowingThrowsWhenTargetRootIsMissing() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        await assertThrows(.rowNotFound) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // CASE 2a.7 —— 两处 `continue` 今天完全静默（连日志都没有），整批被跳过时旧代码
    // 「成功」返回，同步层据此写下基线。
    func testMoveBookmarksThrowingThrowsWhenEveryCandidateIsSkipped() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              spaceId: Self.otherSpaceId)

        await assertThrows(.noCandidateSurvived) {
            try await store.moveBookmarksThrowing(guids: [bookmark],
                                                  toSpaceId: Self.otherSpaceId,
                                                  profileId: Self.profileId)
        }
    }

    // MARK: - updateBookmarkThrowing

    // CASE 2a.8
    func testUpdateBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.rowNotFound) {
            try await store.updateBookmarkThrowing("no-such-guid",
                                                   profileId: Self.profileId,
                                                   title: "B",
                                                   url: nil)
        }
    }

    // CASE 2a.9 —— 一个既有的半应用状态：标题先写进 model，URL 守卫才 return。
    // 抽 body 时必须先校验后写。
    func testUpdateBookmarkThrowingRollsBackTheTitleWhenThePrimaryURLIsInvalid() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.invalidURL) {
            try await store.updateBookmarkThrowing(bookmark,
                                                   profileId: Self.profileId,
                                                   title: "B",
                                                   url: .some("::not a url::"))
        }
        drainMainQueue()

        let stored = try XCTUnwrap(try row(bookmark, in: store))
        XCTAssertEqual(stored.title, "A")
    }

    // CASE 2a.10
    func testUpdateBookmarkThrowingThrowsWhenTheSecondaryURLIsInvalid() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        await assertThrows(.invalidURL) {
            try await store.updateBookmarkThrowing(bookmark,
                                                   profileId: Self.profileId,
                                                   title: nil,
                                                   url: nil,
                                                   secondaryUrl: .some(.some("::not a url::")))
        }
    }

    // CASE 2a.16b —— §4.9 规则 1 要求 `allowsEmptyTitle` 贯穿 create 与 update。
    func testUpdateBookmarkThrowingHonoursAllowsEmptyTitleOnBothSides() async throws {
        let store = try await makeStoreWithSpaces()
        let allowed = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                             title: "A",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        try await store.updateBookmarkThrowing(allowed,
                                               profileId: Self.profileId,
                                               title: .some(""),
                                               url: nil,
                                               allowsEmptyTitle: true)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(allowed, in: store)).title, "")

        let replaced = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        try await store.updateBookmarkThrowing(replaced,
                                               profileId: Self.profileId,
                                               title: .some(""),
                                               url: nil,
                                               allowsEmptyTitle: false)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(replaced, in: store)).title,
                       Self.exampleURL.absoluteString)
    }

    // MARK: - deleteBookmarkThrowing

    // CASE 2a.11 —— 这条守卫今天完全静默。
    func testDeleteBookmarkThrowingThrowsWhenRowIsMissing() async throws {
        let store = try await makeStoreWithSpaces()

        await assertThrows(.rowNotFound) {
            try await store.deleteBookmarkThrowing("no-such-guid", profileId: Self.profileId)
        }
    }

    // CASE 2a.12
    func testDeleteBookmarkThrowingThrowsWhenTargetIsTheRoot() async throws {
        let store = try await makeStoreWithSpaces()
        let rootGuid = try await rootGuid(in: store, spaceId: LocalStore.defaultSpaceId)

        await assertThrows(.rowIsRoot) {
            try await store.deleteBookmarkThrowing(rootGuid, profileId: Self.profileId)
        }
    }

    // MARK: - createBookmarkThrowing

    // CASE 2a.13 —— `resolveParent` 在父解析不到 / 不是文件夹时无日志地落回 Space root。
    // 对 UI 这是善意容错；对同步层它意味着把一条书签建到了账户没要求的位置，而下一轮差分
    // 会把这个位置当成本机意图发回去，覆盖对端正确的 `parent_uuid`。
    func testCreateBookmarkThrowingThrowsWhenTheParentIsNotAFolder() async throws {
        let store = try await makeStoreWithSpaces()
        let leaf = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "Leaf",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        await assertThrows(.rowNotFound) {
            _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                       title: "Child",
                                                       profileId: Self.profileId,
                                                       parentId: leaf)
        }
    }

    // CASE 2a.15 —— 全部创建路径都经 `insertBookmarkNode`，它把空标题替换成 URL 字符串。
    func testCreateBookmarkThrowingKeepsAnEmptyTitleWhenAllowed() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              allowsEmptyTitle: true)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).title, "")
    }

    // CASE 2a.16 —— UI 路径行为不变。
    func testCreateBookmarkThrowingReplacesAnEmptyTitleWhenNotAllowed() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "",
                                                              profileId: Self.profileId,
                                                              parentId: nil,
                                                              allowsEmptyTitle: false)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).title,
                       Self.exampleURL.absoluteString)
    }

    // CASE 2a.17 —— `createBookmark` 对 URL 跑 `URLProcessor.processUserInput`，那是给
    // 用户输入准备的（会把不像 URL 的东西变成搜索）。throwing 兄弟收 `URL`，不走那条路径。
    func testCreateBookmarkThrowingDoesNotRunUserInputProcessing() async throws {
        let store = try await makeStoreWithSpaces()
        let escaped = try XCTUnwrap(URL(string: "https://example.com/a%20b?q=c%20d"))
        let bookmark = try await store.createBookmarkThrowing(url: escaped,
                                                              title: "Escaped",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        drainMainQueue()

        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).url.absoluteString,
                       escaped.absoluteString)
    }

    // MARK: - contentUpdatedDate

    // CASE 2a.18 —— `updateLastSeen` / `updateTabFavicon` 会把 `updatedDate` 往前推，而
    // 「往前推」正是让一个没人动过的本机旧值赢下对端刚做的编辑的那个方向（§6.2）。
    func testContentEditsStampContentUpdatedDateAndReadsDoNot() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)
        drainMainQueue()
        XCTAssertNil(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)

        try await store.updateBookmarkThrowing(bookmark,
                                               profileId: Self.profileId,
                                               title: "B",
                                               url: nil)
        drainMainQueue()
        let afterEdit = try XCTUnwrap(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)

        store.updateLastSeen(bookmark)
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate, afterEdit)

        store.updateTabFavicon(bookmark, favicon: Data([1, 2, 3]))
        drainMainQueue()
        XCTAssertEqual(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate, afterEdit)
    }

    // CASE 2a.19 —— 把标题改成同样文字的一次保存，不该让这一行赢下对端的编辑。
    func testWritingTheSameTitleIsNotAnEdit() async throws {
        let store = try await makeStoreWithSpaces()
        let bookmark = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                              title: "A",
                                                              profileId: Self.profileId,
                                                              parentId: nil)

        try await store.updateBookmarkThrowing(bookmark,
                                               profileId: Self.profileId,
                                               title: "A",
                                               url: nil)
        drainMainQueue()

        XCTAssertNil(try XCTUnwrap(try row(bookmark, in: store)).contentUpdatedDate)
    }

    // MARK: - fire-and-forget 入口

    // CASE 2a.14 —— 抽 body 时把 UI 路径也改成抛出，会让每一次用户侧的竞态变成一次崩溃。
    func testFireAndForgetUpdateStillSwallowsAMissingRow() async throws {
        let store = try await makeStoreWithSpaces()

        store.updateBookmark("no-such-guid",
                             profileId: Self.profileId,
                             title: "B",
                             url: nil)
        drainMainQueue()

        XCTAssertNil(try row("no-such-guid", in: store))
    }

    // MARK: - 批量插入与次键

    // CASE 2a.21 —— `insert(node:to:at:in:)` 每插一行就 fetch 一次该父的孩子并对整个
    // 兄弟列表跑一次 `normalizeIndexes`：250 条落进同一个文件夹是 250 次 fetch 加 250 次
    // 全量重排，全在同一个事务里、整轮都放不掉。
    func testBulkInsertNormalizesEachTouchedParentExactlyOnce() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Bulk",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let rows = (0..<20).map { position in
            LocalStore.BulkBookmarkInsert(guid: "bulk-\(position)",
                                          title: "Bulk \(position)",
                                          url: Self.exampleURL,
                                          index: position,
                                          isFolder: false,
                                          parentGuid: folder,
                                          spaceId: LocalStore.defaultSpaceId,
                                          profileId: Self.profileId,
                                          createdDate: Date())
        }

        let normalizations = try await store.insertBookmarksBulkThrowingCountingNormalizations(rows)
        drainMainQueue()

        XCTAssertEqual(normalizations, 1)
        XCTAssertEqual(store.fetchBookmarks(parentId: folder, profileId: Self.profileId).count, 20)
    }

    // CASE 2a.22 —— 一条被排除的兄弟（停放 / 待删 / 还没身份）会留着过期的 `index` 与新写
    // 的撞上；`children(of:)` 今天只按单个 `SortDescriptor(\.index)` 排，撞上的两行顺序
    // 随 fetch 而变，于是每轮两条无谓的 commit。
    func testChildrenOrderingHasAStableSecondaryKey() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        try await store.insertBookmarkWithIndexForTesting(guid: "BBBB", parentGuid: folder, index: 1)
        try await store.insertBookmarkWithIndexForTesting(guid: "AAAA", parentGuid: folder, index: 1)
        drainMainQueue()

        let ordered = store.fetchBookmarks(parentId: folder, profileId: Self.profileId)
        XCTAssertEqual(ordered.map(\.guid), ["AAAA", "BBBB"])
    }

    // MARK: - existingBookmarkRoot

    // CASE 2a.23 —— `bookmarkRoot` 在 `guard createIfNeeded` 之前就会写
    // `space?.bookmarkRoot = primary` 并 `context.delete(duplicate)`。放进每轮都跑的读
    // 路径等于每轮都可能在主 context 上删行。
    func testExistingBookmarkRootNeitherHealsNorWrites() async throws {
        let store = try await makeStoreWithSpaces()
        _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                   title: "A",
                                                   profileId: Self.profileId,
                                                   parentId: nil,
                                                   spaceId: Self.otherSpaceId)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        let observed = try await store.performBackgroundWriteAndWaitThrowing { context -> ObservedRead in
            let before = try store.allBookmarkModels(in: context).count
            let root = try store.existingBookmarkRoot(profileId: Self.profileId,
                                                      spaceId: Self.otherSpaceId,
                                                      in: context)
            let after = try store.allBookmarkModels(in: context).count
            return ObservedRead(hasChanges: context.hasChanges,
                                rootWasFound: root != nil,
                                countBefore: before,
                                countAfter: after)
        }

        XCTAssertFalse(observed.hasChanges)
        XCTAssertFalse(observed.rootWasFound)
        XCTAssertEqual(observed.countBefore, observed.countAfter)
    }

    // MARK: - Fixtures

    private struct ObservedRead: Sendable {
        let hasChanges: Bool
        let rootWasFound: Bool
        let countBefore: Int
        let countAfter: Int
    }

    private static let profileId = LocalStore.defaultProfileId
    private static let otherSpaceId = "space-b"
    private static let exampleURL = URL(string: "https://example.com/a")!

    private func makeStore() throws -> LocalStore {
        let directory = try makeTemporaryStoreDirectory()
        return LocalStore(account: Account(userID: "test-user"),
                          storeDirectoryURL: directory,
                          presentsCompatibilityAlerts: false)
    }

    private func makeStoreWithSpaces() async throws -> LocalStore {
        let store = try makeStore()
        try await store.createSpaceForTesting(spaceId: LocalStore.defaultSpaceId,
                                              profileId: Self.profileId)
        try await store.createSpaceForTesting(spaceId: Self.otherSpaceId,
                                              profileId: Self.profileId)
        return store
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func rootGuid(in store: LocalStore, spaceId: String) async throws -> String {
        let guid = try await store.performBackgroundWriteAndWaitThrowing { context -> String? in
            try store.existingBookmarkRoot(profileId: Self.profileId,
                                           spaceId: spaceId,
                                           in: context)?.guid
        }
        return try XCTUnwrap(guid)
    }

    private func row(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.guid == guid }
        )
        return try context.fetch(descriptor).first
    }

    // 断言是 autoclosure，先取值再断言。
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

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
