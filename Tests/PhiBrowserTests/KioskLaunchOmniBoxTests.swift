// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// An empty New Kiosk asks for its URL before any Kiosk exists, in a
/// standalone panel. A submission is handed off as a URL for the Kiosk to
/// open; any dismissal opens nothing.
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

    /// A detached omnibox (the standalone panel) is no overlay of its host
    /// Browser's window: announcing one would make that window take key
    /// back on hide and eclipse its panels, and the host's tab changes are
    /// not in front of the user.
    func testDetachedContainerIsNoInWindowOverlayAndIgnoresHostTabChanges() throws {
        let state = try makeState()
        let container = OmniBoxContainerViewController(browserState: state, isDetachedFromHostWindow: true)
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .phiInWindowOverlayVisibilityChanged, object: nil, queue: nil) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        var dismissals = 0
        container.showOmniBox(fromAddressBar: false)
        container.handOffNextSubmission(onSubmit: { _ in }, onDismissWithoutSubmission: { dismissals += 1 })

        state.focusingTab = Tab(guid: 9, url: "about:blank", isActive: true, index: 0)
        let settled = expectation(description: "Focusing-tab change delivered")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertTrue(container.hasShown, "A host tab change must not dismiss a detached omnibox")
        XCTAssertEqual(dismissals, 0)

        container.hideOmniBox()
        XCTAssertEqual(announcements, 0)
        XCTAssertEqual(dismissals, 1)
    }

    func testInWindowContainerStillAnnouncesItsOverlay() throws {
        let state = try makeState()
        let container = OmniBoxContainerViewController(browserState: state)
        var visibility: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .phiInWindowOverlayVisibilityChanged, object: nil, queue: nil) {
                if let visible = $0.userInfo?["visible"] as? Bool { visibility.append(visible) }
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        container.showOmniBox(fromAddressBar: false)
        container.hideOmniBox()
        XCTAssertEqual(visibility, [true, false])
    }

    // MARK: - Opening after activation

    private final class ActivationHarness {
        let center = NotificationCenter()
        let object = NSObject()
        var isActive = false
        var activations = 0
        var nextTurn: [() -> Void] = []
        var fallbacks: [() -> Void] = []

        @MainActor
        var activation: KioskLaunchActivation {
            KioskLaunchActivation(
                isApplicationActive: { [unowned self] in self.isActive },
                activateApplication: { [unowned self] in self.activations += 1 },
                notificationCenter: center,
                activationNotificationObject: object,
                scheduleNextTurn: { [unowned self] in self.nextTurn.append($0) },
                scheduleFallback: { [unowned self] in self.fallbacks.append($0) })
        }

        func becomeActive() {
            isActive = true
            center.post(name: NSApplication.didBecomeActiveNotification, object: object)
        }

        func runNextTurn() {
            let pending = nextTurn
            nextTurn = []
            pending.forEach { $0() }
        }
    }

    /// In an active app the Kiosk still opens a turn later, behind the hide
    /// of the omnibox that asked, which hands key back to its own window.
    func testActiveAppOpensTheKioskOnTheNextTurnWithoutActivating() {
        let harness = ActivationHarness()
        harness.isActive = true
        var opens = 0
        harness.activation.perform { opens += 1 }
        XCTAssertEqual(opens, 0)
        harness.runNextTurn()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(harness.activations, 0)
        XCTAssertTrue(harness.fallbacks.isEmpty)
    }

    func testInactiveAppActivatesAndOpensTheKioskOnceActivationSettles() {
        let harness = ActivationHarness()
        var opens = 0
        harness.activation.perform { opens += 1 }
        XCTAssertEqual(harness.activations, 1)
        XCTAssertEqual(opens, 0, "Not before Phi is active")

        harness.becomeActive()
        XCTAssertEqual(opens, 0, "Not before the activation's own ordering pass")
        harness.runNextTurn()
        XCTAssertEqual(opens, 1)

        harness.fallbacks.forEach { $0() }
        harness.becomeActive()
        harness.runNextTurn()
        XCTAssertEqual(opens, 1, "Opens exactly once")
    }

    func testDeclinedActivationStillOpensTheKioskAfterTheFallback() {
        let harness = ActivationHarness()
        var opens = 0
        harness.activation.perform { opens += 1 }
        XCTAssertEqual(harness.fallbacks.count, 1)
        harness.fallbacks.forEach { $0() }
        XCTAssertEqual(opens, 1)

        harness.becomeActive()
        harness.runNextTurn()
        XCTAssertEqual(opens, 1, "A late activation opens nothing more")
    }

    // MARK: - Standalone panel

    func testStandalonePanelPutsTheBoxInTheTopRightCornerOfTheScreen() {
        let visible = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let margin = KioskLaunchOmniBoxPanelController.shadowMargin
        let rightInset = KioskLaunchOmniBoxPanelController.rightInset
        let topInset = KioskLaunchOmniBoxPanelController.topInset
        let frame = KioskLaunchOmniBoxPanelController.frame(onVisibleFrame: visible)

        XCTAssertEqual(frame.size, KioskLaunchOmniBoxPanelController.panelSize)
        XCTAssertEqual(KioskLaunchOmniBoxPanelController.boxTopRight(onVisibleFrame: visible),
                       NSPoint(x: visible.maxX - rightInset, y: visible.maxY - topInset))
        XCTAssertEqual(frame.maxX - margin, visible.maxX - rightInset, accuracy: 1)
        XCTAssertEqual(frame.maxY - margin, visible.maxY - topInset, accuracy: 1)

        let small = NSRect(x: 100, y: 50, width: 300, height: 200)
        let clamped = KioskLaunchOmniBoxPanelController.frame(onVisibleFrame: small)
        XCTAssertEqual(clamped.minX + margin, small.minX, accuracy: 1,
                       "The box never starts left of a narrow visible frame")
        XCTAssertEqual(clamped.minY + margin, small.minY, accuracy: 1)
    }

    func testKioskTopRightFollowsTheOmniBox() {
        let visible = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
        let topRight = KioskLaunchOmniBoxPanelController.boxTopRight(onVisibleFrame: visible)
        let size = NSSize(width: 560, height: 650)

        let frame = KioskWindowPresentationGeometry.frame(
            size: size, topRight: topRight, constrainedTo: visible)
        XCTAssertEqual(frame, NSRect(x: topRight.x - 560, y: topRight.y - 650,
                                     width: 560, height: 650))

        let tall = KioskWindowPresentationGeometry.frame(
            size: NSSize(width: 560, height: 1200), topRight: topRight, constrainedTo: visible)
        XCTAssertEqual(tall.maxX, topRight.x, accuracy: 1)
        XCTAssertEqual(tall.minY, visible.minY, accuracy: 1)
    }

    /// The shadow margin above the box reaches past the visible frame's top
    /// into the menu bar; AppKit must not push the panel down below it.
    func testStandalonePanelKeepsTheBoxAtItsInsetsOnScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let state = try makeState()
        let controller = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { _ in }
        defer { controller.dismiss() }
        controller.present(on: screen)

        XCTAssertEqual(controller.panel.frame,
                       KioskLaunchOmniBoxPanelController.frame(onVisibleFrame: screen.visibleFrame))
        XCTAssertEqual(controller.boxTopRight,
                       KioskLaunchOmniBoxPanelController.boxTopRight(onVisibleFrame: screen.visibleFrame))
    }

    /// The panel draws no chrome of its own, and its transparent margin holds
    /// the box's whole shadow: a panel edge inside the blur would cut it into
    /// a gray rectangle behind the rounded box.
    func testStandalonePanelHasNoChromeAndRoomForTheBoxShadow() throws {
        let state = try makeState()
        let controller = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { _ in }
        defer { controller.dismiss() }
        controller.present(on: NSScreen.main)

        XCTAssertFalse(controller.panel.isOpaque)
        XCTAssertFalse(controller.panel.hasShadow)
        XCTAssertEqual(controller.panel.backgroundColor, .clear)

        let box = try XCTUnwrap(controller.container.omniBoxController?.view)
        let shadow = try XCTUnwrap(box.shadow)
        let margin = KioskLaunchOmniBoxPanelController.shadowMargin
        XCTAssertGreaterThanOrEqual(margin, shadow.shadowBlurRadius + abs(shadow.shadowOffset.width))
        XCTAssertGreaterThanOrEqual(margin, shadow.shadowBlurRadius + abs(shadow.shadowOffset.height))

        let content = try XCTUnwrap(controller.panel.contentView)
        content.layoutSubtreeIfNeeded()
        let boxInPanel = box.convert(box.bounds, to: content)
        XCTAssertEqual(boxInPanel.width, KioskLaunchOmniBoxPanelController.boxWidth, accuracy: 1)
        XCTAssertEqual(boxInPanel.midX, content.bounds.midX, accuracy: 1,
                       "Centered on the panel, not beside the host Browser's sidebar")
        XCTAssertGreaterThanOrEqual(boxInPanel.minX, margin - 1)
        XCTAssertLessThanOrEqual(boxInPanel.maxX, content.bounds.maxX - margin + 1)
        XCTAssertLessThanOrEqual(boxInPanel.maxY, content.bounds.maxY - margin + 1)
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

    /// Each New Kiosk gets a fresh panel; a finished one leaves nothing that
    /// would stop the next from asking.
    func testAFreshPanelAsksAgainAfterAFinishedOne() throws {
        let state = try makeState()
        var results: [String?] = []
        let first = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { results.append($0) }
        first.present(on: NSScreen.main)
        let firstBox = try XCTUnwrap(first.container.omniBoxController)
        firstBox.updateStatus(with: Tab(guid: 1, url: "https://example.com/one", isActive: true, index: 0))
        firstBox.confirmSelection()

        let second = KioskLaunchOmniBoxPanelController(
            browserState: state, hostWindow: nil) { results.append($0) }
        second.present(on: NSScreen.main)
        XCTAssertTrue(second.panel.isVisible)
        XCTAssertTrue(second.container.hasShown)
        let secondBox = try XCTUnwrap(second.container.omniBoxController)
        secondBox.updateStatus(with: Tab(guid: 2, url: "https://example.com/two", isActive: true, index: 0))
        secondBox.confirmSelection()

        XCTAssertEqual(results, ["https://example.com/one", "https://example.com/two"])
    }
}
