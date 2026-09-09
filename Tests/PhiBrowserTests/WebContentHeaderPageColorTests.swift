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

    override func tearDown() async throws {
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

    func testTabStripInheritsWhileChatIsExpandedAndRestoresLatestPageColor() throws {
        let key = PhiPreferences.GeneralSettings.layoutModeKey
        let originalMode = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(LayoutMode.comfortable.rawValue, forKey: key)
        defer { UserDefaults.standard.set(originalMode, forKey: key) }

        let state = try makeState()
        let (tab, wrapper) = makeTab(color: .black)
        let controller = WebContentViewController(state: state, tab: tab)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let header = try XCTUnwrap(controller.leftContainerViewForTesting.subviews
            .compactMap { $0 as? WebContentHeader }.first)
        header.currentTab = tab
        let split = try XCTUnwrap(controller.children.compactMap { $0 as? NSSplitViewController }.first)
        let chat = try XCTUnwrap(split.splitViewItems.last)
        XCTAssertEqual(split.splitViewItems.count, 2)

        var presentation = WebContentHeaderPageColorPresentation.inherited
        let subscription = controller.tabStripPageColorPresentationPublisher.sink { presentation = $0 }
        defer { subscription.cancel() }
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(presentation.appearance, .dark)

        chat.isCollapsed = false
        XCTAssertEqual(presentation, .inherited)
        XCTAssertEqual(controller.tabStripPageColorPresentation, .inherited)
        assertBackground(header, .black)

        wrapper.pageColor = .white
        drainPageColorUpdates()
        XCTAssertEqual(presentation, .inherited)
        assertBackground(header, .white)
        var restoredPresentation: WebContentHeaderPageColorPresentation?
        let restoredSubscription = controller.tabStripPageColorPresentationPublisher
            .sink { restoredPresentation = $0 }
        defer { restoredSubscription.cancel() }
        XCTAssertEqual(restoredPresentation, .inherited)

        chat.isCollapsed = true
        XCTAssertEqual(presentation, header.pageColorPresentation)
        XCTAssertEqual(controller.tabStripPageColorPresentation, presentation)
        XCTAssertEqual(presentation.appearance, .light)
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

    private func assertBackground(_ header: WebContentHeader, _ expected: NSColor,
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
