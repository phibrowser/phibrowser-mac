// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// `BrowserState.pageCommandTarget`: the page a page-scoped command
/// (Reload, Bookmark, Share, Save to Folio, Copy URL, screenshot) acts on.
/// A peek's tab is never the focused strip tab — its opener stays focused
/// beneath the panel — so the target is the peek on screen when one is up,
/// else the focused tab.
@MainActor
final class BrowserStatePageCommandTargetTests: XCTestCase {
    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in tempDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        tempDirectories.removeAll()
    }

    private func makeState() throws -> BrowserState {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectories.append(directory)
        let store = LocalStore(account: Account(userID: UUID().uuidString),
                               storeDirectoryURL: directory)
        return BrowserState(windowId: 7, localStore: store, profileId: "Default")
    }

    private func makeTab(_ guid: Int) -> Tab {
        Tab(guid: guid, url: "https://e\(guid).example", isActive: false, index: 0)
    }

    func testFocusedTabIsTheTargetWithoutAPeek() throws {
        let state = try makeState()
        let opener = makeTab(1)
        state.tabs = [opener]
        state.focusingTab = opener

        XCTAssertTrue(state.pageCommandTarget === opener)
    }

    func testNothingIsTargetedWithoutAFocusedTab() throws {
        let state = try makeState()
        XCTAssertNil(state.pageCommandTarget)
    }

    func testThePeekInFrontOfTheFocusedTabIsTheTarget() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        state.tabs = [opener]
        state.focusingTab = opener
        state.peekState.present(peek, openerTabId: opener.guid)

        XCTAssertTrue(state.pageCommandTarget === peek)
    }

    /// Only the focused opener's peek is on screen; another opener's peek
    /// stays hidden and must not capture the focused tab's commands.
    func testAnotherOpenersPeekIsNotTheTarget() throws {
        let state = try makeState()
        let focused = makeTab(1)
        let otherOpener = makeTab(2)
        let hiddenPeek = makeTab(3)
        state.tabs = [focused, otherOpener]
        state.focusingTab = focused
        state.peekState.present(hiddenPeek, openerTabId: otherOpener.guid)

        XCTAssertTrue(state.pageCommandTarget === focused)
    }

    /// A peek covers its opener's whole split, so it stays the target
    /// whichever pane is focused.
    func testASplitPartnersPeekIsTheTarget() throws {
        let state = try makeState()
        let primary = makeTab(1)
        let secondary = makeTab(2)
        let peek = makeTab(3)
        state.tabs = [primary, secondary]
        state.splits = [SplitGroup(id: "split",
                                   primaryTabId: primary.guid,
                                   secondaryTabId: secondary.guid,
                                   layout: .vertical,
                                   ratio: 0.5)]
        state.peekState.present(peek, openerTabId: primary.guid)
        state.focusingTab = secondary

        XCTAssertTrue(state.pageCommandTarget === peek)
    }

    func testClosingThePeekHandsTheTargetBackToTheOpener() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        state.tabs = [opener]
        state.focusingTab = opener
        state.peekState.present(peek, openerTabId: opener.guid)
        state.peekState.removePeek(forOpener: opener.guid)

        XCTAssertTrue(state.pageCommandTarget === opener)
    }

    /// Reader View is the one page command with an extra rule: the opener's
    /// own reader covers the peek, and a toggle must close that reader.
    func testReaderViewTargetPrefersTheOpenersOwnReaderOverThePeek() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        let reader = makeTab(3)
        state.tabs = [opener]
        state.focusingTab = opener
        state.peekState.present(peek, openerTabId: opener.guid)
        XCTAssertTrue(state.readerViewTarget(focusingTab: opener) === peek)

        state.readerOverlayState.present(reader, originTabId: opener.guid)
        XCTAssertTrue(state.readerViewTarget(focusingTab: opener) === opener)
        XCTAssertTrue(state.pageCommandTarget === peek)
    }

    // MARK: - Address bar Copy URL

    /// The address bar's Copy URL button resolves its URL through the same
    /// rule as the command, so a presented peek is what both put on the
    /// clipboard — not the opener hidden behind the panel.
    func testAddressBarCopyURLFollowsThePresentedPeek() throws {
        let state = try makeState()
        let opener = makeTab(1)
        let peek = makeTab(2)
        state.tabs = [opener]
        state.focusingTab = opener
        state.peekState.present(peek, openerTabId: opener.guid)

        XCTAssertEqual(state.addressBarCopyURLString(for: opener), "https://e2.example")
        XCTAssertNotEqual(state.addressBarCopyURLString(for: opener), "https://e1.example")
    }

    func testAddressBarCopyURLIsTheBarTabsURLWithoutAPeek() throws {
        let state = try makeState()
        let opener = makeTab(1)
        state.tabs = [opener]
        state.focusingTab = opener

        XCTAssertEqual(state.addressBarCopyURLString(for: opener), "https://e1.example")
    }

    /// Only the bar's own opener's peek is on screen; another opener's peek
    /// stays hidden and must not be copied.
    func testAddressBarCopyURLIgnoresAnotherOpenersPeek() throws {
        let state = try makeState()
        let focused = makeTab(1)
        let otherOpener = makeTab(2)
        let hiddenPeek = makeTab(3)
        state.tabs = [focused, otherOpener]
        state.focusingTab = focused
        state.peekState.present(hiddenPeek, openerTabId: otherOpener.guid)

        XCTAssertEqual(state.addressBarCopyURLString(for: focused), "https://e1.example")
    }

    func testAddressBarCopyURLIsEmptyWithoutATab() throws {
        let state = try makeState()

        XCTAssertNil(state.addressBarCopyURLString(for: nil))
    }

    /// A reader page stands in for its article, whichever caller of the
    /// shared resolution reaches it.
    func testAddressBarCopyURLRecoversTheArticleFromAReaderPage() throws {
        let readerURL = "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html#src=https%3A%2F%2Farticle.example%2Fstory"
        let reader = makeTab(1)
        reader.url = readerURL
        let state = try makeState()
        state.tabs = [reader]
        state.focusingTab = reader

        XCTAssertEqual(state.addressBarCopyURLString(for: reader), "https://article.example/story")
        XCTAssertEqual(BrowserState.copyURLString(forAddressBarShowing: reader), "https://article.example/story")
    }
}
