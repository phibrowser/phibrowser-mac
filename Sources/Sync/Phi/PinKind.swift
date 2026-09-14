// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Foundation

// 固定标签页这一种 kind 的适配：编解码、字段 LWW 表、归属解析、盖戳。
//
// 与书签相差的那几件事，逐条都是「身份是 `(lineage, owner)` 这一对」（R-M3-3-15）的直接
// 后果：
//
// - **pin 没有 location**（§4.3）。owner 是身份的一半、不可变，所以它不是一个可合并的
//   字段，也就没有「位置组」可言；`rank` 是一个**普通 LWW** 字段，不套书签那条相干规则。
// - **换 owner 不是字段变化**：旧 tag 下一条 tombstone + 新 tag 下一条 create（§7.2）。
//   `PinApplyOp` 里因此不存在 `rebind`。
// - **pin 完全不走 §6 的认领**（§6.7）。首次同步时两边的 pin **取并集**——没有内容匹配、
//   没有配对、没有去重，所以 `SyncableOwnedItems.adopt` 只收 `Phi_PhiBookmarkEntity`，
//   这里不补一个 pin 版本。
// - **同一个 owner 下仍可能有多条同 lineage 的活动行**（`mergeCandidates` 对签名不同的
//   变体会留下第二条），它们是用户看得见的两个固定标签页，由 `normalizeVariants(locals:)`
//   各自重铸身份。

enum PinKind: OwnedItemKind {
    typealias Entity = Phi_PhiPinTabEntity
    typealias Local = PhiLocalPin

    static var tagPrefix: String { PhiSyncEntity.pinTagPrefix }
    static var entityName: String { PhiSyncEntity.pinEntityName }

    // MARK: - lineage 的归一

    /// 本地 `pinLineageId`（来自 `UUID().uuidString`，**大写**）→ 线上 `pin_uuid`。
    ///
    /// **三处共用这一个 helper**（§3.2）：client tag 的构造（§2.5）、§5.1 的索引种子、
    /// 落地时的匹配。`PhiSyncEntity.pinClientTag(_:ownerKey:)` 自己**不做**任何大小写归一
    /// ——它是一个纯拼接函数，归一的责任全部在这里，调用方在**进** tag 之前就要归一好。
    /// 把归一塞进 tag 构造器，索引种子与落地匹配那两处就失去了同一个守卫；而三处只要有
    /// 一处漏掉，算出的 hash 与线上那条永不相等，§2.5 的接收端校验会把**每一条** pin 实体
    /// 都判成伪造载荷（§3.2 把这种失效叫「整个 pin 通道失灵」）。
    ///
    /// **两个方向都不写回本地行**：本机那一列仍然是大写的原值。
    static func lineageKey(_ lineageId: String) -> String { lineageId.lowercased() }

    // MARK: - 身份与信封

    /// 线上实体的身份：`<pin_uuid>:<ownerKey>`，与 client tag 去掉前缀之后逐字一致。
    ///
    /// **这里不再调 `lineageKey`**：账户上那条实体的 `pin_uuid` 按定义已经是归一形式，而
    /// 一条没归一的入站实体会被 `refuses` 判成 `.invalidUuid`。若这里顺手小写化，一条
    /// 大写载荷就会与那条合法实体**撞成同一个身份**，于是 `plan` 的收割会把它的
    /// `entityId` / `version` 写到合法那条的游标上——下一次提交带着一个属于别的服务端实体
    /// 的三元组。
    static func identity(of entity: Phi_PhiPinTabEntity) -> String {
        let lineage = entity.pinUuid
        // 空 lineage ⇒ 空身份，由 `plan` 的第一条判据（uuid 为空 ⇒ 拒收）接住。
        guard !lineage.isEmpty else { return "" }
        return lineage + ":" + ownerKey(of: entity)
    }

    /// 本机行的账户身份 `<lineageKey>:<ownerKey>`。
    ///
    /// 两条 nil：**休眠行**（`PhiLocalPin.isDormant` 的自述「休眠行不进快照，也不参与
    /// 差分」——作用域迁移留下的本地备份不是一条账户实体；`allPins()` 的契约已经把它们滤
    /// 掉了，这里再挡一次，于是「只剩休眠副本的 lineage」在差分眼里就是「本机没有这一
    /// 行」并照常产出 tombstone）与**空 lineage**。
    ///
    /// **归属解析不出来时仍然返回一个身份**，后半段换成一个 NUL 打头、任何账户 uuid 都
    /// 产不出的占位：`snapshot` 的排除计数（`excluded_unmapped_owner`）只在
    /// 「`identity` 非 nil ∧ `eligibilityOwner` 为 nil」这一支里 +1（`SyncableOwnedItems`
    /// 里那两个 `guard`），这里返回 nil 就会让 §4.2 第 1 条点名的那一整类排除在计数行上
    /// **完全不可见**——而那正是告诉运维「有一个 Space 映射缺了」的唯一信号。
    ///
    /// **占位值的不变量，两条，缺一条它就会漏到线上：**
    ///
    /// 1. 占位后半段**只**出现在「同一个 resolver 与 scope 下 `eligibilityOwner(of:…)`
    ///    返回 nil」的那些行上。它不是一个可以被别处复用的哨值。
    /// 2. **任何调用方都不得直接从 `identity(of local:)` 派生 client tag、游标键、线上
    ///    字节或日志字段**。这四样东西只能来自 `snapshot(...).entities.keys` 或
    ///    `table.cursors` ——两者都以 `eligibilityOwner != nil` 为前提（模块里那两个
    ///    `guard` 把不合格的行挡在 `candidates` 之外，`identityByLocalId` 也只收合格行）。
    ///    `cursor.ownerUuid` 的每轮刷新（A12 / §3.5）同理走 `eligibilityOwner`，不许去截
    ///    这个身份的后半段。
    static func identity(of local: PhiLocalPin, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        guard !local.isDormant else { return nil }
        let lineage = lineageKey(local.lineageId)
        guard !lineage.isEmpty else { return nil }
        let owner = eligibilityOwner(of: local, resolve: resolve, scope: scope)
        return lineage + ":" + (owner ?? unresolvedOwnerKey)
    }

    static func envelope(_ entity: Phi_PhiPinTabEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.pinTab = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiPinTabEntity? {
        guard case .pinTab(let payload)? = envelope.kind else { return nil }
        return payload
    }

    /// pin 是**平的**：没有父，所以 `parentId` 恒为 nil（`snapshot` 的祖先链判据对它退化
    /// 成「只看自己」，`plan` 的拓扑排序对它是一趟空转）。
    static func localEdge(of local: PhiLocalPin) -> (id: String, parentId: String?) {
        (id: local.guid, parentId: nil)
    }

    // MARK: - 归属（§7.2）

    /// 这条**本机行**坐在哪个归属里，按 §7.2 的表推导；nil = 那个 Space / profile 没有
    /// 映射，该行本轮整条跳过并计一次 `excluded_unmapped_owner`（§4.2 第 1 条）。
    ///
    /// **判据是先看 `spaceId` 再看 `profileId`**，不是「哪个非 nil 用哪个」：一条 Space
    /// 作用域的行两个字段都非 nil（`PhiLocalPin.spaceId` 上那张表），`pinnedTab(_:belongsTo:)`
    /// 保证它恰好属于一个 owner。
    ///
    /// **解析不出来时绝不退化成 `"app"`**：那会把一条 Space 作用域的 pin 发成账户全局的，
    /// 对端按 App 作用域落地之后它在**每一个** Space 里都出现。
    ///
    /// `scope` 不参与推导。账户作用域与本机作用域的比较是 §7.3 的事，不一致的那一轮**整个
    /// 发布段**都不跑；而 `allPins()` 交上来的行按契约全在当前作用域内，行的形状**就是**
    /// 那个作用域。拿 `scope` 去覆写行的形状，会在一次尚未迁移完的作用域变更里把一批
    /// Space 形状的行发成 App 作用域的实体。
    ///
    /// 这同时是 §4.2 的合格性判据与 Task 7 的 `ownerUuid` 预处理读的那一个值——**一个
    /// 实现点**（A12 / §3.5）。
    static func eligibilityOwner(of local: PhiLocalPin, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String? {
        switch owner(of: local, resolve: resolve) {
        case .space(let uuid), .profile(let uuid): return uuid
        case .app: return appOwnerKey
        case nil: return nil
        }
    }

    /// 这条实体落地**之前必须已经解析出来**的归属引用：它的 owner，一个。
    ///
    /// App 作用域返回字面量 `"app"`，与 Space / Profile 同走一条路。引擎侧构造的
    /// `OwnerResolver` 把 `"app"` 映射到**它自己**（Task 5b / Task 6 在各自的构造处写了
    /// 这一行的理由），于是 `plan` 的归属分类把它判成「模块之外解析得出」而正常落地，
    /// `tombstones` 也不必为这个字符串开一个「归属未映射」的例外——那条规则正是 §4.7 用来
    /// 防「一次映射抖动删掉整个 Space 的书签」的。
    static func ownerUuids(of entity: Phi_PhiPinTabEntity) -> [String] {
        [ownerKey(of: entity)]
    }

    // MARK: - 出站投影与盖戳（§4.2）

    /// 本机行 → 线上实体，**不盖戳也不填 rank**。
    ///
    /// `parentIdentity` 被忽略：pin 没有父。归属解析不出 ⇒ nil，该行本轮整条跳过。
    static func project(_ local: PhiLocalPin, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiPinTabEntity? {
        guard let owner = owner(of: local, resolve: resolve) else { return nil }

        var entity = Phi_PhiPinTabEntity()
        entity.pinUuid = lineageKey(local.lineageId)
        switch owner {
        case .space(let uuid): entity.spaceUuid = uuid
        case .profile(let uuid): entity.profileUuid = uuid
        // App 作用域 = 一条 oneof 都不设（§2.4：**缺席就是三个值之一**）。
        case .app: break
        }
        entity.rank = string("")
        entity.title = string(local.title)
        entity.url = string(local.url.absoluteString)
        entity.splitPartnerUuid = string(local.splitPartnerLineageId.map(lineageKey) ?? "")
        entity.source = Int32(truncatingIfNeeded: local.source)
        entity.createdAtMs = milliseconds(local.createdDate)
        return entity
    }

    static func rank(of entity: Phi_PhiPinTabEntity) -> String { entity.rank.stringValue }

    /// **`rank` 的戳，不是 0。**
    ///
    /// 一条 pin 没有 location，但这个值是 §5.6 L1 支（A9）那三个合取项里的第一项——「实体
    /// 的位置戳**严格晚于** `deleteDecidedAtMs`」。返回 0 会让那个比较**恒假**，于是 pin 侧
    /// 的 A9 取消删除永远不触发：一条对端刚从被删作用域里拖出来的 pin 照样被删掉。`rank`
    /// 是 pin 唯一的位置维度，它的戳就是这条实体「位置何时变过」的答案。
    static func locationStamp(of entity: Phi_PhiPinTabEntity) -> Int64 {
        entity.rank.updatedAtMs
    }

    /// 三个内容字段的**取值**字节（时间戳清零），与 `SyncableSettings.signature(of:)` 同义。
    ///
    /// `rank` 不在里面：它由 `.move` 承载（落地是 `PinApplyOp.move(guid:index:)`），混进来
    /// 会让每一次纯排序都额外产出一条空的字段补丁。`split_partner_uuid` **在**里面：它走
    /// `PinFieldPatch.splitPartnerLineageId`，不算进内容签名的话一次纯拆分链接变化产不出
    /// 任何一条 step，两台机器的拆分对从此不同。
    static func contentSignature(of entity: Phi_PhiPinTabEntity) -> Data {
        var out = Data()
        for value in [entity.title, entity.url, entity.splitPartnerUuid] {
            out.append(SyncableSettings.signature(of: value))
            out.append(0)
        }
        return out
    }

    /// §4.2 第 4 / 5 条的盖戳。pin 只有两组字段：`rank`（自己的戳）与内容字段。
    ///
    /// 无基线那一支按 §4.2 第 5 条：`rank` 盖 **0**（本机派生出来的位置不该赢过对端任何
    /// 一次真实操作——书签那边 `location` 与 `rank` 都盖 0，pin 没有 location，剩下的就是
    /// 这一个），**内容字段**（`title` / `url`）盖 **`contentUpdatedDate ?? createdDate`**，
    /// **其余每个字段盖 `now`**（A13）。内容字段绝不盖 `now`：一条几年前建的、从没人动过的
    /// pin 若以 `now` 首发，它会赢下对端上周做的改名。
    ///
    /// `split_partner_uuid` **属于「其余」那一类，盖 `now`**：§4.2 第 5 条点名的内容字段
    /// 只有 `title` / `url` / `secondary_*`，而拆分链接不是用户「编辑内容」的产物——它由
    /// 一次拆分操作产生，`contentUpdatedDate` 不为它而动，拿一个可能几年前的戳去发一条刚
    /// 建立的链接，会让对端一条更早但戳更新的空值赢下它。（它仍然在 `contentSignature`
    /// 里：那个函数判的是「要不要带一份字段补丁」，与盖哪个戳是两件事。）
    ///
    /// **`split_partner_uuid` 的半落地保护**（§7.4）：本机行的伙伴还没落地（本地链接是
    /// nil）而基线里有一个 lineage ⇒ **照抄基线那一份**，绝不发 `""`。发空串等于宣布
    /// 「这条 pin 不再有拆分伙伴」，会在对端把一个完好的拆分对拆开——而这台机器只是接收
    /// 了它。
    static func stamp(_ projected: Phi_PhiPinTabEntity, baseline: Phi_PhiPinTabEntity?,
                      local: PhiLocalPin, rank: String, now: Int64) -> Phi_PhiPinTabEntity {
        var out = projected
        out.rank = string(rank)
        let contentStamp = milliseconds(local.contentUpdatedDate ?? local.createdDate)

        if out.splitPartnerUuid.stringValue.isEmpty,
           let baseline, !baseline.splitPartnerUuid.stringValue.isEmpty {
            out.splitPartnerUuid = baseline.splitPartnerUuid
        }

        guard let baseline else {
            out.rank.updatedAtMs = 0
            out.title.updatedAtMs = contentStamp
            out.url.updatedAtMs = contentStamp
            out.splitPartnerUuid.updatedAtMs = now
            return out
        }
        out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        out.title.updatedAtMs = restamped(out.title, baseline.title, now)
        out.url.updatedAtMs = restamped(out.url, baseline.url, now)
        out.splitPartnerUuid.updatedAtMs = restamped(out.splitPartnerUuid,
                                                     baseline.splitPartnerUuid, now)
        return out
    }

    // MARK: - 合并（§2.4）

    /// 逐字段 LWW，**`rank` 是其中一个普通字段**——没有位置组，也就没有书签那条「相干」
    /// 规则可套（它要问的 `location` 在 pin 上根本不存在，套上去就是让一个恒相等的值去
    /// 决定 rank 的归属）。
    ///
    /// **owner 一个字都不碰**：它是身份的一半、不可变（§2.4 / R-M3-3-15），两条同身份的
    /// 实体必然同 owner——§2.5 的接收端 tag 校验顺带把这件事钉死，一条 `owner` 与 tag 不符
    /// 的实体是伪造载荷而不是一次合法的换绑。`merged` 从 `remote` 继承的那一个就是对的。
    ///
    /// **从 `remote` 起手**：`Phi_PhiPinTabEntity()` 不带 `unknownFields`，从它起手会把更新
    /// 版本客户端写在预留字段 10-13 上的内容在每一轮里都抹掉一次（`Proto/README.md`）。
    static func merge(local: Phi_PhiPinTabEntity,
                      remote: Phi_PhiPinTabEntity) -> Phi_PhiPinTabEntity {
        var merged = remote
        merged.pinUuid = local.pinUuid.isEmpty ? remote.pinUuid : local.pinUuid
        merged.rank = SyncableSettings.lwwWinner(local.rank, remote.rank)
        merged.title = SyncableSettings.lwwWinner(local.title, remote.title)
        merged.url = SyncableSettings.lwwWinner(local.url, remote.url)
        merged.splitPartnerUuid = SyncableSettings.lwwWinner(local.splitPartnerUuid,
                                                             remote.splitPartnerUuid)
        // NOT last-writer-wins：非零的一侧赢；两侧都非零且不同时取较小者（同书签）。
        merged.source = mergedSource(local.source, remote.source)
        // NOT last-writer-wins：最早的创建时刻才是真的那一个。
        let created = [local.createdAtMs, remote.createdAtMs].filter { $0 > 0 }
        merged.createdAtMs = created.min() ?? 0
        return merged
    }

    // MARK: - 拒收（§4.6）

    /// pin 的拒收表只有 §4.6 里标着「两者」的那两行：非法 `pin_uuid` 与非法 `rank`。
    ///
    /// `rank` 这一条是 `rankBetween` 的**解码边界**：那个函数在发布构建里用 `precondition`
    /// 直接 trap，而对端字节是不可信输入。
    ///
    /// `pin_uuid` 必须是**已归一**的形式：本地 lineage 来自 `UUID().uuidString`（大写），
    /// 归一是 `lineageKey` 的事（§3.2），所以一条带大写 lineage 的入站实体说明对端漏掉了
    /// 那一步——接受它会让同一条 pin 在账户上有两个身份。
    ///
    /// `baseline` 用不上：书签那条 `is_folder` 判据在 pin 上没有对应物（一条 pin 不会变形
    /// 成别的东西），而 owner 的分歧在 §2.5 的 tag 校验里就已经被挡住了。**签名仍然带着
    /// 它**——§4.6 那张表只该有一个实现形状。
    ///
    /// **`url` 解析不出 `URL` ⇒ 拒收**，与 `BookmarkKind.refuses` 同一条判据同一个理由：
    /// 落地类型 `PhiLocalPin.url` 是**非可选**的 `URL`，所以落地段既 create 不了也 update
    /// 不了这样一条行。§4.6 那张表把 URL 那一行标成「书签」，是因为它的措辞带着
    /// `is_folder`；它背后的结构性事实对 pin 逐字成立（勘误见 ledger）。不拒收只剩两条坏路：
    /// 静默丢弃（没有任何计数）或永久停放（等一个永远不会变得可解析的东西）。拒收给出的
    /// 是 §4.6 本来的形状——计进 `refused`、不写游标、**每轮重判**，于是对端修好字节的下
    /// 一个版本就被接受。
    ///
    /// 「owner 的 oneof 与账户当前作用域不符」不在这里：§4.6 明确说那**不是** refuse 也
    /// 不是丢弃，而是整条**停放**等作用域收敛（§7.3），由 `plan` 的 `scopeMismatch` 实现。
    static func refuses(_ entity: Phi_PhiPinTabEntity,
                        baseline: Phi_PhiPinTabEntity?) -> OwnedItemRefusal? {
        guard isNormalizedLineage(entity.pinUuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        if URL(string: entity.url.stringValue) == nil { return .invalidURL }
        return nil
    }

    // MARK: - 变体重铸（§7.2 / A11）

    /// 同一个 `(lineage, ownerKey)` 下的多条**活动**行：保留 `index` 最小的那一条（平手取
    /// `guid` 字典序最小），其余每一条重铸 `pinLineageId`。
    ///
    /// 它们**不是**同一条实体的多个副本——它们是用户看得见的两个固定标签页（`mergeCandidates`
    /// 对 `PinnedTabVariantSignature` 不同的副本刻意保留第二条）。按「一条实体、多个物理
    /// 副本」写会留下一整类**永远同步不了**的行：第二个副本没有自己的身份，既到不了别的
    /// 机器，也无法被别的机器删除，而每一个计数器都读健康值。
    ///
    /// **产出的是一个 `PinApplyBatch`**，与那一轮的落地同一个事务；它**不是** push 段
    /// pre-pass 的一次旁路写——那个 pre-pass 按 §4.2 第 2 条是只读的，而重铸不可逆（旧
    /// lineage 已经不在任何行上），在「重铸已提交、实体未发布」的中间态崩掉就再也回不去。
    ///
    /// 分组用的是**本机**的 owner id（`spaceId ?? profileId ?? "app"`），不需要 resolver：
    /// 本机 id → 账户 uuid 的映射在每一类归属内是一一的，所以两行属于同一个账户 owner
    /// 当且仅当它们属于同一个本机 owner。**前置条件**：`locals` 来自一次 `allPins()`，
    /// 即全部属于**同一个作用域类**——混进另一个作用域的行会让这个等价关系不成立。
    /// 休眠行不参与分组（它们是作用域迁移留下的本地备份，重铸它们会把那份备份与它的活动
    /// 行永久拆开）。
    ///
    /// **新 lineage 是确定性的**，见 `mintedLineage(_:ordinal:)`。
    static func normalizeVariants(locals: [PhiLocalPin]) -> PinApplyBatch {
        var groups: [String: [PhiLocalPin]] = [:]
        for local in locals where !local.isDormant {
            let key = lineageKey(local.lineageId) + "\u{0}" + localOwnerKey(local)
            groups[key, default: []].append(local)
        }
        var ops: [PinApplyOp] = []
        // 组的遍历次序固定，于是同一批行产出的 ops 次序也固定。
        for key in groups.keys.sorted() {
            let members = (groups[key] ?? []).sorted {
                $0.index == $1.index ? $0.guid < $1.guid : $0.index < $1.index
            }
            // ordinal 从 1 数：0 是保留原 lineage 的那一条（index 最小），它不产出 op。
            for (ordinal, row) in members.enumerated() where ordinal > 0 {
                ops.append(.relineage(guid: row.guid,
                                      newLineageId: mintedLineage(lineageKey(row.lineageId),
                                                                  ordinal: ordinal)))
            }
        }
        return PinApplyBatch(unordered: ops)
    }

    // MARK: - 私有

    /// App 作用域在 client tag 第三段里的字面量（§2.4 / §2.5）。
    private static let appOwnerKey = "app"

    /// 归属解析不出来时 `identity(of local:)` 用的占位后半段。NUL 打头，账户 uuid 产不出
    /// 这种字节，所以它与任何真实身份都不相等——见 `identity(of local:)` 的注释。
    private static let unresolvedOwnerKey = "\u{0}unresolved-owner"

    private enum PinOwner {
        case space(String)
        case profile(String)
        case app
    }

    private static func owner(of local: PhiLocalPin, resolve: OwnerResolver) -> PinOwner? {
        if let spaceId = local.spaceId {
            guard let uuid = resolve.syncUuid(spaceId) else { return nil }
            return .space(uuid)
        }
        if let profileId = local.profileId {
            guard let uuid = resolve.globalUuid(profileId) else { return nil }
            return .profile(uuid)
        }
        return .app
    }

    /// 线上实体的 ownerKey：`space_uuid` / `profile_uuid` / 字面量 `"app"`（oneof 缺席）。
    private static func ownerKey(of entity: Phi_PhiPinTabEntity) -> String {
        switch entity.owner {
        case .spaceUuid(let uuid): return uuid
        case .profileUuid(let uuid): return uuid
        case nil: return appOwnerKey
        }
    }

    /// 本机那一侧的 owner id：`normalizeVariants` 的分组键，也是
    /// `PhiPinnedTabLocalAccess.isKnownLocalPin(_:ownerKey:)` 那半个身份。
    ///
    /// **判据与 `owner(of:resolve:)` 逐字同序**（先 `spaceId` 再 `profileId`，都没有才是
    /// App 作用域），只是停在本机这一侧、不过映射表。两处分叉的后果是「本机有没有这条
    /// 身份的行」在账户侧与本机侧问出两个答案。
    ///
    /// 与 `identity(of:resolve:scope:)` 的后半段是**两个命名空间**：那一个是账户级 uuid，
    /// 这一个是本机 id。互相直接比较恒为假，中间必须过 `OwnerResolver` 的反查。
    static func localOwnerKey(_ local: PhiLocalPin) -> String {
        local.spaceId ?? local.profileId ?? appOwnerKey
    }

    /// 变体重铸出来的新 lineage：`(原 lineage, ordinal)` 的 SHA-1 取前 16 字节，按
    /// 8-4-4-4-12 排成一个小写 uuid 形状的串。
    ///
    /// **必须跨设备确定。** A11 针对的正是「两台机器跑同一次确定性迁移、面对同一对变体」
    /// ——`migratePinnedTabs` 对 lineage 与 index 都是确定的（§3.2），所以两边看到的是同一
    /// 个分组、同一个次序。用 `UUID()` 各铸一个的话，两边各自发布一条对方没有的实体、又
    /// 各自落地对方那一条，而 §6.7 排除了 pin 的认领——没有任何东西会去重，用户**每个变体
    /// 多出一个固定标签页**，两台机器都是。
    ///
    /// **ownerKey 不进哈希，这是有意的。** 本函数按签名只拿得到本机那一侧的 owner id，而
    /// 本机 `spaceId` 是**按设备**铸的（`LocalStore+Space.swift:69` 用 `UUID().uuidString`），
    /// 把它喂进哈希恰好会毁掉这里要的那个确定性；账户级 ownerKey 则要 resolver，而
    /// `normalizeVariants(locals:)` 的签名里没有。省掉它不引入歧义：身份是
    /// `(lineage, owner)` 这一对，所以同一个新 lineage 落在两个 owner 下就是两条实体——正是
    /// Profile → Space 扇出本来就该有的形状（一条 lineage 在 N 个 Space 里是 N 条实体）；
    /// 而同一个 owner 内 ordinal 互不相同，组内不会撞。
    ///
    /// 前缀是域分隔符：让这个派生不可能与别处任何一个「对某个 uuid 取哈希」的方案撞上。
    /// 值**不是** RFC-4122 的 v4（没有版本位），只是 uuid 形状——本地那一列从来没有校验过
    /// 形状，而线上要的只是「已归一」。
    private static func mintedLineage(_ lineage: String, ordinal: Int) -> String {
        let seed = "phi-pin-variant|" + lineage + "|" + String(ordinal)
        let digest = Array(Insecure.SHA1.hash(data: Data(seed.utf8))).prefix(16)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        var out = ""
        for (offset, character) in hex.enumerated() {
            if offset == 8 || offset == 12 || offset == 16 || offset == 20 { out.append("-") }
            out.append(character)
        }
        return out
    }

    /// 一条**已归一**的 lineage 该有的形状。判的是「对端有没有走过 `lineageKey`」，不是
    /// RFC-4122 合法性——严格校验会连带拒掉每一条形状合法但生成方式不同的对端实体，而
    /// `pinLineageId` 在本仓库里有五处回退成那一行的 `guid`（`LocalStore+PinnedTabScope.swift`
    /// / `LocalStore+PinnedTabTransfer.swift`），那些 guid 未必是 uuid 形状。判据与
    /// `BookmarkKind.isAccountUuid` 同源。
    ///
    /// **`:` 必须拒**：身份是 `lineage + ":" + ownerKey`，一条带冒号的 lineage 让这个拼接
    /// 不再可逆——`("a:b", "c")` 与 `("a", "b:c")` 算出同一个身份，于是一条伪造载荷可以顶
    /// 着另一条实体的身份去收割 `entityId` / `version`，而 client tag 也多出一段。
    /// NUL 一并拒：`identity(of local:)` 的未映射占位用它，组键也用它。
    private static func isNormalizedLineage(_ lineage: String) -> Bool {
        !lineage.isEmpty
            && !lineage.contains(where: { $0.isUppercase })
            && !lineage.contains(where: { $0.isWhitespace || $0.isNewline })
            && !lineage.contains(":")
            && !lineage.unicodeScalars.contains("\u{0}")
    }

    /// 与基线同名字段的 signature 相同 ⇒ 沿用基线的时间戳；不同 ⇒ 盖 `now`。
    private static func restamped(_ value: Phi_PhiSettingValue,
                                  _ baseline: Phi_PhiSettingValue,
                                  _ now: Int64) -> Int64 {
        SyncableSettings.signature(of: value) == SyncableSettings.signature(of: baseline)
            ? baseline.updatedAtMs : now
    }

    private static func mergedSource(_ left: Int32, _ right: Int32) -> Int32 {
        if left == 0 { return right }
        if right == 0 { return left }
        return min(left, right)
    }

    private static func string(_ value: String) -> Phi_PhiSettingValue {
        var out = Phi_PhiSettingValue()
        out.stringValue = value
        return out
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
