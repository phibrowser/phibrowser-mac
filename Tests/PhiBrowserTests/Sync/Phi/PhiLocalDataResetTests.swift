// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// `PhiLocalDataReset` against an in-memory world (docs/sync.md, "Replacing this Mac's data at
/// pairing"): fail-closed preconditions, step order, convergence after a crash, postconditions.
/// Window teardown, the modal and the Chromium deletion are faked here; their production behaviour
/// is runtime-only.
@MainActor
final class PhiLocalDataResetTests: XCTestCase {
    typealias SpaceRow = PhiLocalDataReset.SpaceRow
    private static let defaultSpace = LocalStore.defaultSpaceId
    private static let defaultProfile = LocalStore.defaultProfileId

    struct SimulatedCrash: Error {}

    /// The store, Space and Profile managers, windows and sync state the reset reads and writes.
    @MainActor final class World {
        var paired = false
        var sessionUsable = true
        var history: [PhiLocalDataReset.SyncHistory] = []
        var mappedProfiles: Set<String> = []
        var spaceMappings: [String: String] = [:]
        var spaces: [SpaceRow] = []
        var agentSpaces: [SpaceRow] = []
        /// Chromium's Profiles; `nonAssignable` ones (the agent fallback) are in it too.
        var chromiumProfiles: Set<String> = [LocalStore.defaultProfileId]
        var nonAssignable: Set<String> = []
        var storedProfiles: Set<String> = [LocalStore.defaultProfileId]
        var profileListReadFails = false
        var bookmarks = 0, pinnedTabs = 0, urlRules = 0
        var roleHolder: String?
        var settingsAdoptionCleared = false
        var importing: Set<String> = []
        var agentTaskSpaces: Set<String> = []
        /// Profiles whose windows never close.
        var stuckWindows: Set<String> = []
        var steps: [String] = []
        /// Space deletions answer this outcome once, then behave normally.
        var refuseSpaceDeletion: [String: SpaceManager.PairingResetSpaceDeletion] = [:]
        var rebindOutcome = SpaceManager.PairingResetRebind.rebound
        var brokenWipe = false
        /// The Chromium Profile goes but the process "crashes" before its rows are removed.
        var crashAfterChromiumDeletion: Set<String> = []
        var profileDeletionFailure: ProfileDeletionFailure?
        var rowCleanupFails = false

        func reset() -> PhiLocalDataReset {
            PhiLocalDataReset(sync: syncAccess(), local: localAccess())
        }

        func syncAccess() -> PhiLocalDataReset.SyncAccess {
            PhiLocalDataReset.SyncAccess(
                isPaired: { self.paired },
                isSessionUsable: { self.sessionUsable },
                syncHistory: { self.history },
                isProfileMapped: { self.mappedProfiles.contains($0) },
                spaceMappings: { self.spaceMappings },
                removeSpaceMapping: { self.steps.append("unmap \($0)"); self.spaceMappings[$0] = nil },
                clearSettingsAdoption: { self.steps.append("settings"); self.settingsAdoptionCleared = true })
        }

        private func readProfiles() throws -> Set<String> {
            if profileListReadFails { throw LocalStoreWriteError.storeUnavailable }
            return chromiumProfiles
        }

        func localAccess() -> PhiLocalDataReset.LocalAccess {
            PhiLocalDataReset.LocalAccess(
                counts: {
                    PhiDataCounts(nonDefaultUserSpaces: self.spaces.filter { $0.spaceId != PhiLocalDataResetTests.defaultSpace }.count,
                                  bookmarks: self.bookmarks, pinnedTabs: self.pinnedTabs, urlRules: self.urlRules)
                },
                userSpaces: { self.spaces },
                agentSpaces: { self.agentSpaces },
                chromiumProfileIds: { try self.readProfiles() },
                userAssignableProfileIds: { try self.readProfiles().subtracting(self.nonAssignable) },
                storedProfileIds: { self.storedProfiles },
                isImporting: { self.importing.contains($0) },
                hasRunningAgentTask: { spaceIds, profileIds in
                    self.agentTaskSpaces.contains { spaceId in
                        spaceIds.contains(spaceId)
                            || (self.spaces + self.agentSpaces).first { $0.spaceId == spaceId }
                                .map { profileIds.contains($0.profileId) } == true
                    }
                },
                setDefaultSpaceRole: { self.steps.append("role"); self.roleHolder = PhiLocalDataResetTests.defaultSpace; return true },
                recreateDefaultSpace: { profileId in
                    self.steps.append("recreate")
                    self.spaces.insert(SpaceRow(spaceId: PhiLocalDataResetTests.defaultSpace, profileId: profileId), at: 0)
                },
                rebindDefaultSpace: { profileId in
                    self.steps.append("rebind")
                    guard self.rebindOutcome == .rebound,
                          let index = self.spaces.firstIndex(where: { $0.spaceId == PhiLocalDataResetTests.defaultSpace }) else {
                        return self.rebindOutcome
                    }
                    self.spaces[index] = SpaceRow(spaceId: PhiLocalDataResetTests.defaultSpace, profileId: profileId)
                    return .rebound
                },
                wipeOwnedItems: {
                    self.steps.append("wipe")
                    guard !self.brokenWipe else { return }
                    (self.bookmarks, self.pinnedTabs, self.urlRules) = (0, 0, 0)
                },
                deleteSpace: { spaceId in
                    self.steps.append("space \(spaceId)")
                    if let outcome = self.refuseSpaceDeletion.removeValue(forKey: spaceId) { return outcome }
                    let before = self.spaces.count + self.agentSpaces.count
                    self.spaces.removeAll { $0.spaceId == spaceId }
                    self.agentSpaces.removeAll { $0.spaceId == spaceId }
                    return before == self.spaces.count + self.agentSpaces.count ? .notFound : .deleted
                },
                profilesWithLiveWindows: { profileIds in profileIds.intersection(self.stuckWindows) },
                isProfileInUse: { profileId in
                    (self.spaces + self.agentSpaces).contains { $0.profileId == profileId }
                },
                deleteProfile: { profileId in
                    self.steps.append("profile \(profileId)")
                    if let failure = self.profileDeletionFailure { throw failure }
                    self.chromiumProfiles.remove(profileId)
                    if self.crashAfterChromiumDeletion.remove(profileId) != nil { throw SimulatedCrash() }
                    self.storedProfiles.remove(profileId)
                },
                removeProfileRows: { profileId in
                    if self.rowCleanupFails { throw LocalStoreWriteError.storeUnavailable }
                    if self.storedProfiles.remove(profileId) != nil { self.steps.append("rows \(profileId)") }
                })
        }
    }

    /// A Mac with a second Profile, two extra Spaces (one on each Profile), owned items and a
    /// stale Space mapping from an earlier partial setup.
    private func populatedWorld() -> World {
        let world = World()
        world.chromiumProfiles = [Self.defaultProfile, "Profile 2"]
        world.storedProfiles = [Self.defaultProfile, "Profile 2"]
        world.spaces = [SpaceRow(spaceId: Self.defaultSpace, profileId: Self.defaultProfile),
                        SpaceRow(spaceId: "work", profileId: Self.defaultProfile),
                        SpaceRow(spaceId: "side", profileId: "Profile 2")]
        (world.bookmarks, world.pinnedTabs, world.urlRules) = (12, 3, 2)
        world.spaceMappings = ["gone": "uuid-gone"]
        return world
    }

    private static let deleteProfile2 = LocalResetRequest(deleteProfileIds: ["Profile 2"])

    private func assertFailure(_ expected: PhiLocalDataResetError, _ world: World,
                               _ request: LocalResetRequest = LocalResetRequest(),
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await world.reset().clear(request)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as PhiLocalDataResetError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private func assertRefusal(_ expected: PhiLocalDataResetError, _ world: World,
                               _ request: LocalResetRequest = LocalResetRequest(),
                               file: StaticString = #filePath, line: UInt = #line) async {
        await assertFailure(expected, world, request, file: file, line: line)
        XCTAssertTrue(world.steps.isEmpty, "a refused reset changes nothing", file: file, line: line)
    }

    // MARK: - Preconditions

    func testThePreconditionsFailClosedBeforeAnythingChanges() async {
        var world = populatedWorld()
        world.paired = true
        await assertRefusal(.paired, world)

        world = populatedWorld()
        world.sessionUsable = false
        await assertRefusal(.sessionUnavailable, world)

        for history in [PhiLocalDataReset.SyncHistory.spaceCursor, .profileCursor, .marker,
                        .ownedItemCursor, .profileDeletionJournal] {
            world = populatedWorld()
            world.history = [history]
            await assertRefusal(.syncHistoryPresent(history), world)
        }

        world = populatedWorld()
        await assertRefusal(.profileNotDeletable(Self.defaultProfile), world,
                            LocalResetRequest(deleteProfileIds: [Self.defaultProfile]))

        world = populatedWorld()
        world.chromiumProfiles.insert("agent-fallback")
        world.nonAssignable = ["agent-fallback"]
        await assertRefusal(.profileNotDeletable("agent-fallback"), world,
                            LocalResetRequest(deleteProfileIds: ["agent-fallback"]))

        world = populatedWorld()
        world.mappedProfiles = ["Profile 2"]
        await assertRefusal(.profileMapped("Profile 2"), world, Self.deleteProfile2)

        world = populatedWorld()
        world.importing = [Self.defaultSpace]
        await assertRefusal(.importInProgress, world)

        world = populatedWorld()
        world.agentTaskSpaces = ["side"]
        await assertRefusal(.agentTaskRunning, world)
    }

    /// A Profile list that cannot be read must never look like "the Profiles are already gone".
    func testAFailedProfileListReadDeletesNothing() async {
        let world = populatedWorld()
        world.profileListReadFails = true
        await assertRefusal(.inventoryUnavailable, world, Self.deleteProfile2)
        XCTAssertThrowsError(try world.reset().inventory(deleting: ["Profile 2"])) {
            XCTAssertEqual($0 as? PhiLocalDataResetError, .inventoryUnavailable)
        }
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile, "Profile 2"])
    }

    /// A kept mapped Profile is fine: only Profiles chosen for deletion must be unmapped.
    func testAMappedProfileThatIsKeptDoesNotBlockTheReset() async throws {
        let world = populatedWorld()
        world.mappedProfiles = ["Profile 2"]
        try await world.reset().clear(LocalResetRequest())
        XCTAssertTrue(world.chromiumProfiles.contains("Profile 2"))
    }

    // MARK: - Steps

    func testTheStepsRunInOrderAndReachThePostconditions() async throws {
        let world = populatedWorld()
        world.spaces.removeFirst()   // the user had deleted default-space
        world.roleHolder = "work"

        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertEqual(world.steps, ["role", "recreate", "wipe", "space side", "space work",
                                     "profile Profile 2", "unmap gone", "settings"])
        XCTAssertEqual(world.spaces, [SpaceRow(spaceId: Self.defaultSpace, profileId: Self.defaultProfile)])
        XCTAssertEqual(world.roleHolder, Self.defaultSpace)
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile])
        XCTAssertEqual(world.storedProfiles, [Self.defaultProfile])
        XCTAssertTrue(world.spaceMappings.isEmpty)
        XCTAssertTrue(world.settingsAdoptionCleared)
        XCTAssertTrue(try world.reset().inventory().isEmpty)
    }

    /// A kept extra Profile ends with zero Spaces; no placeholder is created for it.
    func testAKeptProfileIsLeftWithoutSpaces() async throws {
        let world = populatedWorld()
        try await world.reset().clear(LocalResetRequest())
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile, "Profile 2"])
        XCTAssertEqual(world.spaces.map(\.spaceId), [Self.defaultSpace])
        XCTAssertFalse(world.steps.contains("recreate"))
    }

    /// A Profile chosen for deletion loses its agent Spaces; a kept Profile's agent Spaces stay.
    func testAgentSpacesGoWithTheirDeletedProfileOnly() async throws {
        let world = populatedWorld()
        world.chromiumProfiles.insert("Profile 3")
        world.agentSpaces = [SpaceRow(spaceId: "agent-doomed", profileId: "Profile 2"),
                             SpaceRow(spaceId: "agent-kept", profileId: "Profile 3"),
                             SpaceRow(spaceId: "agent-default", profileId: Self.defaultProfile)]

        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertEqual(world.agentSpaces.map(\.spaceId), ["agent-kept", "agent-default"])
        let order = world.steps
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "space agent-doomed")),
                          try XCTUnwrap(order.firstIndex(of: "profile Profile 2")))
    }

    func testARunningTaskInAnAgentSpaceOfADeletedProfileRefuses() async {
        let world = populatedWorld()
        world.agentSpaces = [SpaceRow(spaceId: "agent-doomed", profileId: "Profile 2")]
        world.agentTaskSpaces = ["agent-doomed"]
        await assertRefusal(.agentTaskRunning, world, Self.deleteProfile2)
    }

    func testTheDefaultSpaceIsReboundAwayFromAProfileBeingDeleted() async throws {
        let world = populatedWorld()
        world.spaces[0] = SpaceRow(spaceId: Self.defaultSpace, profileId: "Profile 2")

        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertEqual(Array(world.steps.prefix(3)), ["role", "rebind", "wipe"])
        XCTAssertEqual(world.spaces, [SpaceRow(spaceId: Self.defaultSpace, profileId: Self.defaultProfile)])
    }

    /// A rebind whose windows did not settle stops the reset with its own error, before anything
    /// else is deleted; a rerun converges.
    func testARebindThatDidNotSettleIsATypedFailure() async throws {
        let world = populatedWorld()
        world.spaces[0] = SpaceRow(spaceId: Self.defaultSpace, profileId: "Profile 2")
        world.rebindOutcome = .windowsNotSettled

        await assertFailure(.defaultSpaceRebindRefused(.windowsNotSettled), world, Self.deleteProfile2)
        XCTAssertEqual(world.steps, ["role", "rebind"])

        world.rebindOutcome = .rebound
        try await world.reset().clear(Self.deleteProfile2)
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile])
    }

    /// A refused Space deletion stops the reset before any Profile goes; the rerun skips what was
    /// done and converges.
    func testARerunAfterAFailureMidwayConverges() async throws {
        let world = populatedWorld()
        world.refuseSpaceDeletion = ["work": .failed]

        await assertFailure(.spaceDeletionRefused(spaceId: "work", outcome: .failed), world, Self.deleteProfile2)
        XCTAssertEqual(world.spaces.map(\.spaceId), [Self.defaultSpace, "work"], "side was already deleted")
        XCTAssertTrue(world.chromiumProfiles.contains("Profile 2"), "Profiles go only after every Space")

        world.steps.removeAll()
        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertEqual(world.steps, ["role", "space work", "profile Profile 2", "unmap gone", "settings"],
                       "nothing finished is redone: no wipe and no second deletion of side")
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile])

        world.steps.removeAll()
        try await world.reset().clear(Self.deleteProfile2)
        XCTAssertEqual(world.steps, ["role", "settings"], "a completed reset reruns as a no-op")
    }

    /// A Space deletion that does not settle in time is a typed failure, and nothing after it runs.
    /// The deletion may still finish behind it: a rerun meanwhile is refused as pending, and once it
    /// finished, a rerun converges.
    func testASpaceDeletionTimeoutIsTypedAndARerunConverges() async throws {
        let world = populatedWorld()
        world.refuseSpaceDeletion = ["side": .timedOut]

        await assertFailure(.spaceDeletionRefused(spaceId: "side", outcome: .timedOut), world, Self.deleteProfile2)
        XCTAssertTrue(world.chromiumProfiles.contains("Profile 2"))

        world.refuseSpaceDeletion = ["side": .refusedAlreadyPending]
        await assertFailure(.spaceDeletionRefused(spaceId: "side", outcome: .refusedAlreadyPending), world,
                            Self.deleteProfile2)

        world.spaces.removeAll { $0.spaceId == "side" }   // the late deletion finished
        try await world.reset().clear(Self.deleteProfile2)
        XCTAssertEqual(world.spaces.map(\.spaceId), [Self.defaultSpace])
        XCTAssertEqual(world.chromiumProfiles, [Self.defaultProfile])
    }

    func testEverySpaceDeletionRefusalStopsTheReset() async {
        for outcome in [SpaceManager.PairingResetSpaceDeletion.refusedNotUserSpace, .refusedLastUserSpace,
                        .refusedAlreadyPending, .refusedStoreMismatch, .refusedImportInProgress,
                        .refusedAgentTaskRunning, .failed, .timedOut] {
            let world = populatedWorld()
            world.refuseSpaceDeletion = ["side": outcome]
            await assertFailure(.spaceDeletionRefused(spaceId: "side", outcome: outcome), world)
        }
    }

    /// A window still bound to a Profile about to be deleted fails the reset before step 6.
    func testALiveWindowOnADeletedProfileFailsClosedBeforeTheDeletion() async {
        let world = populatedWorld()
        world.stuckWindows = ["Profile 2"]
        await assertFailure(.liveWindowsOnDeletedProfile("Profile 2"), world, Self.deleteProfile2)
        XCTAssertFalse(world.steps.contains("profile Profile 2"))
        XCTAssertTrue(world.chromiumProfiles.contains("Profile 2"))
    }

    /// A Space row that still binds the Profile (the backstop right before the deletion).
    func testAProfileStillInUseFailsClosed() async {
        let world = populatedWorld()
        world.refuseSpaceDeletion = ["side": .notFound]   // reported gone, but the row stays
        await assertFailure(.profileInUse("Profile 2"), world, Self.deleteProfile2)
        XCTAssertTrue(world.chromiumProfiles.contains("Profile 2"))
    }

    /// The Chromium Profile went, the process stopped before its store rows did: the rerun sweeps
    /// the rows and the postconditions hold.
    func testACrashBetweenTheChromiumDeletionAndTheRowCleanupConvergesOnRerun() async throws {
        let world = populatedWorld()
        world.crashAfterChromiumDeletion = ["Profile 2"]
        do {
            try await world.reset().clear(Self.deleteProfile2)
            XCTFail("expected the simulated crash")
        } catch {}
        XCTAssertFalse(world.chromiumProfiles.contains("Profile 2"))
        XCTAssertTrue(world.storedProfiles.contains("Profile 2"))

        world.steps.removeAll()
        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertTrue(world.steps.contains("rows Profile 2"))
        XCTAssertFalse(world.steps.contains("profile Profile 2"), "the Chromium deletion is not repeated")
        XCTAssertEqual(world.storedProfiles, [Self.defaultProfile])
    }

    func testAFailedRowCleanupIsAnErrorNotSuccess() async {
        let world = populatedWorld()
        world.rowCleanupFails = true
        await assertFailure(.profileRowCleanupFailed("Profile 2"), world, Self.deleteProfile2)
    }

    func testAProfileDeletionFailureCarriesItsReason() async {
        let world = populatedWorld()
        world.profileDeletionFailure = .reason("bridge unavailable")
        await assertFailure(.profileDeletionFailed("Profile 2", reason: "bridge unavailable"), world, Self.deleteProfile2)
    }

    /// Nothing more is deleted once the device paired or the session went away mid-reset.
    func testPairingDuringTheResetStopsFurtherDeletion() async {
        let world = populatedWorld()
        var calls = 0
        let reset = PhiLocalDataReset(
            sync: PhiLocalDataReset.SyncAccess(
                isPaired: { calls += 1; return calls > 2 },
                isSessionUsable: { true }, syncHistory: { [] }, isProfileMapped: { _ in false },
                spaceMappings: { [:] }, removeSpaceMapping: { _ in }, clearSettingsAdoption: {}),
            local: world.localAccess())
        do {
            try await reset.clear(LocalResetRequest())
            XCTFail("expected the reset to stop")
        } catch let error as PhiLocalDataResetError {
            XCTAssertEqual(error, .paired)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertFalse(world.steps.contains { $0.hasPrefix("space ") })
    }

    // MARK: - Postconditions and inventory

    func testPostconditionsCatchAStepThatReportedSuccessWithoutEffect() async {
        let world = populatedWorld()
        world.brokenWipe = true
        do {
            try await world.reset().clear(LocalResetRequest())
            XCTFail("expected a postcondition failure")
        } catch let error as PhiLocalDataResetError {
            guard case .postconditionFailed = error else { return XCTFail("unexpected \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTheInventoryMatchesWhatClearRemoves() async throws {
        let world = populatedWorld()
        let before = try world.reset().inventory(deleting: ["Profile 2", Self.defaultProfile, "missing"])
        XCTAssertEqual(before, LocalPhiInventory(nonDefaultSpaceIds: ["side", "work"], bookmarks: 12,
                                                 pinnedTabs: 3, urlRules: 2, profileIdsToDelete: ["Profile 2"]))

        try await world.reset().clear(Self.deleteProfile2)

        XCTAssertTrue(try world.reset().inventory(deleting: ["Profile 2"]).isEmpty)
    }

    func testAFreshInstallHasNothingToReplace() throws {
        let world = World()
        world.spaces = [SpaceRow(spaceId: Self.defaultSpace, profileId: Self.defaultProfile)]
        XCTAssertTrue(try world.reset().inventory().isEmpty)
    }

    func testAFailedCountReadIsNeverAnEmptyInventory() {
        let world = populatedWorld()
        var access = world.localAccess()
        access.counts = { throw LocalStoreWriteError.storeUnavailable }
        let reset = PhiLocalDataReset(sync: world.syncAccess(), local: access)
        XCTAssertThrowsError(try reset.inventory()) {
            XCTAssertEqual($0 as? PhiLocalDataResetError, .inventoryUnavailable)
        }
    }
}
