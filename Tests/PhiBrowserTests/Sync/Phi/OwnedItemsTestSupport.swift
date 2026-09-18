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
        case allSyncIds
        case siblings(parent: String?, space: String)
        case apply(opCount: Int)
        case clearAllSyncIds
    }

    var rows: [PhiLocalBookmark]
    var importingSpaceIds: Set<String> = []
    /// 让两个读方法抛（R-exec-3）。**每次都抛，不自动清零**：一轮读失败的引擎行为是整段
    /// 跳过，用例要断言的正是「跳过了」，一次性的失败会让第二次读悄悄成功。
    var readError: Error?
    /// 本机有行、但**不在快照里**的那些身份：孤儿根 / 重复根下面的子树（R-exec-4）。
    /// `allBookmarks()` 看不见它们，`allSyncIds()` 必须看得见，否则差分把它们判成删除。
    var orphanedSyncIds: Set<String> = []
    /// 本轮有没有一份可用的快照，**与生产实现同一条契约**：三个读者只在本轮最后一次成功的
    /// `allBookmarks()` 或 `apply(_:)` 之后有意义，否则交出「不在」那个值；`allSyncIds()`
    /// 在此之前抛。
    ///
    /// 假件必须模这一条，否则 Task 6 的引擎用例会在假件上跑过一种生产实现里根本不成立的
    /// 用法——「落地之后直接复核」在假件上答对、在真机上每一条都答不在（G1 / G4）。
    private(set) var snapshotIsLoaded = false
    /// 下一次 `apply` 抛 `LocalStoreWriteError.storeUnavailable`，然后清零。**一行都不改。**
    var failApplyOnce = false
    /// 下一次 `apply` 抛这个错，然后清零。**一行都不改。** `failApplyOnce` 只表达得了
    /// `.storeUnavailable` 一种，而 §4.5 的三种落地失败（导入锁 / `.folderNotEmpty` /
    /// `.rowAlreadyMapped`）的**正确反应方向相反**，用例必须能逐种注入。
    var applyErrorOnce: Error?
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

    /// 按 `(spaceId, parentGuid, index, guid)` 有序（§4.8），与 `allPins()` 对称：喂给引擎
    /// 的次序必须是生产实现真会产出的那个，否则后面断言提交顺序或 index 投影的用例会因为
    /// 一个与被测代码无关的理由变红或变绿。无父的行（`parentGuid == nil`）排在同 Space 的
    /// 有父行之前。
    /// 开新一轮：把快照标成「没读过」。用例用它制造 R-exec-3 之后那三种无效状态。
    func beginRound() {
        snapshotIsLoaded = false
    }

    func allBookmarks() throws -> [PhiLocalBookmark] {
        calls.append(.allBookmarks)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return rows.sorted {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
    }

    /// 那一次 fetch 的行快照本身，**不再 fetch**、**不记调用**——它与
    /// `isKnownLocalBookmark` / `localIsFolder` 同属那一组读缓存的非抛出读者，而 CASE 0.3
    /// 那条逐项相等的 `calls` 断言容不下一个新条目。次序与 `allBookmarks()` 相同。
    ///
    /// **没读过就交 nil**，与生产实现同一条契约：调用方拿它去换掉轮内那份本机投影，一个空
    /// 数组会让整轮的出站快照变空。
    func cachedBookmarks() -> [PhiLocalBookmark]? {
        guard snapshotIsLoaded else { return nil }
        return rows.sorted {
            ($0.spaceId, $0.parentGuid ?? "", $0.index, $0.guid)
                < ($1.spaceId, $1.parentGuid ?? "", $1.index, $1.guid)
        }
    }

    /// 契约是「那一次 fetch 结果在内存里的分组」，所以这里读的也是 `rows`，**不**再记一次
    /// `.allBookmarks`，也**不**过滤（§4.10 的 index 投影要未过滤的兄弟列表）。
    func siblings(ofParent parentGuid: String?, inSpaceId spaceId: String) -> [PhiLocalBookmark] {
        calls.append(.siblings(parent: parentGuid, space: spaceId))
        guard snapshotIsLoaded else { return [] }
        return rows
            .filter { $0.spaceId == spaceId && $0.parentGuid == parentGuid }
            .sorted { ($0.index, $0.guid) < ($1.index, $1.guid) }
    }

    /// 快照里的身份加上被排除的那些。生产实现是一次不做根过滤的 fetch；这里用一个显式的
    /// `orphanedSyncIds` 表达同一件事，因为假件的 `rows` 本身没有根的概念。
    func allSyncIds() throws -> Set<String> {
        calls.append(.allSyncIds)
        if let readError { throw readError }
        // 与生产实现同源：它读的是快照那一次 fetch 的未过滤结果，所以本轮没成功读过就抛，
        // 绝不交出一个会让差分把整棵树判成删除的空集合。
        guard snapshotIsLoaded else { throw LocalStoreWriteError.storeUnavailable }
        return Set(rows.compactMap(\.syncId)).union(orphanedSyncIds)
    }

    func isKnownLocalBookmark(_ guid: String) -> Bool {
        guard snapshotIsLoaded else { return false }
        return rows.contains { $0.guid == guid }
    }

    /// 生产实现从那一次 fetch 的分组缓存里读 `dataType`；这里读的是同一份 `rows`，
    /// 于是假件与生产实现在「找不到 ⇒ nil」这一点上同形。
    func localIsFolder(guid: String) -> Bool? {
        guard snapshotIsLoaded else { return nil }
        return rows.first { $0.guid == guid }?.isFolder
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
        if let applyErrorOnce {
            self.applyErrorOnce = nil
            throw applyErrorOnce
        }
        // 导入锁是 **fail-closed** 的，与生产实现的 `refuseIfImporting`
        // （`LocalStore+Bookmark.swift`）同形：扫一遍这批 ops 涉及的全部 `spaceId`，只要有
        // 一个正在被导入就拒掉整批。假件不模这一条，CASE 6.10c-2 就测不到「按 Space 切开」。
        if let locked = batch.ops.compactMap(spaceId(of:)).first(where: importingSpaceIds.contains) {
            throw LocalStoreWriteError.spaceImporting(spaceId: locked)
        }
        // 一条行的身份**只认领一次**，与生产实现同形（`LocalStore+Bookmark.swift` 的
        // `node.syncId == nil || node.syncId == syncId`）：换一个身份是 fail-closed 的
        // **批次级**拒绝，一行都不改。覆盖写会让旧身份在本机瞬间失去对应行，而下一轮差分对
        // 「没有本机行」的回答是发一条 tombstone，把账户上那条真实的书签删掉。
        //
        // **这道扫描读的是施加任何 op 之前的 `rows`**，所以它接的是「目标行**在这一批之前**
        // 就已经带着另一个身份」那一种形状（上一批写的，或轮首那份快照里就带着）。真 store
        // 是边走边写的，同一批里的第二条 `.claim` 会看见第一条刚写下的 `syncId` 而抛，假件
        // 在这一点上比它宽——同一批双认领由 CASE 6b.13 的身份断言（那一行最后带的是哪一条）
        // 兜住，不靠这里。
        for op in batch.ops {
            guard case .claim(let guid, let syncId) = op,
                  let existing = rows.first(where: { $0.guid == guid })?.syncId,
                  existing != syncId else { continue }
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        // 生产实现末尾会重读一次，于是 §4.5 的落地后复核在同一轮里就能做（G1）。抛错那一
        // 支走不到这里：真实现里那次重读排在写之后，写抛了就不会发生，快照保持原样。
        snapshotIsLoaded = true
        guard !applyLandsNothingSilently else { return }
        for op in batch.ops { land(op) }
    }

    /// Task 10 的回填写入口收到的（行，字节）对，**按到达顺序摊平**。
    private(set) var faviconWrites: [(guid: String, data: Data)] = []
    /// `setFavicon` 被调了几次。光看摊平的条数看不出「整轮一次写回」，而那正是 CASE 10.11
    /// 要的不变量。
    private(set) var faviconWriteCalls = 0
    /// 下一次 `setFavicon` 抛错，然后清零。**一条都不写。**
    var failSetFaviconOnce = false

    /// **不进 `calls`**：`Call` 是同步落地那条路的调用记录，回填刻意不走那条路，把它记进去
    /// 会让「`.apply` 零次」那条断言读起来像是在数另一件事。
    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        faviconWriteCalls += 1
        if failSetFaviconOnce {
            failSetFaviconOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        faviconWrites.append(contentsOf: writes)
    }

    func clearAllSyncIds() async throws {
        calls.append(.clearAllSyncIds)
        if failClearSyncIds { throw LocalStoreWriteError.storeUnavailable }
        for index in rows.indices { rows[index].syncId = nil }
    }

    /// 一个操作落在哪个 Space 上。`.create` / `.move` 自己带目标 Space，其余按被点名的那条
    /// 行现在坐在哪里。
    private func spaceId(of op: BookmarkApplyOp) -> String? {
        switch op {
        case .create(let row): return row.spaceId
        case .move(_, _, let spaceId, _): return spaceId
        case .claim(let guid, _), .update(let guid, _), .delete(let guid):
            return rows.first { $0.guid == guid }?.spaceId
        }
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
        case allPinRows
        case apply(opCount: Int)
        case changeScope(PinnedTabScope)
    }

    var scope: PinnedTabScope
    var account: PinnedTabScope?
    var rows: [PhiLocalPin]
    /// 让两个读方法抛（R-exec-3）。**每次都抛，不自动清零**：一轮读失败的引擎行为是整段
    /// 跳过，用例要断言的正是「跳过了」，一次性的失败会让第二次读悄悄成功。
    var readError: Error?
    /// 本机有行、但**不在快照里**的那些行：作用域迁移原地留下的、当前作用域之外的备份行
    /// （R-exec-4）。`allPins()` 看不见它们，`allPinRows()` 必须看得见，否则差分把它们判成
    /// 删除。
    ///
    /// **是行，不是 lineage**（R-exec-11）：每一条备份行保护的是**它自己那条**
    /// `(lineage, owner)` 身份，所以它的 `spaceId` / `profileId` 必须写实。
    var outOfScopeRows: [PhiLocalPin] = []
    /// 本轮有没有一份可用的快照，**与生产实现同一条契约**：`isKnownLocalPin` 只在本轮最后
    /// 一次成功的 `allPins()` 或 `apply(_:)` 之后有意义，否则交出「不在」那个值；
    /// `allPinRows()` 在此之前抛。
    private(set) var snapshotIsLoaded = false
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

    /// 轮中作用域迁移的脚本（R-exec-12）：`accountScope()` 被问到第 `onAccountScopeRead` 次
    /// 时，**先取好返回值再**就地跑一次 `run`，然后清空自己。Task 8 的跟随迁移
    /// （`PhiChromiumCoordinator.applyAccountPinnedTabScope`）跑在一个 detached `Task` 里，
    /// 落点就在轮首取样与落地之间，这个钩子把那一刻搬进用例。
    ///
    /// **挂在 `accountScope()` 上而不是 `currentScope()` 上**：轮首那个闭包按
    /// `allPins()` → `currentScope()` → `accountScope()` 的次序取样，只有挂在**最后**那一个
    /// 上，轮首才会像现场那样把两个作用域都读成迁移**前**的值。挂在前两个任何一个上，
    /// `beginRound` 自己就读出一对不一致的值 —— 那是 §7.3 既有守卫已经挡住的另一个场景，
    /// 测不到这个 fix。
    ///
    /// 计数：`beginRound` 那一次是第 1 次，此后每一次 `rescanScopes` 各一次。
    var midRoundMigration: (onAccountScopeRead: Int, run: @MainActor (FakePinAccess) -> Void)?
    private(set) var accountScopeReads = 0

    func accountScope() -> PinnedTabScope? {
        accountScopeReads += 1
        let answer = account
        if let hook = midRoundMigration, hook.onAccountScopeRead == accountScopeReads {
            midRoundMigration = nil
            hook.run(self)
        }
        return answer
    }

    /// 开新一轮：把快照标成「没读过」。用例用它制造 R-exec-3 之后那三种无效状态。
    func beginRound() {
        snapshotIsLoaded = false
    }

    /// 非休眠的**全部**行，按 `(ownerKey, index, guid)` 有序。**不挑代表。**
    func allPins() throws -> [PhiLocalPin] {
        calls.append(.allPins)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return rows
            .filter { !$0.isDormant }
            .sorted { (Self.ownerKey($0), $0.index, $0.guid) < (Self.ownerKey($1), $1.index, $1.guid) }
    }

    /// 快照里的行加上作用域之外那些。生产实现是同一次 fetch 里未经作用域过滤的行；这里用
    /// 一个显式的 `outOfScopeRows` 表达同一件事，因为假件的 `rows` 本身没有「另一个作用域」
    /// 的概念。
    func allPinRows() throws -> [PhiLocalPin] {
        calls.append(.allPinRows)
        if let readError { throw readError }
        // 与生产实现同源：本轮没成功读过就抛，绝不交出一个会让差分把整批 pin 判成删除的
        // 空数组。
        guard snapshotIsLoaded else { throw LocalStoreWriteError.storeUnavailable }
        return (rows + outOfScopeRows).filter { !$0.isDormant }
    }

    /// 那一次 fetch 的行快照本身，**不再 fetch**、**不记调用**（理由同
    /// `FakeBookmarkAccess.cachedBookmarks()`）。过滤与次序都与 `allPins()` 相同。
    func cachedPins() -> [PhiLocalPin]? {
        guard snapshotIsLoaded else { return nil }
        return rows
            .filter { !$0.isDormant }
            .sorted { (Self.ownerKey($0), $0.index, $0.guid) < (Self.ownerKey($1), $1.index, $1.guid) }
    }

    /// **两边都过 `PinKind.lineageKey`**（P11），与生产实现同形：传进来的是线上归一过的小写
    /// lineage，而 `rows` 里那一列可能是大写。
    ///
    /// **判据是完整身份 `(lineage, ownerKey)`**，同生产实现：只按 lineage 比的话，一条
    /// `(L, spaceX)` 的行没了、而 `(L, spaceY)` 还在时照样答「在」。`ownerKey` 为 nil =
    /// 调用方反查不出本机 owner ⇒ 本机不可能有这条身份的行。
    func isKnownLocalPin(_ lineageId: String, ownerKey: String?) -> Bool {
        guard snapshotIsLoaded, let ownerKey else { return false }
        let wanted = PinKind.lineageKey(lineageId)
        return rows.contains {
            PinKind.lineageKey($0.lineageId) == wanted && Self.ownerKey($0) == ownerKey
        }
    }

    func apply(_ batch: PinApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        // 生产实现末尾会重读一次，于是 §4.5 的落地后复核在同一轮里就能做。抛错那一支走不
        // 到这里：真实现里那次重读排在写之后，写抛了就不会发生，快照保持原样。
        snapshotIsLoaded = true
        for op in batch.ops { land(op) }
    }

    /// Task 10 的回填写入口。语义与 `FakeBookmarkAccess` 上那一条逐字相同。
    private(set) var faviconWrites: [(guid: String, data: Data)] = []
    private(set) var faviconWriteCalls = 0
    var failSetFaviconOnce = false

    func setFavicon(_ writes: [(guid: String, data: Data)]) async throws {
        faviconWriteCalls += 1
        if failSetFaviconOnce {
            failSetFaviconOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        faviconWrites.append(contentsOf: writes)
    }

    func changeScope(to scope: PinnedTabScope,
                     preferredProfileId: String?,
                     preferredSpaceId: String?) async throws {
        calls.append(.changeScope(scope))
        self.scope = scope
        // 迁移重建了整批物理行，本轮那份快照与它已经没有关系了——生产实现在这里也只清不
        // 重读。
        snapshotIsLoaded = false
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

/// 内存版 `PhiURLRuleLocalAccess`（Task 8）。形状照 `FakeBookmarkAccess`：`apply(_:)` **真的把
/// `ops` 施加到 `rows` 上**，含两桶稠密重排，好让 Task 6 的引擎用例在假件上看到与真库同形的结果。
/// `readError` **每次都抛、不自动清零**（R-exec-3）；`snapshotIsLoaded` 与 `beginRound()` 守
/// 与生产实现同一条契约：两个缓存读者只在本轮最后一次成功的读或 `apply` 之后有意义。
@MainActor
final class FakeURLRuleAccess: PhiURLRuleLocalAccess {
    enum Call: Equatable {
        case allURLRules
        case allURLRulesIncludingDeleted
        case siblings(space: String)
        case liveOwners(count: Int)
        case apply(opCount: Int)
        /// Task 6：落地提交之后那一次显式的路由表刷新（§6.6 / R-M3-4a-34）。
        case refreshRoutingTable
    }

    /// 含软删行（`deletedDate != nil`）。两个读口按自己的定义域过滤。
    var rows: [PhiLocalURLRule]
    /// 让两个读口与 `liveOwners` 抛。**每次都抛，不自动清零。**
    var readError: Error?
    private(set) var snapshotIsLoaded = false
    /// 下一次 `apply` 抛 `LocalStoreWriteError.storeUnavailable`，然后清零。**一行都不改。**
    var failApplyOnce = false
    /// 下一次 `apply` 抛这个错，然后清零。**一行都不改。**
    var applyErrorOnce: Error?
    private(set) var calls: [Call] = []
    /// 最近一次 `apply` 收到的 `ops`（抛错的那次也记）。
    private(set) var lastAppliedOps: [URLRuleSyncOp] = []

    init(rows: [PhiLocalURLRule] = []) {
        self.rows = rows
    }

    /// 开新一轮：把快照标成「没读过」。
    func beginRound() {
        snapshotIsLoaded = false
    }

    /// 活行，按 `(spaceId, sortOrder, id)` 有序——喂给引擎的次序必须是生产实现真会产出的那个。
    func allURLRules() throws -> [PhiLocalURLRule] {
        calls.append(.allURLRules)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return Self.ordered(rows.filter { $0.deletedDate == nil })
    }

    /// 活行 ∪ 软删行，同一次序。
    func allURLRulesIncludingDeleted() throws -> [PhiLocalURLRule] {
        calls.append(.allURLRulesIncludingDeleted)
        if let readError { throw readError }
        snapshotIsLoaded = true
        return Self.ordered(rows)
    }

    /// 本页快照按 `spaceId` 的分组：**软删行排除**（R-M3-4a-51），不按合格性过滤。
    func siblings(inSpaceId spaceId: String) -> [PhiLocalURLRule] {
        calls.append(.siblings(space: spaceId))
        guard snapshotIsLoaded else { return [] }
        return Self.ordered(rows.filter { $0.spaceId == spaceId && $0.deletedDate == nil })
    }

    /// 判据是 `syncId`、不是 `id`，定义域与 `allURLRules()` 同源（活行）。
    func isKnownLocalURLRule(_ syncId: String) -> Bool {
        guard snapshotIsLoaded else { return false }
        return rows.contains { $0.syncId == syncId && $0.deletedDate == nil }
    }

    /// 生产实现自己做一次 fetch、不读本页缓存，所以这里也不看 `snapshotIsLoaded`。只填
    /// `claimed`；`owners` 由 Task 6 的注册项闭包配 `OwnedOwnerMaps` 补。
    func liveOwners(_ candidates: Set<String>) throws -> OwnedLiveRows {
        calls.append(.liveOwners(count: candidates.count))
        if let readError { throw readError }
        let live = Set(rows.filter { $0.deletedDate == nil }.compactMap(\.syncId))
        return OwnedLiveRows(claimed: candidates.intersection(live), owners: [:])
    }

    func apply(_ batch: URLRuleApplyBatch) async throws {
        calls.append(.apply(opCount: batch.ops.count))
        lastAppliedOps = batch.ops
        if failApplyOnce {
            failApplyOnce = false
            throw LocalStoreWriteError.storeUnavailable
        }
        if let applyErrorOnce {
            self.applyErrorOnce = nil
            throw applyErrorOnce
        }
        var touchedBuckets: Set<String> = []
        for op in batch.ops {
            land(op, touchedBuckets: &touchedBuckets)
        }
        for bucket in touchedBuckets {
            densify(bucket)
        }
        // 生产实现末尾会重读一次，于是落地后的复核在同一轮里就能做。
        snapshotIsLoaded = true
    }

    /// 只记一条调用（`calls` 有序，CASE U-24 断言它排在 `.apply` 之后、且一页一条）。
    func refreshRoutingTableAfterLanding() {
        calls.append(.refreshRoutingTable)
    }

    private static func ordered(_ rows: [PhiLocalURLRule]) -> [PhiLocalURLRule] {
        rows.sorted { ($0.spaceId, $0.sortOrder, $0.id) < ($1.spaceId, $1.sortOrder, $1.id) }
    }

    /// 与 `LocalStore.applyURLRuleSyncBatchBody` 同形：寻址含软删行；`.create` / `.update` /
    /// `.move` 命中就写九个字段并清 `deletedDate` / `mergePartnerSyncId`，不命中就建行；
    /// `.reorder` 只写 `sortOrder`；`.delete` 真删。`pendingLocalEdit` 一个字节不碰。
    private func land(_ op: URLRuleSyncOp, touchedBuckets: inout Set<String>) {
        switch op {
        case .create(let values), .update(let values), .move(let values):
            let existing = rows.firstIndex { $0.syncId == values.syncId }
            let sourceBucket = existing.map { rows[$0].spaceId }
            // 与生产 body 同一条规则：建行或救回软删行都算「进了桶」，在写之前读。
            let entersBucket = existing.map { rows[$0].deletedDate != nil } ?? true
            if let index = existing {
                rows[index].spaceId = values.spaceId
                rows[index].host = values.host
                rows[index].pathPrefix = values.pathPrefix
                rows[index].askBeforeRouting = values.askBeforeRouting
                rows[index].sortOrder = values.sortOrder
                rows[index].createdDate = values.createdDate
                rows[index].contentUpdatedDate = values.contentUpdatedDate
                rows[index].targetUpdatedDate = values.targetUpdatedDate
                rows[index].deletedDate = nil
                rows[index].mergePartnerSyncId = nil
            } else {
                rows.append(PhiLocalURLRule(id: UUID().uuidString, syncId: values.syncId,
                                            spaceId: values.spaceId, host: values.host,
                                            pathPrefix: values.pathPrefix,
                                            askBeforeRouting: values.askBeforeRouting,
                                            sortOrder: values.sortOrder, createdDate: values.createdDate,
                                            contentUpdatedDate: values.contentUpdatedDate,
                                            targetUpdatedDate: values.targetUpdatedDate,
                                            deletedDate: nil, pendingLocalEdit: false,
                                            mergePartnerSyncId: nil))
            }
            switch op {
            case .move:
                if let sourceBucket { touchedBuckets.insert(sourceBucket) }
                touchedBuckets.insert(values.spaceId)
            case .create:
                touchedBuckets.insert(values.spaceId)
            default:
                // `.update`：只有进了桶（建行 / 救回软删行）、或（防御）目标真的变了才记桶。
                if entersBucket {
                    touchedBuckets.insert(values.spaceId)
                } else if let sourceBucket, sourceBucket != values.spaceId {
                    touchedBuckets.insert(sourceBucket)
                    touchedBuckets.insert(values.spaceId)
                }
            }
        case .reorder(let syncId, _, let sortOrder):
            guard let index = rows.firstIndex(where: { $0.syncId == syncId }) else { return }
            rows[index].sortOrder = sortOrder
            touchedBuckets.insert(rows[index].spaceId)
        case .delete(let syncId):
            for row in rows where row.syncId == syncId {
                touchedBuckets.insert(row.spaceId)
            }
            rows.removeAll { $0.syncId == syncId }
        }
    }

    /// 该桶的活行按 `(sortOrder, id)` 升序写 `0..<n`。
    private func densify(_ bucket: String) {
        let live = rows.indices
            .filter { rows[$0].spaceId == bucket && rows[$0].deletedDate == nil }
            .sorted { (rows[$0].sortOrder, rows[$0].id) < (rows[$1].sortOrder, rows[$1].id) }
        for (position, index) in live.enumerated() {
            rows[index].sortOrder = position
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

extension PhiLocalURLRule {
    /// 默认目标 `space-a`（`OwnerResolver.fixture()` 映到 `su-1`）。`syncId` 默认 nil 与书签 /
    /// pin 的 fixture 同款，投影用例自己传；两枚行戳默认 nil ⇒ 无基线投影退回 `createdDate`。
    static func fixture(id: String = "i1", syncId: String? = nil,
                        spaceId: String = "space-a", host: String = "github.com",
                        pathPrefix: String? = nil, askBeforeRouting: Bool = false,
                        sortOrder: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date? = nil, targetUpdatedDate: Date? = nil,
                        deletedDate: Date? = nil, pendingLocalEdit: Bool = false,
                        mergePartnerSyncId: String? = nil) -> PhiLocalURLRule {
        PhiLocalURLRule(id: id, syncId: syncId, spaceId: spaceId, host: host,
                        pathPrefix: pathPrefix, askBeforeRouting: askBeforeRouting,
                        sortOrder: sortOrder, createdDate: createdDate,
                        contentUpdatedDate: contentUpdatedDate,
                        targetUpdatedDate: targetUpdatedDate, deletedDate: deletedDate,
                        pendingLocalEdit: pendingLocalEdit,
                        mergePartnerSyncId: mergePartnerSyncId)
    }
}

extension URLRuleLandingValues {
    /// 一次落地写的九个取值；三枚戳默认同一时刻，钉戳的用例自己传。
    static func fixture(syncId: String = "R1", spaceId: String = "S1", host: String = "github.com",
                        pathPrefix: String? = nil, askBeforeRouting: Bool = false, sortOrder: Int = 0,
                        createdDate: Date = Date(timeIntervalSince1970: 1_000),
                        contentUpdatedDate: Date = Date(timeIntervalSince1970: 1_000),
                        targetUpdatedDate: Date = Date(timeIntervalSince1970: 1_000)) -> URLRuleLandingValues {
        URLRuleLandingValues(syncId: syncId, spaceId: spaceId, host: host, pathPrefix: pathPrefix,
                             askBeforeRouting: askBeforeRouting, sortOrder: sortOrder,
                             createdDate: createdDate, contentUpdatedDate: contentUpdatedDate,
                             targetUpdatedDate: targetUpdatedDate)
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

/// 一条 URL Rule 实体。
///
/// 三个合并单元各带自己的戳（§8.2）：内容组三个成员共用 `contentStamp`（载体是 `host`，
/// 发送时写成相等）、`target_space_uuid` 带 `targetStamp`、`rank` 带 `rankStamp`。
/// `path_prefix` 默认发显式的 `""`（线上的「匹配任意路径」编码，本机是 nil）——与
/// `bookmarkPayload` 的 `secondary_url` 同一个理由：省略会让 fixture 与它自己的快照在
/// `has_…` 上不同，每一条「这一轮不发布」的断言都会看到一次虚假 commit。
func urlRulePayload(uuid: String,
                    targetSpaceUuid: String = "su-1",
                    host: String = "github.com",
                    pathPrefix: String = "",
                    ask: Bool = false,
                    rank: String = "V",
                    contentStamp: Int64 = 100,
                    targetStamp: Int64 = 100,
                    rankStamp: Int64 = 100,
                    source: Int64 = 0,
                    createdAtMs: Int64 = 1_000) -> Phi_PhiURLRuleEntity {
    var entity = Phi_PhiURLRuleEntity()
    entity.ruleUuid = uuid
    entity.host = stamped(host, at: contentStamp)
    entity.pathPrefix = stamped(pathPrefix, at: contentStamp)
    entity.ask = stamped(ask, at: contentStamp)
    entity.targetSpaceUuid = stamped(targetSpaceUuid, at: targetStamp)
    entity.rank = stamped(rank, at: rankStamp)
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

func envelope(_ payload: Phi_PhiURLRuleEntity) -> Phi_PhiEntity {
    var out = Phi_PhiEntity()
    out.urlRule = payload
    return out
}

func baselineBytes(_ payload: Phi_PhiURLRuleEntity) -> Data {
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

// MARK: - 游标 fixture 与内存 store

/// 一条**活**游标：没有 `deletedAtMs`，也没有任何待办位。参数只开了用例真正会挑的那几个
/// 字段，其余走 `PhiOwnedItemCursor` 自己的默认值——一条用例写出来的字段就是它在乎的字段。
func ownedCursor(reconciled: Data? = nil, server: Data? = nil,
                 entityId: String = "", version: Int64 = 0,
                 ownerUuid: String? = nil) -> PhiOwnedItemCursor {
    var cursor = PhiOwnedItemCursor()
    cursor.entityId = entityId
    cursor.version = version
    cursor.reconciled = reconciled
    cursor.server = server
    cursor.ownerUuid = ownerUuid
    return cursor
}

/// 一条**待发 tombstone** 的游标：`pendingDelete` 已经置起，`deleteDecidedAtMs` 是差分作出
/// 那个删除决定的时刻（§5.6 的 L1 支拿它与入站实体的 `location` 时间戳比）。
/// `deletedAtMs` 仍是 nil——删除还没被服务端接受，还没定案。
func pendingDeleteCursor(decidedAtMs: Int64, entityId: String = "srv-1",
                         version: Int64 = 1, rejectRounds: Int = 0,
                         reconciled: Data? = nil) -> PhiOwnedItemCursor {
    var cursor = ownedCursor(reconciled: reconciled, entityId: entityId, version: version)
    cursor.pendingDelete = true
    cursor.deleteDecidedAtMs = decidedAtMs
    cursor.deleteRejectRounds = rejectRounds
    return cursor
}

/// 一条**已清理**的 Space 游标，保留期级联（§9.3）用：形状照 `PhiSpaceSyncTable.purgeExpired`
/// 留下的那个 tombstone——`entityId` / `version` 保留，`hidden` 与 `deletedAtMs` 在
/// （`hidden ⇒ deletedAtMs != nil` 是 Space 侧的不变量），再盖上 `purgedAtMs`。
func purgedSpaceCursor(purgedAtMs: Int64 = 1) -> PhiSpaceCursor {
    var cursor = PhiSpaceCursor()
    cursor.entityId = "srv-space"
    cursor.version = 1
    cursor.hidden = true
    cursor.deletedAtMs = purgedAtMs
    cursor.purgedAtMs = purgedAtMs
    return cursor
}

/// 内存版 `PhiOwnedItemStateStore`。`: AnyObject` 是协议要求的，也是这个假件的前提：
/// 测试改了 `table`，引擎下一次 `load` 就该看得到。
final class MemoryOwnedItemStore: PhiOwnedItemStateStore {
    var table: PhiOwnedItemTable
    /// 每次 `load` 都报损（= 那个文件没了）。
    var forcedLoss = false
    /// 只在第 N 次 `load` 报损（N 从 1 数）——「apply 段读到旧表、发布段才发现丢失」这一类
    /// 用例要的就是这个：两次 `load` 之间的那一半轮次必须照常跑完。
    var loseOnLoadNumber: Int?
    private(set) var deleted = false
    /// 每一次 `load` 收到的 `hadRecords`，按调用序。报损判据只随它变，断言它就是断言引擎
    /// 把哪一条 per-kind 标志喂了进来。
    private(set) var hadRecordsSeen: [Bool] = []
    /// 置真 ⇒ 每一次 `save` 都回 false 并**不改** `table`（R-M3-4a-83 的内存版）。
    /// 用例自己置回 false 放行。
    var failNextSave = false
    /// 只让第 N 次 `save` 失败（N 从 1 数，按 `saveCalls` 数）——B-2 的用例要「最后一页那次
    /// 落地写」「发布段那一次」这种精确注入。失败那一次同样**不改** `table`。
    var failSaveOnCallNumber: Int?
    private(set) var saveCalls = 0

    init(table: PhiOwnedItemTable = PhiOwnedItemTable()) {
        self.table = table
    }

    /// 报损那一路**与真 store 逐字同形**，四种情形一个不少：`forcedLoss` 与
    /// `loseOnLoadNumber` 是「文件没了 / 解不开 / 版本偏低」的脚本化对应物，**而「表里一条
    /// 游标都没有」这一条必须自己成立**——`FileOwnedItemStateStore` 对空表照样报损（CASE
    /// 3.6），少了它，一个拿着空表的假件会让 Task 6 / 9 的用例在「正常一轮、什么都没丢」上
    /// 变绿，而线上代码在同一处报损并重放整个 data type。
    ///
    /// `reportedLoss` 一律取 `hadRecords`（`forcedLoss` 说的是「文件没了」，不是「无条件报
    /// 真」——`hadRecords == false` 时文件本来就不该存在，那不是丢失）。`table` 本身不动，
    /// 好让用例还能断言「引擎后来写回去的是什么」。
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
        hadRecordsSeen.append(hadRecords)
        let loses = forcedLoss || loseOnLoadNumber == hadRecordsSeen.count || table.cursors.isEmpty
        guard loses else { return (table, false) }
        return (PhiOwnedItemTable(), hadRecords)
    }

    @discardableResult
    func save(_ table: PhiOwnedItemTable) -> Bool {
        saveCalls += 1
        guard !failNextSave, failSaveOnCallNumber != saveCalls else { return false }
        self.table = table
        return true
    }

    func deleteFile() {
        deleted = true
        table = PhiOwnedItemTable()
    }
}

/// 内存版 `PhiSyncMarkerStore`（M3-4a Task 3）。形状照上面的 `MemoryOwnedItemStore`，并且
/// 同样是**顶层类型**：`PhiSyncMarkerBoundaryTests` 与 `SelfRevokeTests` 跨文件共用同一个
/// 假件，不各抄一份。
///
/// `saves` 记**每一次** `save` 调用收到的表（失败的那一次也记），所以 `saves.count` 就是
/// 调用计数，`failSaveOnCallNumber` 数的正是它；「一次写都没有」断言 `saves.isEmpty`。
final class MemoryMarkerStore: PhiSyncMarkerStore {
    var file: PhiSyncMarkerFile
    /// 每次 `save` 都失败（= 盘满 / 目录不可写）。Task 2b 的第三个置位点用它。
    var failSave = false
    /// 只让第 N 次 `save` 失败（N 从 1 数）——逐页边界的用例要「第 3 页那一次写失败」。
    var failSaveOnCallNumber: Int?
    private(set) var saves: [PhiSyncMarkerFile] = []
    private(set) var loadCount = 0
    private(set) var deleted = false

    init(file: PhiSyncMarkerFile = PhiSyncMarkerFile()) {
        self.file = file
    }

    func load() -> PhiSyncMarkerFile {
        loadCount += 1
        return file
    }

    /// 失败那一路**不改 `file`**（R-M3-4a-83 的内存版）：内存与「磁盘」一起停在旧表上。
    @discardableResult
    func save(_ file: PhiSyncMarkerFile) -> Bool {
        saves.append(file)
        if failSave || failSaveOnCallNumber == saves.count { return false }
        self.file = file
        return true
    }

    /// 删，不是存一张空表：只置 `deleted`，`file` 复位成空表——下一次 `load` 交回的正是
    /// 真 store「文件不存在」那一路的结论。
    func deleteFile() {
        deleted = true
        file = PhiSyncMarkerFile()
    }
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

        _ = try fake.allBookmarks()
        try await fake.apply(BookmarkApplyBatch(unordered: [.delete(guid: "g1")]))

        let calls = fake.calls
        XCTAssertEqual(calls, [.allBookmarks, .apply(opCount: 1)])
    }

    /// CASE 0.4 — `siblings` 不产生第二次读。
    ///
    /// 防的是什么：把 `siblings` 实现成第二次 fetch，一棵上千行的树每轮要扫好几遍，而且
    /// 两次之间用户可能改过行。
    func testSiblingsIsAnInMemoryGroupingRatherThanASecondFetch() throws {
        let fake = FakeBookmarkAccess(rows: [
            .fixture(guid: "a", parentGuid: "p", index: 0),
            .fixture(guid: "b", parentGuid: "p", index: 1),
        ])

        _ = try fake.allBookmarks()
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

// MARK: - 归属解析器 fixture

extension OwnerResolver {
    /// 本里程碑全部归属项用例的公共解析器：`space-a → su-1`、`space-b → su-2`、
    /// `Default → pu-1`，反向映射由正向表现算，两个方向**永远一致**——手写两张表迟早
    /// 会漂，而一条只在单方向存在的映射会让「归属解析不到」这一支在本该绿的用例上变红。
    ///
    /// `ineligible` 里的 syncUuid 让 `isEligibleSpace` 返回 false（模拟 hidden / purged）。
    /// 它对**不在表里**的 uuid 返回 true：`isEligibleSpace` 的判据只对 Space 归属有意义，
    /// pin 的 profile / app 归属走的是另外两个成员，被它一刀切掉会让整类 pin 停止发布。
    static func fixture(spaceUuids: [String: String] = ["space-a": "su-1", "space-b": "su-2"],
                        profileUuids: [String: String] = ["Default": "pu-1"],
                        ineligible: Set<String> = []) -> OwnerResolver {
        var spacesByUuid: [String: String] = [:]
        for (localId, uuid) in spaceUuids { spacesByUuid[uuid] = localId }
        var profilesByUuid: [String: String] = [:]
        for (localId, uuid) in profileUuids { profilesByUuid[uuid] = localId }
        return OwnerResolver(syncUuid: { spaceUuids[$0] },
                             localSpaceId: { spacesByUuid[$0] },
                             isEligibleSpace: { !ineligible.contains($0) },
                             globalUuid: { profileUuids[$0] },
                             localProfileId: { profilesByUuid[$0] })
    }
}
