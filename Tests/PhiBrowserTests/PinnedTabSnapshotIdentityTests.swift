// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// 侧栏那本 diffable 快照的**标识符契约**：一条标识符在数据源还握着它的那段时间里不许变。
///
/// 现场（Mac B 2026-09-15 01:20:27，build 825）：用户在设置里把固定标签页作用域从 Profile
/// 切到 Space，两秒后取消固定了一条 pin，应用在 `-[__NSDiffableDataSource
/// _applyDifferencesFromSnapshot:]` 里抛出未捕获的 ObjC 异常而崩溃。库是干净的——没有重复
/// guid、没有重复 `(space, lineage)`，所以那次重复只存在于内存里。
///
/// 成因不是「一份快照里装了两条一样的条目」，而是**已经交出去的那份快照里的标识符自己变了**：
/// `Item.tabItem` 当时按 `Tab.guidInLocalDB` 算哈希，而 `Tab` 是引用类型、那一列是 `var`，
/// 作用域迁移正是就地改它（`BrowserState+PinnedTabScope.swift` 的
/// `rebindPinnedTabAfterScopeMigrationIfNeeded`，为的是让活着的 WebContents 跟着走）。
/// 数据源留存的那份有序集合于是有了一批「不在自己该在的桶里」的成员，下一次求差分时
/// Foundation 把它报成重复标识符并抛异常。
@MainActor
final class PinnedTabSnapshotIdentityTests: XCTestCase {
    private func makeTab(chromiumGuid: Int, rowGuid: String) -> Tab {
        Tab(guid: chromiumGuid,
            url: "https://example.test/\(rowGuid)",
            isActive: false,
            index: 0,
            title: rowGuid,
            customGuid: rowGuid)
    }

    /// ① 迁移就地换掉物理行之后，**先前建好的那条条目仍然是原来那条标识符**。
    ///
    /// 判据用的是 `Set.contains`：它先按哈希找桶再比相等，正是数据源留存快照做的事。旧写法
    /// 在这里会答「找不到」——那一刻它手上那份有序集合就已经坏了。
    func testAnItemIdentifierSurvivesAScopeMigrationRebind() throws {
        let tab = makeTab(chromiumGuid: 1, rowGuid: "row-old")
        let item = PinnedTabViewController.Item.tab(tab)
        let applied: Set<PinnedTabViewController.Item> = [item]

        // 作用域迁移：同一个 `Tab` 对象被指向新建的那条物理行。
        tab.guidInLocalDB = "row-new"

        XCTAssertTrue(applied.contains(item),
                      "① 条目建好之后标识符就冻住了，迁移改不动它")
        XCTAssertEqual(PinnedTabViewController.Item.tab(tab), PinnedTabViewController.Item.tab(tab),
                       "② 同一个 tab 现在建两次仍然彼此相等（新标识符，但一致）")
    }

    /// ② 两条条目在其中一个 `Tab` 被重新绑到另一条的物理行之后**仍然是两条**。
    ///
    /// 这是那次崩溃的形状：迁移逐条改写 `guidInLocalDB`，中途两个对象短暂落在同一个值上，
    /// 旧写法于是让两条早就发出去的标识符变得相等——一份快照里出现重复标识符，
    /// `NSOrderedSet` 的差分直接抛。
    func testTwoItemsStayDistinctAfterOneTabIsReboundOntoTheOthersRow() throws {
        let first = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let second = makeTab(chromiumGuid: 2, rowGuid: "row-b")
        let firstItem = PinnedTabViewController.Item.tab(first)
        let secondItem = PinnedTabViewController.Item.tab(second)
        XCTAssertNotEqual(firstItem, secondItem, "① 出发时就是两条")

        first.guidInLocalDB = "row-b"

        XCTAssertNotEqual(firstItem, secondItem,
                          "② 重新绑定之后还是两条——标识符不跟着行走")
        XCTAssertEqual(Set([firstItem, secondItem]).count, 2,
                       "③ 装进集合里也还是两条，没有塌成一条重复标识符")
    }

    /// ③ 两条条目的标识符**本来就该相等**时照旧相等：冻结的是时机，不是判据。
    func testTwoItemsForTheSameRowRemainEqual() throws {
        let tab = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let other = makeTab(chromiumGuid: 2, rowGuid: "row-a")
        XCTAssertEqual(PinnedTabViewController.Item.tab(tab),
                       PinnedTabViewController.Item.tab(other),
                       "同一条物理行的两个运行时对象仍然是同一条标识符")
    }

    /// ④ **跟随设备**那条时间线（Mac A 2026-09-15 16:20–16:24）：账户把作用域改成 Space
    /// ⇒ `applyAccountPinnedTabScope` → `changePinnedTabScope` 就地重绑一批 `Tab`
    /// （16:20:57），一分钟后那批停放的实体落地（16:21:56 `applied=5`），再过两分钟对端的
    /// 取消固定落地，侧栏重建 ⇒ 崩。
    ///
    /// 这一条把那三步压在标识符这一层上：重绑之后，数据源**留存**的那条标识符照旧找得到，
    /// 而后来重建出来的那条是**另一条**——差分于是看到一次真实的删+增，两条永远不会塌成
    /// 一条重复标识符。
    func testAFollowerRebindThenALaterRebuildYieldsTwoDistinctIdentifiers() throws {
        let tab = makeTab(chromiumGuid: 7, rowGuid: "row-profile")
        let applied = PinnedTabViewController.Item.tab(tab)
        var retainedSnapshot: Set<PinnedTabViewController.Item> = [applied]

        // 16:20:57 跟随迁移：同一个对象被指向迁移新建的那条 Space 行。
        tab.guidInLocalDB = "row-space"
        XCTAssertTrue(retainedSnapshot.contains(applied),
                      "① 留存快照里那条标识符没有跟着行走")

        // 16:21:56 停放的实体落地 ⇒ 侧栏重建条目。
        let rebuilt = PinnedTabViewController.Item.tab(tab)
        XCTAssertNotEqual(applied, rebuilt, "② 重建出来的是新行的标识符")
        retainedSnapshot.insert(rebuilt)
        XCTAssertEqual(retainedSnapshot.count, 2,
                       "③ 新旧两条同时在场时仍然是两条，差分看到一次删+增")
    }

    /// ⑤ 防御层：重复标识符进到 `applySnapshot` 时被丢掉并计数，绝不抛。
    ///
    /// 上面四条保证不会有重复，这一条保证**万一**上游还是错了，用户看到的是少一格而不是
    /// 应用退出——`NSDiffableDataSourceSnapshot` 对重复标识符是抛未捕获异常，不是忽略。
    func testDuplicateIdentifiersAreDroppedInsteadOfReachingTheSnapshot() throws {
        let first = makeTab(chromiumGuid: 1, rowGuid: "row-a")
        let copyOfFirst = makeTab(chromiumGuid: 2, rowGuid: "row-a")
        let second = makeTab(chromiumGuid: 3, rowGuid: "row-b")
        let items = [
            PinnedTabViewController.Item.tab(first),
            PinnedTabViewController.Item.tab(copyOfFirst),
            PinnedTabViewController.Item.tab(second),
        ]

        var seen = Set<PinnedTabViewController.Item>()
        var dropped = 0
        let unique = PinnedTabViewController.deduplicatedItems(items, seen: &seen, dropped: &dropped)

        XCTAssertEqual(unique.count, 2, "① 重复的那一条被丢掉")
        XCTAssertEqual(dropped, 1, "② 丢掉的条数被记下来，日志只报这个数")
        XCTAssertEqual(unique.first, PinnedTabViewController.Item.tab(first), "③ 留的是第一条")
    }

    /// ⑥ `seen` 跨段共享：`NSDiffableDataSourceSnapshot` 要求标识符在**整份快照**里唯一，
    /// 不是每段各自唯一。
    func testTheSeenSetIsSharedAcrossSections() throws {
        let model = PinnedTabItemModel(id: "ext-1", title: "Ext", icon: nil)
        var seen = Set<PinnedTabViewController.Item>()
        var dropped = 0

        _ = PinnedTabViewController.deduplicatedItems([.extensionItem(model)],
                                                      seen: &seen, dropped: &dropped)
        let second = PinnedTabViewController.deduplicatedItems([.extensionItem(model)],
                                                               seen: &seen, dropped: &dropped)

        XCTAssertTrue(second.isEmpty, "① 第二段里那条重复的没进去")
        XCTAssertEqual(dropped, 1, "② 它被记成一次丢弃")
    }
}
