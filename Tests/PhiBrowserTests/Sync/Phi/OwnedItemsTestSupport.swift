import CryptoKit
import Foundation
import XCTest
@testable import Phi

// MARK: - 假件

/// 内存版 `PhiBookmarkLocalAccess`。形状照既有的 `FakePhiSpaceAccess`
/// （`PhiSpaceLocalAccessTests.swift:9`）：**顶层类型**，调用记在一个 `Call` 枚举数组里。
///
/// `apply(_:)` **真的把 `ops` 施加到 `rows` 上**（V10）：后面一大批用例是在一次 apply
/// 之后直接断言 `rows`，只记调用不改行会让那些断言恒为假。
@MainActor
final class FakeBookmarkAccess: PhiBookmarkLocalAccess {
    enum Call: Equatable {
        case allBookmarks
        case siblings(parent: String?, space: String)
        case apply(opCount: Int)
        case clearAllSyncIds
    }

    var rows: [PhiLocalBookmark]
    var importingSpaceIds: Set<String> = []
    /// 下一次 `apply` 抛 `LocalStoreWriteError.storeUnavailable`，然后清零。**一行都不改。**
    var failApplyOnce = false
    /// `apply` 不抛错、但一条行都不改——模拟 Task 2a 之前那族静默守卫。
    var applyLandsNothingSilently = false
    /// `clearAllSyncIds()` 抛错（Task 9a 的次序用例）。
    var failClearSyncIds = false
    private(set) var calls: [Call] = []
    /// 最近一次 `apply` 收到的 `ops`，供顺序断言。抛错的那次也记——断言的正是「引擎把什么
    /// 交了出去」，而不是「什么落了地」。
    private(set) var lastAppliedOps: [BookmarkApplyOp] = []

    init(rows: [PhiLocalBookmark] = []) {
        self.rows = rows
    }

    func allBookmarks() -> [PhiLocalBookmark] {
        calls.append(.allBookmarks)
        return rows
    }

    /// 契约是「那一次 fetch 结果在内存里的分组」，所以这里读的也是 `rows`，**不**再记一次
    /// `.allBookmarks`，也**不**过滤（§4.10 的 index 投影要未过滤的兄弟列表）。
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        calls.append(.siblings(parent: parentGuid, space: spaceId))
        return rows
            .filter { $0.spaceId == spaceId && $0.parentGuid == parentGuid }
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
    }

    func isKnownLocalBookmark(_ guid: String) -> Bool {
        rows.contains { $0.guid == guid }
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        importingSpaceIds.contains(spaceId)
    }

    func apply(_ batch: BookmarkApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        guard !applyLandsNothingSilently else { return }
        for op in batch.ops { land(op) }
    }

    func clearAllSyncIds() async throws {
        calls.append(.clearAllSyncIds)
        if failClearSyncIds { throw LocalStoreWriteError.storeUnavailable }
        for index in rows.indices { rows[index].syncId = nil }
    }

    /// `.delete` 只移除被点名的那一行，**不**级联到后代：`BookmarkApplyBatch` 已经把整棵
    /// 子树的 delete 按子先于父排进了同一批，级联会让「批里有几条 delete」与「落了几行」
    /// 对不上。
    private func land(_ op: BookmarkApplyOp) {
        switch op {
        case .claim(let guid, let syncId):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].syncId = syncId
        case .create(let row):
            rows.append(row)
        case .move(let guid, let parentGuid, let spaceId, let position):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].parentGuid = parentGuid
            rows[index].spaceId = spaceId
            rows[index].index = position
        case .update(let guid, let fields):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            // 外层 some = 改这个字段。`title` / `url` 在本机模型里非可选，所以内层 nil
            // 分别是「清成空串」与「不动」——一条书签丢不掉它的 URL。
            if let title = fields.title { rows[index].title = title ?? "" }
            if let url = fields.url, let url { rows[index].url = url }
            if let secondaryUrl = fields.secondaryUrl { rows[index].secondaryUrl = secondaryUrl }
            if let secondaryTitle = fields.secondaryTitle {
                rows[index].secondaryTitle = secondaryTitle
            }
        case .delete(let guid):
            rows.removeAll { $0.guid == guid }
        }
    }
}

/// 内存版 `PhiPinnedTabLocalAccess`。`apply(_:)` 的落地契约同 `FakeBookmarkAccess`。
@MainActor
final class FakePinAccess: PhiPinnedTabLocalAccess {
    enum Call: Equatable {
        case allPins
        case apply(opCount: Int)
        case changeScope(PinnedTabScope)
    }

    var scope: PinnedTabScope
    var account: PinnedTabScope?
    var rows: [PhiLocalPin]
    /// 下一次 `apply` 抛 `LocalStoreWriteError.storeUnavailable`，然后清零。**一行都不改。**
    var failApplyOnce = false
    private(set) var calls: [Call] = []
    private(set) var lastAppliedOps: [PinApplyOp] = []

    init(scope: PinnedTabScope, account: PinnedTabScope? = nil, rows: [PhiLocalPin] = []) {
        self.scope = scope
        self.account = account
        self.rows = rows
    }

    func currentScope() -> PinnedTabScope { scope }

    func accountScope() -> PinnedTabScope? { account }

    /// 非休眠的**全部**行，按 `(ownerKey, index, guid)` 有序。**不挑代表。**
    func allPins() -> [PhiLocalPin] {
        calls.append(.allPins)
        return rows
            .filter { !$0.isDormant }
            .sorted { (Self.ownerKey($0), $0.index, $0.guid) < (Self.ownerKey($1), $1.index, $1.guid) }
    }

    func isKnownLocalPin(_ lineageId: String) -> Bool {
        rows.contains { $0.lineageId == lineageId }
    }

    func apply(_ batch: PinApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        for op in batch.ops { land(op) }
    }

    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws {
        calls.append(.changeScope(scope))
        self.scope = scope
    }

    /// `phi-pin:<lineage>:<ownerKey>` 里那个 ownerKey 的本机侧对应物：Space 作用域是
    /// spaceId，Profile 作用域是 profileId，App 作用域是字面量 "app"。
    private static func ownerKey(_ pin: PhiLocalPin) -> String {
        pin.spaceId ?? pin.profileId ?? "app"
    }

    private func land(_ op: PinApplyOp) {
        switch op {
        case .create(let row):
            rows.append(row)
        case .relineage(let guid, let newLineageId):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].lineageId = newLineageId
        case .move(let guid, let position):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            rows[index].index = position
        case .update(let guid, let fields):
            guard let index = rows.firstIndex(where: { $0.guid == guid }) else { return }
            if let title = fields.title { rows[index].title = title ?? "" }
            if let url = fields.url, let url { rows[index].url = url }
            if let partner = fields.splitPartnerLineageId {
                rows[index].splitPartnerLineageId = partner
            }
        case .delete(let guid):
            rows.removeAll { $0.guid == guid }
        }
    }
}

// MARK: - 值类型 fixture

extension PhiLocalBookmark {
    /// 每个参数都有默认值，所以一条用例只写它真正在乎的那几个字段。
    static func fixture(guid: String = "g1",
                        syncId: String? = nil,
                        spaceId: String = LocalStore.defaultSpaceId,
                        profileId: String = "Default",
                        parentGuid: String? = nil,
                        index: Int = 0,
                        isFolder: Bool = false,
                        title: String = "T",
                        url: URL = URL(string: "https://e.example")!,
                        secondaryUrl: URL? = nil,
                        secondaryTitle: String? = nil,
                        source: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil) -> PhiLocalBookmark {
        PhiLocalBookmark(syncId: syncId, guid: guid, spaceId: spaceId, profileId: profileId,
                         parentGuid: parentGuid, index: index, isFolder: isFolder,
                         title: title, url: url, secondaryUrl: secondaryUrl,
                         secondaryTitle: secondaryTitle, source: source,
                         createdDate: createdDate, contentUpdatedDate: contentUpdatedDate)
    }
}

extension PhiLocalPin {
    static func fixture(lineageId: String = "LX",
                        guid: String = "p1",
                        spaceId: String? = nil,
                        profileId: String? = "Default",
                        index: Int = 0,
                        title: String = "T",
                        url: URL = URL(string: "https://e.example")!,
                        splitPartnerLineageId: String? = nil,
                        source: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil,
                        isDormant: Bool = false) -> PhiLocalPin {
        PhiLocalPin(lineageId: lineageId, guid: guid, spaceId: spaceId, profileId: profileId,
                    index: index, title: title, url: url,
                    splitPartnerLineageId: splitPartnerLineageId, source: source,
                    createdDate: createdDate, contentUpdatedDate: contentUpdatedDate,
                    isDormant: isDormant)
    }
}

// MARK: - 载荷构造（返回生成的 proto 类型）

/// `PhiSettingValue` 是这套 schema 的通用「值 + LWW 戳」标量，三种 `v` case 各一个重载。
func stamped(_ value: String, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.stringValue = value
    return out
}

func stamped(_ value: Bool, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.boolValue = value
    return out
}

func stamped(_ value: Int64, at ms: Int64) -> Phi_PhiSettingValue {
    var out = Phi_PhiSettingValue()
    out.updatedAtMs = ms
    out.intValue = value
    return out
}

/// 一条书签实体。
///
/// `space_uuid` 与 `parent_uuid` 是 LOCATION 的两半，共用 `locationStamp`（§4.3）；
/// `rank` 有自己的戳；四个内容字段共用 `contentStamp`。`secondary_url` /
/// `secondary_title` 没有参数，按 proto 的「永远发射」规则发显式清空值 ""——省略它们会让
/// fixture 与它自己的快照在 `has_…` 上不同，每一条「这一轮不发布」的断言都会看到一次
/// 虚假 commit。
func bookmarkPayload(uuid: String,
                     spaceUuid: String = "su-1",
                     parentUuid: String = "",
                     rank: String = "V",
                     isFolder: Bool = false,
                     title: String = "T",
                     url: String = "https://e.example",
                     locationStamp: Int64 = 100,
                     rankStamp: Int64 = 100,
                     contentStamp: Int64 = 100,
                     source: Int64 = 0,
                     createdAtMs: Int64 = 1_000) -> Phi_PhiBookmarkEntity {
    var entity = Phi_PhiBookmarkEntity()
    entity.bookmarkUuid = uuid
    entity.spaceUuid = stamped(spaceUuid, at: locationStamp)
    entity.parentUuid = stamped(parentUuid, at: locationStamp)
    entity.rank = stamped(rank, at: rankStamp)
    entity.isFolder = isFolder
    entity.title = stamped(title, at: contentStamp)
    entity.url = stamped(url, at: contentStamp)
    entity.secondaryURL = stamped("", at: contentStamp)
    entity.secondaryTitle = stamped("", at: contentStamp)
    entity.source = Int32(truncatingIfNeeded: source)
    entity.createdAtMs = createdAtMs
    return entity
}

/// 一条 pin 实体。
///
/// `ownerKey` 就是 client tag 第三段里那个 ownerKey，按 proto 的三选一映射进 `owner`
/// oneof：字面量 "app" = 一条 oneof 都不设（App 作用域，缺席**就是**三个值之一）；
/// `"su-"` 前缀或字面量 `LocalStore.defaultSpaceId` = Space 作用域；其余 = Profile
/// 作用域。本计划的命名约定是 `su-*` 空间 uuid / `pu-*` profile uuid。
func pinPayload(lineage: String,
                ownerKey: String = "pu-1",
                rank: String = "V",
                title: String = "T",
                url: String = "https://e.example",
                splitPartner: String = "",
                rankStamp: Int64 = 100,
                contentStamp: Int64 = 100,
                source: Int64 = 0,
                createdAtMs: Int64 = 1_000) -> Phi_PhiPinTabEntity {
    var entity = Phi_PhiPinTabEntity()
    entity.pinUuid = lineage
    if ownerKey == "app" {
        // owner 留空 = App 作用域。
    } else if ownerKey.hasPrefix("su-") || ownerKey == LocalStore.defaultSpaceId {
        entity.spaceUuid = ownerKey
    } else {
        entity.profileUuid = ownerKey
    }
    entity.rank = stamped(rank, at: rankStamp)
    entity.title = stamped(title, at: contentStamp)
    entity.url = stamped(url, at: contentStamp)
    entity.splitPartnerUuid = stamped(splitPartner, at: contentStamp)
    entity.source = Int32(truncatingIfNeeded: source)
    entity.createdAtMs = createdAtMs
    return entity
}

/// 一条 Space 实体，书签解析 `space_uuid` 时当背景用。
///
/// `profile_uuid` 没有参数，所以不发射；需要 profile 绑定的用例在返回值上自己设
/// （它是 `var`）。默认 Space 按 D1 不带 `theme_id` 与 `profile_uuid`。
func spacePayload(uuid: String, name: String = "S", stamp: Int64 = 100) -> Phi_PhiSpaceEntity {
    var entity = Phi_PhiSpaceEntity()
    entity.spaceUuid = uuid
    entity.name = stamped(name, at: stamp)
    entity.iconName = stamped("emoji:1F4BC", at: stamp)
    entity.colorHex = stamped("#3A6FF8", at: stamp)
    entity.rank = stamped("V", at: stamp)
    if uuid != LocalStore.defaultSpaceId {
        entity.themeID = stamped("", at: stamp)
    }
    entity.overlayOpacityLight = stamped(Int64(-1), at: stamp)
    entity.overlayOpacityDark = stamped(Int64(-1), at: stamp)
    entity.createdAtMs = 1_000
    return entity
}

func envelope(_ payload: Phi_PhiBookmarkEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.bookmark = payload
    return out
}

func envelope(_ payload: Phi_PhiPinTabEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.pinTab = payload
    return out
}

func envelope(_ payload: Phi_PhiSpaceEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.space = payload
    return out
}

/// 基线字节：`envelope(payload).serializedData()`，写进游标的 `reconciled` / `server`。
func baselineBytes(_ payload: Phi_PhiBookmarkEntity) -> Data {
    (try? envelope(payload).serializedData()) ?? Data()
}

func baselineBytes(_ payload: Phi_PhiPinTabEntity) -> Data {
    (try? envelope(payload).serializedData()) ?? Data()
}

// MARK: - 协议层 fixture

/// `PhiRemoteEntity`（`PhiSyncProtocolClient.swift`）是假件页的元素类型。生成的
/// `SyncPb_SyncEntity` 是线上消息，假件不碰它。
///
/// `tag` 是 **client tag**（`phi-bookmark:<uuid>` 之类），这里现算它的 hash。
func remoteEntity(_ envelope: Phi_PhiEntity,
                  tag: String,
                  version: Int64,
                  entityId: String = "srv-1",
                  key: SymmetricKey) -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: entityId,
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: (try? PhiEntityCodec.encrypt(envelope, key: key)) ?? Data(),
                    deleted: false)
}

func remoteTombstone(tag: String, version: Int64, entityId: String = "srv-1") -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: entityId,
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: Data(),
                    deleted: true)
}

/// 密文是随机字节，解不开——§5.5 的隔离路径用。
func remoteUnreadable(tag: String, version: Int64) -> PhiRemoteEntity {
    PhiRemoteEntity(entityId: "srv-1",
                    clientTagHash: PhiSyncEntity.clientTagHash(for: tag),
                    version: version,
                    ciphertext: Data((0..<32).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }),
                    deleted: false)
}

/// 一条 `kind` oneof 都没设的载荷，分发的兜底分支用。
func remoteUnknownKind(tag: String, version: Int64, key: SymmetricKey) -> PhiRemoteEntity {
    remoteEntity(Phi_PhiEntity(), tag: tag, version: version, key: key)
}

func remoteSettingsEntity(key settingKey: String, value: String,
                          version: Int64, key: SymmetricKey) -> PhiRemoteEntity {
    var setting = Phi_PhiSettingEntity()
    setting.values[settingKey] = stamped(value, at: 100)
    var wrapper = Phi_PhiEntity()
    wrapper.setting = setting
    return remoteEntity(wrapper, tag: PhiSyncEntity.clientTag, version: version, key: key)
}

/// `FakePhiSyncClient.Page` 的构造糖。
func page(_ entities: [PhiRemoteEntity],
          marker: String = "m1",
          changesRemaining: Bool = false) -> PhiSyncEngineTests.FakePhiSyncClient.Page {
    PhiSyncEngineTests.FakePhiSyncClient.Page(entities: entities,
                                              newMarker: Data(marker.utf8),
                                              changesRemaining: changesRemaining)
}

// MARK: - commit 过滤

/// 书签 tag 的 commit 条目。设置实体与 Space 实体骑在同一个 `commits` 列表上，不是这些
/// 用例关心的东西。
func bookmarkCommits(_ client: PhiSyncEngineTests.FakePhiSyncClient)
    -> [PhiSyncEngineTests.FakePhiSyncClient.CommitCall] {
    client.commits.filter { $0.name == PhiSyncEntity.bookmarkEntityName }
}

func pinCommits(_ client: PhiSyncEngineTests.FakePhiSyncClient)
    -> [PhiSyncEngineTests.FakePhiSyncClient.CommitCall] {
    client.commits.filter { $0.name == PhiSyncEntity.pinEntityName }
}

/// 从一条 commit 的密文里解出 `bookmark_uuid`，供顺序断言。tombstone（`ciphertext == nil`）
/// 与解不开的密文都返回 nil。
func committedBookmarkUuid(_ call: PhiSyncEngineTests.FakePhiSyncClient.CommitCall,
                           key: SymmetricKey) -> String? {
    guard let ciphertext = call.ciphertext,
          let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
          case .bookmark(let payload)? = entity.kind else { return nil }
    return payload.bookmarkUuid
}

/// 同上，解出 `pin_uuid`（lineage）。**只有 lineage，不含 owner**：一条 lineage 在 N 个
/// owner 里是 N 条实体，要区分它们得另看 `clientTagHash`。
func committedPinIdentity(_ call: PhiSyncEngineTests.FakePhiSyncClient.CommitCall,
                          key: SymmetricKey) -> String? {
    guard let ciphertext = call.ciphertext,
          let entity = try? PhiEntityCodec.decrypt(ciphertext, key: key),
          case .pinTab(let payload)? = entity.kind else { return nil }
    return payload.pinUuid
}

// MARK: - CASE 0.1 – 0.5

/// 本文件既是 M3-3「自有条目」（书签 + pin）全部测试的共享脚手架，也是 Task 0 自己那
/// 五条用例的宿主。形状照 `PhiSpaceLocalAccessTests.swift`：顶层的假件 + 同文件里的
/// `XCTestCase`。
///
/// 假件是 `@MainActor` 的（两个协议都是），所以测试类整体标 `@MainActor`。
@MainActor
final class OwnedItemsTestSupportTests: XCTestCase {

    /// 三个相的编号，与 `BookmarkApplyBatch` 的排序判据同义但**独立实现**——用被测类型
    /// 自己的排序函数来断言它自己的排序，测不出任何东西。
    private func phase(_ op: BookmarkApplyOp) -> Int {
        switch op {
        case .claim, .create, .move: return 1
        case .update: return 2
        case .delete: return 3
        }
    }

    private func createGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .create(let row) = $0 { return row.guid } else { return nil } }
    }

    private func deleteGuids(_ ops: [BookmarkApplyOp]) -> [String] {
        ops.compactMap { if case .delete(let guid) = $0 { return guid } else { return nil } }
    }

    /// CASE 0.1 — 批次按三相排序。
    ///
    /// 防的是什么：三相交错或同相内父子顺序反了，落地时会去更新一条已被删的行，或建一条
    /// 父还不存在的子行。
    func testBookmarkBatchSortsOpsIntoThreePhasesWithParentsBeforeChildren() {
        let unordered: [BookmarkApplyOp] = [
            .delete(guid: "child"),
            .create(.fixture(guid: "child", parentGuid: "parent")),
            .update(guid: "other", fields: BookmarkFieldPatch(title: "T")),
            .delete(guid: "parent"),
            .create(.fixture(guid: "parent", isFolder: true)),
        ]

        let ops = BookmarkApplyBatch(unordered: unordered, parentOf: ["child": "parent"]).ops

        let phases = ops.map(phase)
        XCTAssertEqual(phases, phases.sorted(), "相序号必须单调不减")
        XCTAssertEqual(createGuids(ops), ["parent", "child"], "同相内父先于子")
        XCTAssertEqual(deleteGuids(ops), ["child", "parent"], "delete 相内子先于父")
    }

    /// CASE 0.2 — 祖先的 delete 绝不排在它后代的操作之前。
    ///
    /// 防的是什么：先删父、再更新已随 cascade 消失的子行——那次更新在 Task 2a 之后会抛
    /// `.rowNotFound`，整批回滚，这一轮永远落不了地。
    func testAnAncestorDeleteNeverPrecedesAnOperationOnItsDescendant() {
        let unordered: [BookmarkApplyOp] = [
            .delete(guid: "parent"),
            .update(guid: "child", fields: BookmarkFieldPatch(title: "T")),
        ]

        let ops = BookmarkApplyBatch(unordered: unordered, parentOf: ["child": "parent"]).ops

        let updateIndex = ops.firstIndex { if case .update = $0 { return true } else { return false } }
        let deleteIndex = ops.firstIndex { if case .delete = $0 { return true } else { return false } }
        XCTAssertNotNil(updateIndex)
        XCTAssertNotNil(deleteIndex)
        guard let updateIndex, let deleteIndex else { return }
        XCTAssertLessThan(updateIndex, deleteIndex)
    }

    /// CASE 0.3 — 假件用枚举记调用。
    ///
    /// 防的是什么：用 `[String]` 记调用与既有 `FakePhiSpaceAccess.Call` 形状不一致，复用
    /// 既有断言写法的人会踩空。
    func testFakeBookmarkAccessRecordsCallsAsEnumCases() async throws {
        let fake = FakeBookmarkAccess(rows: [.fixture(guid: "g1")])

        _ = fake.allBookmarks()
        try await fake.apply(BookmarkApplyBatch(unordered: [.delete(guid: "g1")]))

        let calls = fake.calls
        XCTAssertEqual(calls, [.allBookmarks, .apply(opCount: 1)])
    }

    /// CASE 0.4 — `siblings` 不产生第二次读。
    ///
    /// 防的是什么：把 `siblings` 实现成第二次 fetch，一棵上千行的树每轮要扫好几遍，而且
    /// 两次之间用户可能改过行。
    func testSiblingsIsAnInMemoryGroupingRatherThanASecondFetch() {
        let fake = FakeBookmarkAccess(rows: [
            .fixture(guid: "a", parentGuid: "p", index: 0),
            .fixture(guid: "b", parentGuid: "p", index: 1),
        ])

        _ = fake.allBookmarks()
        let siblings = fake.siblings(ofParent: "p", inSpaceId: LocalStore.defaultSpaceId)

        let siblingCount = siblings.count
        let fetchCount = fake.calls.filter { $0 == .allBookmarks }.count
        XCTAssertEqual(siblingCount, 2)
        XCTAssertEqual(fetchCount, 1)
    }

    /// CASE 0.5 — App 作用域的 pin 两个 owner 字段都为 nil。
    ///
    /// 防的是什么：`profileId` 写成非可选时 App 作用域的行根本表达不了，而 §7.2 的 owner
    /// 推导表里那一整行就没法测。
    func testAnAppScopedPinFixtureCarriesNeitherOwnerId() {
        let pin = PhiLocalPin.fixture(spaceId: nil, profileId: nil)

        let spaceId = pin.spaceId
        let profileId = pin.profileId
        XCTAssertNil(spaceId)
        XCTAssertNil(profileId)
    }
}
