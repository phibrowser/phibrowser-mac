// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftData
import XCTest
@testable import Phi

/// CASE 5b.4b —— **唯一**一条真正跑生产实现的用例。
///
/// 没有它，5b 交付的是一个「假件全绿、真实现从没被执行过」的状态——而假件与生产实现之间
/// 恰恰是投影、排序、事务边界这三处最容易分叉的地方。它成立的前提是
/// `AccountPhiPinnedTabAccess(store:defaults:)` 从 init 收依赖：收 `Account` 的写法要经
/// `account.localStorage` 去够一个懒加载、指向真实用户目录的 store，没有任何缝隙能塞进一个
/// 临时目录的 store，这条用例根本写不出来。
@MainActor
final class PhiPinnedTabLocalAccessTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    // MARK: - ① 投影与次序

    /// `allPins()` 返回的条数与次序 `(ownerKey, index, guid)` 与插进去的一致，休眠行被排除。
    ///
    /// 防的是什么：次序是契约的一部分而不是实现细节——差分按它产出提交序列、index 投影按它
    /// 编号。一个只在假件上被断言过的次序，在生产实现里换成 SwiftData 的默认 fetch 顺序也
    /// 一样「全绿」，而线上表现是每轮两条 commit、pin 顺序在两台机器之间来回翻。
    func testProductionAccessProjectsInOwnerIndexGuidOrderAndDropsDormantRows() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        // 本机作用域是默认的 `.profile`，于是 ownerKey 就是 profileId：`Default` < `Work`。
        try insertPin(in: store, guid: "p-b", lineageId: "L-B", profileId: "Default", index: 1)
        try insertPin(in: store, guid: "p-a", lineageId: "L-A", profileId: "Default", index: 0)
        try insertPin(in: store, guid: "p-w", lineageId: "L-W", profileId: "Work", index: 0)
        try insertPin(in: store, guid: "p-d", lineageId: "L-D", profileId: "Default", index: 2,
                      configure: { $0.isPinnedTabDormant = true })

        let rows = try access.allPins()

        XCTAssertEqual(rows.map(\.guid), ["p-a", "p-b", "p-w"])
        XCTAssertEqual(rows.map(\.index), [0, 1, 0])
        XCTAssertEqual(rows.map(\.profileId), ["Default", "Default", "Work"])
    }

    /// 投影**不改写** `pinLineageId` 那一列（P11），而 `isKnownLocalPin` 收一个线上归一过的
    /// 小写 lineage 仍然答得上话。
    ///
    /// 防的是什么：本机那一列的来源有三条，两条是**大写**（`UUID().uuidString` 与回落到
    /// `guid`）。把线上的小写 lineage 直接与它比恒为假，于是每一条本机 pin 都被判成「本机
    /// 没有这一行」，整批发 tombstone。
    func testKnownLocalPinNormalisesBothSidesOfTheLineageComparison() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p1", lineageId: "ABC-UPPER", profileId: "Default")

        let rows = try access.allPins()

        XCTAssertEqual(rows.map(\.lineageId), ["ABC-UPPER"], "那一列原样投影，不被小写化")
        XCTAssertTrue(access.isKnownLocalPin("abc-upper"), "线上归一过的小写 lineage 必须命中")
        XCTAssertFalse(access.isKnownLocalPin("no-such-lineage"))
    }

    /// 差分定义域出自同一次 fetch，且**不做作用域过滤**（R-exec-4）：一条作用域之外的备份行
    /// 不进快照，但它的 lineage 仍然在定义域里。
    ///
    /// 防的是什么：「同步层不认领它」与「账户应该忘掉它」是两句不同的话。后者的回答是给每
    /// 一条游标发 tombstone，于是一次作用域抖动删掉账户上整批 pin，而每台设备都跟着删。
    func testIdentitiesKeepAnOutOfScopeBackupRowThatTheSnapshotDrops() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-profile", lineageId: "l-profile", profileId: "Default")
        // 作用域是 `.profile`，所以一条 Space 形状的行在本轮的快照之外——它正是一次
        // Space→Profile 迁移原地留下的物理备份。
        try insertPin(in: store, guid: "p-space", lineageId: "l-space",
                      profileId: "Default", spaceId: "space-a")

        let snapshot = try access.allPins()
        let identities = try access.allPinIdentities()

        XCTAssertEqual(snapshot.map(\.guid), ["p-profile"], "作用域之外的行不进快照")
        XCTAssertEqual(identities, ["l-profile", "l-space"], "但它照样在差分的定义域里")
    }

    /// 本轮没有过一次成功的读时 `allPinIdentities()` **抛**，`isKnownLocalPin` 答 false。
    ///
    /// 防的是什么：空集合在 §4.7 那边的含义是「本机一条 pin 都没有了」，回答是给每一条游标
    /// 发 tombstone——正是 R-exec-4 要防的那个形状。
    func testIdentitiesThrowBeforeAnySuccessfulSnapshotThisRound() throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p1", lineageId: "l1", profileId: "Default")

        var threw = false
        do { _ = try access.allPinIdentities() } catch { threw = true }

        XCTAssertTrue(threw, "绝不交出一个会让差分整批发 tombstone 的空集合")
    }

    // MARK: - ② 落地之后行确实按 op 变了

    /// `apply` 之后**直接查那个 store**：create / update / delete 三种 op 各自落到了物理行上，
    /// 而 `.create` 的 `lineageId` / `source` / `createdDate` 三个值原样写回。
    ///
    /// 防的是什么：`lineageId` 默认 nil 会让 body 自己铸一个新的 lineage，于是刚从账户落地
    /// 的那条 pin 拿到一个线上没有的身份，下一轮被差分判成「本机新建」再发一次，账户上多出
    /// 一条重复实体。`source` 落成默认值则会把对端记录的导入来源抹掉。
    func testApplyLandsCreateUpdateAndDeleteOntoTheRealStore() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default",
                      index: 0, title: "A")
        try insertPin(in: store, guid: "p-gone", lineageId: "l-gone", profileId: "Default",
                      index: 1, title: "Gone")
        _ = try access.allPins()

        let born = Date(timeIntervalSince1970: 4_242)
        let created = PhiLocalPin.fixture(lineageId: "l-new",
                                          guid: "p-new",
                                          profileId: "Default",
                                          index: 0,
                                          title: "New",
                                          url: try XCTUnwrap(URL(string: "https://new.example")),
                                          source: TabSource.arc.rawValue,
                                          createdDate: born)
        try await access.apply(PinApplyBatch(unordered: [
            .create(created),
            .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
            .delete(guid: "p-gone"),
        ]))

        let landed = try XCTUnwrap(try row("p-new", in: store))
        XCTAssertEqual(landed.pinLineageId, "l-new", "线上身份原样写回，不重铸")
        XCTAssertEqual(landed.source, TabSource.arc.rawValue)
        XCTAssertEqual(landed.createdDate, born)
        XCTAssertEqual(try row("p-a", in: store)?.title, "Renamed")
        XCTAssertNil(try row("p-gone", in: store))
    }

    /// 一次成功的 `apply` 末尾自己重读一遍，于是 §4.5 的「落地之后、写基线之前按计划复核
    /// 一次」在同一轮里就做得到。
    ///
    /// 防的是什么：把落地后的缓存清空了事的实现，会让 `isKnownLocalPin` 对每一条 lineage 都
    /// 答「不在」，于是引擎把每条身份都判成死映射并整批发 tombstone。
    func testApplyRebuildsTheSnapshotSoThePostLandingRecheckSeesTheNewRows() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default")
        _ = try access.allPins()

        try await access.apply(PinApplyBatch(unordered: [
            .create(PhiLocalPin.fixture(lineageId: "l-new", guid: "p-new", profileId: "Default",
                                        index: 1, title: "New")),
        ]))

        XCTAssertTrue(access.isKnownLocalPin("l-new"), "复核读到的是落地**之后**的行")
        XCTAssertEqual(try access.allPinIdentities(), ["l-a", "l-new"])
    }

    // MARK: - ③ 整批一个事务

    /// 中途让一条 op 失败，**前面那些也回滚**。
    ///
    /// 防的是什么：那几个 throwing 兄弟各自开一个写块，挨个调就是 N 个事务、部分成功于是
    /// 成立——引擎会为一批只落了一半的操作写下基线，此后那些没落地的行既不会被差分判成删除
    /// （游标说它已同步），也不会被快照重发。
    func testAFailingOpRollsBackTheWholeBatch() async throws {
        let store = try makeStore()
        let access = AccountPhiPinnedTabAccess(store: store)
        try insertPin(in: store, guid: "p-a", lineageId: "l-a", profileId: "Default", title: "A")
        _ = try access.allPins()

        var thrown: Error?
        do {
            // 排序之后是 create → update → delete，最后那条定位不到行。
            try await access.apply(PinApplyBatch(unordered: [
                .delete(guid: "no-such-guid"),
                .update(guid: "p-a", fields: PinFieldPatch(title: "Renamed")),
                .create(PhiLocalPin.fixture(lineageId: "l-new", guid: "p-new",
                                            profileId: "Default", index: 1)),
            ]))
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? LocalStoreWriteError, .rowNotFound)
        XCTAssertEqual(try row("p-a", in: store)?.title, "A", "同批的 update 也回滚了")
        XCTAssertNil(try row("p-new", in: store), "同批的 create 也回滚了")
    }

    // MARK: - accountScope()

    /// 键缺失 ⇒ nil（引擎按「账户还没发过作用域」处理）；值不认识 ⇒ 同样 nil，**不回落成
    /// `.profile`**。
    ///
    /// 防的是什么：回落会把「账户还没发过作用域」伪装成一次真实的账户取值，于是一台本机在
    /// Space 作用域的机器把它判成 §7.3 的不一致，整个 pin 段就此停摆。
    func testAccountScopeIsNilWhenTheMirrorKeyIsMissingOrUnrecognised() throws {
        let store = try makeStore()
        // 一个一次性的 suite：`UserDefaults.standard` 是进程共享的，往它写会污染同进程里
        // 其它用例，也会把一条键留在跑测试那台机器上。
        let suiteName = "PhiPinAccessTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let access = AccountPhiPinnedTabAccess(store: store, defaults: defaults)

        XCTAssertNil(access.accountScope(), "键缺失")

        defaults.set("galaxy", forKey: "PhiPinnedTabScope")
        XCTAssertNil(access.accountScope(), "值不认识")

        defaults.set(PinnedTabScope.space.rawValue, forKey: "PhiPinnedTabScope")
        XCTAssertEqual(access.accountScope(), .space)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> LocalStore {
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
        context.insert(ProfileModel(profileId: "Work"))
        context.insert(SpaceModel(spaceId: "space-a", profileId: "Default", name: "A",
                                  colorHex: "#000000", iconName: "star", sortOrder: 0))
        try context.save()
        return store
    }

    /// 形状照 `LocalStorePinnedTabTransferTests.insertPinned`：直接往主上下文里插一条
    /// `pinnedTab` 行，绕开任何入口的归一与重排，于是用例控制得住每一个字段。
    @discardableResult
    private func insertPin(in store: LocalStore,
                           guid: String,
                           lineageId: String,
                           profileId: String,
                           spaceId: String? = nil,
                           index: Int = 0,
                           title: String = "T",
                           url: String = "https://pin.example",
                           configure: (TabDataModel) -> Void = { _ in }) throws -> TabDataModel {
        let context = try XCTUnwrap(store.getMainContext())
        let profile = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProfileModel>())
                .first(where: { $0.profileId == profileId })
        )
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: index,
            url: try XCTUnwrap(URL(string: url)),
            favicon: nil,
            createdDate: Date(timeIntervalSince1970: 1_000),
            updatedDate: Date(timeIntervalSince1970: 1_000)
        )
        model.dataType = .pinnedTab
        model.profile = profile
        model.profileId = profileId
        model.spaceId = spaceId
        model.pinLineageId = lineageId
        configure(model)
        context.insert(model)
        try context.save()
        return model
    }

    private func row(_ guid: String, in store: LocalStore) throws -> TabDataModel? {
        let context = try XCTUnwrap(store.getMainContext())
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        return try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )).first
    }
}
