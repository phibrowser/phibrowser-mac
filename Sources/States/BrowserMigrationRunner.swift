// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

// MARK: - Progress

/// Which unit of a run is being worked on. Coarse on purpose: the per-item
/// signals the Chromium side sends up carry no item identity and no total, so
/// a finer bar would be fiction.
struct BrowserMigrationProgress: Equatable {
    /// Zero-based; the view counts from one.
    let unitIndex: Int
    let unitCount: Int
    let unitName: String
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
    @discardableResult
    func start(plan: BrowserMigrationPlan) -> Bool {
        guard !isRunning else { return false }
        let units = Self.units(of: plan)
        guard !units.isEmpty else { return false }
        AppLogInfo("[BrowserMigration] run started: \(plan.profiles.count) Profiles, "
            + "\(units.count - plan.profiles.count) Spaces")
        outcomes = BrowserMigrationOutcomes()
        // Set here rather than in the task so the wizard has progress to draw
        // the moment it switches step.
        state = .running(Self.progress(at: 0, in: units))
        Task { await run(plan: plan, units: units) }
        return true
    }

    /// Clears a finished run's report so the wizard opens on the source list
    /// again. A run in flight is left alone.
    func dismissReport() {
        if case .finished = state { state = .idle }
    }

    // MARK: - Units

    /// One step of a run: a Profile, or one Space bound to it. Later tickets
    /// give each kind more to do — the Profile's history, cookies and
    /// extensions, the Space's Bookmarks and pinned tabs — without changing
    /// the counter the user sees.
    private struct Unit {
        let name: String
        let profile: BrowserMigrationPlannedProfile
        /// Nil for the Profile's own unit.
        let space: BrowserMigrationPlannedSpace?
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
        BrowserMigrationProgress(
            unitIndex: index, unitCount: units.count, unitName: units[index].name)
    }

    private func run(plan: BrowserMigrationPlan, units: [Unit]) async {
        for (index, unit) in units.enumerated() {
            state = .running(Self.progress(at: index, in: units))
            if let space = unit.space {
                await create(space, of: unit.profile)
            } else {
                await create(unit.profile)
            }
        }
        AppLogInfo("[BrowserMigration] run finished: created "
            + "\(outcomes.profileIDs.count) Profiles, \(outcomes.spaceIDs.count) Spaces")
        state = .finished(.folded(plan: plan, outcomes: outcomes))
    }

    private func create(_ planned: BrowserMigrationPlannedProfile) async {
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
            // The Space's own content lands here: its Bookmarks (ticket 06)
            // and its pinned tabs (ticket 07). Both write into a Space that
            // must not be deleted or re-profiled underneath them, which is
            // what the lock refuses for as long as it is held.
        }
    }
}
