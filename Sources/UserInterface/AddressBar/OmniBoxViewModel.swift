// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import AppKit
class OmniBoxViewModel: ObservableObject {
    @Published private(set) var state = OmniBoxState()
    
    weak var delegate: OmniBoxActionDelegate?
    
    private let configuration: OmniBoxConfiguration
    private var cancellables = Set<AnyCancellable>()
    private let chromiumBridge = ChromiumLauncher.sharedInstance().bridge
    private let browserState: BrowserState
    private let searchCoordinator = OmniBoxSearchCoordinator()
    private let keywordSearchURLBuilder: (String, String) -> String?
    private let searchEngineSpaceShortcutProvider: () -> Bool
    @Published private(set) var isSearchEngineSpaceShortcutEnabled = false
    private(set) var preventInlineCompletion: Bool = false
    
    @Published private(set) var canUseTemporaryText = false
    @Published private(set) var keywordSearchHint: OmniBoxKeywordSearchEngine?
    @Published private(set) var selectedSearchEngine: OmniBoxKeywordSearchEngine?
    private var suggestionsQuery: String?
    private var keywordSearchDestination: (query: String, url: String)?
    
    var opennedFromCurrentTab = false
    /// A bookmark's tab and a pinned tab stand for their stored URL: an
    /// address-bar submission there opens a NEW tab rather than navigating
    /// the row in place (which bounces the bookmark tab into a Peek and
    /// re-points the pinned row and its icon). Tracked separately from
    /// `opennedFromCurrentTab`, which still describes where the omnibox was
    /// opened from — the Cmd+L toggle reads that.
    private var opensSubmissionInNewTab = false
    var currentTab: Tab?
    private var openedFromGroupOverview = false
    private(set) var openTraceSession: OmniBoxTraceSession?

    /// The submission target: the focused tab itself, or a fresh tab.
    private var navigatesCurrentTab: Bool {
        opennedFromCurrentTab && !opensSubmissionInNewTab
    }

    /// Claims the tab this submission is about to spawn so the Peek pipeline
    /// leaves it alone. Chromium parents an omnibox-opened foreground tab to
    /// whatever is focused and reports it as a link-foreground child, which on
    /// a bookmark/pinned-bound row is indistinguishable from a link click —
    /// and would become a Peek. An omnibox submission never means "peek this".
    ///
    /// Keyed off `focusingTab` rather than `currentTab`: the standalone
    /// omnibox (Cmd+T / Cmd+L overlay) never sets `currentTab`, and a stale
    /// one can outlive the address-bar open that set it.
    private func claimUpcomingNewTab() {
        guard let opener = browserState.focusingTab,
              browserState.addressBarNavigationOpensNewTab(for: opener) else { return }
        browserState.noteAddressBarWillOpenNewTab(openerTabId: opener.guid)
    }

    private var shouldCreateInGroupOverview: Bool {
        openedFromGroupOverview || browserState.groupOverviewState != nil
    }
    
    // MARK: - Initialization
    
    init(configuration: OmniBoxConfiguration = .default, windowState: BrowserState,
         keywordSearchURLBuilder: ((String, String) -> String?)? = nil,
         searchEngineSpaceShortcutProvider: (() -> Bool)? = nil) {
        self.configuration = configuration
        self.browserState = windowState
        let bridge = chromiumBridge
        let windowId = windowState.windowId.int64Value
        self.keywordSearchURLBuilder = keywordSearchURLBuilder ?? { keyword, query in
            guard let bridge,
                  bridge.responds(to: #selector(PhiChromiumBridgeProtocol.keywordSearchURL(forKeyword:query:windowId:))) else { return nil }
            return bridge.keywordSearchURL(forKeyword: keyword, query: query, windowId: windowId)
        }
        self.searchEngineSpaceShortcutProvider = searchEngineSpaceShortcutProvider ?? {
            guard let bridge,
                  bridge.responds(to: #selector(PhiChromiumBridgeProtocol.isSearchEngineSpaceShortcutEnabled(forWindowId:))) else { return false }
            return bridge.isSearchEngineSpaceShortcutEnabled(forWindowId: windowId)
        }
        setupBindings()
    }
    
    deinit {
    }
    
    // MARK: - Private Setup

    func refreshSearchEngineSpaceShortcut() {
        isSearchEngineSpaceShortcutEnabled = searchEngineSpaceShortcutProvider()
    }
    
    private func setupBindings() {
        state.$inputText
            .sink { [weak self] text in
                self?.handleInputChanged(text)
            }
            .store(in: &cancellables)

        // Persistent subscription so every Chromium suggestion update for the current query
        // is applied. Chromium emits multiple `OnResultChanged` callbacks per request as
        // providers respond at different speeds; the previous per-request `await` model only
        // consumed the first one, which made the on-screen suggestions diverge from
        // AutocompleteController state and caused selectSuggestion line mismatches.
        browserState.searchSuggestionChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] suggestions, originalString in
                self?.handleIncomingSuggestions(suggestions, for: originalString)
            }
            .store(in: &cancellables)
    }

    private func handleIncomingSuggestions(_ results: [[String: Any]], for query: String) {
        guard selectedSearchEngine == nil,
              query == state.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
              searchCoordinator.shouldAcceptResponse(forQuery: query) else {
            logOpenTrace(stage: "response-ignored", details: "query=\(query) reason=stale")
            return
        }
        logOpenTrace(stage: "response-received", details: "query=\(query) resultCount=\(results.count)")
        suggestionsQuery = query
        handleSearchResults(results: results)
    }
    
    func beginOpenTrace(trigger: String, addressViewPresent: Bool) {
        #if DEBUG
        let session = OmniBoxTraceSession(trigger: trigger)
        openTraceSession = session
        session.log(stage: "open-trigger", details: "addressViewPresent=\(addressViewPresent)")
        #endif
    }

    func logOpenTrace(stage: String, details: String? = nil, once: Bool = false) {
        #if DEBUG
        if once {
            openTraceSession?.logOnce(stage: stage, details: details)
        } else {
            openTraceSession?.log(stage: stage, details: details)
        }
        #endif
    }

    func updateStatus(with tab: Tab?, suppressAutomaticSearch: Bool = false) {
        if browserState.groupOverviewState != nil {
            updateStatusForGroupOverview()
            return
        }
        openedFromGroupOverview = false
        guard let tab else {
            return
        }
        currentTab = tab
        // Opening the omnibox via the address bar (sidebar or webcontent) always represents
        // the current tab as the navigation target, including NTP — typing a URL should
        // replace the blank NTP rather than spawn a new tab.
        opennedFromCurrentTab = true
        opensSubmissionInNewTab = browserState.addressBarNavigationOpensNewTab(for: tab)
        if tab.isNTP || tab.url == "about:blank" {
            logOpenTrace(
                stage: "prefill-current-tab",
                details: "suppressAutomaticSearch=\(suppressAutomaticSearch) urlLength=0 isBlank=true"
            )
            state.inputText = ""
            return
        }
        // A reader page stands in for its article: edit (and re-submit) the
        // article's URL rather than the extension page's.
        let rawURL = tab.url ?? ""
        let prefilledText = URLProcessor.phiBrandEnsuredUrlString(
            ReaderExtensionBridge.sourceURLString(fromReaderPageURL: rawURL) ?? rawURL)
        if suppressAutomaticSearch {
            searchCoordinator.prepareForPrefilledOpen(
                text: prefilledText,
                minInputLength: configuration.minInputLength
            )
        }
        logOpenTrace(
            stage: "prefill-current-tab",
            details: "suppressAutomaticSearch=\(suppressAutomaticSearch) urlLength=\(prefilledText.count)"
        )
        state.inputText = prefilledText
    }

    func updateStatusForGroupOverview() {
        currentTab = nil
        opennedFromCurrentTab = false
        opensSubmissionInNewTab = false
        openedFromGroupOverview = true
        searchCoordinator.prepareForPrefilledOpen(
            text: "",
            minInputLength: configuration.minInputLength
        )
        state.inputText = ""
    }

    func setCurrentTab(_ tab: Tab?) {
        if browserState.groupOverviewState != nil {
            updateStatusForGroupOverview()
            return
        }
        currentTab = tab
        openedFromGroupOverview = false
        opensSubmissionInNewTab = tab.map { browserState.addressBarNavigationOpensNewTab(for: $0) } ?? false
        if tab?.isNTP == true || tab?.url == "about:blank" {
            state.inputText = ""
            opennedFromCurrentTab = true
        } else {
            opennedFromCurrentTab = tab != nil
        }
    }
    
    func updateInputText(_ text: String, suppressAutoComplete: Bool = false) {
        preventInlineCompletion = suppressAutoComplete
        state.inputText = text
    }
    
    func setFocused(_ focused: Bool) {
        state.isFocused = focused
    }
    
    func clickSuggestionAtIndex(_ index: Int) {
        if index >= 0, index < state.suggestions.count {
            let suggestion = state.suggestions[index]
            handleNavigationAction(for: suggestion, commandKeyPressed: isCommandKeyPressed)
        }
    }
    
    func selectNextSuggestion() {
        canUseTemporaryText = true
        state.selectNextSuggestion()
        updateKeywordSearchHint(selectedIndex: state.selectedIndex)
    }
    
    func selectPreviousSuggestion() {
        canUseTemporaryText = true
        state.selectPreviousSuggestion()
        updateKeywordSearchHint(selectedIndex: state.selectedIndex)
    }
    
    func handleEnterPressed(commandKeyPressed: Bool = false) {
        if let engine = selectedSearchEngine {
            guard !state.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let destination = keywordSearchDestination, destination.query == state.inputText {
                openURL(destination.url, commandKeyPressed: commandKeyPressed)
                return
            }
            guard let url = keywordSearchURLBuilder(engine.keyword, state.inputText), !url.isEmpty else {
                NSSound.beep()
                return
            }
            openURL(url, commandKeyPressed: commandKeyPressed)
            return
        }
        if let selected = state.selectedSuggestion {
            handleNavigationAction(for: selected, commandKeyPressed: commandKeyPressed)
        } else if !state.inputText.isEmpty {
            let url = URLProcessor.processUserInput(state.inputText)
            openURL(url)
        }
    }

    private func canUseKeywordSearchSuggestion(_ suggestion: OmniBoxSuggestion, for input: String) -> Bool {
        guard let engine = suggestion.keywordSearchEngine,
              input.count >= configuration.minInputLength else { return false }
        // Chromium owns keyword matching. While its replacement results are pending,
        // retain only query-free hints whose literal keyword still matches this input.
        return suggestionsQuery == input
            || (suggestion.url.isEmpty && engine.keyword.lowercased().hasPrefix(input.lowercased()))
    }

    private func updateKeywordSearchHint(selectedIndex: Int, inputText: String? = nil) {
        let input = (inputText ?? state.inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = state.suggestions.indices.contains(selectedIndex) ? state.suggestions[selectedIndex] : nil
        let suggestion = selected.flatMap { canUseKeywordSearchSuggestion($0, for: input) ? $0 : nil }
            ?? state.suggestions.first { canUseKeywordSearchSuggestion($0, for: input) }
        let engine = suggestion?.keywordSearchEngine
        if keywordSearchHint != engine {
            keywordSearchHint = engine
        }
    }

    var canAcceptKeywordSearchWithSpace: Bool {
        let input = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedSearchEngine == nil, isSearchEngineSpaceShortcutEnabled,
              let suggestion = state.selectedSuggestion,
              suggestion.type == .searchEngine else { return false }
        return canUseKeywordSearchSuggestion(suggestion, for: input)
    }

    @discardableResult
    func acceptKeywordSearchWithSpace() -> Bool {
        guard canAcceptKeywordSearchWithSpace else { return false }
        return acceptKeywordSearch()
    }

    @discardableResult
    func acceptKeywordSearch(keyword: String? = nil) -> Bool {
        guard selectedSearchEngine == nil else { return false }
        let input = state.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestion: OmniBoxSuggestion?
        if let keyword {
            suggestion = state.suggestions.first {
                $0.keywordSearchEngine?.keyword == keyword && canUseKeywordSearchSuggestion($0, for: input)
            }
        } else {
            suggestion = state.selectedSuggestion.flatMap {
                canUseKeywordSearchSuggestion($0, for: input) ? $0 : nil
            } ?? state.suggestions.first {
                $0.keywordSearchEngine == keywordSearchHint && canUseKeywordSearchSuggestion($0, for: input)
            }
        }
        guard let suggestion, let engine = suggestion.keywordSearchEngine else { return false }
        let query = suggestion.keywordSearchQuery ?? ""
        keywordSearchDestination = suggestion.url.isEmpty ? nil : (query, suggestion.url)
        browserState.stopAutoCompletion()
        searchCoordinator.reset()
        suggestionsQuery = nil
        selectedSearchEngine = engine
        keywordSearchHint = nil
        canUseTemporaryText = false
        state.clearSuggestions()
        state.inputText = query
        return true
    }

    @discardableResult
    func exitKeywordSearchIfEmpty() -> Bool {
        guard let engine = selectedSearchEngine, state.inputText.isEmpty else { return false }
        keywordSearchDestination = nil
        selectedSearchEngine = nil
        state.inputText = engine.keyword
        return true
    }
    
    private func handleNavigationAction(for suggeston: OmniBoxSuggestion, commandKeyPressed: Bool = false) {
        if let engine = suggeston.keywordSearchEngine, suggeston.url.isEmpty {
            acceptKeywordSearch(keyword: engine.keyword)
            return
        }
        AppLogDebug("omni: handleNavigationAction suggeston: \(suggeston)")
        if shouldCreateInGroupOverview {
            let url = suggeston.url.isEmpty ? URLProcessor.processUserInput(state.inputText) : suggeston.url
            openURL(url, commandKeyPressed: commandKeyPressed)
            return
        }
        if suggeston.index >= 0 {
            selectSuggestion(suggeston, commandKeyPressed: commandKeyPressed)
        } else if !suggeston.url.isEmpty {
            openURL(suggeston.url, switchToTab: suggeston.hasTabMatch, commandKeyPressed: commandKeyPressed)
        }
    }

    private func selectSuggestion(_ suggestion: OmniBoxSuggestion, commandKeyPressed: Bool) {
        let disposition = suggestionDisposition(for: suggestion, commandKeyPressed: commandKeyPressed)
        AppLogDebug("omni: select suggestion line: \(suggestion.index), disposition: \(disposition.rawValue)")
        if disposition == .currentTab, let currentTab {
            browserState.closePeekForAddressBarNavigation(openerTabId: currentTab.guid)
            browserState.closeReaderOverlayForAddressBarNavigation(originTabId: currentTab.guid)
        }
        // Chromium hands the tab this disposition spawns to the Mac side as a
        // link-foreground child of `currentTab`; on a bound row that would be
        // diverted straight into a Peek. Claim it as an address-bar tab first.
        if disposition == .newForegroundTab {
            claimUpcomingNewTab()
        }
        chromiumBridge?.selectSuggestion(atLine: suggestion.index,
                                         windowId: browserState.windowId.int64Value,
                                         disposition: disposition)
        finishNavigationAction()
    }

    private func suggestionDisposition(
        for suggestion: OmniBoxSuggestion,
        commandKeyPressed: Bool
    ) -> PhiOmniboxSuggestionDisposition {
        if suggestion.hasTabMatch && commandKeyPressed {
            return .switchToTab
        }
        if navigatesCurrentTab {
            return .currentTab
        }
        return .newForegroundTab
    }
    
    private func openURL(_ url: String, switchToTab: Bool = false, commandKeyPressed: Bool = false) {
        AppLogDebug("omni: open url: \(url)")
        if shouldCreateInGroupOverview {
            Task { @MainActor [browserState] in
                browserState.createTabInCurrentOverviewGroup(url: url)
            }
        } else if switchToTab {
            if commandKeyPressed {
                browserState.openTab(url)
            } else {
                browserState.createTab(url)
            }
        } else if navigatesCurrentTab {
            navigateCurrentTab(to: url)
        } else {
            // A new tab: the omnibox was opened outside the address bar, this
            // Space has no tab, or the focused row is bookmark/pinned-bound.
            // Opening the URL in the current window goes via a fresh
            // WebContents, which the Space-routing throttle would route —
            // except an "ask" rule's prompt gets suppressed on redirects here.
            // Resolve the rule up front so both ask and auto-route behave like
            // the live-tab path.
            claimUpcomingNewTab()
            if !routeIfSpaceRuleMatches(url) {
                browserState.createTab(url)
            }
        }
        finishNavigationAction()
    }

    /// Asks Chromium whether a Space URL rule routes `url` away from this
    /// window's Space; if so, Chromium performs the hand-off (prompt / spawn /
    /// open-in-window) and this returns `true`, meaning the caller must not open
    /// the URL locally. Needed for the empty-Space paths (native NTP / no tab),
    /// whose navigation runs on a detached WebContents the throttle can't see.
    private func routeIfSpaceRuleMatches(_ url: String) -> Bool {
        chromiumBridge?.routeURLIfSpaceRuleMatches(url, windowId: browserState.windowId.int64Value) ?? false
    }

    private func navigateCurrentTab(to url: String) {
        if let currentTab, let wrapper = currentTab.webContentWrapper {
            browserState.closePeekForAddressBarNavigation(openerTabId: currentTab.guid)
            browserState.closeReaderOverlayForAddressBarNavigation(originTabId: currentTab.guid)
            wrapper.navigate(toURL: url)
            return
        }

        // No live web contents in this tab (native NTP / empty Space). The
        // Space-routing throttle can't attribute the detached NTP WebContents to
        // a Browser, so resolve the rule up front and hand off if it matches.
        if routeIfSpaceRuleMatches(url) {
            return
        }

        guard let currentTab, currentTab.usesNativeNTP else {
            browserState.createTab(url)
            return
        }

        guard let wrapper = chromiumBridge?.newWebContents(
            forUrl: url,
            windowId: browserState.windowId.int64Value
        ) as? (WebContentWrapper & NSObject) else {
            browserState.createTab(url)
            return
        }
        currentTab.setWebContentsWrapper(wrapper: wrapper)
    }

    private func finishNavigationAction() {
        opennedFromCurrentTab = false
        opensSubmissionInNewTab = false
        openedFromGroupOverview = false
        delegate?.omniBoxDidClear()
        
        // Leave time for the hide animation to finish before resetting state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.keywordSearchDestination = nil
            self.selectedSearchEngine = nil
            self.keywordSearchHint = nil
            self.state.reset()
        }
    }

    private var isCommandKeyPressed: Bool {
        NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
    }
    
    func reset() {
        opennedFromCurrentTab = false
        opensSubmissionInNewTab = false
        openedFromGroupOverview = false
        searchCoordinator.reset()
        suggestionsQuery = nil
        openTraceSession = nil
        keywordSearchDestination = nil
        selectedSearchEngine = nil
        keywordSearchHint = nil
        state.reset()
    }
    
    func deleteSuggestion(at index: Int) {
        guard index >= 0 && index < state.suggestions.count else { return }
        let suggestion = state.suggestions[index]
        AppLogDebug("omni: delete suggestion at index: \(suggestion.index) original text:\(state.inputText)")
        // Chromium will emit a refreshed `searchSuggestionChanged` event for the same query
        // after the entry is removed; the persistent subscription in `setupBindings`
        // will pick it up.
        chromiumBridge?.deleteSuggestion(atLine: suggestion.index, windowId: browserState.windowId.int64Value)
    }
    
    // MARK: - Private Methods
    
    private func handleInputChanged(_ text: String) {
        guard selectedSearchEngine == nil else {
            state.clearSuggestions()
            return
        }
        updateKeywordSearchHint(selectedIndex: state.selectedIndex, inputText: text)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.count < configuration.minInputLength {
            searchCoordinator.reset()
            suggestionsQuery = nil
            browserState.stopAutoCompletion()
            state.clearSuggestions()
            return
        }

        guard searchCoordinator.shouldPerformAutomaticSearch(for: text, minInputLength: configuration.minInputLength) else {
            logOpenTrace(stage: "skip-automatic-search", details: "reason=prefill queryLength=\(trimmedText.count)")
            return
        }

        performSearch(for: trimmedText, source: .inputChange)
    }
    
    func performSearchAtonce(source: OmniBoxSearchRequestSource = .manualRefresh) {
        performSearch(for: state.inputText, source: source)
    }
    
    private func performSearch(for query: String, source: OmniBoxSearchRequestSource) {
        guard selectedSearchEngine == nil else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.count >= configuration.minInputLength else {
            state.clearSuggestions()
            return
        }

        browserState.stopAutoCompletion()

        let request = searchCoordinator.beginRequest(query: trimmedQuery, source: source)
        logOpenTrace(
            stage: "request-start",
            details: "request=\(request.id) source=\(request.source.rawValue) queryLength=\(trimmedQuery.count)"
        )

        canUseTemporaryText = false
        chromiumBridge?.requestAutoCompleteSuggestions(
            forText: trimmedQuery,
            preventInlineAutoComplete: preventInlineCompletion,
            windowId: browserState.windowId.int64Value
        )
        AppLogDebug("omni: requestSuggestions for text:\(trimmedQuery), inlineCompletion: \(!preventInlineCompletion)")
    }
    
    private func handleSearchResults(results: [[String: Any]]) {
        let finalSuggestions = results.map { OmniBoxSuggestion(chromiumDic: $0) }
            .filter { !$0.isEmpty && $0.isSupportedType }

        // Preserve the user's manual selection (arrow-key navigation) across streamed
        // updates for the same query, otherwise late provider responses would yank the
        // highlight back to the default row.
        let preserveManualSelection = canUseTemporaryText
            && state.selectedIndex >= 0
            && state.selectedIndex < finalSuggestions.count
        let newSelectedIndex: Int
        if canUseTemporaryText, let engine = state.selectedSuggestion?.keywordSearchEngine {
            newSelectedIndex = finalSuggestions.firstIndex { $0.keywordSearchEngine == engine } ?? -1
        } else if preserveManualSelection {
            newSelectedIndex = state.selectedIndex
        } else if finalSuggestions.first?.allowedToBeDefault == true {
            newSelectedIndex = 0
        } else {
            newSelectedIndex = -1
        }

        let suggestionsChanged = state.suggestions != finalSuggestions
        if suggestionsChanged {
            state.suggestions = finalSuggestions
        }
        updateKeywordSearchHint(selectedIndex: newSelectedIndex)
        if suggestionsChanged || state.selectedIndex != newSelectedIndex {
            state.selectedIndex = newSelectedIndex
        }

        logOpenTrace(
            stage: "results-applied",
            details: "query=\(searchCoordinator.currentQuery ?? "") suggestionCount=\(finalSuggestions.count) selectedIndex=\(state.selectedIndex)"
        )
    }
}
