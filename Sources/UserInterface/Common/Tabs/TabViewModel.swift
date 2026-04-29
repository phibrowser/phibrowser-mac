// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine
import AppKit

@Observable
@MainActor
final class TabViewModel {
    var title: String = ""
    var url: String?
    var faviconUrl: String?
    var liveFaviconImage: NSImage?
    private(set) var liveFaviconRevision: Int = 0
    /// The last non-nil URL used for favicon loading. Prevents globe flash
    /// when viewModel is briefly reconfigured with a nil-url tab during layout.
    private(set) var faviconLoadURL: String?
    var isActive: Bool = false
    var isPressed: Bool = false
    var isLoading: Bool = false
    var loadingProgress: Double = 1.0
    var isCurrentlyAudible: Bool = false
    var isAudioMuted: Bool = false
    var isCapturingMedia: Bool = false
    var isHorizontalCompactMode: Bool = false
    /// Color of the tab group this tab belongs to, if any. Drives the
    /// vertical group-affiliation bar on the leading edge of the cell.
    /// Tracks live: changes when the tab joins / leaves a group, when the
    /// group is closed, or when the group's color is recolored.
    var groupColor: GroupColor?
    /// Membership flag derived directly from `tab.groupToken`. Distinct
    /// from `groupColor != nil`: a tab can be a group member momentarily
    /// before its color resolves (kJoined arrives on the data side
    /// before `state.groups` re-emits onto the main runloop), so this
    /// flag is the authoritative signal for layout decisions like
    /// indentation that should not flicker on color settling.
    var isInGroup: Bool = false
    
    var onToggleMute: (() -> Void)?
    var onToolTipUpdated: (() -> Void)?
    
    private(set) var faviconRevision: Int = 0
    
    private var cancellables = Set<AnyCancellable>()

    var isShimmering: Bool {
        isLoading && loadingProgress < 0.99
    }
    
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url, !url.isEmpty { return url }
        return ""
    }

    func reloadFavicon() {
        faviconRevision += 1
    }

    func cancelSubscriptions() {
        cancellables.removeAll()
    }

    func prepareForReuse() {
        cancellables.removeAll()
        title = ""
        url = nil
        faviconUrl = nil
        faviconLoadURL = nil
        liveFaviconImage = nil
        liveFaviconRevision = 0
        isActive = false
        isPressed = false
        isLoading = false
        loadingProgress = 1.0
        isCurrentlyAudible = false
        isAudioMuted = false
        isCapturingMedia = false
        groupColor = nil
        faviconRevision &+= 1
        onToggleMute = nil
        onToolTipUpdated = nil
    }

    private var configuredTabGuid: Int?

    func configure(with tab: Tab, in browserState: BrowserState? = nil) {
        configuredTabGuid = tab.guid

        self.title = tab.title
        self.url = tab.url
        self.faviconLoadURL = (tab.url?.isEmpty == false) ? tab.url : nil
        self.faviconUrl = tab.faviconUrl
        updateLiveFavicon(data: tab.liveFaviconData, revision: tab.liveFaviconRevision)
        self.isActive = tab.isActive
        self.isLoading = tab.isLoading
        self.loadingProgress = Double(tab.loadingProgress)
        self.isCurrentlyAudible = tab.isCurrentlyAudible
        self.isAudioMuted = tab.isAudioMuted
        self.isCapturingMedia = tab.isCapturingAudio || tab.isCapturingVideo || tab.isSharingScreen
        
        cancellables.removeAll()
        let expectedGuid = tab.guid
        
        tab.$title
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newTitle in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.title = newTitle
                self.onToolTipUpdated?()
            }
            .store(in: &cancellables)
            
        tab.$url
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newUrl in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.url = newUrl
                // Intentionally keep faviconLoadURL when newUrl is nil/empty.
                // During navigation the URL briefly becomes nil before the new
                // page URL arrives; clearing faviconLoadURL here would cause a
                // globe-icon flash. configure() already resets it unconditionally.
                if let newUrl, !newUrl.isEmpty {
                    self.faviconLoadURL = newUrl
                }
            }
            .store(in: &cancellables)
            
        tab.$faviconUrl
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawFaviconUrl in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                let newFaviconUrl = (rawFaviconUrl?.isEmpty == false) ? rawFaviconUrl : nil
                let oldFaviconUrl = (self.faviconUrl?.isEmpty == false) ? self.faviconUrl : nil
                self.faviconUrl = rawFaviconUrl
                
                if let newFaviconUrl,
                    oldFaviconUrl?.isEmpty == false,
                    newFaviconUrl != oldFaviconUrl,
                   let pageURL = self.faviconLoadURL.flatMap(URL.init(string:)) {
                    Task { [weak self] in
                        await FaviconDataProvider.clearCache(for: pageURL)
                        self?.reloadFavicon()
                    }
                } else if oldFaviconUrl == nil {
                    self.reloadFavicon()
                }
            }
            .store(in: &cancellables)

        tab.$liveFaviconData
            .combineLatest(tab.$liveFaviconRevision)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data, revision in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.updateLiveFavicon(data: data, revision: revision)
            }
            .store(in: &cancellables)
            
        tab.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.isActive = $0
            }
            .store(in: &cancellables)
            
        tab.$isLoading
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVal in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.isLoading = newVal
            }
            .store(in: &cancellables)
            
        tab.$loadingProgress
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newVal in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.loadingProgress = Double(newVal)
            }
            .store(in: &cancellables)

        tab.$isCurrentlyAudible
            .combineLatest(tab.$isAudioMuted)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCurrentlyAudible, isAudioMuted in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.isCurrentlyAudible = isCurrentlyAudible
                self.isAudioMuted = isAudioMuted
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(tab.$isCapturingAudio, tab.$isCapturingVideo, tab.$isSharingScreen)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCapturingAudio, isCapturingVideo, isSharingScreen in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.isCapturingMedia = isCapturingAudio || isCapturingVideo || isSharingScreen
            }
            .store(in: &cancellables)

        // Group affiliation color. Updates on (a) tab joining/leaving a group,
        // (b) the dict gaining/losing the entry, (c) the current group's color
        // change. switchToLatest re-binds the inner color publisher whenever
        // membership changes so we don't leak subscriptions to old groups.
        if let token = tab.groupToken,
           let info = browserState?.groups[token] {
            self.groupColor = info.color
        } else {
            self.groupColor = nil
        }
        self.isInGroup = (tab.groupToken != nil)
        // Track group membership independently of color resolution. Updates
        // synchronously on tab.groupToken transitions so callers like
        // `SideTabView`'s indent rely on a flicker-free signal.
        tab.$groupToken
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inGroup in
                guard let self, self.configuredTabGuid == expectedGuid else { return }
                self.isInGroup = inGroup
            }
            .store(in: &cancellables)
        if let browserState {
            tab.$groupToken
                .combineLatest(browserState.$groups)
                .map { token, groups -> AnyPublisher<GroupColor?, Never> in
                    guard let token, let info = groups[token] else {
                        return Just(nil).eraseToAnyPublisher()
                    }
                    return info.$color
                        .map { Optional($0) }
                        .eraseToAnyPublisher()
                }
                .switchToLatest()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] color in
                    guard let self, self.configuredTabGuid == expectedGuid else { return }
                    self.groupColor = color
                }
                .store(in: &cancellables)
        }
    }

    private func updateLiveFavicon(data: Data?, revision: Int) {
        liveFaviconRevision = revision

        guard let data, let image = NSImage(data: data) else {
            liveFaviconImage = nil
            return
        }

        liveFaviconImage = image
    }
}
