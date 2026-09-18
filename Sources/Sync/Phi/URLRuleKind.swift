// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// URL Rule 这一种 kind 的适配：编解码、三个合并单元的 LWW、归属解析、盖戳（spec §5.1）。
//
// 规则是归属项模块的第三种归属语义（§5.2 / D13）：**owner 可变，但身份不含 owner**。
// 三个合并单元各带自己的戳（D15 按 R-M3-4a-40 修订）：
//
//     单元      成员                            戳
//     内容组    host + path_prefix + ask        共用一个，载体是 host（发送时三者写成相等，接收时只读 host）
//     目标      target_space_uuid               自己的戳 = 这一 kind 的 `location`
//     rank      rank                            自己的戳
//
// 目标离开内容组买到两样东西（§8.2 第 2 条）：`locationStamp(of:)` 有了一个可读的载体
// （协议成员是单参数的，A9 的第一个合取项因此可实现），以及 A 改 host、B 同时改目标时
// 两边都存活。
//
// 这里止步于 kind 适配：D30 的机件（签名 / 静止谓词 / `.transfer` / 延迟删除）住在
// 8b-1 ~ 8b-3，本地访问协议与落地批次住在 Task 8，plan 闭包与注册项住在 Task 6。

enum URLRuleKind: OwnedItemKind {
    typealias Entity = Phi_PhiURLRuleEntity
    typealias Local = PhiLocalURLRule

    static var tagPrefix: String { PhiSyncEntity.urlRuleTagPrefix }
    static var entityName: String { PhiSyncEntity.urlRuleEntityName }

    // MARK: - 身份与信封

    static func identity(of entity: Phi_PhiURLRuleEntity) -> String { entity.ruleUuid }

    /// `local.syncId`。**实际恒非 nil**（插入点铸造，R-M3-4a-23），所以模块第一遍的
    /// `continue`（`SyncableOwnedItems.swift:365-368`）对规则不可达，也因此不需要
    /// `snapshot.minted` / `claimIdentities` 那条链路。
    static func identity(of local: PhiLocalURLRule, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        local.syncId
    }

    static func envelope(_ entity: Phi_PhiURLRuleEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.urlRule = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiURLRuleEntity? {
        guard case .urlRule(let payload)? = envelope.kind else { return nil }
        return payload
    }

    /// 规则之间没有依赖边，拓扑排序对它平凡成立。
    static func localEdge(of local: PhiLocalURLRule) -> (id: String, parentId: String?) {
        (id: local.id, parentId: nil)
    }

    // MARK: - 归属（§5.3）

    /// §5.3 的三条判据，按次序求值、第一个命中的决定结果（R-M3-4a-7 / R-M3-4a-8）：
    /// 1. 裸 Incognito 目标（`SpaceManager.incognitoRuleTargetId`）⇒ 保留常量，**合格**；
    /// 2. 其它 incognito 前缀下的 id（过期的运行期 Space）与 agent Space ⇒ nil，不合格；
    /// 3. 否则走映射表，解析不出就是 nil。
    ///
    /// 「不在 `currentSpaces()` 里」与「游标 hidden / purged」**不在这里判**，交还给模块：
    /// 引擎交进来的 `resolve.isEligibleSpace` 已经是那三条的合取，模块对「有 owner 但不合格」
    /// 的行记 `skippedIneligibleOwner`（`SyncableOwnedItems.swift:371-380`）。在这里提前判成
    /// nil 会让那个计数器对规则恒为 0，两条排除路径各自可断言的设计意图就此失效。
    static func eligibilityOwner(of local: PhiLocalURLRule, resolve: OwnerResolver,
                                 scope: PinnedTabScope?) -> String? {
        if local.spaceId == SpaceManager.incognitoRuleTargetId {
            return SyncableSpaces.incognitoSpaceUuid
        }
        if !SpaceManager.isRoutableRuleTarget(local.spaceId) { return nil }
        return resolve.syncUuid(local.spaceId)
    }

    /// **恒为 `[target_space_uuid]`**，保留常量也不例外（R-M3-4a-7 二次修订）。
    ///
    /// 这个返回值**同时是 rank 组键**（`SyncableOwnedItems.swift:443` 把组键算成
    /// `ownerUuids(of:).joined(separator: "\u{0}")`），所以 incognito 规则落进组
    /// `"incognito-space"`，与任何别的目标同形。空串照样返回 `[""]`：`classify`
    /// （`:687-695`）据此判 `.unresolved` 并停放；返回 `[]` 会让它带着空目标落地，而 D16
    /// 要求这种实体永不被改写。
    static func ownerUuids(of entity: Phi_PhiURLRuleEntity) -> [String] {
        [entity.targetSpaceUuid.stringValue]
    }

    /// R-M3-4a-26 的取值源：**直接读字段**，不是 `ownerUuids(of:).first`。两者今天取值恒等，
    /// 但语义不同——`ownerUuids` 的合同是「落地前必须解析出来的归属引用」，将来任何一条
    /// kind 想把某个归属排除在停放判据之外时又会返回空；`.move` 要的是「这条实体现在指向
    /// 哪里」。
    static func targetOwnerUuid(of entity: Phi_PhiURLRuleEntity) -> String? {
        entity.targetSpaceUuid.stringValue
    }

    // MARK: - 出站投影与盖戳（§8.2）

    /// 本机行 → 线上实体，**不盖戳也不填 rank**。规则没有父，`parentIdentity` 被忽略；
    /// 目标解析不出 ⇒ nil，该行本轮整条跳过（§5.3）。
    static func project(_ local: PhiLocalURLRule, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiURLRuleEntity? {
        guard let target = eligibilityOwner(of: local, resolve: resolve, scope: scope) else {
            return nil
        }
        var entity = Phi_PhiURLRuleEntity()
        entity.ruleUuid = local.syncId ?? ""
        entity.host = string(local.host)
        // 本机 nil ⇔ 线上 `""`（「匹配任意路径」的显式清空编码，§8.1）。
        entity.pathPrefix = string(local.pathPrefix ?? "")
        entity.ask = bool(local.askBeforeRouting)
        entity.targetSpaceUuid = string(target)
        entity.rank = string("")
        entity.createdAtMs = milliseconds(local.createdDate)
        // 本机没有 `source` 列（§3.3）：每一个发布者都发 0，基线上非零的值由 `stamp` 折回来。
        entity.source = 0
        return entity
    }

    static func rank(of entity: Phi_PhiURLRuleEntity) -> String { entity.rank.stringValue }

    /// **内容组三个字段**（`host` / `path_prefix` / `ask`）清零戳后的字节。目标不在里面
    /// （R-M3-4a-40 把它拆成独立通道，由 `.move` 承载），`rank` / `created_at_ms` / `source`
    /// 也不在（后两者非 LWW，由 `stamp` 折叠）。
    static func contentSignature(of entity: Phi_PhiURLRuleEntity) -> Data {
        var out = Data()
        for value in [entity.host, entity.pathPrefix, entity.ask] {
            out.append(SyncableSettings.signature(of: value))
            out.append(0)
        }
        return out
    }

    /// R-M3-4a-25：**只读 `target_space_uuid` 自己的戳**（`target_updated_at_ms`），不是任何
    /// 派生值，与 `BookmarkKind.locationStamp` 的分工逐字相同（`stamp` 写它、这里只读它）。
    /// 它是 A9 的第一个合取项（`SyncableOwnedItems.swift:802`）：接成内容组戳会让任何一次
    /// 远端内容编辑只要比本机的删除决定新就取消删除（CASE U-23）。
    static func locationStamp(of entity: Phi_PhiURLRuleEntity) -> Int64 {
        entity.targetSpaceUuid.updatedAtMs
    }

    /// §8.2 的盖戳（D33：**引擎的每一次写都不铸戳**，`now` 只落到 rank 上）。三个单元三条规则：
    ///
    /// - **内容组**：三个成员按 signature 整组比，变了整组带**行戳** `contentUpdatedDate ??
    ///   createdDate`（本机用户真的改它的那一刻，R-M3-4a-11 的写点），否则沿用基线的载体戳
    ///   （`host`）；三个成员**一律写成相等**（§8.2 第 1 条）。**不是快照时刻的 `now`**：一次
    ///   本机编辑可能在几轮之后才被发布，盖 `now` 会让一次更早的本机编辑赢下对端更晚的那次
    ///   真实编辑（控制者裁定：spec §8.2 / D33 压过 `BookmarkKind` 的先例，只对这一 kind）。
    /// - **目标**：变了 ⇒ 目标戳带行戳 `targetUpdatedDate ?? createdDate`、rank 戳盖 `now`
    ///   （§8.2 第 4 条：桶变了，在新桶里的位置也是新的，而 rank 是本机派生的、没有行戳）；
    ///   否则目标戳沿用基线，rank 戳按自己的 signature 比。只靠「rank 串变了才盖」不够：一次
    ///   搬桶之后 rank 串偶然相同时，合并的第三行会拿到一枚旧戳。
    /// - **无基线**（R-M3-4a-12，三项）：内容组戳取 `contentUpdatedDate ?? createdDate`、目标戳
    ///   取 `targetUpdatedDate ?? createdDate`、rank 戳取 0。取 `now` 会让一条三个月前建的、
    ///   没人动过的本机规则凭「我今天跑了一轮同步」赢下对端上周那次真实的改目标；目标戳取
    ///   0 则让 `locationStamp(of: merged)` 恒为 0，A9 的第一个合取项对一条从没发布过的规则
    ///   恒假。这条分支在首次发布与游标报损后的整类型重放里都是**主路径**。
    ///
    /// **有基线那一支还要先把 `created_at_ms` 与 `source` 折叠掉**（R-exec-16 / R-M3-4a-19）
    /// ——理由抄自 `BookmarkKind.swift:162-176`：两个字段本机落不了地，出站投影若继续宣称本机
    /// 那一列的值，发布判据（投影与 `reconciled` 的裸字节比较）每轮都判「变了」，两台机器
    /// 各一条 commit，永远。
    static func stamp(_ projected: Phi_PhiURLRuleEntity, baseline: Phi_PhiURLRuleEntity?,
                      local: PhiLocalURLRule, rank: String, now: Int64) -> Phi_PhiURLRuleEntity {
        var out = projected
        out.rank = string(rank)

        guard let baseline else {
            setContentStamp(&out, milliseconds(local.contentUpdatedDate ?? local.createdDate))
            out.targetSpaceUuid.updatedAtMs = milliseconds(local.targetUpdatedDate ?? local.createdDate)
            out.rank.updatedAtMs = 0
            return out
        }

        out.createdAtMs = mergedCreatedAtMs(out.createdAtMs, baseline.createdAtMs)
        // `source` 是写一次定终身的来源标记：基线上已经有一个就照抄，绝不拿本机的 0 去覆盖。
        if baseline.source != 0 { out.source = baseline.source }

        let contentChanged = contentSignature(of: out) != contentSignature(of: baseline)
        setContentStamp(&out, contentChanged
                            ? milliseconds(local.contentUpdatedDate ?? local.createdDate)
                            : baseline.host.updatedAtMs)

        let targetChanged = SyncableSettings.signature(of: out.targetSpaceUuid)
            != SyncableSettings.signature(of: baseline.targetSpaceUuid)
        if targetChanged {
            out.targetSpaceUuid.updatedAtMs = milliseconds(local.targetUpdatedDate ?? local.createdDate)
            out.rank.updatedAtMs = now
        } else {
            out.targetSpaceUuid.updatedAtMs = baseline.targetSpaceUuid.updatedAtMs
            out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        }
        return out
    }

    // MARK: - 合并（§8.2）

    /// §8.2 的三段式，**对称地写**（不带「本机 / 对面」的视角）：
    ///
    ///     content = LWW(content_X, content_Y)        // 整组一个单元，载体 host
    ///     target  = LWW(target_X,  target_Y)
    ///     rank    = (target_X == target_Y) ? LWW(rank_X, rank_Y)
    ///                                     : rank(赢下 target 的那一条实体)
    ///
    /// 第一行整组取胜：`host` 与 `path_prefix` 是同一把匹配键的两半，逐字段 LWW 会合出一条
    /// 谁都没写过的规则并让它真的生效——那是一次路由行为变化。判定**只读 `host` 的戳**，不取
    /// 三者的 `max`：取 `max` 的实现与取固定成员的实现会对同一份字节算出不同的戳，各自认为
    /// 自己赢、每轮互相重发、永不收敛。
    ///
    /// 第三行是**相干**：一个 rank 只在它所属的那个目标桶里有意义（`sortOrder` 是桶内下标）。
    /// 写成「当赢家是对面那一侧时才取对面的 rank」只修一半。
    ///
    /// **从 `remote` 起手**：`Phi_PhiURLRuleEntity()` 不带 `unknownFields`，从它起手会把更新
    /// 版本客户端写在预留字段上的内容在每一轮里都抹掉一次。
    static func merge(local: Phi_PhiURLRuleEntity,
                      remote: Phi_PhiURLRuleEntity) -> Phi_PhiURLRuleEntity {
        var merged = remote
        merged.ruleUuid = local.ruleUuid.isEmpty ? remote.ruleUuid : local.ruleUuid

        let localBallot = contentBallot(local)
        let remoteBallot = contentBallot(remote)
        let contentWinner = SyncableSettings.lwwWinner(localBallot, remoteBallot) == localBallot
            ? local : remote
        merged.host = contentWinner.host
        merged.pathPrefix = contentWinner.pathPrefix
        merged.ask = contentWinner.ask
        // §8.2 第 1 条：发送时三个成员写成相等，值取赢家的载体戳。
        setContentStamp(&merged, contentWinner.host.updatedAtMs)

        let targetWinner = SyncableSettings.lwwWinner(local.targetSpaceUuid, remote.targetSpaceUuid)
        merged.targetSpaceUuid = targetWinner
        if local.targetSpaceUuid.stringValue == remote.targetSpaceUuid.stringValue {
            merged.rank = SyncableSettings.lwwWinner(local.rank, remote.rank)
        } else {
            merged.rank = targetWinner == local.targetSpaceUuid ? local.rank : remote.rank
        }

        // NOT last-writer-wins：非零的一侧赢；两侧都非零且不同时取较小者。
        merged.source = mergedSource(local.source, remote.source)
        // NOT last-writer-wins：最早的创建时刻才是真的那一个。
        merged.createdAtMs = mergedCreatedAtMs(local.createdAtMs, remote.createdAtMs)
        return merged
    }

    // MARK: - 拒收（§5.4）

    /// §5.4 的结构性判据，按表序求值；`nil` = 接受。`baseline` 收下但不读——规则没有
    /// `is_folder` 那种形变不变量。
    ///
    /// `rank` 这一条是 `rankBetween` 的解码边界：那个函数在发布构建里用 `precondition` 直接
    /// trap，而对端字节是不可信输入（CASE U-9）。
    ///
    /// `host` 含 `:` 那一半必须放过**方括号 IPv6 字面量**：`GURL::host()` 对 IPv6 返回带方括号
    /// 的 `"[::1]"`，编辑器的 `stripPort` 也刻意保留它；一刀切会让一条用户合法创作、在本机真的
    /// 能匹配的规则被每一台对端每一轮拒收（本判据没有 `refusedAtMs`、每轮重判）。
    ///
    /// **不在这里判的两条**（§5.4 表末两行）：`path_prefix` 不是不动点 ⇒ 在 plan 闭包里就地
    /// 归一（`normalizeArrivals`）；`target_space_uuid` 解析不出 ⇒ 整条**停放**（`ownerUuids`）。
    static func refuses(_ entity: Phi_PhiURLRuleEntity,
                        baseline: Phi_PhiURLRuleEntity?) -> OwnedItemRefusal? {
        guard isAccountUuid(entity.ruleUuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        let host = entity.host.stringValue
        if host.isEmpty { return .emptyHost }
        if host == "*" || host == "*." { return .degenerateHost }
        if host.contains("/") { return .malformedHost }
        if host.contains(":"), !(host.hasPrefix("[") && host.hasSuffix("]")) {
            return .malformedHost
        }
        return nil
    }

    // MARK: - 落地投影（§8.3）

    /// 线上是 rank，本机是每桶稠密 `sortOrder`：**按桶跑一次**，比较器逐字是
    /// `(rank ?? "", syncId ?? id)` 升序，形状照 `BookmarkKind.rankToIndex`。返回 `id -> sortOrder`。
    ///
    /// 喂进来的同桶列表**不按同步合格性过滤**（停放中的、待删的、刚建出来还没上过账户的行
    /// 都在——没有 rank 的行排最前，与 `assignRanks` 的补集规则同向；平手按 `syncId ?? id`
    /// 而不是只按 `rule_uuid`，否则那些还没有 uuid 的行的次序是设备相关的）。**软删行由本函数
    /// 排除**（R-M3-4a-51，唯一实现点）：它们不再路由、不再显示，留在定义域里只会让删除方与
    /// 跟随端的 `sortOrder` 错位，而 `sortOrder` 是路由特异度的第三项、排在裁决键之前。
    /// 一次 `.rehome` 的调用方要对**源桶与目标桶**各跑一次（R-M3-4a-3）。
    static func rankToSortOrder(siblings: [PhiLocalURLRule],
                                ranks: [String: String]) -> [String: Int] {
        let ordered = siblings.filter { $0.deletedDate == nil }.sorted { left, right in
            let leftRank = left.syncId.flatMap { ranks[$0] } ?? ""
            let rightRank = right.syncId.flatMap { ranks[$0] } ?? ""
            if leftRank != rightRank { return leftRank < rightRank }
            return (left.syncId ?? left.id) < (right.syncId ?? right.id)
        }
        var out: [String: Int] = [:]
        for (index, row) in ordered.enumerated() { out[row.id] = index }
        return out
    }

    // MARK: - 入站归一（§8.1 / R-M3-4a-29）

    /// plan 闭包的第 0 步，做成纯函数：解码后的 arrivals 逐条跑归一化，字节变了就**替换该
    /// arrival**、**三枚戳一个都不碰**，并把身份记进返回的集合（调用方显式并进
    /// `OwnedPlanOutput.mustRepublish` 并计 `normalized`）。归一化函数由调用方注入，本模块
    /// 不去够 `LocalStore`（与 `SyncableOwnedItems.swift` 的 PURE 自述同款）。
    /// 线上 `path_prefix` 的 `""` 与本机的 nil 在这里互转。
    ///
    /// **归一绝不能挪到 `refuses` 之前**：`refuses` 的签名改写不了实体，而 `plan.mustRepublish`
    /// 是模块按 `payload != payloadBytes(item.entity)` 算的，模块外静默归一 ⇒ 判据恒假 ⇒ 永远
    /// 进不了 `mustRepublish`。**沿用远端戳而不是重盖 `now`**（R-M3-4a-2 修订 / D33）：终止性
    /// 来自不动点本身——对端自己那一行的投影也是归一值，本机把归一后的字节重发上去之后对端
    /// 零差分；重盖 `now` 则是引擎的一次写铸出一枚戳，那枚伪造的新鲜度会去赢对端一次真实的
    /// 用户编辑。
    static func normalizeArrivals(
        _ arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>],
        normalize: (String, String?) -> (host: String, pathPrefix: String?)
    ) -> (arrivals: [OwnedItemArrival<Phi_PhiURLRuleEntity>], normalized: Set<String>) {
        var out = arrivals
        var normalized: Set<String> = []
        for (offset, item) in arrivals.enumerated() {
            let wireHost = item.entity.host.stringValue
            let wirePath = item.entity.pathPrefix.stringValue
            let result = normalize(wireHost, wirePath.isEmpty ? nil : wirePath)
            let path = result.pathPrefix ?? ""
            guard result.host != wireHost || path != wirePath else { continue }
            // 只换取值：`stringValue` 的 setter 只碰 oneof，`updatedAtMs` 原样带着。
            var entity = item.entity
            entity.host.stringValue = result.host
            entity.pathPrefix.stringValue = path
            out[offset].entity = entity
            let identity = identity(of: entity)
            if !identity.isEmpty { normalized.insert(identity) }
        }
        return (out, normalized)
    }

    // MARK: - 私有

    /// 把内容组整组压成一张可以直接喂进 `SyncableSettings.lwwWinner` 的选票：戳是载体
    /// `host` 的，字节覆盖三个成员的取值（平手仍然按序列化字节字典序，且对称）。
    private static func contentBallot(_ entity: Phi_PhiURLRuleEntity) -> Phi_PhiSettingValue {
        var ballot = string(entity.host.stringValue + "\u{0}" + entity.pathPrefix.stringValue
                            + "\u{0}" + (entity.ask.boolValue ? "1" : "0"))
        ballot.updatedAtMs = entity.host.updatedAtMs
        return ballot
    }

    /// §8.2 第 1 条：内容组三个成员的戳一律写成相等。
    private static func setContentStamp(_ entity: inout Phi_PhiURLRuleEntity, _ stamp: Int64) {
        entity.host.updatedAtMs = stamp
        entity.pathPrefix.updatedAtMs = stamp
        entity.ask.updatedAtMs = stamp
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

    /// `created_at_ms` 的合并：非零的一侧赢，两侧都非零取**较早**的那一个。`merge` 与 `stamp`
    /// 共用这一个实现（R-exec-16）。
    private static func mergedCreatedAtMs(_ left: Int64, _ right: Int64) -> Int64 {
        [left, right].filter { $0 > 0 }.min() ?? 0
    }

    /// 一个**账户级**身份该有的形状。与 `BookmarkKind.isAccountUuid` 同源（第三份）：刻意
    /// **不**做 RFC-4122 校验，挡的是「一台设备把自己的本机 id 发上线」，不是规定对端只能用
    /// 某一种 uuid 生成器。不提升可见性，因为提升会把一条刻意不做校验的判据变成公共 API。
    private static func isAccountUuid(_ uuid: String) -> Bool {
        !uuid.isEmpty
            && !uuid.contains(where: { $0.isUppercase })
            && !uuid.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    private static func string(_ value: String) -> Phi_PhiSettingValue {
        var out = Phi_PhiSettingValue()
        out.stringValue = value
        return out
    }

    private static func bool(_ value: Bool) -> Phi_PhiSettingValue {
        var out = Phi_PhiSettingValue()
        out.boolValue = value
        return out
    }

    /// 毫秒换算钉成四舍五入（`BookmarkKind.swift:353`），**不是**截断：截断会让毫秒在两侧各
    /// 差 1 ms 而重现 R-M3-4a-19 那个重发环。
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - D30：合并签名与静止谓词（§8.4.1）

/// 规则的**合并签名**（§8.4.1 / R-M3-4a-52）。三个成员全部取**归一化之后**的值（§8.1 的
/// 同一个不动点函数）。`ask` 与 rank **不在里面**（D30 原文）；**目标在里面**，所以「同一个
/// host 路由到两个不同 Space」是**冲突不是重复**，由 §9 的裁决键分胜负、两条规则都留着。
struct RuleSignature: Hashable {
    let host: String
    /// nil 与 `"/"` 是**两个值**。
    let pathPrefix: String?
    /// **账户级**的量：普通 Space 经 resolver 反查出的 syncUuid，或保留常量
    /// `SyncableSpaces.defaultSpaceUuid` / `SyncableSpaces.incognitoSpaceUuid`。
    /// **绝不是本机 `spaceId`**（RR3-6：签名要与入站实体的 `target_space_uuid` 比，
    /// 按本机 id 建索引是另一个键空间、永不命中，认领会整条静默失效）。
    let owner: String
}

/// 8b-2 补的定序（**不改 8b-1 的类型定义本身**）：`convergePass` / `mergePointerPass` 都按
/// `groups.keys.sorted()` 遍历分组（收敛先例 `PinKind.swift:361`），而字典的 `keys` 次序是
/// 每进程随机的——不定序的实现会让两台机器（甚至同一台的两次运行）按不同次序产出 op。
/// 比较键**注入**：`pathPrefix` 的 nil 与 `""` 是两个值（§8.1），所以先比「有没有」再比值，
/// 两个不同的签名绝不会比成相等。
extension RuleSignature: Comparable {
    static func < (lhs: RuleSignature, rhs: RuleSignature) -> Bool {
        (lhs.host, lhs.pathPrefix == nil ? 0 : 1, lhs.pathPrefix ?? "", lhs.owner)
            < (rhs.host, rhs.pathPrefix == nil ? 0 : 1, rhs.pathPrefix ?? "", rhs.owner)
    }
}

extension URLRuleKind {
    /// §8.4.1 第一条：**两道门必须一起判**（RR7-2）。
    /// ① `eligibilityOwner(of:resolve:scope:) != nil`；
    /// ② `resolve.localSpaceId(owner) == nil || resolve.isEligibleSpace(owner)`
    ///    （与 `snapshot` 的第二道准入 `SyncableOwnedItems.swift:376-380` 逐字相同）。
    /// 任一不过 ⇒ **nil = 这一行惰性（inert）**：不进分组、不参与 M1 / M2 / M3、也不进
    /// `snapshot`。**任何退化取值都是错的**（nil / `""` / 本机 `spaceId` 三种写法都会把目标
    /// 不同的两条规则并进一组 ⇒ 软删其中一条 ⇒ 它若从未发布连 tombstone 都发不出）。
    /// `normalize` 由调用方注入（`LocalStore.normalizedRule`，与 `normalizeArrivals` 同一条
    /// 纪律：本模块不去够 `LocalStore`）。**自己跑一次 `normalize`**：V11 回填的老行按定义没过
    /// 归一化（CASE M-8 的本机行就是 `"GitHub.com."`），幂等保证它对已归一的值是恒等。
    static func signature(of row: PhiLocalURLRule, resolve: OwnerResolver,
                          normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        guard let owner = eligibilityOwner(of: row, resolve: resolve, scope: nil) else { return nil }
        return signature(host: row.host, pathPrefix: row.pathPrefix, owner: owner,
                         resolve: resolve, normalize: normalize)
    }

    /// 实体那一侧的同一条规则：owner 直接读 `target_space_uuid`（它本来就是账户级的量），
    /// 线上 `""` ⇔ 本机 nil（§8.1）。目标为空 / 第二道门不过 ⇒ nil。
    static func signature(of entity: Phi_PhiURLRuleEntity, resolve: OwnerResolver,
                          normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        let wirePath = entity.pathPrefix.stringValue
        return signature(host: entity.host.stringValue,
                         pathPrefix: wirePath.isEmpty ? nil : wirePath,
                         owner: entity.targetSpaceUuid.stringValue,
                         resolve: resolve, normalize: normalize)
    }

    /// §8.4.1 第二条。从 X 游标的 **`reconciled`** 那份投影解出实体、按同一条规则算签名，
    /// 也就是**这次本机编辑之前**那一个（M3 的兜底查找读它）。
    /// 没有游标 / 没有 `reconciled` / 解不出实体 / 目标为空 / 第二道门不过 ⇒ **nil**
    /// （fail-closed，**绝不**退化成任何别的取值）。与 `signature(of entity:)` 是同一个函数，
    /// 两处各写一份的实现迟早分叉（CASE M-30 (e)）。
    static func baselineSignature(identity: String, table: PhiOwnedItemTable,
                                  resolve: OwnerResolver,
                                  normalize: (String, String?)
                                      -> (host: String, pathPrefix: String?)) -> RuleSignature? {
        guard let bytes = table.cursors[identity]?.reconciled,
              let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
              let entity = entity(from: envelope) else { return nil }
        return signature(of: entity, resolve: resolve, normalize: normalize)
    }

    /// §8.4.1 第三条：**静止（at rest）= 十个合取项**，按 spec 的表序求值。三处读**同一个
    /// 谓词**（M2 的入组判据、胜者候选集、§8.4.4 里 W 的合格性），所以它只有这一个实现。
    ///
    /// 实现口径：**只有 `syncId != nil` 的行才谈得上静止**（`syncId` 是判据 1 的寻址键，
    /// 也是胜者比较的键；V11 回填漏掉的行在这里直接出局，**绝不强解包**）。
    ///
    /// 1/2/3/4/5/9 读游标，6/7 读行，8 由 resolver 算，**10 由本页 `arrivals` 算**。
    /// 求值时刻是 kind 的 pre-pass，用**本页那一次** `allURLRulesIncludingDeleted()` 与当时
    /// 的游标表，**每页一次**；同一页之内后续的写不改变已经算好的那份判定（R-M3-4a-62）。
    static func isAtRest(row: PhiLocalURLRule, cursor: PhiOwnedItemCursor?,
                         resolve: OwnerResolver,
                         normalize: (String, String?) -> (host: String, pathPrefix: String?),
                         tombstonesThisPage: Set<String>) -> Bool {
        guard let syncId = row.syncId else { return false }
        // 1. 已发布（R-M3-4a-23）：没上过账户的行没有「账户手上那一份」可比。
        guard let cursor, cursor.server != nil else { return false }
        // 2. 账户手上那一份 == 本机落地的那一份：还没发出去的分歧不算静止。
        guard cursor.server == cursor.reconciled else { return false }
        // 3. 没有停放中的入站实体：停放项落地之后这一行会变。
        guard cursor.pendingApply == nil else { return false }
        // 4. 没有待发的本机删除：它下一轮就会消失。
        guard !cursor.pendingDelete else { return false }
        // 5. 没有停着的远端 tombstone（RR8-3）：选它当胜者 ⇒ 它吸收败者之后自己也被删，
        //    整组归零。
        guard !cursor.pendingTombstone else { return false }
        // 6. 没有未发布的用户编辑（R-M3-4a-65）：那次编辑还没在账户上有代表。
        guard !row.pendingLocalEdit else { return false }
        // 7. 活行：软删行不参与收敛，也不是合并伙伴。
        guard row.deletedDate == nil else { return false }
        // 8. 有签名（两道门都过）：惰性行不进任何一组。
        guard signature(of: row, resolve: resolve, normalize: normalize) != nil else { return false }
        // 9. 不在 R-exec-13 的补键态（判据的镜像在 `PhiSyncEngine` 的 `unkeyed`）：那条游标
        //    正等着经 client tag 重新认一次身份，淘汰它会绕过整套放弃计数。
        guard !(cursor.entityId.isEmpty && cursor.reconciled != nil) else { return false }
        // 10. 本页没有它的入站 tombstone（R-M3-4a-86）：前九项固定在 pre-pass、看不见本页
        //     到达的删除；`.transfer` 与 `.delete` 同页同事务时，先把编辑转移到一条本页就要
        //     被删掉的 W 上，那次编辑丢失。第 5 项与第 10 项是同族的两半。
        guard !tombstonesThisPage.contains(syncId) else { return false }
        return true
    }

    /// 两个 `signature(of:)` 重载共用的收尾：目标为空 ⇒ nil；第二道门（映射得到但不合格）
    /// ⇒ nil；保留常量在 `localSpaceId` 里不映射（R-M3-4a-7），所以那一半对它恒过。
    private static func signature(host: String, pathPrefix: String?, owner: String,
                                  resolve: OwnerResolver,
                                  normalize: (String, String?) -> (host: String, pathPrefix: String?))
        -> RuleSignature? {
        guard !owner.isEmpty else { return nil }
        if resolve.localSpaceId(owner) != nil, !resolve.isEligibleSpace(owner) { return nil }
        let normalized = normalize(host, pathPrefix)
        return RuleSignature(host: normalized.host, pathPrefix: normalized.pathPrefix, owner: owner)
    }
}

// MARK: - D30 M2：两遍指针 + 整组归约（§8.4.3，8b-2）

/// 一条身份此刻的有效账户戳，**按合并单元分两枚**（内容组与目标，R-M3-4a-97 / 98）。
/// M2 只读 `.content`；8b-3 的 `.transfer` 两枚都读。两枚各自可以缺席。
struct URLRuleEffectiveStamps: Equatable, Sendable {
    var content: Date?
    var target: Date?
}

/// §8.4.3 第 2 步 (a)：胜者按**内容组**整组吸收来源的那一次写。三个字段连同它们共用的
/// 那一枚戳（R-M3-4a-48）。**每组至多一条**（R-M3-4a-82）。
struct RuleContentGroupWrite: Equatable {
    var syncId: String
    var host: String
    var pathPrefix: String?
    var ask: Bool
    var contentUpdatedDate: Date
}

/// §8.4.3 第 2 步 (b)：一条败者的软删。`deletedDate` 与 `mergePartnerSyncId` 是**同一次行写**
/// （RR8-4），所以它们是同一个值类型的两半而不是两条 op。
struct RuleSoftDelete: Equatable {
    var syncId: String
    var mergePartnerSyncId: String
}

/// `convergePass` 的产出。
struct URLRuleConvergence: Equatable {
    /// 每组**至多一次**（R-M3-4a-82：整组归约，绝不逐个败者去比一份固定的 W 快照）。
    var contentGroupWrites: [RuleContentGroupWrite] = []
    var softDeletes: [RuleSoftDelete] = []
    /// 生命周期表第 3 行的清空规则①：静止、且签名组里没有第二条活行 ⇒ 清空那一列。
    var clearedPartners: [String] = []
    /// **只统计真的被软删的败者**（R-M3-4a-54）。
    var collapsed = 0
    /// (c)：败者离开的每个桶，进本页的稠密重排定义域。
    var touchedBuckets: Set<String> = []
}

/// 尾钩交回的全部东西。
struct URLRuleMergeResult {
    var ops: [URLRuleSyncOp] = []
    var collapsed = 0
    var touchedBuckets: Set<String> = []
    /// 软删或内容组写 ⇒ 真；**纯指针写 ⇒ 假**（`mergePartnerSyncId` 不进路由表，为它刷一次
    /// 路由表是白刷，CASE M-7 钉住零刷新）。
    var changedRouting = false
}

extension URLRuleKind {
    /// §8.4.1 的归一化函数（三处注入点之外的**唯一**一处内部引用）。M2 的三个纯函数按
    /// spec §11 的字面签名写，没有 `normalize:` 入参，而签名分组必须用同一个不动点函数
    /// ——这个别名把它绑到与 `signatureIndex` / `mergePartners` **同一份**实现上，两处分叉
    /// 不了（§8.4.1 的「三处读同一个谓词」在归一化这一侧的对应物）。
    private static var mergeNormalize: (String, String?) -> (host: String, pathPrefix: String?) {
        URLRuleSignatureQueries.normalize
    }

    /// 毫秒戳 -> `Date`，与 `milliseconds(_:)` 互为逆。**0 当「缺席」**：R-M3-4a-12 的无基线
    /// 分支把目标戳写 0、rank 戳写 0，把它读成 1970 那一刻会让一条从没有过目标编辑的实体在
    /// LWW 里当成「有一枚极旧的真戳」。
    private static func stampDate(_ ms: Int64) -> Date? {
        ms == 0 ? nil : Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// 本页**从账户落地**的那些身份（R-M3-4a-74(1)）。**按 step 种类过滤**：
    /// `outcome.landed` 是它的超集（还含 `.delete` 的身份、以及 8b-3 的 (β) 转移为清
    /// `pendingApply` 交回去的那一条），**绝不**拿 `outcome.landed` 当这个集合用（RR12-6）。
    ///
    /// `.claim` 也在里面：那一行这一页第一次拿到账户身份与账户级 rank，它与 `.create` 同样是
    /// 「账户上这条实体在本机有了代表」，`mergePointerPass` 的锚点子集要认得它。
    static func landedIdentities(in steps: [OwnedItemApplyStep]) -> Set<String> {
        var out: Set<String> = []
        for step in steps {
            switch step.kind {
            case .claim, .create, .move, .update:
                out.insert(step.identity)
            case .delete:
                continue
            }
        }
        return out
    }

    /// 本页 `.transfer` 相（四相下的第三相，R-M3-4a-93）的**目标**身份（R-M3-4a-90），
    /// 要从本页 M2 第 2 步的候选集里减掉（计划裁定六 (1)）。与 `landedIdentities` 同一份
    /// step 列表、同一个 `land` 闭包里算，**不开新通道**。
    ///
    /// **今天结构性地为空**：`.transfer` 那一相由 8b-3 加进 `StepKind`（本任务不改那个枚举），
    /// 所以此刻没有任何 step 落进它。减法本身已经接上（`land` 闭包在调 `mergePass` 之前就减），
    /// 8b-3 补上那个 case 时这个 `switch` 会当场编译不过 —— 那正是它该被想起来的时刻。
    ///
    /// **精确集**是「`transferURLRuleEditBody` 真的写进了 ≥ 1 个单元」的那些目标；本函数是它的
    /// **纯函数超集**（全部 `.transfer` 目标）。两者都安全：超集最坏让那一组**本页**不收敛，
    /// 下一页再收。
    static func transferTargets(in steps: [OwnedItemApplyStep]) -> Set<String> {
        Set(steps.compactMap { step -> String? in
            switch step.kind {
            case .claim, .create, .move, .update, .delete:
                return nil
            }
        })
    }

    /// 合并单元戳的**唯一**取值源：**本页落地之后的「有效账户戳」**（R-M3-4a-94）。
    /// 按身份**分三层**取，**优先级从上到下**（第二层是 R-M3-4a-97 加的）：
    ///
    /// 1. `landed[id]` 有值（本页 `.create` / `.move` / `.update` 的目标）⇒ 取**那份落地值**的
    ///    两枚戳。它与马上要写进游标 `reconciled` 的那份字节是同一枚戳，所以它就是账户此刻
    ///    的值；此时游标里还是**落地前**那一份（记账排在 `land(...)` 之后）。
    /// 2. `rebaselined[id]` 有值（本页「取值没变、只是戳更新」的那些身份，
    ///    `OwnedItemPlan.rebaselined`）⇒ 解那份**新基线字节**取两枚戳。引擎要等 `land` 返回
    ///    之后才把它写进游标，所以 `table` 里那一条仍然是**更旧**的那一枚；漏掉这一层 ⇒
    ///    CASE M-33 变体 (d) 红。
    /// 3. 其余身份 ⇒ 取 `table.cursors[id]?.reconciled` 解出的那条实体的两枚戳。
    ///
    /// - 三层都取不到、或该单元那一枚为 nil ⇒ **这个单元不进表**（`convergePass` 按
    ///   `.distantPast` 处理，永不当 `source`，fail-closed）。
    /// - **毫秒 0 一律读成「缺席」，三层同一条口径**（8b-2 fix round 1 / F3）：第二 / 三层走
    ///   `stampDate`，第一层的两枚戳是非可选的 `Date`，所以要显式压掉 `Date(1970)`——
    ///   R-M3-4a-12 的无基线分支给目标戳与 rank 戳写的正是 0，不压就会给 8b-3 的 `.transfer`
    ///   递一枚「看起来很旧但很真」的目标戳。**缺的那一枚按单元落到下一层**。
    ///
    /// **绝不读行上的 `contentUpdatedDate`**：Task 5 的计划裁定 5 让新行那一列是 `nil`（发布侧
    /// 用 `?? createdDate` 投影、`.applied` 不回填），而 `rebaselined` 只刷游标基线、**一个字节
    /// 都不写行**。于是一条账户戳 30 的静止行，盘上那一列完全可能是 `nil` 或 10 —— 读行就会
    /// 输给一条 B@20，而退到 `?? createdDate` 又变成每设备量、两台选出不同的 `source`。
    /// 「静止」只蕴含「有基线且 `server == reconciled`」，**不蕴含「行戳 == 基线戳」**。
    static func effectiveAccountStamps(landed: [String: URLRuleLandingValues],
                                       rebaselined: [String: Data],
                                       table: PhiOwnedItemTable,
                                       identities: Set<String>)
        -> [String: URLRuleEffectiveStamps] {
        var out: [String: URLRuleEffectiveStamps] = [:]
        for identity in identities {
            var stamps = URLRuleEffectiveStamps()
            // 第一层。**`URLRuleLandingValues` 的两枚戳是非可选的 `Date`**，而 R-M3-4a-12 的
            // 无基线分支给目标戳与 rank 戳写的是 **0** ⇒ 那一枚到这里是 `Date(1970)`，一枚
            // 「看起来很旧但很真」的戳，而它的真实含义是**缺席**（8b-2 fix round 1 / F3）。
            // 与第二 / 三层的 `stampDate` 同一条口径压零，于是缺席的单元不进表
            // （`convergePass` 按 `.distantPast` 处理、永不当 `source`；8b-3 的 `.transfer`
            // 按 `max` 的另一半处理）。
            if let values = landed[identity] {
                stamps.content = suppressingEpoch(values.contentUpdatedDate)
                stamps.target = suppressingEpoch(values.targetUpdatedDate)
            }
            // 第二层优先于第三层：`rebaselined` 里那一份就是这一页之后游标会有的字节。
            // **按单元补**：第一层压零之后还缺的那一枚落到这里（一条本页 `.create` 的身份
            // 根本没有游标，补不到就仍然缺席）。
            if stamps.content == nil || stamps.target == nil,
               let bytes = rebaselined[identity] ?? table.cursors[identity]?.reconciled,
               let envelope = try? Phi_PhiEntity(serializedBytes: bytes),
               let entity = entity(from: envelope) {
                if stamps.content == nil { stamps.content = stampDate(entity.host.updatedAtMs) }
                if stamps.target == nil {
                    stamps.target = stampDate(entity.targetSpaceUuid.updatedAtMs)
                }
            }
            guard stamps.content != nil || stamps.target != nil else { continue }
            out[identity] = stamps
        }
        return out
    }

    /// 毫秒 0 换算过来的那一刻 = **缺席**，不是 1970 年那一枚真戳。
    private static func suppressingEpoch(_ date: Date) -> Date? {
        date.timeIntervalSince1970 == 0 ? nil : date
    }

    /// §8.4.3 第 1 步的**两遍**指针，一次做完，**每一页都跑、不受 `hasDrainedFullReplay`
    /// 的闸约束**（R-M3-4a-74(3) / RR11-1）。交回「身份 -> 锚点」，**只含真的要落行写的那些**。
    ///
    /// - `liveRows`：本页的**全部**活行（`deletedDate == nil`），**含没有签名的**——它们不进
    ///   任何分组，但「指向一条本机没有活行的身份」这个悬空判据要在**全部**活行上问。
    /// - 第一遍分组键 = 每一行**此刻**的 `signature(of:resolve:normalize:)`；第二遍分组键 =
    ///   `preLandingSignatures[id] ?? 此刻的签名`，**两遍的定义域都是全部活行**（RR12-1：
    ///   收成「表里那些身份」会在唯一要救的形状上**静默**空转）；两者都算不出的行不进分组。
    /// - 锚点 = 这一组「已发布活行 ∪ `landedThisPage`」里 `syncId` 字典序最小的那一条，
    ///   **只在这个子集里选，不是组内最小**（RR13-5：一条 `syncId` 更小的未发布行当锚点会
    ///   永远不静止 ⇒ §8.4.4 第一步查找恒不命中）；该子集少于两条 ⇒ 这一组零写。
    ///   **「已发布」由 `publishedIdentities` 显式传入**（R-M3-4a-95），本函数手上没有游标表，
    ///   而 `syncId != nil` **不等于**「已发布」：一条本机新建的行在 M1 认领那一刻就有了
    ///   `syncId`、却要等这一轮的发布段才有服务端三元组。
    /// - `anchorRows`：**第一遍**锚点子集的定义域，与写循环的定义域分开（8b-2 fix round 1）。
    ///   尾钩把它喂成**软删之前**那一份活集，而 `liveRows` 是软删**之后**那一份。分开是承重的：
    ///   §8.4.3 的 `writePointer` 在收敛**之前**求那个 `> 1` 的基数，而先收敛再写指针会把
    ///   「两条已发布成员 + 一条从未发布的活行」这一组的子集从 2 掉到 1 ⇒ 那条从未发布的成员
    ///   拿不到指针，而伪码给它写（生命周期表 RR10-8 那一行正是按「它被写过」立的）。
    ///   `nil` ⇒ 与 `liveRows` 同一份（纯值调用点的常态）。
    /// - **只有第一遍用它；第二遍的锚点子集与基数一律从 `liveRows` 算**（8b-2 fix round 2）。
    ///   「锚点 ≤ 胜者 < 每一条败者、所以锚点永不是败者」这条论证**只在分组键与 `convergePass`
    ///   的键相同时成立** —— 也就是第一遍的「此刻的签名」。第二遍的键是
    ///   `preLandingSignatures[id] ?? 此刻的签名`，一条本页按键 K1 被软删掉的败者会以它的**落地前**
    ///   键 K2 重新进组；它在 K2 里完全可能是 `syncId` 最小的那一条 ⇒ 它当上 K2 的锚点，而它是一条
    ///   **同一个事务里刚被软删的死行**，K2 那条活成员的 `mergePartnerSyncId` 会当场指向它
    ///   （更糟：K2 的子集常常正是**靠这条死行**才够到 2）。所以第二遍必须在软删**之后**那一份
    ///   活集上求子集与基数。可达性：一条本页落地了入站 `.move` / `.update` 的行照样保留 pre-pass
    ///   那一刻的静止判定，收敛因此完全可能选中它当败者。
    /// - **前置（承重句，RR12-7）**：只写这一列**此刻**为 nil、或指向一条本机没有活行的身份
    ///   的**活成员**；已经指向一条活行的不动。函数内部按已产出的写更新自己那份状态，于是
    ///   第二遍不会覆盖第一遍。原语那层的「值相同零写」是**第二道防御**，不是承重条款。
    static func mergePointerPass(liveRows: [PhiLocalURLRule],
                                 anchorRows: [PhiLocalURLRule]? = nil,
                                 landedThisPage: Set<String>,
                                 publishedIdentities: Set<String>,
                                 preLandingSignatures: [String: RuleSignature],
                                 resolve: OwnerResolver) -> [String: String] {
        let normalize = mergeNormalize
        // 锚点子集的定义域。`nil` ⇒ 与写循环同一份（纯值调用点的常态）。
        let anchorDomain = anchorRows ?? liveRows
        // 悬空判据的定义域：**全部**活行的身份（含没有签名的那些）。
        var liveIdentities: Set<String> = []
        // 每条身份那一列**此刻**的值，随本函数已经产出的写就地更新。
        var pointer: [String: String] = [:]
        for row in liveRows {
            guard let identity = row.syncId else { continue }
            liveIdentities.insert(identity)
            if let partner = row.mergePartnerSyncId { pointer[identity] = partner }
        }

        var out: [String: String] = [:]
        /// `anchorsFrom` 是**这一遍**求锚点子集与基数的定义域（见签名上 `anchorRows` 那一条）：
        /// 第一遍是软删**之前**那一份活集，第二遍是软删**之后**那一份。
        func pass(_ keyOf: (PhiLocalURLRule) -> RuleSignature?,
                  anchorsFrom: [PhiLocalURLRule]) {
            var groups: [RuleSignature: [PhiLocalURLRule]] = [:]
            for row in liveRows where row.syncId != nil {
                guard let key = keyOf(row) else { continue }
                groups[key, default: []].append(row)
            }
            var anchorGroups: [RuleSignature: [String]] = [:]
            for row in anchorsFrom {
                guard let identity = row.syncId, let key = keyOf(row),
                      publishedIdentities.contains(identity)
                        || landedThisPage.contains(identity) else { continue }
                anchorGroups[key, default: []].append(identity)
            }
            // 固定的遍历次序（`PinKind.swift:361` 的收敛先例）：字典的 `keys` 每进程随机。
            for key in groups.keys.sorted() {
                let members = (groups[key] ?? []).sorted { ($0.syncId ?? "") < ($1.syncId ?? "") }
                let anchors = (anchorGroups[key] ?? []).sorted()
                // 子集少于两条 ⇒ 这一组零写（一条锚点自己不需要伙伴指针）。
                guard anchors.count >= 2, let anchor = anchors.first else { continue }
                for row in members {
                    guard let identity = row.syncId, identity != anchor else { continue }
                    // 承重前置：已经指向一条活行的**不动**。
                    if let current = pointer[identity], liveIdentities.contains(current) { continue }
                    guard pointer[identity] != anchor else { continue }
                    out[identity] = anchor
                    pointer[identity] = anchor
                }
            }
        }
        // 第一遍：键 = 此刻的签名（与 `convergePass` 同一个键）⇒ 基数按伪码的时刻、也就是
        // 软删**之前**那一份活集求。
        pass({ signature(of: $0, resolve: resolve, normalize: normalize) },
             anchorsFrom: anchorDomain)
        // 第二遍：键 = 落地前的签名 ⇒ 「锚点永不是败者」不成立，子集与基数都从软删**之后**
        // 那一份活集求（fix round 2）。
        pass({ row in
            if let identity = row.syncId, let key = preLandingSignatures[identity] { return key }
            return signature(of: row, resolve: resolve, normalize: normalize)
        }, anchorsFrom: liveRows)
        return out
    }

    /// §8.4.3 第 2 步。**只在 `convergeAllowed` 为真时被调**（调用方守门，C-15）。
    /// `atRest` 是**两次减法之后**的候选集：`land` 闭包减掉本页转移目标（计划裁定六 (1) /
    /// R-M3-4a-90），尾钩在事务里再减掉此刻 `pendingLocalEdit` / 已软删 / 已消失的那些
    /// （计划裁定六 (3) / R-M3-4a-100）。本函数**不再加工**它。
    /// `accountStamps` 是 `effectiveAccountStamps(...)` 交回那张表的 **`.content` 那一枚**
    /// （R-M3-4a-94 / 97）：本页落地过的取落地值，本页 `rebaselined` 的取新基线字节，其余取
    /// 游标基线，**没有一层是行上那一列**；`.content` 缺席的身份不进这张字典。
    ///
    /// 对每个签名组：静止成员 < 2 ⇒ 这一组不收敛（`members.count == 1` 且那一条静止且它的
    /// `mergePartnerSyncId != nil` ⇒ 进 `clearedPartners`，生命周期表第 3 行、零额外读）；
    /// 静止成员 ≥ 2 ⇒ 胜者 W = 静止成员里 `syncId` 字典序最小的那一条，
    /// **(a)** `source` = 全部静止成员（**含 W 自己**）里 `accountStamps` 最大的那一条，
    ///         戳相等按 `syncId` 字典序定序；**当且仅当** `source` 的内容组与 W 不同、**或**
    ///         `source` 的戳严格新于 W ⇒ 产出**一条** `RuleContentGroupWrite`（R-M3-4a-82：
    ///         **绝不**逐个败者去比一份固定的 W 快照，照抄来源的戳、绝不铸 `now`）；
    /// **(b)** 每条败者 ⇒ 一条 `RuleSoftDelete(syncId:, mergePartnerSyncId: W.syncId)`；
    /// **(c)** 败者离开的每个桶进 `touchedBuckets`。胜者的 rank 与目标**一个字节都不动**。
    static func convergePass(groups: [RuleSignature: [PhiLocalURLRule]],
                             atRest: Set<String>,
                             accountStamps: [String: Date]) -> URLRuleConvergence {
        let normalize = mergeNormalize
        var out = URLRuleConvergence()
        /// 内容组的可比形式：三个成员都取**归一化之后**的值（V11 回填的老行按定义没过归一化）。
        func content(_ row: PhiLocalURLRule) -> (String, String?, Bool) {
            let normalized = normalize(row.host, row.pathPrefix)
            return (normalized.host, normalized.pathPrefix, row.askBeforeRouting)
        }
        func stamp(_ row: PhiLocalURLRule) -> Date? {
            row.syncId.flatMap { accountStamps[$0] }
        }

        for key in groups.keys.sorted() {
            let members = (groups[key] ?? []).sorted { ($0.syncId ?? "") < ($1.syncId ?? "") }
            let settled = members.filter { row in
                guard let identity = row.syncId else { return false }
                return atRest.contains(identity)
            }
            guard settled.count >= 2 else {
                // 清空规则①（RR9-4 的措辞是硬的：判据是「组里没有第二条活行」，不是「不在
                // 任何签名组里」——后者按字面永不成立，静止第 8 项就是「它有签名」）。
                if members.count == 1, let row = members.first, let identity = row.syncId,
                   atRest.contains(identity), row.mergePartnerSyncId != nil {
                    out.clearedPartners.append(identity)
                }
                continue
            }
            // 胜者：静止成员里 `syncId` 字典序最小的那一条（`settled` 已按它升序）。
            guard let winner = settled.first, let winnerId = winner.syncId else { continue }
            // (a) **整组归约**：一次选出 `source`，一次写。戳相等按 `syncId` 字典序定序，
            //     于是两台机器逐字相同。
            let source = settled.max { left, right in
                (stamp(left) ?? .distantPast, left.syncId ?? "")
                    < (stamp(right) ?? .distantPast, right.syncId ?? "")
            }
            if let source, let sourceStamp = stamp(source) {
                let winnerStamp = stamp(winner) ?? .distantPast
                if content(source) != content(winner) || sourceStamp > winnerStamp {
                    let normalized = normalize(source.host, source.pathPrefix)
                    out.contentGroupWrites.append(
                        RuleContentGroupWrite(syncId: winnerId,
                                              host: normalized.host,
                                              pathPrefix: normalized.pathPrefix,
                                              ask: source.askBeforeRouting,
                                              // D33 / §8.4.1 第五条：**照抄来源的戳**，绝不铸 `now`。
                                              contentUpdatedDate: sourceStamp))
                }
            }
            // (b) / (c)：`settled.first` **绝不**进这个定义域（本机这一台上某个签名组一条不剩
            //     正是 CASE M-5 要防的那一格）。
            for loser in settled.dropFirst() {
                guard let identity = loser.syncId else { continue }
                out.softDeletes.append(RuleSoftDelete(syncId: identity,
                                                      mergePartnerSyncId: winnerId))
                out.collapsed += 1
                out.touchedBuckets.insert(loser.spaceId)
            }
        }
        return out
    }

    /// 尾钩的全部内容，**纯函数**。次序：过滤活行 ⇒ 建组 ⇒
    /// `effectiveAccountStamps(landed:rebaselined:table:identities:)`（R-M3-4a-94 / 97）⇒
    /// **把 `atRest` 里此刻 `pendingLocalEdit == true` / `deletedDate != nil` / 行已不在的那些
    /// 剔掉**（R-M3-4a-100；`rows` 就是事务里刚重读的那一份，零额外读）⇒（闸开才）
    /// `convergePass`（喂进去的是那张表的 `.content` 那一枚）⇒ 跑 `mergePointerPass`
    /// （计划裁定四；写循环在**软删之后**的活集上，**第一遍**的锚点子集在**软删之前**那一份
    /// 上、**第二遍**的仍在软删之后那一份上）⇒
    /// 按 `.setContentGroup` → `.softDelete` →
    /// `.setMergePartner` 的相序拼 ops。
    ///
    /// **`convergePass` 先于 `mergePointerPass` 的等价性证明**（计划裁定四）。§8.4.3 的伪码把
    /// 第一遍指针与收敛按组交织，第二遍指针跑在整个循环之后的 `liveAfter` 上；这里是**先
    /// 收敛、再两遍指针一次做完**。终态逐字相同、行写严格更少，**三条腿**：
    ///
    /// **(1) 锚点的身份不变** —— 锚点 = 「已发布活行 ∪ `landedThisPage`」里 `syncId` 最小的
    /// 那一条，胜者 = 静止成员里 `syncId` 最小的那一条，而静止**蕴含**已发布（判据 1 / 2）
    /// ⇒ 静止成员 ⊆ 锚点候选集 ⇒ `锚点 ≤ 胜者 < 每一条败者`，且锚点自己若静止就**是**胜者、
    /// 永不当败者 ⇒ 移走败者既不改变锚点的身份，也不会让锚点那一**行**消失。
    ///
    /// **(2) 锚点子集的基数不变 —— 只对第一遍成立，而第一遍正是伪码求那个基数的地方**
    /// （8b-2 fix round 1 + fix round 2）。这条腿靠的不是论证而是**接缝**：伪码的
    /// `writePointer` 在收敛**之前**求 `published.count > 1`，而先收敛会把「两条已发布成员 +
    /// 一条从未发布、本页也没落地的活行」这一组的子集从 2 掉到 1 —— 伪码给那条从未发布的成员
    /// 写指针（生命周期表 RR10-8 那一行按「它被写过」立），先收敛的版本一条都不写。所以
    /// **第一遍**（键 = 此刻的签名，与 `convergePass` 同一个键）的锚点子集建在 `anchorRows`
    /// （软删之前那一份活集）上，写循环仍然只跑 `liveRows`（软删之后那一份）。
    ///
    /// **第二遍不能这么做**：它的键是 `preLandingSignatures[id] ?? 此刻的签名`，与
    /// `convergePass` 的键**不是同一个**，(1) 的「锚点 ≤ 胜者 < 每一条败者」因此不适用 ——
    /// 一条按 K1 被软删掉的败者会以它的落地前键 K2 重新进组，并且完全可能是 K2 里 `syncId`
    /// 最小的那一条 ⇒ 它当上 K2 的锚点，而它是一条**同一个事务里刚被软删的死行**（K2 的子集
    /// 还常常正是靠它才够到 2）。所以**第二遍的子集与基数一律从 `liveRows` 求**。这不违反
    /// 伪码：伪码的第二遍本来就跑在 `liveAfter` 上。
    ///
    /// **(3) 终值支配** —— 伪码里败者行上会先被第一遍写成锚点、再被 (b) 覆盖成胜者，净结果
    /// 是胜者；这里败者根本不进指针的**写**定义域，净结果同样是胜者。非败者行两种次序下的
    /// 输入完全相同。**RR11-2 的「指针不得覆盖 (b) 的终值」因此是结构性成立的，不靠任何运行
    /// 期判断。**
    ///
    /// `table:` / `landed:` / `rebaselined:` 三个入参供且仅供 `effectiveAccountStamps` 用
    /// （R-M3-4a-90 曾把 `table:` 删掉，R-M3-4a-94 恢复：有效账户戳的「未落地那一半」只能从
    /// 游标基线读；`rebaselined:` 是 R-M3-4a-97 的第二层）；
    /// **`convergePass` 仍然不许自己去翻 `table`** —— 它只拿算好的 `accountStamps`。
    /// `publishedIdentities` 供且仅供 `mergePointerPass` 选锚点用（R-M3-4a-95）。
    /// `atRest` 是**上界**：`land` 闭包已经减过本页转移目标，本函数在事务里再减一次。
    static func mergePass(rows: [PhiLocalURLRule],
                          landedThisPage: Set<String>,
                          publishedIdentities: Set<String>,
                          preLandingSignatures: [String: RuleSignature],
                          atRest: Set<String>,
                          landed: [String: URLRuleLandingValues],
                          rebaselined: [String: Data],
                          table: PhiOwnedItemTable,
                          convergeAllowed: Bool,
                          resolve: OwnerResolver) -> URLRuleMergeResult {
        let normalize = mergeNormalize
        var out = URLRuleMergeResult()
        // 活行过滤与 `allURLRules()` 同一条判据（R-M3-4a-51）：一条用户刚删掉的行绝不当成员
        // （CASE M-10）。寻址那一侧要软删行，所以入参是含软删行的那一份。
        let live = rows.filter { $0.deletedDate == nil }

        var groups: [RuleSignature: [PhiLocalURLRule]] = [:]
        for row in live where row.syncId != nil {
            guard let key = signature(of: row, resolve: resolve, normalize: normalize) else {
                continue
            }
            groups[key, default: []].append(row)
        }

        // R-M3-4a-100 的第二次减法：**只减不加**。一条 pre-pass 说不静止的行绝不因为事务里
        // 看起来干净就被加回来（那会绕过游标侧的七个合取项与第 10 项，CASE M-27 / M-36）。
        // 这三个合取项恰好是十项静止谓词里**只读行**的那三项，重读的这份投影本来就带着它们。
        var rowOf: [String: PhiLocalURLRule] = [:]
        for row in rows {
            guard let identity = row.syncId else { continue }
            if row.deletedDate == nil || rowOf[identity] == nil { rowOf[identity] = row }
        }
        let candidates = atRest.filter { identity in
            guard let row = rowOf[identity] else { return false }   // 行已不在
            return !row.pendingLocalEdit && row.deletedDate == nil
        }

        // 这张表在本页只算一次的那一份的尾钩侧副本：纯函数、输入逐字相同 ⇒ 与 `land` 闭包
        // 拼批次之前算的那一张不可能分叉（R-M3-4a-98 的「同一张表」就是这个含义）。
        var asked: Set<String> = landedThisPage
        for members in groups.values {
            for row in members { if let identity = row.syncId { asked.insert(identity) } }
        }
        let stamps = effectiveAccountStamps(landed: landed, rebaselined: rebaselined,
                                            table: table, identities: asked)
        var contentStamps: [String: Date] = [:]
        for (identity, pair) in stamps {
            if let content = pair.content { contentStamps[identity] = content }
        }

        // C-15：闸只管第 2 步。第 1 步的指针与上面的查表都不在闸后面。
        let convergence = convergeAllowed
            ? convergePass(groups: groups, atRest: candidates, accountStamps: contentStamps)
            : URLRuleConvergence()

        // 计划裁定四：指针跑在**软删之后**的活集上。内容组写不改变签名（`ask` 不在签名里，
        // `host` / `pathPrefix` 写的就是这一组共用的那个归一化值），所以这里只减败者。
        let collapsedIds = Set(convergence.softDeletes.map(\.syncId))
        let liveAfter = live.filter { row in
            guard let identity = row.syncId else { return true }
            return !collapsedIds.contains(identity)
        }
        // 写循环跑软删之后那一份活集，**锚点子集跑软删之前那一份**（等价性证明的第 (2) 腿）。
        let pointers = mergePointerPass(liveRows: liveAfter, anchorRows: live,
                                        landedThisPage: landedThisPage,
                                        publishedIdentities: publishedIdentities,
                                        preLandingSignatures: preLandingSignatures,
                                        resolve: resolve)

        // 相序：`.setContentGroup` → `.softDelete` → `.setMergePartner`。清空（规则①）排在
        // 指针写**之前**：同一条身份若两者都命中（第一遍单成员、第二遍按落地前签名进了一个
        // 更大的组），后到的那条指针写才是终值。
        for write in convergence.contentGroupWrites.sorted(by: { $0.syncId < $1.syncId }) {
            out.ops.append(.setContentGroup(syncId: write.syncId, host: write.host,
                                            pathPrefix: write.pathPrefix, ask: write.ask,
                                            contentUpdatedDate: write.contentUpdatedDate))
        }
        for delete in convergence.softDeletes.sorted(by: { $0.syncId < $1.syncId }) {
            out.ops.append(.softDelete(syncId: delete.syncId,
                                       mergePartnerSyncId: delete.mergePartnerSyncId))
        }
        for identity in convergence.clearedPartners.sorted() {
            out.ops.append(.setMergePartner(syncId: identity, mergePartnerSyncId: nil))
        }
        for identity in pointers.keys.sorted() {
            out.ops.append(.setMergePartner(syncId: identity, mergePartnerSyncId: pointers[identity]))
        }

        out.collapsed = convergence.collapsed
        out.touchedBuckets = convergence.touchedBuckets
        // §6.6 第 8 行的触发条件：**指针写不算**（CASE M-7 钉住零刷新）。
        out.changedRouting = !convergence.softDeletes.isEmpty
            || !convergence.contentGroupWrites.isEmpty
        return out
    }
}
