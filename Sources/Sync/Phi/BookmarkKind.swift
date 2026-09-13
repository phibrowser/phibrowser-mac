// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// 书签 / 文件夹这一种 kind 的适配：编解码、字段 LWW 表、归属解析、盖戳。
//
// 这里是 §4.3「位置 = `location` + `rank`」那条规则**唯一**的实现点。位置分成两半，成员
// 按这条实体在树里的位置不同：
//
//     这条实体              location 的成员                       space_uuid
//     根级项（parent == ""） space_uuid + parent_uuid（共用一个戳） 权威
//     子孙（parent != ""）   parent_uuid（自己的戳）               只作诊断，接收端忽略
//
// `rank` 在两种情形下都**独立**，带自己的戳。

enum BookmarkKind: OwnedItemKind {
    typealias Entity = Phi_PhiBookmarkEntity
    typealias Local = PhiLocalBookmark

    static var tagPrefix: String { PhiSyncEntity.bookmarkTagPrefix }
    static var entityName: String { PhiSyncEntity.bookmarkEntityName }

    // MARK: - 身份与信封

    static func identity(of entity: Phi_PhiBookmarkEntity) -> String { entity.bookmarkUuid }

    /// 本机行的账户身份就是 `syncId`。nil = 这一行还没铸过身份——它**仍然可以被 §6 的
    /// 规则 (i) 认领**，所以这里不是「跳过它」的理由，只是「本轮不发布它」。
    static func identity(of local: PhiLocalBookmark, resolve: OwnerResolver,
                         scope: PinnedTabScope?) -> String? {
        local.syncId
    }

    static func envelope(_ entity: Phi_PhiBookmarkEntity) -> Phi_PhiEntity {
        var out = Phi_PhiEntity()
        out.bookmark = entity
        return out
    }

    static func entity(from envelope: Phi_PhiEntity) -> Phi_PhiBookmarkEntity? {
        guard case .bookmark(let payload)? = envelope.kind else { return nil }
        return payload
    }

    static func localEdge(of local: PhiLocalBookmark) -> (id: String, parentId: String?) {
        (id: local.guid, parentId: local.parentGuid)
    }

    // MARK: - 归属

    /// 落地之前必须已经解析出来的那一个归属引用。
    ///
    /// 子孙返回 `parent_uuid`，根级项返回 `space_uuid`。**子孙的 `space_uuid` 不在里面**：
    /// 它是诊断字段、接收端忽略、而且永不重发（R-M3-3-18），所以它会永远停在搬家之前的
    /// 那个 Space 上。把它也算成必须解析，一次「把文件夹移走再删掉旧 Space」就会让整棵
    /// 子树在每一台新设备上**永久**停放。
    static func ownerUuids(of entity: Phi_PhiBookmarkEntity) -> [String] {
        let parent = entity.parentUuid.stringValue
        if !parent.isEmpty { return [parent] }
        let space = entity.spaceUuid.stringValue
        return space.isEmpty ? [] : [space]
    }

    // MARK: - 出站投影与盖戳（§4.2）

    /// 本机行 → 线上实体，**不盖戳也不填 rank**。
    ///
    /// 两条 nil：Space 没有映射（`excluded_unmapped_owner` 的第一半），以及一条有父的行
    /// 的父**不是本轮的同步合格行**（§4.2 第 2 条）——那样的行本轮整条跳过，绝不能退化成
    /// 「挂到 Space 根上」发出去。
    static func project(_ local: PhiLocalBookmark, resolve: OwnerResolver,
                        scope: PinnedTabScope?, parentIdentity: String?) -> Phi_PhiBookmarkEntity? {
        guard let spaceUuid = resolve.syncUuid(local.spaceId) else { return nil }
        if local.parentGuid != nil && parentIdentity == nil { return nil }

        var entity = Phi_PhiBookmarkEntity()
        entity.bookmarkUuid = local.syncId ?? ""
        entity.spaceUuid = string(spaceUuid)
        entity.parentUuid = string(parentIdentity ?? "")
        entity.rank = string("")
        entity.isFolder = local.isFolder
        entity.title = string(local.title)
        entity.url = string(local.url.absoluteString)
        entity.secondaryURL = string(local.secondaryUrl?.absoluteString ?? "")
        entity.secondaryTitle = string(local.secondaryTitle ?? "")
        entity.source = Int32(truncatingIfNeeded: local.source)
        entity.createdAtMs = milliseconds(local.createdDate)
        return entity
    }

    static func rank(of entity: Phi_PhiBookmarkEntity) -> String { entity.rank.stringValue }

    /// 位置合并的载体戳：根级项取 `space_uuid` 的戳，子孙取 `parent_uuid` 的戳。
    ///
    /// **绝不取两者的 `max`**：一个取 `max` 的实现与一个取固定成员的实现会对同一份字节算出
    /// 不同的时间戳，于是各自认为自己赢、每轮互相重发，**永不收敛**。收到的两个成员时间戳
    /// 若不等（只可能来自更旧或有 bug 的对端），仍然用载体那一个，没有例外分支。
    static func locationStamp(of entity: Phi_PhiBookmarkEntity) -> Int64 {
        entity.parentUuid.stringValue.isEmpty
            ? entity.spaceUuid.updatedAtMs
            : entity.parentUuid.updatedAtMs
    }

    /// §4.2 第 4 / 5 条的盖戳。三组字段三条规则：
    ///
    /// - **location**（`space_uuid` + `parent_uuid`）：两个成员共用一个戳。任一成员变化 ⇒
    ///   盖 `now`；**只改次序 ⇒ 一动不动**。
    /// - **rank**：自己的戳，与 location 无关。
    /// - **内容字段**：逐字段按 signature 比，变了盖 `now`。
    ///
    /// 无基线那一支按 §4.2 第 5 条：location 与 rank 都盖 **0**（本机派生出来的位置不该赢
    /// 过对端任何一次真实操作），内容字段盖 **`contentUpdatedDate ?? createdDate`**——一条
    /// 几年前建的、从没人动过的本机书签若以 `now` 首发，它会在被对端那条同 (路径, URL) 的
    /// 实体认领时赢下对端上周做的改名。
    static func stamp(_ projected: Phi_PhiBookmarkEntity, baseline: Phi_PhiBookmarkEntity?,
                      local: PhiLocalBookmark, rank: String, now: Int64) -> Phi_PhiBookmarkEntity {
        var out = projected
        out.rank = string(rank)
        let contentStamp = milliseconds(local.contentUpdatedDate ?? local.createdDate)

        guard let baseline else {
            out.spaceUuid.updatedAtMs = 0
            out.parentUuid.updatedAtMs = 0
            out.rank.updatedAtMs = 0
            out.title.updatedAtMs = contentStamp
            out.url.updatedAtMs = contentStamp
            out.secondaryURL.updatedAtMs = contentStamp
            out.secondaryTitle.updatedAtMs = contentStamp
            return out
        }

        // 子孙的 `space_uuid` **永不重发**（R-M3-3-18）：照抄基线那一份。本机跨 Space 移动
        // 一个文件夹时 `moveBookmarks` 会重打整棵子树的 `spaceId`，若这里发新值，四十个
        // 后代的字节全都会变，于是四十条无谓的 commit 把对端同时做的一次排序整个盖掉。
        if !out.parentUuid.stringValue.isEmpty { out.spaceUuid = baseline.spaceUuid }

        let locationStamp = locationValue(out) == locationValue(baseline)
            ? Self.locationStamp(of: baseline) : now
        out.spaceUuid.updatedAtMs = locationStamp
        out.parentUuid.updatedAtMs = locationStamp
        out.rank.updatedAtMs = restamped(out.rank, baseline.rank, now)
        out.title.updatedAtMs = restamped(out.title, baseline.title, now)
        out.url.updatedAtMs = restamped(out.url, baseline.url, now)
        out.secondaryURL.updatedAtMs = restamped(out.secondaryURL, baseline.secondaryURL, now)
        out.secondaryTitle.updatedAtMs = restamped(out.secondaryTitle, baseline.secondaryTitle, now)
        return out
    }

    // MARK: - 合并（§4.3）

    /// 字段级 LWW + 位置相干规则，**对称地写**（不带「本机 / 对面」的视角）：
    ///
    ///     location = LWW(location_X, location_Y)
    ///     rank     = (location_X == location_Y) ? LWW(rank_X, rank_Y)
    ///                                          : rank(赢下 location 的那一条实体)
    ///
    /// 第二行就是**相干**：一个 rank 只在它所属的那个 `location` 里有意义。写成「当赢家是
    /// 对面那一侧时才取对面的 rank」会只修一半——本机赢下 `location` 而对端的 `rank` 时间戳
    /// 更新时，plain LWW 会把一个在**输掉的** location 里铸出来的 rank 装到赢家的 location
    /// 上，于是两台机器从同一对实体算出**不同**的结果。
    ///
    /// **从 `remote` 起手**：`Phi_PhiBookmarkEntity()` 不带 `unknownFields`，从它起手会把
    /// 更新版本客户端写在预留字段 12-15 上的内容在每一轮里都抹掉一次。
    static func merge(local: Phi_PhiBookmarkEntity,
                      remote: Phi_PhiBookmarkEntity) -> Phi_PhiBookmarkEntity {
        var merged = remote
        merged.bookmarkUuid = local.bookmarkUuid.isEmpty ? remote.bookmarkUuid : local.bookmarkUuid

        let localBallot = locationBallot(local)
        let remoteBallot = locationBallot(remote)
        let localWins = SyncableSettings.lwwWinner(localBallot, remoteBallot) == localBallot
        let winner = localWins ? local : remote
        merged.spaceUuid = winner.spaceUuid
        merged.parentUuid = winner.parentUuid
        // §4.3：发送时同一条实体的两个成员写成相等。
        let stamp = locationStamp(of: winner)
        merged.spaceUuid.updatedAtMs = stamp
        merged.parentUuid.updatedAtMs = stamp
        merged.rank = localBallot.stringValue == remoteBallot.stringValue
            ? SyncableSettings.lwwWinner(local.rank, remote.rank)
            : winner.rank

        // INVARIANT, not LWW：一条行不会在书签与文件夹之间变形，两侧不符的那条实体在落地
        // 处被 §4.6 拒收。这里取并是为了**对称**（合并结果与调用顺序无关），同时让一个
        // 文件夹永远不会因为一次分歧退化成书签——退化会让它的孩子在落地时无处可挂。
        merged.isFolder = local.isFolder || remote.isFolder

        merged.title = SyncableSettings.lwwWinner(local.title, remote.title)
        merged.url = SyncableSettings.lwwWinner(local.url, remote.url)
        merged.secondaryURL = SyncableSettings.lwwWinner(local.secondaryURL, remote.secondaryURL)
        merged.secondaryTitle = SyncableSettings.lwwWinner(local.secondaryTitle,
                                                           remote.secondaryTitle)
        // NOT last-writer-wins：非零的一侧赢；两侧都非零且不同时取较小者。
        merged.source = mergedSource(local.source, remote.source)
        // NOT last-writer-wins：最早的创建时刻才是真的那一个。
        let created = [local.createdAtMs, remote.createdAtMs].filter { $0 > 0 }
        merged.createdAtMs = created.min() ?? 0
        return merged
    }

    // MARK: - 拒收（§4.6）

    /// 结构非法的载荷。`nil` = 接受。
    ///
    /// **`rank` 这一条是 `rankBetween` 的解码边界**：那个函数在发布构建里用 `precondition`
    /// 直接 trap，而对端字节是不可信输入。书签让这件事更严重：rank 只在同一个父下可比，
    /// 一次非法 rank 能污染的是一整个文件夹。
    ///
    /// `.isFolderMismatch` 与 `.cycle` 不在这里判——前者要本机那一行、后者要整个工作集，
    /// 两者都由调用方（落地路径与 `plan`）产出。
    static func refuses(_ entity: Phi_PhiBookmarkEntity) -> OwnedItemRefusal? {
        let uuid = entity.bookmarkUuid
        guard isAccountUuid(uuid) else { return .invalidUuid }
        guard SyncableSpaces.isLegalRank(entity.rank.stringValue) else { return .illegalRank }
        if entity.parentUuid.stringValue == uuid { return .selfReference }
        if !entity.isFolder, URL(string: entity.url.stringValue) == nil { return .invalidURL }
        return nil
    }

    // MARK: - 落地投影（§4.10）

    /// 线上是 rank，本机是稠密 `index`：按 `rank`（平手按身份 uuid）排同一个父下的兄弟，
    /// 写出 `guid -> index`。
    ///
    /// **喂进来的兄弟列表不过滤**：被排除的兄弟留着的旧 `index` 会与新写的撞上。没有 rank
    /// 的行（还没发布过）排在最前，与 `assignRanks` 的补集规则同向。
    static func rankToIndex(siblings: [PhiLocalBookmark], ranks: [String: String]) -> [String: Int] {
        let ordered = siblings.sorted { left, right in
            let leftRank = left.syncId.flatMap { ranks[$0] } ?? ""
            let rightRank = right.syncId.flatMap { ranks[$0] } ?? ""
            if leftRank != rightRank { return leftRank < rightRank }
            return (left.syncId ?? left.guid) < (right.syncId ?? right.guid)
        }
        var out: [String: Int] = [:]
        for (index, row) in ordered.enumerated() { out[row.guid] = index }
        return out
    }

    // MARK: - 私有

    /// `location` 的值：根级项是 `(space_uuid, "")`，子孙是 `("", parent_uuid)`——子孙的
    /// `space_uuid` 不进 location 的值。
    private static func locationValue(_ entity: Phi_PhiBookmarkEntity) -> (String, String) {
        let parent = entity.parentUuid.stringValue
        return parent.isEmpty ? (entity.spaceUuid.stringValue, "") : ("", parent)
    }

    /// 把 `location` 这一整组压成一个可以直接喂进 `SyncableSettings.lwwWinner` 的选票
    /// （R4 单一实现：平手仍然按序列化字节字典序，且对称）。
    ///
    /// 前缀 `s` / `p` 让「根级项在 Space X 下」与「子孙挂在 uuid 为 X 的父下」**不会撞成
    /// 同一张票**：撞上之后平手分支会退化成「返回左边那一个」，而那不是对称的。
    private static func locationBallot(_ entity: Phi_PhiBookmarkEntity) -> Phi_PhiSettingValue {
        let value = locationValue(entity)
        var ballot = string(value.1.isEmpty ? "s\u{0}" + value.0 : "p\u{0}" + value.1)
        ballot.updatedAtMs = locationStamp(of: entity)
        return ballot
    }

    /// 与基线同名字段的 signature 相同 ⇒ 沿用基线的时间戳；不同 ⇒ 盖 `now`。
    /// signature 是「把 `updatedAtMs` 清零后的字节」（R4 单一实现）。
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

    /// 一个**账户级**身份该有的形状。
    ///
    /// 刻意**不**做 RFC-4122 校验：这条判据要挡的是「一台设备把自己的本机 `guid` 发上线」
    /// （`guid` 是大写、按设备、每次克隆重铸，§3.1），而不是规定对端只能用某一种 uuid
    /// 生成器。严格校验会连带拒掉每一条形状合法但生成方式不同的对端实体。
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

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
