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
    private static let defaultSpaceColorHex = "#3A6FF8"
    private static let defaultSpaceIconName = "rectangle.stack"

    @MainActor
    func ensureDefaultSpace(profileId: String) {
        performBackgroundWrite { context in
            do {
                let descriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.profileId == profileId }
                )
                let defaultSpace: SpaceModel
                if let existing = try context.fetch(descriptor).first(where: { $0.spaceId == Self.defaultSpaceId }) {
                    defaultSpace = existing
                } else if try context.fetchCount(descriptor) == 0 {
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
                    // Spaces exist for this profile but none is the default —
                    // don't fabricate one, the data shape is something we
                    // didn't write and we shouldn't paper over it here.
                    return
                }

                // Backlink: legacy installs already have `profile.bookmarkRoot`
                // but the new `space.bookmarkRoot` is nil. Wire them up so
                // existing bookmarks remain reachable through the Space API
                // without any data movement.
                if defaultSpace.bookmarkRoot == nil,
                   let profile = try self.profile(with: profileId, in: context, createIfNeeded: false),
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
                let descriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.profileId == profileId }
                )
                let existing = try context.fetch(descriptor)
                let nextOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
                let space = SpaceModel(
                    spaceId: spaceId,
                    profileId: profileId,
                    name: name,
                    colorHex: colorHex,
                    iconName: iconName,
                    sortOrder: nextOrder
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
            } catch {
                AppLogError("[LocalStore] createSpace failed: \(error)")
            }
        }
    }

    func updateSpace(spaceId: String,
                     name: String? = nil,
                     colorHex: String? = nil,
                     iconName: String? = nil) {
        performBackgroundWrite { context in
            do {
                let descriptor = FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )
                guard let space = try context.fetch(descriptor).first else { return }
                if let name { space.name = name }
                if let colorHex { space.colorHex = colorHex }
                if let iconName { space.iconName = iconName }
                space.updatedDate = Date()
            } catch {
                AppLogError("[LocalStore] updateSpace failed: \(error)")
            }
        }
    }

    /// Re-binds a Space to a different profile. More than a field set, which
    /// is why it isn't an `updateSpace` parameter: every bookmark row is
    /// stamped with `(profileId, profile)` and all bookmark fetches filter
    /// on them, so the Space's whole subtree must be re-stamped in the same
    /// write or its bookmarks become unreachable. `sortOrder` is left
    /// untouched — the strip sorts by it first, so keeping the value keeps
    /// the Space's position; any tie with the new profile's existing values
    /// stays deterministic via the `getAllSpaces` tiebreaks.
    /// The default space is excluded: its bookmark root is shared with the
    /// legacy `profile.bookmarkRoot` (see `ensureDefaultSpace`), so migrating
    /// it would mutate the old profile's root.
    func changeSpaceProfile(spaceId: String, toProfileId newProfileId: String) {
        performBackgroundWrite { context in
            do {
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
                for row in rows where bookmarkTypes.contains(row.type) {
                    row.profileId = newProfileId
                    row.profile = newProfile
                }
                space.profileId = newProfileId
                space.updatedDate = Date()
            } catch {
                AppLogError("[LocalStore] changeSpaceProfile failed: \(error)")
            }
        }
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

    /// Atomically removes a Space and everything tagged to it — the
    /// `SpaceModel` row, its tagged pinned tabs / bookmarks (`TabDataModel`),
    /// and its URL routing rules (`SpaceURLRule`) — in a single write/save.
    /// `SpaceManager.deleteSpace` uses this instead of issuing the three
    /// deletes as separate transactions: a crash between separate saves would
    /// otherwise leave a content-less ghost Space (or orphaned tagged rows),
    /// and the intermediate saves would briefly publish an inconsistent
    /// strip/bookmark state. `deleteSpace` / `deleteTaggedRows` /
    /// `replaceURLRules` stay separate for callers that want a non-cascade or
    /// reassign-to-default flow.
    func deleteSpaceCascade(spaceId: String) {
        performBackgroundWrite { context in
            do {
                for row in try context.fetch(FetchDescriptor<TabDataModel>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )) {
                    context.delete(row)
                }
                for rule in try context.fetch(FetchDescriptor<SpaceURLRule>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )) {
                    context.delete(rule)
                }
                for space in try context.fetch(FetchDescriptor<SpaceModel>(
                    predicate: #Predicate { $0.spaceId == spaceId }
                )) {
                    context.delete(space)
                }
            } catch {
                AppLogError("[LocalStore] deleteSpaceCascade failed: \(error)")
            }
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
                let spaces = try context.fetch(FetchDescriptor<SpaceModel>())
                let byId = Dictionary(uniqueKeysWithValues: spaces.map { ($0.spaceId, $0) })
                for (index, spaceId) in orderedSpaceIds.enumerated() {
                    byId[spaceId]?.sortOrder = index
                }
            } catch {
                AppLogError("[LocalStore] reorderSpaces failed: \(error)")
            }
        }
    }

    /// Returns Spaces. With `profileId == nil` (the default for the
    /// multi-profile sidebar) every Space is returned regardless of which
    /// profile it's bound to; passing an explicit profileId restricts the
    /// result to that profile (used by callers that genuinely care about a
    /// single profile's scope, e.g. seed-on-first-run checks).
    @MainActor
    func getAllSpaces(profileId: String? = nil) -> [SpaceModel] {
        guard let context = mainContext else { return [] }
        do {
            // A manual reorder assigns globally-unique sortOrders, but
            // `createSpace` appends with per-profile max+1 and
            // `changeSpaceProfile` carries the old value into the new
            // profile, so values can tie across (or within) profiles —
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
            return try context.fetch(descriptor)
        } catch {
            AppLogError("[LocalStore] getAllSpaces failed: \(error)")
            return []
        }
    }

    @MainActor
    func spacesPublisher(profileId: String? = nil) -> AnyPublisher<[SpaceModel], Never> {
        guard mainContext != nil else {
            return Just([]).eraseToAnyPublisher()
        }

        let subject = CurrentValueSubject<[SpaceModel], Never>([])
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

        // Dedup on VALUE snapshots taken at emission time — never on the
        // models themselves. `SpaceModel`s are reference types that the
        // context refreshes IN PLACE on save, so the previous emission's
        // array aliases the very objects a new fetch returns: comparing
        // them field-by-field is always trivially equal and every
        // update-only save would be suppressed (inserts/deletes still
        // emitted via the count check, which long masked this).
        return subject
            .map { spaces in (models: spaces, snapshot: spaces.map(SpaceSnapshot.init)) }
            .removeDuplicates { $0.snapshot == $1.snapshot }
            .map(\.models)
            .handleEvents(receiveCancel: { cancellable.cancel() })
            .eraseToAnyPublisher()
    }
}

/// Value copy of the `SpaceModel` fields the spaces publisher dedups on.
/// Captured eagerly per emission so later in-place refreshes of the model
/// objects cannot retroactively equalize past and present.
private struct SpaceSnapshot: Equatable {
    let spaceId: String
    let profileId: String
    let name: String
    let colorHex: String
    let iconName: String
    let sortOrder: Int
    let updatedDate: Date

    init(_ model: SpaceModel) {
        spaceId = model.spaceId
        profileId = model.profileId
        name = model.name
        colorHex = model.colorHex
        iconName = model.iconName
        sortOrder = model.sortOrder
        updatedDate = model.updatedDate
    }
}
