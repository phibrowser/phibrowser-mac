// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
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
        // 这个类里有用例驱动真的作用域迁移，而迁移的成功路径写 `UserDefaults.standard`——在
        // hosted 测试里那就是 Phi 自己的偏好域。
        clearPinnedTabScopeMirrorDefaults()
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

    // MARK: - applyBookmarkSyncBatchThrowing（Task 5a fix round）

    // F2 —— 要删的文件夹底下还有这一批从没点名过的孩子 ⇒ 整批回滚。
    //
    // 防的是什么：`deleteBookmarkBody` 就是一句 `context.delete(node)`，而
    // `TabDataModel.children` 带 `@Relationship(deleteRule: .cascade)`，所以一次删除会把
    // 整棵子树无声地带走。R-M3-3-17 要求引擎先把每一个不该死的后代删掉或提到 Space root，
    // 而最容易漏的正是本地独有、从没发布过的行（`syncId == nil`）——它们不在游标表里，
    // 按游标建提升清单的实现根本看不见它们。漏一个就在这个事务里静默死掉，没有计数也没有
    // 日志，用户只看见书签少了。
    func testDeletingAFolderThatStillHasUnnamedChildrenRollsTheWholeBatchBack() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        // 本机独有的一条：没有 syncId，所以任何按游标算出来的提升清单都不会包含它。
        let localOnly = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                               title: "Local only",
                                                               profileId: Self.profileId,
                                                               parentId: folder)
        let sibling = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                             title: "Sibling",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             syncId: "b-sibling")

        await assertThrows(.folderNotEmpty) {
            try await store.applyBookmarkSyncBatchThrowing([
                .update(guid: sibling, fields: BookmarkFieldPatch(title: "Renamed")),
                .delete(guid: folder),
            ])
        }

        // 整批回滚：那条本机独有的行还在，而同一批里排在 delete 之前的 update 也没落。
        let survivor = try row(localOnly, in: store)
        let folderRow = try row(folder, in: store)
        let siblingTitle = try row(sibling, in: store)?.title
        XCTAssertNotNil(survivor, "级联没有把这条从没发布过的行带走")
        XCTAssertNotNil(folderRow)
        XCTAssertEqual(siblingTitle, "Sibling", "部分成功不存在：同批的 update 也回滚了")
    }

    // F2 的另一半 —— 空文件夹照删，守卫不挡正常路径。
    func testDeletingAnEmptyFolderStillSucceeds() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)

        try await store.applyBookmarkSyncBatchThrowing([.delete(guid: folder)])

        let deleted = try row(folder, in: store)
        XCTAssertNil(deleted)
    }

    // G3 —— 同一批里先删孩子再删父，必须成功。
    //
    // 防的是什么：`.folderNotEmpty` 那道守卫是在**这一批已经删过该文件夹的后代之后**才问
    // 「它还有孩子吗」。它只有在「带待定变更的 fetch 会滤掉同一个块里刚 `context.delete`
    // 标记过的行」这条语义成立时才对，而本里程碑只编译不跑测试，§4.4 还有一句顺带的话说得
    // 正相反。赌错的代价是每一次远端删除非空文件夹都永远抛 `folderNotEmpty`，文件夹删除在
    // 任何设备上都再也落不了地。这条用例把那个赌注变成一条断言。
    func testDeletingAChildAndThenItsParentFolderInOneBatchSucceeds() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil)
        let child = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                           title: "Child",
                                                           profileId: Self.profileId,
                                                           parentId: folder)

        // 三相排序里 delete 相是子先于父，这正是引擎会交出来的次序。
        try await store.applyBookmarkSyncBatchThrowing([
            .delete(guid: child),
            .delete(guid: folder),
        ])

        let childRow = try row(child, in: store)
        let folderRow = try row(folder, in: store)
        XCTAssertNil(childRow)
        XCTAssertNil(folderRow, "守卫不该把一次合法的整棵删除挡下来")
    }

    // F3 —— 一条已经带着别的身份的行不许被重新认领。
    //
    // 防的是什么：覆盖写会让旧身份在本机瞬间失去对应行，而 §4.7 的差分对「没有本机行」的
    // 回答是发一条 tombstone——把对端那条实体删掉。一条行的身份只认领一次（§6.1 / 13d）。
    func testClaimingARowThatAlreadyCarriesADifferentIdentityRollsTheBatchBack() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil,
                                                          syncId: "b-first")

        await assertThrows(.rowAlreadyMapped) {
            try await store.applyBookmarkSyncBatchThrowing([
                .claim(guid: guid, syncId: "b-second"),
            ])
        }

        let identity = try row(guid, in: store)?.syncId
        XCTAssertEqual(identity, "b-first", "旧身份原封不动")
    }

    // F3 —— 认领一条还没有身份的行是正常路径；重复认领同一个 uuid 是幂等的。
    func testClaimingIsIdempotentForTheSameIdentityAndWritesAnUnclaimedRow() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        try await store.applyBookmarkSyncBatchThrowing([.claim(guid: guid, syncId: "b1")])
        try await store.applyBookmarkSyncBatchThrowing([.claim(guid: guid, syncId: "b1")])

        let identity = try row(guid, in: store)?.syncId
        XCTAssertEqual(identity, "b1")
    }

    // F7 —— 导入中的 Space 抛的是一个**专属**的 case，不是 `targetNotWritable`。
    //
    // 防的是什么：`targetNotWritable` 的含义是「Space 被删了或换了 Profile」，那是结构性
    // 失败；导入是瞬时状态，引擎该按停放处理、下一轮重试。两者混用之后 §11.2 的 `parked`
    // 计数分不清一次该重试的停放与一次不该重试的失败。
    func testABatchTargetingAnImportingSpaceThrowsTheDedicatedCase() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)
        ImportTargetLock.shared.begin(into: LocalStore.defaultSpaceId)
        defer { ImportTargetLock.shared.end(into: LocalStore.defaultSpaceId) }

        await assertThrows(.spaceImporting(spaceId: LocalStore.defaultSpaceId)) {
            try await store.applyBookmarkSyncBatchThrowing([
                .update(guid: guid, fields: BookmarkFieldPatch(title: "Renamed")),
            ])
        }

        let title = try row(guid, in: store)?.title
        XCTAssertEqual(title, "A", "锁住时一个字节都不落")
    }

    // MARK: - 差分定义域的那一次 fetch（R-exec-4）

    // F4 —— 孤儿根下面那条行不在快照的定义域里，但**在**差分的定义域里。
    //
    // 防的是什么：`allBookmarkModels` + `canonicalRootGuids` 的递归把孤儿根整棵排除（那是
    // 对的，它不该发布），可 §4.7 的 `locals` 要回答的是另一个问题——「这条身份在本机还有
    // 没有行」。拿快照当差分的定义域，这条行连同整棵子树会被判成删除，账户上那一片就没了，
    // 而本机其实一行都没少。
    func testIdentitiesUnderAnOrphanRootStayInTheDiffDomainAfterTheRootIsDetached() async throws {
        let store = try await makeStoreWithSpaces()
        let folder = try await store.createDirectoryThrowing(title: "Folder",
                                                             profileId: Self.profileId,
                                                             parentId: nil,
                                                             spaceId: Self.otherSpaceId,
                                                             syncId: "b-folder")
        _ = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                   title: "Child",
                                                   profileId: Self.profileId,
                                                   parentId: folder,
                                                   spaceId: Self.otherSpaceId,
                                                   syncId: "b-child")
        let rootGuid = try await rootGuid(in: store, spaceId: Self.otherSpaceId)
        try await store.detachBookmarkRootRelationshipForTesting(spaceId: Self.otherSpaceId)

        // 生产实现从 `allBookmarkModels(in:)` 这一次**未经根过滤**的行里取身份，再对同一份
        // 结果跑根递归产出快照（`AccountPhiBookmarkAccess.rebuildCache`），所以这里断言的
        // 正是它读的那两样东西。
        let observed = try await store.performBackgroundWriteAndWaitThrowing { context -> ObservedDomain in
            let models = try store.allBookmarkModels(in: context)
            return ObservedDomain(canonicalRoots: try store.canonicalRootGuids(in: context),
                                  identities: Set(models.compactMap(\.syncId)))
        }

        XCTAssertFalse(observed.canonicalRoots.contains(rootGuid),
                       "根的关系断了，递归再也够不到这棵子树")
        XCTAssertTrue(observed.identities.isSuperset(of: ["b-folder", "b-child"]),
                      "但这两条身份在本机还有行，绝不能被差分判成删除")
    }

    // MARK: - store 级的变化 publisher（§5.7）

    // CASE 6c.1 —— 一连串写入塌缩成一次下游信号，而且订阅当刻不发。
    //
    // 防抖住在 publisher 里（`LocalStore.changeSignalDebounce`），所以这里**直接订阅**，
    // 不再自己拼一级 `.debounce`——断言量的是出厂形状，不是用例里组装出来的形状。这也是四条
    // 用例里**唯一**用出厂窗口的一条：它量的就是窗口本身，别人把那个常量改了它要跟着动。
    //
    // 「订阅当刻不发」这一半必须在**安静期跑完之后**才量得到，不能只 `drainMainQueue()` 一下
    // 就断言 0：订阅当刻真发了一次的话，那一次也要过完整个防抖窗口才到得了 sink，0.05 秒之后
    // 去数它必然是 0，断言于是永远成立、永远发现不了问题。先空等过一整个窗口、确认零发射，
    // 再放那 30 条写入，两半才都是真的。
    func testBookmarkChangesPublisherCollapsesABurstOfWritesIntoOneSignal() async throws {
        let store = try await makeStoreWithSpaces()

        var received = 0
        let cancellable = store.bookmarkChangesPublisher().sink { _ in received += 1 }
        defer { cancellable.cancel() }

        // 一个字节都没写，跑过整个防抖窗口：seed 的那一次发射会在这里现形。
        waitPastDebounceWindow()
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "订阅当刻不发当前值")

        for index in 0..<30 {
            let url = try XCTUnwrap(URL(string: "https://example.com/burst-\(index)"))
            _ = try await store.createBookmarkThrowing(url: url,
                                                       title: "B\(index)",
                                                       profileId: Self.profileId,
                                                       parentId: nil)
        }
        waitPastDebounceWindow()

        let observed = received
        XCTAssertEqual(observed, 1, "30 次写入在防抖窗口里塌成一次推送")
    }

    // CASE 6c.2 —— favicon 与 lastSeen 的写入零发射。
    //
    // 防的是什么：这两个字段不在 `PhiLocalBookmark` 里，所以它们进不了值快照。真让它们进
    // 去，Task 10 的回填队列每写回一条图标就触发一次推送，而那次推送发的内容与账户上的
    // 完全相同——一台机器每轮空跑几十次提交。两次写都会发 `NSManagedObjectContextDidSave`
    // 并通过类型过滤、也确实会起防抖计时器，被吃掉的地方是安静期之后那一次投影比出来逐字节
    // 相同，不是过滤器。把 `updatedDate` 加进 `BookmarkChangeSnapshot` 这条用例立刻转红。
    func testBookmarkChangesPublisherIgnoresFaviconAndLastSeenWrites() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = try await store.createBookmarkThrowing(url: Self.exampleURL,
                                                          title: "A",
                                                          profileId: Self.profileId,
                                                          parentId: nil)

        var received = 0
        let cancellable = store.bookmarkChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        store.updateTabFavicon(guid, favicon: Data([0x01, 0x02, 0x03]))
        store.updateLastSeen(guid, seenAt: Date(timeIntervalSince1970: 1_700_000_000))
        // 先把两次写挤过写队列，再等窗口：不这么做，短窗口下这条用例会因为「写还没发生」
        // 而通过。
        await flushWrites(store)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 0, "图标与 lastSeen 不进快照，一次都不许发")
    }

    // 作用域本身进快照（T6c-6 / ledger 4）。
    //
    // 防的是什么：一次纯作用域翻转在**每一条** `TabDataModel` 上一个字节都不改，而「同步层
    // 这一轮认领哪一批行」整个换了。快照里只放行、把作用域留在外面的话，过滤器虽然放行了
    // 那次 `BrowserDataSettingsModel` 的 save，去重却会把它当成「什么都没变」吃掉，引擎于是
    // 永远不知道作用域翻过。
    //
    // 用例**一条 pin 都不建**，正是为了让这次翻转除了作用域之外无事可改：真有 pin 在，
    // `migratePinnedTabs` 会顺手改行，那样即使作用域不在快照里断言也照样通过。
    func testPinnedTabChangesPublisherEmitsWhenOnlyTheScopeChanges() async throws {
        let store = try await makeStoreWithSpaces()

        var received = 0
        let cancellable = store.pinnedTabChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        waitPastDebounceWindow(Self.shortDebounceWindow)
        let afterQuietPeriod = received
        XCTAssertEqual(afterQuietPeriod, 0, "订阅当刻不发当前值")

        try await store.changePinnedTabScope(to: .space,
                                             preferredProfileId: Self.profileId,
                                             preferredSpaceId: LocalStore.defaultSpaceId)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 1, "一行 pin 都没有，变的只有作用域——它必须在快照里")
    }

    // pin 侧的 6c.2。`updateLastSeen` 对 `.pinnedTab` 与 `.bookmark` 都写，所以这条路在 pin
    // 上同样成立，而 Task 10 的图标回填两种行都碰。
    func testPinnedTabChangesPublisherIgnoresFaviconAndLastSeenWrites() async throws {
        let store = try await makeStoreWithSpaces()
        let guid = "pin-favicon"
        try await store.createPinnedTabThrowing(guid: guid,
                                                url: Self.exampleURL,
                                                title: "A",
                                                profileId: Self.profileId)

        var received = 0
        let cancellable = store.pinnedTabChangesPublisher(debounceWindow: Self.shortDebounceWindow)
            .sink { _ in received += 1 }
        defer { cancellable.cancel() }

        store.updateTabFavicon(guid, favicon: Data([0x04, 0x05, 0x06]))
        store.updateLastSeen(guid, seenAt: Date(timeIntervalSince1970: 1_700_000_000))
        await flushWrites(store)
        waitPastDebounceWindow(Self.shortDebounceWindow)

        let observed = received
        XCTAssertEqual(observed, 0, "图标与 lastSeen 不进快照，一次都不许发")
    }

    // MARK: - Fixtures

    private struct ObservedDomain: Sendable {
        let canonicalRoots: Set<String>
        let identities: Set<String>
    }

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

    /// 量「窗口之外的性质」的用例用的短窗口：去重、过滤、作用域进不进快照都与窗口多长无关，
    /// 没有理由为每次断言各空转两秒。**只有 CASE 6c.1 用出厂的
    /// `LocalStore.changeSignalDebounce`**——它量的就是窗口本身。
    private static let shortDebounceWindow: TimeInterval = 0.2

    /// 跑过给定的防抖窗口再多留一点，让主队列上的投递有机会落地。
    private func waitPastDebounceWindow(
        _ window: TimeInterval = LocalStore.changeSignalDebounce
    ) {
        RunLoop.main.run(until: Date().addingTimeInterval(window + 0.6))
    }

    /// 把 fire-and-forget 的写入（`updateTabFavicon` / `updateLastSeen`）挤过那条 FIFO 写队列。
    ///
    /// 断言「零发射」的用例**必须**先做这一步，否则短窗口下它会因为写入根本还没落地而通过
    /// ——一条永远绿、什么都没测的用例。
    private func flushWrites(_ store: LocalStore) async {
        await store.performBackgroundWriteAndWait { _ in }
    }
}
