// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// One window's sidebar player. Native sessions are observed only while the
/// sidebar is active; the selected progress is refreshed from browser state.
@MainActor
final class SidebarMediaController: ObservableObject {
    enum Surface: Hashable { case docked, floating }
    struct Item: Equatable {
        let tabId: Int
        let wrapperId: ObjectIdentifier
        let pageURL: String?
        let documentEpoch: Int
        let playback: NativeMediaAdapter.Playback
        let faviconData: Data?
        let isTabMuted: Bool
    }

    @Published private(set) var item: Item?
    @Published private(set) var isRevalidating = false
    @Published private(set) var isSourceVisible = false
    @Published private(set) var isDismissed = false
    @Published private(set) var activeSurface: Surface?
    @Published private(set) var isExpanded = false
    @Published private(set) var isChangingTrack = false
    @Published private(set) var isVolumeExpanded = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var presentationMode: SidebarMediaPresentationMode
    @Published private(set) var backgroundSourceCount = 0
    enum CycleDirection { case next, previous }
    @Published private(set) var cycleDirection: CycleDirection = .next
    @Published private(set) var cycleAnimationGeneration = 0

    private struct SourceIdentity: Equatable {
        let tabId: Int
        let wrapperId: ObjectIdentifier
        let pageURL: String?
        let documentEpoch: Int
        let sourceToken: String

        init(_ item: Item) {
            tabId = item.tabId
            wrapperId = item.wrapperId
            pageURL = item.pageURL
            documentEpoch = item.documentEpoch
            sourceToken = item.playback.sourceToken
        }
    }

    private var dismissedSources: [Int: SourceIdentity] = [:]
    private var pipRetainedSources: [Int: SourceIdentity] = [:]
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
    private var pendingTrackChange: Item?
    private var trackChangeSawGap = false
    private var trackChangeTimeout: DispatchWorkItem?
    private var trackChangeSettle: DispatchWorkItem?
    private var trackChangeGeneration = 0
    private var trackChangeSettleGeneration = 0
    private var mediaSubscriptions: [Int: NativeMediaAdapter.Subscription] = [:]
    private var mediaWrapperIds: [Int: ObjectIdentifier] = [:]
    private var isSyncingTabs = false
    private var subscriptionGenerations: [Int: UUID] = [:]
    private var documentEpochs: [Int: Int] = [:]
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
            finishTrackChange()
            isVolumeExpanded = false
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
            if item != nil { startPolling() }
            probeFocusedTab()
        } else {
            // Hidden tabs can reload the same URL and wrapper without any of
            // this controller's subscriptions seeing it. Keep the selection
            // for later, but hide and block it until a fresh snapshot arrives.
            isRevalidating = item != nil
            backgroundSourceCount = 0
            candidates.removeAll()
            visitsAwaitingPlayback.removeAll()
            stateSubscriptions.removeAll()
            subscriptionGenerations.removeAll()
            mediaSubscriptions.values.forEach { $0.close() }
            mediaSubscriptions.removeAll()
            mediaWrapperIds.removeAll()
            observedTabs.removeAll()
            pollTimer?.invalidate()
            pollTimer = nil
            activationGeneration += 1
            // Retain the paused source while the sidebar is hidden. It is
            // revalidated by its native subscription when the sidebar returns.
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
        isSyncingTabs = true
        defer { isSyncingTabs = false; refreshSelection() }
        var newTabs: [Tab] = []
        let liveTabs = browserState.tabs.filter { $0.isOpenned }
        for (id, observed) in observedTabs where !liveTabs.contains(where: { $0 === observed.tab }) {
            subscriptionGenerations.removeValue(forKey: id)
            mediaSubscriptions.removeValue(forKey: id)?.close()
            mediaWrapperIds.removeValue(forKey: id)
        }
        let ids = Set(liveTabs.map(\.guid))
        observedTabs = observedTabs.filter { entry in
            liveTabs.contains { $0.guid == entry.key && $0 === entry.value.tab }
        }
        documentEpochs = documentEpochs.filter { ids.contains($0.key) }
        candidates = candidates.filter { ids.contains($0.key) }
        pipRetainedSources = pipRetainedSources.filter { ids.contains($0.key) }
        visitsAwaitingPlayback.formIntersection(ids)
        dismissedSources = dismissedSources.filter { ids.contains($0.key) }
        if let item, !liveTabs.contains(where: { $0.guid == item.tabId }) {
            clearSelection()
        }

        for tab in liveTabs where observedTabs[tab.guid] == nil {
            var subscriptions = Set<AnyCancellable>()
            tab.$webContentWrapper
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.observedTabs[tab.guid]?.tab === tab else { return }
                    self.candidates.removeValue(forKey: tab.guid)
                    if self.item?.tabId == tab.guid { self.clearSelection() }
                    self.subscribe(to: tab)
                }
                .store(in: &subscriptions)
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
                    self.inspect(tab)
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
                    } else {
                        self.inspect(tab)
                    }
                }
                .store(in: &subscriptions)
            observedTabs[tab.guid] = (tab, subscriptions)
            newTabs.append(tab)
        }
        // Register every tab before synchronous initial observer delivery.
        for tab in newTabs { subscribe(to: tab) }
        refreshSelection()
    }

    private func focusChanged(to tab: Tab?) {
        let oldId = previousFocusedTabId
        previousFocusedTabId = tab?.guid
        if oldId != tab?.guid {
            finishTrackChange()
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

    private func subscribe(to tab: Tab) {
        subscriptionGenerations.removeValue(forKey: tab.guid)
        mediaSubscriptions.removeValue(forKey: tab.guid)?.close()
        mediaWrapperIds.removeValue(forKey: tab.guid)
        guard isActive, let wrapper = tab.webContentWrapper else { return }
        let wrapperId = ObjectIdentifier(wrapper)
        mediaWrapperIds[tab.guid] = wrapperId
        let generation = UUID()
        let activation = activationGeneration
        subscriptionGenerations[tab.guid] = generation
        let publish: (NativeMediaAdapter.Playback?) -> Void = { [weak self, weak tab] playback in
            guard let self, let tab, self.isActive,
                  self.activationGeneration == activation,
                  self.subscriptionGenerations[tab.guid] == generation,
                  self.observedTabs[tab.guid]?.tab === tab,
                  tab.webContentWrapper.map(ObjectIdentifier.init) == wrapperId else { return }
            self.receive(playback, for: tab, wrapperId: wrapperId)
        }
        // Native start publishes synchronously. Register ownership before
        // forwarding that first value: a UI publisher may deactivate us during
        // delivery, and teardown must be able to close this subscription.
        var isStarting = true
        var initialState: NativeMediaAdapter.Playback?
        let subscription = NativeMediaAdapter.Subscription(wrapper: wrapper, fallbackTitle: tab.title) { playback in
            if isStarting { initialState = playback } else { publish(playback) }
        }
        mediaSubscriptions[tab.guid] = subscription
        isStarting = false
        publish(initialState)
        initialState = nil
    }

    private func inspect(_ tab: Tab) {
        guard isActive, tab.isOpenned, !tab.isLoading,
              observedTabs[tab.guid]?.tab === tab,
              let wrapper = tab.webContentWrapper,
              mediaWrapperIds[tab.guid] == ObjectIdentifier(wrapper) else { return }
        receive(mediaSubscriptions[tab.guid]?.snapshot(fallbackTitle: tab.title),
                for: tab, wrapperId: ObjectIdentifier(wrapper))
    }

    private func receive(_ playback: NativeMediaAdapter.Playback?, for tab: Tab,
                         wrapperId: ObjectIdentifier) {
        guard isValid(tab, wrapperId: wrapperId, pageURL: tab.url,
                      documentEpoch: documentEpochs[tab.guid, default: 0]) else { return }
        var preservePresentation = false
        if let pending = pendingTrackChange, pending.tabId == tab.guid {
            if !isValid(pending) {
                finishTrackChange()
            } else if let playback {
                if trackChangeSawGap || playback.sourceToken != pending.playback.sourceToken
                    || playback.isPictureInPicture {
                    preservePresentation = !playback.isPictureInPicture
                    if preservePresentation {
                        isChangingTrack = false
                        settleTrackChange()
                        manuallySelectedTabId = tab.guid
                    } else {
                        finishTrackChange()
                    }
                }
            } else {
                trackChangeSawGap = true
                isChangingTrack = true
                trackChangeSettleGeneration += 1
                trackChangeSettle?.cancel()
                trackChangeSettle = nil
                return
            }
        }
        if let playback {
            let confirmsPlayingVisit = visitsAwaitingPlayback.remove(tab.guid) != nil && playback.isPlaying
            remember(tab: tab, wrapperId: wrapperId, pageURL: tab.url,
                     documentEpoch: documentEpochs[tab.guid, default: 0], playback: playback)
            if confirmsPlayingVisit { manuallySelectedTabId = nil }
        } else {
            visitsAwaitingPlayback.remove(tab.guid)
            candidates.removeValue(forKey: tab.guid)
            if item?.tabId == tab.guid { clearSelection() }
        }
        refreshSelection(preservePresentation: preservePresentation)
    }

    private func remember(tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                          documentEpoch: Int, playback: NativeMediaAdapter.Playback) {
        let candidate = Item(tabId: tab.guid, wrapperId: wrapperId, pageURL: pageURL,
                             documentEpoch: documentEpoch, playback: playback,
                             faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                             isTabMuted: playback.isTabMuted)
        if let previous = candidates[tab.guid], SourceIdentity(previous) != SourceIdentity(candidate),
           cyclingTabId == tab.guid { cancelCycle() }
        let identity = SourceIdentity(candidate)
        if let retained = pipRetainedSources[tab.guid], retained != identity {
            pipRetainedSources.removeValue(forKey: tab.guid)
        }
        // PiP temporarily replaces the card; keep its selected paused source
        // eligible even if another playing tab occupies the card meanwhile.
        if playback.isPictureInPicture, item.map(SourceIdentity.init) == identity {
            pipRetainedSources[tab.guid] = identity
        }
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
        return isValid(tab, wrapperId: candidate.wrapperId, pageURL: candidate.pageURL,
                       documentEpoch: candidate.documentEpoch)
    }

    private var orderedBackgroundSources: [Item] {
        guard let state = browserState else { return [] }
        let history = state.tabSwitchManager.visitedTabIDs
        let order = history + state.tabs.map(\.guid).filter { !history.contains($0) }
        return order.compactMap { id in
            guard let candidate = candidates[id], isValid(candidate), !isVisible(id),
                  !candidate.playback.isPictureInPicture,
                  dismissedSources[id] != SourceIdentity(candidate),
                  candidate.playback.isPlaying || item?.tabId == id
                    || pipRetainedSources[id] == SourceIdentity(candidate) else { return nil }
            return candidate
        }
    }

    private func refreshSelection(preservePresentation: Bool = false) {
        guard !isSyncingTabs else { return }
        guard isActive else { backgroundSourceCount = 0; return }
        // Empty activation caches are not selection loss. Keep the retained
        // manual/paused identity concealed until its own fresh result arrives.
        if isRevalidating, let retained = item, isValid(retained), candidates[retained.tabId] == nil { return }
        let choices = orderedBackgroundSources
        backgroundSourceCount = choices.count
        if let pending = pendingTrackChange {
            if !preservePresentation, isValid(pending), !isVisible(pending.tabId), !isDismissed {
                return
            }
            if !preservePresentation { finishTrackChange() }
        }
        let chosen: Item?
        if let manual = manuallySelectedTabId, let candidate = choices.first(where: { $0.tabId == manual }) {
            chosen = candidate
        } else {
            manuallySelectedTabId = nil
            chosen = choices.first
        }
        if let chosen, let tab = observedTabs[chosen.tabId]?.tab {
            select(tab: tab, wrapperId: chosen.wrapperId, pageURL: chosen.pageURL,
                   documentEpoch: chosen.documentEpoch, playback: chosen.playback,
                   preservePresentation: preservePresentation)
        } else if let current = item, isValid(current),
                  let candidate = candidates[current.tabId], let tab = observedTabs[current.tabId]?.tab {
            select(tab: tab, wrapperId: candidate.wrapperId, pageURL: candidate.pageURL,
                   documentEpoch: candidate.documentEpoch, playback: candidate.playback)
        } else if item == nil, let focused = browserState?.focusingTab,
                  let candidate = candidates[focused.guid], isValid(candidate) {
            select(tab: focused, wrapperId: candidate.wrapperId, pageURL: candidate.pageURL,
                   documentEpoch: candidate.documentEpoch, playback: candidate.playback)
        }
    }

    /// Cycling changes only the presented source, never tab focus or playback.
    /// The destination's cached identity must survive a fresh page inspection.
    func cycleSource(for expectedItem: Item, direction: CycleDirection = .next, from surface: Surface) {
        guard hasEligibleSource, activeSurface == surface, matchesCurrentSource(expectedItem) else { return }
        let choices = orderedBackgroundSources
        guard choices.count > 1 else { return }
        finishTrackChange()
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
            guard let self else { return }
            let playback = self.mediaSubscriptions[destination.tabId]?.snapshot(fallbackTitle: tab?.title ?? "")
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
            let fresh = Item(tabId: destination.tabId, wrapperId: destination.wrapperId,
                             pageURL: destination.pageURL, documentEpoch: destination.documentEpoch,
                             playback: playback, faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                             isTabMuted: playback.isTabMuted)
            guard SourceIdentity(fresh) == identity, !playback.isPictureInPicture,
                  playback.isPlaying || !destination.playback.isPlaying else {
                self.cancelCycle()
                self.remember(tab: tab, wrapperId: destination.wrapperId, pageURL: destination.pageURL,
                              documentEpoch: destination.documentEpoch, playback: playback)
                self.refreshSelection()
                return
            }
            self.cyclingTabId = nil
            self.manuallySelectedTabId = destination.tabId
            self.remember(tab: tab, wrapperId: destination.wrapperId, pageURL: destination.pageURL,
                          documentEpoch: destination.documentEpoch, playback: playback)
            self.cycleDirection = direction
            self.cycleAnimationGeneration += 1
            self.select(tab: tab, wrapperId: destination.wrapperId, pageURL: destination.pageURL,
                        documentEpoch: destination.documentEpoch, playback: playback,
                        preservePresentation: true)
            self.refreshSelection()
        }
    }

    private func cancelCycle() {
        cycleGeneration += 1
        cyclingTabId = nil
    }

    private func select(tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                        documentEpoch: Int,
                        playback: NativeMediaAdapter.Playback, preservePresentation: Bool = false) {
        let previousSource = item.map(SourceIdentity.init)
        if item?.tabId != tab.guid || item?.wrapperId != wrapperId { isVolumeExpanded = false }
        item = Item(tabId: tab.guid, wrapperId: wrapperId, pageURL: pageURL,
                    documentEpoch: documentEpoch,
                    playback: playback,
                    faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                    isTabMuted: playback.isTabMuted)
        // Published delivery can synchronously deactivate the surface. Do not
        // resume presentation or a timer after that consumer has torn us down.
        guard isActive else { isRevalidating = item != nil; return }
        if let item {
            if !playback.isPictureInPicture { pipRetainedSources.removeValue(forKey: tab.guid) }
            // A new track or document starts a new presentation session.
            // Preserve dismissal only across updates of the same source.
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
        startPolling()
    }

    private func startPolling() {
        guard isActive, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSelected() }
        }
    }

    private func pollSelected() {
        guard isActive else { return }
        guard let item, let tab = observedTabs[item.tabId]?.tab, isValid(item) else {
            if item != nil { clearSelection() }
            return
        }
        // Snapshot computes progress locally from MediaPosition. No renderer
        // evaluation, CDP connection or polling of inactive tabs is involved.
        inspect(tab)
    }

    private func isValid(_ tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                         documentEpoch: Int) -> Bool {
        isActive && tab.isOpenned && !tab.isLoading && tab.url == pageURL
            && documentEpochs[tab.guid, default: 0] == documentEpoch
            && tab.webContentWrapper.map(ObjectIdentifier.init) == wrapperId
            && observedTabs[tab.guid]?.tab === tab
            && browserState?.tabs.contains(where: { $0 === tab }) == true
    }

    private func clearSelection() {
        finishTrackChange()
        isVolumeExpanded = false
        let lostTabId = item?.tabId
        if let lostTabId {
            candidates.removeValue(forKey: lostTabId)
            pipRetainedSources.removeValue(forKey: lostTabId)
            visitsAwaitingPlayback.remove(lostTabId)
        }
        manuallySelectedTabId = nil
        cancelCycle()
        cancelHoverExpansion(clearHover: true)
        item = nil
        isSourceVisible = false
        isDismissed = false
        isRevalidating = false
        isExpanded = false
        pollTimer?.invalidate()
        pollTimer = nil
        refreshSelection()
    }

    private func updateSourceVisibility() {
        guard let browserState, let item, let focused = browserState.focusingTab else {
            isSourceVisible = false
            return
        }
        // Media already visible in PiP or either split pane needs no duplicate card.
        isSourceVisible = item.playback.isPictureInPicture || focused.guid == item.tabId
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
            && item?.playback.token == displayedItem.playback.token
    }

    func dismissCurrent(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              let item, !isRevalidating,
              surface == nil || activeSurface == surface else { return }
        cancelHoverExpansion(clearHover: true)
        cancelCycle()
        finishTrackChange()
        isVolumeExpanded = false
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
        if !hovering && isVolumeExpanded { isVolumeExpanded = false }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }

    private func cancelHoverExpansion(clearHover: Bool = false) {
        hoverGeneration += 1
        hoverEntryWorkItem?.cancel()
        hoverEntryWorkItem = nil
        if clearHover { hoveredSurface = nil }
    }

    func perform(_ action: NativeMediaAdapter.Action, for expectedItem: Item? = nil,
                 from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, !isChangingTrack,
              surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let displayed = expectedItem ?? item
        let changesTrack: Bool
        switch action {
        case .previousTrack, .nextTrack: changesTrack = true
        default: changesTrack = false
        }
        if changesTrack { beginTrackChange(displayed) }
        let accepted = mediaSubscriptions[item.tabId]?.perform(action, expected: displayed.playback) == true
        if changesTrack && !accepted { finishTrackChange() }
        inspect(tab)
    }

    private func beginTrackChange(_ item: Item) {
        finishTrackChange()
        pendingTrackChange = item
        isChangingTrack = true
        let generation = trackChangeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.trackChangeGeneration == generation,
                  let pending = self.pendingTrackChange else { return }
            self.finishTrackChange()
            if let tab = self.observedTabs[pending.tabId]?.tab { self.inspect(tab) }
            self.refreshSelection()
        }
        trackChangeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func settleTrackChange() {
        trackChangeSettleGeneration += 1
        let settleGeneration = trackChangeSettleGeneration
        trackChangeSettle?.cancel()
        let generation = trackChangeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.trackChangeGeneration == generation,
                  self.trackChangeSettleGeneration == settleGeneration else { return }
            self.finishTrackChange()
        }
        trackChangeSettle = work
        // Metadata and player teardown arrive on separate native channels.
        // Keep one short continuity window after fresh state becomes usable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func finishTrackChange() {
        trackChangeGeneration += 1
        trackChangeSettleGeneration += 1
        trackChangeSettle?.cancel()
        trackChangeSettle = nil
        trackChangeTimeout?.cancel()
        trackChangeTimeout = nil
        pendingTrackChange = nil
        trackChangeSawGap = false
        isChangingTrack = false
    }

    func volumeButtonClicked(for expectedItem: Item, from surface: Surface, optionPressed: Bool) {
        guard hasEligibleSource, activeSurface == surface, matchesCurrentSource(expectedItem) else { return }
        if optionPressed {
            toggleMute(for: expectedItem, from: surface)
        } else {
            isVolumeExpanded.toggle()
        }
    }

    func setVolume(_ volume: Double, for expectedItem: Item, from surface: Surface) {
        guard hasEligibleSource, !isChangingTrack, activeSurface == surface,
              matchesCurrentSource(expectedItem), let tab = observedTabs[expectedItem.tabId]?.tab,
              isValid(expectedItem) else { return }
        mediaSubscriptions[expectedItem.tabId]?.setVolume(volume, expected: expectedItem.playback)
        inspect(tab)
    }

    func showTab(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        tab.webContentWrapper?.setAsActiveTab()
    }

    func toggleMute(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.tabId]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let newMuted = !tab.isAudioMuted
        tab.setAudioMuted(newMuted)
        self.item = Item(tabId: item.tabId, wrapperId: item.wrapperId,
                         pageURL: item.pageURL, documentEpoch: item.documentEpoch,
                         playback: item.playback, faviconData: item.faviconData,
                         isTabMuted: newMuted)
    }

    isolated deinit {
        trackChangeSettle?.cancel()
        trackChangeTimeout?.cancel()
        hoverEntryWorkItem?.cancel()
        pollTimer?.invalidate()
        mediaSubscriptions.values.forEach { $0.close() }
    }
}
