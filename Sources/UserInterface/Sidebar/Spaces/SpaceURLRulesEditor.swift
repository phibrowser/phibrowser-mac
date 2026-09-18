// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Universal editor for every Space's URL routing rules. Reachable from the
/// Spaces menu in the main menu bar. Each row carries its own target Space
/// picker so the user can manage all rules in one list — moving a rule from
/// one Space to another is a picker change, not a delete-and-recreate.
///
/// Persists through `SpaceManager.applyRuleEdits(upserts:deletedIds:)`, which
/// touches only the rows this sheet names — rows it never saw are left alone,
/// including ones that landed from another device while it was open. The
/// routing table is refreshed once, after the write commits. No direct
/// LocalStore writes from the view, no manual bridge calls.
///
/// Stays intentionally small: one host per row matched as either a domain
/// suffix (host + all subdomains) or an exact domain, enable toggle,
/// drag-to-reorder within the flat list. Dense per-target sort order is the
/// store's job, not this view's.
struct URLRulesEditor: View {
    @ObservedObject var manager: SpaceManager
    let onClose: () -> Void

    @State private var rows: [Row] = []
    @State private var editingStoreIdentifier: UUID?
    /// The rows exactly as `load()` built them. Kept for the §5.8 call shape;
    /// M5 (8b-4) moved the "did the user touch this row" answer to `dirty`.
    @State private var loadedRows: [Row] = []
    /// Rows the user deleted in this sheet, in deletion order. Only the ones
    /// that came from the store (`storeId != nil`) turn into `deletedIds`.
    @State private var removedRows: [Row] = []
    /// M5（R-M3-4a-72）：用户自 `load()` 以来**真的动过**的那些控件，按行记。
    /// 记的是「碰过」；比值那一步在 `save()` 里对**库里此刻**的行做（裁定 8）。
    @State private var dirty: [UUID: RowDirty] = [:]

    /// Sentinel selection in a row's target-Space picker meaning "don't route
    /// to a fixed Space — prompt every time". Distinct from any real
    /// `spaceId` (UUID strings / "default-space"), so it can never collide.
    static let askSpaceTag = "__phi_ask__"

    /// M5（R-M3-4a-72）：一行上被用户动过的那些**控件**。
    ///
    /// **按控件记，不按「host / pathPrefix」两列记**（裁定 7）：编辑器里 host 与 pathPrefix 是
    /// **同一个文本框** + 一个 `MatchType` 选择器，由 `MatchType.encode(value:)` 在 Save 时拆成
    /// 两列，拆出来的两半不可能各自变脏；而 §4.3 第 4 条的合并单元本来就是「内容组」这**一个**
    /// （三个字段共用一枚戳）。`ask` 同样没有独立控件：它由目标选择器的 `askSpaceTag` 哨兵承载，
    /// 所以那**一个**闭包两个单元都可能碰——选中哨兵 ⇒ 只脏 `.ask`；选中一个真 Space ⇒
    /// 脏 `[.ask, .target]`。
    struct RowDirty: OptionSet {
        let rawValue: Int
        /// 文本框；`MatchType.encode` 把它拆成 host / pathPrefix。
        static let value     = RowDirty(rawValue: 1 << 0)
        static let matchType = RowDirty(rawValue: 1 << 1)
        static let ask       = RowDirty(rawValue: 1 << 2)
        static let target    = RowDirty(rawValue: 1 << 3)
        static let order     = RowDirty(rawValue: 1 << 4)
        /// 内容组这**一个**合并单元的三个控件（§4.3 第 4 条 / D15）。
        static let content: RowDirty = [.value, .matchType, .ask]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ruleList
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 380, idealHeight: 460)
        .onAppear {
            editingStoreIdentifier = manager.storeIdentifier
            load()
        }
        .onChange(of: manager.storeIdentifier) { _, _ in onClose() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("sidebar.urlRulesEditor.title", value: "URL Rules",
                comment: "Title of the universal URL rules editor"))
                .font(.headline)
            Text(NSLocalizedString("sidebar.urlRulesEditor.subtitle", value: "URLs matching any rule will open in the selected destination, no matter where you click or type them.",
                comment: "Subtitle of the universal URL rules editor"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Destinations a rule may target: every user Space, ONE generic
    /// "Incognito" entry, and Kiosk. Incognito Spaces are runtime-only, so a
    /// rule never points at a specific one — it carries the stable generic id
    /// (`SpaceManager.incognitoRuleTargetId`), resolved to a live Incognito
    /// Space (created on demand) at route time. Kiosk similarly uses a stable
    /// reserved id that Chromium resolves to a new ephemeral Kiosk window.
    /// Agent Spaces are ephemeral background workspaces and must never appear
    /// as a routing target.
    private var ruleTargetSpaces: [Space] {
        manager.spaces.filter { !SpaceManager.isIncognitoSpaceId($0.spaceId) && !$0.isAgentSpace }
            + [manager.incognitoRuleTargetSpace(), manager.kioskRuleTargetSpace()]
    }

    private var ruleList: some View {
        // The table host is always mounted (even when empty), so deleting the
        // last rule doesn't tear down the NSView tree mid-animation and adding
        // the first rule doesn't rebuild it. The empty-state placeholder lives
        // inside the host (see RuleTableView.makeEmptyOverlay).
        RuleTableView(rows: $rows, removedRows: $removedRows, dirty: $dirty,
                      spaces: ruleTargetSpaces)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                addBlankRow()
            } label: {
                Label(NSLocalizedString("sidebar.urlRulesEditor.addRuleButton", value: "Add Rule", comment: "Footer button in URL rules editor"),
                      systemImage: "plus")
            }
            .disabled(ruleTargetSpaces.isEmpty)
            Spacer()
            Button(NSLocalizedString("sidebar.urlRulesEditor.cancelButton", value: "Cancel", comment: "Cancel button")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("sidebar.urlRulesEditor.saveButton", value: "Save", comment: "Save button")) {
                save()
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Data

    private func load() {
        rows = manager.allRules.map(Row.init(from:))
        loadedRows = rows
        removedRows = []
        // M5：一次新的加载 = 一张新的脏位表。`initialFingerprint` 与 `fingerprint(of:)` 是
        // 「整表写回」时代的守卫，已经整条删掉——留着会在「用户改了又改回来」时挡掉一次本该
        // 为空的 Save，而空 Save 现在由「零脏位 ⇒ 零 upsert」表达。
        dirty = [:]
    }

    private func addBlankRow() {
        guard let firstSpaceId = ruleTargetSpaces.first?.spaceId else { return }
        // 新行**不看脏位**（裁定 11 / 12）：它在库里查不到，走 `applyURLRuleEditsBody` 的插入支，
        // upsert 带满三个单元。所以这里一个脏位都不记。
        rows.append(Row(defaultSpaceId: firstSpaceId))
    }

    private func save() {
        guard let editingStoreIdentifier,
              manager.acceptsStoreAction(from: editingStoreIdentifier) else { return }
        let rows = self.rows
        let loaded = self.loadedRows
        let removed = self.removedRows
        let dirty = self.dirty
        let manager = self.manager
        // 写在 main actor 上等提交；失败只记一行（R12：错误走 `describe`，不带 host / id），
        // sheet 里的草稿一个字不动。路由表的刷新由 `applyRuleEdits` 在提交之后做（R-M3-4a-34）。
        Task { @MainActor in
            // 裁定 8：比较基线是一次**新的** store 读（§5.8 第 4 条「记脏基线随库走」），落点是
            // `reloadURLRulesFromStore()` 之后的 `manager.allRules`。`load()` 那一刻的 `loadedRows`
            // 只用来回答「用户碰过没有」，绝不用来回答「与库里还差不差」。不直读 store 是因为
            // 视图层的既有边界（见文件头注释）；多出来的那次路由推送与 Save 之后本来就要发的那
            // 一次幂等同形。
            manager.reloadURLRulesFromStore()
            let edits = Self.computeEditSet(rows: rows, loaded: loaded, removed: removed,
                                            stored: manager.allRules, dirty: dirty)
            // 两个集合都空 ⇒ **连 `applyRuleEdits` 都不调**（零写、零置位、零刷新）。
            guard !edits.isEmpty else { return }
            do {
                try await manager.applyRuleEdits(upserts: edits.upserts, deletedIds: edits.deletedIds,
                                                 expectedStoreIdentifier: editingStoreIdentifier)
            } catch {
                AppLogError("[URLRulesEditor] applyRuleEdits failed: \(PhiSyncLog.describe(error))")
            }
        }
    }

    /// One Save's worth of edits, addressed row by row (R-M3-4a-30).
    struct EditSet {
        var upserts: [LocalStore.URLRuleDraft]
        var deletedIds: Set<String>

        var isEmpty: Bool { upserts.isEmpty && deletedIds.isEmpty }
    }

    /// Pure: the whole §5.8 contract in one function so it is testable without a view.
    //
    // 逐条契约（§5.8 第 1 / 2 / 5 条 + M5 的裁定 11 / 12，R-M3-4a-72）：
    // - **删除半边排在脏位过滤之前，一个字不改**：`storeId != nil` 且清空（`value` trim 后为空
    //   或 `encode` 后 host 为空）⇒ `deletedIds` 里放 `storeId`（不是重铸后的 `row.id`）；
    //   `removed` 里 `storeId != nil` 的行同样进 `deletedIds`；`storeId == nil` 的空行 / 从没落过
    //   库的行直接忽略。删除**一个脏位都不看**（R-M3-4a-69：删除不是编辑）。
    // - `storeId == nil`（本次 sheet 新建）⇒ **不看脏位**，走扁平 init 的整条 upsert
    //   （`syncId == nil`，插入点铸，R-M3-4a-23）。
    // - `storeId != nil` 且**零脏位** ⇒ 跳过。**含「库里已经没有这一行」那一支**：用户没碰过的
    //   行被别的设备删掉了，本机不复活它（裁定 11 的后半个分支）。
    // - `storeId != nil`、`stored` 里**找不到**它、且**有脏位** ⇒ **恢复支**（R-M3-4a-101）：
    //   一条**完整 draft**（三个单元全带、取值一律来自 sheet 里那一行此刻的值），`id` 用这一行
    //   原来的本机 `id`，**`syncId` 传 `nil`**。旧身份此刻在账户上是一条 tombstone（硬删）或一条
    //   软删行（M2 / §8.4.4 (β)）——**编辑器这一层看不出区别，也不需要看出**（R-M3-4a-104）：
    //   两种现实用**同一份** draft，分流由 `applyURLRuleEditsBody` 的第 2b 步在写事务里做。
    //   **绝不复用旧的 `syncId`**：那是让编辑器去做一次复活，而复活只走 3b。
    // - 否则按 `.content` / `.target` / `.order` **三组各自**与 `stored[storeId]` 此刻的值比，
    //   仍然不同的才填进对应的可选单元；三个都 nil ⇒ 跳过（零写、零盖戳、零置位）。
    //
    // **恢复支排在三组比值之前**：库里那一行已经没了，拿它去比会退化成「三个都不同」的**按
    // 单元** draft，而那份 draft 落进 store 的插入支会因为 `content`/`spaceId` 可能缺席抛
    // `noCandidateSurvived`、**整批回滚**（用户按了 Save、界面没报错、什么都没写进去）。
    //
    // **没有第三遍「整桶重排」**（裁定 12）：拖动落点只给**被拖动那一行**记 `.order`，其余兄弟
    // 行的稠密重编号由 `applyURLRuleEditsBody` 第 8 步的重排定义域完成，而且**不置位**。给整桶
    // 记脏的实现会把整桶置位 ⇒ 那一轮整桶不静止、整桶对远端删除让位（CASE U-21）。
    //
    // `loaded` 保留在签名里（§5.8 的调用形状），M5 之后「用户碰过没有」由 `dirty` 回答。
    static func computeEditSet(rows: [Row],
                               loaded: [Row],
                               removed: [Row],
                               stored: [SpaceRoutingRule],
                               dirty: [UUID: RowDirty]) -> EditSet {
        var storedByStoreId: [String: SpaceRoutingRule] = [:]
        for rule in stored where storedByStoreId[rule.id] == nil { storedByStoreId[rule.id] = rule }

        struct Live {
            var row: Row
            var host: String
            var pathPrefix: String?
            var bucketIndex: Int
        }
        var upserts: [LocalStore.URLRuleDraft] = []
        var deletedIds: Set<String> = []
        var live: [Live] = []
        var bucketCounts: [String: Int] = [:]

        // 第一遍：分「活行」与「清空」。桶内下标只数活行。
        for row in rows {
            let trimmed = row.value.trimmingCharacters(in: .whitespacesAndNewlines)
            var host = ""
            var pathPrefix: String? = nil
            if !trimmed.isEmpty {
                (host, pathPrefix) = row.matchType.encode(value: trimmed)
            }
            if host.isEmpty {
                if let storeId = row.storeId { deletedIds.insert(storeId) }
                continue
            }
            let index = bucketCounts[row.targetSpaceId, default: 0]
            bucketCounts[row.targetSpaceId] = index + 1
            live.append(Live(row: row, host: host, pathPrefix: pathPrefix, bucketIndex: index))
        }
        for row in removed {
            if let storeId = row.storeId { deletedIds.insert(storeId) }
        }

        // 第二遍（M5）：新行 ⇒ 整条 upsert；既有行 ⇒ 脏位 → 恢复支 / 按单元 draft。
        for entry in live {
            let row = entry.row
            guard let storeId = row.storeId else {
                // 裁定 11 前半：本次 sheet 新建的行，**不看脏位**，三个单元全带（插入支的前置
                // 要求是 `content != nil ∧ spaceId != nil`），`syncId` 在插入点铸。
                upserts.append(LocalStore.URLRuleDraft(
                    id: row.id.uuidString,
                    host: entry.host,
                    pathPrefix: entry.pathPrefix,
                    askBeforeRouting: row.askBeforeRouting,
                    spaceId: row.targetSpaceId,
                    sortOrder: entry.bucketIndex,
                    createdDate: row.createdDate))
                continue
            }
            let bits = dirty[row.id] ?? []
            // 零脏位 ⇒ 跳过。**含「`stored` 里已经没有这一行」那一支**（裁定 11 后半）：用户
            // 没碰过的行被别的设备删掉了，本机不复活它，那一行随刷新从 sheet 里消失。
            guard !bits.isEmpty else { continue }
            guard let current = storedByStoreId[storeId] else {
                // **恢复支**（R-M3-4a-101 / 104）：完整 draft、原 `id`、**`syncId = nil`**。
                // 硬删（tombstone）与软删（M2 / (β)）在 `stored`（`allURLRules()`，过滤软删）
                // 这一层长得一样，分流在写事务里（`applyURLRuleEditsBody` 第 2b 步）。
                upserts.append(LocalStore.URLRuleDraft(
                    id: row.id.uuidString,
                    syncId: nil,
                    content: LocalStore.URLRuleDraft.ContentUnit(
                        host: entry.host,
                        pathPrefix: entry.pathPrefix,
                        askBeforeRouting: row.askBeforeRouting),
                    spaceId: row.targetSpaceId,
                    sortOrder: entry.bucketIndex,
                    createdDate: row.createdDate,
                    contentUpdatedDate: nil))
                continue
            }
            // 三组各自：碰过 **∧** 与库里此刻仍不同，才填那一个单元（裁定 12 那张映射表）。
            var content: LocalStore.URLRuleDraft.ContentUnit? = nil
            if !bits.intersection(.content).isEmpty {
                let normalized = LocalStore.normalizedRule(host: entry.host,
                                                           pathPrefix: entry.pathPrefix)
                if current.host != normalized.host
                    || current.pathPrefix != normalized.pathPrefix
                    || current.askBeforeRouting != row.askBeforeRouting {
                    content = LocalStore.URLRuleDraft.ContentUnit(
                        host: entry.host,
                        pathPrefix: entry.pathPrefix,
                        askBeforeRouting: row.askBeforeRouting)
                }
            }
            var spaceId: String? = nil
            if bits.contains(.target), current.spaceId != row.targetSpaceId {
                spaceId = row.targetSpaceId
            }
            var sortOrder: Int? = nil
            if bits.contains(.order), current.sortOrder != entry.bucketIndex {
                sortOrder = entry.bucketIndex
            }
            // 三个都 nil ⇒ 这一行**不进** `upserts`：零写、零盖戳、零置位。
            guard content != nil || spaceId != nil || sortOrder != nil else { continue }
            upserts.append(LocalStore.URLRuleDraft(
                id: row.id.uuidString,
                syncId: row.syncId,
                content: content,
                spaceId: spaceId,
                sortOrder: sortOrder,
                createdDate: nil,
                contentUpdatedDate: nil))
        }

        return EditSet(upserts: upserts, deletedIds: deletedIds)
    }

    // MARK: - Row model

    enum MatchType: String, CaseIterable, Identifiable {
        case domainSuffix    // host + all subdomains ("*.host")
        case domain          // exact host only
        case domainContains  // host contains a substring ("*needle*")
        case url             // exact host + path prefix ("github.com" + "/anthropics")

        var id: String { rawValue }

        var label: String {
            switch self {
            case .domainSuffix:
                return NSLocalizedString("sidebar.urlRulesEditor.matchType.domainSuffix", value: "Domain suffix",
                    comment: "URL rule match type: host plus all subdomains")
            case .domain:
                return NSLocalizedString("sidebar.urlRulesEditor.matchType.domain", value: "Domain",
                    comment: "URL rule match type: exact host only")
            case .domainContains:
                return NSLocalizedString("sidebar.urlRulesEditor.matchType.domainContains", value: "Domain contains",
                    comment: "URL rule match type: host contains a substring")
            case .url:
                return NSLocalizedString("sidebar.urlRulesEditor.matchType.url", value: "URL",
                    comment: "URL rule match type: exact host plus a path prefix")
            }
        }

        var placeholder: String {
            switch self {
            case .domainSuffix:
                return NSLocalizedString("sidebar.urlRulesEditor.matchValue.domainSuffixPlaceholder", value: "example.com",
                    comment: "URL rule value placeholder for Domain suffix match")
            case .domain:
                return NSLocalizedString("sidebar.urlRulesEditor.matchValue.domainPlaceholder", value: "www.example.com",
                    comment: "URL rule value placeholder for Domain match")
            case .domainContains:
                return NSLocalizedString("sidebar.urlRulesEditor.matchValue.domainContainsPlaceholder", value: "example",
                    comment: "URL rule value placeholder for Domain contains match")
            case .url:
                return NSLocalizedString("sidebar.urlRulesEditor.matchValue.urlPlaceholder", value: "https://example.com/path",
                    comment: "URL rule value placeholder for URL (host + path) match")
            }
        }

        /// Translate the editor's (matchType, value) into the persisted
        /// (host, pathPrefix?) pair the C++ matcher expects. The host-only
        /// modes reduce the value to a bare host (a pasted full URL would
        /// otherwise leave the scheme or a "/" inside the stored host and
        /// the rule would silently never match — GURL hosts contain
        /// neither). The `.url` mode instead keeps the path, splitting the
        /// pasted URL into an exact host plus a path prefix.
        ///
        /// The "*" sigils in the stored host are the wire sentinel, not
        /// user input: the mode picker is the single source of truth, so
        /// any typed "*."/"*"s are stripped and `encode` re-adds the form
        /// its own mode requires. An input that reduces to nothing (e.g. a
        /// bare "*.") yields an empty host, which `save()` drops.
        func encode(value: String) -> (host: String, pathPrefix: String?) {
            var work = value
            if let scheme = work.range(of: "://") {
                work = String(work[scheme.upperBound...])
            }
            // The `.url` mode is the only one that keeps the path: split the
            // value at the first "/" into host + path. The path is returned
            // raw — `LocalStore.URLRuleDraft.init` canonicalizes it (leading
            // slash, percent-encoding, trailing-slash collapse).
            if self == .url {
                var hostPart = work
                var pathPart = ""
                if let slash = work.firstIndex(of: "/") {
                    hostPart = String(work[..<slash])
                    pathPart = String(work[slash...])
                }
                let bare = hostPart.hasPrefix("*.") ? String(hostPart.dropFirst(2)) : hostPart
                let host = Self.stripPort(bare)
                return (host, pathPart.isEmpty ? nil : pathPart)
            }
            if let slash = work.firstIndex(of: "/") {
                work = String(work[..<slash])
            }
            work = Self.stripPort(work)
            switch self {
            case .domainSuffix:
                let bare = work.hasPrefix("*.") ? String(work.dropFirst(2)) : work
                return (bare.isEmpty ? "" : "*." + bare, nil)
            case .domain:
                let bare = work.hasPrefix("*.") ? String(work.dropFirst(2)) : work
                return (bare, nil)
            case .domainContains:
                let needle = work.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                return (needle.isEmpty ? "" : "*\(needle)*", nil)
            case .url:
                return (work, nil)  // unreachable — handled above
            }
        }

        /// Drops a pasted port — GURL::host() never carries one, so a
        /// ":8080" baked into the stored host could never match. Only cuts
        /// when everything after the last ":" is digits, which leaves
        /// bracketed IPv6 literals ("[::1]") untouched.
        private static func stripPort(_ host: String) -> String {
            guard let colon = host.lastIndex(of: ":") else { return host }
            let port = host[host.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return host }
            return String(host[..<colon])
        }

        /// Inverse of `encode` — pick the match type for an existing rule.
        /// A non-empty `pathPrefix` means the rule was authored as a `.url`
        /// match, so the host and path are shown joined back together. The
        /// contains form is checked before the suffix form for the same
        /// reason the matchers do: a needle starting with "." (e.g.
        /// "*.git.*") also carries the "*." prefix.
        static func decode(host: String, pathPrefix: String?) -> (MatchType, String) {
            if let path = pathPrefix, !path.isEmpty {
                return (.url, host + path)
            }
            if host.count > 2, host.hasPrefix("*"), host.hasSuffix("*") {
                return (.domainContains, String(host.dropFirst().dropLast()))
            }
            if host.hasPrefix("*.") {
                return (.domainSuffix, String(host.dropFirst(2)))
            }
            return (.domain, host)
        }
    }

    struct Row: Identifiable {
        let id: UUID
        /// The store row this came from (`SpaceURLRule.id`, verbatim). `nil` means the
        /// user added it in this sheet — the two halves of "clearing a rule deletes it"
        /// split on exactly this, and the delete set addresses rows by it: `id` has
        /// already been recast for any non-UUID legacy id (`init(from:)`).
        let storeId: String?
        /// Account-level identity (V11 `SpaceURLRule.syncId`), passed straight into the
        /// draft so a row whose `id` got recast still lands on the same entity.
        var syncId: String?
        var targetSpaceId: String
        var matchType: MatchType
        var value: String
        /// When true, a matching navigation prompts for a Space instead of
        /// routing to `targetSpaceId` automatically.
        var askBeforeRouting: Bool
        var createdDate: Date

        init(defaultSpaceId: String) {
            self.id = UUID()
            self.storeId = nil
            self.syncId = nil
            self.targetSpaceId = defaultSpaceId
            self.matchType = .domainSuffix
            self.value = ""
            self.askBeforeRouting = false
            self.createdDate = Date()
        }

        init(from rule: SpaceRoutingRule) {
            self.id = UUID(uuidString: rule.id) ?? UUID()
            self.storeId = rule.id
            self.syncId = rule.syncId
            self.targetSpaceId = rule.spaceId
            let (matchType, value) = MatchType.decode(
                host: rule.host, pathPrefix: rule.pathPrefix)
            self.matchType = matchType
            self.value = value
            self.askBeforeRouting = rule.askBeforeRouting
            self.createdDate = rule.createdDate
        }
    }
}

// MARK: - AppKit rule list

/// AppKit-backed list of URL rules. SwiftUI's `List` defers an embedded
/// NSTextField's first responder ~2s (the List/NSTableView wrapper runs
/// click-vs-drag disambiguation on mouse-down) and can't reconcile native
/// drag-reorder with instant field focus. A hand-built NSTableView gets all of
/// it natively: click a field → it focuses immediately; drag a row's empty area
/// → native reorder with live row-parting + a drop indicator; click empty →
/// focus resigns. The SwiftUI shell (header / footer / save) is unchanged.
private struct RuleTableView: NSViewRepresentable {
    @Binding var rows: [URLRulesEditor.Row]
    @Binding var removedRows: [URLRulesEditor.Row]
    /// M5（R-M3-4a-72）：五个记脏落点写它，`computeEditSet` 读它。
    @Binding var dirty: [UUID: URLRulesEditor.RowDirty]
    let spaces: [Space]

    /// Captures every Space field shown in the target popup, so a rename / icon
    /// / profile change (same `spaceId`) still triggers a reload — comparing ids
    /// alone would leave the already-built menus in displayed rows stale.
    private var spacesFingerprint: String {
        spaces.map { "\($0.spaceId)\u{1F}\($0.name)\u{1F}\($0.iconName)\u{1F}\($0.profileId)" }
            .joined(separator: "\u{1E}")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let tableView = NSTableView()
        let column = NSTableColumn(identifier: .ruleColumn)
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Coordinator.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.registerForDraggedTypes([.string])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        context.coordinator.tableView = tableView
        context.coordinator.displayedIDs = rows.map(\.id)
        context.coordinator.spacesFingerprint = spacesFingerprint

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let overlay = Self.makeEmptyOverlay()
        overlay.isHidden = !rows.isEmpty
        context.coordinator.emptyOverlay = overlay

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    /// Centered "no rules yet" placeholder shown inside the table host while
    /// there are no rows, so the empty state never swaps the NSView out (which
    /// would fight the delete/insert row animations).
    private static func makeEmptyOverlay() -> NSView {
        let title = NSTextField(labelWithString:
            NSLocalizedString("sidebar.urlRulesEditor.emptyTitle", value: "No rules yet.", comment: "Empty state label in the URL rules editor"))
        title.font = .preferredFont(forTextStyle: .body)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        let hint = NSTextField(labelWithString: NSLocalizedString("sidebar.urlRulesEditor.emptyHint", value: "Pick a target Space and enter a host like \u{201C}github.com\u{201D}.",
            comment: "Empty state hint in the universal URL rules editor"))
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.maximumNumberOfLines = 0
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }
        coordinator.emptyOverlay?.isHidden = !rows.isEmpty

        let oldIDs = coordinator.displayedIDs
        let newIDs = rows.map(\.id)
        let newFingerprint = spacesFingerprint

        if oldIDs == newIDs {
            // No structural change. Content edits, delete and reorder were
            // applied in place by the coordinator; only a Space display change
            // needs a reload here (never mid-edit — the fingerprint is stable
            // while editing, so the field editor is never dropped).
            if coordinator.spacesFingerprint != newFingerprint {
                coordinator.spacesFingerprint = newFingerprint
                tableView.reloadData()
            }
            return
        }

        coordinator.displayedIDs = newIDs
        coordinator.spacesFingerprint = newFingerprint

        // A single blank row appended at the end is the "Add Rule" path: insert
        // incrementally, scroll it into view, and focus its value field. A saved
        // rule always has a non-empty value, so the initial load never matches
        // and won't steal focus. Anything else falls back to a full reload.
        if newIDs.count == oldIDs.count + 1,
           Array(newIDs.prefix(oldIDs.count)) == oldIDs,
           rows[newIDs.count - 1].value.isEmpty {
            let newRow = newIDs.count - 1
            let newID = newIDs[newRow]
            tableView.insertRows(at: IndexSet(integer: newRow), withAnimation: .effectFade)
            tableView.scrollRowToVisible(newRow)
            // Resolve the row by id when the async fires (matching the drag
            // path); the captured index could otherwise be stale if the row set
            // changes before this runs. firstIndex is bounds-safe — a removed
            // row just yields nil and we skip focusing.
            DispatchQueue.main.async { [weak coordinator, weak tableView] in
                guard let coordinator, let tableView,
                      let row = coordinator.displayedIDs.firstIndex(of: newID),
                      let cell = tableView.view(atColumn: 0, row: row,
                                                makeIfNecessary: true) as? RuleCellView
                else { return }
                cell.beginEditingValue()
            }
        } else {
            tableView.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowHeight: CGFloat = 70
        var parent: RuleTableView
        weak var tableView: NSTableView?
        weak var emptyOverlay: NSView?
        var displayedIDs: [UUID] = []
        var spacesFingerprint: String = ""

        init(_ parent: RuleTableView) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: .ruleCell, owner: self) as? RuleCellView
                ?? RuleCellView()
            cell.identifier = .ruleCell
            let id = parent.rows[row].id
            cell.configure(row: parent.rows[row], spaces: parent.spaces,
                           askSpaceTag: URLRulesEditor.askSpaceTag)
            // M5（裁定 12 那张映射表）：记的是「碰过」，比值那一步在 `save()` 里对库里此刻的
            // 行做。`.value` / `.matchType` / `.ask` 三个控件都属于**内容组**这一个合并单元。
            cell.onValueChange = { [weak self] newValue in
                self?.markDirty(id: id, .value)
                self?.mutate(id: id) { $0.value = newValue }
            }
            cell.onMatchTypeChange = { [weak self] newType in
                self?.markDirty(id: id, .matchType)
                self?.mutate(id: id) { $0.matchType = newType }
            }
            cell.onTargetChange = { [weak self] selection in
                // 一个闭包、**两个单元**：`ask` 由 `askSpaceTag` 哨兵承载，没有独立控件。
                // 选中哨兵 ⇒ 只脏 `.ask`（`row.targetSpaceId` 没被动）；选中一个真 Space ⇒
                // 脏 `[.ask, .target]`。
                let bits: URLRulesEditor.RowDirty =
                    selection == URLRulesEditor.askSpaceTag ? [.ask] : [.ask, .target]
                self?.markDirty(id: id, bits)
                self?.mutate(id: id) { row in
                    if selection == URLRulesEditor.askSpaceTag {
                        row.askBeforeRouting = true
                    } else {
                        row.askBeforeRouting = false
                        row.targetSpaceId = selection
                    }
                }
            }
            cell.onDelete = { [weak self] in self?.deleteRow(id: id) }
            return cell
        }

        /// Applies a content edit in place — order/count unchanged, so the
        /// follow-up `updateNSView` is a no-op and the field keeps focus.
        private func mutate(id: UUID, _ change: (inout URLRulesEditor.Row) -> Void) {
            guard let index = parent.rows.firstIndex(where: { $0.id == id }) else { return }
            var updated = parent.rows
            change(&updated[index])
            parent.rows = updated
        }

        /// M5：给一行**并上**几个脏位。只记「碰过」，永远只增不减——脏位在 `load()` 那一刻
        /// 整张清空，别处都不清（裁定 10：刷新永不清脏位）。
        private func markDirty(id: UUID, _ bits: URLRulesEditor.RowDirty) {
            parent.dirty[id, default: []].formUnion(bits)
        }

        private func deleteRow(id: UUID) {
            guard let index = parent.rows.firstIndex(where: { $0.id == id }) else { return }
            var updated = parent.rows
            // 先记下这一行：`computeEditSet` 从 `removed` 里取 `storeId` 进 `deletedIds`。
            // **一个脏位都不记**（裁定 12 / R-M3-4a-69：删除不是编辑）——删除半边排在脏位过滤
            // 之前，而置位会让一条已决定要删的规则对入站 tombstone 让位。
            parent.removedRows.append(updated[index])
            updated.remove(at: index)
            parent.rows = updated
            displayedIDs = updated.map(\.id)
            tableView?.removeRows(at: IndexSet(integer: index), withAnimation: .effectFade)
        }

        // MARK: Native drag-to-reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.rows.indices.contains(row) else { return nil }
            let item = NSPasteboardItem()
            // Serialize stable row identity (UUID), not the index — the index can
            // go stale and an unchecked remove(at:)/insert(at:) would trap.
            item.setString(parent.rows[row].id.uuidString, forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard (info.draggingSource as? NSTableView) === tableView else { return [] }
            // Coerce a drop ONTO a row into an insertion ABOVE it, so the whole
            // row body is a valid reorder target — not just the thin gap between
            // rows. acceptDrop then receives a `.above` row it already handles.
            if dropOperation == .on {
                tableView.setDropRow(row, dropOperation: .above)
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            // Resolve the source by stable id (not the serialized index) and
            // bounds-check both ends, so a stale / out-of-range drop can't trap.
            guard (info.draggingSource as? NSTableView) === tableView,
                  let item = info.draggingPasteboard.pasteboardItems?.first,
                  let idString = item.string(forType: .string),
                  let sourceRow = parent.rows.firstIndex(where: { $0.id.uuidString == idString })
            else { return false }
            let target = max(0, min(row, parent.rows.count))
            let destination = sourceRow < target ? target - 1 : target
            guard destination != sourceRow else { return false }
            var updated = parent.rows
            let moved = updated.remove(at: sourceRow)
            updated.insert(moved, at: destination)
            // M5（裁定 12）：**只给被拖动的那一行**记 `.order`。给整桶记脏的实现会把整桶置位
            // ⇒ 那一轮整桶不静止、整桶对远端删除让位；其余兄弟行的稠密重编号由
            // `applyURLRuleEditsBody` 第 8 步完成，而且**不置位**（CASE U-21）。
            markDirty(id: moved.id, .order)
            parent.rows = updated
            displayedIDs = updated.map(\.id)
            tableView.beginUpdates()
            tableView.moveRow(at: sourceRow, to: destination)
            tableView.endUpdates()
            return true
        }
    }
}

/// One two-line rule row, built from AppKit controls. Exposes per-control
/// change closures that the table coordinator wires to the matching `Row` by
/// id, so reordering never desyncs a control from its rule.
private final class RuleCellView: NSTableCellView, NSTextFieldDelegate {
    var onValueChange: ((String) -> Void)?
    var onMatchTypeChange: ((URLRulesEditor.MatchType) -> Void)?
    var onTargetChange: ((String) -> Void)?
    var onDelete: (() -> Void)?

    private static let matchTypes = URLRulesEditor.MatchType.allCases

    private let matchTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueField = NSTextField()
    private let deleteButton = NSButton()
    private let openInLabel = NSTextField(labelWithString:
        NSLocalizedString("sidebar.urlRulesEditor.targetSpaceLabel", value: "Open in", comment: "Leading label for a URL rule's destination picker"))
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildLayout() {
        matchTypePopup.addItems(withTitles: Self.matchTypes.map(\.label))
        matchTypePopup.target = self
        matchTypePopup.action = #selector(matchTypeChanged)

        valueField.isBezeled = true
        valueField.bezelStyle = .roundedBezel
        valueField.usesSingleLineMode = true
        valueField.lineBreakMode = .byTruncatingTail
        valueField.cell?.isScrollable = true
        valueField.delegate = self

        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription:
            NSLocalizedString("sidebar.urlRulesEditor.removeRuleButton.accessibilityLabel", value: "Remove rule", comment: "Tooltip for remove-rule button"))
        deleteButton.isBordered = false
        deleteButton.contentTintColor = .secondaryLabelColor
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.toolTip = NSLocalizedString("sidebar.urlRulesEditor.removeRuleButton.tooltip", value: "Remove rule", comment: "Tooltip for remove-rule button")

        openInLabel.textColor = .secondaryLabelColor
        openInLabel.font = .preferredFont(forTextStyle: .callout)

        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)

        let line1 = NSStackView(views: [matchTypePopup, valueField, deleteButton])
        line1.orientation = .horizontal
        line1.spacing = 10
        line1.alignment = .centerY
        line1.distribution = .fill

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let line2 = NSStackView(views: [spacer, openInLabel, targetPopup])
        line2.orientation = .horizontal
        line2.spacing = 8
        line2.alignment = .centerY

        let vstack = NSStackView(views: [line1, line2])
        vstack.orientation = .vertical
        vstack.spacing = 8
        vstack.alignment = .leading
        vstack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vstack)

        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            matchTypePopup.widthAnchor.constraint(equalToConstant: 150),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            vstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            vstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            vstack.centerYAnchor.constraint(equalTo: centerYAnchor),
            line1.widthAnchor.constraint(equalTo: vstack.widthAnchor),
            line2.leadingAnchor.constraint(equalTo: vstack.leadingAnchor),
            // Stop the Space popup at the value field's trailing edge (delete
            // button width + spacing), matching the first line's columns.
            line2.trailingAnchor.constraint(equalTo: vstack.trailingAnchor, constant: -32),
        ])
    }

    func configure(row: URLRulesEditor.Row, spaces: [Space], askSpaceTag: String) {
        if let index = Self.matchTypes.firstIndex(of: row.matchType) {
            matchTypePopup.selectItem(at: index)
        }
        valueField.stringValue = row.value
        valueField.placeholderString = row.matchType.placeholder

        let menu = NSMenu()
        for space in spaces {
            if space.spaceId == SpaceManager.kioskRuleTargetId {
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: Self.spaceMenuTitle(space), action: nil, keyEquivalent: "")
            // Render through SpaceIconView so phi-icons / emoji (which
            // `NSImage(systemSymbolName:)` can't resolve) show here too, matching
            // the Spaces switcher menu — not just legacy SF Symbol icons.
            item.image = SpaceIconView.menuImage(for: space.iconName)
            item.representedObject = space.spaceId
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let askItem = NSMenuItem(
            title: NSLocalizedString("sidebar.urlRulesEditor.target.askEveryTimeOption", value: "Ask every time",
                comment: "Special target in the URL rule Space picker: prompt for a Space on each match"),
            action: nil, keyEquivalent: "")
        askItem.representedObject = askSpaceTag
        menu.addItem(askItem)
        targetPopup.menu = menu

        let selectedTag = row.askBeforeRouting ? askSpaceTag : row.targetSpaceId
        if let match = menu.items.first(where: { ($0.representedObject as? String) == selectedTag }) {
            targetPopup.select(match)
        } else if row.askBeforeRouting {
            targetPopup.select(askItem)
        } else {
            /// Auto-route rule whose target Space is not currently resolvable. Show an
            /// explicit disabled "unavailable" item (NOT a false "Ask every time"); the
            /// row is saved back with its target untouched and simply stays out of the
            /// routing payload until that Space comes back.
            let missing = NSMenuItem(
                title: NSLocalizedString("sidebar.urlRulesEditor.target.unavailablePlaceholder", value: "Target Space unavailable",
                    comment: "URL rule target whose Space no longer exists"),
                action: nil, keyEquivalent: "")
            missing.isEnabled = false
            missing.representedObject = row.targetSpaceId
            menu.insertItem(missing, at: 0)
            targetPopup.select(missing)
        }
    }

    @objc private func matchTypeChanged() {
        let type = Self.matchTypes[matchTypePopup.indexOfSelectedItem]
        valueField.placeholderString = type.placeholder
        onMatchTypeChange?(type)
    }

    @objc private func targetChanged() {
        guard let tag = targetPopup.selectedItem?.representedObject as? String else { return }
        onTargetChange?(tag)
    }

    @objc private func deleteClicked() { onDelete?() }

    func controlTextDidChange(_ obj: Notification) { onValueChange?(valueField.stringValue) }

    /// Focuses this row's value field — used to drop the cursor into a freshly
    /// added rule so the user can type immediately.
    func beginEditingValue() {
        window?.makeFirstResponder(valueField)
    }

    /// "Space name — Profile" so each Space entry shows which profile it
    /// routes into. Special destinations use their plain names.
    private static func spaceMenuTitle(_ space: Space) -> String {
        // The generic Incognito target's synthetic profileId is not one of
        // ProfileManager's, and Kiosk has no profile until route time — show
        // their plain names, not raw wire ids.
        guard !SpaceManager.isIncognitoSpaceId(space.spaceId),
              space.spaceId != SpaceManager.kioskRuleTargetId else {
            return space.name
        }
        let profileName = ProfileManager.shared.profile(for: space.profileId)?.displayName ?? space.profileId
        guard !profileName.isEmpty else { return space.name }
        return "\(space.name) \u{2014} \(profileName)"
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let ruleCell = NSUserInterfaceItemIdentifier("PhiURLRuleCell")
    static let ruleColumn = NSUserInterfaceItemIdentifier("PhiURLRuleColumn")
}
