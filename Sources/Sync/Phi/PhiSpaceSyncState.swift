// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

extension Notification.Name {
    /// Posted whenever the engine pushes a new hidden / unsynced set back to
    /// `PhiSpaceSyncState.shared`. `SpaceManager` re-runs `handleSpacesUpdate`
    /// on its UNFILTERED `lastStoreSpaces` snapshot when it arrives, so
    /// unhiding needs no SwiftData write at all (§6.6).
    static let phiSpaceHiddenSetDidChange = Notification.Name("phiSpaceHiddenSetDidChange")
}

/// Per-Space sync shadow. One of these per `space_uuid`; the whole table lives
/// in the account plist under `sync.phiSpaces`, so it is account-isolated by
/// construction and needs no entry in `PhiSyncEngine.stateKeys`.
struct PhiSpaceCursor: Codable, Equatable {
    var entityId: String?
    var version: Int64 = 0
    /// Serialized `Phi_PhiSpaceEntity`: the change-detection baseline
    /// (the Space-side analogue of M3-1's `<key>.phiSyncVal` + `.phiSyncTs`).
    var reconciled: Data?
    /// Serialized `Phi_PhiSpaceEntity`: what the SERVER holds (M3-1's
    /// `storedLastEntity`), which is what suppresses a redundant push. Never
    /// the merge result -- see §6.2's five baseline write points.
    var server: Data?
    /// A decrypted entity parked while the D2 question is open, or while its
    /// `profile_uuid` still resolves to no local profile (§3.5 fallback B).
    var pendingApply: Data?
    /// Remote binding on an ALREADY-LANDED Space that resolves to no local
    /// profile (§3.5 fallback A). Echoed back with `reconciled`'s own
    /// timestamp, never stamped `now`.
    var heldProfileUuid: String?
    /// The LOCAL profile the hold above was taken against. §3.5: "本机之后主动
    /// 换绑该 Space 时清掉它并按普通字段盖 `now`" -- without this the snapshot
    /// cannot tell "the user has since rebound this Space locally" from "nothing
    /// changed", because the `reconciled` baseline records the REMOTE value and
    /// the local side has no baseline of its own. When this no longer equals the
    /// row's `profileId`, the hold is stale and the local binding is published
    /// normally.
    var heldForLocalProfileId: String?
    var pendingDelete = false
    /// Consecutive INVALID_MESSAGE rejections of this tombstone (§5.1).
    var deleteRejectRounds = 0
    /// A remote tombstone identified by hash but not landed yet (import lock).
    var pendingTombstone = false
    var deletedAtMs: Int64?
    /// Not in the strip: D2 "account wins", or a soft delete.
    var hidden = false
    /// Agent / incognito / excluded: recorded so it is not decrypted and
    /// refused again every round. Such a cursor has NO `entityId`, which is
    /// what makes §9.1's delete-origin criterion safe.
    var refusedAtMs: Int64?
    /// The 30-day sweep ran: baselines dropped, the cursor itself kept forever
    /// as a tombstone record (§9.2).
    var purgedAtMs: Int64?
}

/// 每个 **syncUuid** 一张游标（M3-2b §3.1，R-D6-8）。**键是账户级同步 uuid，不是
/// 本地 spaceId**，三条理由缺一不可：
///  1. 游标本来就会为没有本地行的 uuid 存在（被 §6.5 拒绝的 agent 实体只带
///     `refusedAtMs`；清理过的 tombstone 游标在本地数据级联删除后仍永久保留）；
///  2. tag hash 从 syncUuid 派生（`PhiSyncEntity.spaceClientTag`），tombstone 的
///     身份反查只有这一条路；
///  3. 防复活守卫必须在映射行被删之后继续有效。
///
/// 整张表在账户 plist 的 `sync.phiSpaces` 下，所以它按账户隔离，不需要进
/// `PhiSyncEngine.stateKeys`。
struct PhiSpaceSyncTable: Codable, Equatable {
    /// M3-2 未发布，所以**不写迁移代码**：低于这个版本的表整张丢掉（§3.6）。
    static let currentFormatVersion = 2
    var formatVersion: Int = currentFormatVersion
    /// 按 **syncUuid** 键。
    var cursors: [String: PhiSpaceCursor] = [:]
    /// "keepBoth" | "accountWins" | nil = still pending (§8).
    var firstSyncDecision: String?
    var drainInProgress = false
    var hasDrainedFullReplay = false
    var hadRecords = false
    var spaceSectionEnabled = false
    var markerMovedWhileGateShut = false
    var didReplayForEmptyTable = false
    var lastDrainedBirthday: String?
    /// `client_tag_hash` -> lastSeenAtMs. Rows the server holds under data type
    /// 2000 that this device pulled but could not turn into a Space. Keyed by
    /// hash because a failed decrypt yields no `space_uuid`. Guard 3 refuses to
    /// commit any entry whose tag hash is in here (§5.5).
    var unreadableTagHashes: [String: Int64] = [:]

    // MARK: - Derived sets

    /// `cursor.hidden` 的全集，**按 syncUuid**。D6 之后 hidden 只剩一种含义：远端
    /// 软删（`hidden ⇒ deletedAtMs != nil` 是不变量）。翻回本地 id 是
    /// `PhiSpaceSyncState.refreshCaches` 的事（§3.5）。
    var hiddenSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.hidden }.keys)
    }

    /// 账户里**确实存在**这条实体的 syncUuid 全集（`entityId != nil`）。
    /// `blocksProfileDeletion` 的第三条判据要的那半句（§3.5）：它跑在主 actor 上、
    /// 手里没有表，所以这半句只能在这里算好推回去。
    var publishedSyncUuids: Set<String> {
        Set(cursors.filter { $0.value.entityId != nil }.keys)
    }

    /// ONLY the D2 kind (§8.3): a soft-deleted Space is hidden too, but it is
    /// not "a Space that only exists on this Mac", "join account sync" is a dud
    /// for it, and the 30-day sweep would cascade it away days later.
    ///
    /// D2 残留，随 §8 的删除清单一起走（Task 9）。
    var unsyncedSpaceIds: Set<String> {
        Set(cursors.filter { $0.value.hidden && $0.value.deletedAtMs == nil }.keys)
    }

    // MARK: - Mutations (the engine runs these on its round queue; the facade
    // runs the same code directly only when no engine exists -- §5.3)

    /// §9.1: mark ONLY a uuid that has actually been published to the account
    /// and still belongs to it. The criterion is `entityId`, NOT "the table has
    /// a cursor": agent / incognito entities refused by §6.5 own a cursor with
    /// only `refusedAtMs`, D2-hidden Spaces own one with only `hidden`.
    /// Returns whether anything changed.
    ///
    /// D6：**参数是 syncUuid**（表按 syncUuid 键）。本地 id 在两条边界上翻译，
    /// 两条都在这个文件之外：引擎的 `PhiSyncEngine.run(_:)` 的 `.recordLocalDeletion`
    /// 分支，以及无引擎回退路径 `PhiSpaceSyncState.deliver(_:)`。翻不出来就是
    /// 「从来没发布过」，两条边界都直接返回，不会走到这里。
    @discardableResult
    mutating func recordLocalDeletion(spaceId: String) -> Bool {
        guard var cursor = cursors[spaceId],
              cursor.entityId != nil,
              cursor.deletedAtMs == nil,
              cursor.hidden == false,
              cursor.pendingDelete == false else { return false }
        cursor.pendingDelete = true
        cursors[spaceId] = cursor
        return true
    }

    /// §8.3's second gate: a soft-deleted Space must never be put back in the
    /// strip, and a uuid that is already in the account never belonged in the
    /// "not synced to the account" section in the first place.
    @discardableResult
    mutating func joinAccountSync(spaceId: String) -> Bool {
        guard var cursor = cursors[spaceId], cursor.hidden,
              cursor.deletedAtMs == nil, cursor.entityId == nil else { return false }
        cursor.hidden = false
        cursors[spaceId] = cursor
        return true
    }

    /// Soft deletes older than the retention window: returns the uuids whose
    /// local data the caller must now cascade away, and trims their cursors to
    /// permanent tombstones (§9.2 -- the cursor itself is never dropped).
    mutating func purgeExpired(nowMs: Int64) -> [String] {
        var purged: [String] = []
        for (uuid, cursor) in cursors {
            guard let deletedAtMs = cursor.deletedAtMs, cursor.purgedAtMs == nil,
                  nowMs - deletedAtMs > PhiSpaceSyncState.retentionMs else { continue }
            var tombstone = PhiSpaceCursor()
            tombstone.entityId = cursor.entityId
            tombstone.version = cursor.version
            tombstone.hidden = true
            tombstone.deletedAtMs = deletedAtMs
            tombstone.purgedAtMs = nowMs
            cursors[uuid] = tombstone
            purged.append(uuid)
        }
        return purged.sorted()
    }

    /// §9.4 criteria 1 and 2, as ONE implementation (R4): every global profile
    /// uuid an account Space (from either baseline) or a held binding still
    /// points at. Soft-deleted and purged cursors do not count.
    ///
    /// `PhiSpaceSyncState.refreshCaches` builds its `referencedProfileUuids`
    /// cache from this and nothing else. A second copy of the predicate --
    /// deserialize both baselines, compare `profileUuid.stringValue`, skip the
    /// soft-deleted -- is exactly the drift R4 rejects for `lwwWinner` /
    /// `signature`: the two would eventually disagree about whether a Profile is
    /// deletable, in opposite directions on the two call sites.
    func referencedProfileUuids() -> Set<String> {
        var referenced: Set<String> = []
        for cursor in cursors.values where cursor.deletedAtMs == nil {
            if let held = cursor.heldProfileUuid, !held.isEmpty { referenced.insert(held) }
            for bytes in [cursor.server, cursor.reconciled].compactMap({ $0 }) {
                guard let entity = try? Phi_PhiSpaceEntity(serializedBytes: bytes) else { continue }
                let uuid = entity.profileUuid.stringValue
                if !uuid.isEmpty { referenced.insert(uuid) }
            }
        }
        return referenced
    }

    func referencesProfileUuid(_ uuid: String) -> Bool {
        referencedProfileUuids().contains(uuid)
    }

    /// `load()` 的版本闸。`nil`（键不存在，或 `codableValue` 解码失败）与低版本走
    /// 同一条路：一张空表。
    static func loaded(from decoded: PhiSpaceSyncTable?) -> PhiSpaceSyncTable {
        guard let decoded, decoded.formatVersion >= currentFormatVersion else {
            return PhiSpaceSyncTable()
        }
        return decoded
    }

    /// 判据定义在**原始值**上，不是在 `load()` 上。`AccountUserDefaults.codableValue`
    /// 对「键不存在」与「解码失败」返回同一个 nil，而 `load()` 把两者一起塌成一张空
    /// 表——于是「表是旧的」与「从来没有表」在 `load()` 之后不可区分，照那样实现会让
    /// 每一台首次启动的机器都报「已丢弃」。
    ///
    /// **没有键 ⇒ false，什么都不写。**
    static func isStaleFormat(rawData: Data?) -> Bool {
        guard let rawData else { return false }
        guard let decoded = try? JSONDecoder().decode(PhiSpaceSyncTable.self, from: rawData) else {
            return true
        }
        return decoded.formatVersion < currentFormatVersion
    }
}

protocol PhiSpaceSyncStateStore: AnyObject {
    func load() -> PhiSpaceSyncTable
    func save(_ table: PhiSpaceSyncTable)
}

/// The table in the account plist, next to `sync.profileGlobalUuids`.
/// `AccountUserDefaults` writes `users/<userID>/defaults/account_defaults.plist`,
/// so the table is account-scoped for free.
final class AccountPhiSpaceSyncStateStore: PhiSpaceSyncStateStore {
    static let defaultsKey = "sync.phiSpaces"
    private let defaults: AccountUserDefaults

    init(defaults: AccountUserDefaults) { self.defaults = defaults }

    func load() -> PhiSpaceSyncTable {
        PhiSpaceSyncTable.loaded(from: defaults.codableValue(forKey: Self.defaultsKey))
    }

    func save(_ table: PhiSpaceSyncTable) {
        defaults.set(table, forCodableKey: Self.defaultsKey)
    }

    /// true = 盘上确实有一张旧表、已被丢弃（§3.6）。**没有键**（从没同步过的机器、
    /// 刚登录的机器、ARK 一直锁着的机器）返回 **false**，什么都不写。
    /// 判据与写入分开在 `PhiSpaceSyncTable.isStaleFormat(rawData:)` 里，这里只有
    /// 一次读、一个 guard 和一次写，没有自己的分支。
    @discardableResult
    func discardIfStaleFormat() -> Bool {
        guard PhiSpaceSyncTable.isStaleFormat(rawData: defaults.data(forKey: Self.defaultsKey)) else {
            return false
        }
        save(PhiSpaceSyncTable())
        return true
    }
}

/// Main-thread face of the table for `SpaceManager` and the settings UI.
///
/// SINGLE WRITER (§5.3): the table is owned by the engine actor. Everything
/// here is either a READ-ONLY cache the engine pushes back, or an INTENT the
/// engine executes on its serial round queue. The one exception is "there is no
/// engine" (signed out, ARK locked, `stopPhiSync()` done), where nobody else can
/// be writing and the facade may touch the store directly.
@MainActor
final class PhiSpaceSyncState {
    static let shared = PhiSpaceSyncState()

    /// `nonisolated` because `PhiSpaceSyncTable.purgeExpired(nowMs:)` -- a
    /// nonisolated mutating func on a struct the engine owns off the main actor
    /// -- reads it. Without it this is a Swift 6 hard error and a Swift 5
    /// warning at every such read.
    nonisolated static let retentionMs: Int64 = 30 * 24 * 60 * 60 * 1000

    enum Intent {
        case recordLocalDeletion(String)
        case joinAccountSync(String)
        case runRetentionSweep
    }

    /// Set by `PhiChromiumCoordinator` while an engine exists; nil means the
    /// direct-store fallback applies.
    var intentSink: ((Intent) -> Void)?
    /// Used only on the no-engine path.
    var directStore: PhiSpaceSyncStateStore?
    /// localProfileId -> account-global uuid (`ProfileKeyManager` mapping).
    var globalUuidLookup: ((String) -> String?)?
    /// syncUuid -> 本地 spaceId。`refreshCaches` 把 `hiddenSyncUuids` 翻回本地 id
    /// 的唯一入口（§3.5）。
    var localSpaceIdLookup: ((String) -> String?)?
    /// 本地 spaceId -> syncUuid。**反方向**，两个消费者：`blocksProfileDeletion`
    /// 的第三条判据——它跑在主 actor 上、手里没有表，`localSpaceIdLookup` 方向反了，
    /// 用不上（§2.2 / §3.5）；以及 `deliver` 的无引擎回退路径，它要在写进按 syncUuid
    /// 键的表之前把本地 id 翻过去（与引擎边界同一条规则，§3.4）。
    var syncUuidLookup: ((String) -> String?)?
    /// Every LOCAL Space row with its profile, unfiltered by §6.6's funnel --
    /// `account.localStorage.getAllSpaces()` in production. Needed for §9.4's
    /// third criterion (hidden local Spaces have no cursor `profile_uuid`).
    var localSpaceProfileIds: (() -> [(spaceId: String, profileId: String)])?

    /// 一组**本地** spaceId（语义不变）：`SpaceManager.handleSpacesUpdate` 的漏斗
    /// 过滤（SpaceManager.swift:2691-2692）读的就是它，那一处零改动。
    private(set) var hiddenSpaceIds: Set<String> = []
    /// D2 残留（Task 9 随 §8 一起删）。
    private(set) var unsyncedSpaceIds: Set<String> = []
    /// 账户里确实存在其实体的 syncUuid（§3.5）。**不参与** `changed` 比较。
    private(set) var publishedSyncUuids: Set<String> = []
    private(set) var hasDrainedFullReplay = false
    private var referencedProfileUuids: Set<String> = []

    func isHidden(_ spaceId: String) -> Bool { hiddenSpaceIds.contains(spaceId) }

    /// Called by the engine after every table write, and by the fallback path.
    func refreshCaches(from table: PhiSpaceSyncTable) {
        // 边界翻译（§3.5）：表按 syncUuid 键，而漏斗过滤要的是一组**本地** id。
        // 解析不到的丢弃——那是没有本地行的软删／拒绝游标，本来也不该出现在过滤
        // 集合里。
        let hidden = Set(table.hiddenSyncUuids.compactMap { localSpaceIdLookup?($0) })
        let unsynced = table.unsyncedSpaceIds
        // One implementation of the reference rule, on the table (R4).
        let referenced = table.referencedProfileUuids()
        let changed = hidden != hiddenSpaceIds || unsynced != unsyncedSpaceIds
        hiddenSpaceIds = hidden
        unsyncedSpaceIds = unsynced
        publishedSyncUuids = table.publishedSyncUuids
        referencedProfileUuids = referenced
        hasDrainedFullReplay = table.hasDrainedFullReplay
        if changed {
            NotificationCenter.default.post(name: .phiSpaceHiddenSetDidChange, object: self)
        }
    }

    func recordLocalDeletion(spaceId: String) { deliver(.recordLocalDeletion(spaceId)) }
    func joinAccountSync(spaceId: String) { deliver(.joinAccountSync(spaceId)) }
    func runRetentionSweep() { deliver(.runRetentionSweep) }

    /// §9.4: "a Profile still referenced by a Space cannot be deleted", widened
    /// from `SpaceManager.spaces` to the account. Fail-OPEN before the first
    /// full drain: a long-offline / long-locked machine must not be stuck with
    /// a prompt that never clears (the caller shows the warning instead).
    func blocksProfileDeletion(localProfileId: String) -> Bool {
        guard hasDrainedFullReplay else { return false }
        if let uuid = globalUuidLookup?(localProfileId), referencedProfileUuids.contains(uuid) {
            return true
        }
        // 第三条判据（R-D6-9）：**有映射且其实体已发布**的本地 Space。它必须走两件
        // 新件——`publishedSyncUuids`（这半句只能在 `refreshCaches` 里算好推回来：
        // 这个方法手上没有 `table`，也没有任何按游标键的视图）与 `syncUuidLookup`
        // （`localSpaceIdLookup` 是 syncUuid -> 本地 id，方向反了）。
        // D6 之前这里问的是「hidden 的本地 Space」，而 D2 是那一类行的唯一生产者。
        let rows = localSpaceProfileIds?() ?? []
        return rows.contains { row in
            guard row.profileId == localProfileId,
                  let uuid = syncUuidLookup?(row.spaceId) else { return false }
            return publishedSyncUuids.contains(uuid)
        }
    }

    private func deliver(_ intent: Intent) {
        if let intentSink {
            intentSink(intent)
            return
        }
        guard let directStore else { return }
        var table = directStore.load()
        switch intent {
        case .recordLocalDeletion(let spaceId):
            // 与引擎边界同一件事（§3.4）：表按 syncUuid 键，来的是本地 id。没有
            // resolver 或翻不出来 = 从来没发布过 = 无 tombstone 可发。
            guard let uuid = syncUuidLookup?(spaceId) else { return }
            table.recordLocalDeletion(spaceId: uuid)
        case .joinAccountSync(let spaceId): table.joinAccountSync(spaceId: spaceId)
        case .runRetentionSweep:
            // Data cascade needs SpaceManager, which the no-engine path has no
            // business driving; the sweep runs for real at the next engine start.
            return
        }
        directStore.save(table)
        refreshCaches(from: table)
    }
}
