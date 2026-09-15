// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// 归属项（书签 / pin）的同步影子：**每种 kind 一张表、一个文件**（§3.5）。
//
// 落点：
//
//     <account.userDataStorage>/sync/bookmarks-cursors.json
//     <account.userDataStorage>/sync/pins-cursors.json
//
// `account.userDataStorage` 就是 `<App Support>/Phi/users/<userID>`（`Account.swift`），
// 也就是 `localDB` 与 `defaults/` 的同级目录，所以这两个文件**随账户目录天然隔离**：
// 切账户与账户重置零清理（§9.2），也不需要进 `PhiSyncEngine.stateKeys`。
//
// **为什么不进账户 plist**（与 Space 表不同的那一半）：`AccountUserDefaults` 的每一次
// `set` 都把整个 `account_defaults.plist` 重新序列化并原子落盘，而每条游标最多带三份
// 序列化实体副本（`reconciled` / `server` / `pendingApply`）。上千条书签游标放进去之后，
// 每一次哪怕只改一条游标的小改动都要重写整份账户偏好。
//
// **写入纪律**（逐字同 M3-2 §5.3 的单写者规则）：这两张表的每一个写入方都必须是一个排进
// 引擎 `roundQueue` 的 Round——Swift actor 可重入，「在引擎 actor 上跑」不是排他。落盘
// 一律 `Data.write(to:options:.atomic)`，落下去的永远是一份完整的表。

/// 一种 kind 的整张游标表。每个 kind 一个文件，`formatVersion` 独立演进。
struct PhiOwnedItemTable: Codable, Equatable {
    /// 1 = M3-3 首版。读到更小的、或者根本读不出来 ⇒ **丢整表**（与 M3-2b §3.6 的硬切
    /// 同款，不写迁移代码）。丢表不是静默的：`PhiOwnedItemStateStore.load(hadRecords:)`
    /// 把它报给引擎，引擎按 §3.5 为这个 kind 走一次整类型重放。
    static let currentFormatVersion = 1
    var formatVersion: Int = currentFormatVersion
    /// key = 该 kind 的实体身份（书签 `bookmark_uuid` / pin `<lineage>:<ownerKey>`）。
    ///
    /// 这张表里**没有任何「首次合并窗口」状态**（R-M3-3-22 / R-M3-3-28）：没有
    /// `firstArrival`、没有 `claimEligible`、没有 `lastArrivalMs`，也没有任何「这条身份是不是
    /// 本机铸的」的本地标志或去重残留字段。§6 的认领只有一条**无状态、连续、从不删除任何
    /// 东西**的规则，多一个字段就是给「看起来重复就删一条」留门。
    var cursors: [String: PhiOwnedItemCursor] = [:]

    /// §3.6：删除定案满 30 天的 tombstone 游标整条丢弃，由 `.retentionSweep` round 调用。
    /// 窗口复用 `PhiSpaceSyncState.retentionMs`（与 M1 §2 的恢复窗口同一个 30 天），不另起
    /// 一个常量——两个 30 天一旦分开写就会分开漂。
    ///
    /// **丢弃为什么安全**（这条论证必须留在代码里，因为它与 Space 侧「游标永久保留」的做法
    /// 相反）：服务端的 GetUpdates 只按 `version > marker` 下发，且每个 `entity_id` 只有一行，
    /// **只下发最新版本**。所以一条身份被再次投递时，投到的只可能是它此刻的最新版本：要么
    /// 仍是那条 tombstone，要么是一次**更新的**复活版本（R-M3-3-23），绝不可能是删除**之前**
    /// 的某个旧版本。两种都安全——仍是 tombstone ⇒ 没有游标时走 §5.6 的 T1 支（认不出 hash、
    /// 不建游标），结论与有游标时逐字一样；是复活 ⇒ 没有游标时它作为一条 create 正常落地，
    /// 这正是对复活想要的结果。
    ///
    /// 早先这里的论证是「投到的仍然是 tombstone」，那句话在 R-M3-3-23 之后不再成立；结论
    /// 不变，但证明换成上面这一版，否则下一个读者会从旧证明里重新推出「一律拒绝复活」。
    /// Space 侧永久保留游标，是因为它同时是软删记录、要给 30 天窗口内的 UI 与 purge 用；
    /// 归属项没有软删态，所以没有这个第二用途。
    mutating func dropExpiredTombstones(nowMs: Int64) {
        cursors = cursors.filter { _, cursor in
            guard let deletedAtMs = cursor.deletedAtMs else { return true }
            return nowMs - deletedAtMs <= PhiSpaceSyncState.retentionMs
        }
    }
}

/// 一条归属项身份的同步影子。十四个字段，逐条都有文档注释——这些注释是这些字段**存在
/// 理由**的唯一记录，删掉一条注释等于让下一个人有理由删掉那个字段。
///
/// 逐字段比 `PhiSpaceCursor` 少三项，各有理由：没有 `hidden`（归属项的远端删除是**真删
/// 本地行**，30 天恢复窗口由服务端保留提供，本地没有「隐藏」这个可见状态）、没有
/// `purgedAtMs`（同上，没有两段式清理）、没有 `refusedAtMs`（§4.6 的拒收判据全是结构性的，
/// 对端修好就该被接受，所以每轮重判一次；Space 侧那个「记住我拒过」的优化已经变成一条
/// **无法自愈**的永久排除）。`heldProfileUuid` / `heldForLocalProfileId` 也没有，但那不是
/// 省略：Space 的 fallback A 是「行已落地但绑定解析不了，回显远端值」，而归属项的归属是
/// **位置的一部分**，位置解析不了的行根本不该落地，只有停放一种状态。
struct PhiOwnedItemCursor: Codable, Equatable {
    /// 服务端实体 id。**空串 = 这条身份还没在账户上出现过**，也就是下一次发布是一条
    /// create。它同时是 per-kind「这台机器为该 kind 发布过东西」标志的判据（§3.5）。
    var entityId: String = ""
    /// 服务端上这条实体的版本，提交时作 `baseVersion`。
    var version: Int64 = 0
    /// 序列化实体：变更检测基线（M3-1 `<key>.phiSyncVal` 的同构物）。
    var reconciled: Data?
    /// 序列化实体：**服务端持有**的那一份，用来压掉一次多余的发布。**绝不是 merge 结果。**
    var server: Data?
    /// 这条身份**当前所在的本地归属**：书签是所在 Space 的 syncUuid，pin 是当前的 ownerKey。
    ///
    /// **定义是「解析出来的本地归属」，绝不是线上实体的 `space_uuid` 字段**（A12）：
    /// R-M3-3-18 把子孙的 `space_uuid` 降格成诊断字段且**永不重发**，所以账户上那些子孙实体
    /// 会永远带着搬家之前的 `space_uuid` 字节。落地时由**父链**推出，快照时由**本地行**读出。
    ///
    /// **刷新范围，逐字**（R-exec-8）：每一轮的 snapshot 预处理为**每一条身份在本机有对应行的
    /// 游标**刷新一次——包括本轮因为 250 条切片而排不上队的那些，因为快照读的是
    /// `allBookmarks()` / `allPins()` 那一次**整库**的读，不是切片（N3 / I9）。
    /// 身份在本机**没有**对应行的游标**保留它上一次已知的归属**：那条游标接下来唯一要走的路
    /// 是 §4.7 的差分 tombstone，而差分判「这条身份该不该发 tombstone」用的正是这个值。把它刷成
    /// nil 会让 `tombstones` 的保守 `guard` 永久跳过它，账户上那条实体从此没有任何设备能删掉。
    ///
    /// 它让保留期级联（§9.3）、隐藏 Space 的排除（§4.2）与 `parked` 诊断都只读一个字段，而不是
    /// 把每条游标的基线解一遍。
    ///
    /// 即便如此它仍可能落后（门关着、drain 未完、pin 作用域不一致时 push 段整段不跑），所以
    /// §9.3 的级联**不以它为唯一判据**：没有任何活的本地行认领这条身份时才删游标。
    var ownerUuid: String?
    /// 归属（书签的 Space / 父夹，pin 的 owner）尚未落地而**停放**的入站实体。
    var pendingApply: Data?
    /// 停放所针对的那个未解析 uuid，只为 §11 的 `parked` 诊断与 §4.4 的解停放判据。
    var pendingOwnerUuid: String?
    /// 已按 hash 认出、但本轮没能落地的**远端 tombstone**（导入锁占用）。tombstone 没有密文，
    /// 存不进 `pendingApply`，而共享 marker 已经推过那一页、同一条永不重投——与
    /// `PhiSpaceCursor.pendingTombstone` 同款同理。
    var pendingTombstone: Bool = false
    /// 落地了一半的拆分对：本机这一条已落地，伙伴 lineage 还没有本地行（§7.4）。非 nil 时
    /// 快照**照抄基线的 `split_partner_uuid`**，绝不发 `""`——发空串会把对端那一半也拆掉。
    var pendingPartnerLineage: String?
    /// 差分判定这条身份该删，tombstone 还没被服务端接受。
    var pendingDelete: Bool = false
    /// 上面那个删除决定作出的时刻（§4.7 写入），**0 = 没有待发删除**。§5.6 的 L1 支用它判断
    /// 一条入站实体是不是「删除决定之后发生的、把该项移出被删子树」的那一类（A9）。
    var deleteDecidedAtMs: Int64 = 0
    /// 连续 `INVALID_MESSAGE` 拒绝次数（M3-2 §5.1 的 3 次放弃规则）。
    var deleteRejectRounds: Int = 0
    /// R-exec-13 的补键自愈**连续被拒**的次数，判据与上面那条同款、计的是另一件事：
    /// 「有基线、没有 `entityId`」的游标每一轮被无条件排进发布切片，而那条 create 每一轮
    /// 都被服务端判 `INVALID_MESSAGE`。三轮之后**不再重新武装**（`PhiSyncEngine` 的
    /// `rekeyRejectGiveUpRounds`），于是一条补不回键的游标不会变成一条永久的每轮提交。
    ///
    /// **放弃不写 `deletedAtMs`，也不动 `reconciled`**（与 tombstone 那一条的放弃相反）：
    /// 那条身份在本机**还有活行**——补键自愈的判据里就有这一条。放弃的含义只是「这台机器
    /// 不再主动去认那一行」，本机那一行照常存在、照常显示；它下一次被对端更新收割
    /// （`applyOwnedKind` 的 harvest）或者被用户改一次内容（那时快照字节与基线不等，走的是
    /// 正常的发布通路）就重新有了 id，`.applied` 把它清回 nil。
    ///
    /// **`Int?` 而不是 `Int = 0`，nil 与 0 同义，这不是风格选择。** 合成的 `init(from:)` 对一条
    /// **非可选**属性调的是 `decode(_:forKey:)`——缺键就抛 `keyNotFound`，属性上写没写默认值
    /// 都一样（实测：Swift 6.2 仍是这个行为）。而落盘的 JSON 是 `JSONEncoder` 写的，它只省略
    /// 值为 nil 的可选字段，所以线上那些 822 时代的文件里**每一个非可选字段都在、新加的那个
    /// 不在**。给这个结构体加一条非可选字段 ⇒ 每一台已有设备的 `pins-cursors.json` /
    /// `bookmarks-cursors.json` 整份解不开 ⇒ `FileOwnedItemStateStore.load` 交出空表并报损
    /// ⇒ 整类型重放 + 每一份 `reconciled` 基线当场丢失，正是本文件开头点名的那场静默灾难。
    /// 加可选字段没有这个问题，也就不必为一条计数器去动 `formatVersion` 把全网的表硬切一次。
    /// **下一个往这里加字段的人：要么加可选的，要么就得连 `formatVersion` 一起想清楚。**
    var rekeyRejectRounds: Int?
    /// 这条实体的删除**已经定案**的时刻，**两个方向共用**：远端 tombstone 落地时写，本机
    /// tombstone 被服务端接受（`.applied`）时也写（§5.6）。只写远端那一半，会让本机删掉的
    /// 每一条书签在这张表里留一条永久游标，而一次大规模整理正是这张表最不该永久增长的时刻。
    /// 写它不影响防复活——`entityId` / `version` 一并保留。到期后整条游标被丢弃（§3.6）。
    var deletedAtMs: Int64?
}

/// 把 `PhiSpaceSyncTable` 上属于某一条 kind 的两个标志包成一对可读写的访问器。
///
/// 用 `WritableKeyPath` 而不是「按 label 拼字符串去查」：后者拼错一个字母就会静默地读到
/// 另一条 kind 的标志，而这两个标志控制的是「要不要整类型重放」。
struct OwnedKindFlags {
    let hadRecords: WritableKeyPath<PhiSpaceSyncTable, Bool>
    let replayedForEmptyTable: WritableKeyPath<PhiSpaceSyncTable, Bool>

    static let bookmarks = OwnedKindFlags(hadRecords: \.bookmarksHadRecords,
                                          replayedForEmptyTable: \.bookmarksReplayedForEmptyTable)
    static let pins = OwnedKindFlags(hadRecords: \.pinsHadRecords,
                                     replayedForEmptyTable: \.pinsReplayedForEmptyTable)
}

/// 一张 per-kind 游标表的存储。
///
/// `: AnyObject` —— 对照物 `PhiSpaceSyncStateStore` 也是。引擎以 `(any PhiOwnedItemStateStore)?`
/// 持有它并跨轮复用；非 class-bound 会让「测试改了假件的内部状态、引擎看得到」这个前提失效。
protocol PhiOwnedItemStateStore: AnyObject {
    /// 读整张表，并**在类型上**把「这次读不出来」报回去。
    ///
    /// `hadRecords` 是该 kind 的 `…HadRecords` 标志，它住在 `PhiSpaceSyncTable` 里、store 看不到
    /// （§3.5 的单副本裁定）。做成入参 + 返回值，比让 store 去读另一张表干净，也让报损在类型上
    /// 无法被忽略——丢一个游标文件而不报损是一场**静默的灾难**：`syncId` 住在 SwiftData 行上、
    /// marker 住在 `UserDefaults.standard`，两者都不在被丢掉的那个文件里，于是行仍然同步合格却
    /// 一条基线都没有，下一轮的组批器以 `entityId == "" / version == 0` 发出一批 create，而服务端
    /// 的 `ON CONFLICT (client_tag_hash) DO UPDATE` **没有版本检查**——整个账户的书签被这台机器
    /// 盲写覆盖，时间戳还赢下每个对端的 LWW。
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool)
    func save(_ table: PhiOwnedItemTable)
    /// §9.1 的自撤销：直接删文件，不是保存一张空表。
    func deleteFile()
}

/// 账户目录下的一个 JSON 文件（文件头注释里的落点）。
final class FileOwnedItemStateStore: PhiOwnedItemStateStore {
    /// 公开是因为测试要读它，断言「读不出来的那一路一个字节都不许写回去」。
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// **四种情形返回同一样东西**：文件不存在、字节解不开、`formatVersion` 低于
    /// `currentFormatVersion`、以及表里一条游标都没有——都是一张**空表**，`reportedLoss` 取
    /// 传入的 `hadRecords`，并且**任何一种都不写回文件**。
    ///
    /// 不写回是这条契约里最容易被「顺手修好」掉的一半：读不出来就写一个空表回去，会把一次
    /// 真正的丢失变成一张「正常的空表」，下一次 `load` 再也报不出损。
    ///
    /// 四种情形合在一个 `guard` 里，是因为它们的**结论**逐字相同；分成四个分支写出来，迟早
    /// 有一个分支被单独改成「写回去」。
    func load(hadRecords: Bool) -> (table: PhiOwnedItemTable, reportedLoss: Bool) {
        guard let bytes = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PhiOwnedItemTable.self, from: bytes),
              decoded.formatVersion >= PhiOwnedItemTable.currentFormatVersion,
              !decoded.cursors.isEmpty else {
            return (PhiOwnedItemTable(), hadRecords)
        }
        return (decoded, false)
    }

    /// 原子落盘一份**完整**的表（§3.5，与 `AccountUserDefaults.persistLocked` 同款）。
    ///
    /// 写失败**不重试**（§11.4）：下一轮的 `load` 读到的是上一份完整的表，或者读不出来而报损，
    /// 两条路都是收敛的；一个半截的重试队列不是。日志按 R12 只带条数与错误元数据。
    func save(_ table: PhiOwnedItemTable) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(table).write(to: fileURL, options: .atomic)
        } catch {
            AppLogError("[phi-sync] owned-item cursor save failed cursors=\(table.cursors.count) "
                + "(\(PhiSyncLog.describe(error)))")
        }
    }

    func deleteFile() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            AppLogWarn("[phi-sync] owned-item cursor delete failed (\(PhiSyncLog.describe(error)))")
        }
    }
}
