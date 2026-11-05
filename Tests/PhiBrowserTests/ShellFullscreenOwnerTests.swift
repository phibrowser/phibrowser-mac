// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The hosted shell's AppKit fullscreen belongs to the Space whose request
/// put it there: when that Space leaves the shell with its page fullscreen,
/// Chromium takes the page out of fullscreen and asks for the window to
/// follow, and the shell does, though the Space is in the background by
/// then. The user's own fullscreen belongs to no Space and stays. AppKit is
/// stood in for: the tests count the toggles the slot sends and post the
/// will-change and settle callbacks themselves.
@MainActor
final class ShellFullscreenOwnerTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextWindowId = 123457789
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "shell-fullscreen-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        // A switch goes only to a Space the manager knows.
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        for (index, spaceId) in ["first", "second", "third"].enumerated() {
            context.insert(SpaceModel(spaceId: spaceId, profileId: LocalStore.defaultProfileId,
                name: spaceId, colorHex: "#AAAAAA", iconName: "target", sortOrder: index))
        }
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        await drainMainQueue()
        try await store.closeForAccountDirectoryRemoval()
        store = nil
        for url in [directory, accountDirectory].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.set(previousLayout, forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        try await super.tearDown()
    }

    func testARequestedEnterHasAnOwnerAndAUserEnterHasNone() throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first", "second"])
        let (first, second) = (sessions[0], sessions[1])
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }

        // A page in the presented Space asks for fullscreen.
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        XCTAssertEqual(toggles, 1, "precondition: the presented Space's request toggles the shell")
        transition(slot, toFullScreen: true)
        slot.activate(spaceId: second.spaceId, animated: false)
        XCTAssertTrue(slot.visibleController === second, "precondition: the switch presented the second Space")
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 2, "the Space that asked for fullscreen takes the shell out of it from the background")

        // The user enters fullscreen on the shell itself.
        transition(slot, toFullScreen: false)
        slot.activate(spaceId: first.spaceId, animated: false)
        transition(slot, toFullScreen: true)
        slot.activate(spaceId: second.spaceId, animated: false)
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 2, "the user's fullscreen is no background Space's to leave")
    }

    func testOnlyTheOwningSpaceLeavingInTheBackgroundTakesTheShellOut() throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first", "second", "third"])
        let (first, second, third) = (sessions[0], sessions[1], sessions[2])
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        transition(slot, toFullScreen: true)
        slot.activate(spaceId: third.spaceId, animated: false)
        XCTAssertTrue(slot.visibleController === third, "precondition: the switch presented the third Space")

        slot.sessionRequestedShellFullscreen(second, fullscreen: false)
        XCTAssertEqual(toggles, 1, "another background Space has no say over the shell")
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 2, "the owning Space's exit takes the shell out")

        transition(slot, toFullScreen: false)
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 2, "a shell already out of fullscreen is not toggled back in")
    }

    /// The switch lands inside AppKit's enter animation: the entering
    /// Space's Browser takes the shell's fullscreen and echoes it back
    /// before the enter settles, AppKit drops a toggle sent from inside its
    /// did-enter callback, and a window leaving fullscreen that early can
    /// come back at the screen's visible frame.
    func testAnExitDuringTheEnterOutlivesTheEchoAndTogglesOneTurnAfterTheSettle() async throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first", "second"])
        let (first, second) = (sessions[0], sessions[1])
        let shell = try XCTUnwrap(slot.shell)
        let windowed = shell.window.frame
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        slot.shellFullScreenWillChange(isFullScreen: true)
        slot.activate(spaceId: second.spaceId, animated: false)
        XCTAssertTrue(slot.visibleController === second, "precondition: the switch presented the second Space")

        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 1, "nothing toggles while the enter runs")
        slot.sessionRequestedShellFullscreen(second, fullscreen: true)
        slot.shellIsFullScreenForTesting = true
        slot.shellFullScreenDidSettle()
        XCTAssertEqual(toggles, 1, "no toggle from inside the settle")
        await drainMainQueue()
        XCTAssertEqual(toggles, 2, "the shell leaves fullscreen one turn after the enter settles")

        shell.window.setFrame(NSRect(x: 40, y: 40, width: 800, height: 600), display: false)
        transition(slot, toFullScreen: false)
        XCTAssertEqual(shell.window.frame, windowed, "the exit's settle puts the shell back where it was")
    }

    /// The presented Space's page leaves fullscreen while the shell's enter
    /// animation runs (a video entering picture-in-picture, a script's
    /// exitFullscreen): Chromium's exit lands mid-transition and is held for
    /// the settle. AppKit drops a toggle sent from inside its did-enter
    /// callback, so the held exit toggles one turn later, or the shell stays
    /// fullscreen around a page that no longer is.
    func testAPresentedSessionsExitDuringTheEnterTogglesOneTurnAfterTheSettle() async throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first"])
        let first = sessions[0]
        let shell = try XCTUnwrap(slot.shell)
        let windowed = shell.window.frame
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        XCTAssertEqual(toggles, 1, "precondition: the presented Space's request toggles the shell")
        slot.shellFullScreenWillChange(isFullScreen: true)

        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 1, "nothing toggles while the enter runs")
        slot.shellIsFullScreenForTesting = true
        slot.shellFullScreenDidSettle()
        XCTAssertEqual(toggles, 1, "no toggle from inside the settle")
        await drainMainQueue()
        XCTAssertEqual(toggles, 2, "the shell leaves fullscreen one turn after the enter settles")

        shell.window.setFrame(NSRect(x: 40, y: 40, width: 800, height: 600), display: false)
        transition(slot, toFullScreen: false)
        XCTAssertEqual(shell.window.frame, windowed, "the exit's settle puts the shell back where it was")
    }

    /// A page asking for fullscreen again between the enter's settle and the
    /// held exit completes at once, which stands the exit down.
    func testAPresentedSessionsReentryBeforeTheHeldExitStandsItDown() async throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first"])
        let first = sessions[0]
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        slot.shellFullScreenWillChange(isFullScreen: true)
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        slot.shellIsFullScreenForTesting = true
        slot.shellFullScreenDidSettle()

        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        await drainMainQueue()
        XCTAssertEqual(toggles, 1, "the page's new request keeps the shell fullscreen")
    }

    /// AppKit moves a fullscreen window to another display by leaving
    /// fullscreen and entering it again there; neither half changes whose
    /// fullscreen it is. The halves are posted directly (the settle between
    /// them toggles the window itself), and the owner is read through the
    /// restore snapshot.
    func testAUserReenterHasNoOwnerAndADisplayMoveKeepsTheOwnerItHad() throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first", "second"])
        let (first, second) = (sessions[0], sessions[1])
        var toggles = 0
        slot.toggleShellFullScreenForTesting = { toggles += 1 }
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        transition(slot, toFullScreen: true)
        // The user leaves and enters again: the fullscreen is theirs now.
        transition(slot, toFullScreen: false)
        transition(slot, toFullScreen: true)
        slot.activate(spaceId: second.spaceId, animated: false)
        slot.sessionRequestedShellFullscreen(first, fullscreen: false)
        XCTAssertEqual(toggles, 1, "the user's enter after the exit belongs to nobody")

        // A page's fullscreen moved to another display stays the page's.
        let (moving, movingSessions) = try makeSlot(spaceIds: ["third"])
        let owner = movingSessions[0]
        let tab = try XCTUnwrap(owner.browserState.focusingTab)
        moving.toggleShellFullScreenForTesting = {}
        moving.sessionRequestedShellFullscreen(owner, fullscreen: true)
        moving.shellFullScreenWillChange(isFullScreen: true)
        tab.isInContentFullscreen = true
        try requestDisplayMove(moving, by: owner)
        moving.shellFullScreenWillChange(isFullScreen: false)
        XCTAssertFalse(moving.snapshotIsFullScreen(), "the move's exit leaves the page's fullscreen its owner")
        moving.shellFullScreenWillChange(isFullScreen: true)
        XCTAssertFalse(moving.snapshotIsFullScreen(), "so does the move's enter")
        tab.isInContentFullscreen = false

        // The user's fullscreen moved by a page stays the user's.
        let (userSlot, userSessions) = try makeSlot(spaceIds: ["fourth"])
        let page = userSessions[0]
        let pageTab = try XCTUnwrap(page.browserState.focusingTab)
        userSlot.toggleShellFullScreenForTesting = {}
        userSlot.shellFullScreenWillChange(isFullScreen: true)
        pageTab.isInContentFullscreen = true
        try requestDisplayMove(userSlot, by: page)
        userSlot.shellFullScreenWillChange(isFullScreen: false)
        userSlot.shellFullScreenWillChange(isFullScreen: true)
        XCTAssertTrue(userSlot.snapshotIsFullScreen(), "the move's enter does not hand the user's fullscreen to the page")
        pageTab.isInContentFullscreen = false
    }

    /// A quit with a page in fullscreen freezes the restore record before
    /// Chromium's exit from it could reach the record, and the next launch
    /// came up fullscreen.
    func testAPageFullscreenIsNotRecordedForTheNextLaunch() throws {
        let (slot, sessions) = try makeSlot(spaceIds: ["first"])
        let first = sessions[0]
        let tab = try XCTUnwrap(first.browserState.focusingTab)
        slot.toggleShellFullScreenForTesting = {}
        slot.sessionRequestedShellFullscreen(first, fullscreen: true)
        slot.shellFullScreenWillChange(isFullScreen: true)

        tab.isInContentFullscreen = true
        XCTAssertFalse(slot.snapshotIsFullScreen(), "the page's fullscreen does not reopen fullscreen")
        tab.isInContentFullscreen = false
        XCTAssertTrue(slot.snapshotIsFullScreen(), "the shell's fullscreen without the page's is recorded")

        let (userSlot, userSessions) = try makeSlot(spaceIds: ["second"])
        let userTab = try XCTUnwrap(userSessions[0].browserState.focusingTab)
        userSlot.shellFullScreenWillChange(isFullScreen: true)
        userTab.isInContentFullscreen = true
        XCTAssertTrue(userSlot.snapshotIsFullScreen(), "the user's fullscreen is recorded with a page in it")
        userTab.isInContentFullscreen = false
    }

    // MARK: - Helpers

    /// A shell presenting the first of `spaceIds`, each Space with one
    /// focused tab.
    private func makeSlot(spaceIds: [String]) throws -> (SpaceWindowSlot, [SpaceSessionController]) {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: spaceIds[0])
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        slots.append(slot)
        let sessions = spaceIds.map { spaceId in
            nextWindowId += 1
            let state = UnseededBrowserState(windowId: nextWindowId, localStore: store,
                profileId: LocalStore.defaultProfileId, spaceId: spaceId)
            let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            webViews.append(webView)
            let wrapper = PageColorTestWebContentWrapper(urlString: "https://\(spaceId).example/")
            wrapper.nativeView = webView
            let tab = Tab(guid: nextWindowId, url: wrapper.urlString, isActive: true,
                index: 0, webContentView: wrapper)
            state.tabs = [tab]
            state.updateNormalTabs()
            state.focusingTab = tab
            let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
                profileId: state.profileId, spaceId: spaceId, account: store.account,
                slot: slot, browserState: state, dormant: true)
            slot.registerWindow(session, for: spaceId)
            return session
        }
        XCTAssertTrue(slot.visibleController === sessions[0], "precondition: the first Space is presented")
        XCTAssertTrue(sessions[0].isPresented, "precondition: the first Space is presented")
        return (slot, sessions)
    }

    /// Requests a move of `slot`'s shell to another display while an enter
    /// runs, which holds the move for the settle. This host has one display,
    /// so the shell is ordered out (AppKit pulls a shown titled window back
    /// onto a screen) and put off every screen to make the main one another.
    private func requestDisplayMove(_ slot: SpaceWindowSlot, by session: SpaceSessionController) throws {
        let shell = try XCTUnwrap(slot.shell)
        shell.window.orderOut(nil)
        shell.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        XCTAssertNil(shell.window.screen, "precondition: the shell is off every screen")
        let display = try XCTUnwrap(
            (NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .int64Value)
        slot.sessionRequestedShellFullscreen(session, fullscreen: true, targetDisplayId: display)
    }

    /// What AppKit does with a toggle: will-change, then the settle with the
    /// style mask flipped.
    private func transition(_ slot: SpaceWindowSlot, toFullScreen: Bool) {
        slot.shellFullScreenWillChange(isFullScreen: toFullScreen)
        slot.shellIsFullScreenForTesting = toFullScreen
        slot.shellFullScreenDidSettle()
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// A switch seeds an empty Browser with a tab through the bridge; these
/// Browsers have theirs already, and must never reach it.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}
