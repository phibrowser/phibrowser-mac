// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation
import SwiftData

extension LocalStore {
    /// Stable id of the implicit "Default" space created on first launch so
    /// existing pinned tabs and bookmarks (where `TabDataModel.spaceId` is
    /// nil) can be attributed to a real Space row at migration time.
    static let defaultSpaceId = "default-space"

    private static let defaultSpaceName = "Default"
    static let defaultSpaceColorHex = "#3A6FF8"
    // Keep the existing view-grid-add artwork while using the semantic asset
    // name written by the current icon chooser.
    private static let defaultSpaceIconName = "phi:phi-icon-view-grid-add"

    @MainActor
    func ensureDefaultSpace(profileId: String) {
        performBackgroundWrite { context in
            do {
                let defaultSpaceId = Self.defaultSpaceId
                let defaultSpaceDescriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.spaceId == defaultSpaceId }
                )
                let defaultSpace: SpaceModel
                if let existing = try context.fetch(defaultSpaceDescriptor).first {
                    defaultSpace = existing
                } else if try context.fetchCount(FetchDescriptor<SpaceModel>()) == 0 {
                    let created = SpaceModel(
                        spaceId: Self.defaultSpaceId,
                        profileId: profileId,
                        name: Self.defaultSpaceName,
                        colorHex: Self.defaultSpaceColorHex,
                        iconName: Self.defaultSpaceIconName,
                        sortOrder: 0
                    )
                    context.insert(created)
                    defaultSpace = created
                } else {
                    // Other Spaces exist but the well-known default row is
                    // gone — the user deleted it and its role moved to
                    // another Space (`SpaceManager.currentDefaultSpaceId`).
                    // Recreating it here would resurrect a deleted Space,
                    // so this is strictly a first-launch (empty store)
                    // bootstrap.
                    return
                }

                // Backlink: legacy installs already have `profile.bookmarkRoot`
                // but the new `space.bookmarkRoot` is nil. Wire them up so
                // existing bookmarks remain reachable through the Space API
                // without any data movement.
                if defaultSpace.bookmarkRoot == nil,
                   let profile = try self.profile(
                       with: defaultSpace.profileId,
                       in: context,
                       createIfNeeded: false
                   ),
                   let profileRoot = profile.bookmarkRoot {
                    defaultSpace.bookmarkRoot = profileRoot
                }
            } catch {
                AppLogError("[LocalStore] ensureDefaultSpace failed: \(error)")
            }
        }
    }

    func createSpace(profileId: String,
                     name: String,
                     colorHex: String,
                     iconName: String,
                     spaceId: String = UUID().uuidString) {
        performBackgroundWrite { context in
            do {
                try self.createSpaceBody(profileId: profileId, name: name, colorHex: colorHex,
                                         iconName: iconName, spaceId: spaceId,
                                         createdDate: nil, in: context)
            } catch {
                AppLogError("[LocalStore] createSpace failed: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer: `PhiSyncEngine` may write
    /// the `reconciled` / `server` baselines only after the row landed, and the
    /// fire-and-forget original swallows its own failure (§5.6).
    func createSpaceThrowing(profileId: String,
                             name: String,
                             colorHex: String,
                             iconName: String,
                             spaceId: String,
                             createdDate: Date?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.createSpaceBody(profileId: profileId, name: name, colorHex: colorHex,
                                     iconName: iconName, spaceId: spaceId,
                                     createdDate: createdDate, in: context)
        }
    }

    /// Single implementation shared by both entry points; the body is the
    /// existing one verbatim, plus the optional `createdDate` the sync layer
    /// needs so `created_at_ms` (merged with `min()`) really reaches the row.
    private func createSpaceBody(profileId: String, name: String, colorHex: String,
                                 iconName: String, spaceId: String,
                                 createdDate: Date?, in context: ModelContext) throws {
        // Spaces from every profile share one strip order.
        let existing = try context.fetch(FetchDescriptor<SpaceModel>())
        let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        let space = SpaceModel(
            spaceId: spaceId,
            profileId: profileId,
            name: name,
            colorHex: colorHex,
            iconName: iconName,
            sortOrder: nextOrder,
            createdDate: createdDate ?? Date()
        )
        context.insert(space)
        // Materialize an empty bookmark root immediately so the first
        // bookmark write in this Space doesn't have to discover it
        // lazily — `bookmarkRoot(profileId:spaceId:)` will simply
        // return what's already linked.
        _ = try self.bookmarkRoot(profileId: profileId,
                                  spaceId: spaceId,
                                  in: context,
                                  createIfNeeded: true)
    }

    func updateSpace(spaceId: String,
                     name: String? = nil,
                     colorHex: String? = nil,
                     iconName: String? = nil) {
        performBackgroundWrite { context in
            do {
                try self.updateSpaceBody(spaceId: spaceId, name: name, colorHex: colorHex,
                                         iconName: iconName, createdDate: nil, in: context)
            } catch {
                AppLogError("[LocalStore] updateSpace failed: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer — see `createSpaceThrowing`.
    func updateSpaceThrowing(spaceId: String, name: String?, colorHex: String?,
                             iconName: String?, createdDate: Date?) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.updateSpaceBody(spaceId: spaceId, name: name, colorHex: colorHex,
                                     iconName: iconName, createdDate: createdDate, in: context)
        }
    }

    /// Single implementation shared by both entry points; the existing body plus
    /// the optional `createdDate` the sync layer needs so a remote
    /// `created_at_ms` (merged with `min()`) really reaches the row.
    private func updateSpaceBody(spaceId: String, name: String?, colorHex: String?,
                                 iconName: String?, createdDate: Date?,
                                 in context: ModelContext) throws {
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId }
        )
        guard let space = try context.fetch(descriptor).first else { return }
        if let name { space.name = name }
        if let colorHex { space.colorHex = colorHex }
        if let iconName { space.iconName = iconName }
        if let createdDate { space.createdDate = createdDate }
        space.updatedDate = Date()
    }

    /// Re-binds a Space to a different profile. More than a field set, which
    /// is why it isn't an `updateSpace` parameter: every bookmark row is
    /// stamped with `(profileId, profile)` and all bookmark fetches filter
    /// on them, so the Space's whole subtree must be re-stamped in the same
    /// write or its bookmarks become unreachable. Space-scoped pinned tabs
    /// are re-stamped as well so they stay with the Space. `sortOrder` is left
    /// untouched — the strip sorts by it first, so keeping the value keeps
    /// the Space's position; any tie with the new profile's existing values
    /// stays deterministic via the `getAllSpaces` tiebreaks.
    /// The default space is excluded: its bookmark root is shared with the
    /// legacy `profile.bookmarkRoot` (see `ensureDefaultSpace`), so migrating
    /// it would mutate the old profile's root.
    func changeSpaceProfile(spaceId: String, toProfileId newProfileId: String) {
        performBackgroundWrite { context in
            do {
                try self.changeSpaceProfileBody(spaceId: spaceId,
                                                toProfileId: newProfileId,
                                                in: context)
            } catch {
                AppLogError("[LocalStore] changeSpaceProfile failed: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer — see `createSpaceThrowing`.
    func changeSpaceProfileThrowing(spaceId: String, toProfileId newProfileId: String) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.changeSpaceProfileBody(spaceId: spaceId,
                                            toProfileId: newProfileId,
                                            in: context)
        }
    }

    /// Single implementation shared by both entry points; the existing body,
    /// unchanged.
    private func changeSpaceProfileBody(spaceId: String, toProfileId newProfileId: String,
                                        in context: ModelContext) throws {
        guard spaceId != Self.defaultSpaceId else { return }
        let descriptor = FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId }
        )
        guard let space = try context.fetch(descriptor).first,
              space.profileId != newProfileId else { return }
        guard let newProfile = try self.profile(with: newProfileId,
                                                in: context,
                                                createIfNeeded: true) else { return }
        // Flat fetch by spaceId rather than a walk from
        // `space.bookmarkRoot`: it also catches orphan roots left by
        // the heal-on-read path in `bookmarkRoot(profileId:spaceId:)`,
        // which would otherwise stay keyed to the old profile and
        // become unreachable.
        let rows = try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.spaceId == spaceId }
        ))
        let bookmarkTypes = [TabDataType.bookmark.rawValue,
                             TabDataType.bookmarkFolder.rawValue]
        let includesPinnedTabs = try self.pinnedTabScope(in: context) == .space
        let pinnedType = TabDataType.pinnedTab.rawValue
        for row in rows where bookmarkTypes.contains(row.type)
            || (includesPinnedTabs && row.type == pinnedType) {
            row.profileId = newProfileId
            row.profile = newProfile
        }
        space.profileId = newProfileId
        space.updatedDate = Date()
    }

    /// Deletes a space row. Tagged pinned tabs / bookmarks are NOT cascade-deleted
    /// here — callers must decide whether to reassign them to another space or
    /// delete them, because the right call depends on the UX flow (e.g. confirm
    /// dialog vs. silent reassign-to-default).
    func deleteSpace(spaceId: String) {
        performBackgroundWrite { context in
            do {
                let descriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )
                for space in try context.fetch(descriptor) {
                    context.delete(space)
                }
            } catch {
                AppLogError("[LocalStore] deleteSpace failed: \(error)")
            }
        }
    }

    /// Cascade helper for `SpaceManager.deleteSpace`. Removes every `TabDataModel`
    /// (pinned tabs and bookmarks, since both share that entity) carrying the
    /// supplied `spaceId`, so the rows don't linger as orphans after the Space
    /// row itself is gone. Kept separate from `deleteSpace` so callers that
    /// want a "reassign to default" UX can opt into it later without paying
    /// for the cascade.
    func deleteTaggedRows(forSpaceId spaceId: String) {
        performBackgroundWrite { context in
            do {
                let descriptor = FetchDescriptor<TabDataModel>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )
                for row in try context.fetch(descriptor) {
                    context.delete(row)
                }
            } catch {
                AppLogError("[LocalStore] deleteTaggedRows failed: \(error)")
            }
        }
    }
}

/// 一次 Space 级联删除的**来源**（R-M3-4a-85）。它只决定规则行那一段：
/// `.userIntent` ⇒ 软删（`deletedDate = now`，这是一次「这条规则要在账户上消失」的
/// 决定）；`.retentionPurge` ⇒ `context.delete`（保留期清理是**跟随**不是决定，
/// R-M3-4a-5，写 `deletedDate` 会让 §5.7 的 `explicitDeletions` 把它当显式意图、
/// 绕过两道归属门、删掉对端此刻仍然有效的规则）。**两个 origin 都不置位
/// `pendingLocalEdit`**（R-M3-4a-69 按入口判，不按共享 body 判）。
/// `TabDataModel` 与 `SpaceModel` 两段在两个 origin 下逐字相同。
enum SpaceCascadeOrigin {
    case userIntent
    case retentionPurge
}

extension LocalStore {
    /// Atomically removes a Space and everything tagged to it — the
    /// `SpaceModel` row, its tagged pinned tabs / bookmarks (`TabDataModel`),
    /// and its URL routing rules (`SpaceURLRule`) — in a single write/save.
    /// `SpaceManager.deleteSpace` uses this instead of issuing the three
    /// deletes as separate transactions: a crash between separate saves would
    /// otherwise leave a content-less ghost Space (or orphaned tagged rows),
    /// and the intermediate saves would briefly publish an inconsistent
    /// strip/bookmark state. `deleteSpace` / `deleteTaggedRows` /
    /// `applyURLRuleEditsThrowing` stay separate for callers that want a
    /// non-cascade or reassign-to-default flow.
    ///
    /// `origin` 无默认值：两个调用方（`SpaceManager.deleteSpace` 与
    /// `PhiSpaceLocalAccess.purge`）必须各自表态（R-M3-4a-85）。
    func deleteSpaceCascade(spaceId: String, origin: SpaceCascadeOrigin) {
        performBackgroundWrite { context in
            do {
                try self.deleteSpaceCascadeBody(spaceId: spaceId, origin: origin, in: context)
            } catch {
                AppLogError("[LocalStore] deleteSpaceCascade failed: \(error)")
            }
        }
    }

    /// Throwing sibling used ONLY by the sync layer — see `createSpaceThrowing`.
    func deleteSpaceCascadeThrowing(spaceId: String, origin: SpaceCascadeOrigin) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.deleteSpaceCascadeBody(spaceId: spaceId, origin: origin, in: context)
        }
    }

    /// Single implementation shared by both entry points. 只有规则那一段按
    /// `origin` 分支；`TabDataModel` 与 `SpaceModel` 两段与从前逐字相同。
    private func deleteSpaceCascadeBody(spaceId: String,
                                        origin: SpaceCascadeOrigin,
                                        in context: ModelContext) throws {
        // 同一次级联里全部规则行共用这一枚 `now`。
        let now = Date()
        for row in try context.fetch(FetchDescriptor<TabDataModel>(
            predicate: #Predicate { $0.spaceId == spaceId }
        )) {
            context.delete(row)
        }
        for rule in try context.fetch(FetchDescriptor<SpaceURLRule>(
            predicate: #Predicate { $0.spaceId == spaceId }
        )) {
            switch origin {
            case .retentionPurge:
                context.delete(rule)
            case .userIntent:
                // 软删（R-M3-4a-41）。已经软删的行跳过，不刷新它的 `deletedDate`；
                // `pendingLocalEdit` 一个字节不碰（删除不是编辑，R-M3-4a-69）。
                if rule.deletedDate == nil {
                    rule.deletedDate = now
                }
            }
        }
        for space in try context.fetch(FetchDescriptor<SpaceModel>(
            predicate: #Predicate { $0.spaceId == spaceId }
        )) {
            context.delete(space)
        }
    }

    /// Persists a new strip ordering. `orderedSpaceIds` is the full list of
    /// space ids (across every profile) in the desired top-to-bottom order;
    /// each gets its list index as `sortOrder`, so the values are globally
    /// unique and the strip sort reproduces the arrangement exactly. Ids
    /// absent from the list keep their existing `sortOrder` and rely on the
    /// `getAllSpaces` tiebreaks.
    func reorderSpaces(orderedSpaceIds: [String]) {
        performBackgroundWrite { context in
            do {
                try self.reorderSpacesBody(orderedSpaceIds: orderedSpaceIds, in: context)
            } catch {
                AppLogError("[LocalStore] reorderSpaces failed: \(error)")
            }
        }
    }

    /// How many Spaces the account holds. Separate from `getAllSpaces` because
    /// callers that only need the size pay for neither the rows nor the three
    /// sort descriptors that make the strip's order deterministic.
    @MainActor
    func spaceCount() -> Int {
        guard let context = mainContext else { return 0 }
        do {
            return try context.fetchCount(FetchDescriptor<SpaceModel>())
        } catch {
            AppLogError("[LocalStore] spaceCount failed: \(error)")
            return 0
        }
    }

    /// Throwing sibling used ONLY by the sync layer — see `createSpaceThrowing`.
    func reorderSpacesThrowing(orderedSpaceIds: [String]) async throws {
        try await performBackgroundWriteAndWaitThrowing { context in
            try self.reorderSpacesBody(orderedSpaceIds: orderedSpaceIds, in: context)
        }
    }

    /// Single implementation shared by both entry points; the existing body,
    /// unchanged.
    private func reorderSpacesBody(orderedSpaceIds: [String], in context: ModelContext) throws {
        let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
        let byId = Dictionary(uniqueKeysWithValues: spaces.map { ($0.spaceId, $0) })
        for (index, spaceId) in orderedSpaceIds.enumerated() {
            byId[spaceId]?.sortOrder = index
        }
    }

    /// Returns Spaces. With `profileId == nil` (the default for the
    /// multi-profile sidebar) every Space is returned regardless of which
    /// profile it's bound to; passing an explicit profileId restricts the
    /// result to that profile (used by callers that genuinely care about a
    /// single profile's scope, e.g. seed-on-first-run checks).
    @MainActor
    func getAllSpaces(profileId: String? = nil) -> [Space] {
        guard let context = mainContext else { return [] }
        do {
            // A manual reorder assigns globally-unique sortOrders and
            // `createSpace` appends with global max+1, but legacy rows
            // (written when create numbered per-profile) and
            // `changeSpaceProfile` — which carries the old value into the
            // new profile — can still tie across (or within) profiles;
            // without stable tiebreaks the strip's interleave would
            // reshuffle between launches. profileId then createdDate makes
            // the combined order deterministic.
            let tiebreaks: [SortDescriptor<SpaceModel>] = [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.profileId),
                SortDescriptor(\.createdDate),
            ]
            let descriptor: FetchDescriptor<SpaceModel>
            if let profileId {
                descriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.profileId == profileId },
                    sortBy: tiebreaks
                )
            } else {
                descriptor = FetchDescriptor<SpaceModel>(
                    sortBy: tiebreaks
                )
            }
            return try context.fetch(descriptor).map { model in
                Space(spaceId: model.spaceId, profileId: model.profileId,
                      name: model.name, colorHex: model.colorHex,
                      iconName: model.iconName, sortOrder: model.sortOrder,
                      createdDate: model.createdDate, updatedDate: model.updatedDate,
                      storeIdentifier: identifier)
            }
        } catch {
            AppLogError("[LocalStore] getAllSpaces failed: \(error)")
            return []
        }
    }

    @MainActor
    func spacesPublisher(profileId: String? = nil) -> AnyPublisher<[Space], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[Space], Never>([])
        let fetch = { self.getAllSpaces(profileId: profileId) }
        subject.send(fetch())

        let cancellable = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave)
            .filter {
                Self.notificationContainsChanges(
                    $0,
                    matching: { $0.entity.name == SpaceModel.entityName }
                )
            }
            .receive(on: DispatchQueue.main)
            .sink { _ in subject.send(fetch()) }

        // Snapshot before downstream consumers reconcile observable objects.
        let snapshots = subject.map { spaces -> (spaces: [Space], ids: [String], content: [Space.Content]) in
            (spaces: spaces, ids: spaces.map(\.spaceId), content: spaces.map(\.content))
        }
        let changes = snapshots.removeDuplicates { lhs, rhs in
            lhs.ids == rhs.ids && lhs.content == rhs.content
        }
        return changes
            .map { $0.spaces }
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .prefix(untilOutputFrom: NotificationCenter.default.publisher(
                for: Self.willCloseNotification, object: self))
            .eraseToAnyPublisher()
    }
}
