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

    /// §8.2 的盖戳。三个单元三条规则：
    ///
    /// - **内容组**：三个成员按 signature 整组比，变了整组盖 `now`，否则沿用基线的载体戳
    ///   （`host`）；三个成员**一律写成相等**（§8.2 第 1 条）。
    /// - **目标**：变了 ⇒ 目标戳与 rank 戳**都**盖 `now`（§8.2 第 4 条：桶变了，在新桶里的
    ///   位置也是新的）；否则目标戳沿用基线，rank 戳按自己的 signature 比。只靠「rank 串变了
    ///   才盖」不够：一次搬桶之后 rank 串偶然相同时，合并的第三行会拿到一枚旧戳。
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
        setContentStamp(&out, contentChanged ? now : baseline.host.updatedAtMs)

        let targetChanged = SyncableSettings.signature(of: out.targetSpaceUuid)
            != SyncableSettings.signature(of: baseline.targetSpaceUuid)
        if targetChanged {
            out.targetSpaceUuid.updatedAtMs = now
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
