// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
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

/// A Migration Source's profile. The key identifies it within the source;
/// the directory the Chromium-side importer reads from is carried apart from
/// it, because a Zen container Profile is one of several that read the same
/// Firefox profile directory (ADR 0005). For Arc the two are one.
struct BrowserMigrationSourceProfile {
    let key: String
    let displayName: String
    /// The on-disk profile directory basename the Chromium-side importer
    /// reads from. Several source profiles may share one.
    let sourceDirectory: String
    /// Non-nil when the source has pinned entries but could not read them;
    /// distinct from an empty pinned group, which means the user had none.
    let pinsUnavailable: BrowserMigrationPinsUnavailableReason?

    init(
        key: String,
        displayName: String,
        sourceDirectory: String? = nil,
        pinsUnavailable: BrowserMigrationPinsUnavailableReason? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.sourceDirectory = sourceDirectory ?? key
        self.pinsUnavailable = pinsUnavailable
    }
}

/// A source Space's icon as the source recorded it. What it becomes in Phi is
/// the resolver's decision; the model carries only what was read.
enum BrowserMigrationSourceIcon: Equatable {
    /// The emoji text as the source stored it.
    case emoji(String)
    /// One of Arc's built-in icons, by Arc's own name for it; the resolver's
    /// Arc table says what it becomes.
    case arcNamed(String)
    /// One of Zen's built-in icons, by Zen's own name for it; the resolver's
    /// Zen table says what it becomes. The rule for the Zen adapter, when it
    /// comes: Zen keeps a Space's icon in the session file's `spaces[].icon`
    /// as the emoji text as typed, or as a
    /// `chrome://…/zen-icons/selectable/<name>.svg` URL for one of its
    /// built-in icons; map the URL's basename without its extension here,
    /// any other non-empty string to `.emoji`, and absent or empty to nil.
    /// (Zen's private windows auto-create a Space with `eye.svg`; those
    /// Spaces do not migrate.)
    case zenNamed(String)
}

/// One Space of a Migration Source. A space-less source (Dia) synthesises one
/// per profile before it gets here, so the planner has no source-specific arm.
struct BrowserMigrationSourceSpace {
    let id: String
    /// Already carries the source parser's placeholder when the Space is
    /// untitled; the planner adds no fallback of its own.
    let name: String
    /// Derived from the source Space's theme; nil when the source gave it no
    /// theme, which is a different thing from a colour and takes the default
    /// theme rather than being snapped to a hue.
    let colorHex: String?
    /// nil when the source Space had no icon. One it had keeps the Phi icon
    /// that stands for it, and takes the default new-Space icon when Phi has
    /// nothing for it.
    let icon: BrowserMigrationSourceIcon?
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
        colorHex: String?,
        icon: BrowserMigrationSourceIcon? = nil,
        profileKey: String?,
        bookmarkRoot: ArcDataParserTool.Bookmark? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.icon = icon
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

// MARK: - Space theme

/// Which built-in Phi theme a migrated Space lands on.
///
/// A Space's colour in Phi is its **theme**, not a free value: the `colorHex`
/// the Space model stores is a cache the theme re-derives on every change
/// (`SpaceManager.syncColorHexWithTheme`), and its one visual consumer — the
/// sidebar tint gradient — is disabled today, so a plan carrying only a hex
/// would show nothing and be overwritten by the first `setTheme`. The source's
/// colour is snapped to the nearest built-in instead, and that theme is what
/// the run pins. Only the hue survives the snap.
enum BrowserMigrationSpaceTheme {
    /// What a source Space's colour becomes: the theme the run pins, and the
    /// colour that theme shows — which is what the preview draws, so it cannot
    /// promise a colour Phi will not produce.
    struct Resolved: Equatable {
        let themeID: String
        let colorHex: String
    }

    /// The theme for a source Space whose colour names no hue — too close to
    /// neutral, or too dark — and for one the source gave no theme at all.
    static var defaultThemeID: String { Theme.default.id }

    /// A nil colour is the source saying it gave this Space no theme, which
    /// takes the default rather than being snapped: substituting a colour
    /// first would snap that stand-in to whatever hue it happened to have.
    static func resolved(forSourceColorHex hex: String?) -> Resolved {
        let themeID = hex.map(nearestThemeID(toColorHex:)) ?? defaultThemeID
        return Resolved(themeID: themeID, colorHex: overlayHex(ofThemeID: themeID))
    }

    /// Hue carries the source's colour intent and is all the eight-theme
    /// vocabulary can hold; a colour with too little saturation or brightness
    /// has no hue worth matching.
    private static let neutralSaturation: CGFloat = 0.15
    private static let neutralBrightness: CGFloat = 0.12

    private static func nearestThemeID(toColorHex hex: String) -> String {
        guard let source = hsb(of: NSColor(hexString: hex)),
              source.saturation >= neutralSaturation,
              source.brightness >= neutralBrightness else {
            return defaultThemeID
        }
        // Read off `Theme.builtInThemes` rather than restated here, so a theme
        // added to Phi becomes a Migration target with no second list to keep
        // in step. The default theme is left out of the comparison: its
        // overlay is white, so it has no hue — it is what a neutral falls
        // back to, not something a hue can be nearest to.
        let nearest = Theme.builtInThemes
            .filter { $0.id != defaultThemeID }
            .min { hueDistance(source.hue, of: $0) < hueDistance(source.hue, of: $1) }
        return nearest?.id ?? defaultThemeID
    }

    static func overlayHex(ofThemeID id: String) -> String {
        overlayColor(of: Theme.builtInThemes.first { $0.id == id } ?? Theme.default)
            .hexRGBString
    }

    /// Hue is 0...1 and wraps, so the distance is the shorter way round.
    private static func hueDistance(_ hue: CGFloat, of theme: Theme) -> CGFloat {
        guard let themeHue = hsb(of: overlayColor(of: theme))?.hue else {
            return .greatestFiniteMagnitude
        }
        let delta = abs(hue - themeHue)
        return min(delta, 1 - delta)
    }

    /// Light, explicitly: a plan must not depend on the appearance the user
    /// happens to be in. `setTheme` re-derives the stored `colorHex` for the
    /// live appearance as soon as the Space is created.
    private static func overlayColor(of theme: Theme) -> NSColor {
        theme.color(for: .windowOverlayBackground, appearance: .light)
    }

    private static func hsb(
        of color: NSColor
    ) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat)? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (hue, saturation, brightness)
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
    /// The colour the pinned theme shows, not the source's own colour: eight
    /// hues is the whole vocabulary, so the plan states what will exist.
    let colorHex: String
    /// The built-in theme the run pins, which is what makes the colour stick.
    let themeID: String
    let iconName: String
    /// True when the source could not read this Space's own profile record, so
    /// it was bound to the default profile's Profile.
    let boundToDefaultProfile: Bool
    let bookmarkRoot: ArcDataParserTool.Bookmark?
}

/// One Profile a run creates.
struct BrowserMigrationPlannedProfile {
    /// The source profile's key within the plan.
    let sourceProfileKey: String
    /// The on-disk profile directory the Chromium-side importer reads from:
    /// the source profile's, or the key itself for a profile the source never
    /// listed.
    let sourceDirectory: String
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
    /// How many of the source profile's pinned entries go nowhere with it —
    /// a Zen container no Space is set to still has its Essentials — so the
    /// report can say what was left behind rather than imply there was
    /// nothing.
    let droppedPinnedEntries: Int

    init(
        sourceProfileKey: String, displayName: String, reason: Reason, droppedPinnedEntries: Int = 0
    ) {
        self.sourceProfileKey = sourceProfileKey
        self.displayName = displayName
        self.reason = reason
        self.droppedPinnedEntries = droppedPinnedEntries
    }
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
/// browser. The one thing read from elsewhere is the Space icon matching —
/// the tables and emoji normalisation in `BrowserMigrationSpaceIconResolver`,
/// which the planner alone calls and whose fallback it owns. Modelled on the
/// guest→account data migration's plan-then-mappings shape, under the
/// distinct Browser Migration naming.
enum BrowserMigrationPlanner {
    /// The icon a migrated Space gets when its source had none, or one Phi
    /// has nothing for: the default new-Space icon.
    static let defaultSpaceIconName = IconPickerSelection.defaultSelection.storageValue

    /// The icon storage value a source Space's icon becomes: the resolver's
    /// answer, or the default. Not private: the wizard's preview labels an
    /// unticked Space (which is not in the plan) with the same rule rather
    /// than a second one, as it already does for the theme.
    static func spaceIconName(for icon: BrowserMigrationSourceIcon?) -> String {
        icon.flatMap { BrowserMigrationSpaceIconResolver.storageValue(for: $0) }
            ?? defaultSpaceIconName
    }

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
                    reason: .noSpaces,
                    droppedPinnedEntries: source.pinnedEntries(ofProfile: profileKey).count
                ))
                continue
            }

            // A Profile follows its Spaces: none ticked, nothing created.
            let tickedSpaces = spaces.filter { selection.isTicked(spaceID: $0.id) }
            guard !tickedSpaces.isEmpty else { continue }

            let plannedSpaces = tickedSpaces.map { space in
                let theme = BrowserMigrationSpaceTheme.resolved(
                    forSourceColorHex: space.colorHex)
                return BrowserMigrationPlannedSpace(
                    sourceSpaceID: space.id,
                    name: space.name,
                    colorHex: theme.colorHex,
                    themeID: theme.themeID,
                    iconName: spaceIconName(for: space.icon),
                    boundToDefaultProfile: source.bindsToDefaultProfile(space),
                    bookmarkRoot: space.bookmarkRoot
                )
            }
            profiles.append(BrowserMigrationPlannedProfile(
                sourceProfileKey: profileKey,
                sourceDirectory: sourceProfile?.sourceDirectory ?? profileKey,
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

// MARK: - What a run produced


/// The identifiers a run created, keyed by what the plan called them. A failed
/// unit is recorded by its absence: nothing was created, so there is no
/// identifier, which is exactly what the report reads.
struct BrowserMigrationOutcomes: Equatable {
    /// The created Phi Profile's on-disk basename, per planned source profile.
    var profileIDs: [String: String] = [:]
    /// The created Phi Space's identifier, per planned source Space.
    var spaceIDs: [String: String] = [:]
    /// How many bookmark nodes a Space's tree wrote, per planned source Space,
    /// recorded from the write itself — the import completion signal reports
    /// success unconditionally and before the write runs, so reading the
    /// outcome off it would call a dropped tree a success. A write that did
    /// not land leaves no entry, the same way a Space that was never created
    /// leaves none.
    var spaceBookmarkCounts: [String: Int] = [:]
    /// How many Web Store extensions install was triggered for, per planned
    /// source profile, recorded only when that Profile's history / cookies /
    /// extensions import came back successful. A Profile that failed — or was
    /// never created — leaves no entry, the same way a Space whose Bookmarks
    /// did not land leaves none.
    var profileExtensionCounts: [String: Int] = [:]
    /// The guids of the pinned tabs the store accepted. A planned copy it
    /// refused — an entry whose URL it could not parse — leaves none, so the
    /// report can tell a source entry that landed from one that was dropped.
    /// That is as far as the creation call can report: the insert itself runs
    /// on the store's write queue, which logs a failure of its own rather than
    /// returning it.
    var pinnedTabGuids: Set<String> = []
}

// MARK: - The report

/// What a finished run says it did. Folded from the plan and the identifiers
/// the run produced by a pure function, so the report's structure is pinned
/// without any I/O and the view only draws it.
struct BrowserMigrationReport: Equatable {
    struct SpaceRow: Equatable, Identifiable {
        /// What became of a Space's Bookmarks.
        enum Bookmarks: Equatable {
            /// Nothing was to be written: the Space was never created, or the
            /// source carries no Mac-side tree for it because its bookmarks
            /// arrive Chromium-side.
            case notAttempted
            /// Written, bookmark count included. Always positive: the two ways
            /// a write lands nothing are cases of their own, because a report
            /// that cannot tell them apart has to hedge on both.
            case written(Int)
            /// The write ran and the source Space held no bookmarks to write,
            /// so nothing was lost.
            case noneInSource
            /// The source Space held bookmarks and none of them landed — the
            /// visible symptom of the inherited staged-root defect, and the
            /// only one of the two zeroes the report promotes.
            case noneSaved
            /// Attempted and did not land.
            case failed
        }

        let sourceSpaceID: String
        let name: String
        /// The built-in theme the plan pinned, so the report draws the swatch
        /// the preview promised and the two can be checked against each other.
        let themeID: String
        /// The icon storage value the plan gave the Space, carried the same
        /// way for the same reason.
        let iconName: String
        let created: Bool
        let bookmarks: Bookmarks

        var id: String { sourceSpaceID }
    }

    struct ProfileRow: Equatable, Identifiable {
        /// What became of a Profile's history, cookies and extensions — one
        /// outcome for the three, because the Chromium side answers the whole
        /// request with a single flag.
        enum BrowserData: Equatable {
            /// Nothing was asked for: the Profile was never created.
            case notAttempted
            /// The import ran to completion, and installation was triggered
            /// for `extensions` Web Store extensions. A request, not a result:
            /// each install's outcome stays on the Chromium side, and cookies
            /// are skipped in silence when the source's Keychain prompt is
            /// denied while the completion still says success.
            case requested(extensions: Int)
            /// The import was refused or came back failed.
            case failed
        }

        let sourceProfileKey: String
        let displayName: String
        let created: Bool
        let browserData: BrowserData
        /// How many of the source profile's pinned entries the store accepted,
        /// and how many the plan carried. Counted in source entries rather
        /// than in rows: at `space` scope one entry is written once per Space,
        /// and what the user sees in any one Space is the entry.
        let pinnedTabsWritten: Int
        let pinnedTabsPlanned: Int
        let spaces: [SpaceRow]

        /// True while nothing the plan carried was dropped, which is what the
        /// report ticks on.
        var pinnedTabsComplete: Bool { pinnedTabsWritten == pinnedTabsPlanned }

        var id: String { sourceProfileKey }
    }

    /// The Space the report's button switches to.
    struct FirstSpace: Equatable {
        let spaceID: String
        let name: String
    }

    /// In plan order, which is the source's own order.
    let profiles: [ProfileRow]
    /// The first Space the run created, or nil when it created none — in which
    /// case the report hides its button rather than offering a dead one.
    let firstCreatedSpace: FirstSpace?

    static func folded(
        plan: BrowserMigrationPlan,
        outcomes: BrowserMigrationOutcomes
    ) -> BrowserMigrationReport {
        let profiles = plan.profiles.map { profile in
            let profileCreated = outcomes.profileIDs[profile.sourceProfileKey] != nil
            return ProfileRow(
                sourceProfileKey: profile.sourceProfileKey,
                displayName: profile.displayName,
                created: profileCreated,
                browserData: browserData(
                    of: profile, created: profileCreated, outcomes: outcomes),
                pinnedTabsWritten: lineageCount(
                    of: profile.pinnedTabs.filter {
                        outcomes.pinnedTabGuids.contains($0.guid)
                    }),
                pinnedTabsPlanned: lineageCount(of: profile.pinnedTabs),
                spaces: profile.spaces.map { space in
                    let created = outcomes.spaceIDs[space.sourceSpaceID] != nil
                    return SpaceRow(
                        sourceSpaceID: space.sourceSpaceID,
                        name: space.name,
                        themeID: space.themeID,
                        iconName: space.iconName,
                        created: created,
                        bookmarks: bookmarks(of: space, created: created, outcomes: outcomes))
                })
        }
        let firstCreatedSpace = plan.profiles.lazy.flatMap(\.spaces).compactMap { space in
            outcomes.spaceIDs[space.sourceSpaceID]
                .map { FirstSpace(spaceID: $0, name: space.name) }
        }.first
        return BrowserMigrationReport(
            profiles: profiles, firstCreatedSpace: firstCreatedSpace)
    }

    /// One source entry per lineage, however many owners it was written to.
    private static func lineageCount(of pinnedTabs: [BrowserMigrationPlannedPinnedTab]) -> Int {
        Set(pinnedTabs.map(\.lineageID)).count
    }

    private static func browserData(
        of profile: BrowserMigrationPlannedProfile,
        created: Bool,
        outcomes: BrowserMigrationOutcomes
    ) -> ProfileRow.BrowserData {
        guard created else { return .notAttempted }
        guard let extensions = outcomes.profileExtensionCounts[profile.sourceProfileKey] else {
            return .failed
        }
        return .requested(extensions: extensions)
    }

    private static func bookmarks(
        of space: BrowserMigrationPlannedSpace,
        created: Bool,
        outcomes: BrowserMigrationOutcomes
    ) -> SpaceRow.Bookmarks {
        guard created, let root = space.bookmarkRoot else { return .notAttempted }
        guard let count = outcomes.spaceBookmarkCounts[space.sourceSpaceID] else {
            return .failed
        }
        guard count == 0 else { return .written(count) }
        // A written zero is either of two things the report words — and
        // classifies — apart, and only the source tree it was written from
        // says which.
        return sourceBookmarkCount(of: root) > 0 ? .noneSaved : .noneInSource
    }

    /// How many bookmarks the source tree held, counted the way the store
    /// counts what it wrote: a folder is not a bookmark, so a Space carrying
    /// nothing but empty folders had none to lose.
    private static func sourceBookmarkCount(of node: ArcDataParserTool.Bookmark) -> Int {
        node.children.reduce(0) { total, child in
            total + (child.isFolder ? 0 : 1) + sourceBookmarkCount(of: child)
        }
    }
}

// MARK: - The problems the report promotes

extension BrowserMigrationReport {
    /// One hard failure, named by what failed and where. The report promotes
    /// these above its disclosure and leaves everything else inside it: an
    /// outcome Phi asked for but cannot confirm — cookies requested,
    /// extensions triggered — is not a failure, and marking it as one would
    /// teach the reader to ignore the mark that matters.
    /// A hard failure the report promotes: something the run set out to do and
    /// is known not to have done. Not the three hedges — a request Chromium
    /// answers with one unconditional success flag is unconfirmable, not
    /// failed, and promoting every unconfirmable outcome would teach the reader
    /// to ignore the colour that matters.
    enum Problem: Equatable {
        case profileNotCreated(profile: String)
        /// The Profile exists but its history, cookies and extensions import
        /// came back failed. A confirmed failure, not one of the three hedges:
        /// `requested` is what cannot be confirmed, `failed` is what is known.
        /// Only ever reported for a Profile that exists — with no Profile there
        /// was nothing to import into, which its own row already says.
        case browserDataFailed(profile: String)
        case spaceNotCreated(profile: String, space: String)
        case bookmarksFailed(profile: String, space: String)
        /// The source Space held bookmarks and none of them landed. Distinct
        /// from a Space that had none, which is not a problem at all.
        case bookmarksNoneSaved(profile: String, space: String)
        /// Some of the Profile's pinned entries were refused. Only ever
        /// reported for a Profile that exists: with no Profile there was
        /// nothing to write them to, which its own row already says.
        case pinnedTabsIncomplete(profile: String, written: Int, planned: Int)
    }

    /// Every promoted failure, in plan order, each Profile's own ahead of its
    /// Spaces'. A pure projection: the report holds the facts, this decides
    /// which of them the reader is made to look at, and the view only draws
    /// the result.
    var problems: [Problem] {
        profiles.flatMap { profile -> [Problem] in
            var found: [Problem] = []
            if !profile.created {
                found.append(.profileNotCreated(profile: profile.displayName))
            } else {
                // Independent failures of the same existing Profile, so both
                // are reported: an import that was refused says nothing about
                // whether the pinned entries landed. Ordered as the expanded
                // rows are, browser data before pinned tabs.
                if profile.browserData == .failed {
                    found.append(.browserDataFailed(profile: profile.displayName))
                }
                if !profile.pinnedTabsComplete {
                    found.append(.pinnedTabsIncomplete(
                        profile: profile.displayName,
                        written: profile.pinnedTabsWritten,
                        planned: profile.pinnedTabsPlanned))
                }
            }
            return found + profile.spaces.compactMap { space in
                switch space.failure {
                case nil:
                    return nil
                case .notCreated:
                    return .spaceNotCreated(
                        profile: profile.displayName, space: space.name)
                case .bookmarksFailed:
                    return .bookmarksFailed(
                        profile: profile.displayName, space: space.name)
                case .bookmarksNoneSaved:
                    return .bookmarksNoneSaved(
                        profile: profile.displayName, space: space.name)
                }
            }
        }
    }

    /// How many Profiles and Spaces the run actually created — the summary's
    /// two numbers, and the difference between "Created 2 Profiles and 5
    /// Spaces." and "Nothing was created."
    var createdProfileCount: Int { profiles.filter(\.created).count }

    var createdSpaceCount: Int {
        profiles.flatMap(\.spaces).filter(\.created).count
    }
}

extension BrowserMigrationReport.SpaceRow {
    /// Which promoted failure a Space carries, if any. The rule lives here
    /// alone: the promoted list and the row's own mark both read it, so a
    /// sixth kind cannot land in one and be missed by the other.
    enum Failure: Equatable {
        case notCreated
        case bookmarksFailed
        case bookmarksNoneSaved
    }

    var failure: Failure? {
        guard created else { return .notCreated }
        switch bookmarks {
        case .failed: return .bookmarksFailed
        case .noneSaved: return .bookmarksNoneSaved
        case .notAttempted, .written, .noneInSource: return nil
        }
    }
}

extension BrowserMigrationReport.ProfileRow {
    /// Whether everything about the Profile itself that could be confirmed
    /// was — what its row's tick claims. Every way this can be false is also a
    /// promoted problem, so a row without a tick is always accounted for in the
    /// block the reader is made to look at. Its Spaces answer for themselves.
    var landedCleanly: Bool {
        created && pinnedTabsComplete && browserData != .failed
    }
}
