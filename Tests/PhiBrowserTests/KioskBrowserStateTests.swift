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
        XCTAssertFalse(
            PhiPreferences.GeneralSettings.openKioskOnCommandOptionClick.defaultValue
        )
    }

    func testSpaceMenuPrimaryTargetPrefersActiveThenDefaultSpace() {
        let defaultSpace = SpaceModel(
            spaceId: LocalStore.defaultSpaceId,
            profileId: "profile",
            name: "Default",
            colorHex: "#000000",
            iconName: "rectangle.stack",
            sortOrder: 0
        )
        let activeSpace = SpaceModel(
            spaceId: "active-space",
            profileId: "profile",
            name: "Active",
            colorHex: "#FFFFFF",
            iconName: "circle",
            sortOrder: 1
        )
        let spaces = [defaultSpace, activeSpace]

        XCTAssertEqual(
            KioskSpaceMenuTargetResolver.primarySpace(
                in: spaces,
                activeSpaceId: activeSpace.spaceId
            )?.spaceId,
            activeSpace.spaceId
        )
        XCTAssertEqual(
            KioskSpaceMenuTargetResolver.primarySpace(
                in: spaces,
                activeSpaceId: "missing-space"
            )?.spaceId,
            defaultSpace.spaceId
        )
        XCTAssertEqual(
            KioskSpaceMenuTargetResolver.primarySpace(
                in: [activeSpace],
                activeSpaceId: nil
            )?.spaceId,
            activeSpace.spaceId
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

    func testKioskUsesURLHandoffWhenDestinationRequiresSpaceSwitch() {
        XCTAssertFalse(SpaceManager.kioskTransferRequiresURLHandoff(
            isKioskWindow: true,
            activeSpaceId: "active-space",
            targetSpaceId: "active-space"
        ))
        XCTAssertTrue(SpaceManager.kioskTransferRequiresURLHandoff(
            isKioskWindow: true,
            activeSpaceId: "active-space",
            targetSpaceId: "other-space"
        ))
        XCTAssertFalse(SpaceManager.kioskTransferRequiresURLHandoff(
            isKioskWindow: false,
            activeSpaceId: "active-space",
            targetSpaceId: "other-space"
        ))
    }

    func testKioskWebURLHandoffBypassesSpaceRouting() {
        XCTAssertTrue(SpaceManager.kioskURLHandoffNeedsRoutingBypass("https://example.com/path"))
        XCTAssertTrue(SpaceManager.kioskURLHandoffNeedsRoutingBypass("HTTP://example.com"))
        XCTAssertFalse(SpaceManager.kioskURLHandoffNeedsRoutingBypass("chrome://newtab"))
        XCTAssertFalse(SpaceManager.kioskURLHandoffNeedsRoutingBypass(""))
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

    func testAddressFieldHidesAboutBlank() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "about:blank",
            isActive: false,
            index: 0,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let controller = KioskBrowserContentViewController(state: state)
        _ = controller.view

        let addressField = try XCTUnwrap(findTextField(in: controller.view))

        XCTAssertEqual(addressField.stringValue, "")
    }

    func testCopyURLButtonUsesThemeAwareHosting() throws {
        let toolbar = KioskBrowserToolbar(state: try makeState())

        XCTAssertTrue(containsThemedHostingView(in: toolbar))
    }

    func testBackButtonTracksFocusedTabNavigationState() throws {
        let state = try makeState()
        let wrapper = KioskTestWebContentWrapper(urlString: "https://example.com")
        let tab = Tab(
            guid: 42,
            url: "https://example.com",
            isActive: false,
            index: 0,
            webContentView: wrapper,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let controller = KioskBrowserContentViewController(state: state)
        _ = controller.view

        XCTAssertFalse(controller.isBackButtonVisibleForTesting)

        wrapper.canGoBack = true
        let navigationStateUpdated = expectation(
            description: "Back navigation state updated"
        )
        DispatchQueue.main.async {
            navigationStateUpdated.fulfill()
        }
        wait(for: [navigationStateUpdated], timeout: 1)

        XCTAssertTrue(controller.isBackButtonVisibleForTesting)

        wrapper.canGoBack = false
        let navigationStateReset = expectation(
            description: "Back navigation state reset"
        )
        DispatchQueue.main.async {
            navigationStateReset.fulfill()
        }
        wait(for: [navigationStateReset], timeout: 1)

        XCTAssertFalse(controller.isBackButtonVisibleForTesting)
    }

    func testKioskWindowRestoresAndAutosavesSharedFrame() throws {
        let autosaveName = KioskWindowFramePersistence.autosaveName
        NSWindow.removeFrame(usingName: autosaveName)
        defer { NSWindow.removeFrame(usingName: autosaveName) }

        let visibleFrame = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let savedFrame = NSRect(
            x: visibleFrame.minX + 40,
            y: visibleFrame.minY + 40,
            width: min(780, visibleFrame.width - 80),
            height: min(620, visibleFrame.height - 80)
        )
        let sourceWindow = makeWindow(frame: savedFrame)
        let persistedFrame = sourceWindow.frame
        sourceWindow.saveFrame(usingName: autosaveName)

        let restoredWindow = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        XCTAssertTrue(
            KioskWindowFramePersistence.restoreFrameAndEnableAutosave(
                for: restoredWindow
            )
        )

        XCTAssertEqual(restoredWindow.frame.origin.x, persistedFrame.origin.x)
        XCTAssertEqual(restoredWindow.frame.origin.y, persistedFrame.origin.y)
        XCTAssertEqual(restoredWindow.frame.width, persistedFrame.width)
        XCTAssertEqual(restoredWindow.frame.height, persistedFrame.height)
        XCTAssertEqual(restoredWindow.frameAutosaveName, autosaveName)
    }

    func testKioskCursorPresentationParsesBridgeContext() throws {
        let request = try XCTUnwrap(
            KioskWindowPresentationRequest(
                bridgeContext: [
                    "kind": "cursorZoom",
                    "anchorX": NSNumber(value: -240.5),
                    "anchorY": NSNumber(value: 720.25),
                ]
            )
        )

        XCTAssertEqual(request.anchorInScreen.x, -240.5)
        XCTAssertEqual(request.anchorInScreen.y, 720.25)
        XCTAssertNil(
            KioskWindowPresentationRequest(
                bridgeContext: [
                    "kind": "unsupported",
                    "anchorX": 100,
                    "anchorY": 200,
                ]
            )
        )
    }

    func testKioskCursorPresentationCentersAndConstrainsFinalFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
        let size = NSSize(width: 800, height: 600)

        let centeredFrame = KioskWindowPresentationGeometry.finalFrame(
            size: size,
            centeredAt: NSPoint(x: 800, y: 500),
            constrainedTo: visibleFrame
        )
        XCTAssertEqual(centeredFrame, NSRect(x: 400, y: 200, width: 800, height: 600))

        let edgeFrame = KioskWindowPresentationGeometry.finalFrame(
            size: size,
            centeredAt: NSPoint(x: 50, y: 950),
            constrainedTo: visibleFrame
        )
        XCTAssertEqual(edgeFrame, NSRect(x: 0, y: 400, width: 800, height: 600))
    }

    func testKioskCursorPresentationStartsAtCursor() {
        let anchor = NSPoint(x: -300, y: 740)
        let initialFrame = KioskWindowPresentationGeometry.initialFrame(
            growingTo: NSRect(x: -700, y: 440, width: 800, height: 600),
            from: anchor
        )

        XCTAssertEqual(initialFrame.midX, anchor.x)
        XCTAssertEqual(initialFrame.midY, anchor.y)
        XCTAssertEqual(initialFrame.width, 144)
        XCTAssertEqual(initialFrame.height, 108)
    }

    func testKioskZoomButtonUsesDefaultSpaceAction() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 900, height: 640)
        )
        let controller = KioskBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }

        let zoomButton = try XCTUnwrap(
            window.standardWindowButton(.zoomButton)
        )
        XCTAssertTrue(zoomButton.target === controller)
        XCTAssertEqual(
            zoomButton.action,
            NSSelectorFromString("openFocusedTabInDefaultSpace:")
        )
    }

    func testKioskWindowRemainsWindowedInExistingFullscreenSpace() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 900, height: 640)
        )
        window.collectionBehavior = [
            .managed,
            .participatesInCycle,
            .fullScreenPrimary,
        ]
        let controller = KioskBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }

        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertTrue(window.collectionBehavior.contains(.managed))
        XCTAssertTrue(window.collectionBehavior.contains(.participatesInCycle))
    }

    func testKioskOmniBoxIsCentered() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 640)
        )
        let controller = KioskBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }

        window.makeKeyAndOrderFront(nil)
        controller.presentOmniBoxCentered()

        let omniBoxContainer = try XCTUnwrap(
            controller.omniBoxContainerViewController
        )
        XCTAssertFalse(omniBoxContainer.isAnchoredToAddressBarForTesting)

        let frameUpdated = expectation(description: "Omnibox frame updated")
        DispatchQueue.main.async {
            let containerBounds = omniBoxContainer.view.bounds
            let omniBoxFrame = omniBoxContainer.omniBoxController?.view.frame
                ?? .zero
            XCTAssertEqual(
                omniBoxFrame.midX,
                containerBounds.midX,
                accuracy: 0.5
            )
            XCTAssertGreaterThanOrEqual(omniBoxFrame.minX, 20)
            XCTAssertGreaterThanOrEqual(
                containerBounds.maxX - omniBoxFrame.maxX,
                20
            )
            frameUpdated.fulfill()
        }
        wait(for: [frameUpdated], timeout: 1)
    }

    func testKioskAddressClickPrefillsPhiBrandedURL() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 640)
        )
        let controller = KioskBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }
        controller.browserState.handleNewTabFromChromium(Tab(
            guid: 42,
            url: "chrome://settings/privacy",
            isActive: false,
            index: 0,
            windowId: state.windowId
        ))
        let contentController = try XCTUnwrap(
            controller.contentViewController as? KioskBrowserContentViewController
        )
        let addressField = try XCTUnwrap(
            contentController.addressBarAnchorView.subviews
                .compactMap { $0 as? NSTextField }
                .first
        )
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

        let omniBoxView = try XCTUnwrap(
            controller.omniBoxContainerViewController?.omniBoxController?.view
        )
        XCTAssertEqual(
            findTextField(in: omniBoxView)?.stringValue,
            "phi://settings/privacy"
        )
    }

    func testKioskFocusLocationPrefillsPhiBrandedURL() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 640)
        )
        let controller = KioskBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }
        controller.browserState.handleNewTabFromChromium(Tab(
            guid: 42,
            url: "chrome://settings/privacy",
            isActive: false,
            index: 0,
            windowId: state.windowId
        ))

        XCTAssertTrue(controller.handleCommand(.IDC_FOCUS_LOCATION))

        let omniBoxView = try XCTUnwrap(
            controller.omniBoxContainerViewController?.omniBoxController?.view
        )
        XCTAssertEqual(
            findTextField(in: omniBoxView)?.stringValue,
            "phi://settings/privacy"
        )
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
                    originalCenterY - 6,
                    accuracy: 0.5
                )
            }
        }

        try assertTrafficLightsAreShifted()
        XCTAssertEqual(
            titlebarContainer.frame.height,
            trafficLightButtons[0].frame.height
                + 2 * (originalTopMargin + 6),
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
        XCTAssertEqual(toolbar.controlCenterYsForTesting.count, 3)
        for centerY in toolbar.controlCenterYsForTesting {
            XCTAssertEqual(
                centerY,
                toolbar.bounds.midY,
                accuracy: 0.5
            )
            XCTAssertEqual(
                centerY,
                trafficLightCenterY,
                accuracy: 0.5
            )
        }
    }

    private func makeWindow(frame: NSRect) -> NSWindow {
        NSWindow(
            contentRect: frame,
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
            ],
            backing: .buffered,
            defer: false
        )
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

    func testKioskOmniBoxHidesAboutBlankFromInput() throws {
        let state = try makeState()
        let tab = Tab(
            guid: 42,
            url: "about:blank",
            isActive: false,
            index: 0,
            windowId: state.windowId
        )
        state.handleNewTabFromChromium(tab)
        let viewModel = OmniBoxViewModel(windowState: state)
        viewModel.updateInputText("previous value")

        viewModel.updateStatus(with: tab, suppressAutomaticSearch: true)

        XCTAssertEqual(viewModel.state.inputText, "")
        XCTAssertTrue(viewModel.opennedFromCurrentTab)
    }

    func testKioskOmniBoxHidesSwitchToTabHint() throws {
        let state = try makeState()
        let container = OmniBoxContainerViewController(browserState: state)
        let omniBox = try XCTUnwrap(container.omniBoxController)
        let suggestion = OmniBoxSuggestion(
            type: .url,
            title: "Example",
            url: "https://example.com",
            index: 0,
            stringToFill: "https://example.com",
            swapContentsAndDescription: false,
            hasTabMatch: true
        )
        let kioskCell = OmniBoxSuggestionCellView(
            suggestion: suggestion,
            index: 0,
            showsSwitchToTabHint: omniBox.showsSwitchToTabHintForTesting
        )
        let regularCell = OmniBoxSuggestionCellView(
            suggestion: suggestion,
            index: 0,
            showsSwitchToTabHint: true
        )

        XCTAssertFalse(omniBox.showsSwitchToTabHintForTesting)
        XCTAssertTrue(kioskCell.isSwitchToTabViewHiddenForTesting)
        XCTAssertFalse(regularCell.isSwitchToTabViewHiddenForTesting)
    }

    func testKioskOmniBoxDismissalRestoresWindowInteraction() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let controller = MainBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account,
            browserState: state
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }

        window.makeKeyAndOrderFront(nil)
        controller.toggleOmniBox(fromAddressBar: false)
        let hostPanel = try XCTUnwrap(controller.omniBoxHostPanel)
        XCTAssertTrue(hostPanel.parent === window)
        XCTAssertFalse(hostPanel.ignoresMouseEvents)

        controller.omniBoxContainerViewController?.hideOmniBox()
        let observerDrained = expectation(description: "Overlay observer drained")
        DispatchQueue.main.async {
            observerDrained.fulfill()
        }
        wait(for: [observerDrained], timeout: 1)

        XCTAssertTrue(hostPanel.ignoresMouseEvents)
    }

    func testOmniBoxHostPanelSharesWindowLevelAndRetiresOnDismissal() throws {
        let state = try makeState()
        let window = makeWindow(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480)
        )
        let controller = MainBrowserWindowController(
            window: window,
            windowId: state.windowId,
            browserType: .kiosk,
            profileId: state.profileId,
            account: state.localStore.account,
            browserState: state
        )
        defer {
            window.close()
            withExtendedLifetime(controller) {}
        }

        window.makeKeyAndOrderFront(nil)
        controller.toggleOmniBox(fromAddressBar: false)
        let hostPanel = try XCTUnwrap(controller.omniBoxHostPanel)

        // Any level above the window's own would lift the overlay out of the
        // inter-app window order, leaving the omnibox floating over whatever
        // app the user switches to.
        XCTAssertEqual(hostPanel.level, window.level)

        controller.omniBoxContainerViewController?.hideOmniBox()
        let observerDrained = expectation(description: "Overlay observer drained")
        DispatchQueue.main.async {
            observerDrained.fulfill()
        }
        wait(for: [observerDrained], timeout: 1)

        // A dismissed omnibox leaves no window behind.
        XCTAssertNil(hostPanel.parent)
        XCTAssertFalse(hostPanel.isVisible)
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

    private func containsThemedHostingView(in view: NSView) -> Bool {
        if view is ThemedHostingView {
            return true
        }
        return view.subviews.contains(where: containsThemedHostingView)
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
    @objc dynamic var isDiscarded = false
    @objc dynamic var isUnloaded = false
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
    func updateIsPeekSurface(_ isPeekSurface: Bool) {}
    func focus() {}
    func restoreFocus() {}
    func updateSecurityState(_ securityState: [AnyHashable: Any]) {}
    func setAudioMuted(_ muted: Bool) {}
    func muteAudio() {}
    func unmuteAudio() {}
}
