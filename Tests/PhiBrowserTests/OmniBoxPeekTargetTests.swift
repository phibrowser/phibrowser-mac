// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The address-bar omnibox (Cmd+L, header click) describes
/// `BrowserState.pageCommandTarget`: the peek in front of the focused tab
/// while one is up, else the focused tab. Its URL is what the omnibox
/// prefills, and a submission navigates that page itself — Chromium's
/// CURRENT_TAB open would load the match into the strip-active opener
/// hidden behind the panel.
@MainActor
final class OmniBoxPeekTargetTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?
    /// Matches the model handed to Chromium's `selectSuggestion(atLine:
    /// windowId:disposition:)`. A match aimed at a peek must never land
    /// here: Chromium would open it in the strip-active opener.
    private var chromiumSelections: [(line: Int, disposition: PhiOmniboxSuggestionDisposition)] = []

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func makeModel() throws -> (OmniBoxViewModel, BrowserState) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let model = OmniBoxViewModel(windowState: state, keywordSearchURLBuilder: { _, _ in nil },
                                    searchEngineSpaceShortcutProvider: { false },
                                    suggestionSelector: { [weak self] line, disposition in
                                        self?.chromiumSelections.append((line, disposition))
                                    })
        return (model, state)
    }

    private func makeTab(_ guid: Int, url: String) -> (Tab, BookmarkLayoutTestWebContentWrapper) {
        let tab = Tab(guid: guid, url: url, isActive: false, index: 0)
        let wrapper = BookmarkLayoutTestWebContentWrapper(urlString: url)
        tab.setWebContentsWrapper(wrapper: wrapper)
        return (tab, wrapper)
    }

    /// A focused opener with a peek presented in front of it, and the
    /// omnibox opened from the address bar over that pair.
    private func makePeekedOmniBox() throws -> (model: OmniBoxViewModel, state: BrowserState,
                                                opener: BookmarkLayoutTestWebContentWrapper,
                                                peek: BookmarkLayoutTestWebContentWrapper) {
        let (model, state) = try makeModel()
        let (opener, openerWrapper) = makeTab(1, url: "https://opener.example/a")
        let (peek, peekWrapper) = makeTab(2, url: "https://peek.example/b")
        state.tabs = [opener]
        state.focusingTab = opener
        state.peekState.present(peek, openerTabId: opener.guid)
        model.updateStatus(with: state.pageCommandTarget, suppressAutomaticSearch: true)
        return (model, state, openerWrapper, peekWrapper)
    }

    private func urlResult(_ url: String, line: Int = 0) -> [String: Any] {
        ["type": "url-what-you-typed", "contents": url, "description": "",
         "destinationUrl": url, "fillIntoEdit": url, "line": line,
         "allowedToBeDefaultMatch": true]
    }

    private func deliver(_ results: [[String: Any]], query: String, to state: BrowserState) {
        state.searchSuggestionChanged.send((results, query))
        let delivered = expectation(description: "Autocomplete response delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }

    func testAddressBarOpenPrefillsThePresentedPeeksURL() throws {
        let (model, state, _, _) = try makePeekedOmniBox()

        XCTAssertEqual(model.state.inputText, "https://peek.example/b")
        XCTAssertTrue(model.currentTab === state.peekState.peek(forOpener: 1))
        XCTAssertTrue(model.opennedFromCurrentTab,
                      "A peek's tab is a plain page: a submission navigates it rather than a new tab")
    }

    func testAddressBarOpenFollowsThePeeksLatestURL() throws {
        let (model, state, _, peek) = try makePeekedOmniBox()
        peek.navigate(toURL: "https://peek.example/redirected")

        model.updateStatus(with: state.pageCommandTarget, suppressAutomaticSearch: true)

        XCTAssertEqual(model.state.inputText, "https://peek.example/redirected")
    }

    func testSubmittingASuggestionNavigatesThePeekNotTheOpenerBehindIt() throws {
        let (model, state, opener, peek) = try makePeekedOmniBox()
        model.updateInputText("https://peek.example/c")
        deliver([urlResult("https://peek.example/c")], query: "https://peek.example/c", to: state)
        XCTAssertEqual(model.state.selectedSuggestion?.url, "https://peek.example/c")

        model.handleEnterPressed()

        XCTAssertEqual(peek.urlString, "https://peek.example/c")
        XCTAssertEqual(opener.urlString, "https://opener.example/a")
        XCTAssertTrue(chromiumSelections.isEmpty,
                      "The match must not reach Chromium, whose CURRENT_TAB open lands in the opener")
        XCTAssertNotNil(state.peekState.peek(forOpener: 1), "The peek stays up, now showing the new page")
    }

    func testSubmittingTypedTextNavigatesThePeek() throws {
        let (model, state, opener, peek) = try makePeekedOmniBox()
        model.updateInputText("https://peek.example/typed")

        model.handleEnterPressed()

        XCTAssertEqual(peek.urlString, "https://peek.example/typed")
        XCTAssertEqual(opener.urlString, "https://opener.example/a")
        XCTAssertNotNil(state.peekState.peek(forOpener: 1))
    }

    /// Without a peek the focused tab is strip-active, so Chromium's own
    /// CURRENT_TAB open (shortcut learning included) still handles the
    /// match; nothing is navigated natively.
    func testSubmittingASuggestionWithoutAPeekLeavesTheOpenToChromium() throws {
        let (model, state) = try makeModel()
        let (tab, wrapper) = makeTab(1, url: "https://opener.example/a")
        state.tabs = [tab]
        state.focusingTab = tab
        model.updateStatus(with: state.pageCommandTarget, suppressAutomaticSearch: true)
        model.updateInputText("https://opener.example/c")
        deliver([urlResult("https://opener.example/c")], query: "https://opener.example/c", to: state)

        model.handleEnterPressed()

        XCTAssertEqual(wrapper.urlString, "https://opener.example/a")
        XCTAssertEqual(chromiumSelections.count, 1)
        XCTAssertEqual(chromiumSelections.first?.line, 0)
        XCTAssertEqual(chromiumSelections.first?.disposition, .currentTab)
    }

    func testClosingThePeekHandsTheAddressBarBackToTheOpener() throws {
        let (model, state, _, _) = try makePeekedOmniBox()
        state.peekState.removePeek(forOpener: 1)

        model.updateStatus(with: state.pageCommandTarget, suppressAutomaticSearch: true)

        XCTAssertEqual(model.state.inputText, "https://opener.example/a")
        XCTAssertTrue(model.currentTab === state.focusingTab)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    // MARK: - The peek closing under the omnibox

    /// A peek closing itself (page JS `window.close()`) leaves the opener
    /// focused, so the container's focus observer never fires; the omnibox
    /// has lost the page it describes and must go anyway.
    func testThePeekClosingUnderTheOmniBoxDismissesIt() throws {
        let (model, state, _, _) = try makePeekedOmniBox()
        let spy = OmniBoxClearSpy()
        model.delegate = spy

        state.peekState.removePeek(forOpener: 1)
        drainMainQueue()

        XCTAssertEqual(spy.clears, 1)
    }

    /// Another opener's peek coming or going is not this omnibox's business.
    func testAnotherOpenersPeekClosingLeavesTheOmniBoxUp() throws {
        let (model, state, _, _) = try makePeekedOmniBox()
        let spy = OmniBoxClearSpy()
        model.delegate = spy
        let (otherOpener, _) = makeTab(3, url: "https://other.example/a")
        let (otherPeek, _) = makeTab(4, url: "https://other.example/b")
        state.tabs.append(otherOpener)
        state.peekState.present(otherPeek, openerTabId: otherOpener.guid)
        drainMainQueue()
        XCTAssertEqual(spy.clears, 0)

        state.peekState.removePeek(forOpener: otherOpener.guid)
        drainMainQueue()

        XCTAssertEqual(spy.clears, 0)
    }

    /// An omnibox aimed at a strip tab ignores peeks appearing and closing.
    func testAPeekChangeDoesNotDismissAnOmniBoxAimedAtAStripTab() throws {
        let (model, state) = try makeModel()
        let (tab, _) = makeTab(1, url: "https://opener.example/a")
        state.tabs = [tab]
        state.focusingTab = tab
        model.updateStatus(with: state.pageCommandTarget, suppressAutomaticSearch: true)
        let spy = OmniBoxClearSpy()
        model.delegate = spy
        let (peek, _) = makeTab(2, url: "https://peek.example/b")

        state.peekState.present(peek, openerTabId: tab.guid)
        state.peekState.removePeek(forOpener: tab.guid)
        drainMainQueue()

        XCTAssertEqual(spy.clears, 0)
    }

    /// Enter landing before the dismissal sink: the submission is dropped —
    /// neither the opener behind the vanished panel nor the dead peek is
    /// navigated — and the omnibox closes as after any submission.
    func testSubmittingASuggestionAfterThePeekClosedDropsTheSubmission() throws {
        let (model, state, opener, peek) = try makePeekedOmniBox()
        model.updateInputText("https://peek.example/c")
        deliver([urlResult("https://peek.example/c")], query: "https://peek.example/c", to: state)
        let spy = OmniBoxClearSpy()
        model.delegate = spy
        state.peekState.removePeek(forOpener: 1)

        model.handleEnterPressed()

        XCTAssertEqual(peek.urlString, "https://peek.example/b")
        XCTAssertEqual(opener.urlString, "https://opener.example/a")
        XCTAssertTrue(chromiumSelections.isEmpty, "A dropped submission is not handed to Chromium either")
        XCTAssertEqual(spy.clears, 1)
        drainMainQueue()
        XCTAssertEqual(spy.clears, 1, "The late dismissal sink must not clear a second time")
    }

    func testSubmittingTypedTextAfterThePeekClosedDropsTheSubmission() throws {
        let (model, state, opener, peek) = try makePeekedOmniBox()
        model.updateInputText("https://peek.example/typed")
        state.peekState.removePeek(forOpener: 1)

        model.handleEnterPressed()

        XCTAssertEqual(peek.urlString, "https://peek.example/b")
        XCTAssertEqual(opener.urlString, "https://opener.example/a")
    }
}

/// Stands in for the omnibox container: `omniBoxDidClear` is what hides the
/// overlay.
private final class OmniBoxClearSpy: OmniBoxActionDelegate {
    var clears = 0
    func omniBoxDidClear() { clears += 1 }
}
