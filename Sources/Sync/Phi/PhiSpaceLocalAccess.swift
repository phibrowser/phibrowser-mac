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
    func hide(spaceId: String) async throws
    func unhide(spaceId: String) async throws
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

    /// Only sync-eligible Spaces (§6.5's exclusion list applied AT THE SOURCE,
    /// not as an afterthought filter): incognito, both agent signatures, and any
    /// Space on the agent fallback profile never reach the sync layer at all.
    func currentSpaces() -> [PhiLocalSpace] {
        let pins = account.userDefaults.spaceThemeIds()
        let opacities = account.userDefaults.spaceOverlayOpacities()
        return account.localStorage.getAllSpaces().compactMap { model in
            guard !SpaceManager.isIncognitoSpaceId(model.spaceId) else { return nil }
            guard !AgentSpaceManager.isAgentSpaceModel(name: model.name,
                                                       iconName: model.iconName,
                                                       colorHex: model.colorHex) else { return nil }
            guard !AgentSpaceManager.isPersistentAgentSpaceModel(iconName: model.iconName,
                                                                 colorHex: model.colorHex) else { return nil }
            // The agent fallback profile is structurally never registered, so it
            // never has a mapping; a Space bound to it must not be published.
            guard globalUuid(forProfileId: model.profileId) != nil
                    || model.spaceId == LocalStore.defaultSpaceId else { return nil }
            let entry = opacities[model.spaceId] ?? [:]
            return PhiLocalSpace(
                spaceId: model.spaceId, profileId: model.profileId, name: model.name,
                colorHex: model.colorHex, iconName: model.iconName, sortOrder: model.sortOrder,
                createdDate: model.createdDate, themeId: pins[model.spaceId],
                opacityLight: entry["light"], opacityDark: entry["dark"])
        }
    }

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

    /// Placeholder until Task 5 adds the reverse lookup
    /// (`SyncKeyController.localProfileId(forGlobalUuid:)` over
    /// `ProfileSyncMappingStore.allMappings()`). Returning nil is the safe
    /// direction: §6.2 treats "no local profile for this uuid" as an unmapped
    /// entity, which is retried next round rather than mis-landed.
    func localProfileId(forGlobalUuid uuid: String) -> String? {
        nil
    }

    func isKnownLocalProfile(_ profileId: String) -> Bool {
        ProfileManager.shared.userAssignableProfiles.contains { $0.profileId == profileId }
    }

    /// Placeholder until Task 5 adds `SyncKeyController.removeMapping(forProfileId:)`
    /// (and the `ProfileSyncMappingStore` deletion op behind it). Until then the
    /// §6.2 A0 self-heal simply does not fire; nothing else depends on it.
    func dropMapping(forProfileId profileId: String) {
    }

    func isImporting(intoSpaceId spaceId: String) -> Bool {
        ImportTargetLock.shared.isImporting(into: spaceId)
    }

    func refreshAccountProfiles() async -> ProfileRefreshOutcome {
        // Filled in by Task 11; until then a refresh is a no-op that never
        // blocks a landing.
        .unchanged
    }

    /// Filled in by Task 11 together with `refreshAccountProfiles()`; until the
    /// refresh actually runs, nothing was created, so 0 is the true answer and
    /// §11's `profiles_created` reads 0.
    func profilesCreatedInLastRefresh() -> Int {
        0
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

    func unhide(spaceId: String) async throws {
        SpaceManager.shared.applyRemoteHidden(spaceId: spaceId, hidden: false)
    }

    func purge(spaceId: String) async throws {
        SpaceManager.shared.closeSpaceWindows(spaceId: spaceId)
        try await account.localStorage.deleteSpaceCascadeThrowing(spaceId: spaceId)
        SpaceManager.shared.clearThemeRecords(forSpaceId: spaceId)
    }
}
