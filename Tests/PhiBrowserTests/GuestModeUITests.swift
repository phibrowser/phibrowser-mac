// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class GuestModeUITests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "GuestModeUITests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaultsSuiteName = nil
        defaults = nil
        super.tearDown()
    }

    func testGuestModeDisablesAIWhilePreservingNewTabBehavior() {
        let newTabPageKey = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue

        for openNewTabPage in [false, true] {
            defaults.set(true, forKey: GuestModePreferences.aiEnabledKey)
            defaults.set(openNewTabPage, forKey: newTabPageKey)

            let didApply = GuestModePreferences.disableAI(defaults: defaults)

            XCTAssertTrue(didApply)
            XCTAssertFalse(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
            XCTAssertEqual(defaults.bool(forKey: newTabPageKey), openNewTabPage)
        }
    }

    func testGuestModePersistsDisabledAIWithoutCreatingNewTabPreference() {
        let newTabPageKey = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue

        GuestModePreferences.disableAI(defaults: defaults)

        let domain = defaults.persistentDomain(forName: defaultsSuiteName)
        XCTAssertEqual(domain?[GuestModePreferences.aiEnabledKey] as? Bool, false)
        XCTAssertNil(domain?[newTabPageKey])
    }

    func testDisablingGuestAIIsIdempotent() {
        GuestModePreferences.disableAI(defaults: defaults)

        XCTAssertFalse(GuestModePreferences.disableAI(defaults: defaults))
    }

    func testPostLoginAIEnableIntentIsConsumedOnce() {
        var intent = PostLoginAIEnableIntent()

        intent.request()

        XCTAssertTrue(intent.isPending)
        XCTAssertTrue(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
        XCTAssertTrue(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
    }

    func testPostLoginAIEnableIntentCanBeCancelled() {
        var intent = PostLoginAIEnableIntent()
        defaults.set(false, forKey: GuestModePreferences.aiEnabledKey)

        intent.request()
        intent.cancel()

        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: true)
        )
        XCTAssertFalse(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
    }

    func testUnsupportedBuildCannotEnableAIFromPostLoginIntent() {
        var intent = PostLoginAIEnableIntent()
        defaults.set(true, forKey: GuestModePreferences.aiEnabledKey)
        intent.request()

        XCTAssertFalse(
            intent.enableAIIfRequested(defaults: defaults, supportsAI: false)
        )
        XCTAssertFalse(intent.isPending)
        XCTAssertFalse(defaults.bool(forKey: GuestModePreferences.aiEnabledKey))
    }

    func testLoginRequiredPolicyFailsClosedForStaleEnabledGuestAIState() {
        for surface in [
            LoginRequiredSurface.newTabPage,
            .aiChat
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: true
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true
                )
            )
        }
    }

    func testLoginRequiredPolicyGatesEveryGuestAccountSurface() {
        for surface in [
            LoginRequiredSurface.browserMemory,
            LoginRequiredSurface.connectors,
            .imChannels
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: true,
                    isPhiAIEnabled: false
                )
            )
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.shouldPresent(
                    for: surface,
                    isGuest: false,
                    isPhiAIEnabled: true
                )
            )
        }
    }

    func testBrowserMemoryURLClassificationAcceptsInternalAliasesOnly() {
        for url in [
            "chrome://memory/memory.html",
            "phi://memory/memory.html",
            "phi://MEMORY/dashboard?view=recent"
        ] {
            XCTAssertTrue(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }

        for url in [
            "https://memory/memory.html",
            "phi://memory-settings/memory.html",
            "phi://conversation/memory.html",
            nil
        ] {
            XCTAssertFalse(
                LoginRequiredPresentationPolicy.isBrowserMemoryURL(url)
            )
        }
    }

    @MainActor
    func testContinueAsGuestInvokesLifecycleCallback() {
        let controller = LoginViewController()
        controller.isGuestModeActiveProvider = { false }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertTrue(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 1)
    }

    @MainActor
    func testGuestLoginPresentationHidesAndBlocksContinueAsGuest() {
        let controller = LoginViewController()
        controller.isGuestModeActiveProvider = { true }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertFalse(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 0)
    }

    @MainActor
    func testGuestMigrationRecoveryHidesAndBlocksContinueAsGuest() {
        let controller = LoginViewController()
        controller.presentationMode = .guestMigrationRecovery
        controller.isGuestModeActiveProvider = { false }
        var callbackCount = 0
        controller.onContinueAsGuest = {
            callbackCount += 1
        }

        XCTAssertFalse(controller.shouldShowContinueAsGuest)
        controller.continueAsGuestAction()

        XCTAssertEqual(callbackCount, 0)
    }
}
