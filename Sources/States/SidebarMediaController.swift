// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// One window's sidebar player. Tab publications discover likely media;
/// only the selected page is polled, and only while its sidebar is active.
@MainActor
final class SidebarMediaController: ObservableObject {
    enum Surface: Hashable { case docked, floating }
    struct Item: Equatable {
        let tabId: Int
        let targetId: String
        let pageURL: String?
        let documentEpoch: Int
        let playback: SidebarMediaBridge.Playback
        let faviconData: Data?
        let isTabMuted: Bool
    }

    @Published private(set) var item: Item?
    @Published private(set) var isRevalidating = false
    @Published private(set) var isSourceVisible = false
    @Published private(set) var isDismissed = false
    @Published private(set) var activeSurface: Surface?
    @Published private(set) var isExpanded = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var presentationMode: SidebarMediaPresentationMode
    @Published private(set) var backgroundSourceCount = 0
    enum CycleDirection { case next, previous }
    @Published private(set) var cycleDirection: CycleDirection = .next
    @Published private(set) var cycleAnimationGeneration = 0

    private struct SourceIdentity: Equatable {
        let tabId: Int
        let targetId: String
        let pageURL: String?
        let documentEpoch: Int
        let source: String
        let index: Int
        let topDocumentTimeOrigin: Double
        let mediaDocumentTimeOrigin: Double
        let title: String
        let artist: String?
        let metadataIdentity: String

        init(_ item: Item) {
            tabId = item.tabId
            targetId = item.targetId
            pageURL = item.pageURL
            documentEpoch = item.documentEpoch
            source = item.playback.source
            index = item.playback.index
            topDocumentTimeOrigin = item.playback.topDocumentTimeOrigin
            mediaDocumentTimeOrigin = item.playback.mediaDocumentTimeOrigin
            title = item.playback.title
            artist = item.playback.artist
            metadataIdentity = item.playback.metadataIdentity
        }
    }
    private var dismissedSources: [Int: SourceIdentity] = [:]
    private var candidates: [Int: Item] = [:]
    private var manuallySelectedTabId: Int?
    private var previousFocusedTabId: Int?
    private var visitsAwaitingPlayback = Set<Int>()
    private var cyclingTabId: Int?
    private var cycleGeneration = 0
    private var hoveredSurface: Surface?
    private var hoverEntryWorkItem: DispatchWorkItem?
    private var hoverGeneration = 0

    private weak var browserState: BrowserState?
    private let defaults: UserDefaults
    private var preferencesSubscription: AnyCancellable?
    private var isActive = false
    private var activeSurfaces = Set<Surface>()
    private var observedTabs: [Int: (tab: Tab, subscriptions: Set<AnyCancellable>)] = [:]
    private var stateSubscriptions = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var pollConnection: SidebarMediaBridge.PollConnection?
    private var discoveryTimer: Timer?
    private var inspectionsInFlight = Set<Int>()
    private var documentEpochs: [Int: Int] = [:]
    private var pollInFlight = false
    private var consecutiveMisses = 0
    private var selectionGeneration = 0
    private var activationGeneration = 0

    init(browserState: BrowserState, defaults: UserDefaults = .standard) {
        self.browserState = browserState
        self.defaults = defaults
        isEnabled = PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.loadValue(from: defaults)
        presentationMode = PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults)
        preferencesSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPreferences() }
    }

    func setActive(_ active: Bool, on surface: Surface = .docked) {
        if active {
            activeSurfaces.insert(surface)
        } else {
            activeSurfaces.remove(surface)
        }
        updateActivation()
    }

    private func refreshPreferences() {
        let enabled = PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.loadValue(from: defaults)
        let mode = PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults)
        if isEnabled != enabled { isEnabled = enabled }
        if presentationMode != mode {
            cancelCycle()
            cancelHoverExpansion(clearHover: true)
            presentationMode = mode
            applyPresentationMode(resetDynamic: true)
        }
        updateActivation()
    }

    private func updateActivation() {
        let presented: Surface? = !isEnabled ? nil
            : activeSurfaces.contains(.floating) ? .floating
            : activeSurfaces.contains(.docked) ? .docked : nil
        if activeSurface != presented {
            cancelHoverExpansion(clearHover: true)
            cancelCycle()
            activeSurface = presented
            applyPresentationMode(resetDynamic: true)
        }
        let anySurfaceActive = presented != nil
        guard anySurfaceActive != isActive else { return }
        isActive = anySurfaceActive
        if anySurfaceActive {
            bindState()
            syncTabs()
            // A silent video has no audible notification. Check the focused
            // page occasionally, without probing every tab in the window.
            discoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.probeFocusedTab() }
            }
            if item != nil {
                startPolling()
                pollSelected()
            }
            probeFocusedTab()
        } else {
            // Hidden tabs can reload the same URL and target without any of
            // this controller's subscriptions seeing it. Keep the selection
            // for later, but hide and block it until a fresh snapshot arrives.
            isRevalidating = item != nil
            backgroundSourceCount = 0
            candidates.removeAll()
            visitsAwaitingPlayback.removeAll()
            stateSubscriptions.removeAll()
            observedTabs.removeAll()
            discoveryTimer?.invalidate()
            discoveryTimer = nil
            pollTimer?.invalidate()
            pollTimer = nil
            pollConnection?.close()
            pollConnection = nil
            selectionGeneration += 1
            activationGeneration += 1
            // Retain the paused source while the sidebar is hidden. It is
            // revalidated before the first poll when the sidebar returns.
        }
    }

    private func bindState() {
        guard let browserState else { return }
        browserState.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTabs() }
            .store(in: &stateSubscriptions)
        browserState.$focusingTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tab in self?.focusChanged(to: tab) }
            .store(in: &stateSubscriptions)
        browserState.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSelection() }
            .store(in: &stateSubscriptions)
    }

    private func syncTabs() {
        guard isActive, let browserState else { return }
        let liveTabs = browserState.tabs.filter { $0.isOpenned && $0.webContentWrapper != nil }
        let ids = Set(liveTabs.map(\.guid))
        observedTabs = observedTabs.filter { entry in
            liveTabs.contains { $0.guid == entry.key && $0 === entry.value.tab }
        }
        documentEpochs = documentEpochs.filter { ids.contains($0.key) }
        candidates = candidates.filter { ids.contains($0.key) }
        visitsAwaitingPlayback.formIntersection(ids)
        dismissedSources = dismissedSources.filter { ids.contains($0.key) }
        if let item, !liveTabs.contains(where: { $0.guid == item.tabId }) {
            clearSelection()
        }

        for tab in liveTabs where observedTabs[tab.guid] == nil {
            var subscriptions = Set<AnyCancellable>()
            tab.$isCurrentlyAudible
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] audible in
                    guard let self, let tab else { return }
                    // A known source may pause/end or become silent. Inspect
                    // that transition rather than trusting its last snapshot.
                    if audible || self.candidates[tab.guid] != nil || self.item?.tabId == tab.guid {
                        self.inspect(tab)
                    }
                }
                .store(in: &subscriptions)
            tab.$url
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab else { return }
                    self.candidates.removeValue(forKey: tab.guid)
                    self.visitsAwaitingPlayback.remove(tab.guid)
                    if self.cyclingTabId == tab.guid { self.cancelCycle() }
                    if self.item?.tabId == tab.guid { self.clearSelection() }
                    self.refreshSelection()
                }
                .store(in: &subscriptions)
            tab.$isLoading
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] loading in
                    guard let self, let tab else { return }
                    if loading {
                        self.documentEpochs[tab.guid, default: 0] += 1
                        self.candidates.removeValue(forKey: tab.guid)
                        self.visitsAwaitingPlayback.remove(tab.guid)
                        if self.cyclingTabId == tab.guid { self.cancelCycle() }
                        if self.item?.tabId == tab.guid { self.clearSelection() }
                        self.refreshSelection()
                    } else if self.browserState?.focusingTab === tab || tab.isCurrentlyAudible {
                        self.inspect(tab)
                    }
                }
                .store(in: &subscriptions)
            observedTabs[tab.guid] = (tab, subscriptions)
        }
        refreshSelection()
    }

    private func focusChanged(to tab: Tab?) {
        let oldId = previousFocusedTabId
        previousFocusedTabId = tab?.guid
        if oldId != tab?.guid {
            visitsAwaitingPlayback.formUnion([oldId, tab?.guid].compactMap { $0 }.filter {
                candidates[$0]?.playback.isPlaying != true && observedTabs[$0]?.tab.isCurrentlyAudible != true
            })
            cancelCycle()
            // Unrelated visits preserve an explicit card choice. Visiting or
            // leaving a playing media source restores the browser's MRU policy.
            if [oldId, tab?.guid].compactMap({ $0 }).contains(where: {
                candidates[$0]?.playback.isPlaying == true || observedTabs[$0]?.tab.isCurrentlyAudible == true
            }) { manuallySelectedTabId = nil }
            if let oldId, let previous = observedTabs[oldId]?.tab { inspect(previous) }
        }
        refreshSelection()
        probeFocusedTab()
    }

    private func probeFocusedTab() {
        guard isActive, let tab = browserState?.focusingTab else { return }
        if item?.tabId == tab.guid { return }
        inspect(tab)
    }

    private func inspect(_ tab: Tab) {
        guard isActive, tab.isOpenned,
              !tab.isLoading,
              !inspectionsInFlight.contains(tab.guid),
              let targetId = tab.webContentWrapper?.devToolsTargetId,
              !targetId.isEmpty else { return }
        inspectionsInFlight.insert(tab.guid)
        let tabId = tab.guid
        let pageURL = tab.url
        let documentEpoch = documentEpochs[tabId, default: 0]
        let activation = activationGeneration
        Task { [weak self, weak tab] in
            let playback = await SidebarMediaBridge.inspect(
                targetId: targetId, fallbackTitle: tab?.title ?? "")
            guard let self else { return }
            self.inspectionsInFlight.remove(tabId)
            guard self.activationGeneration == activation else {
                // The old activation may have occupied this tab's inspection
                // slot during reveal. Rediscover it with a fresh request now.
                if self.isActive, let tab,
                   tab.isCurrentlyAudible || self.browserState?.focusingTab === tab {
                    self.inspect(tab)
                }
                return
            }
            guard let tab, self.isValid(tab, targetId: targetId,
                                        pageURL: pageURL, documentEpoch: documentEpoch) else { return }
            if let playback {
                let confirmsPlayingVisit = self.visitsAwaitingPlayback.remove(tabId) != nil && playback.isPlaying
                self.remember(tab: tab, targetId: targetId, pageURL: pageURL,
                              documentEpoch: documentEpoch, playback: playback)
                if confirmsPlayingVisit { self.manuallySelectedTabId = nil }
            } else {
                self.visitsAwaitingPlayback.remove(tabId)
                self.candidates.removeValue(forKey: tabId)
                if self.item?.tabId == tabId { self.clearSelection() }
            }
            self.refreshSelection()
        }
    }

    private func remember(tab: Tab, targetId: String, pageURL: String?,
                          documentEpoch: Int, playback: SidebarMediaBridge.Playback) {
        let candidate = Item(tabId: tab.guid, targetId: targetId, pageURL: pageURL,
                             documentEpoch: documentEpoch, playback: playback,
                             faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                             isTabMuted: tab.isAudioMuted)
        if let previous = candidates[tab.guid], SourceIdentity(previous) != SourceIdentity(candidate),
           cyclingTabId == tab.guid { cancelCycle() }
        candidates[tab.guid] = candidate
        if let dismissed = dismissedSources[tab.guid], dismissed != SourceIdentity(candidate) {
            dismissedSources.removeValue(forKey: tab.guid)
        }
    }

    private func isVisible(_ tabId: Int) -> Bool {
        guard let state = browserState, let focused = state.focusingTab else { return false }
        return focused.guid == tabId
            || state.splitGroup(forTabId: tabId)?.contains(tabId: focused.guid) == true
    }

    private func isValid(_ candidate: Item) -> Bool {
        guard let tab = observedTabs[candidate.tabId]?.tab else { return false }
        return isValid(tab, targetId: candidate.targetId, pageURL: candidate.pageURL,
                       documentEpoch: candidate.documentEpoch)
    }

    private var orderedBackgroundSources: [Item] {
        guard let state = browserState else { return [] }
        let history = state.tabSwitchManager.visitedTabIDs
        let order = history + state.tabs.map(\.guid).filter { !history.contains($0) }
        return order.compactMap { id in
            guard let candidate = candidates[id], isValid(candidate), !isVisible(id),
                  dismissedSources[id] != SourceIdentity(candidate),
                  candidate.playback.isPlaying || item?.tabId == id else { return nil }
            return candidate
        }
    }

    private func refreshSelection() {
        guard isActive else { backgroundSourceCount = 0; return }
        // Empty activation caches are not selection loss. Keep the retained
        // manual/paused identity concealed until its own fresh result arrives.
        if isRevalidating, let retained = item, isValid(retained), candidates[retained.tabId] == nil { return }
        let choices = orderedBackgroundSources
        backgroundSourceCount = choices.count
        let chosen: Item?
        if let manual = manuallySelectedTabId, let candidate = choices.first(where: { $0.tabId == manual }) {
            chosen = candidate
        } else {
            manuallySelectedTabId = nil
            chosen = choices.first
        }
        if let chosen, let tab = observedTabs[chosen.tabId]?.tab {
            select(tab: tab, targetId: chosen.targetId, pageURL: chosen.pageURL,
                   documentEpoch: chosen.documentEpoch, playback: chosen.playback)
        } else if let current = item, isValid(current) {
            // Retain an active or dismissed source for reappearance/new-track
            // detection, without concealing another eligible background player.
            updateSourceVisibility()
        } else if item == nil, let focused = browserState?.focusingTab,
                  let candidate = candidates[focused.guid], isValid(candidate) {
            select(tab: focused, targetId: candidate.targetId, pageURL: candidate.pageURL,
                   documentEpoch: candidate.documentEpoch, playback: candidate.playback)
        }
    }

    /// Cycling changes only the presented source, never tab focus or playback.
    /// The destination's cached identity must survive a fresh page inspection.
    func cycleSource(for expectedItem: Item, direction: CycleDirection = .next, from surface: Surface) {
        guard hasEligibleSource, activeSurface == surface, matchesCurrentSource(expectedItem) else { return }
        let choices = orderedBackgroundSources
        guard choices.count > 1 else { return }
        let anchor = cyclingTabId ?? expectedItem.tabId
        let index = choices.firstIndex(where: { $0.tabId == anchor }) ?? 0
        let offset = direction == .next ? 1 : choices.count - 1
        let destination = choices[(index + offset) % choices.count]
        guard let tab = observedTabs[destination.tabId]?.tab else { return }
        cancelCycle()
        cyclingTabId = destination.tabId
        let generation = cycleGeneration
        let identity = SourceIdentity(destination)
        Task { [weak self, weak tab] in
            let playback = await SidebarMediaBridge.inspect(targetId: destination.targetId,
                                                             fallbackTitle: tab?.title ?? "")
            guard let self else { return }
            defer {
                if self.cycleGeneration == generation { self.cyclingTabId = nil }
            }
            guard self.cycleGeneration == generation,
                  self.cyclingTabId == destination.tabId,
                  self.activeSurface == surface, self.matchesCurrentSource(expectedItem),
                  let tab, self.isValid(destination), !self.isVisible(destination.tabId),
                  self.candidates[destination.tabId].map(SourceIdentity.init) == identity else { return }
            guard let playback else {
                self.cancelCycle()
                self.candidates.removeValue(forKey: destination.tabId)
                if self.item?.tabId == destination.tabId { self.clearSelection() }
                self.refreshSelection()
                return
            }
            let fresh = Item(tabId: destination.tabId, targetId: destination.targetId,
                             pageURL: destination.pageURL, documentEpoch: destination.documentEpoch,
                             playback: playback, faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                             isTabMuted: tab.isAudioMuted)
            guard SourceIdentity(fresh) == identity,
                  playback.isPlaying || !destination.playback.isPlaying else {
                self.cancelCycle()
                self.remember(tab: tab, targetId: destination.targetId, pageURL: destination.pageURL,
                              documentEpoch: destination.documentEpoch, playback: playback)
                self.refreshSelection()
                return
            }
            self.cyclingTabId = nil
            self.manuallySelectedTabId = destination.tabId
            self.remember(tab: tab, targetId: destination.targetId, pageURL: destination.pageURL,
                          documentEpoch: destination.documentEpoch, playback: playback)
            self.cycleDirection = direction
            self.cycleAnimationGeneration += 1
            self.select(tab: tab, targetId: destination.targetId, pageURL: destination.pageURL,
                        documentEpoch: destination.documentEpoch, playback: playback,
                        preservePresentation: true)
            self.refreshSelection()
        }
    }

    private func cancelCycle() {
        cycleGeneration += 1
        cyclingTabId = nil
    }

    private func select(tab: Tab, targetId: String, pageURL: String?,
                        documentEpoch: Int,
                        playback: SidebarMediaBridge.Playback, preservePresentation: Bool = false) {
        let previousSource = item.map(SourceIdentity.init)
        let replaced = item?.tabId != tab.guid || item?.targetId != targetId
        if replaced {
            pollConnection?.close()
            pollConnection = nil
        }
        item = Item(tabId: tab.guid, targetId: targetId, pageURL: pageURL,
                    documentEpoch: documentEpoch,
                    playback: playback,
                    faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                    isTabMuted: tab.isAudioMuted)
        if let item {
            // A new track or document starts a new presentation session.
            // Preserve dismissal only across polls of the same source.
            isDismissed = dismissedSources[item.tabId] == SourceIdentity(item)
            updateSourceVisibility()
        }
        isRevalidating = false
        let sourceChanged = item.map(SourceIdentity.init) != previousSource
        if sourceChanged {
            cancelHoverExpansion(clearHover: true)
            cancelCycle()
        }
        // A validated user cycle preserves the current presentation, including
        // a hover exit that occurred while its destination was being inspected.
        applyPresentationMode(resetDynamic: sourceChanged && !preservePresentation)
        if replaced {
            selectionGeneration += 1
            consecutiveMisses = 0
        }
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSelected() }
        }
    }

    private func pollSelected() {
        guard isActive, !pollInFlight else { return }
        guard let item,
              let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, targetId: item.targetId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else {
            if item != nil { clearSelection() }
            return
        }
        pollInFlight = true
        let generation = selectionGeneration
        let connection: SidebarMediaBridge.PollConnection
        if let existing = pollConnection, existing.targetId == item.targetId {
            connection = existing
        } else {
            pollConnection?.close()
            connection = SidebarMediaBridge.PollConnection(targetId: item.targetId)
            pollConnection = connection
        }
        Task { [weak self, weak tab] in
            let playback = await connection.inspect(fallbackTitle: tab?.title ?? "")
            guard let self else { return }
            self.pollInFlight = false
            guard self.selectionGeneration == generation,
                  let tab,
                  self.isValid(tab, targetId: item.targetId, pageURL: item.pageURL,
                               documentEpoch: item.documentEpoch) else { return }
            guard let playback else {
                self.consecutiveMisses += 1
                if self.consecutiveMisses >= 2 {
                    self.clearSelection()
                    self.probeFocusedTab()
                }
                return
            }
            self.consecutiveMisses = 0
            self.remember(tab: tab, targetId: item.targetId, pageURL: item.pageURL,
                          documentEpoch: item.documentEpoch, playback: playback)
            self.refreshSelection()
        }
    }

    private func isValid(_ tab: Tab, targetId: String, pageURL: String?,
                         documentEpoch: Int) -> Bool {
        isActive && tab.isOpenned && !tab.isLoading && tab.url == pageURL
            && documentEpochs[tab.guid, default: 0] == documentEpoch
            && tab.webContentWrapper?.devToolsTargetId == targetId
            && observedTabs[tab.guid]?.tab === tab
    }

    private func clearSelection() {
        let lostTabId = item?.tabId
        if let lostTabId {
            candidates.removeValue(forKey: lostTabId)
            visitsAwaitingPlayback.remove(lostTabId)
        }
        manuallySelectedTabId = nil
        cancelCycle()
        cancelHoverExpansion(clearHover: true)
        selectionGeneration += 1
        item = nil
        isSourceVisible = false
        isDismissed = false
        isRevalidating = false
        isExpanded = false
        consecutiveMisses = 0
        pollTimer?.invalidate()
        pollTimer = nil
        pollConnection?.close()
        pollConnection = nil
        // Audible publications need not repeat when another source ends or
        // closes. Rescan those existing live candidates once on selection loss.
        // Skip the lost source, whose audible flag may lag its ended snapshot.
        if let lostTabId, isActive, let browserState {
            for tab in browserState.tabs where tab.guid != lostTabId && tab.isCurrentlyAudible {
                inspect(tab)
            }
        }
        refreshSelection()
    }

    private func updateSourceVisibility() {
        guard let browserState, let item, let focused = browserState.focusingTab else {
            isSourceVisible = false
            return
        }
        // Both panes of a split are visible even when only one owns focus.
        isSourceVisible = focused.guid == item.tabId
            || browserState.splitGroup(forTabId: item.tabId)?.contains(tabId: focused.guid) == true
        if isSourceVisible {
            cancelHoverExpansion(clearHover: true)
            isExpanded = false
        } else {
            applyPresentationMode()
        }
    }

    func matchesCurrentSource(_ displayedItem: Item) -> Bool {
        item.map(SourceIdentity.init) == SourceIdentity(displayedItem)
    }

    func dismissCurrent(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              let item, !isRevalidating,
              surface == nil || activeSurface == surface else { return }
        cancelHoverExpansion(clearHover: true)
        cancelCycle()
        dismissedSources[item.tabId] = SourceIdentity(item)
        isDismissed = true
        isExpanded = false
        refreshSelection()
    }

    private var hasEligibleSource: Bool {
        isEnabled && activeSurface != nil && item != nil
            && !isRevalidating && !isSourceVisible && !isDismissed
    }

    private func applyPresentationMode(resetDynamic: Bool = false) {
        guard hasEligibleSource else { isExpanded = false; return }
        switch presentationMode {
        case .alwaysExpanded: isExpanded = true
        case .alwaysCompact: isExpanded = false
        case .dynamic:
            if resetDynamic { isExpanded = false }
        }
    }

    func setExpanded(_ expanded: Bool, on surface: Surface) {
        guard activeSurface == surface else { return }
        cancelHoverExpansion()
        if presentationMode == .dynamic {
            isExpanded = expanded && hasEligibleSource
        } else {
            applyPresentationMode()
        }
    }

    /// The delay belongs to the production controller so cancellation and
    /// source/surface validation do not depend on SwiftUI delivering disappear.
    func setHovering(_ hovering: Bool, on surface: Surface) {
        guard activeSurface == surface else { return }
        cancelHoverExpansion()
        hoveredSurface = hovering ? surface : nil
        guard hovering, presentationMode == .dynamic, hasEligibleSource,
              !isExpanded, let item else { return }
        let source = SourceIdentity(item)
        let generation = hoverGeneration
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation,
                  self.hoveredSurface == surface, self.activeSurface == surface,
                  self.presentationMode == .dynamic, self.hasEligibleSource,
                  self.item.map(SourceIdentity.init) == source else { return }
            self.hoverEntryWorkItem = nil
            self.isExpanded = true
        }
        hoverEntryWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
    }

    private func cancelHoverExpansion(clearHover: Bool = false) {
        hoverGeneration += 1
        hoverEntryWorkItem?.cancel()
        hoverEntryWorkItem = nil
        if clearHover { hoveredSurface = nil }
    }

    func perform(_ action: SidebarMediaBridge.Action, for expectedItem: Item? = nil,
                 from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed,
              surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, targetId: item.targetId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let generation = selectionGeneration
        Task { [weak self] in
            _ = await SidebarMediaBridge.perform(
                action, targetId: item.targetId,
                source: item.playback.source, index: item.playback.index,
                metadataIdentity: item.playback.metadataIdentity,
                topDocumentTimeOrigin: item.playback.topDocumentTimeOrigin,
                mediaDocumentTimeOrigin: item.playback.mediaDocumentTimeOrigin)
            guard let self, self.selectionGeneration == generation else { return }
            self.pollSelected()
        }
    }

    func showTab(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, targetId: item.targetId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        tab.webContentWrapper?.setAsActiveTab()
    }

    func toggleMute(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, targetId: item.targetId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let newMuted = !tab.isAudioMuted
        tab.setAudioMuted(newMuted)
        self.item = Item(tabId: item.tabId, targetId: item.targetId,
                         pageURL: item.pageURL, documentEpoch: item.documentEpoch,
                         playback: item.playback, faviconData: item.faviconData,
                         isTabMuted: newMuted)
    }

    isolated deinit {
        hoverEntryWorkItem?.cancel()
        pollTimer?.invalidate()
        discoveryTimer?.invalidate()
        pollConnection?.close()
    }
}
