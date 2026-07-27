// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CoreData

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

enum LocalStoreWriteError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .storeUnavailable:
            return NSLocalizedString("localData.pinnedTabScope.unavailableError", value: "Local browser data is unavailable.",
                comment: "Pinned-tab scope migration error when the local store cannot be opened"
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
    let favicon: Data?
}

private struct PinnedTabVariantSignature: Hashable {
    let content: PinnedTabContentSignature
    let splitPartnerLineageId: String?
    let splitPartnerContent: PinnedTabContentSignature?
}

private struct PinnedTabMergeCandidate {
    let source: TabDataModel
    let lineageId: String
    let signature: PinnedTabVariantSignature
    var sourceGuids: [String]
    var lastSeen: Date?
}

extension LocalStore {
    @MainActor
    func pinnedTabScope() -> PinnedTabScope {
        guard let context = mainContext else { return .profile }
        do {
            return try pinnedTabScope(in: context)
        } catch {
            AppLogError("[LocalStore] Failed to read pinned-tab scope: \(error)")
            return .profile
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
    }

    func pinnedTabScope(in context: NSManagedObjectContext) throws -> PinnedTabScope {
        let settings = try browserDataSettings(in: context, createIfNeeded: false)
        return settings.flatMap { PinnedTabScope(rawValue: $0.pinnedTabScopeRawValue) } ?? .profile
    }

    func pinnedTabs(
        profileId: String,
        spaceId: String,
        scope: PinnedTabScope,
        in context: NSManagedObjectContext
    ) throws -> [TabDataModel] {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let sortBy = [
            NSSortDescriptor(key: "index", ascending: true),
            NSSortDescriptor(key: "guid", ascending: true),
        ]
        let predicate: NSPredicate
        switch scope {
        case .space:
            predicate = NSPredicate(
                format: "type == %d AND (profileId == %@ OR profile.profileId == %@) AND spaceId == %@",
                pinnedRaw, profileId, profileId, spaceId
            )
        case .profile:
            predicate = NSPredicate(
                format: "type == %d AND (profileId == %@ OR profile.profileId == %@) AND spaceId == nil",
                pinnedRaw, profileId, profileId
            )
        case .app:
            predicate = NSPredicate(
                format: "type == %d AND profileId == nil AND spaceId == nil",
                pinnedRaw
            )
        }
        return try context.fetch(TabDataModel.request(predicate, sortBy: sortBy))
    }

    func applyCurrentPinnedTabOwner(
        profileId: String,
        spaceId: String,
        to tab: TabDataModel,
        in context: NSManagedObjectContext
    ) throws {
        let owner: PinnedTabOwner
        switch try pinnedTabScope(in: context) {
        case .space:
            owner = PinnedTabOwner(profileId: profileId, spaceId: spaceId)
        case .profile:
            owner = PinnedTabOwner(profileId: profileId, spaceId: nil)
        case .app:
            owner = PinnedTabOwner(profileId: nil, spaceId: nil)
        }
        try applyPinnedTabOwner(owner, to: tab, in: context)
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
        in context: NSManagedObjectContext
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
        let sourceRequest = TabDataModel.request(
            NSPredicate(format: "guid == %@ AND type == %d", guid, pinnedRaw)
        )
        guard let source = try context.fetch(sourceRequest).first,
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

        let allPinned = try context.fetch(TabDataModel.request(
            NSPredicate(format: "type == %d", pinnedRaw)
        ))
        let rowsByGuid = Dictionary(uniqueKeysWithValues: allPinned.map { ($0.guid, $0) })
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
        guard url != nil || title != nil else { return }
        performBackgroundWrite { context in
            do {
                let pinnedRaw = TabDataType.pinnedTab.rawValue
                let request = TabDataModel.request(
                    NSPredicate(format: "guid == %@ AND type == %d", guid, pinnedRaw)
                )
                guard let tab = try context.fetch(request).first,
                      self.pinnedTab(tab, belongsTo: try self.pinnedTabScope(in: context)) else {
                    AppLogWarn("[LocalStore] Rejecting inactive pinned-tab update: \(guid)")
                    return
                }
                if let url {
                    tab.url = url
                    tab.needUpdateMetaData = true
                }
                if let title {
                    tab.title = title
                }
                tab.updatedDate = Date()
            } catch {
                AppLogError("[LocalStore] Failed to update active pinned tab: \(error)")
            }
        }
    }

    func removeActivePinnedTab(guid: String) {
        performBackgroundWrite { context in
            do {
                let pinnedRaw = TabDataType.pinnedTab.rawValue
                let request = TabDataModel.request(
                    NSPredicate(format: "guid == %@ AND type == %d", guid, pinnedRaw)
                )
                guard let tab = try context.fetch(request).first,
                      self.pinnedTab(tab, belongsTo: try self.pinnedTabScope(in: context)) else {
                    AppLogWarn("[LocalStore] Rejecting inactive pinned-tab removal: \(guid)")
                    return
                }
                context.delete(tab)
            } catch {
                AppLogError("[LocalStore] Failed to remove active pinned tab: \(error)")
            }
        }
    }

    private func pinnedTabVariantSignature(
        for tab: TabDataModel,
        rowsByGuid: [String: TabDataModel]
    ) -> PinnedTabVariantSignature {
        let partner = tab.splitPartnerGuid.flatMap { rowsByGuid[$0] }
        return PinnedTabVariantSignature(
            content: contentSignature(for: tab),
            splitPartnerLineageId: partner.map { $0.pinLineageId ?? $0.guid },
            splitPartnerContent: partner.map { contentSignature(for: $0) }
        )
    }

    private func applyPinnedTabOwner(
        _ owner: PinnedTabOwner,
        to tab: TabDataModel,
        in context: NSManagedObjectContext
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
        in context: NSManagedObjectContext,
        createIfNeeded: Bool
    ) throws -> BrowserDataSettingsModel? {
        let request = BrowserDataSettingsModel.request(
            NSPredicate(format: "id == %@", BrowserDataSettingsModel.singletonId)
        )
        if let settings = try context.fetch(request).first {
            return settings
        }
        guard createIfNeeded else { return nil }
        return BrowserDataSettingsModel(insertInto: context)
    }

    private func migratePinnedTabs(
        from sourceScope: PinnedTabScope,
        to targetScope: PinnedTabScope,
        preferredProfileId: String?,
        preferredSpaceId: String?,
        in context: NSManagedObjectContext
    ) throws {
        let pinnedRaw = TabDataType.pinnedTab.rawValue
        let allPinned = try context.fetch(TabDataModel.request(
            NSPredicate(format: "type == %d", pinnedRaw),
            sortBy: [
                NSSortDescriptor(key: "index", ascending: true),
                NSSortDescriptor(key: "guid", ascending: true),
            ]
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
        let lineageByGuid = Dictionary(
            uniqueKeysWithValues: sourceRows.map { ($0.guid, $0.pinLineageId ?? $0.guid) }
        )

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
                try context.fetch(SpaceModel.request()).map(\.profileId)
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
        in context: NSManagedObjectContext
    ) throws -> Set<PinnedTabOwner> {
        switch scope {
        case .app:
            return [PinnedTabOwner(profileId: nil, spaceId: nil)]
        case .profile:
            let profiles = try context.fetch(ProfileModel.request())
            let profileIds = Set(profiles.map(\.profileId))
                .union(sourceRows.compactMap { $0.profileId ?? $0.profile?.profileId })
            return Set(profileIds.map { PinnedTabOwner(profileId: $0, spaceId: nil) })
        case .space:
            let spaces = try context.fetch(SpaceModel.request())
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
                        .map { contentSignature(for: $0) }
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
                    continue
                }

                let candidate = PinnedTabMergeCandidate(
                    source: source,
                    lineageId: lineageId,
                    signature: signature,
                    sourceGuids: [source.guid],
                    lastSeen: source.lastSeen
                )
                candidates.append(candidate)
                candidateIndicesByLineage[lineageId, default: []].append(candidates.count - 1)
            }
        }
        return candidates
    }

    private func contentSignature(for tab: TabDataModel) -> PinnedTabContentSignature {
        PinnedTabContentSignature(
            title: tab.title,
            url: tab.url,
            favicon: tab.favicon
        )
    }

    private func insertPinnedTabs(
        _ candidates: [PinnedTabMergeCandidate],
        for owner: PinnedTabOwner,
        in context: NSManagedObjectContext
    ) throws {
        var targetModels: [TabDataModel] = []
        var candidateIndexBySourceGuid: [String: Int] = [:]

        for (index, candidate) in candidates.enumerated() {
            let source = candidate.source
            let model = TabDataModel(
                insertInto: context,
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
            model.lastSeen = candidate.lastSeen
            model.pinLineageId = candidate.lineageId
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
