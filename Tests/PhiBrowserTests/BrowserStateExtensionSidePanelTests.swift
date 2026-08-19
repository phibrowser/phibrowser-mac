// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import XCTest
@testable import Phi

/// State-layer coverage for the extension side panel slot: open/close
/// bookkeeping, the synchronous outgoing-view detach contract, the
/// AI Chat ↔ panel mutex (both directions), and the slot width clamping.
/// Container-layer layout coverage lives in
/// `ExtensionSidePanelContainerLayoutTests` below.
@MainActor
final class BrowserStateExtensionSidePanelTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var originalPhiAIEnabled: Any?

    override func setUpWithError() throws {
        // The AI Chat expand path is gated on the AI preference; pin it on
        // and restore the user's value afterwards.
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        originalPhiAIEnabled = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
    }

    override func tearDownWithError() throws {
        let key = PhiPreferences.AISettings.phiAIEnabled.rawValue
        if let originalPhiAIEnabled {
            UserDefaults.standard.set(originalPhiAIEnabled, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        originalPhiAIEnabled = nil

        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeTemporaryStoreDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        return directory
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = try makeTemporaryStoreDirectory()
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    @discardableResult
    private func seed(state: BrowserState, guids: [Int]) -> [Tab] {
        let tabs = guids.map {
            Tab(guid: $0, url: "https://tab\($0).example", isActive: false, index: 0)
        }
        state.tabs = tabs
        state.updateNormalTabs()
        return tabs
    }

    private func makePanel(
        extensionId: String = "test-extension",
        wrapper: ExtensionSidePanelTestWebContentWrapper
    ) -> BrowserState.ExtensionSidePanelState {
        BrowserState.ExtensionSidePanelState(extensionId: extensionId,
                                             displayName: "Test Extension",
                                             iconPNG: nil,
                                             wrapper: wrapper)
    }

    // MARK: - Slot open/close

    func testOpenAndClosePublishPanelState() throws {
        let state = try makeBrowserState()
        let wrapper = ExtensionSidePanelTestWebContentWrapper()

        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        XCTAssertEqual(state.extensionSidePanel?.extensionId, "test-extension")
        XCTAssertEqual(state.extensionSidePanel?.displayName, "Test Extension")
        XCTAssertTrue(state.extensionSidePanel?.wrapper === wrapper)

        state.updateExtensionSidePanel(nil)

        XCTAssertNil(state.extensionSidePanel)
    }

    func testCloseDetachesOutgoingNativeViewSynchronously() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let nativeView = NSView()
        superview.addSubview(nativeView)
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView
        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        state.updateExtensionSidePanel(nil)

        XCTAssertNil(nativeView.superview)
    }

    func testClosePublishesBeforeDetachingOutgoingView() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let nativeView = NSView()
        superview.addSubview(nativeView)
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView
        state.updateExtensionSidePanel(makePanel(wrapper: wrapper))

        // The container's synchronous sink snapshots the closing panel for
        // its slide-out animation, so the close publish must arrive while
        // the outgoing NSView is still in the hierarchy. The backstop
        // detach after the publish keeps the synchronous-detach contract
        // when no sink detaches the view itself.
        var attachedAtClosePublish: Bool?
        let cancellable = state.$extensionSidePanel
            .dropFirst()  // subscription replay of the open panel
            .sink { panel in
                if panel == nil {
                    attachedAtClosePublish = nativeView.superview != nil
                }
            }
        defer { cancellable.cancel() }

        state.updateExtensionSidePanel(nil)

        XCTAssertEqual(attachedAtClosePublish, true)
        XCTAssertNil(nativeView.superview)
    }

    func testContentReplacementDetachesOutgoingNativeView() throws {
        let state = try makeBrowserState()
        let superview = NSView()
        let outgoingView = NSView()
        superview.addSubview(outgoingView)
        let outgoing = ExtensionSidePanelTestWebContentWrapper()
        outgoing.nativeView = outgoingView
        state.updateExtensionSidePanel(makePanel(extensionId: "a", wrapper: outgoing))

        let incoming = ExtensionSidePanelTestWebContentWrapper()
        state.updateExtensionSidePanel(makePanel(extensionId: "b", wrapper: incoming))

        XCTAssertNil(outgoingView.superview)
        XCTAssertEqual(state.extensionSidePanel?.extensionId, "b")
    }

    // MARK: - Mutex: panel open collapses AI Chat

    func testPanelOpenCollapsesAIChatOnAllTabs() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100, 200, 300])
        tabs[0].aiChatCollapsed = false
        tabs[2].aiChatCollapsed = false
        state.aiChatCollapsed = false

        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        XCTAssertTrue(tabs.allSatisfy { $0.aiChatCollapsed })
        XCTAssertTrue(state.aiChatCollapsed)
    }

    // MARK: - Mutex: AI Chat expand closes the panel first

    func testAIChatExpandClosesPanelBeforeExpanding() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.focuseTab(tabs[0])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))
        XCTAssertTrue(tabs[0].aiChatCollapsed)

        var chatWasStillCollapsedAtCloseRequest = false
        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state, weak tab = tabs[0]] in
            closeRequests += 1
            chatWasStillCollapsedAtCloseRequest = tab?.aiChatCollapsed ?? false
            // Simulate Chromium's synchronous close push back over the bridge.
            state?.updateExtensionSidePanel(nil)
        }

        state.toggleAIChat(false)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertTrue(chatWasStillCollapsedAtCloseRequest)
        XCTAssertNil(state.extensionSidePanel)
        XCTAssertFalse(tabs[0].aiChatCollapsed)
    }

    func testMirroredExpandViaSetAIChatCollapsedClosesPanel() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { [weak state] in
            closeRequests += 1
            state?.updateExtensionSidePanel(nil)
        }

        state.setAIChatCollapsed(for: tabs[0], collapsed: false)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertNil(state.extensionSidePanel)
        XCTAssertFalse(tabs[0].aiChatCollapsed)
    }

    func testAIChatCollapseLeavesPanelOpen() throws {
        let state = try makeBrowserState()
        let tabs = seed(state: state, guids: [100])
        state.focuseTab(tabs[0])
        state.updateExtensionSidePanel(
            makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper()))

        var closeRequests = 0
        state.extensionSidePanelCloseRequestOverrideForTesting = { closeRequests += 1 }

        state.toggleAIChat(true)
        state.setAIChatCollapsed(for: tabs[0], collapsed: true)

        XCTAssertEqual(closeRequests, 0)
        XCTAssertNotNil(state.extensionSidePanel)
    }

    // MARK: - Slot width

    func testPanelViewClampsWidth() {
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(100), ExtensionSidePanelView.minWidth)
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(9999), ExtensionSidePanelView.maxWidth)
        XCTAssertEqual(ExtensionSidePanelView.clampedWidth(500), 500)

        let panel = ExtensionSidePanelView(initialWidth: 100)
        XCTAssertEqual(panel.preferredWidth, ExtensionSidePanelView.minWidth)

        panel.setPreferredWidth(640)
        XCTAssertEqual(panel.preferredWidth, 640)

        panel.setPreferredWidth(12000)
        XCTAssertEqual(panel.preferredWidth, ExtensionSidePanelView.maxWidth)
    }
}

/// Container-layer coverage for the extension side panel slot: the 4pt
/// page-to-panel gap, the attach/detach end states (slide animations
/// disabled so layout settles synchronously), and the per-window width
/// memory across a close/reopen.
@MainActor
final class ExtensionSidePanelContainerLayoutTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var originalLayoutMode: String?

    override func setUpWithError() throws {
        WebContentContainerViewController.panelSlideAnimationsDisabledForTesting = true
        originalLayoutMode = UserDefaults.standard.string(
            forKey: PhiPreferences.GeneralSettings.layoutModeKey)
    }

    override func tearDownWithError() throws {
        WebContentContainerViewController.panelSlideAnimationsDisabledForTesting = false
        if let originalLayoutMode {
            UserDefaults.standard.set(originalLayoutMode,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        originalLayoutMode = nil
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeContainer() throws -> WebContentContainerViewController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 8, localStore: store, profileId: "Default")
        let container = WebContentContainerViewController(state: state)
        container.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        return container
    }

    private func makePanel(wrapper: ExtensionSidePanelTestWebContentWrapper)
        -> BrowserState.ExtensionSidePanelState {
        BrowserState.ExtensionSidePanelState(extensionId: "test-extension",
                                             displayName: "Test Extension",
                                             iconPNG: nil,
                                             wrapper: wrapper)
    }

    private func attachPanel(to container: WebContentContainerViewController,
                             holding nativeView: NSView)
        throws -> ExtensionSidePanelView {
        let wrapper = ExtensionSidePanelTestWebContentWrapper()
        wrapper.nativeView = nativeView
        container.attachExtensionSidePanel(makePanel(wrapper: wrapper))
        container.view.layoutSubtreeIfNeeded()
        return try XCTUnwrap(container.extensionSidePanelViewForTesting)
    }

    /// The panel settles as a sub-card inside the content frame (AI Chat
    /// parity): contentEdgeSpacing (4pt) below the frame's top line and
    /// 4pt inside the shared 8pt window margins on the right and bottom,
    /// in every layout mode.
    private func assertPanelSettlesAsFrameSubCard(
        mode: LayoutMode, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
        let container = try makeContainer()
        let nativeView = NSView()

        let panelView = try attachPanel(to: container, holding: nativeView)

        XCTAssertTrue(nativeView.superview === panelView.contentHostView,
                      file: file, line: line)
        XCTAssertEqual(panelView.frame.width, 360, accuracy: 0.5,
                       file: file, line: line)
        let containerFrame = container.splitTabDropContainer.frame
        XCTAssertEqual(panelView.frame.maxY, containerFrame.maxY - 4,
                       accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(panelView.frame.minY, containerFrame.minY + 12,
                       accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(panelView.frame.maxX, 1200 - 12, accuracy: 0.5,
                       file: file, line: line)
        // splitViewContainer's right edge (8pt margin inside the content
        // container) must land exactly on the panel's leading edge so its
        // background paints the 4pt seam next to the inset page card.
        XCTAssertEqual(containerFrame.maxX, panelView.frame.minX + 8,
                       accuracy: 0.5, file: file, line: line)

        // The frame-interior fill: same vertical extent as
        // splitViewContainer, wrapping the panel card plus its 4pt margin,
        // sitting ABOVE the content container (to cover its vibrancy
        // strip) with only its outer (right) corners rounded.
        let backdrop = try XCTUnwrap(
            container.extensionSidePanelFrameBackdropForTesting,
            file: file, line: line)
        XCTAssertEqual(backdrop.frame.maxY, containerFrame.maxY,
                       accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(backdrop.frame.minY, containerFrame.minY + 8,
                       accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(backdrop.frame.maxX, 1200 - 8, accuracy: 0.5,
                       file: file, line: line)
        XCTAssertEqual(backdrop.frame.minX, panelView.frame.minX,
                       accuracy: 0.5, file: file, line: line)
        let subviews = container.view.subviews
        let backdropIndex = try XCTUnwrap(subviews.firstIndex(of: backdrop),
                                          file: file, line: line)
        let containerIndex = try XCTUnwrap(
            subviews.firstIndex(of: container.splitTabDropContainer),
            file: file, line: line)
        XCTAssertGreaterThan(backdropIndex, containerIndex, file: file, line: line)
        XCTAssertEqual(backdrop.layer?.maskedCorners,
                       [.layerMaxXMinYCorner, .layerMaxXMaxYCorner],
                       file: file, line: line)
    }

    func testBalancedPanelSettlesAsFrameSubCard() throws {
        try assertPanelSettlesAsFrameSubCard(mode: .balanced)
    }

    func testPerformancePanelSettlesAsFrameSubCard() throws {
        try assertPanelSettlesAsFrameSubCard(mode: .performance)
    }

    func testComfortablePanelSettlesAsFrameSubCard() throws {
        try assertPanelSettlesAsFrameSubCard(mode: .comfortable)
    }

    func testDetachRestoresFullWidthAndRemembersDraggedWidth() throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(.balanced)
        let container = try makeContainer()
        let firstNative = NSView()
        let firstWrapper = ExtensionSidePanelTestWebContentWrapper()
        firstWrapper.nativeView = firstNative
        container.attachExtensionSidePanel(makePanel(wrapper: firstWrapper))
        container.view.layoutSubtreeIfNeeded()
        let firstPanel = try XCTUnwrap(container.extensionSidePanelViewForTesting)
        firstPanel.setPreferredWidth(500)

        container.detachExtensionSidePanel()
        container.view.layoutSubtreeIfNeeded()

        XCTAssertNil(container.extensionSidePanelViewForTesting)
        XCTAssertNil(firstPanel.superview)
        XCTAssertNil(container.extensionSidePanelFrameBackdropForTesting)
        XCTAssertEqual(container.splitTabDropContainer.frame.maxX, 1200, accuracy: 0.5)

        let secondNative = NSView()
        let secondWrapper = ExtensionSidePanelTestWebContentWrapper()
        secondWrapper.nativeView = secondNative
        container.attachExtensionSidePanel(makePanel(wrapper: secondWrapper))
        container.view.layoutSubtreeIfNeeded()

        let secondPanel = try XCTUnwrap(container.extensionSidePanelViewForTesting)
        XCTAssertEqual(secondPanel.preferredWidth, 500)
        XCTAssertEqual(secondPanel.frame.width, 500, accuracy: 0.5)
    }
}

/// Page-card separation on panel open: a docked panel insets the page card
/// 4pt and gives it a border — the same treatment an expanded AI Chat
/// applies — in every layout mode, and squares splitViewContainer's right
/// corners (interior boundary with the panel's frame fill) for the panel's
/// stay.
@MainActor
final class WebContentPanelSeparationStyleTests: XCTestCase {

    private var tempDirectories: [URL] = []
    private var originalLayoutMode: String?

    private static let allRoundedCorners: CACornerMask =
        [.layerMinXMinYCorner, .layerMinXMaxYCorner,
         .layerMaxXMinYCorner, .layerMaxXMaxYCorner]

    override func setUpWithError() throws {
        originalLayoutMode = UserDefaults.standard.string(
            forKey: PhiPreferences.GeneralSettings.layoutModeKey)
    }

    override func tearDownWithError() throws {
        if let originalLayoutMode {
            UserDefaults.standard.set(originalLayoutMode,
                                      forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: PhiPreferences.GeneralSettings.layoutModeKey)
        }
        originalLayoutMode = nil
        let fileManager = FileManager.default
        for directory in tempDirectories {
            try? fileManager.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeController() throws
        -> (BrowserState, WebContentViewController) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        let state = BrowserState(windowId: 11, localStore: store, profileId: "Default")
        let tab = Tab(guid: 600, url: "https://example.com/", isActive: true, index: 0)
        state.tabs = [tab]
        state.updateNormalTabs()
        let controller = WebContentViewController(state: state, tab: tab)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        controller.viewWillAppear()  // installs the $extensionSidePanel sink
        return (state, controller)
    }

    private func makePanel() -> BrowserState.ExtensionSidePanelState {
        BrowserState.ExtensionSidePanelState(
            extensionId: "test-extension",
            displayName: "Test Extension",
            iconPNG: nil,
            wrapper: ExtensionSidePanelTestWebContentWrapper())
    }

    private func assertPanelSeparatesPageCard(
        mode: LayoutMode, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        PhiPreferences.GeneralSettings.saveLayoutMode(mode)
        let (state, controller) = try makeController()
        let pageCard = controller.leftContainerViewForTesting
        let pageContainer = controller.closeSnapshotSourceView
        XCTAssertEqual(pageCard.layer?.borderWidth, 0, file: file, line: line)

        state.updateExtensionSidePanel(makePanel())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageCard.layer?.borderWidth, 1, file: file, line: line)
        let wrapperBounds = try XCTUnwrap(pageCard.superview, file: file, line: line).bounds
        XCTAssertEqual(pageCard.frame, wrapperBounds.insetBy(dx: 4, dy: 4),
                       file: file, line: line)
        XCTAssertEqual(pageContainer.layer?.maskedCorners,
                       [.layerMinXMinYCorner, .layerMinXMaxYCorner],
                       file: file, line: line)

        state.updateExtensionSidePanel(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageCard.layer?.borderWidth, 0, file: file, line: line)
        XCTAssertEqual(pageCard.frame,
                       try XCTUnwrap(pageCard.superview, file: file, line: line).bounds,
                       file: file, line: line)
        XCTAssertEqual(pageContainer.layer?.maskedCorners, Self.allRoundedCorners,
                       file: file, line: line)
    }

    func testBalancedPanelOpenSeparatesPageCard() throws {
        try assertPanelSeparatesPageCard(mode: .balanced)
    }

    func testComfortablePanelOpenSeparatesPageCard() throws {
        try assertPanelSeparatesPageCard(mode: .comfortable)
    }

    func testPerformancePanelOpenSeparatesPageCard() throws {
        try assertPanelSeparatesPageCard(mode: .performance)
    }
}

/// Minimal `WebContentWrapper` conformance for panel-state tests (same
/// pattern as `BookmarkLayoutTestWebContentWrapper`). `nativeView` is weak,
/// matching the protocol — tests must hold the NSView strongly themselves.
private final class ExtensionSidePanelTestWebContentWrapper: NSObject, WebContentWrapper {
    @objc dynamic weak var nativeView: NSView?
    @objc dynamic var isLoading = false
    @objc dynamic var loadingState = PhiTabLoadingState(rawValue: 0)!
    @objc dynamic var isFocused = false
    @objc dynamic var loadProgress: CGFloat = 1
    @objc dynamic var favIconURL: String?
    @objc dynamic var favIconData: Data?
    @objc dynamic var favIconRevision = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var title: String?
    @objc dynamic var urlString: String?
    @objc dynamic var securityInfo: [String: Any]?
    @objc dynamic var isCurrentlyAudible = false
    @objc dynamic var isAudioMuted = false
    @objc dynamic var isCapturingAudio = false
    @objc dynamic var isCapturingVideo = false
    @objc dynamic var isCapturingWindow = false
    @objc dynamic var isCapturingDisplay = false
    @objc dynamic var isCapturingTab = false
    @objc dynamic var isBeingMirrored = false
    @objc dynamic var isSharingScreen = false
    @objc dynamic var isInContentFullscreen = false
    @objc dynamic var isDistillable = false
    @objc dynamic var devToolsTargetId: String?

    func requestAccessibilityTreeSnapshot(
        withMinimumPages minimumPages: Int,
        timeoutMs: Int,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        completion(nil)
    }

    func close() {}
    func reload() {}
    func reloadBypassingCache() {}
    func goBack() {}
    func goForward() {}
    func stopLoading() {}
    func navigate(toURL urlString: String) { self.urlString = urlString }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  beforeTabId anchorTabId: Int64) {}
    func moveSelf(toWindow targetWindowId: Int64,
                  andAddToGroupTokenHex targetGroupTokenHex: String,
                  afterTabId anchorTabId: Int64) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) {}
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}
