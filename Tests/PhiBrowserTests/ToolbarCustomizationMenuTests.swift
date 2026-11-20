// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
@testable import Phi

/// Items are found by identifier or represented object, never by title: the
/// test host may run in another language.
@MainActor
final class ToolbarCustomizationMenuTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Site Menu

    func testTheAddressMenuAlwaysOffersCustomize() {
        let menu = WebContentAddressBarMenuPresenter.makeMenu(browserState: nil, currentTab: nil, showsSiteMemoriesEntry: false, onCustomize: {})
        XCTAssertEqual(menu.items.last?.title, ToolbarCustomizationMenu.customizeItem(action: {}).title)
        XCTAssertEqual(menu.items.last?.identifier, ToolbarCustomizationMenu.customizeItemIdentifier)
    }

    func testTheAddressMenuCustomizeItemFiresAfterTheMenuIsReturned() throws {
        var customized = 0
        let menu = WebContentAddressBarMenuPresenter.makeMenu(
            browserState: nil, currentTab: nil, showsSiteMemoriesEntry: false,
            onCustomize: { customized += 1 }
        )
        let index = try XCTUnwrap(menu.items.lastIndex {
            $0.identifier == ToolbarCustomizationMenu.customizeItemIdentifier
        })
        menu.performActionForItem(at: index)
        XCTAssertEqual(customized, 1)
    }

    func testTheAddressMenuOffersSiteMemoriesOnlyWhenTheButtonIsNotShown() {
        func hasEntry(_ shows: Bool) -> Bool {
            WebContentAddressBarMenuPresenter.makeMenu(
                browserState: nil, currentTab: nil, showsSiteMemoriesEntry: shows, onCustomize: {}
            ).items.contains { $0.identifier == WebContentAddressBarMenuPresenter.siteMemoriesItemIdentifier }
        }
        XCTAssertFalse(hasEntry(false))
        XCTAssertTrue(hasEntry(true))
    }

    func testSiteMemoriesFromARightClickOpensAtTheRightClick() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let anchor = NSView(frame: NSRect(x: 100, y: 10, width: 600, height: 26))
        window.contentView?.addSubview(anchor)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 450, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        XCTAssertEqual(WebContentAddressBarMenuPresenter.memoryMenuLocation(for: event, in: anchor), NSPoint(x: 350, y: 10))
        XCTAssertNil(WebContentAddressBarMenuPresenter.memoryMenuLocation(for: nil, in: anchor),
                     "the Site Menu button opens it under the anchor")
    }

    func testTheSiteMemoriesButtonShowsOnlyWhereItIsPlacedAndDrawn() {
        var arrangement = ToolbarArrangement.standard
        XCTAssertTrue(arrangement.showsSiteMemoriesButton, "Standard draws the address zones")

        arrangement.addressBarStyle = .minimal
        XCTAssertTrue(arrangement.showsSiteMemoriesButton, "Minimal draws the address zones too")

        arrangement.place(.siteMemories, in: .right, at: 0)
        XCTAssertTrue(arrangement.showsSiteMemoriesButton, "Minimal draws the side zones")

        arrangement.addressBarStyle = .standard
        arrangement.remove(.siteMemories)
        XCTAssertFalse(arrangement.showsSiteMemoriesButton, "A removed button is not drawn")
    }

    func testARemovedAddressBarHidesTheSiteMemoriesButtonInIt() {
        var arrangement = ToolbarArrangement.standard
        arrangement.showsAddressBar = false
        XCTAssertFalse(arrangement.showsSiteMemoriesButton, "the Site Menu offers Site Memories instead")
        arrangement.place(.siteMemories, in: .left, at: 0)
        XCTAssertTrue(arrangement.showsSiteMemoriesButton)
    }

    func testARemovedMinimalAddressBarHidesTheSiteMemoriesButtonInIt() {
        var arrangement = ToolbarArrangement.standard
        arrangement.addressBarStyle = .minimal
        arrangement.place(.siteMemories, in: .addressLeading, at: 0)
        XCTAssertTrue(arrangement.showsSiteMemoriesButton, "in front of the centered address")
        arrangement.showsAddressBar = false
        XCTAssertFalse(arrangement.showsSiteMemoriesButton)
    }

    // MARK: - Toolbar right-click

    func testTheToolbarOffersTheSiteMenuWhileTheAddressBarIsRemoved() {
        XCTAssertEqual(WebContentHeader.contextMenuChoice(showsAddressBar: false, isOverAddressBar: false), .siteMenu)
        XCTAssertEqual(WebContentHeader.contextMenuChoice(showsAddressBar: true, isOverAddressBar: true), .siteMenu)
        XCTAssertEqual(WebContentHeader.contextMenuChoice(showsAddressBar: true, isOverAddressBar: false), .customizeToolbar)
    }

    func testTheSiteMemoriesEntryNeedsAPageWithMemories() {
        var arrangement = ToolbarArrangement.standard
        arrangement.remove(.siteMemories)
        XCTAssertFalse(WebContentAddressBarMenuPresenter.showsSiteMemoriesEntry(
            arrangement: arrangement, browserState: nil, currentTab: nil
        ))
    }

    // MARK: - Tab strip

    func testTheTabStripButtonsMenuKeepsOnlyProfileAndCustomize() throws {
        let submenu = try buttonsSubmenu(isHorizontalLayout: true)
        XCTAssertEqual(
            submenu.items.compactMap { $0.representedObject as? String },
            [PhiPreferences.GeneralSettings.topBarShowsProfile.rawValue]
        )
        XCTAssertTrue(submenu.items.contains { $0.identifier == ToolbarCustomizationMenu.customizeItemIdentifier })
    }

    func testTheTabStripCustomizeItemIsDisabledInAnEmptyWindow() throws {
        let state = try makeBrowserState()
        func customizeItem() throws -> NSMenuItem {
            let helper = TabAreaContextMenuHelper(browserState: state, isHorizontalLayout: true)
            let menu = NSMenu()
            helper.populate(menu)
            return try XCTUnwrap(menu.items.last?.submenu?.items.first { $0.identifier == ToolbarCustomizationMenu.customizeItemIdentifier })
        }
        XCTAssertNotNil(try customizeItem().action)

        state.enterPlaceholderMode(wrapper: PageColorTestWebContentWrapper(urlString: "chrome://dino/"))
        XCTAssertNil(try customizeItem().action, "greyed out: the placeholder has no toolbar to customize")
    }

    func testTheSidebarBottomButtonsMenuIsUnchanged() throws {
        let submenu = try buttonsSubmenu(isHorizontalLayout: false)
        let settings = submenu.items.compactMap { $0.representedObject as? String }
        XCTAssertEqual(Array(settings.prefix(2)), [
            PhiPreferences.GeneralSettings.sidebarBottomBarShowsProfile.rawValue,
            PhiPreferences.GeneralSettings.sidebarBottomBarShowsDownloads.rawValue,
        ])
        XCTAssertFalse(submenu.items.contains { $0.identifier == ToolbarCustomizationMenu.customizeItemIdentifier })
    }

    // MARK: - Helpers

    private func buttonsSubmenu(isHorizontalLayout: Bool) throws -> NSMenu {
        let helper = TabAreaContextMenuHelper(browserState: try makeBrowserState(), isHorizontalLayout: isHorizontalLayout)
        let menu = NSMenu()
        helper.populate(menu)
        return try XCTUnwrap(menu.items.last?.submenu)
    }

    private func makeBrowserState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 8, localStore: store, profileId: "Default")
    }
}
