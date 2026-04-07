// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
class OmniBoxViewModel: ObservableObject {
    @Published private(set) var state = OmniBoxState()
    
    weak var delegate: OmniBoxActionDelegate?
    
    private let configuration: OmniBoxConfiguration
    private var cancellables = Set<AnyCancellable>()
    private let chromiumBridge = ChromiumLauncher.sharedInstance().bridge
    private let browserState: BrowserState
    private let searchCoordinator = OmniBoxSearchCoordinator()
    private var currentSearchTask: Task<Void, Never>?
    private(set) var preventInlineCompletion: Bool = false
    
    @Published private(set) var canUseTemporaryText = false
    
    var opennedFromCurrentTab = false
    var currentTab: Tab?
    private(set) var openTraceSession: OmniBoxTraceSession?
    
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
        guard let tab else {
            return
        }
        currentTab = tab
        let prefilledText = URLProcessor.phiBrandEnsuredUrlString(tab.url ?? "")
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
        opennedFromCurrentTab = true
    }

    func setCurrentTab(_ tab: Tab?) {
        currentTab = tab
        opennedFromCurrentTab = true
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
            handleNavigationAction(for: suggestion)
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
    
    func handleEnterPressed() {
        if let selected = state.selectedSuggestion {
            handleNavigationAction(for: selected)
        } else if !state.inputText.isEmpty {
            let url = URLProcessor.processUserInput(state.inputText)
            openURL(url)
        }
    }
    
    private func handleNavigationAction(for suggeston: OmniBoxSuggestion) {
        AppLogDebug("omni: handleNavigationAction suggeston: \(suggeston)")
        if !suggeston.url.isEmpty {
            openURL(suggeston.url, switchToTab: suggeston.hasTabMatch)
        }
    }
    
    private func openURL(_ url: String, switchToTab: Bool = false) {
        AppLogDebug("omni: open url: \(url)")
        if opennedFromCurrentTab, let tab = currentTab, !tab.isPinnedOrInDB {
            tab.webContentWrapper?.navigate(toURL: url)
        } else if switchToTab {
            browserState.openTab(url)
        } else {
            browserState.createTab(url)
        }
        opennedFromCurrentTab = false
        delegate?.omniBoxDidClear()
        
        // Leave time for the hide animation to finish before resetting state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.state.reset()
        }
    }
    
    func reset() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        opennedFromCurrentTab = false
        searchCoordinator.reset()
        openTraceSession = nil
        state.reset()
    }
    
    func deleteSuggestion(at index: Int) {
        guard index >= 0 && index < state.suggestions.count else { return }
        let suggestion = state.suggestions[index]
        Task { @MainActor in
            let result = await deleteSuggestion(at: suggestion.index, searchText: state.inputText, on: browserState)
            handleSearchResults(results: result ?? [])
        }
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

        currentSearchTask?.cancel()
        browserState.stopAutoCompletion()

        let request = searchCoordinator.beginRequest(query: trimmedQuery, source: source)
        logOpenTrace(
            stage: "request-start",
            details: "request=\(request.id) source=\(request.source.rawValue) queryLength=\(trimmedQuery.count)"
        )

        currentSearchTask = Task { @MainActor in
            let result = await requestSuggestions(
                for: trimmedQuery,
                on: browserState,
                _preventInlineComplete: self.preventInlineCompletion
            )

            guard !Task.isCancelled else { return }

            let resultCount = result?.count ?? 0
            logOpenTrace(stage: "response-received", details: "request=\(request.id) resultCount=\(resultCount)")

            guard searchCoordinator.shouldApplyResponse(for: request) else {
                logOpenTrace(stage: "response-ignored", details: "request=\(request.id) reason=stale")
                return
            }

            handleSearchResults(results: result ?? [], request: request)
        }
    }
    
    private func handleSearchResults(results: [[String: Any]], request: OmniBoxSearchRequestToken? = nil) {
        let suggestions = results.compactMap { OmniBoxSuggestion(chromiumDic: $0) }
            .filter { !$0.isEmpty && $0.isSupportedType }
            .sorted {
                $0.relevanceScore > $1.relevanceScore
            }
        
        // Promote the first default-eligible suggestion while preserving the rest of the order.
        if let firstDefaultIdx = suggestions.firstIndex(where: { $0.allowedToBeDefault }) {
            var r = suggestions
            let firstDefault = r.remove(at: firstDefaultIdx)
            r.insert(firstDefault, at: 0)
            state.suggestions = r
            state.selectedIndex = 0
        } else {
            state.suggestions = suggestions
            state.selectedIndex = -1
        }
        
        let requestDescription = request.map { "request=\($0.id) source=\($0.source.rawValue)" } ?? "request=delete-or-reset"
        logOpenTrace(
            stage: "results-applied",
            details: "\(requestDescription) suggestionCount=\(suggestions.count) selectedIndex=\(state.selectedIndex)"
        )
    }
    
    @MainActor
    private func requestSuggestions(for searchText: String,
                                    on state: BrowserState,
                                    _preventInlineComplete: Bool = false,
                                    timeout: Duration = .seconds(1)) async -> [[String: Any]]? {
        canUseTemporaryText = false
        return await withTaskGroup(of: [[String: Any]]?.self) { group in
            // Subscribe first so the Chromium response cannot race past the observer.
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    var cancellable: AnyCancellable?
                    cancellable = state.searchSuggestionChanged
                        .sink { suggestions, originalString in
                            if originalString == searchText {
                                AppLogDebug("searchSuggestionChanged for text: \(searchText)")
                                AppLogDebug("result: \(suggestions)")
                                continuation.resume(returning: suggestions)
                                cancellable?.cancel()
                                cancellable = nil
                            }
                        }
                    
                    self.chromiumBridge?.requestAutoCompleteSuggestions(
                        forText: searchText,
                        preventInlineAutoComplete: _preventInlineComplete,
                        windowId: state.windowId.int64Value
                    )
                    AppLogDebug("requestSuggestions for text:\(searchText), inlineCompletion: \(!_preventInlineComplete)")
                }
            }
            
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
    
    @MainActor
    private func deleteSuggestion(at index: Int,
                                  searchText: String,
                                  on state: BrowserState,
                                  timeout: Duration = .seconds(1)) async -> [[String: Any]]? {
        return await withTaskGroup(of: [[String: Any]]?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    var cancellable: AnyCancellable?
                    cancellable = state.searchSuggestionChanged
                        .sink { suggestions, originalString in
                            if originalString == searchText {
                                AppLogDebug("searchSuggestionChanged for text: \(searchText)")
                                AppLogDebug("result: \(suggestions)")
                                continuation.resume(returning: suggestions)
                                cancellable?.cancel()
                                cancellable = nil
                            }
                        }
                    
                    self.chromiumBridge?.deleteSuggestion(atLine: index, windowId: state.windowId.int64Value)
                    AppLogDebug("delete suggestion at index: \(index) original text:\(searchText)")
                }
            }
            
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
