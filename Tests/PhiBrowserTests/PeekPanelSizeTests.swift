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
    private var previousEdgeToEdge: Any?
    private var slots: [SpaceWindowSlot] = []
    private let manager = SpaceManager(observeAccountChanges: false)
    private var nextId = 123461100
    /// Held here: a wrapper's `nativeView` is weak.
    private var webViews: [NSView] = []
    private var wrappers: [PageColorTestWebContentWrapper] = []

    override func setUp() async throws {
        previousLayout = UserDefaults.standard.object(forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        previousEdgeToEdge = UserDefaults.standard.object(forKey: "edgeToEdgeWebContent")
        UserDefaults.standard.set(false, forKey: "edgeToEdgeWebContent")
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
        UserDefaults.standard.set(previousEdgeToEdge, forKey: "edgeToEdgeWebContent")
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

    func testEdgeToEdgeSettingRelayoutsAnOpenPeekAndRestoresItsFrame() throws {
        let fixture = try makeSessionWithPeek()
        let page = try XCTUnwrap(fixture.container.currentPageCardView)
        let originalPage = screenFrame(of: page)
        let originalPeek = screenFrame(of: fixture.panel.pageCardView)
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        settle()
        fixture.container.view.layoutSubtreeIfNeeded()
        fixture.panel.relayoutIfVisible()
        let expandedPage = screenFrame(of: page)
        XCTAssertEqual(expandedPage.maxX, originalPage.maxX + 8, accuracy: 0.5)
        XCTAssertEqual(expandedPage.minY, originalPage.minY - 8, accuracy: 0.5)
        XCTAssertEqual(expandedPage.maxY, originalPage.maxY + 8, accuracy: 0.5)
        XCTAssertGreaterThan(screenFrame(of: fixture.panel.pageCardView).height, originalPeek.height)
        XCTAssertGreaterThan(page.layer?.cornerRadius ?? 0, 0)

        fixture.state.isInFullScreenMode = true
        settle()
        XCTAssertEqual(page.layer?.cornerRadius, 0)
        fixture.state.isInFullScreenMode = false
        settle()
        XCTAssertGreaterThan(page.layer?.cornerRadius ?? 0, 0)

        UserDefaults.standard.set(false, forKey: "edgeToEdgeWebContent")
        settle()
        fixture.container.view.layoutSubtreeIfNeeded()
        fixture.panel.relayoutIfVisible()
        assertEqual(screenFrame(of: page), originalPage)
        assertEqual(screenFrame(of: fixture.panel.pageCardView), originalPeek)
    }

    func testComfortableRemovesThreeMarginsAndPreservesTopThroughFullscreenRestore() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        let fixture = try makeSessionWithPeek()
        let page = try XCTUnwrap(fixture.container.currentPageCardView)
        let bar = try XCTUnwrap(fixture.container.children.compactMap { $0 as? TabStripBarController }.first).view
        let originalPage = screenFrame(of: page)
        let originalBar = screenFrame(of: bar)
        let originalPeek = screenFrame(of: fixture.panel.pageCardView)
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        settle()
        fixture.container.view.layoutSubtreeIfNeeded()
        fixture.panel.relayoutIfVisible()
        let expandedPage = screenFrame(of: page)
        XCTAssertEqual(expandedPage.minX, originalPage.minX - 8, accuracy: 0.5)
        XCTAssertEqual(expandedPage.maxX, originalPage.maxX + 8, accuracy: 0.5)
        XCTAssertEqual(expandedPage.minY, originalPage.minY - 8, accuracy: 0.5)
        XCTAssertEqual(expandedPage.maxY, originalPage.maxY, accuracy: 0.5)
        assertEqual(screenFrame(of: bar), originalBar)
        XCTAssertGreaterThan(page.layer?.cornerRadius ?? 0, 0)
        let expandedPeek = screenFrame(of: fixture.panel.pageCardView)
        XCTAssertGreaterThan(expandedPeek.width, originalPeek.width)
        XCTAssertGreaterThan(expandedPeek.height, originalPeek.height)

        fixture.state.isInFullScreenMode = true
        settle()
        XCTAssertEqual(page.layer?.cornerRadius, 0)
        XCTAssertEqual(screenFrame(of: page).maxY, expandedPage.maxY + 6, accuracy: 0.5)
        fixture.state.isInFullScreenMode = false
        settle()
        assertEqual(screenFrame(of: page), expandedPage)
        assertEqual(screenFrame(of: bar), originalBar)
        XCTAssertGreaterThan(page.layer?.cornerRadius ?? 0, 0)

        UserDefaults.standard.set(false, forKey: "edgeToEdgeWebContent")
        settle()
        fixture.panel.relayoutIfVisible()
        assertEqual(screenFrame(of: page), originalPage)
        assertEqual(screenFrame(of: fixture.panel.pageCardView), originalPeek)
    }

    func testGeometryChangeWhileExpansionAwaitsMountDropsOnlyTheStaleSnapshot() throws {
        let fixture = try makeSessionWithPeek()
        let peek = try XCTUnwrap(fixture.state.peekState.peek(forOpener: fixture.opener.guid))
        fixture.panel.prepareToExpand(tabId: peek.guid)
        XCTAssertEqual(overlays(in: fixture).count, 2, "live Peek plus its painted cover")
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        settle()
        XCTAssertEqual(overlays(in: fixture).count, 1, "discard only the stale snapshot before adoption")
        adopt(peek, in: fixture)
        settle()
        XCTAssertTrue(overlays(in: fixture).isEmpty, "the pending mount still removes the live Peek")
        XCTAssertNotNil(peek.webContentView?.window)
    }

    func testComfortableFullscreenExpansionSquaresItsSnapshotAndResizeCancelsTheFlight() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        try assertFullscreenExpansionAndResize()
    }

    func testFullscreenExpansionSquaresItsSnapshotAndResizeCancelsTheFlight() throws {
        try assertFullscreenExpansionAndResize()
    }

    private func assertFullscreenExpansionAndResize() throws {
        let fixture = try makeSessionWithPeek()
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        fixture.state.isInFullScreenMode = true
        settle()
        let peek = try XCTUnwrap(fixture.state.peekState.peek(forOpener: fixture.opener.guid))
        attachImage(of: fixture.container.view, named: "Fullscreen Peek before expansion")
        fixture.panel.prepareToExpand(tabId: peek.guid)
        XCTAssertEqual(overlays(in: fixture).count, 2)
        adopt(peek, in: fixture)
        let deadline = Date().addingTimeInterval(1)
        var flying: PageOverlayView?
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            flying = overlays(in: fixture).first { $0.layer?.animation(forKey: "phiPeekExpandIntoTab") != nil }
        } while flying == nil && Date() < deadline
        let snapshot = try XCTUnwrap(flying, "expansion must exercise the real CA flight")
        let card = try XCTUnwrap(snapshot.subviews.first)
        let image = try XCTUnwrap(card.subviews.first)
        XCTAssertEqual(card.layer?.cornerRadius, 0)
        XCTAssertEqual(image.layer?.cornerRadius, 0)
        XCTAssertNotNil(image.layer?.animation(forKey: "phiPeekExpandCorners"))
        attachImage(of: fixture.container.view, named: "Fullscreen Peek expansion")
        let window = try XCTUnwrap(fixture.container.view.window)
        window.setContentSize(NSSize(width: 1100, height: 760))
        settle()
        XCTAssertNil(snapshot.superview, "a resize must drop the old destination frame")
        XCTAssertTrue(overlays(in: fixture).isEmpty)
        XCTAssertEqual(fixture.container.currentPageCardView?.layer?.cornerRadius, 0)
    }

    func testClosingThenReopeningPeekLeavesNoAnimationCover() throws {
        let fixture = try makeSessionWithPeek()
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        settle()
        for _ in 0..<2 {
            let peek = try XCTUnwrap(fixture.state.peekState.peek(forOpener: fixture.opener.guid))
            fixture.panel.prepareToClose(tabId: peek.guid)
            XCTAssertEqual(overlays(in: fixture).count, 2)
            fixture.state.peekState.removePeek(forOpener: fixture.opener.guid)
            let (replacement, view) = makeTab()
            fixture.state.peekState.present(replacement, openerTabId: fixture.opener.guid)
            waitUntilMounted(view)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(overlays(in: fixture).count, 1)
            XCTAssertTrue(fixture.panel.isHosting(replacement))
            XCTAssertGreaterThan(fixture.panel.pageCardView.layer?.cornerRadius ?? 0, 0)
        }
    }

    func testTrafficLightsFollowBalancedPageHeaderWhenEdgeToEdgeChanges() throws {
        let fixture = try makeSessionWithPeek()
        fixture.state.peekState.removePeek(forOpener: fixture.opener.guid)
        settle()
        let window = try XCTUnwrap(fixture.container.view.window)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        func centerFromTop() -> CGFloat {
            window.frame.height - close.convert(close.bounds, to: nil).midY
        }
        XCTAssertEqual(centerFromTop(), 27.5, accuracy: 0.01)
        UserDefaults.standard.set(true, forKey: "edgeToEdgeWebContent")
        settle()
        fixture.container.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let header = try XCTUnwrap(descendants(fixture.container.view).compactMap { $0 as? WebContentHeader }.first)
        XCTAssertEqual(close.convert(close.bounds, to: nil).midY,
                       header.convert(header.bounds, to: nil).midY, accuracy: 0.5)
        XCTAssertEqual(centerFromTop(), 20, accuracy: 0.01)
        XCTAssertEqual(close.convert(close.bounds, to: nil).midX, 22, accuracy: 0.01)

        fixture.state.isInFullScreenMode = true
        settle()
        fixture.state.isInFullScreenMode = false
        settle()
        XCTAssertEqual(centerFromTop(), 20, accuracy: 0.01)
        PhiPreferences.GeneralSettings.saveLayoutMode(.performance)
        settle()
        XCTAssertEqual(centerFromTop(), 20, accuracy: 0.01)
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        settle()
        XCTAssertEqual(centerFromTop(), 22, accuracy: 0.01)
        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        settle()
        XCTAssertEqual(centerFromTop(), 20, accuracy: 0.01)
        UserDefaults.standard.set(false, forKey: "edgeToEdgeWebContent")
        settle()
        XCTAssertEqual(centerFromTop(), 27.5, accuracy: 0.01)
    }

    private func overlays(in fixture: Fixture) -> [PageOverlayView] {
        fixture.container.view.subviews.compactMap { $0 as? PageOverlayView }
    }

    private func adopt(_ peek: Tab, in fixture: Fixture) {
        fixture.state.tabs.append(peek)
        fixture.state.updateNormalTabs()
        fixture.state.focusingTab = peek
        fixture.state.peekState.removePeek(forOpener: fixture.opener.guid)
    }

    private func attachImage(of view: NSView, named name: String) {
        guard let image = WebContentSnapshotter.captureOnScreen(view, resolution: .bestResolution) else { return }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

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
