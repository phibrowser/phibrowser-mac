// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Combine
import Foundation

/// One physical window's player. Native observation spans its live Space sessions;
/// only the presented sidebar refreshes progress and accepts UI interactions.
@MainActor
final class SidebarMediaController: ObservableObject {
    struct Surface: Hashable {
        enum Kind: Hashable { case docked, floating }
        let sessionID: ObjectIdentifier?
        let kind: Kind

        init(session: BrowserState, kind: Kind) {
            sessionID = ObjectIdentifier(session)
            self.kind = kind
        }

        private init(kind: Kind) { sessionID = nil; self.kind = kind }
        // Unqualified surfaces are only for standalone, single-session hosts.
        static let docked = Surface(kind: .docked)
        static let floating = Surface(kind: .floating)
    }

    struct SourceKey: Hashable {
        let sessionID: ObjectIdentifier
        let tabID: Int
    }

    @MainActor
    private final class Session {
        weak var state: BrowserState?
        var tabOrder: [Int]
        init(_ state: BrowserState) {
            self.state = state
            let history = state.tabSwitchManager.visitedTabIDs
            tabOrder = history + state.tabs.map(\.guid).filter { !history.contains($0) }
        }
    }
    struct Item: Equatable {
        let key: SourceKey
        var tabId: Int { key.tabID }
        var sessionID: ObjectIdentifier { key.sessionID }
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
        let key: SourceKey
        let wrapperId: ObjectIdentifier
        let pageURL: String?
        let documentEpoch: Int
        let sourceToken: String

        init(_ item: Item) {
            key = item.key
            wrapperId = item.wrapperId
            pageURL = item.pageURL
            documentEpoch = item.documentEpoch
            sourceToken = item.playback.sourceToken
        }
    }

    private var dismissedSources: [SourceKey: SourceIdentity] = [:]
    private var pipRetainedSources: [SourceKey: SourceIdentity] = [:]
    private var candidates: [SourceKey: Item] = [:]
    private var manuallySelectedSourceKey: SourceKey?
    private var previousFocusedSourceKey: SourceKey?
    private var visitsAwaitingPlayback = Set<SourceKey>()
    private var cyclingSourceKey: SourceKey?
    private var cycleGeneration = 0
    private var hoveredSurface: Surface?
    private var hoverEntryWorkItem: DispatchWorkItem?
    private var hoverGeneration = 0

    private weak var browserState: BrowserState?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var sessionOrder: [ObjectIdentifier] = []
    private var visitedSources: [SourceKey] = []
    private var navigationGeneration = 0
    /// The slot invokes completion only once its target session is presented.
    var activateSession: ((ObjectIdentifier, @escaping (Bool) -> Void) -> Void)?

    private var liveStates: [BrowserState] {
        sessionOrder.compactMap { sessions[$0]?.state }
    }

    private func sourceKey(for tab: Tab) -> SourceKey? {
        guard let state = liveStates.first(where: { $0.tabs.contains { $0 === tab } }) else { return nil }
        return SourceKey(sessionID: ObjectIdentifier(state), tabID: tab.guid)
    }

    private func accepts(_ surface: Surface) -> Bool {
        guard let browserState else { return false }
        return surface.sessionID == ObjectIdentifier(browserState)
            || (surface.sessionID == nil && sessions.count == 1)
    }

    func setSessions(_ states: [BrowserState], presented: BrowserState?) {
        let ids = states.map(ObjectIdentifier.init)
        let membershipChanged = Set(ids) != Set(sessions.keys)
        let presentationChanged = browserState !== presented
        let oldPresentedID = browserState.map(ObjectIdentifier.init)
        sessions = Dictionary(uniqueKeysWithValues: states.map { state in
            let id = ObjectIdentifier(state)
            return (id, sessions[id] ?? Session(state))
        })
        sessionOrder = ids
        browserState = presented.flatMap { state in states.contains(where: { $0 === state }) ? state : nil }
        if presentationChanged {
            // The expected return switch may complete; unrelated later switches cancel it.
            if let target = navigationTarget, browserState.map(ObjectIdentifier.init) != target {
                navigationGeneration += 1
                navigationTarget = nil
            }
            if let oldPresentedID {
                activeSurfaces = activeSurfaces.filter { $0.sessionID != oldPresentedID && $0.sessionID != nil }
            }
            if manuallySelectedSourceKey == nil { manuallySelectedSourceKey = item?.key }
            previousFocusedSourceKey = browserState?.focusingTab.flatMap { sourceKey(for: $0) }
            finishTrackChange()
            cancelCycle()
            cancelHoverExpansion(clearHover: true)
            isVolumeExpanded = false
        }
        if membershipChanged && isActive { bindState() }
        updateActivation()
        if isActive { syncTabs() }
        if states.isEmpty { clearSelection() }
    }

    private var navigationTarget: ObjectIdentifier?
    private let defaults: UserDefaults
    private var preferencesSubscription: AnyCancellable?
    private var isActive = false
    private var activeSurfaces = Set<Surface>()
    private var observedTabs: [SourceKey: (tab: Tab, subscriptions: Set<AnyCancellable>)] = [:]
    private var stateSubscriptions = Set<AnyCancellable>()
    private var pollTimer: Timer?
    private var pendingTrackChange: Item?
    private var trackChangeSawGap = false
    private var trackChangeTimeout: DispatchWorkItem?
    private var trackChangeSettle: DispatchWorkItem?
    private var trackChangeGeneration = 0
    private var trackChangeSettleGeneration = 0
    private var mediaSubscriptions: [SourceKey: NativeMediaAdapter.Subscription] = [:]
    private var mediaWrapperIds: [SourceKey: ObjectIdentifier] = [:]
    private var isSyncingTabs = false
    private var subscriptionGenerations: [SourceKey: UUID] = [:]
    private var documentEpochs: [SourceKey: Int] = [:]
    private var activationGeneration = 0

    init(browserState: BrowserState? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = PhiPreferences.GeneralSettings.sidebarMediaPlayerEnabled.loadValue(from: defaults)
        presentationMode = PhiPreferences.GeneralSettings.loadSidebarMediaPresentationMode(from: defaults)
        preferencesSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPreferences() }
        if let browserState { setSessions([browserState], presented: browserState) }
    }

    func setActive(_ active: Bool, on surface: Surface = .docked) {
        if active {
            guard accepts(surface) else { return }
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
        let eligible = activeSurfaces.filter { accepts($0) }
        let presented: Surface? = !isEnabled ? nil
            : eligible.first(where: { $0.kind == .floating })
                ?? eligible.first(where: { $0.kind == .docked })
        if activeSurface != presented {
            finishTrackChange()
            isVolumeExpanded = false
            cancelHoverExpansion(clearHover: true)
            cancelCycle()
            activeSurface = presented
            applyPresentationMode(resetDynamic: true)
        }
        if presented == nil { pollTimer?.invalidate(); pollTimer = nil }
        let observing = isEnabled && !sessions.isEmpty
        guard observing != isActive else {
            if presented != nil && item != nil { startPolling() }
            return
        }
        isActive = observing
        if observing {
            bindState()
            syncTabs()
            if item != nil { startPolling() }
            probeFocusedTab()
        } else {
            // While disabled, tabs can reload the same URL and wrapper without any of
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
        stateSubscriptions.removeAll()
        for browserState in liveStates {
        browserState.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncTabs() }
            .store(in: &stateSubscriptions)
        browserState.$focusingTab
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self, weak browserState] tab in
                guard let self, let browserState, self.browserState === browserState,
                      browserState.focusingTab === tab else { return }
                self.focusChanged(to: tab)
            }
            .store(in: &stateSubscriptions)
        browserState.$splits
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSelection() }
            .store(in: &stateSubscriptions)
        }
    }

    private func syncTabs() {
        guard isActive else { return }
        isSyncingTabs = true
        defer { isSyncingTabs = false; refreshSelection() }
        var newTabs: [Tab] = []
        let liveTabs = liveStates.flatMap(\.tabs).filter { $0.isOpenned }
        for state in liveStates {
            guard let session = sessions[ObjectIdentifier(state)] else { continue }
            let ids = state.tabs.filter(\.isOpenned).map(\.guid)
            session.tabOrder = session.tabOrder.filter { ids.contains($0) }
            session.tabOrder += ids.filter { !session.tabOrder.contains($0) }
        }
        for (id, observed) in observedTabs where !liveTabs.contains(where: { $0 === observed.tab && sourceKey(for: $0) == id }) {
            subscriptionGenerations.removeValue(forKey: id)
            mediaSubscriptions.removeValue(forKey: id)?.close()
            mediaWrapperIds.removeValue(forKey: id)
        }
        let ids = Set(liveTabs.compactMap { sourceKey(for: $0) })
        observedTabs = observedTabs.filter { entry in
            liveTabs.contains { sourceKey(for: $0) == entry.key && $0 === entry.value.tab }
        }
        documentEpochs = documentEpochs.filter { ids.contains($0.key) }
        candidates = candidates.filter { ids.contains($0.key) }
        pipRetainedSources = pipRetainedSources.filter { ids.contains($0.key) }
        visitsAwaitingPlayback.formIntersection(ids)
        visitedSources.removeAll { !ids.contains($0) }
        dismissedSources = dismissedSources.filter { ids.contains($0.key) }
        if let item, !liveTabs.contains(where: { sourceKey(for: $0) == item.key }) {
            clearSelection()
        }

        for tab in liveTabs {
            guard let key = sourceKey(for: tab), observedTabs[key] == nil else { continue }
            var subscriptions = Set<AnyCancellable>()
            tab.$webContentWrapper
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.sourceKey(for: tab) == key, self.observedTabs[key]?.tab === tab else { return }
                    self.candidates.removeValue(forKey: key)
                    if self.item?.key == key { self.clearSelection() }
                    self.subscribe(to: tab)
                }
                .store(in: &subscriptions)
            tab.$isCurrentlyAudible
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] audible in
                    guard let self, let tab, self.sourceKey(for: tab) == key else { return }
                    // A known source may pause/end or become silent. Inspect
                    // that transition rather than trusting its last snapshot.
                    if audible || self.candidates[key] != nil || self.item?.key == key {
                        self.inspect(tab)
                    }
                }
                .store(in: &subscriptions)
            tab.$url
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] _ in
                    guard let self, let tab, self.sourceKey(for: tab) == key else { return }
                    self.candidates.removeValue(forKey: key)
                    self.visitsAwaitingPlayback.remove(key)
                    if self.cyclingSourceKey == key { self.cancelCycle() }
                    if self.item?.key == key { self.clearSelection() }
                    self.inspect(tab)
                    self.refreshSelection()
                }
                .store(in: &subscriptions)
            tab.$isLoading
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak tab] loading in
                    guard let self, let tab, self.sourceKey(for: tab) == key else { return }
                    if loading {
                        self.documentEpochs[key, default: 0] += 1
                        self.candidates.removeValue(forKey: key)
                        self.visitsAwaitingPlayback.remove(key)
                        if self.cyclingSourceKey == key { self.cancelCycle() }
                        if self.item?.key == key { self.clearSelection() }
                        self.refreshSelection()
                    } else {
                        self.inspect(tab)
                    }
                }
                .store(in: &subscriptions)
            observedTabs[key] = (tab, subscriptions)
            newTabs.append(tab)
        }
        // Register every tab before synchronous initial observer delivery.
        for tab in newTabs { subscribe(to: tab) }
        refreshSelection()
    }

    private func focusChanged(to tab: Tab?) {
        let oldId = previousFocusedSourceKey
        if let tab, let key = sourceKey(for: tab) {
            visitedSources.removeAll { $0 == key }
            visitedSources.insert(key, at: 0)
        }
        let newId = tab.flatMap { sourceKey(for: $0) }
        previousFocusedSourceKey = newId
        if oldId != newId {
            // A user's newer tab choice wins over an unsettled return animation.
            if navigationTarget != nil {
                navigationGeneration += 1
                navigationTarget = nil
            }
            finishTrackChange()
            visitsAwaitingPlayback.formUnion([oldId, newId].compactMap { $0 }.filter {
                candidates[$0]?.playback.isPlaying != true && observedTabs[$0]?.tab.isCurrentlyAudible != true
            })
            cancelCycle()
            // Unrelated visits preserve an explicit card choice. Visiting or
            // leaving a playing media source restores the browser's MRU policy.
            if [oldId, newId].compactMap({ $0 }).contains(where: {
                candidates[$0]?.playback.isPlaying == true || observedTabs[$0]?.tab.isCurrentlyAudible == true
            }) { manuallySelectedSourceKey = nil }
            if let oldId, let previous = observedTabs[oldId]?.tab { inspect(previous) }
        }
        refreshSelection()
        probeFocusedTab()
    }

    private func probeFocusedTab() {
        guard isActive, let tab = browserState?.focusingTab else { return }
        if item?.key == sourceKey(for: tab) { return }
        inspect(tab)
    }

    private func subscribe(to tab: Tab) {
        guard let key = sourceKey(for: tab) else { return }
        subscriptionGenerations.removeValue(forKey: key)
        mediaSubscriptions.removeValue(forKey: key)?.close()
        mediaWrapperIds.removeValue(forKey: key)
        guard isActive, let wrapper = tab.webContentWrapper else { return }
        let wrapperId = ObjectIdentifier(wrapper)
        mediaWrapperIds[key] = wrapperId
        let generation = UUID()
        let activation = activationGeneration
        subscriptionGenerations[key] = generation
        let publish: (NativeMediaAdapter.Playback?) -> Void = { [weak self, weak tab] playback in
            guard let self, let tab, self.isActive,
                  self.activationGeneration == activation,
                  self.subscriptionGenerations[key] == generation,
                  self.sourceKey(for: tab) == key, self.observedTabs[key]?.tab === tab,
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
        mediaSubscriptions[key] = subscription
        isStarting = false
        publish(initialState)
        initialState = nil
    }

    private func inspect(_ tab: Tab) {
        guard let key = sourceKey(for: tab) else { return }
        guard isActive, tab.isOpenned, !tab.isLoading,
              observedTabs[key]?.tab === tab,
              let wrapper = tab.webContentWrapper,
              mediaWrapperIds[key] == ObjectIdentifier(wrapper) else { return }
        receive(mediaSubscriptions[key]?.snapshot(fallbackTitle: tab.title),
                for: tab, wrapperId: ObjectIdentifier(wrapper))
    }

    private func receive(_ playback: NativeMediaAdapter.Playback?, for tab: Tab,
                         wrapperId: ObjectIdentifier) {
        guard let key = sourceKey(for: tab) else { return }
        guard isValid(tab, wrapperId: wrapperId, pageURL: tab.url,
                      documentEpoch: documentEpochs[key, default: 0]) else { return }
        var preservePresentation = false
        if let pending = pendingTrackChange, pending.key == key {
            if !isValid(pending) {
                finishTrackChange()
            } else if let playback {
                if trackChangeSawGap || playback.sourceToken != pending.playback.sourceToken
                    || playback.isPictureInPicture {
                    preservePresentation = !playback.isPictureInPicture
                    if preservePresentation {
                        isChangingTrack = false
                        settleTrackChange()
                        manuallySelectedSourceKey = key
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
            let confirmsPlayingVisit = visitsAwaitingPlayback.remove(key) != nil && playback.isPlaying
            remember(tab: tab, wrapperId: wrapperId, pageURL: tab.url,
                     documentEpoch: documentEpochs[key, default: 0], playback: playback)
            if confirmsPlayingVisit { manuallySelectedSourceKey = nil }
        } else {
            visitsAwaitingPlayback.remove(key)
            candidates.removeValue(forKey: key)
            if item?.key == key { clearSelection() }
        }
        refreshSelection(preservePresentation: preservePresentation)
    }

    private func remember(tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                          documentEpoch: Int, playback: NativeMediaAdapter.Playback) {
        guard let key = sourceKey(for: tab) else { return }
        let candidate = Item(key: key, wrapperId: wrapperId, pageURL: pageURL,
                             documentEpoch: documentEpoch, playback: playback,
                             faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                             isTabMuted: playback.isTabMuted)
        if let previous = candidates[key], SourceIdentity(previous) != SourceIdentity(candidate),
           cyclingSourceKey == key { cancelCycle() }
        let identity = SourceIdentity(candidate)
        if let retained = pipRetainedSources[key], retained != identity {
            pipRetainedSources.removeValue(forKey: key)
        }
        // PiP temporarily replaces the card; keep its selected paused source
        // eligible even if another playing tab occupies the card meanwhile.
        if playback.isPictureInPicture, item.map(SourceIdentity.init) == identity {
            pipRetainedSources[key] = identity
        }
        candidates[key] = candidate
        if let dismissed = dismissedSources[key], dismissed != SourceIdentity(candidate) {
            dismissedSources.removeValue(forKey: key)
        }
    }

    private func isVisible(_ key: SourceKey) -> Bool {
        guard let state = browserState, ObjectIdentifier(state) == key.sessionID,
              let focused = state.focusingTab else { return false }
        return focused.guid == key.tabID
            || state.splitGroup(forTabId: key.tabID)?.contains(tabId: focused.guid) == true
    }

    private func isValid(_ candidate: Item) -> Bool {
        guard let tab = observedTabs[candidate.key]?.tab else { return false }
        return isValid(tab, wrapperId: candidate.wrapperId, pageURL: candidate.pageURL,
                       documentEpoch: candidate.documentEpoch)
    }

    private var orderedBackgroundSources: [Item] {
        let fallback = liveStates.flatMap { state -> [SourceKey] in
            let ids = sessions[ObjectIdentifier(state)]?.tabOrder ?? []
            return ids.map { SourceKey(sessionID: ObjectIdentifier(state), tabID: $0) }
        }
        let order = visitedSources + fallback.filter { !visitedSources.contains($0) }
        return order.compactMap { id in
            guard let candidate = candidates[id], isValid(candidate), !isVisible(id),
                  !candidate.playback.isPictureInPicture,
                  dismissedSources[id] != SourceIdentity(candidate),
                  candidate.playback.isPlaying || item?.key == id
                    || pipRetainedSources[id] == SourceIdentity(candidate) else { return nil }
            return candidate
        }
    }

    private func refreshSelection(preservePresentation: Bool = false) {
        guard !isSyncingTabs else { return }
        guard isActive else { backgroundSourceCount = 0; return }
        // Empty activation caches are not selection loss. Keep the retained
        // manual/paused identity concealed until its own fresh result arrives.
        if isRevalidating, let retained = item, isValid(retained), candidates[retained.key] == nil { return }
        let choices = orderedBackgroundSources
        backgroundSourceCount = choices.count
        if let pending = pendingTrackChange {
            if !preservePresentation, isValid(pending), !isVisible(pending.key), !isDismissed {
                return
            }
            if !preservePresentation { finishTrackChange() }
        }
        let chosen: Item?
        if let manual = manuallySelectedSourceKey, let candidate = choices.first(where: { $0.key == manual }) {
            chosen = candidate
        } else {
            manuallySelectedSourceKey = nil
            chosen = choices.first
        }
        if let chosen, let tab = observedTabs[chosen.key]?.tab {
            select(tab: tab, wrapperId: chosen.wrapperId, pageURL: chosen.pageURL,
                   documentEpoch: chosen.documentEpoch, playback: chosen.playback,
                   preservePresentation: preservePresentation)
        } else if let current = item, isValid(current),
                  let candidate = candidates[current.key], let tab = observedTabs[current.key]?.tab {
            select(tab: tab, wrapperId: candidate.wrapperId, pageURL: candidate.pageURL,
                   documentEpoch: candidate.documentEpoch, playback: candidate.playback)
        } else if item == nil, let focused = browserState?.focusingTab,
                  let key = sourceKey(for: focused), let candidate = candidates[key], isValid(candidate) {
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
        let anchor = cyclingSourceKey ?? expectedItem.key
        let index = choices.firstIndex(where: { $0.key == anchor }) ?? 0
        let offset = direction == .next ? 1 : choices.count - 1
        let destination = choices[(index + offset) % choices.count]
        guard let tab = observedTabs[destination.key]?.tab else { return }
        cancelCycle()
        cyclingSourceKey = destination.key
        let generation = cycleGeneration
        let identity = SourceIdentity(destination)
        Task { [weak self, weak tab] in
            guard let self else { return }
            let playback = self.mediaSubscriptions[destination.key]?.snapshot(fallbackTitle: tab?.title ?? "")
            defer {
                if self.cycleGeneration == generation { self.cyclingSourceKey = nil }
            }
            guard self.cycleGeneration == generation,
                  self.cyclingSourceKey == destination.key,
                  self.activeSurface == surface, self.matchesCurrentSource(expectedItem),
                  let tab, self.isValid(destination), !self.isVisible(destination.key),
                  self.candidates[destination.key].map(SourceIdentity.init) == identity else { return }
            guard let playback else {
                self.cancelCycle()
                self.candidates.removeValue(forKey: destination.key)
                if self.item?.key == destination.key { self.clearSelection() }
                self.refreshSelection()
                return
            }
            let fresh = Item(key: destination.key, wrapperId: destination.wrapperId,
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
            self.cyclingSourceKey = nil
            self.manuallySelectedSourceKey = destination.key
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
        cyclingSourceKey = nil
    }

    private func select(tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                        documentEpoch: Int,
                        playback: NativeMediaAdapter.Playback, preservePresentation: Bool = false) {
        guard let key = sourceKey(for: tab) else { return }
        let previousSource = item.map(SourceIdentity.init)
        if item?.key != key || item?.wrapperId != wrapperId { isVolumeExpanded = false }
        item = Item(key: key, wrapperId: wrapperId, pageURL: pageURL,
                    documentEpoch: documentEpoch,
                    playback: playback,
                    faviconData: tab.liveFaviconData ?? tab.cachedFaviconData,
                    isTabMuted: playback.isTabMuted)
        // Published delivery can synchronously deactivate the surface. Do not
        // resume presentation or a timer after that consumer has torn us down.
        guard isActive else {
            if sessions.isEmpty { item = nil }
            isRevalidating = item != nil
            return
        }
        if let item {
            if !playback.isPictureInPicture { pipRetainedSources.removeValue(forKey: key) }
            // A new track or document starts a new presentation session.
            // Preserve dismissal only across updates of the same source.
            isDismissed = dismissedSources[item.key] == SourceIdentity(item)
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
        guard isActive, activeSurface != nil, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollSelected() }
        }
    }

    private func pollSelected() {
        guard isActive else { return }
        guard let item, let tab = observedTabs[item.key]?.tab, isValid(item) else {
            if item != nil { clearSelection() }
            return
        }
        // Snapshot computes progress locally from MediaPosition. No renderer
        // evaluation, CDP connection or polling of inactive tabs is involved.
        inspect(tab)
    }

    private func isValid(_ tab: Tab, wrapperId: ObjectIdentifier, pageURL: String?,
                         documentEpoch: Int) -> Bool {
        guard let key = sourceKey(for: tab) else { return false }
        return isActive && tab.isOpenned && !tab.isLoading && tab.url == pageURL
            && documentEpochs[key, default: 0] == documentEpoch
            && tab.webContentWrapper.map(ObjectIdentifier.init) == wrapperId
            && observedTabs[key]?.tab === tab

    }

    private func clearSelection() {
        finishTrackChange()
        isVolumeExpanded = false
        let lostSourceKey = item?.key
        if let lostSourceKey {
            candidates.removeValue(forKey: lostSourceKey)
            pipRetainedSources.removeValue(forKey: lostSourceKey)
            visitsAwaitingPlayback.remove(lostSourceKey)
        }
        manuallySelectedSourceKey = nil
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
        guard let item else { isSourceVisible = false; return }
        // Only the presented session's page and split panes are visible.
        isSourceVisible = item.playback.isPictureInPicture || isVisible(item.key)
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
        dismissedSources[item.key] = SourceIdentity(item)
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
              let item, let tab = observedTabs[item.key]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let displayed = expectedItem ?? item
        let changesTrack: Bool
        switch action {
        case .previousTrack, .nextTrack: changesTrack = true
        default: changesTrack = false
        }
        if changesTrack { beginTrackChange(displayed) }
        let accepted = mediaSubscriptions[item.key]?.perform(action, expected: displayed.playback) == true
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
            if let tab = self.observedTabs[pending.key]?.tab { self.inspect(tab) }
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
              matchesCurrentSource(expectedItem), let tab = observedTabs[expectedItem.key]?.tab,
              isValid(expectedItem) else { return }
        mediaSubscriptions[expectedItem.key]?.setVolume(volume, expected: expectedItem.playback)
        inspect(tab)
    }

    func showTab(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.key]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        navigationGeneration += 1
        let generation = navigationGeneration
        let identity = SourceIdentity(item)
        navigationTarget = item.sessionID
        let complete: (Bool) -> Void = { [weak self, weak tab] success in
            guard let self, self.navigationGeneration == generation,
                  self.navigationTarget == item.sessionID else { return }
            self.navigationTarget = nil
            guard success, let tab, self.isValid(item),
                  self.candidates[item.key].map(SourceIdentity.init) == identity,
                  self.browserState.map(ObjectIdentifier.init) == item.sessionID else { return }
            tab.webContentWrapper?.setAsActiveTab()
        }
        if browserState.map(ObjectIdentifier.init) == item.sessionID {
            complete(true)
        } else if let activateSession {
            activateSession(item.sessionID, complete)
        } else { complete(false) }
    }

    func toggleMute(for expectedItem: Item? = nil, from surface: Surface? = nil) {
        guard expectedItem.map(matchesCurrentSource) ?? true,
              !isRevalidating, !isDismissed, surface == nil || activeSurface == surface,
              let item, let tab = observedTabs[item.key]?.tab,
              isValid(tab, wrapperId: item.wrapperId, pageURL: item.pageURL,
                      documentEpoch: item.documentEpoch) else { return }
        let newMuted = !tab.isAudioMuted
        tab.setAudioMuted(newMuted)
        self.item = Item(key: item.key, wrapperId: item.wrapperId,
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
