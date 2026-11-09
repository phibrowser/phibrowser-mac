// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// An empty New Kiosk asks for its URL before any Kiosk exists: in a main
/// browser window on screen when there is one, otherwise in a standalone
/// panel. A submission is handed off as a URL for the Kiosk to open; any
/// dismissal opens nothing.
@MainActor
final class KioskLaunchOmniBoxTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?
    private var chromiumSelections: [Int] = []

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        chromiumSelections = []
        try await super.tearDown()
    }

    private func makeState() throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        return BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
    }

    private func makeModel() throws -> (OmniBoxViewModel, BrowserState) {
        let state = try makeState()
        let model = OmniBoxViewModel(windowState: state, keywordSearchURLBuilder: { _, _ in nil },
                                     searchEngineSpaceShortcutProvider: { false },
                                     suggestionSelector: { [weak self] line, _ in
                                         self?.chromiumSelections.append(line)
                                     })
        return (model, state)
    }

    private func deliver(_ results: [[String: Any]], query: String, to state: BrowserState) {
        state.searchSuggestionChanged.send((results, query))
        let delivered = expectation(description: "Autocomplete response delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }

    private func window(_ id: Int, main: Bool = true, onScreen: Bool = true,
                        activeSpace: Bool = true) -> KioskLaunchOmniBoxRouting.Window {
        .init(windowId: id, isMainBrowserWindow: main, isOnScreen: onScreen,
              isOnActiveSpace: activeSpace)
    }

    // MARK: - Routing

    func testVisibleMainWindowHostsTheOmniBox() {
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [window(1)],
                                             activeWindowId: 1, applicationIsHidden: false),
            .browserWindow(windowId: 1))
    }

    func testWithoutAMainWindowOnScreenTheStandalonePanelHostsIt() {
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [],
                                             activeWindowId: nil, applicationIsHidden: false),
            .standalone, "Every main window closed")
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [window(7, main: false)],
                                             activeWindowId: 7, applicationIsHidden: false),
            .standalone, "A Kiosk window is never the host")
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [window(1, onScreen: false)],
                                             activeWindowId: 1, applicationIsHidden: false),
            .standalone, "Ordered out or miniaturized main windows count as absent")
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [window(1)],
                                             activeWindowId: 1, applicationIsHidden: true),
            .standalone, "A hidden app must not be unhidden to host the omnibox")
    }

    func testActiveMainWindowWinsThenTheFrontmostOne() {
        let windows = [window(7, main: false), window(2), window(1)]
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: windows,
                                             activeWindowId: 1, applicationIsHidden: false),
            .browserWindow(windowId: 1))
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: windows,
                                             activeWindowId: 7, applicationIsHidden: false),
            .browserWindow(windowId: 2), "The active Kiosk does not count; the frontmost main window does")
    }

    func testWindowOnTheCurrentDesktopWinsOverOneOnAnotherSpace() {
        let windows = [window(1, activeSpace: false), window(2)]
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: windows,
                                             activeWindowId: 1, applicationIsHidden: false),
            .browserWindow(windowId: 2))
        XCTAssertEqual(
            KioskLaunchOmniBoxRouting.target(windowsFrontToBack: [window(1, activeSpace: false)],
                                             activeWindowId: nil, applicationIsHidden: false),
            .browserWindow(windowId: 1), "With no window here, the main window elsewhere still hosts it")
    }

    func testOnlyMainBrowserTypesHostTheOmniBox() {
        XCTAssertTrue(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.normal))
        XCTAssertTrue(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.incognito))
        XCTAssertTrue(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.incognitoSpace))
        XCTAssertFalse(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.kiosk))
        XCTAssertFalse(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.kioskIncognito))
        XCTAssertFalse(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.shadow))
        XCTAssertFalse(KioskLaunchOmniBoxRouting.isMainBrowserWindowType(.popup))
    }

    // MARK: - Submission handoff

    func testHandedOffSuggestionResolvesToItsURLInsteadOfOpeningHere() throws {
        let (model, state) = try makeModel()
        var handedOff: [String] = []
        model.submissionURLHandler = { handedOff.append($0) }
        model.updateInputText("example.com/a")
        deliver([["type": "url-what-you-typed", "contents": "https://example.com/a",
                  "description": "", "destinationUrl": "https://example.com/a",
                  "fillIntoEdit": "example.com/a", "line": 0, "hasTabMatch": true,
                  "allowedToBeDefaultMatch": true]],
                query: "example.com/a", to: state)

        model.handleEnterPressed(commandKeyPressed: true)

        XCTAssertEqual(handedOff, ["https://example.com/a"])
        XCTAssertTrue(chromiumSelections.isEmpty, "Chromium must not open the match in this window")
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testHandedOffTypedTextResolvesToTheProcessedURL() throws {
        let (model, state) = try makeModel()
        var handedOff: [String] = []
        model.submissionURLHandler = { handedOff.append($0) }
        model.updateInputText("https://example.com/typed")

        model.handleEnterPressed()

        XCTAssertEqual(handedOff, [URLProcessor.processUserInput("https://example.com/typed")])
        XCTAssertTrue(chromiumSelections.isEmpty)
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testContainerHandsOffSubmissionOnceAndThenOpensNormallyAgain() throws {
        let state = try makeState()
        let container = OmniBoxContainerViewController(browserState: state)
        let omniBox = try XCTUnwrap(container.omniBoxController)
        var submitted: [String] = []
        var dismissals = 0
        container.showOmniBox(fromAddressBar: false)
        container.handOffNextSubmission(onSubmit: { submitted.append($0) },
                                        onDismissWithoutSubmission: { dismissals += 1 })
        XCTAssertTrue(container.isHandingOffSubmission)
        XCTAssertFalse(omniBox.showsSwitchToTabHintInSuggestionsForTesting,
                       "A handed-off submission never switches tabs")

        omniBox.updateStatus(with: Tab(guid: 1, url: "https://example.com/picked", isActive: true, index: 0))
        omniBox.confirmSelection()

        XCTAssertEqual(submitted, ["https://example.com/picked"])
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(container.hasShown)
        XCTAssertFalse(container.isHandingOffSubmission)
        XCTAssertFalse(omniBox.isHandingOffSubmissions)
        XCTAssertTrue(omniBox.showsSwitchToTabHintInSuggestionsForTesting)

        container.showOmniBox(fromAddressBar: false)
        container.hideOmniBox()
        XCTAssertEqual(submitted.count, 1, "A later ordinary session hands nothing off")
        XCTAssertEqual(dismissals, 0)
    }

    func testContainerDismissalWithoutSubmissionOpensNothing() throws {
        let state = try makeState()
        let container = OmniBoxContainerViewController(browserState: state)
        var submitted: [String] = []
        var dismissals = 0
        container.showOmniBox(fromAddressBar: false)
        container.handOffNextSubmission(onSubmit: { submitted.append($0) },
                                        onDismissWithoutSubmission: { dismissals += 1 })

        container.hideOmniBox()
        container.hideOmniBox()

        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(container.isHandingOffSubmission)
    }

    // MARK: - Standalone panel

    func testStandalonePanelSitsCenteredInTheUpperPartOfTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = KioskLaunchOmniBoxPanelController.panelSize
        let frame = KioskLaunchOmniBoxPanelController.frame(size: size, onVisibleFrame: visible)

        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
        let boxTop = frame.maxY - KioskLaunchOmniBoxPanelController.shadowMargin
        XCTAssertEqual(boxTop, visible.maxY - visible.height * KioskLaunchOmniBoxPanelController.topOffsetRatio,
                       accuracy: 1)

        let small = NSRect(x: 100, y: 50, width: 500, height: 200)
        let clamped = KioskLaunchOmniBoxPanelController.frame(size: size, onVisibleFrame: small)
        XCTAssertTrue(small.contains(clamped), "The panel stays inside a small visible frame")
    }

    func testStandalonePanelHandsOffTheSubmissionAndCloses() throws {
        let state = try makeState()
        var results: [String?] = []
        let controller = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { results.append($0) }
        controller.present(on: NSScreen.main)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(controller.container.hasShown)

        let omniBox = try XCTUnwrap(controller.container.omniBoxController)
        omniBox.updateStatus(with: Tab(guid: 1, url: "https://example.com/kiosk", isActive: true, index: 0))
        omniBox.confirmSelection()

        XCTAssertEqual(results, ["https://example.com/kiosk"])
        XCTAssertTrue(controller.isFinished)
        XCTAssertFalse(controller.panel.isVisible)
        controller.dismiss()
        XCTAssertEqual(results.count, 1, "The panel finishes exactly once")
    }

    func testStandalonePanelDismissalOpensNothing() throws {
        let state = try makeState()
        var results: [String?] = []
        let controller = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { results.append($0) }
        controller.present(on: NSScreen.main)

        controller.dismiss()

        XCTAssertEqual(results, [nil])
        XCTAssertFalse(controller.panel.isVisible)
    }

    func testStandalonePanelDismissesWhenItsHostBrowserCloses() throws {
        let state = try makeState()
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: true)
        hostWindow.isReleasedWhenClosed = false
        var results: [String?] = []
        let controller = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: hostWindow) { results.append($0) }
        controller.present(on: NSScreen.main)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: hostWindow)

        XCTAssertEqual(results, [nil])
        XCTAssertFalse(controller.panel.isVisible)
    }
}
