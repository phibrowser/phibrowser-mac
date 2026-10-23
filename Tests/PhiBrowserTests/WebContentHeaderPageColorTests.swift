// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class WebContentHeaderPageColorTests: XCTestCase {
    private var directories: [URL] = []
    private var stores: [LocalStore] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
        for store in stores { try await store.closeForAccountDirectoryRemoval() }
        stores.removeAll()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testDarkPageChangesParentAndDescendantAppearanceOnly() throws {
        let state = try makeState()
        let (tab, _) = makeTab(color: .black)
        let header = WebContentHeader(browserState: state)
        let anchor = NSView()
        header.addSubview(anchor)
        header.currentTab = tab

        assertBackground(header, .black)
        XCTAssertEqual(header.appearance?.phiAppearance, .dark)
        XCTAssertEqual(anchor.effectiveAppearance.phiAppearance, .dark)
        XCTAssertEqual(state.themeContext.currentAppearance, .light)
        XCTAssertEqual(state.themeContext.currentTheme.id, Theme.pure.id)
    }

    func testNewTabHeaderMatchesExtensionSurfaceAndRestoresPageColorsOnNavigation() throws {
        let state = try makeState()
        let base = state.themeContext.currentTheme
        let palette = ThemePalette(hue: 0.85, saturation: 0.8, colorCount: 3)
        state.themeContext.setTheme(palette.applying(to: base))
        let (tab, wrapper) = makeTab(color: .black)
        wrapper.urlString = "chrome://newtab/"
        drainPageColorUpdates()
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab

        assertBackground(header, .white)
        XCTAssertNil(header.pageColorPresentation.appearance)
        XCTAssertNotNil(header.pageColorPresentation.backgroundColor,
                        "The address bar and adjacent chrome must inherit the same new-tab color.")

        wrapper.urlString = "https://example.com"
        drainPageColorUpdates()
        assertBackground(header, .black)
        XCTAssertEqual(header.pageColorPresentation.appearance, .dark)
        wrapper.pageColor = .white
        drainPageColorUpdates()
        assertBackground(header, .white)
        XCTAssertEqual(header.pageColorPresentation.appearance, .light)

        let changed = palette.rotatingHue(by: 0.3)
        state.themeContext.setTheme(changed.applying(to: base))
        drainPageColorUpdates()
        assertBackground(header, .white)
        wrapper.pageColor = nil
        drainPageColorUpdates()
        assertBackground(header, base.color(for: .windowBackground, appearance: .light))
        XCTAssertNil(header.pageColorPresentation.backgroundColor)

        wrapper.urlString = "phi://newtab/"
        drainPageColorUpdates()
        assertBackground(header, .white)
        state.themeContext.setUserAppearanceChoice(.dark)
        drainPageColorUpdates()
        let primary = changed.colors(for: .dark)[0].usingColorSpace(.sRGB)!
        assertBackground(header, NSColor(srgbRed: primary.redComponent * 0.20,
                                         green: primary.greenComponent * 0.20,
                                         blue: primary.blueComponent * 0.20, alpha: 1))
        XCTAssertNil(header.appearance, "New-tab chrome follows the window appearance.")
    }

    func testTranslucentPageHeaderRemainsIndependentOfPaletteEdits() throws {
        let state = try makeState()
        let base = state.themeContext.currentTheme
        let pageColor = NSColor(srgbRed: 0.1, green: 0.25, blue: 0.4, alpha: 0.35)
        let expected = WebContentHeader.compositePageColor(
            pageColor, over: base.color(for: .windowBackground, appearance: .light)
        )
        let (tab, _) = makeTab(color: pageColor)
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        for hue in [0.0, 0.33, 0.66] {
            state.themeContext.setTheme(ThemePalette(hue: hue, saturation: 1, colorCount: 3).applying(to: base))
            drainPageColorUpdates()
            assertBackground(header, expected)
        }
    }

    func testDarkInternalAndMissingTabHeadersShareTheNtpTopColor() throws {
        let state = try makeState()
        let theme = ThemePalette(hue: 0.2, saturation: 0.7, colorCount: 3)
            .applying(to: state.themeContext.currentTheme)
        state.themeContext.setTheme(theme)
        state.themeContext.setUserAppearanceChoice(.dark)
        let primary = theme.color(for: .windowOverlayBackground, appearance: .dark)
            .usingColorSpace(.sRGB)!
        let expected = NSColor(srgbRed: primary.redComponent * 0.20,
                               green: primary.greenComponent * 0.20,
                               blue: primary.blueComponent * 0.20, alpha: 1)
        let header = WebContentHeader(browserState: state)
        assertBackground(header, expected)
        let (tab, wrapper) = makeTab(color: .red)
        for url in ["chrome://newtab/", "phi://newtab/", "chrome://conversation/", "phi://skills/"] {
            wrapper.urlString = url
            header.currentTab = tab
            drainPageColorUpdates()
            assertBackground(header, expected)
            XCTAssertNil(header.pageColorPresentation.appearance)
        }
        wrapper.urlString = "https://example.com"
        drainPageColorUpdates()
        assertBackground(header, .red)
        wrapper.pageColor = nil
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
    }

    func testTabStripInheritsWhileChatIsExpandedAndRestoresLatestPageColor() throws {
        let key = PhiPreferences.GeneralSettings.layoutModeKey
        let originalMode = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: key)
        defer { UserDefaults.standard.set(originalMode, forKey: key) }
        // Expanding the chat is gated on the AI switch.
        let aiKey = PhiPreferences.AISettings.phiAIEnabled.rawValue
        let originalAI = UserDefaults.standard.object(forKey: aiKey)
        UserDefaults.standard.set(true, forKey: aiKey)
        defer { UserDefaults.standard.set(originalAI, forKey: aiKey) }

        let state = try makeState()
        state.aiChatTabCreationGateOverrideForTesting = false
        let (tab, wrapper) = makeTab(color: .black)
        state.tabs = [tab]
        state.focusingTab = tab
        let controller = WebContentViewController(state: state, tab: tab)
        showInWindow(controller)
        let header = try XCTUnwrap(controller.leftContainerViewForTesting.subviews
            .compactMap { $0 as? WebContentHeader }.first)
        header.currentTab = tab
        let bookmarkBar = BookmarkBar(browserState: state)
        controller.attachBookmarkBar(bookmarkBar)
        let bookmarkLabel = NSTextField(labelWithString: "Bookmark")
        bookmarkBar.addSubview(bookmarkLabel)
        assertBackground(bookmarkBar, .black)
        XCTAssertEqual(bookmarkLabel.effectiveAppearance.phiAppearance, .dark)
        let split = try XCTUnwrap(controller.children.compactMap { $0 as? NSSplitViewController }.first)
        let chat = try XCTUnwrap(split.splitViewItems.last)
        XCTAssertEqual(split.splitViewItems.count, 2)

        var presentation = WebContentHeaderPageColorPresentation.inherited
        let subscription = controller.tabStripPageColorPresentationPublisher.sink { presentation = $0 }
        defer { subscription.cancel() }
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(presentation.appearance, .dark)

        // The tab strip follows the page card, which separates once the
        // chat's split item expands.
        state.toggleAIChat(false)
        waitUntil { !chat.isCollapsed && presentation == .inherited }
        XCTAssertEqual(controller.tabStripPageColorPresentation, .inherited)
        assertBackground(header, .black)
        assertBackground(bookmarkBar, .black)
        XCTAssertEqual(bookmarkBar.appearance?.phiAppearance, .dark)

        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertEqual(presentation, .inherited)
        assertBackground(header, .white)
        assertBackground(bookmarkBar, .white)
        XCTAssertEqual(bookmarkLabel.effectiveAppearance.phiAppearance, .light)
        var restoredPresentation: WebContentHeaderPageColorPresentation?
        let restoredSubscription = controller.tabStripPageColorPresentationPublisher
            .sink { restoredPresentation = $0 }
        defer { restoredSubscription.cancel() }
        XCTAssertEqual(restoredPresentation, .inherited)

        // The card, and the tab strip with it, rejoins the header once the
        // collapse animation ends.
        state.toggleAIChat(true)
        waitUntil { presentation != .inherited }
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
        XCTAssertEqual(presentation.appearance, .light)
        assertBackground(bookmarkBar, .white)
    }

    func testTabStripInheritsWhileReaderIsPresentedAndRestoresLatestPageColor() throws {
        let key = PhiPreferences.GeneralSettings.layoutModeKey
        let originalMode = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: key)
        defer { UserDefaults.standard.set(originalMode, forKey: key) }

        let state = try makeState()
        let (tab, wrapper) = makeTab(guid: 1, color: .black)
        let (otherTab, _) = makeTab(guid: 2, color: .black)
        let (reader, _) = makeTab(guid: 3, color: .white)
        state.tabs = [tab, otherTab]
        state.focusingTab = tab
        let controller = WebContentViewController(state: state, tab: tab)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let header = try XCTUnwrap(controller.leftContainerViewForTesting.subviews
            .compactMap { $0 as? WebContentHeader }.first)
        header.currentTab = tab

        var presentation = WebContentHeaderPageColorPresentation.inherited
        let subscription = controller.tabStripPageColorPresentationPublisher.sink { presentation = $0 }
        defer { subscription.cancel() }
        XCTAssertEqual(presentation, header.pageColorPresentation)

        state.readerOverlayState.present(reader, originTabId: tab.guid)
        XCTAssertEqual(presentation, .inherited)
        XCTAssertEqual(controller.tabStripPageColorPresentation, .inherited)
        assertBackground(header, .black)

        // Switching between equally colored pages must still update Reader suppression.
        state.focusingTab = otherTab
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
        state.focusingTab = tab
        XCTAssertEqual(presentation, .inherited)

        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertEqual(presentation, .inherited)
        assertBackground(header, .white)
        var initialPresentation: WebContentHeaderPageColorPresentation?
        let initialSubscription = controller.tabStripPageColorPresentationPublisher
            .sink { initialPresentation = $0 }
        defer { initialSubscription.cancel() }
        XCTAssertEqual(initialPresentation, .inherited)

        state.readerOverlayState.removeReader(forOrigin: tab.guid)
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
        XCTAssertEqual(presentation.appearance, .light)

        // A background tab's reader must not suppress the focused page's color.
        state.readerOverlayState.present(reader, originTabId: otherTab.guid)
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
    }

    func testTabStripInheritsWhileExtensionSidePanelIsOpenAndRestoresLatestPageColor() throws {
        let key = PhiPreferences.GeneralSettings.layoutModeKey
        let originalMode = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: key)
        defer { UserDefaults.standard.set(originalMode, forKey: key) }

        let state = try makeState()
        let (tab, wrapper) = makeTab(color: .black)
        let controller = WebContentViewController(state: state, tab: tab)
        showInWindow(controller)
        let header = try XCTUnwrap(controller.leftContainerViewForTesting.subviews
            .compactMap { $0 as? WebContentHeader }.first)
        header.currentTab = tab

        var presentation = WebContentHeaderPageColorPresentation.inherited
        let subscription = controller.tabStripPageColorPresentationPublisher.sink { presentation = $0 }
        defer { subscription.cancel() }
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(presentation.appearance, .dark)

        state.updateExtensionSidePanel(BrowserState.ExtensionSidePanelState(
            extensionId: "test-extension", displayName: "Test Extension", iconPNG: nil,
            wrapper: PageColorTestWebContentWrapper(urlString: "chrome-extension://test/panel.html")
        ))
        // The page card separates on the next turn; the tab strip follows it.
        drainPageColorUpdates()
        XCTAssertEqual(presentation, .inherited)
        XCTAssertEqual(controller.tabStripPageColorPresentation, .inherited)
        assertBackground(header, .black)

        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertEqual(presentation, .inherited)
        assertBackground(header, .white)
        var openPresentation: WebContentHeaderPageColorPresentation?
        let openSubscription = controller.tabStripPageColorPresentationPublisher
            .sink { openPresentation = $0 }
        defer { openSubscription.cancel() }
        XCTAssertEqual(openPresentation, .inherited)

        state.updateExtensionSidePanel(nil)
        drainPageColorUpdates()
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
        XCTAssertEqual(presentation.appearance, .light)
    }

    func testSharedBookmarkBarSwitchesPageSubscriptionAndRestoresThemeFallback() throws {
        let layoutKey = PhiPreferences.GeneralSettings.layoutModeKey
        let bookmarkKey = PhiPreferences.GeneralSettings.alwaysShowBookmarkBar.rawValue
        let originalLayout = UserDefaults.standard.object(forKey: layoutKey)
        let originalBookmarkSetting = UserDefaults.standard.object(forKey: bookmarkKey)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: layoutKey)
        UserDefaults.standard.set(true, forKey: bookmarkKey)
        defer {
            UserDefaults.standard.set(originalLayout, forKey: layoutKey)
            UserDefaults.standard.set(originalBookmarkSetting, forKey: bookmarkKey)
        }

        let state = try makeState()
        let (oldTab, oldWrapper) = makeTab(guid: 1, color: .black)
        let (newTab, newWrapper) = makeTab(guid: 2, color: .white)
        let oldController = WebContentViewController(state: state, tab: oldTab)
        let newController = WebContentViewController(state: state, tab: newTab)
        for (controller, tab) in [(oldController, oldTab), (newController, newTab)] {
            controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            let header = try XCTUnwrap(controller.leftContainerViewForTesting.subviews
                .compactMap { $0 as? WebContentHeader }.first)
            header.currentTab = tab
        }
        let bar = BookmarkBar(browserState: state)
        oldController.attachBookmarkBar(bar)
        assertBackground(bar, .black)
        oldController.detachBookmarkBarIfAttached()
        newController.attachBookmarkBar(bar)
        assertBackground(bar, .white)
        XCTAssertEqual(bar.appearance?.phiAppearance, .light)

        oldWrapper.pageColor = .red
        state.themeContext.setUserAppearanceChoice(.dark)
        drainPageColorUpdates()
        assertBackground(bar, .white)
        XCTAssertEqual(bar.appearance?.phiAppearance, .light)

        newWrapper.pageColor = nil
        drainPageColorUpdates()
        assertBackground(bar, ThemedColor.contentOverlayBackground.resolve(
            theme: state.themeContext.currentTheme, appearance: .dark
        ))
        XCTAssertNil(bar.appearance)

        state.themeContext.setUserAppearanceChoice(.light)
        drainPageColorUpdates()
        assertBackground(bar, ThemedColor.contentOverlayBackground.resolve(
            theme: state.themeContext.currentTheme, appearance: .light
        ))
    }

    func testLightPageOverridesDarkWindowAndNilRestoresInheritance() throws {
        let state = try makeState()
        state.themeContext.setUserAppearanceChoice(.dark)
        let (tab, wrapper) = makeTab(color: .white)
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        assertBackground(header, .white)
        XCTAssertEqual(header.appearance?.phiAppearance, .light)

        wrapper.pageColor = nil
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        XCTAssertNil(header.appearance)
        XCTAssertEqual(state.themeContext.currentAppearance, .dark)
    }

    func testSameGuidReplacementImmediatelyUsesNewTabAndIgnoresOldTab() throws {
        let state = try makeState()
        let (oldTab, oldWrapper) = makeTab(guid: 1, color: .black)
        let (newTab, _) = makeTab(guid: 1, color: .white)
        let header = WebContentHeader(browserState: state)
        header.currentTab = oldTab
        oldWrapper.pageColor = .red
        header.currentTab = newTab
        assertBackground(header, .white)
        drainPageColorUpdates()
        assertBackground(header, .white)
    }

    func testIndependentHeadersKeepTheirOwnTabColor() throws {
        let state = try makeState()
        let otherState = try makeState()
        let (tab, _) = makeTab(guid: 1, color: .black)
        let (otherTab, otherWrapper) = makeTab(guid: 2, color: .white)
        let header = WebContentHeader(browserState: state)
        let otherHeader = WebContentHeader(browserState: otherState)
        header.currentTab = tab
        otherHeader.currentTab = otherTab
        otherWrapper.pageColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        drainPageColorUpdates()
        assertBackground(header, .black)
        assertBackground(otherHeader, try XCTUnwrap(otherTab.pageColor))
    }

    func testSplitMembershipDisablesColorAndDissolutionRestoresIt() throws {
        let state = try makeState()
        let (tab, wrapper) = makeTab(guid: 1, color: .black)
        let (partner, _) = makeTab(guid: 2, color: .white)
        state.tabs = [tab, partner]
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        state.splits = [SplitGroup(id: "page-color-split", primaryTabId: 1,
                                  secondaryTabId: 2, layout: .vertical, ratio: 0.5)]
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        XCTAssertNil(header.appearance)
        header.currentTab = partner
        assertBackground(header, fallback(state))
        wrapper.pageColor = .white
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        state.splits = []
        drainPageColorUpdates()
        assertBackground(header, .white)
        XCTAssertEqual(header.appearance?.phiAppearance, .light)
    }

    func testThemeUpdatesPreserveOverrideAndRefreshNilFallback() throws {
        let state = try makeState()
        let (tab, wrapper) = makeTab(color: .black)
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        state.themeContext.setUserAppearanceChoice(.dark)
        drainPageColorUpdates()
        assertBackground(header, .black)
        wrapper.pageColor = nil
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        state.themeContext.setUserAppearanceChoice(.light)
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        XCTAssertNil(header.appearance)
    }

    func testNativePagesCrashAndMissingTabRestoreFallback() throws {
        let state = try makeState()
        let (tab, wrapper) = makeTab(color: .black)
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        wrapper.urlString = "chrome://newtab/"
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        XCTAssertNil(header.appearance)
        wrapper.urlString = "https://example.com"
        drainPageColorUpdates()
        assertBackground(header, .black)
        tab.crashState = CrashPageData(dictionary: [:])
        drainPageColorUpdates()
        assertBackground(header, fallback(state))
        tab.crashState = nil
        drainPageColorUpdates()
        assertBackground(header, .black)
        header.currentTab = nil
        assertBackground(header, fallback(state))
        XCTAssertNil(header.appearance)
    }

    func testTranslucentPageUsesCompositedColorForContrast() throws {
        let state = try makeState()
        let color = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1)
        let (tab, _) = makeTab(color: color)
        let header = WebContentHeader(browserState: state)
        header.currentTab = tab
        XCTAssertEqual(tab.pageColor?.alphaComponent, 0.1)
        XCTAssertEqual(header.appearance?.phiAppearance, .light)

        let result = WebContentHeader.compositePageColor(color, over: .white)
        XCTAssertEqual(result.redComponent, 0.9, accuracy: 0.001)
        XCTAssertEqual(result.alphaComponent, 1, accuracy: 0.001)
        let translucentResult = WebContentHeader.compositePageColor(
            color, over: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        )
        XCTAssertEqual(translucentResult.alphaComponent, 0.55, accuracy: 0.001)
    }

    private func makeState() throws -> BrowserState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        stores.append(store)
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        state.themeContext.mirrorsSharedTheme = false
        state.themeContext.mirrorsSharedAppearance = false
        state.themeContext.setTheme(.pure)
        state.themeContext.setUserAppearanceChoice(.light)
        return state
    }

    /// Puts the controller on screen. It installs its AI Chat and extension
    /// side panel subscriptions on first appearance, and those drive the page
    /// card the tab strip follows.
    private func showInWindow(_ controller: WebContentViewController) {
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: controller.view.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        windows.append(window)
    }

    /// Runs the run loop until `condition` holds (the AI Chat animations
    /// included), for at most two seconds.
    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    private func makeTab(guid: Int = 1, color: NSColor?) -> (Tab, PageColorTestWebContentWrapper) {
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://example.com")
        wrapper.pageColor = color
        let tab = Tab(guid: guid, url: wrapper.urlString, isActive: true, index: 0, webContentView: wrapper)
        return (tab, wrapper)
    }

    private func fallback(_ state: BrowserState) -> NSColor {
        ThemedColor.windowBackground.resolve(theme: state.themeContext.currentTheme,
                                            appearance: state.themeContext.currentAppearance)
    }

    private func assertBackground(_ header: NSView, _ expected: NSColor,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let cgColor = header.layer?.backgroundColor,
              let actual = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else {
            XCTFail("Expected an sRGB header background", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}
