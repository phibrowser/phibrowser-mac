// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ApplicationStateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var notificationCenter: NotificationCenter!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "ApplicationStateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        notificationCenter = NotificationCenter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        notificationCenter = nil
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testFreshStateRequiresLogin() {
        let state = makeState()

        XCTAssertEqual(state.browserAccessState, .loginRequired)
        XCTAssertFalse(state.canUseBrowser)
        XCTAssertFalse(state.isGuest)
        XCTAssertFalse(state.isAuthenticated)
    }

    func testAuthenticationDisabledAlwaysUsesGuestBrowserAccess() {
        let state = makeState(supportsAuthentication: false)

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertTrue(state.canUseBrowser)
        XCTAssertTrue(state.isGuest)
        XCTAssertFalse(state.isAuthenticated)

        state.resolveInitialAccess(
            isAuthenticationBlocked: true,
            hasRecoverableLoginSession: true,
            isAuthenticated: true
        )
        state.markSignedIn()
        state.requireLogin()
        state.clearPersistedGuestChoice()

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertTrue(state.canUseBrowser)
        XCTAssertTrue(state.isGuest)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.beginGuestMigrationRecovery())
        XCTAssertFalse(state.beginGuestAccountPromotion())
        XCTAssertEqual(
            makeState(supportsAuthentication: false).browserAccessState,
            .guest
        )
    }

    func testGuestChoicePersistsAcrossInstances() {
        let state = makeState()
        state.enterGuestMode()

        let restoredState = makeState()

        XCTAssertEqual(restoredState.browserAccessState, .guest)
        XCTAssertTrue(restoredState.canUseBrowser)
        XCTAssertTrue(restoredState.isGuest)
        XCTAssertFalse(restoredState.isAuthenticated)
    }

    func testCompletedLoginClearsPersistedGuestChoice() {
        let state = makeState()
        state.enterGuestMode()
        state.markSignedIn()

        XCTAssertEqual(state.browserAccessState, .signedIn)
        XCTAssertTrue(state.canUseBrowser)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(makeState().browserAccessState, .loginRequired)
    }

    func testPersistedGuestOutranksRecoverableIncompleteLogin() {
        let state = makeState()
        state.enterGuestMode()

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: false
        )

        XCTAssertEqual(state.browserAccessState, .guest)
    }

    func testPublishedAuthenticationOutranksPersistedGuest() {
        let state = makeState()
        state.enterGuestMode()

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: true
        )

        XCTAssertEqual(state.browserAccessState, .signedIn)
    }

    func testPromotionFencePreventsAutomaticCommitUntilRebindCompletes() {
        let state = makeState()
        state.enterGuestMode()
        XCTAssertTrue(state.beginGuestAccountPromotion())

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: true
        )
        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertFalse(state.isAuthenticated)

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: false
        )

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(makeState().browserAccessState, .guest)

        state.markSignedIn()
        XCTAssertEqual(makeState().browserAccessState, .loginRequired)
    }

    func testPromotionFenceCanBeCancelledBeforeAccountPublication() {
        let state = makeState()
        state.enterGuestMode()
        XCTAssertTrue(state.beginGuestAccountPromotion())
        state.cancelGuestAccountPromotion()

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: true
        )

        XCTAssertEqual(state.browserAccessState, .signedIn)
        XCTAssertEqual(makeState().browserAccessState, .loginRequired)
    }

    func testMigrationRecoveryTemporarilySuspendsPersistedGuestAccess() {
        let state = makeState()
        state.enterGuestMode()

        XCTAssertTrue(state.beginGuestMigrationRecovery())
        XCTAssertTrue(state.isGuest)
        XCTAssertTrue(state.isGuestMigrationRecoveryInProgress)
        XCTAssertFalse(state.canUseBrowser)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(makeState().browserAccessState, .guest)

        state.resolveInitialAccess(
            isAuthenticationBlocked: false,
            hasRecoverableLoginSession: true,
            isAuthenticated: true
        )

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertFalse(state.canUseBrowser)
    }

    func testRecoveryEntryPersistsGuestWithoutTransientBrowserAccess() {
        let state = makeState()

        state.enterGuestMigrationRecovery()

        XCTAssertTrue(state.isGuest)
        XCTAssertTrue(state.isGuestMigrationRecoveryInProgress)
        XCTAssertFalse(state.canUseBrowser)
        XCTAssertEqual(makeState().browserAccessState, .guest)
    }

    func testEndingMigrationRecoveryRestoresGuestAccess() {
        let state = makeState()
        state.enterGuestMode()
        state.beginGuestMigrationRecovery()

        state.endGuestMigrationRecovery()

        XCTAssertTrue(state.isGuest)
        XCTAssertFalse(state.isGuestMigrationRecoveryInProgress)
        XCTAssertTrue(state.canUseBrowser)
    }

    func testPromotionMakesTargetDataAvailableWhileRecoveryMarkerPersists() {
        let state = makeState()
        state.enterGuestMode()
        state.beginGuestMigrationRecovery()
        XCTAssertTrue(state.beginGuestAccountPromotion())

        XCTAssertTrue(state.resumeBrowserAccessForGuestAccountPromotion())

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertTrue(state.canUseBrowser)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(makeState().browserAccessState, .guest)
    }

    // `hasRecoverableLoginSession` is false in every fenced launch:
    // `AuthManager.hasRecoverableLoginSession()` returns false while a deletion
    // fence is up, so both production call sites pass false here.
    func testAuthenticationFenceRequiresLoginWithoutAPersistedGuestChoice() {
        let state = makeState()

        state.resolveInitialAccess(
            isAuthenticationBlocked: true,
            hasRecoverableLoginSession: false,
            isAuthenticated: false
        )

        XCTAssertEqual(state.browserAccessState, .loginRequired)
        XCTAssertEqual(makeState().browserAccessState, .loginRequired)
    }

    func testAuthenticationFenceKeepsAGuestChoiceMadeAfterTheDeletion() {
        let state = makeState()
        state.enterGuestMode()

        state.resolveInitialAccess(
            isAuthenticationBlocked: true,
            hasRecoverableLoginSession: false,
            isAuthenticated: false
        )

        XCTAssertEqual(state.browserAccessState, .guest)
        XCTAssertTrue(state.canUseBrowser)
        XCTAssertFalse(
            state.isAuthenticated,
            "The fence still blocks authenticated capabilities"
        )
        XCTAssertEqual(
            makeState().browserAccessState,
            .guest,
            "The choice must survive the relaunch the fence keeps triggering"
        )
    }

    func testClearingThePersistedGuestChoiceLeavesTheCurrentStateAlone() {
        let state = makeState()
        state.enterGuestMode()

        state.clearPersistedGuestChoice()

        XCTAssertEqual(
            state.browserAccessState,
            .guest,
            "The running session keeps its access until it is transitioned"
        )
        XCTAssertEqual(makeState().browserAccessState, .loginRequired)
    }

    func testNotificationPostsOnlyForActualStateChanges() {
        let state = makeState()
        let stateChanges = expectation(description: "Browser access state changes")
        stateChanges.expectedFulfillmentCount = 3
        stateChanges.assertForOverFulfill = true
        let observer = notificationCenter.addObserver(
            forName: .browserAccessStateDidChange,
            object: state,
            queue: nil
        ) { _ in
            stateChanges.fulfill()
        }
        defer { notificationCenter.removeObserver(observer) }

        state.requireLogin()
        state.enterGuestMode()
        state.enterGuestMode()
        state.markSignedIn()
        state.markSignedIn()
        state.requireLogin()

        wait(for: [stateChanges], timeout: 0.1)
    }

    private func makeState(
        supportsAuthentication: Bool = true
    ) -> ApplicationState {
        ApplicationState(
            defaults: defaults,
            notificationCenter: notificationCenter,
            supportsAuthentication: supportsAuthentication
        )
    }
}
