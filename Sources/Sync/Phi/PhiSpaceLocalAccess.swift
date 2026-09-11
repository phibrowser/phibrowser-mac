// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Value snapshot of one local Space as the sync layer sees it: the fields the
/// spaces publisher dedups on, with `updatedDate` swapped for `createdDate`
/// (the source of `created_at_ms`; change detection uses the `reconciled`
/// baseline, which is more reliable than a local clock) plus the two per-Space
/// theme plist values.
struct PhiLocalSpace: Equatable {
    var spaceId: String
    var profileId: String
    var name: String
    var colorHex: String
    var iconName: String
    var sortOrder: Int
    var createdDate: Date
    /// nil = no pin, follows the global theme (the wire encoding is "").
    var themeId: String?
    /// nil = no custom opacity, use the theme's own alpha (the wire encoding is -1).
    var opacityLight: Double?
    var opacityDark: Double?
}

/// Result of one account Profile-list refresh (§3.6).
enum ProfileRefreshOutcome: Equatable {
    case unchanged
    case changed
    /// The refresh was declined before it started: the Space gate is shut
    /// (`sync.joinPairingPending`, locked ARK, no account), this round already
    /// refreshed, or the 30 s minimum interval has not elapsed. §11 logs this
    /// as `profile_refresh=skipped` and says in so many words that it is
    /// **not** a failure -- so it must not share `.failed`'s bucket, which
    /// drives the retry ("`.failed` does not arm the interval") and
    /// `ProfilePairingGate`'s hysteresis.
    case skipped
    case failed
}

/// The engine is an `actor`; it hops to the main actor for these exactly the way
/// it already hops for `domainKey()`. Every write is `async throws` on purpose:
/// a non-throwing signature cannot express "the baseline may only be written
/// after the row landed" (§5.6).
@MainActor
protocol PhiSpaceLocalAccess: AnyObject {
    // Reads: pure queries.

    /// The SYNC-ELIGIBLE view (§6.5 applied at the source). Drives `snapshot`
    /// and `land`.
    func currentSpaces() -> [PhiLocalSpace]

    /// The UNFILTERED local strip order (incognito removed, nothing else).
    /// §7's "landing order" projects the synced Spaces back into THEIR OWN
    /// slots, so `plannedOrder` must see the agent Spaces and the Spaces on
    /// unmapped profiles too: `LocalStore.reorderSpaces` assigns `index` as
    /// `sortOrder` to exactly the ids it is handed and documents that "Ids
    /// absent from the list keep their existing `sortOrder`"
    /// (LocalStore+Space.swift:243-261). Feeding it the filtered list would
    /// renumber the synced Spaces 0..n-1 while every excluded Space kept a
    /// stale value, and the two sets would interleave arbitrarily.
    func allSpacesForOrdering() -> [PhiLocalSpace]

    func globalUuid(forProfileId profileId: String) -> String?
    func localProfileId(forGlobalUuid uuid: String) -> String?

    /// Does this device still have that local Chromium profile? §6.2 A0's
    /// dead-mapping criterion, written exactly as §3.6 states it: "反查命中但该
    /// profileId 已不在 `ProfileManager.shared.userAssignableProfiles` 里".
    /// A reverse lookup alone cannot answer it -- `globalUuid(forProfileId:)`
    /// reads back the very mapping the reverse lookup resolved FROM, so it
    /// always says yes.
    func isKnownLocalProfile(_ profileId: String) -> Bool

    /// §3.6's "唯一的例外 / 唯一自愈路径": drop one dead mapping so the next
    /// round's refresh lists that uuid as missing and rebuilds the profile.
    func dropMapping(forProfileId profileId: String)

    // MARK: - Space identity mapping (M3-2b §3.4)
    //
    // 翻译 seam 就在这个协议的**上方**，不在它下方：写方法（`create` / `update` /
    // `rebind` / `applyThemeState` / `applyOrder` / `hide` / `purge`）的参数
    // **一律仍是本地 id**。把任何一个改成收 syncUuid，都是把翻译责任推给
    // `LocalStore`，那正是 §2.4 的不变量禁止的事。

    func syncUuid(forSpaceId spaceId: String) -> String?
    func localSpaceId(forSyncUuid uuid: String) -> String?
    /// 首次 snapshot 前的懒铸造（R-D6-7）。
    func ensureMapped(spaceId: String) throws -> String
    /// 落地一个账户里有、本机没有的 Space 之后回写映射（§3.4）。
    func mapSpace(_ spaceId: String, toSyncUuid uuid: String) throws
    /// 死映射自愈：反查命中、但 `getAllSpaces()` 里已经没有那一行。
    func dropSpaceMapping(forSpaceId spaceId: String)
    /// `getAllSpaces()` 里还有没有这一行。`syncUuid(forSpaceId:)` 回答不了——它读回
    /// 的正是反查解析 FROM 的那张表，永远说有（与 `isKnownLocalProfile` 同款理由）。
    func isKnownLocalSpace(_ spaceId: String) -> Bool
    /// tag 索引的第二个种子（§3.4）：一个刚被向导映射、还没 commit 过的 Space 没有
    /// 游标，而账户里那条实体的 tombstone 随时可能先到。
    func allSpaceMappings() -> [String: String]

    /// 配对向导第 2 步的左列（§5.4）。只应用 §6.5 的**身份类**排除 —— incognito
    /// 与两种 agent 特征 —— 而**不**应用 `currentSpaces()` 的「该 Space 的 profile
    /// 已有映射」判据。含默认 Space。
    ///
    /// 这不是口味问题，是向导能否工作的前提：profile-映射那一条是一条**发布**前置
    /// 条件，而按 R-D6-3，第 1 步的 Profile 决定要到 Finish 才应用——向导开着的时候
    /// 正在被配对的那些 Profile 按定义还没有映射，用 `currentSpaces()` 取左列等于把
    /// 它们下面的 Space 全部藏掉，左列只剩那条只读的默认行。
    func pairableSpaces() -> [PhiLocalSpace]

    func isImporting(intoSpaceId spaceId: String) -> Bool

    /// Account Profile-list refresh + auto-create (§3.6). Called by the engine
    /// once per pull round, after the domain key and before the paging loop.
    func refreshAccountProfiles() async -> ProfileRefreshOutcome

    /// How many local profiles §3.6 created during the MOST RECENT
    /// `refreshAccountProfiles()`. Read only for §11's `profiles_created`
    /// counter, which is why it is a second read rather than a richer return
    /// type: `ensureLocalProfilesForAccount()`'s own signature stays an enum and
    /// every Task 11 assertion against it stays as written.
    func profilesCreatedInLastRefresh() -> Int

    // Writes: one call = one entity landing, and it throws when it did not land.
    func create(_ space: PhiLocalSpace) async throws
    func update(spaceId: String, name: String?, colorHex: String?,
                iconName: String?, createdDate: Date?) async throws
    func rebind(spaceId: String, toProfileId profileId: String) async throws
    func applyThemeState(spaceId: String, themeId: String?,
                         opacityLight: Double?, opacityDark: Double?) async throws
    func applyOrder(_ orderedSpaceIds: [String]) async throws
    /// 远端软删（§9.2）。**单向**：D6 删掉 D2 的「加入账户同步」之后，`unhide` 没有
    /// 任何可能的调用方，一条行一旦 hidden 就只会走 30 天窗口后的清理。
    func hide(spaceId: String) async throws
    func purge(spaceId: String) async throws
}

/// Production wiring over `Account.localStorage` + `Account.userDefaults` +
/// `SpaceManager.shared` + `SyncKeyController`.
@MainActor
final class AccountPhiSpaceAccess: PhiSpaceLocalAccess {
    private let account: Account
    private weak var controller: SyncKeyController?

    init(account: Account, controller: SyncKeyController?) {
        self.account = account
        self.controller = controller
    }

    // MARK: - Reads

    /// §6.5 的排除清单，一份实现两个入口。`requireMappedProfile` 是**发布**前置
    /// 条件（agent fallback profile 结构上永远不会被注册，所以绑在它上面的 Space
    /// 不能发布）；配对向导要看的是**身份**，所以它传 false（§3.4 末）。
    ///
    /// §6.5's exclusion list applied AT THE SOURCE, not as an afterthought
    /// filter: incognito and both agent signatures never reach the sync layer
    /// at all.
    private func localSpaces(requireMappedProfile: Bool) -> [PhiLocalSpace] {
        let pins = account.userDefaults.spaceThemeIds()
        let opacities = account.userDefaults.spaceOverlayOpacities()
        return account.localStorage.getAllSpaces().compactMap { model in
            guard !SpaceManager.isIncognitoSpaceId(model.spaceId) else { return nil }
            guard !AgentSpaceManager.isAgentSpaceModel(name: model.name,
                                                       iconName: model.iconName,
                                                       colorHex: model.colorHex) else { return nil }
            guard !AgentSpaceManager.isPersistentAgentSpaceModel(iconName: model.iconName,
                                                                 colorHex: model.colorHex) else { return nil }
            if requireMappedProfile {
                // The agent fallback profile is structurally never registered, so it
                // never has a mapping; a Space bound to it must not be published.
                guard self.globalUuid(forProfileId: model.profileId) != nil
                        || model.spaceId == LocalStore.defaultSpaceId else { return nil }
            }
            let entry = opacities[model.spaceId] ?? [:]
            return PhiLocalSpace(
                spaceId: model.spaceId, profileId: model.profileId, name: model.name,
                colorHex: model.colorHex, iconName: model.iconName, sortOrder: model.sortOrder,
                createdDate: model.createdDate, themeId: pins[model.spaceId],
                opacityLight: entry["light"], opacityDark: entry["dark"])
        }
    }

    func currentSpaces() -> [PhiLocalSpace] { localSpaces(requireMappedProfile: true) }

    func pairableSpaces() -> [PhiLocalSpace] { localSpaces(requireMappedProfile: false) }

    /// Everything the strip can order: the store's own list minus incognito.
    /// §6.5's exclusions are deliberately NOT applied here -- see the protocol.
    func allSpacesForOrdering() -> [PhiLocalSpace] {
        let pins = account.userDefaults.spaceThemeIds()
        let opacities = account.userDefaults.spaceOverlayOpacities()
        return account.localStorage.getAllSpaces().compactMap { model in
            guard !SpaceManager.isIncognitoSpaceId(model.spaceId) else { return nil }
            let entry = opacities[model.spaceId] ?? [:]
            return PhiLocalSpace(
                spaceId: model.spaceId, profileId: model.profileId, name: model.name,
                colorHex: model.colorHex, iconName: model.iconName, sortOrder: model.sortOrder,
                createdDate: model.createdDate, themeId: pins[model.spaceId],
                opacityLight: entry["light"], opacityDark: entry["dark"])
        }
    }

    func globalUuid(forProfileId profileId: String) -> String? {
        controller?.profileKeys.mappedGlobalUuid(forProfileId: profileId)
    }

    func localProfileId(forGlobalUuid uuid: String) -> String? {
        controller?.localProfileId(forGlobalUuid: uuid)
    }

    func isKnownLocalProfile(_ profileId: String) -> Bool {
        ProfileManager.shared.userAssignableProfiles.contains { $0.profileId == profileId }
    }

    func dropMapping(forProfileId profileId: String) {
        controller?.removeMapping(forProfileId: profileId)
    }

    // MARK: - Space identity mapping

    func syncUuid(forSpaceId spaceId: String) -> String? {
        controller?.syncUuid(forSpaceId: spaceId)
    }

    func localSpaceId(forSyncUuid uuid: String) -> String? {
        controller?.localSpaceId(forSyncUuid: uuid)
    }

    func ensureMapped(spaceId: String) throws -> String {
        guard let controller else { throw SpaceSyncMappingError.mappingLayerUnavailable }
        return try controller.ensureSpaceMapped(spaceId: spaceId)
    }

    func mapSpace(_ spaceId: String, toSyncUuid uuid: String) throws {
        guard let controller else { throw SpaceSyncMappingError.mappingLayerUnavailable }
        try controller.mapSpace(spaceId, toSyncUuid: uuid)
    }

    func dropSpaceMapping(forSpaceId spaceId: String) {
        controller?.removeSpaceMapping(forSpaceId: spaceId)
    }

    func isKnownLocalSpace(_ spaceId: String) -> Bool {
        account.localStorage.getAllSpaces().contains { $0.spaceId == spaceId }
    }

    func allSpaceMappings() -> [String: String] {
        controller?.allSpaceMappings() ?? [:]
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        ImportTargetLock.shared.isImporting(into: spaceId)
    }

    /// A dropped controller means the refresh did not run: `.failed`, so the
    /// engine retries next round instead of arming the 30 s interval on a round
    /// that looked at nothing.
    func refreshAccountProfiles() async -> ProfileRefreshOutcome {
        guard let controller else { return .failed }
        return await controller.ensureLocalProfilesForAccount()
    }

    /// §11's `profiles_created`, read straight after the refresh that produced it.
    func profilesCreatedInLastRefresh() -> Int {
        controller?.lastRefreshCreatedCount ?? 0
    }

    // MARK: - Writes

    func create(_ space: PhiLocalSpace) async throws {
        try await account.localStorage.createSpaceThrowing(
            profileId: space.profileId, name: space.name, colorHex: space.colorHex,
            iconName: space.iconName, spaceId: space.spaceId, createdDate: space.createdDate)
    }

    func update(spaceId: String, name: String?, colorHex: String?,
                iconName: String?, createdDate: Date?) async throws {
        try await account.localStorage.updateSpaceThrowing(
            spaceId: spaceId, name: name, colorHex: colorHex,
            iconName: iconName, createdDate: createdDate)
    }

    func rebind(spaceId: String, toProfileId profileId: String) async throws {
        try await SpaceManager.shared.applyRemoteRebind(spaceId: spaceId, toProfileId: profileId)
    }

    func applyThemeState(spaceId: String, themeId: String?,
                         opacityLight: Double?, opacityDark: Double?) async throws {
        SpaceManager.shared.applyRemoteThemeState(
            spaceId: spaceId, themeId: themeId,
            opacityLight: opacityLight, opacityDark: opacityDark)
    }

    func applyOrder(_ orderedSpaceIds: [String]) async throws {
        try await account.localStorage.reorderSpacesThrowing(orderedSpaceIds: orderedSpaceIds)
    }

    func hide(spaceId: String) async throws {
        SpaceManager.shared.applyRemoteHidden(spaceId: spaceId, hidden: true)
    }

    func purge(spaceId: String) async throws {
        SpaceManager.shared.closeSpaceWindows(spaceId: spaceId)
        try await account.localStorage.deleteSpaceCascadeThrowing(spaceId: spaceId)
        SpaceManager.shared.clearThemeRecords(forSpaceId: spaceId)
    }
}
