// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The Peek panel insets itself inside the focused tab's page card. A tab that
/// closes takes its card with it, so the panel coming back over the next tab
/// can be laid out before that tab's card is mounted. It has to re-fit once the
/// card arrives, or it keeps the larger size of the container around the card.
@MainActor
final class PeekPanelSizeTests: XCTestCase {
    private var store: LocalStore!
    private var directory: URL!
    private var accountDirectory: URL!
    private var previousLayout: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextId = 123461100
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []
    private var wrappers: [PageColorTestWebContentWrapper] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let account = Account(userID: "peek-size-test-\(UUID().uuidString)")
        accountDirectory = account.userDataStorage
        store = LocalStore(account: account, storeDirectoryURL: directory, presentsCompatibilityAlerts: false)
        account.localStorage = store
        let context = try XCTUnwrap(store.getMainContext())
        context.insert(ProfileModel(profileId: LocalStore.defaultProfileId))
        context.insert(SpaceModel(spaceId: "first", profileId: LocalStore.defaultProfileId,
            name: "first", colorHex: "#AAAAAA", iconName: "target", sortOrder: 0))
        try context.save()
        manager.bind(to: store.account)
        await drainMainQueue()
    }

    override func tearDown() async throws {
        manager.discardSpacePrewarm()
        for slot in slots { slot.closeShellIfPresent() }
        slots.removeAll()
        webViews.removeAll()
        wrappers.removeAll()
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

    /// The close leaves no page card behind, unlike a plain tab switch.
    func testThePeekKeepsItsSizeWhenAnotherTabClosesAndFocusReturnsToItsOpener() throws {
        let fixture = try makeSessionWithPeek()
        let originalFrame = screenFrame(of: fixture.panel.pageCardView)
        XCTAssertLessThan(originalFrame.height, fixture.containerHeight,
                          "precondition: the card the peek sits in is shorter than the container")

        let (closing, closingView) = makeTab()
        fixture.state.tabs = [fixture.opener, closing]
        fixture.state.updateNormalTabs()
        fixture.state.focusingTab = closing
        waitUntilMounted(closingView)
        XCTAssertTrue(fixture.panel.pageCardView.isHiddenOrHasHiddenAncestor,
                      "precondition: the peek hides while its opener is not focused")

        fixture.state.applyTabsRemoved([closing.guid])
        settle()
        XCTAssertNil(fixture.container.currentPageCardView,
                     "precondition: the closed tab took its card with it")

        fixture.state.handleChromiumActiveTabChanged(fixture.opener.guid)
        settle()

        XCTAssertFalse(fixture.panel.pageCardView.isHiddenOrHasHiddenAncestor)
        assertEqual(screenFrame(of: fixture.panel.pageCardView), originalFrame)
    }

    func testThePeekKeepsItsSizeWhenSwitchingBackToItsOpener() throws {
        let fixture = try makeSessionWithPeek()
        let originalFrame = screenFrame(of: fixture.panel.pageCardView)

        let (other, otherView) = makeTab()
        fixture.state.tabs = [fixture.opener, other]
        fixture.state.updateNormalTabs()
        fixture.state.focusingTab = other
        waitUntilMounted(otherView)

        fixture.state.focusingTab = fixture.opener
        settle()

        XCTAssertFalse(fixture.panel.pageCardView.isHiddenOrHasHiddenAncestor)
        assertEqual(screenFrame(of: fixture.panel.pageCardView), originalFrame)
    }

    /// Mounting a page while the peek is hidden must not bring the peek back.
    func testMountingAnotherTabLeavesTheHiddenPeekHidden() throws {
        let fixture = try makeSessionWithPeek()

        let (first, firstView) = makeTab()
        let (second, secondView) = makeTab()
        fixture.state.tabs = [fixture.opener, first, second]
        fixture.state.updateNormalTabs()
        fixture.state.focusingTab = first
        waitUntilMounted(firstView)

        fixture.state.focusingTab = second
        waitUntilMounted(secondView)

        XCTAssertTrue(fixture.panel.pageCardView.isHiddenOrHasHiddenAncestor)
    }

    // MARK: - Helpers

    private struct Fixture {
        let state: BrowserState
        let session: SpaceSessionController
        let container: WebContentContainerViewController
        let panel: PeekPanelController
        let opener: Tab
        let containerHeight: CGFloat
    }

    /// A shell presenting one Space whose focused tab carries a peek on screen.
    private func makeSessionWithPeek() throws -> Fixture {
        let slot = SpaceWindowSlot(manager: manager, initialSpaceId: "first")
        slot.ensureShell(initialFrame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        slots.append(slot)
        nextId += 1
        let state = UnseededBrowserState(windowId: nextId, localStore: store,
            profileId: LocalStore.defaultProfileId, spaceId: "first")
        let (opener, openerView) = makeTab()
        state.tabs = [opener]
        state.updateNormalTabs()
        state.focusingTab = opener
        let session = SpaceSessionController(window: slot.shell!.window, windowId: state.windowId,
            profileId: state.profileId, spaceId: "first", account: store.account,
            slot: slot, browserState: state, dormant: true)
        slot.registerWindow(session, for: "first")
        XCTAssertTrue(session.isPresented, "precondition: the Space is presented")
        slot.shell?.window.orderFront(nil)
        waitUntilMounted(openerView)

        let (peek, peekView) = makeTab()
        state.peekState.present(peek, openerTabId: opener.guid)
        waitUntilMounted(peekView)
        let panel = try XCTUnwrap(session.peekPanelControllerIfLoaded)
        let container = session.mainSplitViewController.webContentContainerViewController
        return Fixture(state: state, session: session, container: container, panel: panel,
                       opener: opener, containerHeight: container.view.bounds.height)
    }

    private func makeTab() -> (Tab, NSView) {
        nextId += 1
        let webView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        webViews.append(webView)
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://e\(nextId).example/")
        wrapper.nativeView = webView
        wrappers.append(wrapper)
        return (Tab(guid: nextId, url: wrapper.urlString, isActive: false, index: 0,
                    webContentView: wrapper), webView)
    }

    private func screenFrame(of view: NSView) -> NSRect {
        view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
    }

    private func assertEqual(_ actual: NSRect, _ expected: NSRect,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, "height", file: file, line: line)
    }

    private func waitUntilMounted(_ webView: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while webView.window == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotNil(webView.window, "precondition: the page is mounted", file: file, line: line)
        settle()
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }
}

/// These Browsers have their tabs already, and must never seed one.
private final class UnseededBrowserState: BrowserState {
    override func createQuickLookupTab(customGuid: String? = nil) {}
}
