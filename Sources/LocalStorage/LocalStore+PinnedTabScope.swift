// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import SwiftData

enum PinnedTabScope: String, CaseIterable, Identifiable {
    case space
    case profile
    case app

    var id: String { rawValue }

    var hierarchyLevel: Int {
        switch self {
        case .space: 0
        case .profile: 1
        case .app: 2
        }
    }
}

enum LocalStoreWriteError: LocalizedError, Equatable {
    case storeUnavailable
    case migrationInFlight
    case folderNotEmpty, rowAlreadyMapped
    case spaceImporting(spaceId: String)
    case rowNotFound, rowIsRoot, invalidURL, targetNotWritable, noCandidateSurvived, rowNotInActiveScope

    var errorDescription: String? {
        switch self {
        case .rowNotFound, .rowIsRoot, .invalidURL, .targetNotWritable, .noCandidateSurvived, .rowNotInActiveScope, .folderNotEmpty, .rowAlreadyMapped, .spaceImporting:
            return nil
        case .storeUnavailable:
            return NSLocalizedString("localData.pinnedTabScope.unavailableError", value: "Local browser data is unavailable.",
                comment: "Pinned-tab scope migration error when the local store cannot be opened"
            )
        case .migrationInFlight:
            return NSLocalizedString("localData.pinnedTabScope.migrationInFlightError", value: "The pinned tab scope can\u{2019}t be changed while a migration from another browser is running. Try again when it has finished.",
                comment: "Pinned-tab scope migration error when a browser migration is in flight"
            )
        }
    }
}

private struct PinnedTabOwner: Hashable {
    let profileId: String?
    let spaceId: String?

    var sortKey: String {
        "\(profileId ?? "")\u{0}\(spaceId ?? "")"
    }
}

private struct PinnedTabContentSignature: Hashable {
    // Only fields that define the user-visible pinned item participate in
    // variant identity. Bookmark provenance/secondary fields are preserved on
    // the selected row but must not create indistinguishable pinned variants.
    let title: String
    let url: URL
}

private struct PinnedTabVariantSignature: Hashable {
    let content: PinnedTabContentSignature
    let splitPartnerLineageId: String?
    let splitPartnerContent: PinnedTabContentSignature?
    let layout: String?
}

private struct PinnedTabMergeCandidate {
    let source: TabDataModel
    let lineageId: String
    let signature: PinnedTabVariantSignature
    var sourceGuids: [String]
    var lastSeen: Date?
    /// Latest content-edit timestamp across merged copies, like `lastSeen`. Copies merge only when content
    /// signatures match, so any copy supplies identical content but their edit times can differ. Taking the
    /// maximum is order-independent and converges; taking only `source` could publish different stamps and
    /// cause repeated overwrites.
    var contentUpdatedDate: Date?
}

extension LocalStore {
    @MainActor
    func pinnedTabScope() -> PinnedTabScope {
        pinnedTabScopeIfReadable() ?? .profile
    }

    /// Read the scope, returning nil on failure instead of presenting `.profile` as a stored value. An
    /// unopened/incompatible store or failed read can safely default UI display to `.profile`, but must not
    /// seed an unpublished account's authoritative mirror with that fallback. Sync writers use this API
    /// (`PinnedTabScopeMirror.reseed`'s `rowValue` contract); `AccountPhiPinnedTabAccess.accountScope()`
    /// applies the same rule to mirror reads.
    @MainActor
    func pinnedTabScopeIfReadable() -> PinnedTabScope? {
        guard let context = mainContext else { return nil }
        do {
            return try pinnedTabScope(in: context)
        } catch {
            AppLogError("[LocalStore] Failed to read pinned-tab scope: \(error)")
            return nil
        }
    }

    /// Changes the store-wide pinned-tab scope and migrates all currently
    /// active collections in the same save. Moving to a narrower scope copies
    /// each parent collection to its existing children. Moving to a broader
    /// scope merges child collections, collapsing unchanged copies by lineage
    /// while preserving divergent variants as separate pinned tabs.
    func changePinnedTabScope(
        to newScope: PinnedTabScope,
        preferredProfileId: String? = nil,
        preferredSpaceId: String? = nil
    ) async throws {
        // A Migration writes its pinned entries to the owners its plan was
        // built for, at the scope that was active when the run started, so
        // moving the scope under a running one strands them at the wrong
        // level. Refused here as well as disabled in Settings: the settings
        // view asks for confirmation before it calls this, and no future
        // caller has to remember the rule.
        if await BrowserDataActivity.migrationRunIsInFlight {
            throw LocalStoreWriteError.migrationInFlight
        }
        try await performBackgroundWriteAndWaitThrowing { context in
            let currentScope = try self.pinnedTabScope(in: context)
            guard currentScope != newScope else { return }

            try self.migratePinnedTabs(
                from: currentScope,
                to: newScope,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId,
                in: context
            )
            let settings = try self.browserDataSettings(in: context, createIfNeeded: true)
            settings?.pinnedTabScopeRawValue = newScope.rawValue
        }
        // Local → mirror (§7.1 step 2), only after the throwing write: if migration fails, neither row nor key
        // may change.
        //
        // Every nonthrowing path writes, including the `currentScope == newScope` no-op, which returns from
        // the closure only. The postcondition is key == row. However, a no-op targeting the current row could
        // erase an already-landed account value awaiting migration (§7.1 step 3, case 2). Both production
        // callers (`applyAccountPinnedTabScope`, `requestPinnedTabScopeChange`) compare the row first; new
        // callers must too.
        //
        // This is the sole intentional write leaving the sidecar behind the key: a real user change or replay
        // should be stamped and published by `SyncableSettings.snapshot`. For remote landing, `apply` already
        // saved the same signature, so rewriting the identical value produces no echo.
        UserDefaults.standard.set(newScope.rawValue, forKey: PinnedTabScopeMirror.key)
    }

    func pinnedTabScope(in context: ModelContext) throws -> PinnedTabScope {
        let settings = try browserDataSettings(in: context, createIfNeeded: false)
        return settings.flatMap { PinnedTabScope(rawValue: $0.pinnedTabScopeRawValue) } ?? .profile
    }

    func pinnedTabs(
        profileId: String,
        spaceId: String,
        scope: PinnedTabScope,
        in context: ModelContext
    ) throws -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sortBy = [SortDescriptor<TabDataModel>(\.index), SortDescriptor(\.guid)]
        let descriptor: FetchDescriptor<TabDataModel>
        switch scope {
        case .space:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == spaceId
                },
                sortBy: sortBy
            )
        case .profile:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    ($0.profileId == profileId || $0.profile?.profileId == profileId) &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        case .app:
            descriptor = FetchDescriptor(
                predicate: #Predicate<TabDataModel> {
                    $0.type == pinnedRaw &&
                    $0.profileId == nil &&
                    $0.spaceId == nil
                },
                sortBy: sortBy
            )
        }
        return try context.fetch(descriptor)
    }

    func applyCurrentPinnedTabOwner(
        profileId: String,
        spaceId: String,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        let owner = Self.pinnedTabOwner(for: try pinnedTabScope(in: context),
                                        profileId: profileId,
                                        spaceId: spaceId)
        try applyPinnedTabOwner(owner, to: tab, in: context)
    }

    /// Owner for a `(profileId, spaceId)` pair at a given scope. Shared with the sync batch to identify the
    /// owner requiring normalization after create; duplicating `applyCurrentPinnedTabOwner`'s switch could
    /// miss an owner and leave duplicate indices.
    fileprivate static func pinnedTabOwner(for scope: PinnedTabScope,
                                           profileId: String,
                                           spaceId: String) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: profileId, spaceId: spaceId)
        case .profile:
            return PinnedTabOwner(profileId: profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    /// Returns whether a pinned row belongs to the store's currently selected
    /// scope. Inactive rows are retained as migration backups, so callers that
    /// mutate by physical guid must reject them rather than reporting success
    /// after changing data that no window can currently see.
    @MainActor
    func isPinnedTabInActiveScope(_ tab: TabDataModel) -> Bool {
        guard tab.dataType == .pinnedTab, let context = mainContext else {
            return false
        }
        do {
            return pinnedTab(tab, belongsTo: try pinnedTabScope(in: context))
        } catch {
            AppLogError("[LocalStore] Failed to validate pinned-tab scope membership: \(error)")
            return false
        }
    }

    @MainActor
    func isPinnedTabInActiveScope(guid: String) -> Bool {
        guard let tab = getTab(by: guid) else { return false }
        return isPinnedTabInActiveScope(tab)
    }

    /// Resolves a physical pinned guid against the collection currently owned
    /// by the requested window. A scope migration retains its source rows as
    /// inactive backups and creates new physical rows, so a UI action queued
    /// during that handoff can still carry the old guid. Resolve that backup
    /// through lineage and the complete persisted variant instead of mutating
    /// the invisible source row or creating a duplicate in the new scope.
    func activePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        in context: ModelContext
    ) throws -> TabDataModel? {
        let scope = try pinnedTabScope(in: context)
        let activeTabs = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        if let exact = activeTabs.first(where: { $0.guid == guid }) {
            return exact
        }

        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sourceDescriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let source = try context.fetch(sourceDescriptor).first,
              !pinnedTab(source, belongsTo: scope) else {
            // A guid owned by another active Space/Profile must never be
            // redirected into this window's collection.
            return nil
        }

        let lineageId = source.pinLineageId ?? source.guid
        let lineageMatches = activeTabs.filter {
            ($0.pinLineageId ?? $0.guid) == lineageId
        }
        guard !lineageMatches.isEmpty else { return nil }

        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw }
        ))
        // Use `uniquingKeysWith`: schema GUIDs are not unique, so duplicate rows would trap
        // `uniqueKeysWithValues` inside a write transaction. Keep the first row, matching
        // `pinnedTabRow(with:in:)`; see `healDuplicatePinnedTabRowsBody`.
        let rowsByGuid = Dictionary(allPinned.map { ($0.guid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        let sourceSignature = pinnedTabVariantSignature(for: source, rowsByGuid: rowsByGuid)
        let exactVariants = lineageMatches.filter {
            pinnedTabVariantSignature(for: $0, rowsByGuid: rowsByGuid) == sourceSignature
        }
        if exactVariants.count == 1 {
            return exactVariants[0]
        }
        return lineageMatches.count == 1 ? lineageMatches[0] : nil
    }

    /// Updates a pinned record in the requested window's active owner. The
    /// owner-aware resolution keeps an edit sheet that straddles a scope
    /// migration from writing into the retained, invisible backup row.
    func updatePinnedTab(
        resolving guid: String,
        profileId: String,
        spaceId: String,
        url: URL,
        title: String?
    ) {
        performBackgroundWrite { context in
            do {
                guard let activeTab = try self.activePinnedTab(
                    resolving: guid,
                    profileId: profileId,
                    spaceId: spaceId,
                    in: context
                ) else {
                    AppLogWarn("[LocalStore] Active pinned tab not found for update: \(guid)")
                    return
                }
                activeTab.url = url
                activeTab.needUpdateMetaData = true
                if let title {
                    activeTab.title = title
                }
                activeTab.updatedDate = Date()
            } catch {
                AppLogError("[LocalStore] Failed to update pinned tab: \(error)")
            }
        }
    }

    /// Executes an Agent/API mutation only while its exact physical guid is
    /// still part of the selected scope. Unlike a window-owned UI action, an
    /// API call has no unambiguous child Space to target after a narrowing
    /// migration, so a stale guid must fail closed instead of touching backup
    /// data or guessing an owner.
    func updateActivePinnedTab(
        guid: String,
        url: URL?,
        title: String?
    ) {
        // Preserve the entry-point no-op before enqueueing: it schedules no write and logs nothing, so this
        // path never reaches the equivalent shared-body guard.
        guard url != nil || title != nil else { return }
        performBackgroundWrite { context in
            do {
                try self.updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to update active pinned tab: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by sync (§4.9). A GUID outside the active scope must fail closed visibly:
    /// the UI's silent return would look like successful landing and save `reconciled` / `server` for a write
    /// that never occurred. The existing row would then be neither deleted by diff nor republished by
    /// snapshot.
    func updateActivePinnedTabThrowing(
        guid: String,
        url: URL?,
        title: String?
    ) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func updateActivePinnedTabBody(
        guid: String,
        url: URL?,
        title: String?,
        in context: ModelContext
    ) throws {
        // Supplying no fields is a caller bug, not a successful no-op.
        guard url != nil || title != nil else {
            throw LocalStoreWriteError.noCandidateSurvived
        }
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        // Keep assignments unconditional: skipping unchanged values would also skip `needUpdateMetaData` and
        // alter UI behavior. `contentDidChange` controls only `contentUpdatedDate`.
        var contentDidChange = false
        if let url {
            if tab.url != url { contentDidChange = true }
            tab.url = url
            tab.needUpdateMetaData = true
        }
        if let title {
            if tab.title != title { contentDidChange = true }
            tab.title = title
        }
        let now = Date()
        // Stamp only actual content changes (§4.9 item 0 / R-M3-3-26), so saving the same title cannot outrank
        // a peer edit. Both local UI edits and remote landing use the same meaning of content-edit time.
        if contentDidChange {
            tab.contentUpdatedDate = now
        }
        tab.updatedDate = now
    }

    func removeActivePinnedTab(guid: String) {
        performBackgroundWrite { context in
            do {
                try self.removeActivePinnedTabBody(guid: guid, in: context)
            } catch {
                AppLogError("[LocalStore] Failed to remove active pinned tab: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by sync (§4.9), for the same reason as `updateActivePinnedTabThrowing`.
    func removeActivePinnedTabThrowing(guid: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.removeActivePinnedTabBody(guid: guid, in: context)
        }
    }

    /// Single implementation shared by both entry points.
    private func removeActivePinnedTabBody(guid: String, in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        guard pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        context.delete(tab)
    }

    private func pinnedTabVariantSignature(
        for tab: TabDataModel,
        rowsByGuid: [String: TabDataModel]
    ) -> PinnedTabVariantSignature {
        let partner = tab.splitPartnerGuid.flatMap { rowsByGuid[$0] }
        return PinnedTabVariantSignature(
            content: contentSignature(for: tab),
            splitPartnerLineageId: partner.map { $0.pinLineageId ?? $0.guid },
            splitPartnerContent: partner.map { contentSignature(for: $0) },
            layout: tab.layout
        )
    }

    private func applyPinnedTabOwner(
        _ owner: PinnedTabOwner,
        to tab: TabDataModel,
        in context: ModelContext
    ) throws {
        tab.profileId = owner.profileId
        tab.spaceId = owner.spaceId
        if let profileId = owner.profileId {
            tab.profile = try profile(with: profileId, in: context, createIfNeeded: true)
        } else {
            tab.profile = nil
        }
    }

    private func browserDataSettings(
        in context: ModelContext,
        createIfNeeded: Bool
    ) throws -> BrowserDataSettingsModel? {
        let singletonId = BrowserDataSettingsModel.singletonId
        let descriptor = FetchDescriptor<BrowserDataSettingsModel>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let settings = try context.fetch(descriptor).first {
            return settings
        }
        guard createIfNeeded else { return nil }
        let settings = BrowserDataSettingsModel()
        context.insert(settings)
        return settings
    }

    private func migratePinnedTabs(
        from sourceScope: PinnedTabScope,
        to targetScope: PinnedTabScope,
        preferredProfileId: String?,
        preferredSpaceId: String?,
        in context: ModelContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let allPinned = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.type == pinnedRaw },
            sortBy: [SortDescriptor(\.index), SortDescriptor(\.guid)]
        ))
        let activeSourceRows = allPinned.filter { pinnedTab($0, belongsTo: sourceScope) }
        // A Profile collection with no Space cannot be represented while Space
        // scope is active. Its rows remain logically live even though their
        // physical owner still has Profile shape, so include them alongside the
        // visible Space collections when leaving Space scope. The persisted bit
        // distinguishes them from ordinary, stale Profile migration backups if
        // Spaces are created, deleted, or re-profiled before the next change.
        let dormantSourceRows = sourceScope == .space
            ? allPinned.filter {
                $0.isPinnedTabDormant && pinnedTab($0, belongsTo: .profile)
            }
            : []
        let sourceRows = activeSourceRows + dormantSourceRows
        let targetRows = allPinned.filter { pinnedTab($0, belongsTo: targetScope) }

        // Old rows for an inactive target scope are backups, not migration
        // input. Rebuild that target from the currently active scope so
        // switching back never resurrects stale edits. Deletion happens after
        // insertion because dormant Profile rows are both logical source rows
        // and physical rows in the Profile-shaped target collection.

        let targetOwners = try pinnedTabTargetOwners(
            for: targetScope,
            sourceRows: sourceRows,
            in: context
        )
        // Keep the first row, as in `activePinnedTab(resolving:…)`: schema GUIDs are not unique, and
        // `uniqueKeysWithValues` would trap mid-migration. Rows sharing a GUID also share lineage by
        // construction, so either gives the same value.
        let lineageByGuid = Dictionary(sourceRows.map { ($0.guid, $0.pinLineageId ?? $0.guid) },
                                       uniquingKeysWith: { first, _ in first })

        for owner in targetOwners.sorted(by: { $0.sortKey < $1.sortKey }) {
            let collections = sourceCollections(
                from: sourceRows,
                sourceScope: sourceScope,
                targetScope: targetScope,
                targetOwner: owner,
                preferredProfileId: preferredProfileId,
                preferredSpaceId: preferredSpaceId
            )
            let candidates = mergeCandidates(
                from: collections,
                lineageByGuid: lineageByGuid
            )
            try insertPinnedTabs(candidates, for: owner, in: context)
        }

        for row in targetRows {
            context.delete(row)
        }

        if sourceScope == .profile, targetScope == .space {
            let profileIdsWithSpaces = Set(
                try context.fetch(FetchDescriptor<SpaceModel>()).map(\.profileId)
            )
            for row in activeSourceRows {
                guard let profileId = row.profileId ?? row.profile?.profileId else {
                    row.isPinnedTabDormant = false
                    continue
                }
                row.isPinnedTabDormant = !profileIdsWithSpaces.contains(profileId)
            }
        } else {
            // Once a dormant collection has been represented in another active
            // scope, its retained physical rows become ordinary backups again.
            for row in dormantSourceRows where !targetRows.contains(where: { $0 === row }) {
                row.isPinnedTabDormant = false
            }
        }
    }

    private func pinnedTab(_ tab: TabDataModel, belongsTo scope: PinnedTabScope) -> Bool {
        switch scope {
        case .space:
            return tab.spaceId != nil
        case .profile:
            return (tab.profileId != nil || tab.profile != nil) && tab.spaceId == nil
        case .app:
            return tab.profileId == nil && tab.spaceId == nil
        }
    }

    private func pinnedTabTargetOwners(
        for scope: PinnedTabScope,
        sourceRows: [TabDataModel],
        in context: ModelContext
    ) throws -> Set<PinnedTabOwner> {
        switch scope {
        case .app:
            return [PinnedTabOwner(profileId: nil, spaceId: nil)]
        case .profile:
            let profiles = try context.fetch(FetchDescriptor<ProfileModel>())
            let profileIds = Set(profiles.map(\.profileId))
                .union(sourceRows.compactMap { $0.profileId ?? $0.profile?.profileId })
            return Set(profileIds.map { PinnedTabOwner(profileId: $0, spaceId: nil) })
        case .space:
            let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
            return Set(spaces.map {
                PinnedTabOwner(profileId: $0.profileId, spaceId: $0.spaceId)
            })
        }
    }

    private func sourceCollections(
        from sourceRows: [TabDataModel],
        sourceScope: PinnedTabScope,
        targetScope: PinnedTabScope,
        targetOwner: PinnedTabOwner,
        preferredProfileId: String?,
        preferredSpaceId: String?
    ) -> [[TabDataModel]] {
        let relevantRows = sourceRows.filter { row in
            switch (sourceScope, targetScope) {
            case (.app, _), (_, .app):
                return true
            case (.profile, .space), (.space, .profile):
                return (row.profileId ?? row.profile?.profileId) == targetOwner.profileId
            default:
                return true
            }
        }
        let grouped = Dictionary(grouping: relevantRows) { row in
            owner(of: row, at: sourceScope)
        }
        let orderedOwners = grouped.keys.sorted { lhs, rhs in
            let lhsPreferred = isPreferred(
                lhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            let rhsPreferred = isPreferred(
                rhs,
                scope: sourceScope,
                profileId: preferredProfileId,
                spaceId: preferredSpaceId
            )
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            return lhs.sortKey < rhs.sortKey
        }
        return orderedOwners.map { owner in
            (grouped[owner] ?? []).sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.guid < $1.guid
            }
        }
    }

    private func owner(of tab: TabDataModel, at scope: PinnedTabScope) -> PinnedTabOwner {
        switch scope {
        case .space:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: tab.spaceId)
        case .profile:
            return PinnedTabOwner(profileId: tab.profileId ?? tab.profile?.profileId, spaceId: nil)
        case .app:
            return PinnedTabOwner(profileId: nil, spaceId: nil)
        }
    }

    private func isPreferred(
        _ owner: PinnedTabOwner,
        scope: PinnedTabScope,
        profileId: String?,
        spaceId: String?
    ) -> Bool {
        switch scope {
        case .space:
            return owner.spaceId == spaceId
        case .profile:
            return owner.profileId == profileId
        case .app:
            return true
        }
    }

    private func mergeCandidates(
        from collections: [[TabDataModel]],
        lineageByGuid: [String: String]
    ) -> [PinnedTabMergeCandidate] {
        var candidates: [PinnedTabMergeCandidate] = []
        var candidateIndicesByLineage: [String: [Int]] = [:]

        for collection in collections {
            for source in collection {
                let lineageId = source.pinLineageId ?? source.guid
                let signature = PinnedTabVariantSignature(
                    content: contentSignature(for: source),
                    splitPartnerLineageId: source.splitPartnerGuid.flatMap { lineageByGuid[$0] },
                    splitPartnerContent: source.splitPartnerGuid
                        .flatMap { partnerGuid in
                            collections.lazy.flatMap { $0 }.first(where: { $0.guid == partnerGuid })
                        }
                        .map { contentSignature(for: $0) },
                    layout: source.layout
                )
                let matchingIndex = candidateIndicesByLineage[lineageId]?.first {
                    candidates[$0].signature == signature
                }
                if let matchingIndex {
                    candidates[matchingIndex].sourceGuids.append(source.guid)
                    if let lastSeen = source.lastSeen,
                       candidates[matchingIndex].lastSeen.map({ lastSeen > $0 }) ?? true {
                        candidates[matchingIndex].lastSeen = lastSeen
                    }
                    if let edited = source.contentUpdatedDate,
                       candidates[matchingIndex].contentUpdatedDate.map({ edited > $0 }) ?? true {
                        candidates[matchingIndex].contentUpdatedDate = edited
                    }
                    continue
                }

                let candidate = PinnedTabMergeCandidate(
                    source: source,
                    lineageId: lineageId,
                    signature: signature,
                    sourceGuids: [source.guid],
                    lastSeen: source.lastSeen,
                    contentUpdatedDate: source.contentUpdatedDate
                )
                candidates.append(candidate)
                candidateIndicesByLineage[lineageId, default: []].append(candidates.count - 1)
            }
        }
        return candidates
    }

    // Merge keys include only syncable fields (R-M3-3-16). Favicon bytes are device-local and independently
    // backfilled under D9/spec §8. Including them could merge a lineage into one pin on one device but two on
    // another after the same account scope change, silently diverging counts. Excluding them makes identical
    // syncable inputs converge; any residual extra entities are a shared union rather than device-specific
    // divergence.
    private func contentSignature(for tab: TabDataModel) -> PinnedTabContentSignature {
        PinnedTabContentSignature(
            title: tab.title,
            url: tab.url
        )
    }

    private func insertPinnedTabs(
        _ candidates: [PinnedTabMergeCandidate],
        for owner: PinnedTabOwner,
        in context: ModelContext
    ) throws {
        var targetModels: [TabDataModel] = []
        var candidateIndexBySourceGuid: [String: Int] = [:]

        for (index, candidate) in candidates.enumerated() {
            let source = candidate.source
            let model = TabDataModel(
                title: source.title,
                guid: UUID().uuidString,
                index: index,
                url: source.url,
                favicon: source.favicon,
                createdDate: source.createdDate,
                updatedDate: source.updatedDate
            )
            model.dataType = .pinnedTab
            model.overrideTitle = source.overrideTitle
            model.isOpenned = false
            model.isCreatedByChromium = source.isCreatedByChromium
            model.needUpdateMetaData = source.needUpdateMetaData
            model.source = source.source
            model.secondaryUrl = source.secondaryUrl
            model.secondaryTitle = source.secondaryTitle
            model.layout = source.layout
            model.lastSeen = candidate.lastSeen
            model.icon = source.icon
            // Carry the content-edit stamp through migration (R-M3-3-26). Otherwise scope changes reset
            // comparison time to `createdDate`, allowing stale remote edits to overwrite every local pin. Use
            // the maximum across candidate copies, not just `source`; see
            // `PinnedTabMergeCandidate.contentUpdatedDate`.
            model.contentUpdatedDate = candidate.contentUpdatedDate
            model.pinLineageId = candidate.lineageId
            // Insert before touching relationships, matching `moveOrCreatePinnedTabBody`.
            // `applyPinnedTabOwner` writes `profile`, whose inverse `ProfileModel.tabs` would otherwise
            // register a blank placeholder with six missing required fields. Every later save then fails
            // validation (NSCocoaErrorDomain 1560) until rollback.
            context.insert(model)
            try applyPinnedTabOwner(owner, to: model, in: context)
            targetModels.append(model)
            for sourceGuid in candidate.sourceGuids {
                candidateIndexBySourceGuid[sourceGuid] = index
            }
        }

        for (index, candidate) in candidates.enumerated() {
            guard let partnerGuid = candidate.source.splitPartnerGuid,
                  let partnerIndex = candidateIndexBySourceGuid[partnerGuid] else {
                targetModels[index].splitPartnerGuid = nil
                continue
            }
            targetModels[index].splitPartnerGuid = targetModels[partnerIndex].guid
        }
    }
}

// MARK: - Sync pin access (§4.8 / §4.9)
//
// Keep this extension in this file: Swift's `private` helpers `pinnedTab(_:belongsTo:)`, `owner(of:at:)` and
// `contentSignature(for:)` are accessible only to extensions in the same file.
extension LocalStore {
    /// The single pin fetch for a sync round supplies both snapshot and diff domains from the same models
    /// (L9). Separate queries introduce an actor-hop race: a user unpin could make the same row live in the
    /// snapshot but absent in diff, both publishing and tombstoning it in one round.
    struct PinSyncFetch {
        /// Non-dormant rows in the current scope, sorted by `(ownerKey, index, guid)`, for `allPins()`.
        let active: [TabDataModel]
        /// Non-dormant rows from the same fetch, without scope filtering, for `allPinRows()` (R-exec-4). Diff
        /// and §9.3 cascade operate per row and derive `(lineage, owner)` via `PinKind.identity(of local:)`
        /// (R-exec-11).
        ///
        /// Scope filtering is deliberately absent: migration keeps source-scope physical rows as backups and
        /// deletes only target-scope rows. Most backups remain non-dormant; not claiming them this round does
        /// not mean the account should delete them. Filtering them would tombstone whole collections on scope
        /// changes.
        ///
        /// Dormancy filtering remains required: dormant rows participate in neither snapshot nor diff. A
        /// lineage with only dormant copies is locally absent and emits a tombstone (spec §12.1, 8b opening
        /// sentence).
        let nonDormant: [TabDataModel]
    }

    /// All non-dormant pin rows without scope filtering, with `profile` prefetched. Share this predicate
    /// between `PinSyncFetch.nonDormant` (diff domain) and `LocalStore.pinnedTabChangesPublisher` (§5.7). Both
    /// ask which pins exist locally; a narrower notification snapshot would permanently suppress some real
    /// changes.
    func nonDormantPinModels(in context: ModelContext) throws -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == pinnedRaw }
        )
        // Owner derivation reads `profile?.profileId`; prefetch avoids a fault for each row.
        descriptor.relationshipKeyPathsForPrefetching = [\.profile]
        return try context.fetch(descriptor).filter { !$0.isPinnedTabDormant }
    }

    /// One fetch with `profile` prefetched and one scope read; all remaining work is in memory.
    func pinSyncFetch(in context: ModelContext) throws -> PinSyncFetch {
        let scope = try pinnedTabScope(in: context)
        let nonDormant = try nonDormantPinModels(in: context)
        let active = nonDormant
            .filter { pinnedTab($0, belongsTo: scope) }
            .sorted { lhs, rhs in
                let lhsOwner = owner(of: lhs, at: scope)
                let rhsOwner = owner(of: rhs, at: scope)
                if lhsOwner.sortKey != rhsOwner.sortKey {
                    return lhsOwner.sortKey < rhsOwner.sortKey
                }
                if lhs.index != rhs.index { return lhs.index < rhs.index }
                return lhs.guid < rhs.guid
            }
        return PinSyncFetch(active: active, nonDormant: nonDormant)
    }

    /// One-time startup repair of existing duplicate pin rows.
    ///
    /// 1. Shared GUIDs: the schema lacks uniqueness, so duplicate creates can persist (Mac B, 2026-09-14
    /// 23:49: `landPins` emitted two creates for one identity with two steps). Repair at the store: sync
    /// delete/move/A11 resolve only the first GUID match, and the sidebar's `guidInLocalDB` dictionary traps
    /// on duplicates.
    /// 2. Exact identity duplicates: identity is `(lineage, owner)` (§7.2). Match A11 collapse rule 1 and
    /// merge only identical variant signatures. Preserve divergent variants; A11 mints new lineages for these
    /// distinct user-visible pins.
    ///
    /// Keep the smallest index, then earliest creation time, then enumeration order within this fetch. Dormant
    /// rows participate only in GUID deduplication; identity collapse must not merge backups with active rows.
    ///
    /// Do not renumber: index gaps are harmless to sorted readers and normalized writers; cross-owner
    /// renumbering would unnecessarily require scope knowledge. R12 logs only two counts, never GUIDs, titles
    /// or URLs.
    func healDuplicatePinnedTabRows() {
        performBackgroundWrite { context in
            do {
                _ = try self.healDuplicatePinnedTabRowsBody(in: context)
            } catch {
                AppLogError("[LocalStore] Pinned-tab duplicate self-heal failed: \(error)")
            }
        }
    }

    /// Transaction body exposed for tests against a store with known contents.
    @discardableResult
    func healDuplicatePinnedTabRowsBody(
        in context: ModelContext
    ) throws -> (sharedGuid: Int, sharedIdentity: Int) {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        var descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate<TabDataModel> { $0.type == pinnedRaw }
        )
        // Owner derivation reads `profile?.profileId`; prefetch avoids a fault for each row.
        descriptor.relationshipKeyPathsForPrefetching = [\.profile]
        let rows = try context.fetch(descriptor)
        guard rows.count > 1 else { return (0, 0) }

        /// Order each group with the survivor first.
        func ordered(_ group: [(offset: Int, row: TabDataModel)])
            -> [(offset: Int, row: TabDataModel)] {
            group.sorted {
                if $0.row.index != $1.row.index { return $0.row.index < $1.row.index }
                if $0.row.createdDate != $1.row.createdDate {
                    return $0.row.createdDate < $1.row.createdDate
                }
                return $0.offset < $1.offset
            }
        }

        // 1. Shared GUIDs. Traverse group keys deterministically for repeatable results on the same rows.
        var byGuid: [String: [(offset: Int, row: TabDataModel)]] = [:]
        for (offset, row) in rows.enumerated() {
            byGuid[row.guid, default: []].append((offset: offset, row: row))
        }
        var sharedGuid = 0
        var survivors: [(offset: Int, row: TabDataModel)] = []
        var doomed: [TabDataModel] = []
        for key in byGuid.keys.sorted() {
            let group = ordered(byGuid[key] ?? [])
            guard let keeper = group.first else { continue }
            survivors.append(keeper)
            guard group.count > 1 else { continue }
            sharedGuid += group.count - 1
            // Keep split-partner backlinks: this GUID still exists and points to the survivor.
            doomed.append(contentsOf: group.dropFirst().map(\.row))
        }

        // 2. Exact identity duplicates among surviving, non-dormant rows only.
        let rowsByGuid = Dictionary(rows.map { ($0.guid, $0) },
                                    uniquingKeysWith: { first, _ in first })
        var byIdentity: [String: [(offset: Int, row: TabDataModel)]] = [:]
        for entry in survivors where !entry.row.isPinnedTabDormant {
            let lineage = (entry.row.pinLineageId ?? entry.row.guid).lowercased()
            let owner = entry.row.spaceId ?? entry.row.profileId ?? "app"
            byIdentity[lineage + "\u{0}" + owner, default: []].append(entry)
        }
        var sharedIdentity = 0
        for key in byIdentity.keys.sorted() {
            let group = ordered(byIdentity[key] ?? [])
            guard group.count > 1, let keeper = group.first else { continue }
            let keeperSignature = pinnedTabVariantSignature(for: keeper.row,
                                                            rowsByGuid: rowsByGuid)
            for entry in group.dropFirst()
            where pinnedTabVariantSignature(for: entry.row, rowsByGuid: rowsByGuid)
                == keeperSignature {
                sharedIdentity += 1
                // This GUID disappears with its row, so first clear partner links that would otherwise dangle
                // from survivors.
                try clearSplitPartnerBackReferenceBody(of: entry.row, in: context)
                doomed.append(entry.row)
            }
        }

        guard !doomed.isEmpty else { return (0, 0) }
        for row in doomed { context.delete(row) }
        AppLogWarn("[LocalStore] pins: startup self-heal collapsed \(sharedGuid) row(s) "
                   + "sharing a guid and \(sharedIdentity) exact duplicate row(s) of one identity")
        return (sharedGuid: sharedGuid, sharedIdentity: sharedIdentity)
    }

    /// Remint `pinLineageId` for variants of one lineage under one owner (§7.2 / A11). Broader-scope migration
    /// can leave active copies with divergent content: they are distinct user-visible pins, not physical
    /// copies of one entity. Without new identities, the second variant cannot sync or be remotely deleted
    /// despite healthy counters.
    ///
    /// This local write belongs in the round's `PinApplyBatch`, in the landing transaction, never the
    /// read-only push pre-pass (W14). No fire-and-forget sibling is needed: UI does not change lineage.
    func relineagePinnedTabThrowing(guid: String, newLineageId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.relineagePinnedTabBody(guid: guid, newLineageId: newLineageId, in: context)
        }
    }

    private func relineagePinnedTabBody(
        guid: String,
        newLineageId: String,
        in context: ModelContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        // Match the grouping domain from `pinSyncFetch(in:).active`: out-of-scope backups and dormant rows do
        // not receive new lineages.
        guard !tab.isPinnedTabDormant,
              pinnedTab(tab, belongsTo: try pinnedTabScope(in: context)) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }
        guard tab.pinLineageId != newLineageId else { return }
        tab.pinLineageId = newLineageId
        // Identity is not content; leave `contentUpdatedDate` unchanged (§4.9 item 0).
        tab.updatedDate = Date()
    }

    /// Throwing sibling used ONLY by sync (§4.9). Additional parameters preserve `lineageId` from the wire and
    /// persist the min-merged `createdDate` (`created_at_ms`). Accept `URL` directly, avoiding entry-point
    /// parsing (§4.9 item 2).
    ///
    /// `source` is `PhiPinTabEntity` field 8 (`TabSource` raw value), merged by preferring nonzero, then the
    /// smaller nonzero value. Without it, landing would write 0 and later erase the peer's import source.
    ///
    /// Likewise, carry `contentUpdatedDate` (R-exec-5, as in bookmark `BulkBookmarkInsert`). Without it,
    /// snapshot fallback to `createdDate` could make a newly landed pin appear more recently edited than its
    /// peer and incorrectly win the next conflict.
    func createPinnedTabThrowing(guid: String,
                                 url: URL,
                                 title: String,
                                 profileId: String,
                                 spaceId: String = LocalStore.defaultSpaceId,
                                 index: Int? = nil,
                                 lineageId: String? = nil,
                                 createdDate: Date? = nil,
                                 source: Int = 0,
                                 contentUpdatedDate: Date? = nil) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.createPinnedTabBody(guid: guid,
                                         url: url,
                                         title: title,
                                         profileId: profileId,
                                         spaceId: spaceId,
                                         index: index,
                                         lineageId: lineageId,
                                         createdDate: createdDate,
                                         source: source,
                                         contentUpdatedDate: contentUpdatedDate,
                                         in: context)
        }
    }

    /// Single implementation shared by both entry points.
    func createPinnedTabBody(guid: String,
                             url: URL,
                             title: String,
                             profileId: String,
                             spaceId: String,
                             index: Int?,
                             lineageId: String?,
                             createdDate: Date?,
                             source: Int,
                             contentUpdatedDate: Date? = nil,
                             in context: ModelContext) throws {
        // GUID is a pin row's physical identity and must not repeat. The schema has no unique constraint; a
        // duplicate create succeeds silently, but move/update/delete resolve only the first match and the
        // sidebar dictionary traps (Mac B, 2026-09-14 23:49, PinnedTabViewController.swift:601).
        //
        // Reject instead of deduplicating: `landPins` already consolidated by identity, so reaching this guard
        // is a caller bug. `rowAlreadyMapped` tells the engine to refuse the entire invalid batch without
        // persisting anything.
        if try pinnedTabRow(with: guid, in: context) != nil {
            AppLogWarn("[LocalStore] Refused a pinned-tab create on an existing guid")
            throw LocalStoreWriteError.rowAlreadyMapped
        }
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let now = Date()
        let model = TabDataModel(
            title: title,
            guid: guid,
            index: 0,
            url: url,
            favicon: nil,
            createdDate: createdDate ?? now,
            updatedDate: now
        )
        model.dataType = .pinnedTab
        model.isCreatedByChromium = false
        model.pinLineageId = lineageId ?? guid
        model.source = source
        // Preserve nil: `PhiLocalPin.contentUpdatedDate` defines it as never edited. Substituting `now` would
        // make every newly created local pin look edited.
        model.contentUpdatedDate = contentUpdatedDate
        // Insert before assigning ownership, as in `insertPinnedTabs`: `applyCurrentPinnedTabOwner` writes
        // `profile`, whose inverse would otherwise register a placeholder with missing required fields.
        context.insert(model)
        do {
            try applyCurrentPinnedTabOwner(
                profileId: profileId,
                spaceId: spaceId,
                to: model,
                in: context
            )
        } catch {
            // Remove the inserted row if ownership assignment fails. Fire-and-forget `createPinnedTab` only
            // logs the error, so `perform` would otherwise save a pin with no profile/profileId/spaceId:
            // invisible locally but permanently published under the app owner. Throwing callers also roll back
            // via `performThrowing`; explicit deletion keeps both paths correct.
            context.delete(model)
            throw error
        }
        let insertIndex = min(max(index ?? activePins.count, 0), activePins.count)
        activePins.insert(model, at: insertIndex)
        for (position, tabModel) in activePins.enumerated() {
            tabModel.index = position
            tabModel.updatedDate = now
        }
    }

    /// Throwing sibling used ONLY by sync (§4.9). The fire-and-forget API extracts four values from an active
    /// `Tab`; sync accepts those values directly.
    ///
    /// Accept `URL?` instead of `String?` and leave parsing on the create branch: moving an existing row must
    /// still succeed when the supplied URL is invalid.
    func moveOrCreatePinnedTabThrowing(guid: String,
                                       lineageId: String?,
                                       title: String,
                                       url: URL?,
                                       after afterGuid: String?,
                                       profileId: String,
                                       spaceId: String = LocalStore.defaultSpaceId,
                                       newGuid: String? = nil) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.moveOrCreatePinnedTabBody(guid: guid,
                                               lineageId: lineageId,
                                               title: title,
                                               url: url,
                                               after: afterGuid,
                                               profileId: profileId,
                                               spaceId: spaceId,
                                               newGuid: newGuid,
                                               in: context)
        }
    }

    /// Single implementation shared by both entry points.
    ///
    /// The three former warning-and-return guards throw so sync cannot record a baseline for an unapplied
    /// write (§4.9 / R-M3-3-14). The fire-and-forget wrapper catches and logs; `performBackgroundWrite` still
    /// saves pre-error changes without rollback, preserving its prior behavior.
    func moveOrCreatePinnedTabBody(guid tabGuid: String,
                                   lineageId tabLineageId: String?,
                                   title tabTitle: String,
                                   url tabURL: URL?,
                                   after afterGuid: String?,
                                   profileId: String,
                                   spaceId: String,
                                   newGuid: String?,
                                   in context: ModelContext) throws {
        let scope = try pinnedTabScope(in: context)
        var activePins = try pinnedTabs(
            profileId: profileId,
            spaceId: spaceId,
            scope: scope,
            in: context
        )
        let resolvedTabGuid = try activePinnedTab(
            resolving: tabGuid,
            profileId: profileId,
            spaceId: spaceId,
            in: context
        )?.guid
        let resolvedAfterGuid: String?
        if let afterGuid {
            guard let activeAfterTab = try activePinnedTab(
                resolving: afterGuid,
                profileId: profileId,
                spaceId: spaceId,
                in: context
            ) else {
                throw LocalStoreWriteError.rowNotFound
            }
            resolvedAfterGuid = activeAfterTab.guid
        } else {
            resolvedAfterGuid = nil
        }

        var tabToMove: TabDataModel
        // Track whether this call created the row. On ownership failure, remove only a new row; deleting an
        // existing row would destroy the user's pin.
        var didCreateRow = false
        let now = Date()
        if let resolvedTabGuid,
           let tabToMoveIndex = activePins.firstIndex(where: { $0.guid == resolvedTabGuid }) {
            tabToMove = activePins.remove(at: tabToMoveIndex)
        } else {
            // A supplied lineage with no active row means another active owner owns this GUID, which
            // `activePinnedTab` rejects (§7.2). Owner changes are an old-tag tombstone plus a new-tag create,
            // not a move.
            guard tabLineageId == nil else {
                throw LocalStoreWriteError.rowNotInActiveScope
            }
            guard let url = tabURL else {
                throw LocalStoreWriteError.invalidURL
            }

            tabToMove = TabDataModel(
                title: tabTitle,
                guid: newGuid ?? UUID().uuidString,
                index: 0,
                url: url,
                favicon: nil,
                createdDate: now,
                updatedDate: now
            )
            tabToMove.dataType = .pinnedTab
            tabToMove.isCreatedByChromium = false
            tabToMove.pinLineageId = tabLineageId ?? tabToMove.guid
            context.insert(tabToMove)
            didCreateRow = true
            AppLogInfo("[LocalStore] Created new pinned tab with guid: \(String(tabGuid.prefix(8)))")
        }

        if tabToMove.pinLineageId == nil {
            tabToMove.pinLineageId = tabToMove.guid
        }
        do {
            try applyCurrentPinnedTabOwner(
                profileId: profileId,
                spaceId: spaceId,
                to: tabToMove,
                in: context
            )
        } catch {
            // Like `createPinnedTabBody`, this has a fire-and-forget caller. Remove only a row created by this
            // call; preserve existing rows on the move path.
            if didCreateRow { context.delete(tabToMove) }
            throw error
        }

        let insertIndex: Int
        if let resolvedAfterGuid {
            guard let afterIndex = activePins.firstIndex(where: { $0.guid == resolvedAfterGuid }) else {
                throw LocalStoreWriteError.rowNotFound
            }
            insertIndex = afterIndex + 1
        } else {
            insertIndex = 0
        }

        activePins.insert(tabToMove, at: insertIndex)

        for (index, tabModel) in activePins.enumerated() {
            tabModel.index = index
            tabModel.updatedDate = now
        }
    }

    /// Throwing sibling used ONLY by sync (§4.9). For a nonempty `split_partner_uuid`, write both
    /// `splitPartnerGuid` directions in one transaction (§7.4). `reconcilePinnedSplitPartners()` scans
    /// active-window `SplitGroup`s, which newly landed split pins do not have.
    func updateTabSplitPartnerThrowing(_ guid: String, partnerGuid: String?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateTabSplitPartnerBody(guid, partnerGuid: partnerGuid, in: context)
        }
    }

    /// Single implementation shared by both entry points. An already-equal value is success and may advance
    /// the baseline; a missing row is failure.
    ///
    /// Resolve only pin rows (M5). Ordinary tabs may share the GUID space; matching any `TabDataModel` could
    /// rewrite a normal tab's split partner and introduce it into a pin snapshot. Existing UI callers already
    /// obtain GUIDs from `pinnedTabs`, preserving their behavior (BrowserState+Split.swift:309-310, 852-853,
    /// 900-904; BrowserState.swift:3217, 5906-5907).
    func updateTabSplitPartnerBody(_ guid: String,
                                   partnerGuid: String?,
                                   in context: ModelContext) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let predicate = #Predicate<TabDataModel> { $0.guid == guid && $0.type == pinnedRaw }
        let descriptor = FetchDescriptor<TabDataModel>(predicate: predicate)
        guard let tab = try context.fetch(descriptor).first else {
            throw LocalStoreWriteError.rowNotFound
        }
        let layoutAlreadyCleared = partnerGuid != nil || tab.layout == nil
        guard tab.splitPartnerGuid != partnerGuid || !layoutAlreadyCleared else { return }
        tab.splitPartnerGuid = partnerGuid
        if partnerGuid == nil { tab.layout = nil }
        tab.updatedDate = Date()
    }

    // MARK: - Remote landing batch entry (pin counterpart of R-exec-2)

    /// Apply all pin operations from one remote round in one write block and transaction. `PinApplyBatch`
    /// orders create/relineage/move → update → delete; never reorder here.
    ///
    /// Do not compose throwing helpers (R-exec-2): each starts its own serialized write, creating partial
    /// success across N transactions; nesting them deadlocks. Keep this entry in the same file as the private
    /// shared bodies.
    ///
    /// Recheck import locks inside the transaction (§4.9 item 3), covering imports started after the
    /// round-start read. Throw `spaceImporting` to roll back and retry the entire batch. Finally normalize
    /// each touched owner once: pins group by owner, not parent, and per-operation dense ordering alone cannot
    /// ensure the final result.
    func applyPinSyncBatchThrowing(_ ops: [PinApplyOp]) async throws {
        guard !ops.isEmpty else { return }
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.applyPinSyncBatchBody(ops, in: context)
        }
    }

    /// Transaction body, extracted solely for readability; it has one caller.
    private func applyPinSyncBatchBody(_ ops: [PinApplyOp], in context: ModelContext) throws {
        try refuseIfImportingPins(ops, in: context)

        let scope = try pinnedTabScope(in: context)
        // Record owner values for final normalization, not models: reading a deleted row's properties later in
        // the batch is undefined.
        var touchedOwners = Set<PinnedTabOwner>()

        for op in ops {
            switch op {
            case .create(let row):
                // Explicitly pass all four values (§4.9 / R-exec-5). A nil `lineageId` would mint a new
                // identity and republish the landed pin as a duplicate. Defaults for `source`, `createdDate`
                // or `contentUpdatedDate` would erase remote values; losing the edit stamp also resets
                // comparison time to landing time.
                let profileId = row.profileId ?? Self.defaultProfileId
                let spaceId = row.spaceId ?? Self.defaultSpaceId
                try createPinnedTabBody(guid: row.guid,
                                        url: row.url,
                                        title: row.title,
                                        profileId: profileId,
                                        spaceId: spaceId,
                                        index: row.index,
                                        lineageId: row.lineageId,
                                        createdDate: row.createdDate,
                                        source: row.source,
                                        contentUpdatedDate: row.contentUpdatedDate,
                                        in: context)
                touchedOwners.insert(Self.pinnedTabOwner(for: scope,
                                                         profileId: profileId,
                                                         spaceId: spaceId))

            case .relineage(let guid, let newLineageId):
                // Identity is not position: reminting leaves index unchanged and does not add to
                // `touchedOwners`.
                try relineagePinnedTabBody(guid: guid,
                                           newLineageId: newLineageId,
                                           in: context)

            case .move(let guid, let index):
                guard let tab = try pinnedTabRow(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                guard pinnedTab(tab, belongsTo: scope) else {
                    throw LocalStoreWriteError.rowNotInActiveScope
                }
                // An equal value is success and needs no `updatedDate` stamp. Never change
                // `contentUpdatedDate` for position (§4.9 item 0).
                if tab.index != index {
                    tab.index = index
                    tab.updatedDate = Date()
                }
                touchedOwners.insert(owner(of: tab, at: scope))

            case .update(let guid, let fields):
                // Outer optional selects whether to change; inner optional selects the value. A nil inner
                // title clears it; a nil inner URL leaves it unchanged, since pins cannot lose their URL.
                let title = fields.title.map { $0 ?? "" }
                let url = fields.url.flatMap { $0 }
                let changesSplitPartner = fields.splitPartnerLineageId != nil
                // A patch with no effective change is a caller bug (M4). Check the three resolved values, not
                // outer optionals: a present URL unit with nil inside means unchanged too. The §4.9 baseline
                // guarantee requires nonthrowing completion to mean actual landing.
                guard title != nil || url != nil || changesSplitPartner else {
                    throw LocalStoreWriteError.noCandidateSurvived
                }
                if title != nil || url != nil {
                    // Call only if title or URL is supplied: the shared body throws `noCandidateSurvived`
                    // otherwise, but a split-partner-only patch is valid here.
                    try updateActivePinnedTabBody(guid: guid, url: url, title: title, in: context)
                }
                if let partnerLineageId = fields.splitPartnerLineageId {
                    try applyPinSplitPartnerBody(guid: guid,
                                                 partnerLineageId: partnerLineageId,
                                                 in: context)
                }

            case .delete(let guid):
                guard let tab = try pinnedTabRow(with: guid, in: context) else {
                    throw LocalStoreWriteError.rowNotFound
                }
                // Capture ownership before deletion; reading a deleted model is undefined.
                touchedOwners.insert(owner(of: tab, at: scope))
                // Clear the other half's backlink in the same transaction (M6). UI deletes split pins
                // together, but §7.2 sync may remove one half after remote unpinning. A dangling GUID would
                // confuse variant signatures, scope migration and the merged UI cell.
                try clearSplitPartnerBackReferenceBody(of: tab, in: context)
                try removeActivePinnedTabBody(guid: guid, in: context)
            }
        }

        // Normalize once per owner (§4.10). Explicitly exclude `isDeleted` rows, as for bookmarks:
        // pending-change fetch filtering was not runtime-tested in this milestone, and numbering a deleted row
        // would leave an index gap.
        for touched in touchedOwners.sorted(by: { $0.sortKey < $1.sortKey }) {
            let rows = try pinnedTabs(profileId: touched.profileId ?? Self.defaultProfileId,
                                      spaceId: touched.spaceId ?? Self.defaultSpaceId,
                                      scope: scope,
                                      in: context)
                .filter { !$0.isDeleted }
            Self.normalizePinnedIndexes(for: rows)
        }
    }

    /// Dense renumbering, equivalent to bookmark `normalizeIndexes(for:)`, whose private extension is
    /// inaccessible here. Write only changed indices: unconditional assignments would stamp the entire
    /// collection's `updatedDate` instead of only moved rows.
    private static func normalizePinnedIndexes(for rows: [TabDataModel]) {
        for (position, row) in rows.enumerated() where row.index != position {
            row.index = position
            row.updatedDate = Date()
        }
    }

    /// Refuse the entire batch if any touched Space is importing (§4.9 item 3). Resolve Spaces for all four
    /// GUID-addressed operations inside the transaction, not from a potentially stale round-start snapshot.
    /// Profile/App pins have no Space and correctly bypass this Space-scoped `ImportTargetLock`.
    private func refuseIfImportingPins(_ ops: [PinApplyOp], in context: ModelContext) throws {
        var spaceIds = Set<String>()
        for op in ops {
            switch op {
            case .create(let row):
                if let spaceId = row.spaceId { spaceIds.insert(spaceId) }
            case .relineage(let guid, _), .move(let guid, _),
                 .update(let guid, _), .delete(let guid):
                if let spaceId = try pinnedTabRow(with: guid, in: context)?.spaceId {
                    spaceIds.insert(spaceId)
                }
            }
        }
        for spaceId in spaceIds.sorted() where ImportTargetLock.shared.isImporting(into: spaceId) {
            // Importing is transient, unlike `targetNotWritable`: park and retry instead of treating it as
            // structural failure. Sort to report a deterministic Space when several imports are active.
            throw LocalStoreWriteError.spaceImporting(spaceId: spaceId)
        }
    }

    /// Land `split_partner_uuid`, writing both directions in one transaction when resolvable (§7.4 / I11).
    ///
    /// An unresolved partner is not failure (§7.4 landing rule 3): leave the local link nil and let the engine
    /// record `pendingPartnerLineage`, then repair both directions when the partner lands. Throwing would roll
    /// back every pin operation for this normal half-arrived state and block progress indefinitely.
    ///
    /// Treat a partner under another owner as unresolved too. Split pairs must share an owner (§7.4); §4.6
    /// rejects/parks malformed payloads, and cross-owner matching could join pins in unrelated Spaces.
    /// `reconcilePinnedSplitPartners()` cannot help because landed pins have no active-window `SplitGroup`.
    private func applyPinSplitPartnerBody(guid: String,
                                          partnerLineageId: String?,
                                          in context: ModelContext) throws {
        guard let tab = try pinnedTabRow(with: guid, in: context) else {
            throw LocalStoreWriteError.rowNotFound
        }
        let scope = try pinnedTabScope(in: context)
        guard pinnedTab(tab, belongsTo: scope) else {
            throw LocalStoreWriteError.rowNotInActiveScope
        }

        var resolvedPartnerGuid: String?
        if let partnerLineageId {
            let wanted = PinKind.lineageKey(partnerLineageId)
            let siblings = try pinnedTabs(
                profileId: tab.profileId ?? tab.profile?.profileId ?? Self.defaultProfileId,
                spaceId: tab.spaceId ?? Self.defaultSpaceId,
                scope: scope,
                in: context
            )
            // Normalize through `lineageKey`: local values may be uppercase UUIDs or legacy GUID fallbacks,
            // while wire lineages are lowercase. Direct comparison would leave split pins waiting forever.
            resolvedPartnerGuid = siblings.first {
                $0.guid != guid && PinKind.lineageKey($0.pinLineageId ?? $0.guid) == wanted
            }?.guid
        }

        // Clear the old partner's backlink only if it actually points to this row, preserving unrelated split
        // pairs after reassignment.
        if let previous = tab.splitPartnerGuid,
           previous != resolvedPartnerGuid,
           let previousRow = try pinnedTabRow(with: previous, in: context),
           previousRow.splitPartnerGuid == guid {
            try updateTabSplitPartnerBody(previous, partnerGuid: nil, in: context)
        }
        try updateTabSplitPartnerBody(guid, partnerGuid: resolvedPartnerGuid, in: context)
        if let resolvedPartnerGuid {
            try updateTabSplitPartnerBody(resolvedPartnerGuid, partnerGuid: guid, in: context)
        }
    }

    /// Clear the link pointing back to this row in the same transaction before split-pin deletion. Write only
    /// if the partner still references this row; a stale one-way link must not break the partner's new pair.
    private func clearSplitPartnerBackReferenceBody(of tab: TabDataModel,
                                                    in context: ModelContext) throws {
        guard let partnerGuid = tab.splitPartnerGuid, partnerGuid != tab.guid,
              let partner = try pinnedTabRow(with: partnerGuid, in: context),
              partner.splitPartnerGuid == tab.guid else {
            return
        }
        try updateTabSplitPartnerBody(partnerGuid, partnerGuid: nil, in: context)
    }

    /// Resolve only a pin row by GUID. Ordinary tabs may share GUID space; matching any `TabDataModel` as
    /// `bookmarkNode(with:)` does could rewrite a tab and introduce it into the next pin snapshot.
    private func pinnedTabRow(with guid: String,
                              in context: ModelContext) throws -> TabDataModel? {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let descriptor = FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.guid == guid && $0.type == pinnedRaw }
        )
        return try context.fetch(descriptor).first
    }
}
