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
    private(set) var preventInlineCompletion: Bool = false
    
    @Published private(set) var canUseTemporaryText = false
    
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
    
    init(configuration: OmniBoxConfiguration = .default, windowState: BrowserState) {
        self.configuration = configuration
        self.browserState = windowState
        setupBindings()
    }
    
    deinit {
    }
    
    // MARK: - Private Setup
    
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
        guard searchCoordinator.shouldAcceptResponse(forQuery: query) else {
            logOpenTrace(stage: "response-ignored", details: "query=\(query) reason=stale")
            return
        }
        logOpenTrace(stage: "response-received", details: "query=\(query) resultCount=\(results.count)")
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
    }
    
    func selectPreviousSuggestion() {
        canUseTemporaryText = true
        state.selectPreviousSuggestion()
    }
    
    func handleEnterPressed(commandKeyPressed: Bool = false) {
        if let selected = state.selectedSuggestion {
            handleNavigationAction(for: selected, commandKeyPressed: commandKeyPressed)
        } else if !state.inputText.isEmpty {
            let url = URLProcessor.processUserInput(state.inputText)
            openURL(url)
        }
    }
    
    private func handleNavigationAction(for suggeston: OmniBoxSuggestion, commandKeyPressed: Bool = false) {
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
        openTraceSession = nil
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
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.count < configuration.minInputLength {
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
        let suggestions = results.compactMap { OmniBoxSuggestion(chromiumDic: $0) }
            .filter { !$0.isEmpty && $0.isSupportedType }
        
        let finalSuggestions: [OmniBoxSuggestion] = suggestions

        // Preserve the user's manual selection (arrow-key navigation) across streamed
        // updates for the same query, otherwise late provider responses would yank the
        // highlight back to the default row.
        let preserveManualSelection = canUseTemporaryText
            && state.selectedIndex >= 0
            && state.selectedIndex < finalSuggestions.count
        let newSelectedIndex: Int
        if preserveManualSelection {
            newSelectedIndex = state.selectedIndex
        } else if finalSuggestions.first?.allowedToBeDefault == true {
            newSelectedIndex = 0
        } else {
            newSelectedIndex = -1
        }

        state.suggestions = finalSuggestions
        state.selectedIndex = newSelectedIndex

        logOpenTrace(
            stage: "results-applied",
            details: "query=\(searchCoordinator.currentQuery ?? "") suggestionCount=\(finalSuggestions.count) selectedIndex=\(state.selectedIndex)"
        )
    }
}
