// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

// MARK: - Progress

/// One unit of a run as the window draws it: what it is called, and whether it
/// is a Profile or one of the Spaces bound to the Profile above it.
struct BrowserMigrationRunUnit: Equatable {
    let name: String
    let isSpace: Bool
}

/// Which unit of a run is being worked on, and the whole list it is worked
/// through. Coarse on purpose: the per-item signals the Chromium side sends up
/// carry no item identity and no total, so a finer bar would be fiction — but
/// the units themselves are known from the plan, so the window lists them.
struct BrowserMigrationProgress: Equatable {
    /// Zero-based; the view counts from one. Always a valid index into
    /// `units`: every value is built by the run, which never leaves the list.
    let unitIndex: Int
    /// In the order the run works through them, so the window renders the list
    /// rather than rebuilding it from the plan.
    let units: [BrowserMigrationRunUnit]

    var unitCount: Int { units.count }
    var currentUnit: BrowserMigrationRunUnit { units[unitIndex] }
}

// MARK: - The run

/// Runs a Migration plan. Process-level rather than window-level: closing the
/// wizard does not interrupt a run, and reopening the menu item returns to the
/// live progress or to the report of the run that just finished.
///
/// Work is strictly serial — one unit at a time, a Profile before the Spaces
/// bound to it — and best effort: a unit that fails is recorded and the run
/// carries on to the next one. Nothing is rolled back, and a failure never
/// disturbs browsing.
@MainActor
final class BrowserMigrationRunner: ObservableObject {
    static let shared = BrowserMigrationRunner()

    enum State {
        case idle
        case running(BrowserMigrationProgress)
        case finished(BrowserMigrationReport)
    }

    @Published private(set) var state: State = .idle

    /// The source the run in flight — or the finished one whose report is
    /// still up — was started from. The report interpolates its name, and must
    /// read it from here rather than from the wizard's pick: a run outlives
    /// its window, and the window reopened over the report may have moved the
    /// pick on since.
    @Published private(set) var runSource: BrowserMigrationSourceKind?

    private var outcomes = BrowserMigrationOutcomes()

    private init() {}

    var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Starts `plan` and reports whether it started. A run already in flight
    /// is left alone: the wizard returns to its progress rather than putting a
    /// second run against the same source in the air.
    ///
    /// `source` is what the plan was built from: the plan names source profiles
    /// and Spaces, and this says which browser they came out of — the importer
    /// type each Profile's data is pulled through and the directory its
    /// extensions are counted in.
    @discardableResult
    func start(plan: BrowserMigrationPlan, source: BrowserMigrationSourceKind) -> Bool {
        guard !isRunning else { return false }
        let units = Self.units(of: plan)
        guard !units.isEmpty else { return false }
        AppLogInfo("[BrowserMigration] run started: \(plan.profiles.count) Profiles, "
            + "\(units.count - plan.profiles.count) Spaces")
        outcomes = BrowserMigrationOutcomes()
        runSource = source
        // Set here rather than in the task so the wizard has progress to draw
        // the moment it switches step.
        state = .running(Self.progress(at: 0, in: units))
        Task { await run(plan: plan, source: source, units: units) }
        return true
    }

    /// Clears a finished run's report so the wizard opens on the source list
    /// again. A run in flight is left alone.
    func dismissReport() {
        if case .finished = state { state = .idle }
    }

    // MARK: - The already-migrated mark

    /// Stands a mark up in tests, which have no bound account to read one
    /// from. Always nil in production.
    static var migratedSourcesOverrideForTesting: Set<String>?

    /// Whether this account has already completed a Migration from `source` —
    /// what the wizard warns on before starting a second one. The mark is per
    /// account: signing into another lifts it, since that account's data is
    /// empty anyway, and a guest session carries its own, which the
    /// guest→account data migration deliberately does not bring across.
    static func hasMigrated(from source: BrowserMigrationSourceKind) -> Bool {
        if let migratedSourcesOverrideForTesting {
            return migratedSourcesOverrideForTesting.contains(source.rawValue)
        }
        return accountDefaults?.migratedBrowserSources().contains(source.rawValue) ?? false
    }

    private static var accountDefaults: AccountUserDefaults? {
        AccountController.shared.localDataAccount?.userDefaults
    }

    // MARK: - Units

    /// One step of a run: a Profile, with its history, cookies and extensions,
    /// or one Space bound to it, with its Bookmarks and pinned entries.
    private struct Unit {
        let name: String
        let profile: BrowserMigrationPlannedProfile
        /// Nil for the Profile's own unit.
        let space: BrowserMigrationPlannedSpace?

        /// What the progress publishes for this unit — the name and the kind,
        /// without the planned records the run itself works from.
        var published: BrowserMigrationRunUnit {
            BrowserMigrationRunUnit(name: name, isSpace: space != nil)
        }
    }

    /// A Profile ahead of the Spaces bound to it, so a Space always has one to
    /// bind to by the time its unit runs.
    private static func units(of plan: BrowserMigrationPlan) -> [Unit] {
        plan.profiles.flatMap { profile in
            [Unit(name: profile.displayName, profile: profile, space: nil)]
                + profile.spaces.map { Unit(name: $0.name, profile: profile, space: $0) }
        }
    }

    private static func progress(
        at index: Int, in units: [Unit]
    ) -> BrowserMigrationProgress {
        BrowserMigrationProgress(unitIndex: index, units: units.map(\.published))
    }

    /// The progress a run of `plan` publishes while it is on unit `index` —
    /// the value the window renders, off the same walk the run itself makes.
    /// Exposed for the suite that pins the unit list against the plan.
    static func progress(at index: Int, of plan: BrowserMigrationPlan)
        -> BrowserMigrationProgress {
        progress(at: index, in: units(of: plan))
    }

    private func run(
        plan: BrowserMigrationPlan,
        source: BrowserMigrationSourceKind,
        units: [Unit]
    ) async {
        // One importer for the whole run. It holds the continuations the
        // Chromium-side completion resumes, so it has to outlive each unit —
        // and no longer than the run, since it observes that completion for as
        // long as it exists.
        let importer = BrowserDataImporter()
        for (index, unit) in units.enumerated() {
            state = .running(Self.progress(at: index, in: units))
            if let space = unit.space {
                await create(space, of: unit.profile)
            } else {
                await create(unit.profile, from: source, through: importer)
            }
        }
        AppLogInfo("[BrowserMigration] run finished: created "
            + "\(outcomes.profileIDs.count) Profiles, \(outcomes.spaceIDs.count) Spaces")
        // Marked only by a run that reached the end and created something:
        // one cut short by a quit, or one whose every Profile failed, left no
        // first copy for a second run to duplicate.
        if !outcomes.profileIDs.isEmpty {
            Self.accountDefaults?.addMigratedBrowserSource(source.rawValue)
        }
        state = .finished(.folded(plan: plan, outcomes: outcomes))
    }

    private func create(
        _ planned: BrowserMigrationPlannedProfile,
        from source: BrowserMigrationSourceKind,
        through importer: BrowserDataImporter
    ) async {
        let profileID = await withCheckedContinuation { continuation in
            ProfileManager.shared.createProfile(displayName: planned.displayName) {
                continuation.resume(returning: $0)
            }
        }
        guard let profileID else {
            AppLogWarn("[BrowserMigration] couldn't create Profile \(planned.displayName)")
            return
        }
        outcomes.profileIDs[planned.sourceProfileKey] = profileID
        await importBrowserData(
            of: planned, from: source, into: profileID, through: importer)
    }

    /// Moves the source profile's history, cookies and extensions into the
    /// Profile just created for it, from the directory the plan names for it —
    /// several Profiles may read one. The Profile is named by its on-disk
    /// basename, so no window is opened on it — a Profile Migration creates has
    /// none, and the user's own window must not be moved to make one.
    ///
    /// One Profile at a time, which the serial run gives for free: the
    /// Chromium-side completion is keyed by browser type alone, so a second
    /// import from the same source in flight would be indistinguishable from
    /// this one's.
    ///
    /// What comes back is a single flag for the whole request, and it is worth
    /// no more than the report claims of it: the extension installs it starts
    /// run on in the background with no way back here, and a denied Keychain
    /// prompt makes the importer skip the cookies while still reporting
    /// success. A Profile whose import fails is recorded and the run moves on
    /// to the next unit.
    private func importBrowserData(
        of planned: BrowserMigrationPlannedProfile,
        from source: BrowserMigrationSourceKind,
        into profileID: String,
        through importer: BrowserDataImporter
    ) async {
        let imported = await importer.importDataIntoProfile(
            source.browserType,
            destinationProfileId: profileID,
            sourceProfileDirectory: planned.sourceDirectory,
            dataTypes: source.migrationDataTypes)
        guard imported else {
            AppLogWarn("[BrowserMigration] couldn't import \(source.displayName) data "
                + "into Profile \(planned.displayName)")
            return
        }
        outcomes.profileExtensionCounts[planned.sourceProfileKey] =
            BrowserDataImporter.webStoreExtensionCount(
                userDataURL: source.userDataURL,
                sourceProfileDirectory: planned.sourceDirectory)
    }

    private func create(
        _ planned: BrowserMigrationPlannedSpace,
        of profile: BrowserMigrationPlannedProfile
    ) async {
        // Its Profile failed, so there is nothing to bind the Space to. The
        // report says the Space was not created and the run carries on.
        guard let profileID = outcomes.profileIDs[profile.sourceProfileKey] else {
            AppLogWarn("[BrowserMigration] skipping Space \(planned.name): "
                + "Profile \(profile.displayName) wasn't created")
            return
        }
        // Not made active: a run started in the background must not move the
        // user's current window. The report's button is how they switch.
        guard let spaceID = SpaceManager.shared.createSpace(
            name: planned.name,
            colorHex: planned.colorHex,
            iconName: planned.iconName,
            profileId: profileID,
            makeDefaultActive: false
        ) else {
            AppLogWarn("[BrowserMigration] couldn't create Space \(planned.name)")
            return
        }
        outcomes.spaceIDs[planned.sourceSpaceID] = spaceID
        // A Space's colour is its theme: the `colorHex` above is a cache the
        // theme re-derives, so pinning the theme is what makes the colour
        // stick — and what the sidebar and window actually render.
        SpaceManager.shared.setTheme(forSpaceId: spaceID, themeId: planned.themeID)
        await ImportTargetLock.shared.holding(spaceID) {
            // The Space's own content lands here: its Bookmarks and the pinned
            // entries the plan gave it. Both write into a Space that must not
            // be deleted or re-profiled underneath them, which is what the
            // lock refuses for as long as it is held.
            await persistBookmarks(of: planned, profileID: profileID, spaceID: spaceID)
            await persistPinnedTabs(
                of: profile,
                ownerSpaceID: planned.sourceSpaceID,
                profileID: profileID,
                spaceID: spaceID)
        }
    }

    /// Writes the source Space's own tree into the Space just created for it,
    /// with no landing folder — the Space holds nothing else to keep it apart
    /// from.
    ///
    /// The outcome comes from the write itself rather than from any import
    /// completion signal, and a Space whose Bookmarks are dropped is recorded
    /// and left behind — the run carries on to the next unit either way.
    private func persistBookmarks(
        of planned: BrowserMigrationPlannedSpace,
        profileID: String,
        spaceID: String
    ) async {
        // No Mac-side tree to write: the source's bookmarks arrive through the
        // Chromium importer instead.
        guard let bookmarkRoot = planned.bookmarkRoot else { return }
        guard let store = AccountController.shared.localDataAccount?.localStorage else {
            AppLogWarn("[BrowserMigration] no local store for \(planned.name)'s Bookmarks")
            return
        }
        guard let count = await store.saveArcBookmarksToLocalStore(
            bookmarkRoot, profileId: profileID, spaceId: spaceID, landingFolder: false
        ) else {
            AppLogWarn("[BrowserMigration] couldn't save \(planned.name)'s Bookmarks")
            return
        }
        outcomes.spaceBookmarkCounts[planned.sourceSpaceID] = count
    }

    /// Writes the pinned entries the plan gave this Space's owner — every one
    /// of the Profile's entries at `space` scope, and the whole set through
    /// its first Space at the other two, where the row belongs to the Profile
    /// or the app rather than to a Space.
    ///
    /// The copies of one source entry carry one lineage, so widening the
    /// Pinned Tab Scope later collapses them back into one entry as far as
    /// Phi's own fan-out copies collapse. An entry the store refuses is left
    /// out of the outcomes and reported as such; the rest still land.
    private func persistPinnedTabs(
        of profile: BrowserMigrationPlannedProfile,
        ownerSpaceID: String,
        profileID: String,
        spaceID: String
    ) async {
        let planned = profile.pinnedTabs.filter { $0.ownerSpaceID == ownerSpaceID }
        guard !planned.isEmpty else { return }
        guard let store = AccountController.shared.localDataAccount?.localStorage else {
            AppLogWarn("[BrowserMigration] no local store for \(profile.displayName)'s "
                + "pinned tabs")
            return
        }
        for pin in planned {
            // In source order, and appended at the end of the collection, so
            // the order the user built survives the move.
            if store.createPinnedTab(
                guid: pin.guid,
                url: pin.url,
                title: pin.title,
                profileId: profileID,
                spaceId: spaceID,
                lineageId: pin.lineageID
            ) {
                outcomes.pinnedTabGuids.insert(pin.guid)
            } else {
                AppLogWarn("[BrowserMigration] couldn't pin \(pin.url) in "
                    + "\(profile.displayName)")
            }
        }
        // The creation call enqueues its write rather than awaiting it, so
        // drain the store's queue before the lock goes: the Space has to still
        // be undeletable when these land.
        await store.performBackgroundWriteAndWait { _ in }
    }
}

// MARK: - Mutual exclusion

/// Whether a Migration or a browser-data import is in flight. One object, so
/// the places that gate on it cannot drift apart: the Migration menu item is
/// greyed out while an import is in flight, the import menu item while a
/// Migration is, and the Pinned Tab Scope reads the Migration run alone — a
/// browser-data import writes no pinned tabs. Each window's own owner answers
/// for it, since both outlive their close and "in flight" is not "a window
/// exists".
@MainActor
enum BrowserDataActivity {
    /// Stands a run up in tests, which have no Chromium bridge to start a real
    /// one with. Always nil in production.
    static var migrationRunOverrideForTesting: Bool?

    /// A Migration run is under way — what the Pinned Tab Scope refuses on: a
    /// run writes its pinned entries to the owners its plan was built for, so
    /// the scope must not move under it.
    static var migrationRunIsInFlight: Bool {
        migrationRunOverrideForTesting ?? BrowserMigrationRunner.shared.isRunning
    }

    /// A Migration run is under way, or its wizard is on screen: the import
    /// menu item is greyed out.
    static var migrationBlocksImport: Bool {
        migrationRunIsInFlight || AppController.browserMigrationWizardIsOnScreen
    }

    /// An import is under way, or its window is on screen: the Migration menu
    /// item is greyed out.
    static var importBlocksMigration: Bool {
        MainBrowserWindowController.importIsInFlight
    }
}
