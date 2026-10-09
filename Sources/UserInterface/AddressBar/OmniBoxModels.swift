// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
import Dispatch
import Kingfisher
// MARK: - OmniBox Suggestion Types

enum OmniBoxSuggestionType: String, CaseIterable {
    case url = "url"
    case search = "search"
    case searchSuggest = "searchSuggest"
    case bookmark = "bookmark"
    case history = "history"
    case topSite = "topSite"
    case `extension` = "extension"
    case searchEngine = "searchOtherEngine"
    case opennedTab = "opennedTab"
    case pedal = "pedal"
}

// MARK: - OmniBox Suggestion Model

struct OmniBoxKeywordSearchEngine: Equatable {
    let keyword: String
    let name: String

    // Match the keywords seeded by Chromium, never the user-editable display name.
    var brandColor: NSColor? {
        switch keyword.lowercased() {
        case "x.com", "twitter.com", "wikipedia.org": return NSColor(hex: 0x000000)
        case "spotify.com": return NSColor(hex: 0x1DB954)
        case "reddit.com": return NSColor(hex: 0xFF4500)
        case "youtube.com": return NSColor(hex: 0xFF0000)
        case "github.com": return NSColor(hex: 0x24292F)
        case "gmail.com": return NSColor(hex: 0xEA4335)
        case "docs.google.com", "calendar.google.com": return NSColor(hex: 0x4285F4)
        case "drive.google.com": return NSColor(hex: 0x34A853)
        default: return nil
        }
    }

    var accentColor: ThemedColor {
        brandColor.map { ThemedColor($0) } ?? .themeColor
    }

    init?(dictionary: [String: String]) {
        guard let keyword = dictionary["keyword"], !keyword.isEmpty,
              let name = dictionary["name"], !name.isEmpty else { return nil }
        self.keyword = keyword
        self.name = name
    }
}

struct OmniBoxSuggestion: Equatable {
    let type: OmniBoxSuggestionType
    let title: String
    let subtitle: String?
    let url: String
    let iconName: String?
    let iconURL: String?
    let relevanceScore: Int
    let isStarred: Bool
    let canDelete: Bool
    let fillIntoEdit: String
    let swapContentsAndDescription: Bool
    let hasTabMatch: Bool
    let index: Int
    var inlineCompletionString: String?
    var allowedToBeDefault: Bool = true
    // Keyword-search metadata from a Chromium autocomplete match.
    var keywordSearchEngine: OmniBoxKeywordSearchEngine?
    var keywordSearchQuery: String?
    var keywordSearchFaviconURL: URL?

    init(
        type: OmniBoxSuggestionType,
        title: String,
        subtitle: String? = nil,
        url: String,
        iconName: String? = nil,
        iconURL: String? = nil,
        index: Int,
        relevanceScore: Int = 0,
        isStarred: Bool = false,
        stringToFill: String,
        swapContentsAndDescription: Bool,
        canDelete: Bool = false,
        hasTabMatch: Bool = false
    ) {
        self.type = type
        self.title = title.replaceChromeSchemeWithPhi()
        self.subtitle = subtitle
        self.url = url
        self.iconName = iconName
        self.iconURL = iconURL
        self.relevanceScore = relevanceScore
        self.index = index
        self.isStarred = isStarred
        self.canDelete = canDelete
        self.fillIntoEdit = stringToFill.replaceChromeSchemeWithPhi()
        self.swapContentsAndDescription = swapContentsAndDescription
        self.hasTabMatch = hasTabMatch
    }
    
    func defaultIconName() -> String {
        switch type {
        case .url:
            return "globe"
        case .search, .searchSuggest, .searchEngine:
            return "magnifyingglass"
        case .bookmark:
            return "star.fill"
        case .history:
            return "clock"
        case .topSite:
            return "star"
        case .extension:
            return "puzzlepiece"
        default:
            return "globe"
        }
    }
    
    init(chromiumDic: [String: Any]) {
        let relevance = chromiumDic["relevance"] as? Int ?? 0
        let contents = chromiumDic["contents"] as? String ?? ""
        let description = chromiumDic["description"] as? String ?? ""
        let destinationUrl = chromiumDic["destinationUrl"] as? String ?? ""
        let type = chromiumDic["type"] as? String ?? ""
        let fillString = chromiumDic["fillIntoEdit"] as? String ?? ""
        let swap = chromiumDic["swapContentsAndDescription"] as? Bool ?? false
        let tabMatch = chromiumDic["hasTabMatch"] as? Bool ?? false
        let index = chromiumDic["line"] as? Int
        let iconUrl = chromiumDic["imageUrl"] as? String
        let deletable = chromiumDic["deletable"] as? Bool ?? false
        let inlineCompletion = chromiumDic["inlineAutocompletion"] as? String
        let allowdToBeDefault = chromiumDic["allowedToBeDefaultMatch"] as? Bool ?? true
        var omniTpye: OmniBoxSuggestionType
        switch type.lowercased() {
        case "search-suggest":
            omniTpye = .searchSuggest
        case "search-what-you-typed":
            omniTpye = .searchSuggest
        case "bookmark-title":
            omniTpye = .bookmark
        case "history-url", "search-history":
            omniTpye = .history
        case "search-other-engine":
            omniTpye = .searchEngine // For inputs like `google.com`.
        case "pedal":
            omniTpye = .pedal // Commands such as "share tab".
        default:
            omniTpye = .url
        }
        let engine = type == "search-other-engine"
            ? OmniBoxKeywordSearchEngine(dictionary: [
                "keyword": chromiumDic["keywordSearchKeyword"] as? String ?? "",
                "name": chromiumDic["keywordSearchName"] as? String ?? ""
            ]) ?? (destinationUrl.isEmpty ? nil : OmniBoxKeywordSearchEngine(dictionary: [
                "keyword": fillString.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "",
                "name": description
            ])) : nil
        let selectionEngine = destinationUrl.isEmpty ? engine : nil
        let title = selectionEngine.map {
            String(format: NSLocalizedString("addressBar.keywordSearch.suggestionTitle", value: "Search %@", comment: "Address bar - Suggestion that selects the named search engine"), $0.name)
        } ?? contents
        self.init(type: omniTpye,
                  title: title,
                  subtitle: selectionEngine?.keyword ?? description,
                  url: destinationUrl,
                  iconName: omniTpye == .searchEngine ? "magnifyingglass" : nil,
                  iconURL: iconUrl,
                  index: index ?? -1,
                  relevanceScore: relevance,
                  isStarred: omniTpye == .bookmark,
                  stringToFill: fillString,
                  swapContentsAndDescription: swap,
                  canDelete: selectionEngine == nil && deletable,
                  hasTabMatch: tabMatch)
        self.inlineCompletionString = inlineCompletion
        self.allowedToBeDefault = selectionEngine == nil && allowdToBeDefault
        self.keywordSearchEngine = engine
        self.keywordSearchQuery = engine != nil && !destinationUrl.isEmpty ? contents : nil
        if omniTpye == .searchEngine,
           let source = chromiumDic["keywordSearchFaviconURL"] as? String,
           let faviconURL = URL(string: source),
           let host = faviconURL.host, !host.isEmpty,
           faviconURL.scheme == "https" || faviconURL.scheme == "http" {
            self.keywordSearchFaviconURL = faviconURL
        }
        
    }
    
    var isEmpty: Bool { title.isEmpty && (subtitle?.isEmpty ?? true) }
    var isSupportedType: Bool { type != .pedal /*&& type != .searchEngine*/ }

    var faviconPageURL: URL? {
        type == .history ? URL(string: url) : nil
    }
}

extension OmniBoxSuggestion: CustomStringConvertible {
    var description: String {
        "title-contents: \(title), subTitle-des: \(subtitle ?? ""), type: \(type), inline:\(String(describing: inlineCompletionString)), fill:\(fillIntoEdit)"
    }
}

enum OmniBoxSearchRequestSource: String {
    case inputChange = "input-change"
    case openPrefill = "open-prefill"
    case manualRefresh = "manual-refresh"
}

struct OmniBoxSearchRequestToken: Equatable {
    let id: Int
    let query: String
    let source: OmniBoxSearchRequestSource
}

final class OmniBoxSearchCoordinator {
    private var nextRequestID: Int = 0
    private var latestQuery: String?
    private var suppressNextAutomaticSearch = false

    func prepareForPrefilledOpen(text: String, minInputLength: Int) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        suppressNextAutomaticSearch = trimmedText.count >= minInputLength
    }

    func shouldPerformAutomaticSearch(for text: String, minInputLength: Int) -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count >= minInputLength else {
            suppressNextAutomaticSearch = false
            return false
        }

        if suppressNextAutomaticSearch {
            suppressNextAutomaticSearch = false
            return false
        }

        return true
    }

    func beginRequest(query: String, source: OmniBoxSearchRequestSource) -> OmniBoxSearchRequestToken {
        nextRequestID += 1
        latestQuery = query
        return OmniBoxSearchRequestToken(id: nextRequestID, query: query, source: source)
    }

    /// Chromium streams suggestions as providers respond, so we may receive multiple updates
    /// per request. Accept every response whose original query still matches the latest one
    /// the user requested; older responses (from stale queries) are dropped.
    func shouldAcceptResponse(forQuery query: String) -> Bool {
        latestQuery == query
    }

    var currentQuery: String? { latestQuery }

    func reset() {
        nextRequestID = 0
        suppressNextAutomaticSearch = false
        latestQuery = nil
    }
}

final class OmniBoxTraceSession {
    private let sessionID: String
    private let trigger: String
    private let startedAt: UInt64
    private let timeProvider: () -> UInt64
    private var loggedStages = Set<String>()

    init(
        trigger: String,
        sessionID: String = String(UUID().uuidString.prefix(8)),
        timeProvider: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.sessionID = sessionID
        self.trigger = trigger
        self.timeProvider = timeProvider
        self.startedAt = timeProvider()
    }

    func message(for stage: String, details: String? = nil) -> String {
        let elapsedMilliseconds = Double(timeProvider() - startedAt) / 1_000_000
        let detailsSuffix: String
        if let details, !details.isEmpty {
            detailsSuffix = " \(details)"
        } else {
            detailsSuffix = ""
        }
        return "[OmniboxTrace] session=\(sessionID) trigger=\(trigger) stage=\(stage) elapsed=\(String(format: "%.1f", elapsedMilliseconds))ms\(detailsSuffix)"
    }

    func log(stage: String, details: String? = nil) {
        AppLogDebug(message(for: stage, details: details))
    }

    func logOnce(stage: String, details: String? = nil) {
        guard loggedStages.insert(stage).inserted else { return }
        log(stage: stage, details: details)
    }
}

// MARK: - OmniBox State Management

class OmniBoxState: ObservableObject {
    @Published var inputText: String = ""
    @Published var suggestions: [OmniBoxSuggestion] = []
    @Published var selectedIndex: Int = -1
    @Published var isShowingSuggestions: Bool = false
    @Published var isFocused: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        $suggestions
            .map { !$0.isEmpty }
            .assign(to: \.isShowingSuggestions, on: self)
            .store(in: &cancellables)
    }
    
    func selectSuggestion(at index: Int) {
        guard index >= 0 && index < suggestions.count else { return }
        selectedIndex = index
    }
    
    func selectNextSuggestion() {
        if selectedIndex < suggestions.count - 1 {
            selectedIndex += 1
        } else if selectedIndex == suggestions.count - 1 {
            selectedIndex = 0
        }
    }
    
    func selectPreviousSuggestion() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else if selectedIndex == 0 || selectedIndex == -1 {
            selectedIndex = suggestions.count - 1
        }
    }
    
    var selectedSuggestion: OmniBoxSuggestion? {
        guard selectedIndex >= 0 && selectedIndex < suggestions.count else { return nil }
        return suggestions[selectedIndex]
    }
    
    func clearSuggestions() {
        if !suggestions.isEmpty { suggestions = [] }
        if selectedIndex != -1 { selectedIndex = -1 }

    }
    
    func reset() {
        inputText = ""
        clearSuggestions()
        isFocused = false
    }
}

// MARK: - OmniBox Configuration

struct OmniBoxConfiguration {
    let maxSuggestions: Int
    let debounceInterval: DispatchQueue.SchedulerTimeType.Stride
    let minInputLength: Int
    let showBookmarks: Bool
    let showHistory: Bool
    let showTopSites: Bool
    let placeholder: String
    
    static let `default` = OmniBoxConfiguration(
        maxSuggestions: 8,
        debounceInterval: .seconds(0.1),
        minInputLength: 1,
        showBookmarks: true,
        showHistory: true,
        showTopSites: true,
        placeholder: NSLocalizedString("addressBar.configuration.defaultPlaceholder", value: "Search or Enter URL", comment: "Address bar - Default placeholder supplied by its configuration")
    )
}

// MARK: - OmniBox Action Protocol

protocol OmniBoxActionDelegate: AnyObject {
    func omniBoxDidClear()
}

struct OmniSuggestionIconProvier {
    @MainActor
    static func updateImage(for iconImageView: NSImageView, with suggestion: OmniBoxSuggestion, defaultImage: NSImage? = nil) {
        iconImageView.kf.cancelDownloadTask()
        if suggestion.type == .searchEngine {
            iconImageView.contentTintColor = nil
            iconImageView.kf.setImage(
                with: suggestion.keywordSearchFaviconURL,
                placeholder: defaultIcon(for: .searchEngine),
                options: [.transition(.fade(0.2)), .cacheOriginalImage]
            )
        } else if let url = suggestion.faviconPageURL {
            iconImageView.contentTintColor = nil
            iconImageView.setFavicon(for: url)
        } else if let iconName = suggestion.iconName {
            iconImageView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        } else if let iconURLStr = suggestion.iconURL,
                  let iconURL = URL(string: iconURLStr) {
            iconImageView.kf.setImage(
                with: iconURL,
                placeholder: NSImage(systemSymbolName: "globe", accessibilityDescription: "Website"),
                options: [.transition(.fade(0.2)),
                          .cacheOriginalImage,
                          .processor( RoundCornerImageProcessor(cornerRadius: 6))]
            )
        } else {
            let defaultIcon = defaultImage ?? defaultIcon(for: suggestion.type)
            iconImageView.image = defaultIcon
        }
        
    }
    
    private static func defaultIcon(for type: OmniBoxSuggestionType) -> NSImage? {
        let iconName: String = {
            switch type {
            case .url:
                return "globe"
            case .search, .searchSuggest, .searchEngine:
                return "magnifyingglass"
            case .bookmark:
                return "star.fill"
            case .history:
                return "clock"
            case .topSite:
                return "star"
            case .extension:
                return "puzzlepiece"
            default:
                return "globe"
            }
        }()
        return NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
    }
}

extension String {
    var hasSchemePrefix: Bool {
        let lowercased = lowercased()
        return lowercased.hasPrefix("http://") ||
        lowercased.hasPrefix("https://") ||
        lowercased.hasPrefix("ftp://") ||
        lowercased.hasPrefix("file://") ||
        lowercased.hasPrefix("chrome://") ||
        lowercased.hasPrefix("phi://")
    }
    
    func urlScheme() -> String? {
        guard let range = self.range(of: "://") else {
            return nil
        }
        return String(self[..<range.lowerBound])
    }
    
    func trimmingScheme() -> String {
        guard let range = self.range(of: "://") else {
            return self
        }
        return String(self[range.upperBound...])
    }
    
    func normalizedForURLComparison() -> String {
        var result = self.trimmingScheme().lowercased()
        if result.hasPrefix("www.") {
            result = String(result.dropFirst(4))
        }
        while result.hasSuffix("/") {
            result = String(result.dropLast())
        }
        return result
    }

    func replaceChromeSchemeWithPhi() -> String {
        return URLProcessor.phiBrandEnsuredUrlString(self)
    }
}
