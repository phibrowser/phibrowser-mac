// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class KioskBrowserStateTests: XCTestCase {
    func testExternalLinksInKioskDefaultsOff() {
        XCTAssertFalse(
            PhiPreferences.GeneralSettings.openExternalLinksInKiosk.defaultValue
        )
    }

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testWireValuesAreAppendOnly() {
        XCTAssertEqual(ChromiumBrowserType.kiosk.rawValue, 11)
        XCTAssertEqual(ChromiumBrowserType.kioskIncognito.rawValue, 12)
    }

    func testStateIsIsolatedAndPreservesReportedProfile() throws {
        let state = try makeState(profileId: "Profile 2")

        XCTAssertTrue(state.isKioskWindow)
        XCTAssertFalse(state.participatesInSpaces)
        XCTAssertEqual(state.profileId, "Profile 2")
        XCTAssertTrue(state.pinnedTabs.isEmpty)
    }

    func testKioskPlaceholderDoesNotCountAsDefaultSpaceMembership() {
        XCTAssertFalse(SpaceManager.sourceAlreadyBelongsToTargetSpace(
            participatesInSpaces: false,
            sourceSpaceId: LocalStore.defaultSpaceId,
            targetSpaceId: LocalStore.defaultSpaceId
        ))
        XCTAssertTrue(SpaceManager.sourceAlreadyBelongsToTargetSpace(
            participatesInSpaces: true,
            sourceSpaceId: LocalStore.defaultSpaceId,
            targetSpaceId: LocalStore.defaultSpaceId
        ))
    }

    func testFirstChromiumTabBecomesFocusedContent() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0,
            title: "Example",
            windowId: state.windowId
        )

        state.handleNewTabFromChromium(tab)

        XCTAssertEqual(state.tabs.map(\.guid), [42])
        XCTAssertEqual(state.normalTabs.map(\.guid), [42])
        XCTAssertTrue(state.focusingTab === tab)
        XCTAssertTrue(tab.isActive)
        XCTAssertEqual(tab.profileId, state.profileId)
    }

    func testChromiumCloseRemovesFocusedContent() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0
        )
        state.handleNewTabFromChromium(tab)

        state.closeTab(tab.guid)

        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertNil(state.focusingTab)
    }

    func testAddressFieldIsReadOnlyAndRequestsOmniBoxOnClick() throws {
        let state = try makeState()
        let wrapper = KioskTestWebContentWrapper(urlString: "https://old.example")
        let tab = Tab(
            guid: 42,
            url: "https://old.example",
            isActive: false,
            index: 0,
            webContentView: wrapper,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let controller = KioskBrowserContentViewController(state: state)
        var omniBoxRequestCount = 0
        controller.configureActions(
            onProfileSelection: { _ in },
            onSpaceSelection: { _ in },
            onOmniBoxRequest: {
                omniBoxRequestCount += 1
            }
        )
        _ = controller.view
        let addressField = try XCTUnwrap(findTextField(in: controller.view))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        addressField.mouseDown(with: event)

        XCTAssertFalse(addressField.isEditable)
        XCTAssertFalse(addressField.isSelectable)
        XCTAssertFalse(addressField.stringValue.isEmpty)
        XCTAssertEqual(omniBoxRequestCount, 1)
        XCTAssertTrue(wrapper.navigatedURLs.isEmpty)
    }

    func testToolbarAndNativeTrafficLightsMoveDownTogether() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(
            identifier: NSToolbar.Identifier("KioskBrowserToolbarTest")
        )
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let contentView = try XCTUnwrap(window.contentView)
        let trafficLightButtons = try [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].map { buttonType in
            try XCTUnwrap(window.standardWindowButton(buttonType))
        }
        let originalTrafficLightCenterYs = try trafficLightButtons.map { button in
            let titlebarView = try XCTUnwrap(button.superview)
            return titlebarView.convert(
                NSPoint(x: button.frame.midX, y: button.frame.midY),
                to: nil
            ).y
        }
        let originalButtonFrames = trafficLightButtons.map(\.frame)
        let originalButtonSuperviews = try trafficLightButtons.map {
            try XCTUnwrap($0.superview)
        }
        let titlebarContainer = try XCTUnwrap(
            trafficLightButtons[0].superview?.superview
        )
        let originalTitlebarContainerFrame = titlebarContainer.frame
        let closeFrameInContainer = originalButtonSuperviews[0].convert(
            trafficLightButtons[0].frame,
            to: titlebarContainer
        )
        let originalTopMargin = titlebarContainer.bounds.maxY
            - closeFrameInContainer.maxY

        let positioner = KioskTrafficLightPositioner(
            window: window,
            downwardOffset: KioskBrowserToolbar.titlebarVerticalShift
        )
        positioner.start()

        func assertTrafficLightsAreShifted() throws {
            for (button, originalCenterY) in zip(
                trafficLightButtons,
                originalTrafficLightCenterYs
            ) {
                let titlebarView = try XCTUnwrap(button.superview)
                let shiftedCenterY = titlebarView.convert(
                    NSPoint(x: button.frame.midX, y: button.frame.midY),
                    to: nil
                ).y
                XCTAssertEqual(
                    shiftedCenterY,
                    originalCenterY - 4,
                    accuracy: 0.5
                )
            }
        }

        try assertTrafficLightsAreShifted()
        XCTAssertEqual(
            titlebarContainer.frame.height,
            trafficLightButtons[0].frame.height
                + 2 * (originalTopMargin + 4),
            accuracy: 0.5
        )
        XCTAssertEqual(
            titlebarContainer.frame.maxY,
            originalTitlebarContainerFrame.maxY,
            accuracy: 0.5
        )
        for (button, originalSuperview) in zip(
            trafficLightButtons,
            originalButtonSuperviews
        ) {
            XCTAssertTrue(button.superview === originalSuperview)
        }

        for (button, frame) in zip(trafficLightButtons, originalButtonFrames) {
            button.frame = frame
        }
        try assertTrafficLightsAreShifted()

        titlebarContainer.frame = originalTitlebarContainerFrame
        try assertTrafficLightsAreShifted()

        for button in trafficLightButtons {
            button.postsFrameChangedNotifications = false
        }
        for (button, frame) in zip(trafficLightButtons, originalButtonFrames) {
            button.frame = frame
        }
        window.title = "example.com"
        try assertTrafficLightsAreShifted()

        let toolbar = KioskBrowserToolbar(state: try makeState())
        toolbar.frame = NSRect(
            x: 0,
            y: contentView.bounds.maxY - KioskBrowserToolbar.preferredHeight,
            width: contentView.bounds.width,
            height: KioskBrowserToolbar.preferredHeight
        )
        contentView.addSubview(toolbar)

        toolbar.layoutSubtreeIfNeeded()

        let closeButton = trafficLightButtons[0]
        let trafficLightCenterY = toolbar.convert(
            NSPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        ).y
        XCTAssertEqual(toolbar.controlCenterYsForTesting.count, 2)
        for centerY in toolbar.controlCenterYsForTesting {
            XCTAssertEqual(
                centerY,
                trafficLightCenterY,
                accuracy: 0.5
            )
        }
    }

    func testKioskStateDrivesExistingOmniBoxController() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let container = OmniBoxContainerViewController(browserState: state)
        let omniBox = try XCTUnwrap(container.omniBoxController)

        omniBox.updateStatus(with: tab, suppressAutomaticSearch: true)

        XCTAssertTrue(omniBox.openningFromCurrenTab)
    }

    func testExtensionSidePanelMountsAndDetachesSynchronously() throws {
        let state = try makeState()
        let controller = KioskBrowserContentViewController(state: state)
        _ = controller.view
        let nativeView = NSView()
        let wrapper = KioskTestWebContentWrapper(urlString: nil)
        wrapper.nativeView = nativeView
        let panel = BrowserState.ExtensionSidePanelState(
            extensionId: "test-extension",
            displayName: "Test Extension",
            iconPNG: nil,
            wrapper: wrapper
        )

        state.updateExtensionSidePanel(panel)

        let panelView = try XCTUnwrap(
            controller.extensionSidePanelViewForTesting
        )
        XCTAssertTrue(nativeView.superview === panelView.contentHostView)

        state.updateExtensionSidePanel(nil)

        XCTAssertNil(controller.extensionSidePanelViewForTesting)
        XCTAssertNil(nativeView.superview)
    }

    private func makeState(
        profileId: String = LocalStore.defaultProfileId
    ) throws -> KioskBrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        let account = Account(userID: UUID().uuidString)
        let store = LocalStore(
            account: account,
            storeDirectoryURL: directory,
            presentsCompatibilityAlerts: false
        )
        return KioskBrowserState(
            windowId: 73,
            localStore: store,
            profileId: profileId,
            isIncognito: false
        )
    }

    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let textField = findTextField(in: subview) {
                return textField
            }
        }
        return nil
    }
}

private final class KioskTestWebContentWrapper: NSObject, WebContentWrapper {
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

    private(set) var navigatedURLs: [String] = []

    init(urlString: String?) {
        self.urlString = urlString
        super.init()
    }

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
    func navigate(toURL urlString: String) {
        navigatedURLs.append(urlString)
        self.urlString = urlString
    }
    func setAsActiveTab() {}
    func moveSelf(to newIndex: Int, selectAfterMove: Bool) {}
    func moveSelf(toNewWindow activateNewWindow: Bool) {}
    func moveSelf(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        beforeTabId anchorTabId: Int64
    ) {}
    func moveSelf(
        toWindow targetWindowId: Int64,
        andAddToGroupTokenHex targetGroupTokenHex: String,
        afterTabId anchorTabId: Int64
    ) {}
    func moveSplit(toNewWindow activateNewWindow: Bool) {}
    func moveSplit(toWindow targetWindowId: Int64, at insertIndex: Int) {}
    func updateTabCustomValue(_ customValue: String) {}
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}
