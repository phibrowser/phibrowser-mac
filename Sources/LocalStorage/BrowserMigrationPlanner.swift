// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - Migration Source model

/// Why a Migration Source could not read one profile's pinned entries. The
/// plan carries it through so the preview and the report can say *why* a
/// Profile has no pinned tabs rather than implying the user had none.
enum BrowserMigrationPinsUnavailableReason: String, Equatable {
    /// The source application could not be opened.
    case sourceCouldNotBeOpened
    /// The source is running but has no window, so its profiles — and with
    /// them its tabs — are not reachable.
    case noSourceWindow
    /// macOS refused Phi permission to read from the source.
    case permissionRefused
    /// The installed source version exposes no readable scripting interface.
    case sourceNotScriptable
}

/// One top-level pinned entry of a source profile: an Arc Favorite, a Dia
/// pinned tab, a Zen Essential.
struct BrowserMigrationPinnedEntry: Equatable {
    let title: String
    let url: String
}

/// One source profile's top-level pinned entries, in source order. Like a
/// Space, it names its profile by directory basename, and nil when the
/// source's profile record for it is unreadable.
struct BrowserMigrationSourcePinnedGroup {
    let profileKey: String?
    let entries: [BrowserMigrationPinnedEntry]
}

/// A Migration Source's profile, keyed by the on-disk directory basename the
/// Chromium-side importer needs.
struct BrowserMigrationSourceProfile {
    let key: String
    let displayName: String
    /// Non-nil when the source has pinned entries but could not read them;
    /// distinct from an empty pinned group, which means the user had none.
    let pinsUnavailable: BrowserMigrationPinsUnavailableReason?

    init(
        key: String,
        displayName: String,
        pinsUnavailable: BrowserMigrationPinsUnavailableReason? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.pinsUnavailable = pinsUnavailable
    }
}

/// One Space of a Migration Source. A space-less source (Dia) synthesises one
/// per profile before it gets here, so the planner has no source-specific arm.
struct BrowserMigrationSourceSpace {
    let id: String
    /// Already carries the source parser's placeholder when the Space is
    /// untitled; the planner adds no fallback of its own.
    let name: String
    /// Already derived from the source Space's theme, with the default
    /// new-Space colour standing in when it has none.
    let colorHex: String
    /// nil when the source's profile record for this Space is unreadable.
    let profileKey: String?
    /// The Space's own bookmark tree, parsed Mac-side; nil for a source whose
    /// bookmarks arrive Chromium-side. This is the tree node type every
    /// Mac-side sidebar parser already produces and the store's Arc landing
    /// call already takes, so the plan carries it rather than a copy of it.
    let bookmarkRoot: ArcDataParserTool.Bookmark?

    init(
        id: String,
        name: String,
        colorHex: String,
        profileKey: String?,
        bookmarkRoot: ArcDataParserTool.Bookmark? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.profileKey = profileKey
        self.bookmarkRoot = bookmarkRoot
    }
}

/// Everything a Migration Source supplies. Sources differ only in how this is
/// built: a source lacking one part supplies its empty or degenerate form
/// rather than a shape of its own.
struct BrowserMigrationSource {
    /// The profiles the source's own profile cache lists, in its order. A
    /// Space or a pinned group may name a profile the cache left out; the
    /// planner creates one for it rather than dropping what named it.
    let profiles: [BrowserMigrationSourceProfile]
    /// The directory basename of the source's default profile. A Space or
    /// pinned group whose own profile record is unreadable belongs to it.
    let defaultProfileKey: String
    /// Every Space of the source, in the source's own order.
    let spaces: [BrowserMigrationSourceSpace]
    /// Each profile's top-level pinned entries, in source order.
    let pinnedGroups: [BrowserMigrationSourcePinnedGroup]

    init(
        profiles: [BrowserMigrationSourceProfile],
        defaultProfileKey: String,
        spaces: [BrowserMigrationSourceSpace],
        pinnedGroups: [BrowserMigrationSourcePinnedGroup] = []
    ) {
        self.profiles = profiles
        self.defaultProfileKey = defaultProfileKey
        self.spaces = spaces
        self.pinnedGroups = pinnedGroups
    }
}

extension BrowserMigrationSource {
    /// True when the source could not read this Space's own profile record, so
    /// it belongs to the default profile and the preview says so.
    func bindsToDefaultProfile(_ space: BrowserMigrationSourceSpace) -> Bool {
        space.profileKey == nil
    }

    /// The profile a Space belongs to — a malformed profile record costs a
    /// label, not a Space.
    func resolvedProfileKey(for space: BrowserMigrationSourceSpace) -> String {
        space.profileKey ?? defaultProfileKey
    }

    /// The same rule for a group of pinned entries.
    func resolvedProfileKey(for group: BrowserMigrationSourcePinnedGroup) -> String {
        group.profileKey ?? defaultProfileKey
    }

    /// This profile's Spaces, in source order.
    func spaces(ofProfile key: String) -> [BrowserMigrationSourceSpace] {
        spaces.filter { resolvedProfileKey(for: $0) == key }
    }

    /// This profile's pinned entries, in source order.
    func pinnedEntries(ofProfile key: String) -> [BrowserMigrationPinnedEntry] {
        pinnedGroups.filter { resolvedProfileKey(for: $0) == key }.flatMap(\.entries)
    }

    /// Every profile a run has to consider: the ones the cache lists, in its
    /// order, then any a Space or pinned group names that it left out.
    var profileKeysInSourceOrder: [String] {
        var keys = profiles.map(\.key)
        var seen = Set(keys)
        let referenced = spaces.map { resolvedProfileKey(for: $0) }
            + pinnedGroups.map { resolvedProfileKey(for: $0) }
        for key in referenced where seen.insert(key).inserted {
            keys.append(key)
        }
        return keys
    }
}

// MARK: - Tick state

/// Which of a Migration Source's Spaces the user has ticked. A Profile carries
/// no tick of its own: it is ticked exactly while at least one of its Spaces
/// is, so "unticking the last Space unticks the Profile" holds without a
/// second piece of state to keep in step.
///
/// A Space that belongs to the default profile because its own record could
/// not be read has no tick of its own either; it is ticked exactly while its
/// Profile is, which both mutations restore before they return.
struct BrowserMigrationSelection: Equatable {
    private(set) var tickedSpaceIDs: Set<String>

    init(tickedSpaceIDs: Set<String> = []) {
        self.tickedSpaceIDs = tickedSpaceIDs
    }

    /// Everything ticked — how the preview opens.
    static func all(in source: BrowserMigrationSource) -> BrowserMigrationSelection {
        BrowserMigrationSelection(tickedSpaceIDs: Set(source.spaces.map(\.id)))
    }

    func isTicked(spaceID: String) -> Bool {
        tickedSpaceIDs.contains(spaceID)
    }

    func isTicked(profileKey: String, in source: BrowserMigrationSource) -> Bool {
        source.spaces(ofProfile: profileKey).contains { tickedSpaceIDs.contains($0.id) }
    }

    /// Ticking a Profile ticks all of its Spaces; unticking it unticks them.
    func setting(
        profileKey: String,
        ticked: Bool,
        in source: BrowserMigrationSource
    ) -> BrowserMigrationSelection {
        let ids = Set(source.spaces(ofProfile: profileKey).map(\.id))
        return BrowserMigrationSelection(
            tickedSpaceIDs: ticked ? tickedSpaceIDs.union(ids) : tickedSpaceIDs.subtracting(ids)
        ).restoringDefaultBoundSpaces(in: source)
    }

    /// Ticking or unticking one Space leaves every other Space alone. A Space
    /// bound to the default profile because its own record could not be read
    /// has no tick of its own — it follows that Profile — so this is a no-op
    /// for it.
    func setting(
        spaceID: String,
        ticked: Bool,
        in source: BrowserMigrationSource
    ) -> BrowserMigrationSelection {
        guard let space = source.spaces.first(where: { $0.id == spaceID }),
              !source.bindsToDefaultProfile(space) else {
            return self
        }
        var ids = tickedSpaceIDs
        if ticked {
            ids.insert(spaceID)
        } else {
            ids.remove(spaceID)
        }
        return BrowserMigrationSelection(tickedSpaceIDs: ids)
            .restoringDefaultBoundSpaces(in: source)
    }

    /// Puts the default-bound Spaces back in step with their Profile, so
    /// re-ticking one of its other Spaces brings them back rather than
    /// stranding them off with no control that can reach them.
    private func restoringDefaultBoundSpaces(
        in source: BrowserMigrationSource
    ) -> BrowserMigrationSelection {
        let boundIDs = source.spaces.filter { source.bindsToDefaultProfile($0) }.map(\.id)
        // With no Space of its own to follow, the Profile's tick is whatever
        // the Profile-level mutation just made it.
        let siblings = source.spaces.filter {
            !source.bindsToDefaultProfile($0)
                && source.resolvedProfileKey(for: $0) == source.defaultProfileKey
        }
        guard !boundIDs.isEmpty, !siblings.isEmpty else { return self }

        var ids = tickedSpaceIDs
        if siblings.contains(where: { tickedSpaceIDs.contains($0.id) }) {
            ids.formUnion(boundIDs)
        } else {
            ids.subtract(boundIDs)
        }
        return BrowserMigrationSelection(tickedSpaceIDs: ids)
    }
}

// MARK: - The plan

/// One pinned tab a run writes. All the copies fanned out from one source
/// entry share `lineageID`, so widening the Pinned Tab Scope later collapses
/// them back into one entry exactly as far as Phi's own fan-out copies do.
struct BrowserMigrationPlannedPinnedTab: Equatable {
    let guid: String
    let lineageID: String
    let title: String
    let url: String
    /// The Profile and Space this copy is written through. At `profile` and
    /// `app` scope the Space only satisfies the store's headless creation call
    /// — the scope, not this pair, decides the row's owner.
    let ownerProfileKey: String
    let ownerSpaceID: String
}

/// One Space a run creates.
struct BrowserMigrationPlannedSpace {
    /// The source Space this was planned from; the executor maps it to the
    /// created Space's identifier.
    let sourceSpaceID: String
    let name: String
    let colorHex: String
    let iconName: String
    /// True when the source could not read this Space's own profile record, so
    /// it was bound to the default profile's Profile.
    let boundToDefaultProfile: Bool
    let bookmarkRoot: ArcDataParserTool.Bookmark?
}

/// One Profile a run creates.
struct BrowserMigrationPlannedProfile {
    /// The source profile's on-disk directory basename — both this plan's key
    /// and what the Chromium-side importer reads from.
    let sourceProfileKey: String
    /// Free of collisions with existing Phi Profiles and with the other
    /// Profiles this plan creates, because Profile creation rejects duplicate
    /// display names outright.
    let displayName: String
    /// In source order.
    let spaces: [BrowserMigrationPlannedSpace]
    /// Empty when `pinsUnavailable` is set.
    let pinnedTabs: [BrowserMigrationPlannedPinnedTab]
    let pinsUnavailable: BrowserMigrationPinsUnavailableReason?
}

/// A source profile a run creates nothing for.
struct BrowserMigrationSkippedProfile: Equatable {
    enum Reason: String, Equatable {
        /// The source profile has no Spaces at all, so it would arrive as an
        /// empty Profile the user could not see or use.
        case noSpaces
    }

    let sourceProfileKey: String
    let displayName: String
    let reason: Reason
}

/// Exactly what a run would create: building one performs no I/O and touches
/// no store. Not `Equatable`, and not journalled the way the guest data
/// migration's records are, because it carries the source's bookmark trees by
/// reference and is consumed within the run that built it.
struct BrowserMigrationPlan {
    let pinnedTabScope: PinnedTabScope
    /// In source-profile order.
    let profiles: [BrowserMigrationPlannedProfile]
    let skippedProfiles: [BrowserMigrationSkippedProfile]
}

// MARK: - Planner

/// Turns a Migration Source into a plan. Every mapping decision of the
/// Migration design lives here, so the wizard and the executor hold none of
/// their own and the design can be tested from fixtures without a running
/// browser. Modelled on the guest→account data migration's plan-then-mappings
/// shape, under the distinct Browser Migration naming.
enum BrowserMigrationPlanner {
    /// The icon every migrated Space gets: the two icon vocabularies do not
    /// correspond, so Space icons are not migrated.
    static let spaceIconName = IconPickerSelection.defaultSelection.storageValue

    static func plan(
        source: BrowserMigrationSource,
        existingProfileDisplayNames: [String],
        pinnedTabScope: PinnedTabScope,
        selection: BrowserMigrationSelection,
        operationID: UUID
    ) -> BrowserMigrationPlan {
        var takenDisplayNames = Set(existingProfileDisplayNames.map(normalizedName))
        var profiles: [BrowserMigrationPlannedProfile] = []
        var skippedProfiles: [BrowserMigrationSkippedProfile] = []

        for (profileIndex, profileKey) in source.profileKeysInSourceOrder.enumerated() {
            let sourceProfile = source.profiles.first { $0.key == profileKey }
            let displayName = resolvedDisplayName(
                of: sourceProfile?.displayName, key: profileKey)
            let spaces = source.spaces(ofProfile: profileKey)
            guard !spaces.isEmpty else {
                skippedProfiles.append(BrowserMigrationSkippedProfile(
                    sourceProfileKey: profileKey,
                    displayName: displayName,
                    reason: .noSpaces
                ))
                continue
            }

            // A Profile follows its Spaces: none ticked, nothing created.
            let tickedSpaces = spaces.filter { selection.isTicked(spaceID: $0.id) }
            guard !tickedSpaces.isEmpty else { continue }

            let plannedSpaces = tickedSpaces.map { space in
                BrowserMigrationPlannedSpace(
                    sourceSpaceID: space.id,
                    name: space.name,
                    colorHex: space.colorHex,
                    iconName: spaceIconName,
                    boundToDefaultProfile: source.bindsToDefaultProfile(space),
                    bookmarkRoot: space.bookmarkRoot
                )
            }
            profiles.append(BrowserMigrationPlannedProfile(
                sourceProfileKey: profileKey,
                displayName: uniqueDisplayName(displayName, taken: &takenDisplayNames),
                spaces: plannedSpaces,
                pinnedTabs: plannedPinnedTabs(
                    ofProfile: profileKey,
                    profileIndex: profileIndex,
                    in: source,
                    pinsUnavailable: sourceProfile?.pinsUnavailable,
                    spaces: plannedSpaces,
                    pinnedTabScope: pinnedTabScope,
                    operationID: operationID
                ),
                pinsUnavailable: sourceProfile?.pinsUnavailable
            ))
        }

        return BrowserMigrationPlan(
            pinnedTabScope: pinnedTabScope,
            profiles: profiles,
            skippedProfiles: skippedProfiles
        )
    }

    // MARK: - Pinned tabs

    private static func plannedPinnedTabs(
        ofProfile profileKey: String,
        profileIndex: Int,
        in source: BrowserMigrationSource,
        pinsUnavailable: BrowserMigrationPinsUnavailableReason?,
        spaces: [BrowserMigrationPlannedSpace],
        pinnedTabScope: PinnedTabScope,
        operationID: UUID
    ) -> [BrowserMigrationPlannedPinnedTab] {
        // A profile whose pinned entries could not be read writes nothing; the
        // marker travels on the planned Profile instead.
        guard pinsUnavailable == nil else { return [] }

        // One owner per Space at `space` scope, one owner otherwise. The Space
        // named at `profile` and `app` scope is only what the store's headless
        // creation call needs to resolve the collection to append to.
        let ownerSpaceIDs: [String]
        switch pinnedTabScope {
        case .space:
            ownerSpaceIDs = spaces.map(\.sourceSpaceID)
        case .profile, .app:
            ownerSpaceIDs = Array(spaces.prefix(1).map(\.sourceSpaceID))
        }

        let entries = source.pinnedEntries(ofProfile: profileKey)
        return entries.enumerated().flatMap { entryIndex, entry in
            let lineageID = identifier(
                operationID: operationID,
                kind: "pin-lineage",
                path: [profileIndex, entryIndex]
            )
            return ownerSpaceIDs.enumerated().map { ownerIndex, spaceID in
                BrowserMigrationPlannedPinnedTab(
                    guid: identifier(
                        operationID: operationID,
                        kind: "pin",
                        path: [profileIndex, entryIndex, ownerIndex]
                    ),
                    lineageID: lineageID,
                    title: entry.title,
                    url: entry.url,
                    ownerProfileKey: profileKey,
                    ownerSpaceID: spaceID
                )
            }
        }
    }

    // MARK: - Names and identifiers

    /// An empty display name — or a profile the source's cache never listed at
    /// all — falls back to the directory basename. Not private: the wizard
    /// labels the rows a plan leaves out (an unticked Profile creates nothing,
    /// so it is not in the plan) with the same rule rather than a second one.
    static func resolvedDisplayName(of displayName: String?, key: String) -> String {
        let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? key : trimmed
    }

    /// Profile creation rejects a duplicate display name outright — and does so
    /// case-insensitively after trimming — so the suffixing is the planner's
    /// job. The first clash becomes "<name> 2".
    private static func uniqueDisplayName(
        _ base: String,
        taken: inout Set<String>
    ) -> String {
        var candidate = base
        var suffix = 1
        while taken.contains(normalizedName(candidate)) {
            suffix += 1
            candidate = "\(base) \(suffix)"
        }
        taken.insert(normalizedName(candidate))
        return candidate
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Derived from the run's operation id the way the guest data migration
    /// derives its own, so planning the same input twice yields the same plan.
    private static func identifier(
        operationID: UUID,
        kind: String,
        path: [Int]
    ) -> String {
        let steps = path.map(String.init).joined(separator: "-")
        return "browser-migration-\(operationID.uuidString.lowercased())-\(kind)-\(steps)"
    }
}

// MARK: - Late-completion guard

/// Stamps each step of a run so a completion notification that arrives after
/// its step has moved on cannot be consumed by the next one. The Chromium-side
/// completion channel is keyed by browser type alone and carries no request
/// identity, so this comparison is what tells a late signal from a current one.
struct BrowserMigrationGeneration: Equatable {
    private(set) var current = 0

    /// Starts the next step and returns the generation to stamp it with.
    mutating func advance() -> Int {
        current += 1
        return current
    }

    /// Whether a completion carrying `generation` belongs to the step running
    /// now.
    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}
