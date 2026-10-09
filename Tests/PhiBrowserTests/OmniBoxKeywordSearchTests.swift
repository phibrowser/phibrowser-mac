// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import XCTest
@testable import Phi

@MainActor
final class OmniBoxKeywordSearchTests: XCTestCase {
    private var directory: URL?
    private var store: LocalStore?

    override func tearDown() async throws {
        try await store?.closeForAccountDirectoryRemoval()
        store = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    private func makeModel(urlBuilder: @escaping (String, String) -> String? = { _, _ in nil },
                           spaceShortcutProvider: @escaping () -> Bool = { false }) throws -> (OmniBoxViewModel, BrowserState) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        let store = LocalStore(account: Account(userID: UUID().uuidString), storeDirectoryURL: directory)
        self.store = store
        let state = BrowserState(windowId: UUID().hashValue, localStore: store, profileId: "Default")
        let model = OmniBoxViewModel(windowState: state, keywordSearchURLBuilder: urlBuilder,
                                    searchEngineSpaceShortcutProvider: spaceShortcutProvider)
        return (model, state)
    }

    private func engineResult(keyword: String = "duckduckgo.com", name: String = "DuckDuckGo", line: Int = 7,
                              query: String = "") -> [String: Any] {
        ["type": "search-other-engine", "contents": query.isEmpty ? "<Type search term>" : query,
         "description": name,
         "destinationUrl": query.isEmpty ? "" : "https://example.com/search?q=test",
         "fillIntoEdit": "\(keyword) \(query)", "line": line,
         "keywordSearchKeyword": query.isEmpty ? keyword : "", "keywordSearchName": query.isEmpty ? name : "",
         "allowedToBeDefaultMatch": false]
    }

    private func deliver(_ results: [[String: Any]], query: String, to state: BrowserState) {
        state.searchSuggestionChanged.send((results, query))
        let delivered = expectation(description: "Autocomplete response delivered")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
    }

    private func suggestBaidu(_ model: OmniBoxViewModel, _ state: BrowserState) {
        model.updateInputText("baidu")
        deliver([engineResult(keyword: "baidu", name: "Baidu")], query: "baidu", to: state)
    }

    func testPresentationRefreshesSpaceShortcutPreference() throws {
        var enabled = true
        var reads = 0
        let (model, state) = try makeModel(spaceShortcutProvider: {
            reads += 1
            return enabled
        })
        let controller = OmniBoxViewController(viewModel: model, state: state)
        XCTAssertEqual(reads, 0)
        controller.prepareForPresentation()
        XCTAssertTrue(model.isSearchEngineSpaceShortcutEnabled)
        enabled = false
        controller.prepareForPresentation()
        XCTAssertFalse(model.isSearchEngineSpaceShortcutEnabled)
        XCTAssertEqual(reads, 2)
    }

    func testSpaceRequiresSelectedEngineEvenWhenTabHintIsAvailable() throws {
        let (model, state) = try makeModel(spaceShortcutProvider: { true })
        model.refreshSearchEngineSpaceShortcut()
        model.updateInputText("bing")
        deliver([["type": "search-what-you-typed", "contents": "bing", "line": 0],
                 engineResult(keyword: "bing.com", name: "Bing")], query: "bing", to: state)
        XCTAssertEqual(model.state.selectedIndex, 0)
        XCTAssertNotNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearchWithSpace())
        model.selectNextSuggestion()
        XCTAssertTrue(model.acceptKeywordSearchWithSpace())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
        XCTAssertFalse(model.acceptKeywordSearchWithSpace())
    }

    func testShortcutHintTracksSelectedEngineAndSpacePreference() throws {
        var spaceEnabled = true
        let (model, state) = try makeModel(spaceShortcutProvider: { spaceEnabled })
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 200)
        defer { window.close() }
        controller.prepareForPresentation()
        model.updateInputText("spotify.com")
        deliver([["type": "url-what-you-typed", "contents": "spotify.com", "line": 0],
                 engineResult(keyword: "spotify.com", name: "Spotify", line: 1)],
                query: "spotify.com", to: state)
        func drainUpdates() {
            let rendered = expectation(description: "Shortcut hint updated")
            DispatchQueue.main.async { rendered.fulfill() }
            wait(for: [rendered], timeout: 1)
        }
        drainUpdates()
        XCTAssertEqual(model.state.selectedIndex, 0)
        XCTAssertEqual(model.keywordSearchHint?.name, "Spotify")
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        let labels = try XCTUnwrap(input.superview).subviews.filter { $0 !== input }
            .flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }
        let hint = try XCTUnwrap(labels.first { $0.stringValue == "Tab to search Spotify" })
        XCTAssertFalse(hint.isHidden)
        model.selectNextSuggestion()
        drainUpdates()
        XCTAssertEqual(hint.stringValue, "Tab or Space to search Spotify")
        XCTAssertFalse(hint.isHidden)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(hint.frame.maxX, try XCTUnwrap(hint.superview).bounds.maxX)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/phi-omnibox-tab-or-space-hint.png"))
        model.selectPreviousSuggestion()
        drainUpdates()
        XCTAssertEqual(hint.stringValue, "Tab to search Spotify")
        model.selectNextSuggestion()
        drainUpdates()
        XCTAssertEqual(hint.stringValue, "Tab or Space to search Spotify")
        spaceEnabled = false
        controller.prepareForPresentation()
        drainUpdates()
        XCTAssertEqual(hint.stringValue, "Tab to search Spotify")
        spaceEnabled = true
        controller.prepareForPresentation()
        drainUpdates()
        XCTAssertEqual(hint.stringValue, "Tab or Space to search Spotify")
    }

    func testDisabledSpaceShortcutStillAllowsTab() throws {
        let (model, state) = try makeModel()
        model.refreshSearchEngineSpaceShortcut()
        suggestBaidu(model, state)
        model.selectNextSuggestion()
        XCTAssertFalse(model.acceptKeywordSearchWithSpace())
        XCTAssertEqual(model.state.inputText, "baidu")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "baidu")
    }

    func testSpaceRejectsStaleSelectedEngine() throws {
        let (model, state) = try makeModel(spaceShortcutProvider: { true })
        model.refreshSearchEngineSpaceShortcut()
        suggestBaidu(model, state)
        XCTAssertFalse(model.acceptKeywordSearchWithSpace())
        model.selectNextSuggestion()
        model.updateInputText("other")
        XCTAssertFalse(model.acceptKeywordSearchWithSpace())
        XCTAssertNil(model.selectedSearchEngine)
    }

    func testSpaceKeyPreservesQueryAndLeavesInputMethodAndOtherWindowsAlone() throws {
        let (model, state) = try makeModel(spaceShortcutProvider: { true })
        let controller = OmniBoxViewController(viewModel: model, state: state)
        controller.prepareForPresentation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        window.makeFirstResponder(input.textFiled)
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        let query = "weather today"
        model.updateInputText("bing.com \(query)")
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: query)],
                query: "bing.com \(query)", to: state)
        model.selectNextSuggestion()
        func spaceEvent(modifiers: NSEvent.ModifierFlags = [], windowNumber: Int? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: windowNumber ?? window.windowNumber,
                                          context: nil, characters: " ", charactersIgnoringModifiers: " ",
                                          isARepeat: false, keyCode: 49))
        }
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            XCTAssertFalse(controller.handleKeywordSearchSpaceKeyDown(try spaceEvent(modifiers: modifier)))
        }
        XCTAssertFalse(controller.handleKeywordSearchSpaceKeyDown(try spaceEvent(windowNumber: 0)))
        editor.setMarkedText("b", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertFalse(controller.handleKeywordSearchSpaceKeyDown(try spaceEvent()))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertNil(model.selectedSearchEngine)
        editor.unmarkText()
        model.updateInputText("bing.com \(query)")
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: query)],
                query: "bing.com \(query)", to: state)
        model.selectNextSuggestion()
        XCTAssertTrue(try spaceEvent().window === window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(editor.hasMarkedText())
        input.selectToEnd()
        XCTAssertTrue(controller.handleKeywordSearchSpaceKeyDown(try spaceEvent()))
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
        XCTAssertEqual(input.stringValue, query)
        XCTAssertEqual(editor.string, query)
        XCTAssertEqual(editor.selectedRange, NSRange(location: (query as NSString).length, length: 0))
        XCTAssertFalse(controller.handleKeywordSearchSpaceKeyDown(try spaceEvent()))
    }

    func testSpaceShortcutLeavesCaretAndSelectionEditsToTextField() throws {
        let (model, state) = try makeModel(spaceShortcutProvider: { true })
        let controller = OmniBoxViewController(viewModel: model, state: state)
        controller.prepareForPresentation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        window.makeFirstResponder(input.textFiled)
        let editor = try XCTUnwrap(input.textFiled.currentEditor() as? NSTextView)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        let query = "weather \u{1F30D}"
        let text = "bing.com \(query)"
        let length = (text as NSString).length
        func selectEngineSuggestion() {
            model.updateInputText(text)
            deliver([engineResult(keyword: "bing.com", name: "Bing", query: query)],
                    query: text, to: state)
            model.selectNextSuggestion()
            let rendered = expectation(description: "Selected engine rendered")
            DispatchQueue.main.async { rendered.fulfill() }
            wait(for: [rendered], timeout: 1)
        }
        for range in [NSRange(location: 0, length: 0),
                      NSRange(location: 12, length: 0),
                      NSRange(location: length - 2, length: 2),
                      NSRange(location: 0, length: length)] {
            selectEngineSuggestion()
            editor.selectedRange = range
            XCTAssertFalse(controller.handleKeywordSearchSpaceKeyDown(event))
            XCTAssertNil(model.selectedSearchEngine)
            XCTAssertEqual(editor.selectedRange, range)
            XCTAssertEqual(editor.string, text)
            editor.insertText(" ", replacementRange: range)
            XCTAssertEqual(editor.string, (text as NSString).replacingCharacters(in: range, with: " "))
        }
        selectEngineSuggestion()
        editor.selectedRange = NSRange(location: length, length: 0)
        XCTAssertTrue(controller.handleKeywordSearchSpaceKeyDown(event))
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
        XCTAssertEqual(editor.string, query)
        XCTAssertEqual(editor.selectedRange, NSRange(location: (query as NSString).length, length: 0))
    }

    func testPrefixHintComesFromAutocompleteAndTabUsesCompleteKeyword() throws {
        let (model, state) = try makeModel()
        model.updateInputText("duck")
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearch())
        deliver([engineResult()], query: "duck", to: state)
        XCTAssertEqual(model.state.suggestions.count, 1)
        XCTAssertEqual(model.state.suggestions[0].title, "Search DuckDuckGo")
        XCTAssertEqual(model.state.suggestions[0].index, 7)
        XCTAssertEqual(model.keywordSearchHint?.keyword, "duckduckgo.com")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "duckduckgo.com")
        XCTAssertEqual(model.state.inputText, "")
        XCTAssertNil(model.keywordSearchHint)
        model.updateInputText("weather & news")
        model.performSearchAtonce()
        deliver([engineResult()], query: "duck", to: state)
        XCTAssertTrue(model.state.suggestions.isEmpty)
        XCTAssertEqual(model.state.inputText, "weather & news")
        XCTAssertFalse(model.exitKeywordSearchIfEmpty())
    }

    func testStreamedResultsPreserveChromiumOrderAndIndicesWithoutAddingRows() throws {
        let (model, state) = try makeModel()
        model.updateInputText("bing")
        let results: [[String: Any]] = [
            ["type": "search-what-you-typed", "contents": "bing", "line": 0],
            engineResult(keyword: "bing.com", name: "Microsoft Bing", line: 3),
            ["type": "url-what-you-typed", "contents": "bing.com", "line": 5]
        ]
        for _ in 0..<2 {
            deliver(results, query: "bing", to: state)
            XCTAssertEqual(model.state.suggestions.map(\.index), [0, 3, 5])
            XCTAssertEqual(model.state.suggestions[1].title, "Search Microsoft Bing")
            XCTAssertFalse(model.state.suggestions[1].allowedToBeDefault)
        }
        model.selectNextSuggestion()
        XCTAssertEqual(model.state.selectedSuggestion?.keywordSearchEngine?.keyword, "bing.com")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
    }

    func testExtendingKeywordKeepsSuggestionsAndHintUntilReplacementResults() throws {
        let (model, state) = try makeModel()
        model.updateInputText("duck")
        let result: [[String: Any]] = [
            ["type": "search-what-you-typed", "contents": "duck", "line": 0],
            engineResult()
        ]
        deliver(result, query: "duck", to: state)
        let controller = OmniBoxViewController(viewModel: model, state: state)
        _ = controller.view
        let settled = expectation(description: "Initial suggestion height applied")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        var counts: [Int] = []
        var hints: [OmniBoxKeywordSearchEngine?] = []
        var sizes: [NSSize] = []
        let rows = model.state.$suggestions.dropFirst().sink { counts.append($0.count) }
        let hint = model.$keywordSearchHint.dropFirst().sink { hints.append($0) }
        let size = controller.$contentSize.dropFirst().sink { sizes.append($0) }
        defer { rows.cancel(); hint.cancel(); size.cancel() }

        model.updateInputText("duckd")
        XCTAssertTrue(counts.isEmpty)
        XCTAssertTrue(hints.isEmpty)
        XCTAssertEqual(model.keywordSearchHint?.keyword, "duckduckgo.com")
        var replacement = result
        replacement[0]["contents"] = "duckd"
        deliver(replacement, query: "duckd", to: state)
        let rendered = expectation(description: "Replacement suggestion height applied")
        DispatchQueue.main.async { rendered.fulfill() }
        wait(for: [rendered], timeout: 1)
        XCTAssertEqual(counts, [2])
        XCTAssertTrue(hints.isEmpty)
        XCTAssertTrue(sizes.isEmpty)
    }

    func testIdenticalStreamedResultsDoNotRepublishSuggestionsOrHint() throws {
        let (model, state) = try makeModel()
        model.updateInputText("duck")
        let result: [[String: Any]] = [
            ["type": "search-what-you-typed", "contents": "duck", "line": 0],
            engineResult()
        ]
        deliver(result, query: "duck", to: state)
        var rowUpdates = 0
        var hintUpdates = 0
        let rows = model.state.$suggestions.dropFirst().sink { _ in rowUpdates += 1 }
        let hint = model.$keywordSearchHint.dropFirst().sink { _ in hintUpdates += 1 }
        defer { rows.cancel(); hint.cancel() }

        deliver(result, query: "duck", to: state)
        deliver(result, query: "duck", to: state)
        XCTAssertEqual(rowUpdates, 0)
        XCTAssertEqual(hintUpdates, 0)
        XCTAssertEqual(model.state.selectedIndex, 0)
    }

    func testTabUsesSelectedEngineWhenPrefixMatchesMultipleEngines() throws {
        let (model, state) = try makeModel()
        model.updateInputText("b")
        deliver([engineResult(keyword: "baidu", name: "Baidu", line: 0),
                 engineResult(keyword: "bing.com", name: "Microsoft Bing", line: 1)], query: "b", to: state)
        model.selectNextSuggestion()
        model.selectNextSuggestion()
        XCTAssertEqual(model.keywordSearchHint?.keyword, "bing.com")
        // Later providers may reorder the list. Keep the chosen engine selected.
        deliver([engineResult(keyword: "bing.com", name: "Microsoft Bing", line: 0),
                 engineResult(keyword: "baidu", name: "Baidu", line: 1)], query: "b", to: state)
        XCTAssertEqual(model.state.selectedIndex, 0)
        XCTAssertEqual(model.keywordSearchHint?.keyword, "bing.com")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
    }

    func testEngineRowClickAndEnterSelectTheEngine() throws {
        let (model, state) = try makeModel()
        suggestBaidu(model, state)
        model.clickSuggestionAtIndex(0)
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "baidu")
        XCTAssertEqual(model.state.inputText, "")
        model.reset()
        suggestBaidu(model, state)
        model.state.selectSuggestion(at: 0)
        model.handleEnterPressed()
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "baidu")
    }

    func testEditingInvalidatesHintAndRejectsStaleResponsesIncludingEmptyInput() throws {
        let (model, state) = try makeModel()
        model.updateInputText("duck")
        deliver([engineResult()], query: "duck", to: state)
        model.updateInputText("other")
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearch())
        deliver([engineResult()], query: "duck", to: state)
        // Retain the displayed snapshot while waiting, but never activate its stale engine.
        XCTAssertEqual(model.state.suggestions.count, 1)
        model.clickSuggestionAtIndex(0)
        model.handleEnterPressed()
        XCTAssertNil(model.selectedSearchEngine)
        deliver([["type": "search-what-you-typed", "contents": "other", "line": 0]], query: "other", to: state)
        XCTAssertEqual(model.state.suggestions.first?.title, "other")
        model.updateInputText("")
        deliver([engineResult()], query: "other", to: state)
        XCTAssertTrue(model.state.suggestions.isEmpty)
    }

    func testEmptyBackspaceRestoresKeywordAndResetClearsScope() throws {
        let (model, state) = try makeModel()
        suggestBaidu(model, state)
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertTrue(model.exitKeywordSearchIfEmpty())
        XCTAssertNil(model.selectedSearchEngine)
        XCTAssertEqual(model.state.inputText, "baidu")
        XCTAssertFalse(model.acceptKeywordSearch())
        deliver([engineResult(keyword: "baidu", name: "Baidu")], query: "baidu", to: state)
        XCTAssertTrue(model.acceptKeywordSearch())
        model.reset()
        XCTAssertNil(model.selectedSearchEngine)
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearch())
    }

    func testEnterUsesSelectedEngineAndKeepsScopeOnUnavailableEngine() throws {
        var submitted: (String, String)?
        let (model, state) = try makeModel { keyword, query in
            submitted = (keyword, query)
            return nil
        }
        suggestBaidu(model, state)
        XCTAssertTrue(model.acceptKeywordSearch())
        model.handleEnterPressed()
        XCTAssertNil(submitted)
        model.updateInputText("https://example.com/?a=1&b=2")
        model.handleEnterPressed()
        XCTAssertEqual(submitted?.0, "baidu")
        XCTAssertEqual(submitted?.1, "https://example.com/?a=1&b=2")
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "baidu")
    }

    func testNavigableOtherEngineMatchIsNotAnEngineSelectionAction() {
        var result = engineResult(query: "weather")
        result["description"] = "DuckDuckGo Search"
        result["keywordSearchKeyword"] = "duckduckgo.com"
        result["keywordSearchName"] = "DuckDuckGo"
        result["allowedToBeDefaultMatch"] = true
        result["deletable"] = true
        let suggestion = OmniBoxSuggestion(chromiumDic: result)
        XCTAssertEqual(suggestion.keywordSearchEngine?.name, "DuckDuckGo")
        XCTAssertEqual(suggestion.title, "weather")
        XCTAssertEqual(suggestion.fillIntoEdit, "duckduckgo.com weather")
        XCTAssertEqual(suggestion.keywordSearchQuery, "weather")
        XCTAssertFalse(suggestion.url.isEmpty)
        XCTAssertTrue(suggestion.allowedToBeDefault)
        XCTAssertTrue(suggestion.canDelete)
        XCTAssertEqual(suggestion.index, 7)
    }

    func testSearchEngineFaviconUsesExplicitEngineIconInsteadOfOtherURLs() {
        for (keyword, icon) in [
            ("baidu.com", "https://www.baidu.com/favicon.ico"),
            ("google.com", "https://www.gstatic.com/images/branding/searchlogo/ico/favicon.ico")
        ] {
            for query in ["", "weather"] {
                var result = engineResult(keyword: keyword, query: query)
                result["keywordSearchFaviconURL"] = icon
                result["imageUrl"] = "https://images.example.com/search.png"
                let suggestion = OmniBoxSuggestion(chromiumDic: result)
                XCTAssertEqual(suggestion.keywordSearchFaviconURL?.absoluteString, icon)
                XCTAssertNil(suggestion.faviconPageURL)
                XCTAssertEqual(suggestion.iconURL, "https://images.example.com/search.png")
            }
        }
    }

    func testMissingOrInvalidEngineFaviconFallsBackToSearchIcon() {
        for icon in [nil, "", "http://[", "chrome://settings", "file:///tmp/icon.png", "favicon.ico"] as [String?] {
            var result = engineResult(keyword: "baidu.com")
            result["keywordSearchFaviconURL"] = icon
            result["imageUrl"] = "https://images.example.com/search.png"
            let suggestion = OmniBoxSuggestion(chromiumDic: result)
            XCTAssertNil(suggestion.keywordSearchFaviconURL)
            XCTAssertNil(suggestion.faviconPageURL)
            let imageView = NSImageView()
            OmniSuggestionIconProvier.updateImage(for: imageView, with: suggestion)
            XCTAssertNotNil(imageView.image)
            XCTAssertEqual(imageView.image?.tiffRepresentation,
                           NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.tiffRepresentation)
        }
    }

    func testHistoryKeepsPageFaviconAndIgnoresEngineIconMetadata() {
        let suggestion = OmniBoxSuggestion(chromiumDic: [
            "type": "history-url", "contents": "Baidu", "destinationUrl": "https://www.baidu.com/",
            "keywordSearchFaviconURL": "https://other.example/icon.png"
        ])
        XCTAssertNil(suggestion.keywordSearchFaviconURL)
        XCTAssertEqual(suggestion.faviconPageURL?.absoluteString, "https://www.baidu.com/")
    }

    func testNavigableEngineHintsTabFromAnOrdinarySelectedRowAndPreservesQuery() throws {
        var submitted: (String, String)?
        let (model, state) = try makeModel { keyword, query in
            submitted = (keyword, query)
            return nil
        }
        let wrapper = PageColorTestWebContentWrapper(urlString: "https://initial.example")
        let tab = Tab(guid: 101, url: "https://initial.example", isActive: true, index: 0, webContentView: wrapper)
        model.setCurrentTab(tab)
        let query = "weather & news https://example.com/?q=hello+world"
        model.updateInputText("BING.COM \(query)")
        deliver([
            ["type": "search-what-you-typed", "contents": model.state.inputText, "line": 0],
            engineResult(keyword: "bing.com", name: "Bing", line: 1, query: query)
        ], query: model.state.inputText, to: state)
        XCTAssertEqual(model.state.selectedIndex, 0)
        XCTAssertNil(model.state.selectedSuggestion?.keywordSearchEngine)
        XCTAssertEqual(model.keywordSearchHint?.name, "Bing")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
        XCTAssertEqual(model.state.inputText, query)
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertTrue(model.state.suggestions.isEmpty)
        model.handleEnterPressed()
        XCTAssertNil(submitted, "The existing destination URL must bypass URL generation")
        XCTAssertEqual(wrapper.urlString, "https://example.com/search?q=test")
    }

    func testLegacyNavigableEngineWithoutMetadataStillOffersTabAndPreservesQuery() throws {
        let (model, state) = try makeModel()
        let query = "weather & news"
        model.updateInputText("bing.com \(query)")
        deliver([
            ["type": "search-what-you-typed", "contents": model.state.inputText, "line": 0],
            ["type": "search-other-engine", "contents": query, "description": "Bing Search",
             "fillIntoEdit": "bing.com \(query)", "destinationUrl": "https://www.bing.com/search?q=weather",
             "line": 1]
        ], query: model.state.inputText, to: state)
        XCTAssertEqual(model.state.selectedIndex, 0)
        XCTAssertEqual(model.keywordSearchHint?.keyword, "bing.com")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
        XCTAssertEqual(model.state.inputText, query)
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertTrue(model.state.suggestions.isEmpty)
    }

    func testTabWaitsForReplacementResultsAfterQueryChanges() throws {
        let (model, state) = try makeModel()
        model.updateInputText("bing.com old")
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: "old")],
                query: "bing.com old", to: state)
        model.updateInputText("bing.com new words")
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearch())
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: "new words")],
                query: "bing.com new words", to: state)
        XCTAssertEqual(model.keywordSearchHint?.name, "Bing")
        XCTAssertTrue(model.acceptKeywordSearch())
        XCTAssertEqual(model.state.inputText, "new words")
    }

    func testEditingScopedQueryDoesNotSubmitTheOriginalDestination() throws {
        var submitted: (String, String)?
        let (model, state) = try makeModel { keyword, query in
            submitted = (keyword, query)
            return nil
        }
        model.updateInputText("bing.com old")
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: "old")],
                query: "bing.com old", to: state)
        XCTAssertTrue(model.acceptKeywordSearch())
        model.updateInputText("new words")
        model.handleEnterPressed()
        XCTAssertEqual(submitted?.0, "bing.com")
        XCTAssertEqual(submitted?.1, "new words")
        XCTAssertEqual(model.selectedSearchEngine?.keyword, "bing.com")
    }

    func testChangingKeywordRejectsNavigableEngineHint() throws {
        let (model, state) = try makeModel()
        model.updateInputText("bing.com old")
        deliver([engineResult(keyword: "bing.com", name: "Bing", query: "old")],
                query: "bing.com old", to: state)
        model.updateInputText("bing.com.other new")
        XCTAssertNil(model.keywordSearchHint)
        XCTAssertFalse(model.acceptKeywordSearch())
    }

    func testTextFieldTabShowsBingAndKeepsExistingSearchTerms() throws {
        let (model, state) = try makeModel()
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 57)
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        window.makeFirstResponder(input.textFiled)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: input.textFiled) as? NSTextView)
        let query = "\u{86E4}\u{86E4}\u{86E4}1\u{1F30D}"
        model.updateInputText("bing.com \(query)")
        deliver([engineResult(keyword: "bing.com", name: "Microsoft Bing Search", query: query)],
                query: "bing.com \(query)", to: state)
        let hinted = expectation(description: "Bing Tab hint rendered")
        DispatchQueue.main.async { hinted.fulfill() }
        wait(for: [hinted], timeout: 1)
        let labels = try XCTUnwrap(input.superview).subviews.filter { $0 !== input }
            .flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }
        let hint = try XCTUnwrap(labels.first { $0.stringValue == "Tab to search Microsoft Bing Search" })
        XCTAssertFalse(hint.isHidden)
        XCTAssertTrue(input.control(input.textFiled, textView: editor,
                                    doCommandBy: #selector(NSTextView.insertTab(_:))))
        let scoped = expectation(description: "Bing keyword scope rendered")
        DispatchQueue.main.async { scoped.fulfill() }
        wait(for: [scoped], timeout: 1)
        XCTAssertEqual(input.stringValue, query)
        XCTAssertEqual(editor.string, query)
        XCTAssertEqual(editor.selectedRange, NSRange(location: (query as NSString).length, length: 0))
        XCTAssertEqual(model.selectedSearchEngine?.name, "Microsoft Bing Search")
        XCTAssertTrue(hint.isHidden)
        let engineLabel = try XCTUnwrap(labels.first { $0.stringValue == "Microsoft Bing Search" })
        XCTAssertFalse(engineLabel.isHiddenOrHasHiddenAncestor)
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: URL(fileURLWithPath: "/tmp/phi-bing-keyword-search-active.png"))
    }

    func testMarkedTextLeavesCommandsToTheInputMethod() throws {
        let (model, state) = try makeModel()
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let input = OmniBoxTextField(frame: .zero)
        input.omniBoxDelegate = controller
        suggestBaidu(model, state)
        let editor = NSTextView()
        editor.setMarkedText("\u{767E}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSTextView.insertTab(_:)),
                         #selector(NSTextView.moveUp(_:)),
                         #selector(NSTextView.moveDown(_:)),
                         #selector(NSTextView.insertNewline(_:)),
                         #selector(NSTextView.deleteBackward(_:))] {
            XCTAssertFalse(input.control(input.textFiled, textView: editor, doCommandBy: selector))
        }
        XCTAssertNil(model.selectedSearchEngine)
        XCTAssertEqual(model.state.selectedIndex, -1)
        XCTAssertEqual(model.state.inputText, "baidu")
    }

    func testNewDefaultResultUpdatesInlineCompletionWithoutChangingSelectedRow() throws {
        let (model, state) = try makeModel()
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        window.makeFirstResponder(input.textFiled)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: input.textFiled) as? NSTextView)
        func deliverCompletion(query: String, suffix: String) {
            model.updateInputText(query)
            deliver([["type": "url-what-you-typed", "contents": "example.com", "line": 0,
                      "fillIntoEdit": "example.com", "inlineAutocompletion": suffix]], query: query, to: state)
            let rendered = expectation(description: "Selection update rendered")
            DispatchQueue.main.async { rendered.fulfill() }
            wait(for: [rendered], timeout: 1)
        }
        deliverCompletion(query: "ex", suffix: "ample.com")
        XCTAssertEqual(editor.string, "example.com")
        XCTAssertEqual(model.state.selectedIndex, 0)
        deliverCompletion(query: "exam", suffix: "ple.com")
        XCTAssertEqual(editor.string, "example.com")
        XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 7))
        XCTAssertEqual(model.state.selectedIndex, 0)
    }

    func testLateSuggestionsDoNotReplaceMarkedTextWithInlineCompletion() throws {
        let (model, state) = try makeModel()
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        window.makeFirstResponder(input.textFiled)
        let editor = try XCTUnwrap(window.fieldEditor(true, for: input.textFiled) as? NSTextView)
        model.updateInputText("bai")
        editor.setMarkedText("\u{767E}", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        XCTAssertTrue(editor.hasMarkedText())
        deliver([["type": "url-what-you-typed", "contents": "baidu", "line": 0,
                  "fillIntoEdit": "baidu", "inlineAutocompletion": "du"]], query: "bai", to: state)
        let rendered = expectation(description: "Late suggestion rendered")
        DispatchQueue.main.async { rendered.fulfill() }
        wait(for: [rendered], timeout: 1)
        XCTAssertEqual(editor.string, "\u{767E}")
        XCTAssertTrue(editor.hasMarkedText())
    }

    func testTextFieldTabAndBackspaceDriveKeywordScope() throws {
        let (model, state) = try makeModel()
        let controller = OmniBoxViewController(viewModel: model, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 680, height: 57)
        defer { window.close() }
        let input = try XCTUnwrap(controller.view.subviews.first?.subviews.flatMap(\.subviews)
            .compactMap { $0 as? OmniBoxTextField }.first)
        let editor = NSTextView()
        suggestBaidu(model, state)
        editor.string = "baidu"
        XCTAssertTrue(input.control(input.textFiled, textView: editor,
                                    doCommandBy: #selector(NSTextView.insertTab(_:))))
        XCTAssertEqual(input.stringValue, "")
        XCTAssertEqual(model.selectedSearchEngine?.name, "Baidu")
        let delivered = expectation(description: "Keyword labels updated")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 1)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(input.textFiled.placeholderAttributedString?.string, "Search…")
        let labels = try XCTUnwrap(input.superview).subviews.filter { $0 !== input }
            .flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue), ["Baidu"])
        let badge = try XCTUnwrap(labels.first { $0.stringValue == "Baidu" }?.superview)
        XCTAssertEqual(badge.frame.height, 24)
        XCTAssertEqual(badge.layer?.cornerRadius, 12)
        XCTAssertGreaterThanOrEqual(input.frame.minX - badge.frame.maxX, 8)
        model.updateInputText("weather")
        XCTAssertEqual(input.textFiled.placeholderAttributedString?.string, "Search…")
        XCTAssertEqual(labels.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue), ["Baidu"])
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: image, uniformTypeIdentifier: "public.png")
        attachment.name = "Keyword search active"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.write(to: URL(fileURLWithPath: "/tmp/phi-keyword-search-active.png"))
        model.updateInputText("")
        editor.string = ""
        XCTAssertTrue(input.control(input.textFiled, textView: editor,
                                    doCommandBy: #selector(NSTextView.deleteBackward(_:))))
        XCTAssertEqual(input.stringValue, "baidu")
        XCTAssertNil(model.selectedSearchEngine)
        let exited = expectation(description: "Keyword badge hidden")
        DispatchQueue.main.async { exited.fulfill() }
        wait(for: [exited], timeout: 1)
        XCTAssertTrue(badge.isHidden)
        XCTAssertEqual(input.textFiled.placeholderAttributedString?.string, "Search or Enter URL")
    }
}
