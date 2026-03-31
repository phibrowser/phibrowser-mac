// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
/// Experimental `NSTextSuggestionsDelegate` implementation that is currently unused.
extension OmniBoxViewController: NSTextSuggestionsDelegate {
    typealias SuggestionItemType = OmniBoxSuggestion
    func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
        let string = textField.stringValue
        AppLogDebug("preparing to request suggestion with str: \(string)")
        func suggestionItem(_ suggestion: OmniBoxSuggestion) -> Item {
            var item = NSSuggestionItem(representedValue: suggestion, title: suggestion.title)
            if let sub = suggestion.subtitle, sub.count > 0 {
                item.title = "\(suggestion.title) - \(sub)"
            }
            item.image = NSImage(systemSymbolName: suggestion.defaultIconName(), accessibilityDescription: nil)
            return item
        }
        
        guard string.count > 0, let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            responseHandler(NSSuggestionItemResponse())
            return
        }
        Task {
            ChromiumLauncher.sharedInstance().bridge?.requestAutoCompleteSuggestions(forText: string)
            
            guard let suggesstionInfos = await watiForResponse(for: string, on: state) else {
                responseHandler(NSSuggestionItemResponse())
                return
            }
            
            let map = suggesstionInfos.map { OmniBoxSuggestion(chromiumDic: $0) }.map(suggestionItem(_:))
            let response = NSSuggestionItemResponse(items: map)
            responseHandler(response)
        }
    }
    
    @MainActor
    func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        guard let item = item.representedValue as? OmniBoxSuggestion else {
            return nil
        }
        if item.type == .history {
            return item.url
        } else {
            return item.title
        }
    }

    @MainActor
    func textField(_ textField: NSTextField, didSelect item: Item) {
        
        
    }
    
    private func watiForResponse(for searchText: String, on state: BrowserState, timeout: Duration = .seconds(3)) async -> [[String: Any]]? {
        await withTaskGroup(of: [[String: Any]]?.self) { group in
            // Wait for the suggestion stream first.
            group.addTask {
                await withCheckedContinuation { continuation in
                    var cancellable: AnyCancellable?
                    cancellable = state.searchSuggestionChanged
                        .sink { suggestions, originalString in
                            if originalString == searchText {
                                continuation.resume(returning: suggestions)
                                cancellable?.cancel()
                                cancellable = nil
                            }
                        }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            let result = await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    private func buildSuggesstionReulst(with infos: [[String: Any]], state: BrowserState) -> SuggestionResult {
        var history: [OmniBoxSuggestion] = []
        var openedTab: [OmniBoxSuggestion] = []
        var searchSuggestion: [OmniBoxSuggestion] = []
        
        for info in infos {
            let suggestion = OmniBoxSuggestion(chromiumDic: info)
            print("suggestion.url: \(suggestion.url)")
            let isOpenedTab = state.tabs.contains { tab in
                guard let tabUrl = tab.url else { return false }
                return tabUrl == suggestion.url
            }
            
            switch suggestion.type {
            case .history, .bookmark:
                if isOpenedTab {
                    openedTab.append(suggestion)
                } else {
                    history.append(suggestion)
                }
            case .search, .searchSuggest:
                searchSuggestion.append(suggestion)
            case .topSite, .url:
                if isOpenedTab {
                    openedTab.append(suggestion)
                } else {
                    history.append(suggestion)
                }
            case .extension:
                break
            }
        }
        
        return SuggestionResult(
            histroy: history.isEmpty ? nil : history,
            openedTab: openedTab.isEmpty ? nil : openedTab,
            searchSuggestion: searchSuggestion.isEmpty ? nil : searchSuggestion
        )
    }
    
}

extension OmniBoxViewController {
    struct SuggestionResult {
        var histroy: [OmniBoxSuggestion]?
        var openedTab: [OmniBoxSuggestion]?
        var searchSuggestion: [OmniBoxSuggestion]?
    }
}
