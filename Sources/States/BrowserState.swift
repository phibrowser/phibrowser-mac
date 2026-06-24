// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Combine
/// Window-scoped browser state for tabs, layout, and sidebar UI.
class BrowserState {
    /// Tabs mirrored from Chromium, including their order.
    @Published var tabs: [Tab] = []
    /// Non-pinned tabs shown in the sidebar list.
    @Published var normalTabs: [Tab] = []
    /// Pinned tabs managed on the native side.
    @Published var pinnedTabs: [Tab] = []

    /// Tab groups in this window, keyed by hex token. Mirrors Chromium's
    /// `TabGroupModel`; updated by the `handleTabGroup*` family.
    @Published var groups: [String: WebContentGroupInfo] = [:]

    /// Window-scoped presentation state; membership remains owned by `Tab.groupToken`.
    @Published var groupOverviewState: GroupOverviewState?

    /// Tab → token claims received from Chromium before the matching `Tab`
    /// arrived in `handleNewTabFromChromium`. The new-tab handler drains
    /// this map so the late-arriving Tab inherits its group membership.
    /// Without this, kJoined-before-NewTab races silently drop the membership
    /// permanently because `tab.groupToken` is the only source of truth.
    private var pendingGroupClaims: [Int: String] = [:]

    /// Native ordering for non-pinned tabs, stored as Chromium guids.
    private var normalTabOrder: [Int] = []

    /// Tabs that were placed by native order before Chromium's initial
    /// tab-index echo caught up. Protected tabs keep their native slot for
    /// one Chromium order echo, then return to normal Chromium resequencing.
    private var nativeOrderProtectedTabIds: Set<Int> = []
    
    /// Pending requests to mark the next created tab as a native NTP (incognito only).
    private var pendingNativeNtpCount: Int = 0

    private struct PendingNormalTabInsertion {
        let url: String?
        let guid: Int?
        let expectedGroupToken: String?
        let index: Int
        let syncChromiumOrder: Bool

        func matches(tab: Tab) -> Bool {
            if let expectedGroupToken {
                return tab.groupToken == expectedGroupToken
            }
            if let guid { return tab.guid == guid }
            guard let url else { return false }
            return url.isEmpty || tab.url == url
        }
    }
    /// Pending insertion state for tabs created by drag/drop into the normal-tab section.
    private var pendingNormalTabInsertion: PendingNormalTabInsertion?

    /// Pending insertion state for a CROSS-WINDOW group arrival. Set by
    /// the source's `moveGroupSliceToWindow` on this (target) state
    /// right before it fires Chromium's atomic detach + insert. Each
    /// of the N member tabs arrives via `handleNewTabFromChromium` —
    /// the early branch there matches the incoming tab's guid against
    /// `memberGuids` and inserts it at `atIndex + arrivedCount` so the
    /// final positions are `[atIndex, atIndex+N)`.
    ///
    /// Robust against out-of-order arrival because we always insert at
    /// "arrivedCount past atIndex" — earlier arrivals occupy the
    /// earlier slots, later arrivals slot in after them. (Chromium's
    /// `InsertDetachedTabGroupAt` should fire kInserted events in
    /// group-order, but this is defensive.)
    ///
    /// Cleared on completion (all N arrived) or timeout
    /// (`pendingGroupInsertionTimeoutSeconds` from request) or explicit
    /// cancel.
    private struct PendingGroupInsertion {
        let memberGuids: Set<Int>
        let atIndex: Int
        var arrivedCount: Int
        let requestedAt: Date
    }
    private var pendingGroupInsertion: PendingGroupInsertion?
    private static let pendingGroupInsertionTimeoutSeconds: TimeInterval = 4.0

    /// customGuid → split-partner request. When a tab created via
    /// `openNewTabAsSplit` arrives from Chromium, it is paired with the
    /// stored partner into a vertical split; the slot field decides which
    /// side the *new* tab takes (the partner takes the other slot).
    var pendingSplitPartnerByCustomGuid: [String: PendingSplitPartner] = [:]

    /// customGuid → target URLs. The tab is initially opened as NTP (to keep
    /// `CrossDomainNewTabNavigationThrottle` from intercepting the initial
    /// load while the customGuid marker is set); once Chromium echoes the
    /// tab back, the marker is cleared and the tab is navigated to the
    /// stored primary URL. Used by the bookmark "Open as Split" menu, where
    /// the arriving tab becomes the primary pane (inverse of
    /// `pendingSplitPartnerByCustomGuid`). `secondaryURL` is set only for
    /// split-view bookmarks; the partner NTP is navigated to it instead of
    /// being left blank.
    var pendingPrimarySplitTargetByGuid: [String: PendingPrimarySplit] = [:]

    /// customGuid → pending split-pane replacement. When a tab opened via
    /// `openTabAsPaneReplacement` (bookmark / closed-pinned dragged onto a
    /// split pane) arrives from Chromium, it is swapped into the recorded
    /// split slot and the evicted pane becomes a standalone tab. Mirrors
    /// `pendingSplitPartnerByCustomGuid` for the replace-a-pane flow.
    var pendingSplitSlotSwapByCustomGuid: [String: PendingSplitSlotSwap] = [:]

    /// splitId → tab id the caller wanted in the primary (left/top) slot.
    /// Chromium always reports the lower-tab-strip-indexed tab as primary, so
    /// when the caller had a specific orientation in mind we reverse the split
    /// in `handleSplitCreated` if Chromium picked the other one.
    var pendingSplitPrimaryByCreateId: [String: Int] = [:]

    /// splitIds whose pinned flag must be forced on the very next
    /// `handleSplitCreated`. The caller (e.g. drop-into-pinned-strip) pins
    /// the panes synchronously and registers the createId here so the
    /// pinned-inference in `handleSplitCreated` doesn't race the async
    /// `pinnedTabs` publisher feeding `isSplitMembersAllPinned`.
    var pendingPinnedSplitMarkByCreateId: Set<String> = []

    /// splitId → destination index (in `normalTabs` space) the caller wants
    /// the freshly-created split relocated to once it exists. Set by the
    /// closed-split drop paths (`openSplitBookmarkAsTabs`,
    /// `unpinClosedPinnedSplit`), whose two panes are materialized
    /// asynchronously and therefore land at the end of the strip. Consumed in
    /// `handleSplitCreated`, which then relocates the pair to the drop index.
    var pendingSplitMoveToNormalIndexByCreateId: [String: Int] = [:]

    private var nativeRelationGraph: NativeTabRelationGraph = .empty
    private var pendingSelectionOverride: NativePendingSelectionOverride?

    private var lastLegacyLayout: Bool?
    @Published var layoutMode: LayoutMode = .performance
    @Published var lastPhiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.loadValue()
    private var lastSentinelOnLogin: Bool = PhiPreferences.AISettings.launchSentinelOnLogin.loadValue()
    
    /// Currently focused tab.
    @Published var focusingTab: Tab? {
        didSet {
            // Activating a different tab (new tab, switch, etc.) exits the
            // temporary multi-selection. Building a selection via Cmd+click
            // never reassigns this, so it won't interfere.
            if oldValue?.guid != focusingTab?.guid {
                clearMultiSelection()
            }
        }
    }

    /// Temporary multi-selection. Empty == normal single-selection mode.
    @Published private(set) var multiSelection: TabMultiSelection = .empty

    /// Visible bookmark items in the sidebar bookmark section.
    /// This list is maintained by `SidebarTabListViewController` and is ordered by the current
    /// visual order in the sidebar (top-to-bottom).
    ///
    /// Note: This contains *all visible bookmark items* (opened or not). Switching to an unopened
    /// bookmark will open a new tab via `openBookmark(_:)`.
    @Published var visibleBookmarkTabs: [Bookmark] = []
    
    /// AI Chat tabs keyed by the associated tab identifier.
    @Published var aiChatTabs: [String: Tab] = [:]

    /// Identifiers whose AI Chat tab creation has been dispatched to Chromium
    /// but hasn't been mirrored back via `handleNewTabFromChromium` yet. Used
    /// to dedupe parallel `createAIChatTab(for:chromeTabId:)` requests from
    /// multiple chat view controllers (e.g. sidebar + traditional layout)
    /// before `aiChatTabs` is populated.
    private var aiChatTabsBeingCreated: Set<String> = []
    
    @Published var sidebarCollapsed = false
    @Published var sidebarWidth: CGFloat = 0
    @Published var aiChatCollapsed = true
    @Published var isInFullScreenMode = false
    @Published var targetURL: String = ""

    /// True while this window is showing the chrome://dino placeholder.
    /// Drives every UI binding that hides sub-elements during placeholder mode.
    @Published private(set) var isInPlaceholderMode: Bool = false

    /// Wrapper around the Chromium-owned placeholder WebContents while in
    /// placeholder mode. Retained for the duration of placeholder mode;
    /// released on exit. Lifetime of the underlying NSView is owned by
    /// Chromium — wrapper.nativeView is invalid after exitPlaceholderMode
    /// returns.
    private(set) var placeholderWrapper: (WebContentWrapper & NSObject)? = nil

    @Published var isDraggingTab = false

    /// Side-by-side tab splits, mirrored from Chromium (source of truth).
    @Published var splits: [SplitGroup] = []

    /// Pinned-tab DB guids that the user just asked to reopen as a split via
    /// `openPinnedSplit`. Auto-recreation only fires for guids in this set so
    /// that session-restored splits (which Chromium emits its own
    /// `splitCreated` for) don't race against a Mac-side `createSplit` call.
    /// Consumed pairwise once both halves have bound to a live Chromium tab.
    var pendingPinnedSplitRecreateGuids: Set<String> = []

    /// DB guids whose `createSplit` is currently in flight on the next
    /// runloop tick. A second `openPinnedSplit` for either guid is dropped
    /// while a queued async block is still scheduled, so a rapid double
    /// click on the merged cell can't fire two `createSplit` requests.
    var pinnedSplitRecreateInFlight: Set<String> = []

    /// Pinned-tab DB guids waiting to be opened as live tabs so they can
    /// immediately enter `openNewTabAsSplit` as the partner. Seeded by
    /// `openNewTabAsSplitFromUnopenedPinned` (right-click "Open as Split"
    /// on an unopened pinned cell — the pinned record's synthetic `guid`
    /// can't be fed directly to `openNewTabAsSplit` because no live
    /// Chromium tab carries that id). Drained per-guid in
    /// `handleNewTabFromChromium` once the pinned tab's live counterpart
    /// arrives, at which point the standard split-formation path runs and
    /// `demotePinnedTabLeavingPlaceholder` moves the freshly-bound tab
    /// out of the pinned strip while leaving a placeholder behind.
    var pendingSplitAfterPinnedOpen: Set<String> = []

    /// bookmark.guid → splitId of the split that was opened from that
    /// split-view bookmark. Lets `openBookmark` detect that the bookmark is
    /// already open (and re-activate its primary pane) instead of creating
    /// another duplicate split. Cleared when the split is removed. Not
    /// persisted — window-scoped.
    var splitBookmarkBindings: [String: String] = [:]

    let imagePreviewState: BrowserImagePreviewState
    let themeContext: BrowserThemeContext

    /// Tracks in-flight tab dragging within this BrowserState (not a singleton).
    @MainActor private(set) lazy var tabDraggingSession: TabDraggingSession = { .init(state: self) }()

    @MainActor private(set) lazy var tabSwitchManager: TabSwitchManager = { .init(browserState: self) }()
    
    /// Whether this window can accept a cross-window drag from `source`.
    /// - Same-profile normal windows: allowed
    /// - Incognito-to-incognito: allowed
    /// - Normal vs incognito or different profiles: prohibited
    func canAcceptCrossWindowDrag(from source: BrowserState) -> Bool {
        if isIncognito && source.isIncognito { return true }
        if isIncognito != source.isIncognito { return false }
        return profileId == source.profileId
    }

    let windowId: Int
    let localStore: LocalStore
    let profileId: String
    let isIncognito: Bool
    let searchSuggestionChanged = PassthroughSubject<([[String: Any]], String), Never>()
    
    // MARK: - AI Chat Tab Identifier Helpers
    
    /// Prefix for AI Chat tab customGuid.
    static let aiChatIdPrefix = "ai-chat-for:"
    
    /// Returns the AI Chat customGuid for a tab identifier.
    static func aiChatId(for identifier: String) -> String {
        return "\(aiChatIdPrefix)\(identifier)"
    }
    
    /// Returns whether a customGuid belongs to an AI Chat tab.
    static func isAIChatId(_ customGuid: String?) -> Bool {
        guard let customGuid else { return false }
        return customGuid.hasPrefix(aiChatIdPrefix)
    }
    
    /// Extracts the associated tab identifier from an AI Chat customGuid.
    static func associatedIdentifier(from aiChatGuid: String) -> String? {
        guard aiChatGuid.hasPrefix(aiChatIdPrefix) else { return nil }
        return String(aiChatGuid.dropFirst(aiChatIdPrefix.count))
    }
    
    /// Returns the identifier used to associate AI Chat tabs with a browser tab.
    func getTabIdentifier(for tab: Tab) -> String {
        if let guidInDB = tab.guidInLocalDB, !guidInDB.isEmpty {
            return guidInDB
        }
        return String(tab.guid)
    }

    /// Resolves the identifier under which a tab's AI Chat tab is keyed.
    /// For tabs inside a split, both panes resolve to a single shared key so the
    /// split shares exactly one chat tab and switching the active pane does not
    /// switch the chat. Outside a split, falls back to the per-tab identifier.
    func chatIdentifier(for tab: Tab) -> String {
        guard let group = splitGroup(forTabId: tab.guid),
              let primary = tabs.first(where: { $0.guid == group.primaryTabId }),
              let secondary = tabs.first(where: { $0.guid == group.secondaryTabId }) else {
            return getTabIdentifier(for: tab)
        }
        let primaryId = getTabIdentifier(for: primary)
        let secondaryId = getTabIdentifier(for: secondary)
        if aiChatTabs[primaryId] != nil { return primaryId }
        if aiChatTabs[secondaryId] != nil { return secondaryId }
        // Neither pane has a chat yet: bind to the caller's tab so the chat
        // follows the pane the user invoked from, not whichever pane happens
        // to be focused at split-creation time. Keyed by tab.guid, so
        // reversing the split's primary/secondary roles does not move the
        // binding.
        return getTabIdentifier(for: tab)
    }

    // MARK: - Native NTP (Incognito)

    func enqueueNativeNTP() {
        pendingNativeNtpCount += 1
    }

    private func consumePendingNativeNTP() -> Bool {
        guard isIncognito, pendingNativeNtpCount > 0 else { return false }
        pendingNativeNtpCount -= 1
        return true
    }
    
    /// Migrates AI Chat association when a tab identifier changes.
    private func migrateAIChatTab(for tab: Tab, toNewIdentifier newIdentifier: String?) {
        let oldIdentifier = getTabIdentifier(for: tab)
        let targetIdentifier = newIdentifier ?? String(tab.guid)
        
        guard oldIdentifier != targetIdentifier else { return }
        
        if let aiChatTab = aiChatTabs[oldIdentifier] {
            aiChatTabs.removeValue(forKey: oldIdentifier)
            aiChatTabs[targetIdentifier] = aiChatTab
            AppLogInfo("🔄 [AIChat] Migrated AI Chat tab from '\(oldIdentifier)' to '\(targetIdentifier)'")
        }
    }

    /// Move the shared chat tab from one identifier to another (e.g. when a split
    /// pane closes and the chat tab must follow the surviving pane).
    func migrateAIChatTab(fromIdentifier oldId: String, toIdentifier newId: String) {
        guard oldId != newId, let aiChatTab = aiChatTabs.removeValue(forKey: oldId) else { return }
        aiChatTabs[newId] = aiChatTab
        AppLogInfo("🔄 [AIChat] Migrated split chat tab from '\(oldId)' to '\(newId)'")
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private(set) lazy var  bookmarkManager: BookmarkManager = { .init(with: self) }()
    private(set) lazy var  extensionManager: ExtensionManager = { .init(browserState: self) }()
    private(set) lazy var  downloadsManager: DownloadsManager = { .init(browserState: self) }()
    
    weak var windowController: MainBrowserWindowController?
    
    @MainActor
    init(windowId: Int,
         localStore: LocalStore,
         profileId: String = LocalStore.defaultProfileId,
         isIncognito: Bool = false) {
        self.windowId = windowId
        self.localStore = localStore
        self.profileId = profileId
        self.isIncognito = isIncognito
        self.imagePreviewState = BrowserImagePreviewState(loader: ImagePreviewLoader())
        self.themeContext = BrowserThemeContext(
            configuration: BrowserThemeConfigurationResolver.resolve(isIncognito: isIncognito)
        )
        self.layoutMode = Self.buildLayoutMode()
        if isIncognito {
            pinnedTabs = []
            visibleBookmarkTabs = []
        } else {
            addPinnedTabObserver()
            _ = bookmarkManager
        }
        self.tabDraggingSession.isDraggingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                self?.isDraggingTab = isDragging
            }
            .store(in: &cancellables)
        _ = extensionManager

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newLayoutMode = Self.buildLayoutMode()
                if self.layoutMode != newLayoutMode {
                    self.layoutMode = newLayoutMode
                    self.clearMultiSelection()
                }
                self.mayUpdateNormalTabsOnLayoutChanged()
                self.updateAISettings()
            }
            .store(in: &cancellables)

    }
    
    private func makePinnedTab(from model: TabDataModel) -> Tab {
        let tab = Tab(with: model)
        if let guid = tab.guidInLocalDB {
            tab.setFaviconSnapshotUpdater { [weak self] data in
                self?.localStore.updateTabFavicon(guid, favicon: data)
            }
        }
        return tab
    }
    
    private func syncPinnedTabMetadata(_ existing: Tab, from localTab: Tab) {
        let persistedURL = localTab.pinnedUrl ?? localTab.url
        if existing.pinnedUrl != persistedURL {
            existing.pinnedUrl = persistedURL
        }
        
        if existing.storedTitle != localTab.storedTitle {
            if let storedTitle = localTab.storedTitle, !storedTitle.isEmpty {
                existing.applyStoredTitle(storedTitle)
            } else {
                existing.storedTitle = nil
                existing.title = localTab.title
            }
        } else if let storedTitle = localTab.storedTitle, !storedTitle.isEmpty, existing.title != storedTitle {
            existing.title = storedTitle
        } else if localTab.storedTitle == nil, existing.title != localTab.title {
            existing.title = localTab.title
        }
        
        if existing.index != localTab.index {
            existing.setIndex(localTab.index)
        }
        existing.profileId = localTab.profileId

        if existing.splitPartnerGuid != localTab.splitPartnerGuid {
            existing.splitPartnerGuid = localTab.splitPartnerGuid
        }

        if existing.lastSeen != localTab.lastSeen {
            existing.lastSeen = localTab.lastSeen
        }

        if !existing.isOpenned {
            existing.url = persistedURL
        }
    }
    
    @MainActor
    func pinnedTabEditingURL(for guid: String, fallbackURL: String?) -> String {
        if let localTab = localStore.getTab(by: guid) {
            return localTab.url.absoluteString
        }
        guard let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else {
            return fallbackURL ?? ""
        }
        return pinnedTab.pinnedUrl ?? pinnedTab.url ?? fallbackURL ?? ""
    }
    
    @MainActor func addPinnedTabObserver() {
        guard !isIncognito else {
            pinnedTabs = []
            return
        }
        loadInitialPinnedTabs()

        $focusingTab
            .sink { [weak self] focusingTab in
                self?.updatePinnedTabActiveState(focusingTab)
            }
            .store(in: &cancellables)

        localStore.pinnedTabsPublisher(for: profileId)
            .sink { [weak self] (localTabs: [TabDataModel]) in
                guard let self else { return }
                self.handlePinnedTabsChanged(localTabs.map { self.makePinnedTab(from: $0) })
            }
            .store(in: &cancellables)
    }

    @MainActor private func loadInitialPinnedTabs() {
        guard !isIncognito else {
            pinnedTabs = []
            return
        }
        let localTabs: [TabDataModel] = localStore.getAllPinnedTabs(for: profileId)
        pinnedTabs = localTabs.map { makePinnedTab(from: $0) }

        for pinnedTab in pinnedTabs {
            guard let localGuid = pinnedTab.guidInLocalDB else { continue }
            if let activeTab = tabs.first(where: { $0.guidInLocalDB == localGuid }) {
                pinnedTab.isOpenned = true
                pinnedTab.setWebContentsWrapper(wrapper: activeTab.webContentWrapper)
                pinnedTab.guid = activeTab.guid
            }
        }
        updateNormalTabs()
    }

    private func handlePinnedTabsChanged(_ localTabs: [Tab]) {
        guard !isIncognito else {
            pinnedTabs = []
            return
        }
        pinnedTabs = localTabs.map { localTab in
            if let existing = pinnedTabs.first(where: { $0.guidInLocalDB == localTab.guidInLocalDB }) {
                syncPinnedTabMetadata(existing, from: localTab)
                return existing
            }
            return localTab
        }

        // Re-sync every pinned tab against the currently open Chromium tabs.
        syncAllPinnedTabsState()
        // Stamp the pinned-split partner linkage from any live `isPinned`
        // group now that the records exist, so closing a just-pinned split
        // can't strand the pair unlinked while the store write is still in
        // flight.
        reconcilePinnedSplitPartners()
        updateNormalTabs()
    }

    private func syncAllPinnedTabsState() {
        for pinnedTab in pinnedTabs {
            guard let localGuid = pinnedTab.guidInLocalDB else { continue }
            if let activeTab = tabs.first(where: { $0.guidInLocalDB == localGuid }) {
                pinnedTab.isOpenned = true
                pinnedTab.setWebContentsWrapper(wrapper: activeTab.webContentWrapper)
                pinnedTab.guid = activeTab.guid
            } else {
                pinnedTab.isOpenned = false
                pinnedTab.guid = -1
                pinnedTab.setWebContentsWrapper(wrapper: nil)
            }
            
            if pinnedTab.guidInLocalDB == focusingTab?.guidInLocalDB {
                pinnedTab.isActive = true
            }
        }
    }

    private func updatePinnedTabActiveState(_ focusingTab: Tab?) {
        for pinnedTab in pinnedTabs {
            pinnedTab.isActive = (pinnedTab.guid == focusingTab?.guid)
        }
        // Keep bookmark active state aligned with the focused Chromium tab.
        updateBookmarkActiveState(focusingTab)
    }
    
    private func updateBookmarkActiveState(_ focusingTab: Tab?) {
        guard !isIncognito else { return }
        let allBookmarks = bookmarkManager.getAllBookmarks()
        for bookmark in allBookmarks {
            // Split bookmarks aren't bound to a single Chromium tab; their
            // active state follows whether the focused tab sits in the split
            // we registered for that bookmark.
            if let splitId = splitBookmarkBindings[bookmark.guid],
               let group = splits.first(where: { $0.id == splitId }) {
                let isActive = focusingTab.map { group.contains(tabId: $0.guid) } ?? false
                if bookmark.isActive != isActive { bookmark.isActive = isActive }
                continue
            }
            bookmark.isActive = (bookmark.chromiumTabGuid == focusingTab?.guid)
        }
    }

    private func updateAISettings() {
        let aiEnabled = PhiPreferences.AISettings.phiAIEnabled.loadValue()
        let sentinelOnLogin = PhiPreferences.AISettings.launchSentinelOnLogin.loadValue()

        let aiChanged = aiEnabled != lastPhiAIEnabled
        let sentinelChanged = sentinelOnLogin != lastSentinelOnLogin

        guard aiChanged || sentinelChanged else { return }

        lastPhiAIEnabled = aiEnabled
        lastSentinelOnLogin = sentinelOnLogin

        if aiChanged {
            onAIEnabledChanged(aiEnabled, sentinelOnLogin: sentinelOnLogin)
        } else if sentinelChanged {
            updateSentinelRegistration(sentinelOnLogin)
        }
    }

    private func mayUpdateNormalTabsOnLayoutChanged() {
        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        if lastLegacyLayout != nil && traditionalLayout == lastLegacyLayout {
            return
        }
        lastLegacyLayout = traditionalLayout
        self.updateNormalTabs()
    }

    func updateNormalTabs() {
        let openedPinnedGuids = isIncognito
            ? []
            : Set(pinnedTabs.filter { $0.isOpenned }.compactMap { $0.guidInLocalDB })
        let openedBookmarkGuids = isIncognito
            ? []
            : Set(bookmarkManager.getAllBookmarks().filter { $0.isOpened }.map { $0.guid })

        // Tabs belonging to a split that's bound to a bookmark are
        // represented visually by the split-view bookmark cell, so hide
        // them from the sidebar tab list (mirrors the single-tab bookmark
        // binding that's filtered via `guidInLocalDB` above). Split tabs
        // have their `guidInLocalDB` cleared in
        // `consumePendingPrimarySplit`, so the lookup goes through
        // `splitBookmarkBindings` and the `SplitGroup` ids.
        let splitBookmarkBoundTabIds: Set<Int> = {
            var ids: Set<Int> = []
            for splitId in splitBookmarkBindings.values {
                guard let group = splits.first(where: { $0.id == splitId }) else { continue }
                ids.insert(group.primaryTabId)
                ids.insert(group.secondaryTabId)
            }
            return ids
        }()

        let traditionalLayout = PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
        let normalTabGuids = tabs.compactMap { tab -> Int? in
            if let localGuid = tab.guidInLocalDB, !localGuid.isEmpty {
                if openedPinnedGuids.contains(localGuid) {
                    return nil
                }
                if !traditionalLayout {
                    if openedBookmarkGuids.contains(localGuid) {
                        return nil
                    }
                }
            }
            if tab.isPinned {
                return nil
            }
            if !traditionalLayout, splitBookmarkBoundTabIds.contains(tab.guid) {
                return nil
            }
            return tab.guid
        }
        let normalTabGuidSet = Set(normalTabGuids)
        
        normalTabOrder.removeAll { !normalTabGuidSet.contains($0) }

        for guid in normalTabGuids where !normalTabOrder.contains(guid) {
            normalTabOrder.append(guid)
        }

        enforceSplitAdjacency()

        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }

        if multiSelection.isActive {
            var pruned = multiSelection
            pruned.formIntersection(normalTabGuidSet)
            if pruned != multiSelection {
                multiSelection = pruned
            }
        }
    }

    /// Re-asserts the invariant that every split's two members are adjacent
    /// in `normalTabOrder`, with `primaryTabId` immediately before
    /// `secondaryTabId`. The merged tab-bar rendering in `SideTabView` and
    /// `TabBackgroundLayer` requires physical adjacency (see
    /// `splitPairPosition`), but `reorderTabs` can re-sequence
    /// `normalTabOrder` from a Chromium echo that's stale relative to a
    /// just-issued `placeTabAdjacent`, leaving the pair separated. Called
    /// from `updateNormalTabs` (every publish) and `handleSplitCreated`
    /// (every new SplitGroup). Returns true when the order changed.
    @discardableResult
    func enforceSplitAdjacency() -> Bool {
        var changed = false
        for group in splits {
            guard let primaryIdx = normalTabOrder.firstIndex(of: group.primaryTabId),
                  let secondaryIdx = normalTabOrder.firstIndex(of: group.secondaryTabId) else {
                continue
            }
            if secondaryIdx == primaryIdx + 1 { continue }
            normalTabOrder.remove(at: secondaryIdx)
            guard let anchor = normalTabOrder.firstIndex(of: group.primaryTabId) else { continue }
            normalTabOrder.insert(group.secondaryTabId, at: anchor + 1)
            changed = true
        }
        return changed
    }
    
    
    func openOrFocusPinnedTab(_ tab: Tab) {
        // FIXME: FavoriteTabViewController can hand back a different object instance for the same
        // logical tab because it uses DifferenceDatasource. Resolve against `pinnedTabs` first.
        guard let guid = tab.guidInLocalDB, let realTab = pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else {
            return
        }

        // Pinned-split pairs are rendered as one merged cell in the sidebar
        // and as one wide cell in the horizontal tab strip. Both surfaces
        // funnel clicks here, and the keyboard "go to pinned tab N" shortcut
        // also does. Route to `openPinnedSplit` so the partner pane comes
        // along instead of opening only the bound URL.
        //
        // `openPinnedSplit` is `@MainActor`; the existing call sites
        // (sidebar / tab strip / keyboard shortcuts) all dispatch from the
        // main thread, so `assumeIsolated` is safe here and avoids forcing
        // every caller of `openOrFocusPinnedTab` to become `@MainActor`.
        if let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: realTab) {
            localStore.updateLastSeen(leftDB)
            localStore.updateLastSeen(rightDB)
            MainActor.assumeIsolated {
                openPinnedSplit(leftPinnedGuid: leftDB,
                                rightPinnedGuid: rightDB,
                                focusRight: guid == rightDB)
            }
            return
        }

        localStore.updateLastSeen(guid)
        if realTab.isOpenned, let wrapper = realTab.webContentWrapper {
            wrapper.setAsActiveTab()
        } else {
            createTab(realTab.url ?? "", customGuid: realTab.guidInLocalDB, focusAfterCreate: true)
        }
    }
    
    func toggleSidebar(_ collapse: Bool? = nil) {
        if let collapse {
            sidebarCollapsed = collapse
        } else {
            sidebarCollapsed.toggle()
        }
    }
    
    /// Toggle AI Chat for the currently focused tab
    /// The collapse state is now managed per-tab, not globally
    func toggleAIChat(_ collapse: Bool? = nil) {
        // Defense in depth: any caller (extension, debug, etc.) hitting this
        // path during placeholder mode would operate on a stale focusingTab.
        // Primary entry points are gated upstream; this is the safety net.
        guard !isInPlaceholderMode else { return }
        // Overview owns the web content surface; allow forced collapse, but
        // block stale actions from reopening chat while overview is visible.
        if groupOverviewState != nil, collapse != true { return }

        // Dispatch to the focusing tab's AI Chat state, mirroring to its split
        // partner so both panes of a split share one expand/collapse state.
        if let tab = focusingTab {
            setAIChatCollapsed(for: tab, collapsed: collapse ?? !tab.aiChatCollapsed)
        }

        // Also update the global state for backward compatibility
        // (e.g., for AIChatViewController in non-traditional layout)
        if let collapse {
            aiChatCollapsed = collapse
        } else {
            aiChatCollapsed.toggle()
        }
    }

    /// Sets the AI Chat collapsed state for a tab, mirroring it to the tab's
    /// split partner so both panes of a split share one expand/collapse state.
    func setAIChatCollapsed(for tab: Tab, collapsed: Bool) {
        tab.toggleAIChat(collapsed)
        guard let group = splitGroup(forTabId: tab.guid),
              let partnerId = group.partnerTabId(of: tab.guid),
              let partner = tabs.first(where: { $0.guid == partnerId }),
              partner.aiChatCollapsed != collapsed else {
            return
        }
        partner.toggleAIChat(collapsed)
    }

    // =========================================================================
    // Placeholder mode (last-tab close → chrome://dino shell)
    //
    // Driven by PhiChromiumCoordinator.windowDidEnter/ExitPlaceholderMode,
    // which are themselves triggered by Browser::Show/HidePlaceholder on the
    // Chromium side. See docs/superpowers/specs/
    // 2026-05-25-placeholder-on-last-tab-close-design.md §6.1 / §9.1 for
    // the synchronous detach contract.
    // =========================================================================

    @MainActor
    func enterPlaceholderMode(wrapper: WebContentWrapper & NSObject) {
        guard placeholderWrapper == nil else { return }  // Idempotent
        placeholderWrapper = wrapper
        // Clear stale focused tab. The just-closed tab is already gone from
        // `tabs`, but `focusingTab` still references it because nothing on the
        // close path nils it. Selectors that read `focusingTab` (e.g.
        // canBookmarkCurrentTab, address-bar context menu) would otherwise
        // operate on a destroyed Tab object during placeholder mode.
        focusingTab = nil
        isInPlaceholderMode = true
        AppLogInfo("🦖 [BrowserState] entered placeholder mode windowId=\(windowId)")
    }

    @MainActor
    func exitPlaceholderMode() {
        guard let wrapper = placeholderWrapper else { return }
        // CONTRACT (UAF prevention): detach NSView SYNCHRONOUSLY before
        // returning. Chromium calls placeholder_web_contents_.reset()
        // immediately after this bridge call returns; the underlying NSView
        // is destroyed at that point. If it's still in the AppKit hierarchy,
        // AppKit holds a dangling pointer.
        wrapper.nativeView?.removeFromSuperview()
        placeholderWrapper = nil
        isInPlaceholderMode = false
        // The new real tab's activeTabChanged event arrives shortly and sets
        // focusingTab. Until then, nil is correct.
        AppLogInfo("🦖 [BrowserState] exited placeholder mode windowId=\(windowId)")
    }

    deinit {
        // Diagnostic only. By the time we get here both the Mac-side
        // windowWillClose handler AND Chromium's Browser::~Browser →
        // HidePlaceholder bridge call should have run exitPlaceholderMode,
        // leaving placeholderWrapper == nil. We deliberately do NOT touch
        // nativeView here: deinit is non-isolated and may run off the main
        // thread, and removeFromSuperview() is a main-thread AppKit call.
        // If this warn fires, the fix belongs in the teardown paths, not here.
        if placeholderWrapper != nil {
            AppLogWarn("🦖 [BrowserState] deinit reached with placeholderWrapper still set — teardown paths skipped windowId=\(windowId)")
        }
    }

    func toggleFullScreenMode(_ fullScreen: Bool) {
        if fullScreen != isInFullScreenMode {
            isInFullScreenMode.toggle()
        }
    }
    
    @MainActor
    func focuseTab(_ tab: Tab) {
        // AI Chat Tab cannot become focusingTab
        if let customGuid = tab.guidInLocalDB, Self.isAIChatId(customGuid) {
            return
        }

        if normalTabs.contains(where: { $0.guid == tab.guid }) {
            clearGroupOverview()
        }
        
        if focusingTab?.guid == tab.guid {
            return
        }
        tabs.forEach {
            if $0.guid == tab.guid {
                $0.setActive(true)
            } else {
                $0.setActive(false)
            }
        }
        tabSwitchManager.handleExternalFocusChange()
        focusingTab = tab
        tabSwitchManager.recordActiveTab(tab)
    }

    // MARK: - Multi-selection

    @MainActor
    @discardableResult
    func toggleMultiSelection(for tab: Tab) -> Bool {
        guard TabMultiSelection.isEnabled else {
            clearMultiSelection()
            return false
        }

        // Pinned / bookmark-backed tabs do not participate: exit multi-select + activate.
        if tab.isPinned {
            clearMultiSelection()
            openOrFocusPinnedTab(tab)
            return true
        }
        if isBookmarkBackedTab(tab) {
            clearMultiSelection()
            focuseTab(tab)
            return true
        }
        // A group overview is a separate surface where multi-selection is
        // disabled: a Cmd+click activates the tab (which dismisses the
        // overview) rather than toggling the selection.
        if activeGroupOverviewToken != nil {
            clearMultiSelection()
            focuseTab(tab)
            return true
        }
        // The active tab is always implicitly included; toggling it is a no-op.
        if tab.guid == focusingTab?.guid { return true }
        multiSelection.toggle(tab.guid)
        return true
    }

    func clearMultiSelection() {
        guard multiSelection.isActive else { return }
        multiSelection = .empty
    }

    /// Selected tabs in authoritative tab order (active tab implicitly included).
    var orderedMultiSelectedTabs: [Tab] {
        var target = multiSelection.guids
        if let active = focusingTab?.guid { target.insert(active) }
        return normalTabs.filter { target.contains($0.guid) }
    }

    private func isBookmarkBackedTab(_ tab: Tab) -> Bool {
        guard !tab.isPinned, let guid = tab.guidInLocalDB, !guid.isEmpty else { return false }
        return bookmarkManager.bookmark(withGuid: guid) != nil
    }

    // MARK: - Multi-selection batch actions

    @MainActor
    func closeMultiSelectedTabs() {
        let tabs = orderedMultiSelectedTabs
        clearMultiSelection()
        for tab in tabs {
            tab.close()
        }
    }

    var hasTabsOutsideMultiSelection: Bool {
        let selectedTabIds = Set(orderedMultiSelectedTabs.map(\.guid))
        return tabs.contains { !selectedTabIds.contains($0.guid) }
    }

    @MainActor
    func closeTabsOutsideMultiSelection() {
        let selectedTabIds = Set(orderedMultiSelectedTabs.map(\.guid))
        guard !selectedTabIds.isEmpty else { return }
        closeTabs(keeping: selectedTabIds)
    }

    func copyLinksOfMultiSelectedTabs() {
        let urls = orderedMultiSelectedTabs.compactMap { $0.url }
        clearMultiSelection()
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.joined(separator: "\n"), forType: .string)
    }

    @MainActor
    func duplicateMultiSelectedTabs() {
        let tabs = orderedMultiSelectedTabs
        clearMultiSelection()
        for tab in tabs {
            guard let tabURL = tab.url, !tabURL.isEmpty else { continue }
            createTab(tabURL, focusAfterCreate: true)
        }
    }

    func bookmarkMultiSelectedTabs(into folder: Bookmark?) {
        let tabs = orderedMultiSelectedTabs
        clearMultiSelection()
        for tab in tabs {
            guard let tabURL = tab.url, !tabURL.isEmpty else { continue }
            bookmarkManager.addBookmark(title: tab.title,
                                        url: URLProcessor.processUserInput(tabURL),
                                        to: folder,
                                        faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
        }
    }

    /// Bookmarks a pre-captured tab snapshot into a newly created folder.
    /// The caller must snapshot the selection before any async UI (e.g. the
    /// new-folder dialog) clears it; reading the live selection here would
    /// only see the implicit active tab.
    func bookmarkTabs(_ tabs: [Tab], intoNewFolderNamed name: String) {
        let validTabs = tabs.filter { ($0.url?.isEmpty == false) }
        clearMultiSelection()
        guard let first = validTabs.first, let firstURL = first.url else { return }
        bookmarkManager.addFolderFromTabStrip(
            title: name,
            to: nil,
            bookmarkTitle: first.title,
            bookmarkURL: URLProcessor.processUserInput(firstURL),
            bookmarkFaviconData: first.liveFaviconData ?? first.cachedFaviconData
        ) { [weak self] success, newFolderGuid in
            // The folder may not be in the in-memory index yet, so address it
            // by guid rather than resolving a `Bookmark` instance.
            guard success, let self else { return }
            for tab in validTabs.dropFirst() {
                guard let tabURL = tab.url, !tabURL.isEmpty else { continue }
                self.bookmarkManager.addBookmark(
                    title: tab.title,
                    url: URLProcessor.processUserInput(tabURL),
                    toParentGuid: newFolderGuid,
                    faviconData: tab.liveFaviconData ?? tab.cachedFaviconData)
            }
        }
    }

    @MainActor
    func groupMultiSelectedTabs() {
        let tabs = orderedMultiSelectedTabs
        clearMultiSelection()
        guard !tabs.isEmpty, let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let tabIds = tabs.map { NSNumber(value: Int64($0.guid)) }
        let token = bridge.createGroupFromTabs(withWindowId: Int64(windowId),
                                               tabIds: tabIds,
                                               title: nil,
                                               color: nil)
        guard !token.isEmpty else { return }
        for tab in tabs {
            applyOptimisticGroupMembership(tabId: tab.guid, newToken: token)
        }
    }

    /// Targets to add to an existing group, excluding tabs already in it.
    func multiSelectionTargets(forAddingToGroup token: String) -> [Tab] {
        orderedMultiSelectedTabs.filter { $0.groupToken != token }
    }

    @MainActor
    func addMultiSelectedTabs(toGroup token: String) {
        let targets = multiSelectionTargets(forAddingToGroup: token)
        clearMultiSelection()
        guard !targets.isEmpty, let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let tabIds = targets.map { NSNumber(value: Int64($0.guid)) }
        bridge.addTabsToGroup(withWindowId: Int64(windowId),
                              tabIds: tabIds,
                              tokenHex: token)
        for tab in targets {
            applyOptimisticGroupMembership(tabId: tab.guid, newToken: token)
        }
    }
    
    @MainActor
    func focusTabWithTabId(_ tabId: Int) {
        // AI Chat tabs redirect focus back to the associated content tab.
        for (identifier, aiTab) in aiChatTabs {
            if aiTab.guid == tabId {
                if let associatedTab = findTabByIdentifier(identifier) {
                    focuseTab(associatedTab)
                }
                return
            }
        }
        
        if let tab = tabs.first(where: { $0.guid == tabId }) {
            focuseTab(tab)
        }
    }

    @MainActor
    func handleChromiumActiveTabChanged(_ tabId: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let previousActiveTabId = focusingTab?.guid
        let previousActiveText = previousActiveTabId.map(String.init) ?? "nil"
        let resetTabIds = Array(nativeRelationGraph.resetOnActiveChangeTabIds).sorted()
        AppLogDebug(
            "[NativeTab] handleChromiumActiveTabChanged new=\(tabId) " +
            "previous=\(previousActiveText) " +
            "graphBefore={openers=\(nativeRelationGraph.openerByTabId), reset=\(resetTabIds)}"
        )
        if let previousActiveTabId {
            nativeRelationGraph.forgetOpenerOnActiveTabChange(from: previousActiveTabId, to: tabId)
        }
        let resetTabIdsAfterForget = Array(nativeRelationGraph.resetOnActiveChangeTabIds).sorted()
        AppLogDebug(
            "[NativeTab] handleChromiumActiveTabChanged graphAfterForget={openers=\(nativeRelationGraph.openerByTabId), " +
            "reset=\(resetTabIdsAfterForget)}"
        )

        if let pendingSelectionOverride {
            let closingTabStillExists = tabs.contains(where: { $0.guid == pendingSelectionOverride.closingTabId })
            AppLogDebug(
                "[NativeTab] handleChromiumActiveTabChanged pendingOverride={closing=\(pendingSelectionOverride.closingTabId), " +
                "target=\(pendingSelectionOverride.targetTabId), version=\(pendingSelectionOverride.relationVersion)} " +
                "chromiumChose=\(tabId) closingTabStillExists=\(closingTabStillExists)"
            )

            if closingTabStillExists {
                AppLogDebug("[NativeTab] handleChromiumActiveTabChanged discarding stale override, closing tab not yet removed")
                self.pendingSelectionOverride = nil
            } else if pendingSelectionOverride.targetTabId == tabId {
                AppLogDebug("[NativeTab] handleChromiumActiveTabChanged override matches chromium choice")
                self.pendingSelectionOverride = nil
                focusTabWithTabId(tabId)
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                AppLogDebug("[NativeTab] ⏱ handleChromiumActiveTabChanged tabId=\(tabId) took \(String(format: "%.2f", elapsed))ms")
                return
            } else if let targetTab = tabs.first(where: { $0.guid == pendingSelectionOverride.targetTabId }),
                      let wrapper = targetTab.webContentWrapper {
                AppLogDebug("[NativeTab] handleChromiumActiveTabChanged overriding to target=\(pendingSelectionOverride.targetTabId)")
                self.pendingSelectionOverride = nil
                wrapper.setAsActiveTab()
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                AppLogDebug("[NativeTab] ⏱ handleChromiumActiveTabChanged tabId=\(tabId) took \(String(format: "%.2f", elapsed))ms")
                return
            } else {
                AppLogDebug("[NativeTab] handleChromiumActiveTabChanged override target not found, falling through")
                self.pendingSelectionOverride = nil
            }
        }

        focusTabWithTabId(tabId)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        AppLogDebug("[NativeTab] ⏱ handleChromiumActiveTabChanged tabId=\(tabId) took \(String(format: "%.2f", elapsed))ms")
    }
    
    /// Find a tab by its identifier (either guidInLocalDB or chromium guid as string)
    private func findTabByIdentifier(_ identifier: String) -> Tab? {
        if let tab = tabs.first(where: { $0.guidInLocalDB == identifier }) {
            return tab
        }
        if let guid = Int(identifier), let tab = tabs.first(where: { $0.guid == guid }) {
            return tab
        }
        return nil
    }
    
    /// Create an AI Chat tab associated with the specified identifier
    /// - Parameters:
    ///   - identifier: The tab identifier to associate with
    ///   - chromeTabId: The Chromium tab ID (used by Chrome extension APIs) of the associated content tab
    func createAIChatTab(for identifier: String, chromeTabId: Int) {
        guard LoginController.shared.isLoggedin() else {
            return
        }
        if aiChatTabs[identifier] != nil {
            return
        }
        if !aiChatTabsBeingCreated.insert(identifier).inserted {
            return
        }
        let customGuid = Self.aiChatId(for: identifier)
        createTab("chrome-extension://fenmfiepnpdlhplemgijlimpbebebljo/index.html?is_sidebar=1&tabId=\(chromeTabId)", customGuid: customGuid, focusAfterCreate: false)
    }
    
    /// Close the AI Chat tab associated with the specified identifier
    /// - Parameter identifier: The tab identifier whose AI Chat tab should be closed
    ///
    /// Goes straight through `WebContentWrapper.close()` instead of `Tab.close()` so we
    /// never accidentally enter the `IDC_CLOSE_TAB` branch (the AI tab is not active on
    /// the mac side, and that command would close whatever is active in Chromium, which
    /// is not necessarily the AI tab — especially with `UnclosableTabMarker` skewing
    /// Chromium's selection logic).
    func closeAIChatTab(for identifier: String) {
        guard let aiTab = aiChatTabs.removeValue(forKey: identifier) else { return }
        aiTab.webContentWrapper?.close()
    }
    
    /// Close the normal tab associated with the specified identifier (called when AI Chat tab is closed)
    /// - Parameter identifier: The tab identifier of the normal tab to close
    private func closeAssociatedTab(for identifier: String) {
        guard let tab = findTabByIdentifier(identifier) else { return }
        tab.close()
    }
    
    func handleNewTabFromChromium(_ tab: Tab, context: NativeTabCreationContext? = nil) {
        // AI Chat tabs never participate in the split/bookmark/pinned rebind
        // pipeline below — short-circuit before the defer so the split-pending
        // consumers don't fire for a tab that was never added to `tabs`.
        if let customGuid = tab.guidInLocalDB,
           Self.isAIChatId(customGuid),
           let identifier = Self.associatedIdentifier(from: customGuid) {
            aiChatTabsBeingCreated.remove(identifier)
            // Defensive: if Chromium produced more than one AI Chat tab for the
            // same identifier (e.g. two callers raced before our dedup landed,
            // or a previous build leaked one), keep the first arrival and close
            // the duplicate via Chromium so it doesn't outlive its associated
            // content tab and keep the window alive.
            if let existing = aiChatTabs[identifier] {
                AppLogWarn("🤖 [AIChat] duplicate AI tab for identifier=\(identifier) existing=\(existing.guid) duplicate=\(tab.guid); closing duplicate")
                tab.webContentWrapper?.close()
                return
            }
            aiChatTabs[identifier] = tab
            return  // Don't add to regular tabs
        }

        defer {
            consumePendingSplitPartner(for: tab)
            consumePendingPrimarySplit(for: tab)
            consumePendingSplitSlotSwap(for: tab)
        }

        if consumePendingNativeNTP() {
            tab.usesNativeNTP = true
        }

        // Seed `cachedFaviconData` for cross-window / tear-off
        // arrivals from the shared cross-window favicon stash. Runs
        // BEFORE `tabs.append(tab)` so the first chip-mosaic layout
        // triggered by the `@Published tabs` sink reads populated
        // bytes instead of nil; otherwise the mosaic stays blank for
        // normal sites (NTP slots are unaffected — they go through
        // the URL classifier in `collectMosaicFaviconData`). See
        // `crossWindowFaviconStash` for the why.
        if let stashedFavicon = Self.consumeCrossWindowFavicon(for: tab.guid) {
            tab.updateCachedFaviconData(stashedFavicon)
        }

        let preseededHiddenOpenerTabIds = hiddenPinnedOrBookmarkTabIds()
        preseedHiddenOpenerInsertionIfNeeded(tab: tab,
                                             context: context,
                                             hiddenOpenerTabIds: preseededHiddenOpenerTabIds)

        tabs.append(tab)
        // If Chromium emitted a kCreated/kJoined for this tab while it was
        // still in flight, restore the group membership now that the Tab
        // exists. Sidebar reactivity comes through the group's
        // objectWillChange (signalled by drainPendingGroupClaim).
        drainPendingGroupClaim(for: tab)
        let creationKindText = context?.creationKind.rawValue ?? "nil"
        let t0 = CFAbsoluteTimeGetCurrent()
        let openerText = context?.openerTabId.map(String.init) ?? "nil"
        let insertAfterText = context?.insertAfterTabId.map(String.init) ?? "nil"
        let sourceText = context?.sourceTabId.map(String.init) ?? "nil"
        let resetOnActiveText = context?.resetOpenerOnActiveTabChange.description ?? "nil"
        let resetTabIds = Array(nativeRelationGraph.resetOnActiveChangeTabIds).sorted()
        AppLogDebug(
            "[NativeTab] handleNewTabFromChromium tabId=\(tab.guid) title=\(tab.title ?? "") " +
            "url=\(tab.url ?? "") normalOrderBefore=\(normalTabOrder) " +
            "context={kind=\(creationKindText), opener=\(openerText), insertAfter=\(insertAfterText), " +
            "source=\(sourceText), resetOnActive=\(resetOnActiveText)} " +
            "graphBefore={openers=\(nativeRelationGraph.openerByTabId), reset=\(resetTabIds)}"
        )
        nativeRelationGraph.applyOptimisticCreation(tabId: tab.guid, context: context)

        // Reattach to a pinned tab entry when the local guid matches.
        if let localGuid = tab.guidInLocalDB,
           let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == localGuid }) {
            localStore.updateLastSeen(localGuid)
            pinnedTab.isOpenned = true
            pinnedTab.setWebContentsWrapper(wrapper: tab.webContentWrapper)
            pinnedTab.guid = tab.guid
            // If this pinned tab was part of a pinned-split before the last
            // shutdown and its partner is also live now, re-create the split
            // so the pair shows as one again. Skipped when a `SplitGroup`
            // already covers the pair (e.g. Chromium's own session restore).
            maybeRecreatePersistedPinnedSplit(forJustOpenedPinnedTab: pinnedTab)
            // Drain a pending "Open as Split" intent recorded against this
            // pinned guid. Deferred one runloop tick so the surrounding
            // new-tab event finishes unwinding before `openNewTabAsSplit`
            // calls back into Chromium (matches the same defer used by the
            // pinned-split recreate path for the same reason).
            if pendingSplitAfterPinnedOpen.remove(localGuid) != nil {
                let liveTabId = tab.guid
                DispatchQueue.main.async { [weak self] in
                    self?.openNewTabAsSplit(partnerTabId: liveTabId)
                }
            }
        }

        // Reattach to a bookmark entry when the local guid matches.
        handleBookmarkTabOpened(tab)

        // Honor cross-window group arrival first (priority over single-
        // tab pending). Each of the N members lands at
        // `atIndex + arrivedCount`; arrival order should match
        // Chromium's group order but the index formula tolerates skew.
        if let pending = pendingGroupInsertion {
            let isStale = pending.requestedAt.timeIntervalSinceNow
                < -Self.pendingGroupInsertionTimeoutSeconds
            if isStale {
                AppLogWarn(
                    "[TabGroupDrag] pendingGroupInsertion timed out (members=" +
                    "\(pending.memberGuids), arrived=\(pending.arrivedCount)) — dropping"
                )
                pendingGroupInsertion = nil
                // Fall through to single-tab pending / default flow.
            } else if pending.memberGuids.contains(tab.guid) {
                let insertIndex = pending.atIndex + pending.arrivedCount
                AppLogDebug(
                    "[TabGroupDrag] pendingGroupInsertion match tabId=\(tab.guid) " +
                    "insertIndex=\(insertIndex) arrived=\(pending.arrivedCount + 1)/" +
                    "\(pending.memberGuids.count)"
                )
                insertIntoNormalTabOrder(
                    tabGuid: tab.guid,
                    at: insertIndex,
                    syncChromiumOrder: false
                )
                let newCount = pending.arrivedCount + 1
                if newCount >= pending.memberGuids.count {
                    pendingGroupInsertion = nil
                } else {
                    var updated = pending
                    updated.arrivedCount = newCount
                    pendingGroupInsertion = updated
                }
                let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                AppLogDebug("[NativeTab] ⏱ handleNewTabFromChromium tabId=\(tab.guid) took \(String(format: "%.2f", elapsed))ms")
                return
            }
        }

        // Honor any pending insertion target for tabs promoted into the normal tab list.
        if consumePendingNormalTabInsertion(for: tab) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            AppLogDebug("[NativeTab] ⏱ handleNewTabFromChromium tabId=\(tab.guid) took \(String(format: "%.2f", elapsed))ms")
            return
        }

        let hiddenOpenerTabIds = preseededHiddenOpenerTabIds
        let shouldSyncHiddenOpenerOrder: Bool = {
            guard let context,
                  let openerTabId = context.openerTabId,
                  hiddenOpenerTabIds.contains(openerTabId) else {
                return false
            }
            return context.creationKind == .linkForeground || context.creationKind == .linkBackground
        }()

        if let insertionIndex = NativeTabDecisionEngine.insertionIndex(
            visibleNormalTabIds: normalTabs.map(\.guid),
            context: context,
            relationGraph: nativeRelationGraph,
            splitPartnerByTabId: splitPartnerByTabIdMap(),
            hiddenOpenerTabIds: hiddenOpenerTabIds
        ) {
            AppLogDebug("[NativeTab] handleNewTabFromChromium inserting tabId=\(tab.guid) at index=\(insertionIndex)")
            insertIntoNormalTabOrder(tabGuid: tab.guid,
                                     at: insertionIndex,
                                     syncChromiumOrder: shouldSyncHiddenOpenerOrder)
            let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            AppLogDebug("[NativeTab] ⏱ handleNewTabFromChromium tabId=\(tab.guid) took \(String(format: "%.2f", elapsed))ms")
            return
        }
        
        AppLogDebug("[NativeTab] handleNewTabFromChromium falling back to updateNormalTabs for tabId=\(tab.guid)")
        updateNormalTabs()
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        AppLogDebug("[NativeTab] ⏱ handleNewTabFromChromium tabId=\(tab.guid) took \(String(format: "%.2f", elapsed))ms")
    }

    private func preseedHiddenOpenerInsertionIfNeeded(
        tab: Tab,
        context: NativeTabCreationContext?,
        hiddenOpenerTabIds: Set<Int>
    ) {
        guard pendingGroupInsertion?.memberGuids.contains(tab.guid) != true,
              pendingNormalTabInsertion?.matches(tab: tab) != true,
              let context,
              let openerTabId = context.openerTabId,
              hiddenOpenerTabIds.contains(openerTabId),
              context.creationKind == .linkForeground || context.creationKind == .linkBackground,
              let insertionIndex = NativeTabDecisionEngine.insertionIndex(
                visibleNormalTabIds: normalTabs.map(\.guid),
                context: context,
                relationGraph: nativeRelationGraph,
                splitPartnerByTabId: splitPartnerByTabIdMap(),
                hiddenOpenerTabIds: hiddenOpenerTabIds
              ) else {
            return
        }

        normalTabOrder.removeAll { $0 == tab.guid }
        let insertIndex = min(max(0, insertionIndex), normalTabOrder.count)
        normalTabOrder.insert(tab.guid, at: insertIndex)
        nativeOrderProtectedTabIds.insert(tab.guid)
        AppLogDebug(
            "[NativeTab] preseed hidden opener insertion tabId=\(tab.guid) " +
            "opener=\(openerTabId) index=\(insertIndex)"
        )
    }

    private func hiddenPinnedOrBookmarkTabIds() -> Set<Int> {
        guard !isIncognito else { return [] }

        let openedPinnedGuids = Set(
            pinnedTabs.filter { $0.isOpenned }.compactMap { $0.guidInLocalDB }
        )
        let openedBookmarkGuids = Set(
            bookmarkManager.getAllBookmarks().filter { $0.isOpened }.map { $0.guid }
        )
        var result: Set<Int> = []

        for tab in tabs where !normalTabOrder.contains(tab.guid) {
            if tab.isPinned {
                result.insert(tab.guid)
                continue
            }
            guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty else {
                continue
            }
            if openedPinnedGuids.contains(localGuid) || openedBookmarkGuids.contains(localGuid) {
                result.insert(tab.guid)
            }
        }

        for splitId in splitBookmarkBindings.values {
            guard let group = splits.first(where: { $0.id == splitId }) else { continue }
            if !normalTabOrder.contains(group.primaryTabId) {
                result.insert(group.primaryTabId)
            }
            if !normalTabOrder.contains(group.secondaryTabId) {
                result.insert(group.secondaryTabId)
            }
        }

        return result
    }

    func applyRelationshipSnapshot(_ snapshot: NativeTabRelationshipSnapshot) {
        guard snapshot.windowId == windowId else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let snapshotResetTabIds = Array(snapshot.resetOnActiveChangeTabIds).sorted()
        let knownTabIds = Array(nativeRelationGraph.knownTabIds).sorted()
        let graphResetTabIds = Array(nativeRelationGraph.resetOnActiveChangeTabIds).sorted()
        let localFixBefore = nativeRelationGraph.locallyFixedOpenerTabIds
        AppLogDebug(
            "[NativeTab] applyRelationshipSnapshot version=\(snapshot.version) " +
            "snapshotOpeners=\(snapshot.openerByTabId) " +
            "snapshotReset=\(snapshotResetTabIds) " +
            "graphBefore={known=\(knownTabIds), openers=\(nativeRelationGraph.openerByTabId), " +
            "reset=\(graphResetTabIds), localFix=\(localFixBefore)}"
        )
        nativeRelationGraph.apply(snapshot: snapshot)
        let knownTabIdsAfterApply = Array(nativeRelationGraph.knownTabIds).sorted()
        let graphResetTabIdsAfterApply = Array(nativeRelationGraph.resetOnActiveChangeTabIds).sorted()
        AppLogDebug(
            "[NativeTab] applyRelationshipSnapshot graphAfter={known=\(knownTabIdsAfterApply), " +
            "openers=\(nativeRelationGraph.openerByTabId), reset=\(graphResetTabIdsAfterApply), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds), version=\(nativeRelationGraph.version)}"
        )
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        AppLogDebug("[NativeTab] ⏱ applyRelationshipSnapshot version=\(snapshot.version) took \(String(format: "%.2f", elapsed))ms")
    }

    func prepareForActiveTabClose(tabId: Int) {
        guard focusingTab?.guid == tabId else { return }
        guard normalTabs.contains(where: { $0.guid == tabId }) else { return }
        let visibleIds = normalTabs.map(\.guid)
        AppLogDebug(
            "[NativeTab] prepareForActiveTabClose tabId=\(tabId) " +
            "visibleIds=\(visibleIds) " +
            "graph={openers=\(nativeRelationGraph.openerByTabId), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds)}"
        )
        var targetTabId = NativeTabDecisionEngine.selectionTarget(
            visibleNormalTabIds: visibleIds,
            closingTabId: tabId,
            relationGraph: nativeRelationGraph
        )

        if let target = targetTabId,
           nativeRelationGraph.openerByTabId[tabId] != nil,
           !isOpenerRelated(target: target, closingTabId: tabId) {
            if let pinnedTarget = findPinnedOrBookmarkAncestor(of: tabId) {
                AppLogDebug("[NativeTab] prepareForActiveTabClose redirecting to pinned/bookmark ancestor \(pinnedTarget)")
                targetTabId = pinnedTarget
            }
        }

        guard let finalTarget = targetTabId else {
            AppLogDebug("[NativeTab] prepareForActiveTabClose no selectionTarget found, clearing override")
            pendingSelectionOverride = nil
            return
        }

        pendingSelectionOverride = NativePendingSelectionOverride(
            closingTabId: tabId,
            targetTabId: finalTarget,
            relationVersion: nativeRelationGraph.version
        )
        AppLogDebug(
            "[NativeTab] prepareForActiveTabClose override={closing=\(tabId), " +
            "target=\(finalTarget), version=\(nativeRelationGraph.version)}"
        )
    }

    /// Walk the opener chain upward to find a pinned or bookmark content tab.
    private func findPinnedOrBookmarkAncestor(of tabId: Int) -> Int? {
        guard !isIncognito else { return nil }
        let openedPinnedGuids = Set(pinnedTabs.filter { $0.isOpenned }.compactMap { $0.guidInLocalDB })
        let openedBookmarkGuids = Set(bookmarkManager.getAllBookmarks().filter { $0.isOpened }.map { $0.guid })

        var current: Int? = nativeRelationGraph.openerByTabId[tabId]
        var visited = Set<Int>()
        while let cid = current, !visited.contains(cid) {
            visited.insert(cid)
            if let tab = tabs.first(where: { $0.guid == cid }),
               let localGuid = tab.guidInLocalDB, !localGuid.isEmpty {
                if openedPinnedGuids.contains(localGuid) || openedBookmarkGuids.contains(localGuid) {
                    return cid
                }
            }
            current = nativeRelationGraph.openerByTabId[cid]
        }
        return nil
    }

    /// Check if `target` was selected via direct opener relationship (child, sibling, or opener).
    /// Remote ancestors don't count — they indicate a neighbor fallback, not opener-based selection.
    private func isOpenerRelated(target: Int, closingTabId: Int) -> Bool {
        let closingOpener = nativeRelationGraph.openerByTabId[closingTabId]
        let targetOpener = nativeRelationGraph.openerByTabId[target]
        if targetOpener == closingTabId { return true }
        if let co = closingOpener, targetOpener == co { return true }
        if let co = closingOpener, target == co { return true }
        return false
    }
    
    @MainActor
    func closeTab(_ tabId: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        // Ensure selection override is computed before the graph is modified.
        // Tab.close() already calls this for sidebar-initiated closes, but
        // Chromium-driven closes (CMD+W, etc.) arrive via tabWillBeRemove
        // and skip Tab.close() entirely.
        prepareForActiveTabClose(tabId: tabId)

        // When an AI Chat tab closes, also clear its association and close the linked content tab.
        for (identifier, aiTab) in aiChatTabs {
            if aiTab.guid == tabId {
                aiChatTabs.removeValue(forKey: identifier)
                closeAssociatedTab(for: identifier)
                return
            }
        }
        
        // Resolve the normal tab after AI Chat-tab handling has been ruled out.
        guard let closedTab = tabs.first(where: { $0.guid == tabId }) else { return }

        // Close the linked AI Chat synchronously. EventBus already hops through a
        // `Task @MainActor`, so we are no longer inside Chromium's tab strip
        // change callback and can call `WebContentWrapper.close()` directly.
        let identifier = getTabIdentifier(for: closedTab)
        if let group = splitGroup(forTabId: closedTab.guid),
           let partnerId = group.partnerTabId(of: closedTab.guid),
           let survivor = tabs.first(where: { $0.guid == partnerId }),
           aiChatTabs[identifier] != nil {
            // Closing pane owns the split's shared chat tab → hand it to the
            // surviving pane instead of closing it (follow survivor).
            migrateAIChatTab(fromIdentifier: identifier,
                             toIdentifier: getTabIdentifier(for: survivor))
        } else {
            closeAIChatTab(for: identifier)
        }
        
        // Remove the tab from pinned state if it was mirrored there.
        if let localGuid = closedTab.guidInLocalDB,
           let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == localGuid }) {
            pinnedTab.isOpenned = false
            pinnedTab.guid = -1
            pinnedTab.setWebContentsWrapper(wrapper: nil)
            if let originalUrl = pinnedTab.pinnedUrl {
                pinnedTab.url = originalUrl
            }
        }
        
        // Clear bookmark open-state linkage if this tab came from a bookmark.
        handleBookmarkTabClosed(closedTab)

        tabSwitchManager.removeTab(tabID: tabId)

        // Remove the tab from the in-memory list after linked state is updated.
        tabs.removeAll { $0.guid == tabId }
        let closedChildren = nativeRelationGraph.directChildren(of: tabId)
        AppLogDebug(
            "[NativeTab] closeTab tabId=\(tabId) children=\(closedChildren) " +
            "graphBefore={openers=\(nativeRelationGraph.openerByTabId), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds)}"
        )
        nativeRelationGraph.fixOpenersAfterMovingTab(tabId)
        for childId in closedChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }
        nativeRelationGraph.removeTab(tabId)
        AppLogDebug(
            "[NativeTab] closeTab graphAfter={openers=\(nativeRelationGraph.openerByTabId), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds)}"
        )
        updateNormalTabs()
        validateActiveGroupOverview()
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        AppLogDebug("[NativeTab] ⏱ closeTab tabId=\(tabId) took \(String(format: "%.2f", elapsed))ms")
    }
    
    // =========================================================================
    // Tab groups (Chromium → Mac state)
    //
    // Routed in via `EventBus.handleTabGroupEvent`. Source of truth lives in
    // Chromium; these handlers only mirror the visible state used by the
    // sidebar UI.
    // =========================================================================

    @MainActor
    func handleTabGroupCreated(token: String,
                               title: String,
                               color: GroupColor,
                               isCollapsed: Bool,
                               initialTabIds: [Int]) {
        AppLogDebug(
            "[TAB_GROUPS] groupCreated windowId=\(windowId) token=\(token) " +
            "title=\"\(title)\" color=\(color.rawValue) isCollapsed=\(isCollapsed) " +
            "initialTabIds=\(initialTabIds)"
        )
        let info = WebContentGroupInfo(token: token,
                                       title: title,
                                       color: color,
                                       isCollapsed: isCollapsed)
        groups[token] = info

        // Sync membership on each initial tab. Chromium fires kCreated before
        // any kJoined for the seed tabs, so this is where they first learn
        // their group token. Tabs that haven't arrived via
        // `handleNewTabFromChromium` yet are stashed in `pendingGroupClaims`
        // for backfill on arrival.
        for tabId in initialTabIds {
            if let tab = tabs.first(where: { $0.guid == tabId }) {
                tab.groupToken = token
            } else {
                pendingGroupClaims[tabId] = token
            }
        }
    }

    @MainActor
    func handleTabGroupVisualDataChanged(token: String,
                                         title: String,
                                         color: GroupColor,
                                         isCollapsed: Bool) {
        guard let info = groups[token] else {
            AppLogWarn(
                "[TAB_GROUPS] visualDataChanged for unknown token=\(token) " +
                "windowId=\(windowId); ignoring"
            )
            return
        }
        AppLogDebug(
            "[TAB_GROUPS] visualDataChanged windowId=\(windowId) token=\(token) " +
            "title=\"\(title)\" color=\(color.rawValue) isCollapsed=\(isCollapsed)"
        )
        if info.title != title { info.title = title }
        if info.color != color { info.color = color }
        if info.isCollapsed != isCollapsed { info.isCollapsed = isCollapsed }
    }

    @MainActor
    func handleTabGroupClosed(token: String) {
        AppLogDebug("[TAB_GROUPS] groupClosed windowId=\(windowId) token=\(token)")
        clearGroupOverview(ifToken: token)
        groups.removeValue(forKey: token)
        // Defensive: any tab that still claims this token gets cleared. In
        // normal flow Chromium fires kLeft for each member before kClosed,
        // but this guards against any reordering races.
        for tab in tabs where tab.groupToken == token {
            tab.groupToken = nil
        }
        // Drop any stashed claims that would resurrect membership for a
        // late-arriving tab once the group is gone.
        pendingGroupClaims = pendingGroupClaims.filter { $0.value != token }
    }

    @MainActor
    func handleTabJoinedGroup(tabId: Int, token: String) {
        AppLogDebug(
            "[TAB_GROUPS] tabJoinedGroup windowId=\(windowId) tabId=\(tabId) token=\(token)"
        )
        guard let info = groups[token] else {
            // kCreated raced behind kJoined (rare). Stash so the new-tab
            // handler or a later kCreated can backfill.
            pendingGroupClaims[tabId] = token
            AppLogWarn(
                "[TAB_GROUPS] tabJoinedGroup before group exists " +
                "windowId=\(windowId) tabId=\(tabId) token=\(token); stashed"
            )
            return
        }
        if let tab = tabs.first(where: { $0.guid == tabId }) {
            tab.groupToken = token
            _ = consumePendingNormalTabInsertion(for: tab)
            relocateJoinerIntoGroupRun(tabId: tabId, token: token)
            // Tab.groupToken is @Published but the sidebar's
            // TabSectionController doesn't subscribe per-tab; nudge the
            // group's objectWillChange so the wrapper re-resolves children
            // / count.
            info.objectWillChange.send()
        } else {
            pendingGroupClaims[tabId] = token
        }
    }

    /// Keeps a group's members contiguous in `normalTabOrder` after a
    /// tab joins. New tabs created via Chromium's
    /// `createTabInGroup` (and the join flow generally) are appended
    /// to `normalTabOrder` by `updateNormalTabs`, so a group whose
    /// other members already sit elsewhere in the strip ends up
    /// non-contiguous (e.g. [grey, blue, newGrey]). The horizontal
    /// strip's `currentGroupRuns` then produces multiple runs for the
    /// same token, the layout engine reserves a chip slot at every
    /// run start, but `chipFrames[token]` only carries the last
    /// run's frame — the earlier slot ends up as empty padding and
    /// the first member appears "orphaned" without a chip in front.
    /// Move the joiner so its index sits immediately after the
    /// existing last member.
    private func relocateJoinerIntoGroupRun(tabId: Int, token: String) {
        guard let currentIdx = normalTabOrder.firstIndex(of: tabId) else { return }
        // If the joiner is already next to an existing member of the
        // same group, the run is contiguous as-is — preserve the
        // joiner's current position. Important for the drag-drop
        // auto-join path, where the user just chose where to insert
        // the tab (e.g. on the group's leading edge); forcing it to
        // the trailing edge would override that choice.
        let leftIsMember = currentIdx > 0
            && tabs.first(where: { $0.guid == normalTabOrder[currentIdx - 1] })?.groupToken == token
        let rightIsMember = currentIdx + 1 < normalTabOrder.count
            && tabs.first(where: { $0.guid == normalTabOrder[currentIdx + 1] })?.groupToken == token
        if leftIsMember || rightIsMember { return }

        var lastOtherIdx: Int?
        for (idx, guid) in normalTabOrder.enumerated() where idx != currentIdx {
            guard let other = tabs.first(where: { $0.guid == guid }),
                  other.groupToken == token else { continue }
            if lastOtherIdx == nil || idx > lastOtherIdx! {
                lastOtherIdx = idx
            }
        }
        guard let lastOther = lastOtherIdx else { return }
        // Post-removal indexing: removing currentIdx shifts everything
        // after it down by one, so when the joiner was *after* the
        // last member we re-insert at lastOther+1, otherwise at
        // lastOther (which used to be lastOther but the removal moves
        // it to lastOther-1, so +1 lands right after it).
        let targetIdx = (currentIdx < lastOther) ? lastOther : (lastOther + 1)
        normalTabOrder.remove(at: currentIdx)
        normalTabOrder.insert(tabId, at: targetIdx)
        AppLogDebug(
            "[TAB_GROUPS] relocated joiner tabId=\(tabId) " +
            "from=\(currentIdx) to=\(targetIdx) token=\(token)"
        )
        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }
    }

    @MainActor
    func handleTabLeftGroup(tabId: Int, token: String) {
        AppLogDebug(
            "[TAB_GROUPS] tabLeftGroup windowId=\(windowId) tabId=\(tabId) token=\(token)"
        )
        if let tab = tabs.first(where: { $0.guid == tabId }),
           tab.groupToken == token {
            tab.groupToken = nil
            // The tab just dropped its membership but its position
            // in normalTabOrder is unchanged. If it was a *middle*
            // member, the remaining members on either side now
            // straddle a non-member, splitting the group's
            // contiguous run. `currentGroupRuns` would emit two
            // runs sharing the same token, and
            // `layoutNormalWithGroups` would render two chip slots
            // for one chip view — leaving an empty slot at the
            // first run and visually orphaning the early member.
            //
            // Mirror of the inserted-non-member fix: treat the
            // freshly-detached tab as an interloper and slide it
            // past the group's last remaining member so the run
            // stays unbroken.
            relocateInterloperOutOfGroupRun(tabGuid: tabId)
            updateNormalTabs()
        }
        // Drop any stale claim for this tab so a future arrival doesn't
        // resurrect the membership.
        if pendingGroupClaims[tabId] == token {
            pendingGroupClaims.removeValue(forKey: tabId)
        }
        guard let info = groups[token] else { return }
        // If the last member left and Chromium hasn't (yet) fired kClosed,
        // drop the entry so the sidebar doesn't carry an empty header.
        // Membership is now derived from `tab.groupToken`, so check the
        // live tab list.
        let stillHasMember = tabs.contains { $0.groupToken == token }
        if !stillHasMember {
            groups.removeValue(forKey: token)
        } else {
            info.objectWillChange.send()
        }
        validateActiveGroupOverview()
    }

    /// Drains any pending group claim for `tab.guid` left by a kCreated /
    /// kJoined that arrived before the tab itself. Call from
    /// `handleNewTabFromChromium` after the tab is appended to `tabs`.
    private func drainPendingGroupClaim(for tab: Tab) {
        guard let token = pendingGroupClaims.removeValue(forKey: tab.guid) else { return }
        guard let info = groups[token] else {
            AppLogWarn(
                "[TAB_GROUPS] pending claim drained for tabId=\(tab.guid) " +
                "but group token=\(token) no longer exists; ignoring"
            )
            return
        }
        AppLogDebug(
            "[TAB_GROUPS] backfill from pending claim windowId=\(windowId) " +
            "tabId=\(tab.guid) token=\(token)"
        )
        tab.groupToken = token
        relocateJoinerIntoGroupRun(tabId: tab.guid, token: token)
        info.objectWillChange.send()
    }

    func closeTabs(keeping: Set<Int>) {
        // Expand the keep-set to cover the partner pane of any split the user
        // is keeping — "Close Other Tabs" should leave the whole splitview
        // intact rather than dissolve it into a single pane.
        var keep = keeping
        for tabId in keeping {
            if let group = splitGroup(forTabId: tabId) {
                keep.insert(group.primaryTabId)
                keep.insert(group.secondaryTabId)
            }
        }
        for tab in tabs {
            if !keep.contains(tab.guid) {
                tab.close()
            }
        }
    }

    // =========================================================================
    // Flicker fix: Tab visibility synchronization
    // =========================================================================

    /// Called when Chromium has hidden the previous WebContents and it's ready for cleanup.
    /// This is part of the flicker fix - we defer cleanup until Chromium confirms the old tab is hidden.
    func handlePreviousTabReadyForCleanup(tabId: Int) {
        AppLogDebug("[Tab] handlePreviousTabReadyForCleanup: tabId=\(tabId)")
        windowController?.handlePreviousTabReadyForCleanup(tabId: tabId)
    }

    /// Called when a new tab has completed its first visually non-empty paint.
    /// Mac should bring the new tab's view to the front.
    func handleTabReadyToDisplay(tabId: Int) {
        // AppLogDebug("[FlickerFix][BrowserState] handleTabReadyToDisplay: tabId=\(tabId)")

        // Mark the tab as having completed first paint
        if let tab = tabs.first(where: { $0.guid == tabId }) {
            tab.hasFirstPaint = true
            // AppLogDebug("[FlickerFix][BrowserState] Set hasFirstPaint=true for tabId=\(tabId)")
        }

        windowController?.handleTabReadyToDisplay(tabId: tabId)
    }

    /// Called when a tab enters/exits HTML5 content fullscreen. Writes the
    /// new state onto the Tab so the owning WebContentViewController can
    /// observe and re-parent its hostView.
    func handleTabContentFullscreen(tabId: Int, isFullscreen: Bool) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else {
            return
        }
        if tab.isInContentFullscreen != isFullscreen {
            tab.isInContentFullscreen = isFullscreen
        }
    }
    
    func toggleTabPinStatus(_ tabId: Int, guidInDB: String?) {
        if let opennedTab = tabs.first(where: { $0.guid == tabId }) {
            // A bookmark-backed tab is not pinned yet still carries a non-empty
            // guidInLocalDB (the bookmark GUID). The branch below treats any
            // non-empty guidInLocalDB as "already pinned" and would unpin it,
            // which severs the bookmark binding and leaves the tab neither
            // pinned nor bookmarked. Pin it like a normal tab instead: a fresh
            // pinned-record GUID is minted and the live tab retargeted, while
            // the original bookmark (a separate record keyed by its own GUID)
            // is left in place.
            if !opennedTab.isPinned,
               let bookmarkGuid = opennedTab.guidInLocalDB, !bookmarkGuid.isEmpty,
               bookmarkManager.bookmark(withGuid: bookmarkGuid) != nil {
                moveNormalTab(tabId: opennedTab.guid, toPinnd: -1, selectAfterMove: opennedTab.isActive)
                opennedTab.isPinned = true
                updateNormalTabs()
                return
            }
            if opennedTab.isPinned || opennedTab.guidInLocalDB?.isEmpty == false {
                if let pinnedGuid = opennedTab.guidInLocalDB,
                   let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
                   pinnedSplitDBPair(forPinnedTab: pinnedTab) != nil {
                    movePinnedTabOut(pinnedGuid: pinnedGuid,
                                     to: normalTabOrder.count,
                                     selectAfterMove: opennedTab.isActive)
                    return
                }

                // Migrate AI Chat tab association before changing identifier
                // When unpinning, identifier changes from guidInLocalDB to chromium guid
                migrateAIChatTab(for: opennedTab, toNewIdentifier: nil)

                clearPinnedSplitPartnerReference(forPinnedGuid: opennedTab.guidInLocalDB)
                localStore.removePinnedTab(opennedTab)
                opennedTab.guidInLocalDB = nil
                if let wrapper = opennedTab.webContentWrapper {
                    wrapper.updateTabCustomValue("")
                }
                opennedTab.isPinned = false
                insertIntoNormalTabOrder(tabGuid: opennedTab.guid,
                                         at: normalTabOrder.count,
                                         syncChromiumOrder: true)
            } else {
                // create Local tab
                // Note: moveNormalTab already handles AI Chat tab migration
                moveNormalTab(tabId: opennedTab.guid, toPinnd: -1, selectAfterMove: opennedTab.isActive)
                opennedTab.isPinned = true
                updateNormalTabs()
            }
        } else if let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == guidInDB }) {
            // Unopened pinned split: the record being unpinned has a partner
            // record in `pinnedTabs`. Route through the persistence-aware path
            // so both halves are removed and reopened together as a split
            // instead of orphaning the partner and creating a single tab.
            if let myDB = pinnedTab.guidInLocalDB,
               let partnerGuid = pinnedTab.splitPartnerGuid, !partnerGuid.isEmpty,
               pinnedTabs.contains(where: { $0.guidInLocalDB == partnerGuid }) {
                let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedTab) ?? (myDB, partnerGuid)
                MainActor.assumeIsolated {
                    unpinClosedPinnedSplit(leftDB: leftDB, rightDB: rightDB)
                }
                return
            }
            clearPinnedSplitPartnerReference(forPinnedGuid: pinnedTab.guidInLocalDB)
            localStore.removePinnedTab(pinnedTab)
            createTab(pinnedTab.url ?? "", customGuid: nil, focusAfterCreate: false)
        }
    }

    /// When a pinned tab is about to be removed, clear the partner record's
    /// reverse pointer so a dangling `splitPartnerGuid` doesn't survive in the
    /// DB. The partner's in-memory record is also updated so the sidebar drops
    /// the merged-cell rendering immediately.
    private func clearPinnedSplitPartnerReference(forPinnedGuid pinnedGuid: String?) {
        guard let pinnedGuid,
              let owner = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
              let partnerGuid = owner.splitPartnerGuid,
              !partnerGuid.isEmpty else {
            return
        }
        owner.splitPartnerGuid = nil
        if let partner = pinnedTabs.first(where: { $0.guidInLocalDB == partnerGuid }) {
            partner.splitPartnerGuid = nil
        }
        localStore.updateTabSplitPartner(partnerGuid, partnerGuid: nil)
    }
    
    func createTab(_ url: String?, customGuid: String? = nil, focusAfterCreate: Bool = true) {
        AppLogDebug("🪟 [Restore] createTab request windowId=\(windowId) focus=\(focusAfterCreate) url=\(url ?? "") customGuid=\(customGuid ?? "nil")")
        let focusingTabText = focusingTab?.guid ?? -1
        AppLogDebug(
            "[NativeTab] mac createTab " +
            "windowId=\(windowId) url=\(url ?? "") focusAfterCreate=\(focusAfterCreate) " +
            "focusingTab=\(focusingTabText) normalOrder=\(normalTabOrder)"
        )
        ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url ?? "",
                                                               windowId: windowId.int64Value,
                                                               customGuid: customGuid,
                                                               focusAfterCreate: focusAfterCreate)
    }

    func createQuickLookupTab(customGuid: String? = nil) {
        let focusingTabText = focusingTab?.guid ?? -1
        AppLogDebug(
            "[NativeTab] mac createQuickLookupTab " +
            "windowId=\(windowId) focusingTab=\(focusingTabText) normalOrder=\(normalTabOrder)"
        )
        ChromiumLauncher.sharedInstance().bridge?.createQuickLookupTab(withWindowId: windowId.int64Value,
                                                                       customGuid: customGuid)
    }
    
    func openTab(_ url: String?) {
        ChromiumLauncher.sharedInstance().bridge?.openTab(withUrl: url ?? "", windowId: windowId.int64Value)
    }
    
    func updateTabTitle(tabId: Int, newTitle: String) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else {
            AppLogWarn("tab not found for id: \(tabId)")
            return
        }
        if tab.title != newTitle {
            tab.title = newTitle
            self.tabs = tabs
        }
    }
    
    func reorderTabs(_ indexesMap: [Int: Int]) {
        tabs.forEach { tab in
            if let index = indexesMap[tab.guid] {
                tab.setIndex(index)
            }
        }
        let sorted = tabs.sorted { $0.index < $1.index }
        if sorted != tabs {
            tabs = sorted
        }
        // updateNormalTabs() is sticky-by-design (only appends new guids,
        // only removes vanished ones) so local drag reorders survive an
        // in-flight tabIndicesUpdated. But Chromium-initiated reorders that
        // touch only existing tabs — e.g. ReverseTabsInSplit swapping the
        // two members of a split — would otherwise never reach the sidebar
        // or tab strip: the panes swap visually via splitContentsChanged,
        // but normalTabOrder keeps the pre-reverse sequence. Re-sequence
        // existing entries to match Chromium's authoritative order here.
        let cachedSet = Set(normalTabOrder)
        let resequenced = tabs.compactMap { cachedSet.contains($0.guid) ? $0.guid : nil }
        let protectedTabIds = nativeOrderProtectedTabIds.intersection(cachedSet)
        if resequenced == normalTabOrder {
            nativeOrderProtectedTabIds.subtract(protectedTabIds)
        } else if protectedTabIds.isEmpty {
            normalTabOrder = resequenced
        } else {
            var mergedOrder = resequenced.filter { !protectedTabIds.contains($0) }
            let protectedPositions = normalTabOrder.enumerated()
                .filter { protectedTabIds.contains($0.element) }
            for (index, tabId) in protectedPositions {
                mergedOrder.insert(tabId, at: min(index, mergedOrder.count))
            }
            if mergedOrder != normalTabOrder {
                normalTabOrder = mergedOrder
            }
            AppLogDebug(
                "[NativeTab] reorderTabs preserved protected native slots " +
                "protected=\(Array(protectedTabIds).sorted()) resequenced=\(resequenced) " +
                "normalOrder=\(normalTabOrder)"
            )
            nativeOrderProtectedTabIds.subtract(protectedTabIds)
        }
        updateNormalTabs()
    }
    
    func move(tab: Tab, to newIndex: Int, selectAfterMove: Bool) {
        guard let wrapper = tab.webContentWrapper else {
            return
        }
        wrapper.moveSelf(to: newIndex, selectAfterMove: selectAfterMove)
    }
    
    /// Reorders all members of a tab group as a contiguous block inside
    /// `normalTabs`. Mirrors `moveNormalTabLocally`'s splice + opener-graph
    /// hygiene, then notifies Chromium so its TabGroupModel stays aligned.
    ///
    /// - Parameters:
    ///   - token: Hex token of the group to move.
    ///   - toIndex: Destination insertion index inside `normalTabs`,
    ///     interpreted in the *pre-move* coordinate system (NSOutlineView
    ///     convention; same semantics as `moveNormalTabLocally`'s `toIndex`).
    @MainActor
    func moveGroupBlock(token: String, to toIndex: Int) {
        // Members carry their order through their position in normalTabOrder;
        // the resolver guarantees membership is contiguous, but we don't rely
        // on that here — gather positions and splice the block as-is.
        let memberPositions: [Int] = normalTabOrder.enumerated().compactMap { idx, guid in
            guard let tab = tabs.first(where: { $0.guid == guid }),
                  tab.groupToken == token else { return nil }
            return idx
        }
        guard let blockStart = memberPositions.first else {
            AppLogDebug(
                "[TAB_GROUPS] moveGroupBlock no members for token=\(token); skipping"
            )
            return
        }
        let blockSize = memberPositions.count
        let memberGuids = memberPositions.map { normalTabOrder[$0] }

        // Mirror moveNormalTabLocally's `from < to` adjustment: when the
        // block moves forward, removing it shifts later indices down by
        // blockSize. When it moves backward (or stays), no adjustment.
        var insertIndex = toIndex
        if blockStart < toIndex {
            insertIndex = max(0, toIndex - blockSize)
        }
        let postRemovalCount = normalTabOrder.count - blockSize
        insertIndex = min(max(0, insertIndex), postRemovalCount)
        guard insertIndex != blockStart else { return }

        AppLogDebug(
            "[TAB_GROUPS] moveGroupBlock token=\(token) blockStart=\(blockStart) " +
            "blockSize=\(blockSize) toIndex=\(toIndex) insertIndex=\(insertIndex) " +
            "members=\(memberGuids)"
        )

        // Remove members in descending order so earlier positions remain valid.
        for pos in memberPositions.reversed() {
            normalTabOrder.remove(at: pos)
        }
        for (offset, guid) in memberGuids.enumerated() {
            normalTabOrder.insert(guid, at: insertIndex + offset)
        }

        // Opener-graph hygiene: the block as a whole crossed positions, so
        // each member's opener relationship may need re-resolution. Mirrors
        // the per-member call in moveNormalTabLocally.
        for guid in memberGuids {
            nativeRelationGraph.fixOpenersAfterMovingTab(guid)
        }

        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }

        // TODO(P5): verify the strip vs. normal-tabs index conversion. The
        // bridge expects a tab-strip index (pinned tabs occupy the front of
        // the strip), but there is no precedent in this file for the
        // translation; passing `toIndex` straight through and revisiting
        // when the drop wiring lands.
        ChromiumLauncher.sharedInstance().bridge?.moveGroup(
            withWindowId: Int64(windowId),
            tokenHex: token,
            to: NSInteger(toIndex)
        )
    }

    /// Reorders normal tabs locally and mirrors their relative order to Chromium.
    /// - Parameters:
    ///   - fromIndex: Source index inside `normalTabs`.
    ///   - toIndex: Destination insertion index inside `normalTabs`.
    ///   - syncChromiumOrder: When false, updates Mac order only so callers
    ///     can change Chromium group membership before mirroring the move.
    func moveNormalTabLocally(from fromIndex: Int,
                              to toIndex: Int,
                              syncChromiumOrder: Bool = true) {
        guard fromIndex >= 0, fromIndex < normalTabOrder.count else { return }

        // Split tabs travel as a unit. If the dragged tab is in a split, move
        // both pair members together via Chromium's MoveSplit so the split
        // collection itself relocates (instead of accidentally tearing the
        // partner away from the pair).
        let draggedGuid = normalTabOrder[fromIndex]
        if let group = splitGroup(forTabId: draggedGuid) {
            moveSplitPairOrderLocally(group: group, to: toIndex)
            return
        }

        // Refuse drops that would land strictly between the two members of a
        // split pair. Snap past the pair on whichever side matches the drag
        // direction so the pair stays contiguous.
        let snappedToIndex = snapDropOutsideSplitPair(toIndex: toIndex, fromIndex: fromIndex)
        var insertIndex = snappedToIndex
        if fromIndex < snappedToIndex {
            insertIndex = max(0, snappedToIndex - 1)
        }
        insertIndex = min(insertIndex, normalTabOrder.count)
        guard insertIndex != fromIndex else { return }

        let guid = normalTabOrder.remove(at: fromIndex)
        let affectedChildren = nativeRelationGraph.directChildren(of: guid)
        AppLogDebug(
            "[NativeTab] moveNormalTabLocally tabId=\(guid) from=\(fromIndex) to=\(insertIndex) " +
            "children=\(affectedChildren) " +
            "graphBefore={openers=\(nativeRelationGraph.openerByTabId), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds)}"
        )
        nativeRelationGraph.fixOpenersAfterMovingTab(guid)
        for childId in affectedChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }
        AppLogDebug(
            "[NativeTab] moveNormalTabLocally graphAfter={openers=\(nativeRelationGraph.openerByTabId), " +
            "localFix=\(nativeRelationGraph.locallyFixedOpenerTabIds)}"
        )

        normalTabOrder.insert(guid, at: insertIndex)

        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }

        if syncChromiumOrder {
            syncNormalTabRelativeOrderToChromium(tabId: guid)
        }
    }

    /// Reorders a contiguous slice of group members in `normalTabOrder`
    /// as a single atomic operation. The slice's group membership is
    /// invariant; only its position changes.
    ///
    /// - Parameters:
    ///   - memberIds: Member guids in source order. **Must** be
    ///     contiguous in `normalTabOrder`; otherwise the call asserts
    ///     in debug and bails out in release.
    ///   - to: Destination insertion index in `normalTabOrder`. Drops
    ///     in `[s, s+N]` (the slice's own range, inclusive of its
    ///     right edge) are no-ops — callers should already filter
    ///     these via `TabGroupDragContext.hasPositionChanged`, but the
    ///     method double-checks.
    func moveNormalTabSlice(memberIds: [Int], to: Int) {
        guard !memberIds.isEmpty,
              let firstIdx = normalTabOrder.firstIndex(of: memberIds[0]) else {
            AppLogWarn("[TabGroupDrag] moveNormalTabSlice: empty or unknown members=\(memberIds)")
            return
        }
        let n = memberIds.count
        let sourceRange = firstIdx..<(firstIdx + n)
        // Safety clamp — protects against out-of-bounds callers. Valid
        // pre-removal insertions are in [0, normalTabOrder.count].
        let clampedTo = min(max(0, to), normalTabOrder.count)
        if clampedTo != to {
            AppLogWarn("[TabGroupDrag] moveNormalTabSlice clamped to=\(to)→\(clampedTo)")
        }

        // Contiguity check: each subsequent member must sit at firstIdx + offset.
        for offset in 0..<n {
            let expectedIdx = firstIdx + offset
            guard expectedIdx < normalTabOrder.count,
                  normalTabOrder[expectedIdx] == memberIds[offset] else {
                assertionFailure(
                    "[TabGroupDrag] moveNormalTabSlice non-contiguous members=\(memberIds) firstIdx=\(firstIdx)"
                )
                AppLogWarn("[TabGroupDrag] moveNormalTabSlice non-contiguous bail members=\(memberIds)")
                return
            }
        }

        // No-op for drops anywhere inside the source range (inclusive
        // of the right edge — t == s+N inserts immediately past the
        // slice's own right edge, same physical slot).
        guard clampedTo < sourceRange.lowerBound || clampedTo > sourceRange.upperBound else {
            AppLogDebug("[TabGroupDrag] moveNormalTabSlice no-op to=\(clampedTo) source=\(sourceRange)")
            return
        }

        let adjustedTo = clampedTo > sourceRange.upperBound ? clampedTo - n : clampedTo
        AppLogDebug(
            "[TabGroupDrag] moveNormalTabSlice members=\(memberIds) " +
            "source=\(sourceRange) to=\(clampedTo) adjustedTo=\(adjustedTo)"
        )

        // 1. Capture cross-slice external children — needed for
        //    locallyFixedOpenerTabIds tracking after the graph fix.
        let memberSet = Set(memberIds)
        var externalChildren: Set<Int> = []
        for m in memberIds {
            for c in nativeRelationGraph.directChildren(of: m)
            where !memberSet.contains(c) {
                externalChildren.insert(c)
            }
        }

        // 2. Mutate normalTabOrder — atomic slice remove + insert.
        normalTabOrder.removeSubrange(sourceRange)
        normalTabOrder.insert(contentsOf: memberIds, at: adjustedTo)

        // 3. Fix opener graph for cross-slice edges only; track in
        //    locallyFixedOpenerTabIds so a subsequent Chromium snapshot
        //    won't revert the local fix-up.
        nativeRelationGraph.fixOpenersAfterMovingSlice(memberSet)
        for childId in externalChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }

        // 4. Re-derive normalTabs from the new normalTabOrder.
        updateNormalTabs()

        // 5. Mirror the slice's new position to Chromium via an
        //    anchor-based batch call (`moveGroupWithWindowId:tokenHex:
        //    beforeTabId:` or `afterTabId:`). Mirrors the single-tab
        //    path's `syncNormalTabRelativeOrderToChromium`: pick the
        //    right neighbor of the slice's new range for the
        //    beforeTabId form; fall back to the left neighbor for
        //    afterTabId. Anchors are guids in `normalTabOrder`, so
        //    Chromium converts to its own TabStripModel index space
        //    server-side — Mac's `pinnedTabs.count` is intentionally
        //    not used here because it does NOT map 1:1 to Chromium's
        //    pinned region.
        guard let firstMember = tabs.first(where: { $0.guid == memberIds[0] }),
              let token = firstMember.groupToken else {
            AppLogWarn(
                "[TabGroupDrag] moveNormalTabSlice: first member has no groupToken " +
                "id=\(memberIds[0]); skipping Chromium sync"
            )
            return
        }
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let firstNewIdx = adjustedTo
        let lastNewIdx = adjustedTo + n - 1
        if lastNewIdx + 1 < normalTabOrder.count {
            let anchorTabId = normalTabOrder[lastNewIdx + 1]
            AppLogDebug(
                "[TabGroupDrag] bridge.moveGroup token=\(token) " +
                "beforeTabId=\(anchorTabId)"
            )
            bridge.moveGroup(
                withWindowId: windowId.int64Value,
                tokenHex: token,
                beforeTabId: anchorTabId.int64Value
            )
        } else if firstNewIdx > 0 {
            let anchorTabId = normalTabOrder[firstNewIdx - 1]
            AppLogDebug(
                "[TabGroupDrag] bridge.moveGroup token=\(token) " +
                "afterTabId=\(anchorTabId)"
            )
            bridge.moveGroup(
                withWindowId: windowId.int64Value,
                tokenHex: token,
                afterTabId: anchorTabId.int64Value
            )
        } else {
            AppLogDebug(
                "[TabGroupDrag] moveNormalTabSlice: slice covers entire normal " +
                "zone — no anchor available, skipping Chromium sync"
            )
        }
    }

    /// Cross-window companion to `moveNormalTabSlice`: relocates a
    /// contiguous group slice from THIS window's normal-tab list into
    /// `targetState`'s normal-tab list at `atIndex`.
    ///
    /// Unlike `moveNormalTabSlice`, this method does NOT pre-mutate
    /// this window's `normalTabOrder` — Chromium's atomic detach +
    /// insert (driven via the anchor-based bridge) fires
    /// `TabStripModelChange::kRemoved` on the source and a batched
    /// `TabStripModelChange::kInserted` on the target. The existing
    /// observers in `PhiChromiumCoordinator` propagate those events to
    /// each BrowserState's `tabs` / `normalTabOrder`; we only need to
    /// pre-stage:
    ///   (1) source-side opener-graph cleanup for cross-slice externals
    ///       (because the moved members are leaving this window
    ///       entirely — children that pointed to them must reattach to
    ///       an ancestor that stays);
    ///   (2) a `PendingGroupInsertion` on the target so its observer
    ///       can normalize `normalTabOrder` at the requested position
    ///       when the batched kInserted event arrives.
    ///
    /// WebContents transfer is owned by Chromium. Mac does NOT call
    /// `wrapper.moveSelf(toWindow:)` here — the bridge
    /// `moveGroupWithWindowId:tokenHex:toWindowId:beforeTabId:`/
    /// `afterTabId:` (Task 1's anchor-based methods) drives the
    /// detach + insert + active-tab restore atomically on Chromium's
    /// side (see `tab_groups_proxy.cc` `MoveGroupAcrossStripsImpl`).
    ///
    /// Anchor resolution mirrors `moveNormalTabSlice`'s Chromium-sync
    /// step: pick the **right neighbor** of the destination slot in
    /// target's `normalTabs` for the `beforeTabId` form; fall back to
    /// the **left neighbor** for `afterTabId`. The anchor must be a
    /// guid that lives in the TARGET strip (not the source). Target
    /// normalTabs being empty is treated as a known limitation —
    /// would require a separate "cross-window MoveGroupTo end" bridge
    /// (skipped per plan v1; tear-off to a brand-new window has its
    /// own Task 5 path).
    func moveGroupSliceToWindow(memberIds: [Int], targetState: BrowserState, atIndex: Int) {
        guard !memberIds.isEmpty,
              let firstIdx = normalTabOrder.firstIndex(of: memberIds[0]) else {
            AppLogWarn("[TabGroupDrag] moveGroupSliceToWindow empty/unknown members=\(memberIds)")
            return
        }
        let n = memberIds.count
        let sourceRange = firstIdx..<(firstIdx + n)
        let clampedAtIndex = min(max(0, atIndex), targetState.normalTabs.count)
        if clampedAtIndex != atIndex {
            AppLogWarn(
                "[TabGroupDrag] moveGroupSliceToWindow clamped atIndex=\(atIndex)→" +
                "\(clampedAtIndex) targetCount=\(targetState.normalTabs.count)"
            )
        }

        // Contiguity check — slice invariant. Bails in release if
        // members are not contiguous in source (defensive; controller
        // already snapshots `sourceRange` at drag start).
        for offset in 0..<n {
            let expectedIdx = firstIdx + offset
            guard expectedIdx < normalTabOrder.count,
                  normalTabOrder[expectedIdx] == memberIds[offset] else {
                assertionFailure(
                    "[TabGroupDrag] moveGroupSliceToWindow non-contiguous members=\(memberIds) firstIdx=\(firstIdx)"
                )
                AppLogWarn("[TabGroupDrag] moveGroupSliceToWindow non-contiguous bail members=\(memberIds)")
                return
            }
        }

        guard let firstMember = tabs.first(where: { $0.guid == memberIds[0] }),
              let token = firstMember.groupToken else {
            AppLogWarn(
                "[TabGroupDrag] moveGroupSliceToWindow: first member has no groupToken " +
                "id=\(memberIds[0])"
            )
            return
        }

        // Source-side opener-graph cleanup. Same shape as
        // `moveNormalTabSlice`: capture cross-slice external children
        // BEFORE mutation, run `fixOpenersAfterMovingSlice` to re-parent
        // them to a non-slice ancestor, then mark them in
        // `locallyFixedOpenerTabIds` so a subsequent Chromium snapshot
        // doesn't revert the local fix. The members themselves will
        // be removed from `tabs` / `normalTabOrder` by the kRemoved
        // observer once Chromium fires the cross-window detach event.
        let memberSet = Set(memberIds)
        var externalChildren: Set<Int> = []
        for m in memberIds {
            for c in nativeRelationGraph.directChildren(of: m)
            where !memberSet.contains(c) {
                externalChildren.insert(c)
            }
        }
        nativeRelationGraph.fixOpenersAfterMovingSlice(memberSet)
        for childId in externalChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }

        // Park source-side favicon bytes in the shared cross-window
        // stash so target's `handleNewTabFromChromium` can seed the
        // freshly-constructed Tab's `cachedFaviconData` before its
        // first chip-mosaic layout. See `crossWindowFaviconStash`
        // for the rationale; this call site handles the cross-window-
        // into-existing-window variant.
        Self.stashCrossWindowFavicons(forMemberIds: memberIds, in: tabs)

        // Schedule target-side insertion. The batched kInserted event
        // observed by `targetState`'s observer matches against this
        // pending entry and lands the members at `clampedAtIndex` in
        // target's `normalTabOrder`.
        targetState.scheduleGroupInsertion(memberGuids: memberIds, atIndex: clampedAtIndex)

        // Resolve anchor in target. Prefer right-neighbor (beforeTabId);
        // fall back to left-neighbor (afterTabId). Target normalTabs
        // being empty is a known v1 limitation — see method doc.
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        let srcWindowId = windowId.int64Value
        let dstWindowId = targetState.windowId.int64Value

        if clampedAtIndex < targetState.normalTabs.count {
            let anchorGuid = targetState.normalTabs[clampedAtIndex].guid
            AppLogDebug(
                "[TabGroupDrag] bridge.moveGroup src=\(srcWindowId) dst=\(dstWindowId) " +
                "token=\(token) beforeTabId=\(anchorGuid)"
            )
            bridge.moveGroup(
                withWindowId: srcWindowId,
                tokenHex: token,
                toWindowId: dstWindowId,
                beforeTabId: Int64(anchorGuid)
            )
        } else if clampedAtIndex > 0,
                  clampedAtIndex - 1 < targetState.normalTabs.count {
            let anchorGuid = targetState.normalTabs[clampedAtIndex - 1].guid
            AppLogDebug(
                "[TabGroupDrag] bridge.moveGroup src=\(srcWindowId) dst=\(dstWindowId) " +
                "token=\(token) afterTabId=\(anchorGuid)"
            )
            bridge.moveGroup(
                withWindowId: srcWindowId,
                tokenHex: token,
                toWindowId: dstWindowId,
                afterTabId: Int64(anchorGuid)
            )
        } else {
            AppLogWarn(
                "[TabGroupDrag] moveGroupSliceToWindow: target normalTabs empty " +
                "(clampedAtIndex=\(clampedAtIndex)) — no anchor available, " +
                "skipping bridge call. Source members will stay put."
            )
            // Roll back the target-side schedule so we don't leave a
            // dangling expectation if no bridge call fires.
            targetState.cancelPendingGroupInsertion()
        }
    }

    /// Tear-off variant of `moveGroupSliceToWindow`: detaches the
    /// group identified by `memberIds` from THIS window's strip into a
    /// brand-new Browser window. Chromium owns the new-window creation
    /// (`chrome::MoveGroupToNewWindow`) so Mac does not have to wait
    /// for a target `BrowserState` to be ready — the new window will
    /// appear via the existing `.mainBrowserWindowCreated` notification
    /// flow.
    ///
    /// Window placement (frame around `dropScreenLocation`) is recorded
    /// on `tabDraggingSession`'s pending-placement queue. Even though
    /// whole-group drag does NOT route through `tabDraggingSession`
    /// for its lifecycle (see plan §Task 4.4), reusing the session's
    /// placement queue avoids duplicating the
    /// `.mainBrowserWindowCreated` observer + frame-resolution logic.
    /// The session's observer was registered at app init; it picks up
    /// the next eligible new window and applies the frame.
    ///
    /// As with `moveGroupSliceToWindow`, source-side `normalTabOrder`
    /// is left alone — Chromium's kRemoved events fire and the
    /// existing source observer drops the members from `tabs` /
    /// `normalTabOrder` naturally. We do source-side opener-graph
    /// fixup eagerly because the opener graph is Mac-only state that
    /// Chromium's snapshot won't reconstitute.
    ///
    /// `@MainActor` because `tabDraggingSession` is main-actor
    /// isolated. Callers (chip drag end on the source TabStrip) are
    /// always main-actor anyway.
    @MainActor
    func moveGroupSliceToNewWindow(memberIds: [Int], dropScreenLocation: CGPoint) {
        guard !memberIds.isEmpty,
              let firstIdx = normalTabOrder.firstIndex(of: memberIds[0]) else {
            AppLogWarn("[TabGroupDrag] moveGroupSliceToNewWindow empty/unknown members=\(memberIds)")
            return
        }
        let n = memberIds.count

        // Contiguity check (defensive — controller has already
        // snapshotted sourceRange at drag start, but bail if state has
        // drifted).
        for offset in 0..<n {
            let expectedIdx = firstIdx + offset
            guard expectedIdx < normalTabOrder.count,
                  normalTabOrder[expectedIdx] == memberIds[offset] else {
                assertionFailure(
                    "[TabGroupDrag] moveGroupSliceToNewWindow non-contiguous members=\(memberIds) firstIdx=\(firstIdx)"
                )
                AppLogWarn("[TabGroupDrag] moveGroupSliceToNewWindow non-contiguous bail members=\(memberIds)")
                return
            }
        }

        guard let firstMember = tabs.first(where: { $0.guid == memberIds[0] }),
              let token = firstMember.groupToken else {
            AppLogWarn(
                "[TabGroupDrag] moveGroupSliceToNewWindow: first member has no " +
                "groupToken id=\(memberIds[0])"
            )
            return
        }

        // Source-side opener-graph cleanup (same shape as
        // `moveGroupSliceToWindow`).
        let memberSet = Set(memberIds)
        var externalChildren: Set<Int> = []
        for m in memberIds {
            for c in nativeRelationGraph.directChildren(of: m)
            where !memberSet.contains(c) {
                externalChildren.insert(c)
            }
        }
        nativeRelationGraph.fixOpenersAfterMovingSlice(memberSet)
        for childId in externalChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }

        // Record placement so the upcoming `.mainBrowserWindowCreated`
        // observer (registered at session init) can frame the new
        // window around the drop point. Provide the source NSWindow so
        // the matcher in `handleMainBrowserWindowCreated` skips the
        // source window (defensive — Chromium creates a brand-new
        // window so the source NSWindow shouldn't fire that event, but
        // belt-and-suspenders).
        let sourceWindow = windowController?.window
        tabDraggingSession.recordPendingTearOffWindowPlacement(
            screenLocation: dropScreenLocation,
            sourceWindow: sourceWindow
        )

        // Park source-side favicon bytes in the shared cross-window
        // stash so the new window's `handleNewTabFromChromium` can
        // seed each freshly-constructed Tab's `cachedFaviconData`
        // before its first chip-mosaic layout. The new BrowserState
        // doesn't exist yet at this call site, so the per-pending-
        // insertion dict used by `moveGroupSliceToWindow` isn't an
        // option here; the global guid-keyed stash works for both.
        Self.stashCrossWindowFavicons(forMemberIds: memberIds, in: tabs)

        // Fire Chromium-side atomic "create new Browser + detach group +
        // insert at index 0 + show window". The new Browser inherits
        // this profile; window placement is applied by the session
        // observer when `.mainBrowserWindowCreated` fires.
        guard let bridge = ChromiumLauncher.sharedInstance().bridge else { return }
        AppLogDebug(
            "[TabGroupDrag] bridge.moveGroupToNewWindow src=\(windowId) " +
            "token=\(token) members=\(memberIds) dropScreen=\(dropScreenLocation)"
        )
        bridge.moveGroupToNewWindow(
            withWindowId: windowId.int64Value,
            tokenHex: token
        )
    }

    /// Reorder a split pair as a unit. Called from `moveNormalTabLocally` when
    /// the dragged tab is part of a split — both members travel together so
    /// the split collection stays intact, and Chromium's `MoveSplit` is used
    /// instead of per-tab `moveTab` (which would otherwise tear the pair).
    ///
    /// `toIndex` is the destination index the drop layer requested for the
    /// dragged tab; drop positions that fall on or between the two pair
    /// members are treated as no-ops since "between" would mean splitting.
    func moveSplitPairOrderLocally(group: SplitGroup, to toIndex: Int) {
        let primary = group.primaryTabId
        let secondary = group.secondaryTabId
        guard let primaryIdx = normalTabOrder.firstIndex(of: primary),
              let secondaryIdx = normalTabOrder.firstIndex(of: secondary) else {
            return
        }
        let pairMin = min(primaryIdx, secondaryIdx)
        let pairMax = max(primaryIdx, secondaryIdx)
        let pairGuidsInOrder: [Int] = primaryIdx < secondaryIdx
            ? [primary, secondary]
            : [secondary, primary]

        // Snap drops that would land strictly between the two members of
        // *another* split pair. The per-tab path does this via
        // `snapDropOutsideSplitPair` from `moveNormalTabLocally`, but the
        // split-as-a-unit branch took an early `return` before that snap
        // ran — so a drag-out-of-group that happened to release on an
        // unrelated adjacent split sent an unsnapped index to the bridge,
        // and Chromium's `TabStripModel::MoveSplitTo` aborted on
        // `CHECK(!destination_split.has_value())` (the contiguity guard
        // in `MoveBreaksSplitContiguity`). Passing `pairMin` as
        // `fromIndex` is safe: splits cannot overlap, so our pair sits
        // entirely on one side of any other split, and the snap picks
        // the side that matches the drag direction.
        let snappedToIndex = snapDropOutsideSplitPair(toIndex: toIndex, fromIndex: pairMin)

        // Drop on or inside the pair's current span → nothing to do.
        if snappedToIndex >= pairMin && snappedToIndex <= pairMax + 1 {
            return
        }

        // Remove both members; insert them adjacent at the adjusted index.
        var newOrder = normalTabOrder
        newOrder.removeAll { $0 == primary || $0 == secondary }

        var insertIndex: Int
        if snappedToIndex > pairMax {
            insertIndex = snappedToIndex - 2
        } else {
            insertIndex = snappedToIndex
        }
        insertIndex = max(0, min(insertIndex, newOrder.count))

        // `insertIndex` is a `normalTabOrder` index, which excludes pinned
        // and bookmark-bound tabs even though those still occupy Chromium
        // strip slots. `moveSplit` → `TabStripModel::MoveSplitTo` expects a
        // full strip index (the block's final post-removal position), so the
        // two spaces diverge whenever such tabs exist — passing the normal
        // index straight through lands the split too far left (or, once
        // `ConstrainMoveIndex` clamps it past the pinned region, at the start
        // of the normal section). Translate via the anchor tab's
        // authoritative Chromium index (`tab.index`, maintained by
        // `UpdateTabIndices` over the entire strip). Resolving from a real
        // tab is robust to whatever is hidden ahead of *or interspersed
        // within* the normal section; a flat pinned-count offset would miss
        // bookmark tabs sitting between visible normal tabs. The pair's own
        // strip indices are subtracted when they sit left of the anchor
        // because Chromium reports the destination after the pair is removed.
        func stripIndexOf(_ guid: Int) -> Int? {
            tabs.first(where: { $0.guid == guid })?.index
        }
        let pairStrips = [primary, secondary].compactMap { stripIndexOf($0) }
        func removedLeftOf(_ stripIndex: Int) -> Int {
            pairStrips.filter { $0 < stripIndex }.count
        }
        let stripToIndex: Int?
        if insertIndex < newOrder.count, let anchor = stripIndexOf(newOrder[insertIndex]) {
            stripToIndex = anchor - removedLeftOf(anchor)
        } else if let last = newOrder.last, let anchor = stripIndexOf(last) {
            stripToIndex = anchor - removedLeftOf(anchor) + 1
        } else {
            stripToIndex = nil
        }
        guard let stripToIndex else { return }

        newOrder.insert(contentsOf: pairGuidsInOrder, at: insertIndex)
        normalTabOrder = newOrder
        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }

        ChromiumLauncher.sharedInstance().bridge?.moveSplit(
            group.id,
            to: Int32(stripToIndex),
            windowId: windowId.int64Value)
    }

    func syncNormalTabsRelativeOrderToChromium(tabIds: [Int]) {
        for tabId in tabIds {
            syncNormalTabRelativeOrderToChromium(tabId: tabId)
        }
    }

    private func syncNormalTabRelativeOrderToChromium(tabId: Int) {
        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              let movedIndex = normalTabOrder.firstIndex(of: tabId) else {
            return
        }

        if movedIndex + 1 < normalTabOrder.count {
            let anchorTabId = splitSafeBeforeAnchorTabId(
                normalTabOrder[movedIndex + 1])
            bridge.moveTab(withWindowId: windowId.int64Value,
                           tabId: tabId.int64Value,
                           beforeTabId: anchorTabId.int64Value)
            return
        }

        if movedIndex > 0 {
            let anchorTabId = splitSafeAfterAnchorTabId(
                normalTabOrder[movedIndex - 1])
            bridge.moveTab(withWindowId: windowId.int64Value,
                           tabId: tabId.int64Value,
                           afterTabId: anchorTabId.int64Value)
        }
    }

    private func splitSafeBeforeAnchorTabId(_ anchorTabId: Int) -> Int {
        guard let group = splitGroup(forTabId: anchorTabId),
              let partnerId = group.partnerTabId(of: anchorTabId),
              let anchorIndex = normalTabOrder.firstIndex(of: anchorTabId),
              let partnerIndex = normalTabOrder.firstIndex(of: partnerId),
              abs(partnerIndex - anchorIndex) == 1,
              partnerIndex < anchorIndex else {
            return anchorTabId
        }
        return partnerId
    }

    private func splitSafeAfterAnchorTabId(_ anchorTabId: Int) -> Int {
        guard let group = splitGroup(forTabId: anchorTabId),
              let partnerId = group.partnerTabId(of: anchorTabId),
              let anchorIndex = normalTabOrder.firstIndex(of: anchorTabId),
              let partnerIndex = normalTabOrder.firstIndex(of: partnerId),
              abs(partnerIndex - anchorIndex) == 1,
              partnerIndex > anchorIndex else {
            return anchorTabId
        }
        return partnerId
    }
    
    func scheduleNormalTabInsertion(tabGuid: Int, at index: Int) {
        pendingNormalTabInsertion = PendingNormalTabInsertion(url: nil,
                                                              guid: tabGuid,
                                                              expectedGroupToken: nil,
                                                              index: index,
                                                              syncChromiumOrder: true)
    }

    func scheduleNextNormalTabInsertion(at index: Int,
                                        syncChromiumOrder: Bool,
                                        expectedGroupToken: String? = nil) {
        if pendingNormalTabInsertion != nil {
            AppLogWarn("[NativeTab] overriding pending normal tab insertion windowId=\(windowId)")
        }
        pendingNormalTabInsertion = PendingNormalTabInsertion(url: "",
                                                              guid: nil,
                                                              expectedGroupToken: expectedGroupToken,
                                                              index: index,
                                                              syncChromiumOrder: syncChromiumOrder)
    }

    @discardableResult
    private func consumePendingNormalTabInsertion(for tab: Tab) -> Bool {
        guard let pending = pendingNormalTabInsertion,
              pending.matches(tab: tab) else {
            return false
        }
        insertIntoNormalTabOrder(tabGuid: tab.guid,
                                 at: pending.index,
                                 syncChromiumOrder: pending.syncChromiumOrder)
        pendingNormalTabInsertion = nil
        return true
    }

    /// Source-driven companion: called by another window's
    /// `moveGroupSliceToWindow` before firing Chromium's atomic
    /// detach + insert. This (target) state's
    /// `handleNewTabFromChromium` consumes the pending entry as
    /// member tabs arrive, landing them at the requested base index.
    /// See `PendingGroupInsertion` doc for details.
    func scheduleGroupInsertion(memberGuids: [Int], atIndex: Int) {
        pendingGroupInsertion = PendingGroupInsertion(
            memberGuids: Set(memberGuids),
            atIndex: atIndex,
            arrivedCount: 0,
            requestedAt: Date()
        )
        AppLogDebug(
            "[TabGroupDrag] scheduleGroupInsertion windowId=\(windowId) " +
            "members=\(memberGuids) atIndex=\(atIndex)"
        )
    }

    /// Drop the pending group insertion. Used when the source side
    /// decides not to fire the bridge after all (e.g. no anchor
    /// available in target). Leaving a dangling entry would interfere
    /// with subsequent legitimate insertions in this target.
    func cancelPendingGroupInsertion() {
        if pendingGroupInsertion != nil {
            AppLogDebug("[TabGroupDrag] cancelPendingGroupInsertion windowId=\(windowId)")
            pendingGroupInsertion = nil
        }
    }

    // MARK: - Cross-window favicon stash

    /// Shared cross-window favicon stash, keyed by Chromium tab guid.
    /// Written by the source-side cross-window / tear-off paths just
    /// before firing the Chromium bridge call; read and consumed by
    /// ANY BrowserState's `handleNewTabFromChromium` when the
    /// corresponding kInserted lands the tab on the destination side.
    ///
    /// Why a global static rather than per-BrowserState state: the
    /// tear-off path creates a brand-new BrowserState that doesn't
    /// exist when the source fires the bridge, so the per-target
    /// `pendingGroupInsertion` channel isn't reachable. Tab guids are
    /// stable across cross-window moves (WebContents identity, not
    /// TabStripModel slot), so a guid-keyed global lookup serves both
    /// cross-window-into-existing AND tear-off without forking the
    /// mechanism.
    ///
    /// Why the destination wrapper can't supply the favicon itself:
    /// the bridge wrapper on the destination side is a fresh ObjC
    /// instance whose `favIconData` starts at nil, and Chromium fires
    /// favicon KVO only on actual favicon changes — cross-window
    /// WebContents transfer is not such a change. Without this seed
    /// the chip mosaic stays blank for normal sites until the user
    /// re-navigates a member. NTP / `phi://` / `chrome://` slots are
    /// unaffected because their URL classifier in
    /// `collectMosaicFaviconData` returns the shared default bytes
    /// regardless of Tab favicon state.
    ///
    /// Stale entries (>`crossWindowFaviconStashTimeoutSeconds`) are
    /// evicted lazily on the next consume — defensive against drag
    /// paths where Chromium rejects or never fires the move.
    ///
    /// Concurrency: all callers (drag-end on the source strip, EventBus
    /// dispatch on the destination) run on the main thread by the
    /// project-wide convention shared with the rest of `BrowserState`.
    /// We don't mark these `@MainActor` because peer instance methods
    /// (`handleNewTabFromChromium`, `moveGroupSliceToWindow`,
    /// `moveTabToWindowJoiningGroup`) are nonisolated and would
    /// otherwise need to await, which the existing call chains don't
    /// support.
    private static var crossWindowFaviconStash: [Int: (data: Data, requestedAt: Date)] = [:]
    private static let crossWindowFaviconStashTimeoutSeconds: TimeInterval = 4.0

    /// Capture `liveFaviconData ?? cachedFaviconData` for each of
    /// `memberIds` from `sourceTabs` and write the non-nil bytes into
    /// the shared cross-window favicon stash. Called by both
    /// `moveGroupSliceToWindow` and `moveGroupSliceToNewWindow`
    /// immediately before firing their respective bridge calls.
    static func stashCrossWindowFavicons(forMemberIds memberIds: [Int], in sourceTabs: [Tab]) {
        let now = Date()
        var stashed = 0
        for memberId in memberIds {
            guard let member = sourceTabs.first(where: { $0.guid == memberId }),
                  let data = member.liveFaviconData ?? member.cachedFaviconData else {
                continue
            }
            crossWindowFaviconStash[memberId] = (data, now)
            stashed += 1
        }
        AppLogDebug(
            "[TabGroupDrag] stashCrossWindowFavicons captured=\(stashed)/\(memberIds.count)"
        )
    }

    /// Consume the stashed favicon bytes for `tabGuid`, if any.
    /// Returns nil when no entry exists or the entry is stale (older
    /// than `crossWindowFaviconStashTimeoutSeconds`). Stale entries
    /// are evicted opportunistically on every consume to keep the
    /// dict from leaking in pathological drag paths.
    static func consumeCrossWindowFavicon(for tabGuid: Int) -> Data? {
        let now = Date()
        crossWindowFaviconStash = crossWindowFaviconStash.filter { _, entry in
            now.timeIntervalSince(entry.requestedAt) <= crossWindowFaviconStashTimeoutSeconds
        }
        return crossWindowFaviconStash.removeValue(forKey: tabGuid)?.data
    }

    /// Moves an existing normal tab immediately to one side of `anchorTabId`
    /// in both the Swift `normalTabOrder` and the Chromium tab strip.
    /// Used by split creation: bridge-created tabs that arrive without an
    /// `insertAfterTabId` hint are appended at the end of the strip, so the
    /// new pane would otherwise sit far from its partner instead of next to
    /// it before `createSplit` is sent.
    func placeTabAdjacent(tabId: Int, to anchorTabId: Int, on slot: SplitSlot) {
        guard tabId != anchorTabId,
              let anchorIdx = normalTabOrder.firstIndex(of: anchorTabId) else { return }
        let currentIdx = normalTabOrder.firstIndex(of: tabId)
        // Account for the upcoming removal of `tabId` if it currently sits
        // at or before the anchor, so the post-removal index for the anchor
        // shifts down by one.
        let adjustedAnchorIdx: Int
        if let currentIdx, currentIdx <= anchorIdx {
            adjustedAnchorIdx = anchorIdx - 1
        } else {
            adjustedAnchorIdx = anchorIdx
        }
        let targetIdx: Int
        switch slot {
        case .right: targetIdx = adjustedAnchorIdx + 1
        case .left:  targetIdx = adjustedAnchorIdx
        }
        if currentIdx == targetIdx {
            // The Swift order may already show the tab adjacent (the decision
            // engine inserts an opener's child next to it with
            // syncChromiumOrder: false), while the Chromium strip still has the
            // bridge-created pane at the append slot. Push the relative order to
            // Chromium so the imminent createSplit pivots on the pane in place
            // instead of relocating the whole split to the strip's end.
            syncNormalTabRelativeOrderToChromium(tabId: tabId)
            return
        }
        insertIntoNormalTabOrder(tabGuid: tabId, at: targetIdx, syncChromiumOrder: true)
    }
    
    /// Inserts a tab guid into `normalTabOrder` at the requested index.
    /// - Parameters:
    ///   - tabGuid: Chromium tab guid.
    ///   - index: Destination index relative to `normalTabs`.
    private func insertIntoNormalTabOrder(tabGuid: Int, at index: Int, syncChromiumOrder: Bool = false) {
        normalTabOrder.removeAll { $0 == tabGuid }

        let insertIndex = min(max(0, index), normalTabOrder.count)
        normalTabOrder.insert(tabGuid, at: insertIndex)
        // Preserve group contiguity: if the newly placed tab is a
        // non-member of the surrounding group (e.g. a bookmark
        // opened while the active tab sits inside a group), shove
        // it out past the group's last member so the strip's
        // currentGroupRuns doesn't split into two runs of the same
        // token (which trips the empty-chip-slot artifact in
        // layoutNormalWithGroups).
        relocateInterloperOutOfGroupRun(tabGuid: tabGuid)
        updateNormalTabs()
        if syncChromiumOrder {
            syncNormalTabRelativeOrderToChromium(tabId: tabGuid)
        }
    }

    /// Mirror of `relocateJoinerIntoGroupRun`: handles the case where
    /// a tab that is *not* a member of a group lands between two of
    /// that group's members in `normalTabOrder`. Moves it to just
    /// after the group's last member. No-op when the tab is at the
    /// strip's edge or when its neighbors don't share a group token.
    private func relocateInterloperOutOfGroupRun(tabGuid: Int) {
        guard let tab = tabs.first(where: { $0.guid == tabGuid }) else { return }
        guard let currentIdx = normalTabOrder.firstIndex(of: tabGuid) else { return }
        let interloperToken = tab.groupToken
        let leftIdx = currentIdx - 1
        let rightIdx = currentIdx + 1
        guard leftIdx >= 0, rightIdx < normalTabOrder.count else { return }
        let leftToken = tabs.first(where: { $0.guid == normalTabOrder[leftIdx] })?.groupToken
        let rightToken = tabs.first(where: { $0.guid == normalTabOrder[rightIdx] })?.groupToken
        guard let splittingToken = leftToken,
              splittingToken == rightToken,
              splittingToken != interloperToken else { return }

        var lastMemberIdx: Int?
        for (idx, guid) in normalTabOrder.enumerated() where idx != currentIdx {
            if tabs.first(where: { $0.guid == guid })?.groupToken == splittingToken {
                if lastMemberIdx == nil || idx > lastMemberIdx! {
                    lastMemberIdx = idx
                }
            }
        }
        guard let last = lastMemberIdx else { return }

        normalTabOrder.remove(at: currentIdx)
        // Post-removal indexing: when the interloper was *before*
        // the last member, removing it shifts the last member down
        // by one and we re-insert at that shifted index +1 = `last`;
        // when it was *after*, `last` is unchanged and we insert at
        // `last + 1`.
        let targetIdx = (currentIdx < last) ? last : (last + 1)
        let safeIdx = min(targetIdx, normalTabOrder.count)
        normalTabOrder.insert(tabGuid, at: safeIdx)
        AppLogDebug(
            "[TAB_GROUPS] relocated interloper tabId=\(tabGuid) " +
            "from=\(currentIdx) to=\(safeIdx) splittingToken=\(splittingToken)"
        )
    }

    /// Synchronous companion to `handleTabJoinedGroup` /
    /// `handleTabLeftGroup`: applies a group-membership change on the Mac
    /// side immediately, instead of waiting for Chromium's `kJoined` /
    /// `kLeft` to round-trip back through the async `EventBus` hop.
    ///
    /// Why this exists: `bridge.addTabsToGroup` /
    /// `bridge.removeTabsFromGroup` / `bridge.createGroupFromTabs` all
    /// return synchronously, but the corresponding
    /// `TabGroupEvent.tabJoinedGroup` / `tabLeftGroup` ride the
    /// `EventBus.send → Task { @MainActor }` queue and don't land until
    /// at least the next runloop tick. If the caller also synchronously
    /// repositioned the tab (e.g. sidebar drag dropped it inside a
    /// group's child range via `moveNormalTabLocally`), the strip ends
    /// up in a `[member, non-member(stale), member]` state for that
    /// window — `TabStrip.currentGroupRuns()`'s contiguity assertion
    /// fires if a layout pass lands during the gap (most reliably when
    /// the user switches to Comfortable and the horizontal strip mounts
    /// for the first time).
    ///
    /// The authoritative async event handler is a no-op when the state
    /// it would set already matches: `handleTabJoinedGroup` early-
    /// returns inside `relocateJoinerIntoGroupRun` once the joiner is
    /// adjacent, and `handleTabLeftGroup`'s `tab.groupToken == token`
    /// guard skips the body entirely.
    @MainActor
    func applyOptimisticGroupMembership(tabId: Int, newToken: String?) {
        applyOptimisticGroupMembership(updates: [(tabId, newToken)])
    }

    /// Batched variant of `applyOptimisticGroupMembership(tabId:newToken:)`.
    /// All token mutations land first, then the relocates run, then a
    /// single `updateNormalTabs()` publishes the result — so a split pair
    /// leaving / joining a group together never goes through the transient
    /// `[member, non-member(stale), member]` state that trips
    /// `TabStrip.currentGroupRuns()`'s contiguity assertion.
    @MainActor
    func applyOptimisticGroupMembership(updates: [(tabId: Int, newToken: String?)]) {
        var effective: [(tab: Tab, newToken: String?)] = []
        for (tabId, newToken) in updates {
            guard let tab = tabs.first(where: { $0.guid == tabId }),
                  tab.groupToken != newToken else { continue }
            effective.append((tab, newToken))
        }
        guard !effective.isEmpty else { return }
        for (tab, newToken) in effective {
            tab.groupToken = newToken
        }
        for (tab, newToken) in effective {
            if let newToken {
                relocateJoinerIntoGroupRun(tabId: tab.guid, token: newToken)
            }
            // Always run the interloper relocate: when leaving a group (or
            // moving between groups), the tab's old position may still sit
            // mid-run of the old group's members, which would split that
            // group as soon as `tab.groupToken` no longer matches them.
            relocateInterloperOutOfGroupRun(tabGuid: tab.guid)
        }
        updateNormalTabs()
    }

    /// Clamps a pinned insert index so it never lands between the two
    /// records of a pinned split pair. The strip and the sidebar both pair
    /// by partner guid and render the pair as one merged cell wherever its
    /// records sit, so an interior index would silently persist a record
    /// order that diverges from every visible order. Snapping past the
    /// pair matches the reachable producers (drops on the pair's right).
    /// Live-only pairs whose `splitPartnerGuid` hasn't persisted yet are
    /// not detected — the drop-index tail fix upstream covers those.
    static func pinnedInsertIndexOutsideSplitPair(_ index: Int, pinnedTabs: [Tab]) -> Int {
        guard index > 0, index < pinnedTabs.count else { return index }
        let before = pinnedTabs[index - 1]
        let after = pinnedTabs[index]
        guard let partnerGuid = before.splitPartnerGuid, !partnerGuid.isEmpty,
              let afterGuid = after.guidInLocalDB, !afterGuid.isEmpty,
              afterGuid == partnerGuid else {
            return index
        }
        return index + 1
    }

    /// Reorder pinned  tab
    func movePinnedTab(tab: Tab, to newIndex: Int, selectAfterMove: Bool) {
        // Split-aware: use the same resolver as pinned-split rendering so
        // live, persisted, and half-persisted pairs all move as one unit.
        if let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: tab),
           let tabGuid = tab.guidInLocalDB {
            let partnerGuid = tabGuid == leftDB ? rightDB : leftDB
            guard let partner = pinnedTabs.first(where: { $0.guidInLocalDB == partnerGuid }) else {
                return
            }
            movePinnedSplitPair(handle: tab, partner: partner, to: newIndex)
            return
        } else if let partnerGuid = tab.splitPartnerGuid, !partnerGuid.isEmpty,
           let partner = pinnedTabs.first(where: { $0.guidInLocalDB == partnerGuid }) {
            movePinnedSplitPair(handle: tab, partner: partner, to: newIndex)
            return
        }

        let insertIndex = Self.pinnedInsertIndexOutsideSplitPair(newIndex, pinnedTabs: pinnedTabs)
        var after: String?
        if insertIndex > 0, !pinnedTabs.isEmpty {
            let tab = pinnedTabs[insertIndex - 1]
            after = tab.guidInLocalDB
        }

        localStore.moveOrCreatePinnedTab(tab, after: after, profileId: profileId)
//        if !tab.isOpenned {
//            openOrFocusPinnedTab(tab)
//        }
    }

    /// Reorders a pinned-split pair so both panes land adjacent at the
    /// requested visual index. The pane currently first in `pinnedTabs`
    /// stays first after the move so the merged cell's left/right favicon
    /// order is preserved.
    private func movePinnedSplitPair(handle: Tab, partner: Tab, to newIndex: Int) {
        guard let handleIdx = pinnedTabs.firstIndex(of: handle),
              let partnerIdx = pinnedTabs.firstIndex(of: partner) else {
            return
        }
        let firstPane: Tab
        let secondPane: Tab
        if handleIdx <= partnerIdx {
            firstPane = handle
            secondPane = partner
        } else {
            firstPane = partner
            secondPane = handle
        }

        // `newIndex` is computed from the full `pinnedTabs` count; convert
        // it to an index in the list with the pair removed so the "after"
        // anchor is unambiguous.
        let pairGuids: Set<String> = [
            firstPane.guidInLocalDB ?? "",
            secondPane.guidInLocalDB ?? ""
        ]
        let rest = pinnedTabs.filter { tab in
            guard let guid = tab.guidInLocalDB else { return true }
            return !pairGuids.contains(guid)
        }
        var restIndex = newIndex
        if handleIdx < newIndex { restIndex -= 1 }
        if partnerIdx < newIndex { restIndex -= 1 }
        restIndex = max(0, min(restIndex, rest.count))

        let afterFirstPane: String? = restIndex > 0
            ? rest[restIndex - 1].guidInLocalDB
            : nil

        localStore.moveOrCreatePinnedTab(firstPane, after: afterFirstPane, profileId: profileId)
        localStore.moveOrCreatePinnedTab(secondPane, after: firstPane.guidInLocalDB, profileId: profileId)
    }
    
    func moveNormalTab(tabId: Int, toPinnd pinnedIndex: Int, selectAfterMove: Bool = false) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else {
            return
        }
        // Phi-side pinning bypasses Chromium's TabStripModel (it stores
        // the tab as a bookmark-backed local entry instead), so the
        // automatic "pinning detaches from group" behavior in
        // `TabStripModel::SetTabPinned` doesn't fire. Detach explicitly
        // here so all five paths into pinning — the right-click "Pin"
        // menu plus the four drag-to-pinned-area drop sites (sidebar
        // and horizontal strip, same- and cross-window) — keep
        // Chromium's group state and Phi's `tab.groupToken` consistent.
        // Local clear avoids a transient "pinned + grouped" frame
        // before the kLeft event round-trips back through the bridge.
        if tab.groupToken != nil,
           let bridge = ChromiumLauncher.sharedInstance().bridge {
            bridge.removeTabsFromGroup(withWindowId: windowId.int64Value,
                                        tabIds: [NSNumber(value: Int64(tabId))])
            tab.groupToken = nil
        }
        var afterGuid: String?
        if pinnedIndex > 0, !pinnedTabs.isEmpty {
            let snappedIndex = Self.pinnedInsertIndexOutsideSplitPair(pinnedIndex, pinnedTabs: pinnedTabs)
            let clampedIdx = min(snappedIndex - 1, pinnedTabs.count - 1)
            afterGuid = pinnedTabs[clampedIdx].guidInLocalDB
        } else if pinnedIndex == -1, !pinnedTabs.isEmpty {
            afterGuid = pinnedTabs.last!.guidInLocalDB
        }
        moveNormalTabToPinned(tab, after: afterGuid, selectAfterMove: selectAfterMove)
    }

    /// Pin a normal tab using an explicit "after" anchor guid instead of an
    /// index. Lets callers chain multiple inserts in one runloop turn — the
    /// `pinnedTabs` publisher is async (background SwiftData write + main-queue
    /// hop), so an index computed against the post-first-insert state is not
    /// observable yet when a second insert runs synchronously after the first.
    func moveNormalTabToPinned(_ tab: Tab, after afterGuid: String?, selectAfterMove: Bool = false) {
        let tabId = tab.guid
        let affectedChildren = nativeRelationGraph.directChildren(of: tabId)
        nativeRelationGraph.fixOpenersAfterMovingTab(tabId)
        for childId in affectedChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }

        let newGuid = UUID().uuidString
        migrateAIChatTab(for: tab, toNewIdentifier: newGuid)

        localStore.moveOrCreatePinnedTab(tab, after: afterGuid, profileId: profileId, newGuid: newGuid)
        tab.guidInLocalDB = newGuid
        if let wrapper = tab.webContentWrapper {
            wrapper.updateTabCustomValue(newGuid)
        }
    }
    
    func movePinnedTabOut(pinnedGuid: String, to normalIndex: Int, selectAfterMove: Bool = false) {
        guard let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }) else {
            return
        }
        // Split-aware: resolve the partner pane through the same resolver the
        // merged pinned-split cell renders from — live `isPinned` SplitGroup
        // first, persisted `splitPartnerGuid` as fallback. Keying off the raw
        // `splitPartnerGuid` field plus a both-panes-live requirement left two
        // gaps that stranded the partner record in the pinned list while only
        // the dragged pane moved: a partially-live split (one pane closed after
        // the pair was opened), and a freshly-pinned split whose
        // `splitPartnerGuid` had not been persisted yet but whose live
        // `SplitGroup` already paired the panes.
        if let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedTab) {
            let partnerDB = leftDB == pinnedGuid ? rightDB : leftDB
            let handleLive = tabs.first(where: { $0.guidInLocalDB == pinnedGuid })
            let partnerLive = tabs.first(where: { $0.guidInLocalDB == partnerDB })
            if let handleLive, let partnerLive,
               let partnerPinned = pinnedTabs.first(where: { $0.guidInLocalDB == partnerDB }) {
                // Both panes live: carry the existing SplitGroup over so the
                // pair lands in the tab list as one merged split cell.
                unpinSplitPanesIntoNormalList(handleLive: handleLive,
                                              partnerLive: partnerLive,
                                              handlePinned: pinnedTab,
                                              partnerPinned: partnerPinned,
                                              insertIndex: normalIndex)
                return
            }
            // One or both panes closed. Close whichever pane is still live so
            // the reopen below doesn't leave a duplicate tab backed by the
            // now-deleted pinned record, then drop both pinned records and
            // reopen the pair as a fresh split at the drop site.
            MainActor.assumeIsolated {
                if let handleLive { closeTab(handleLive.guid) }
                if let partnerLive { closeTab(partnerLive.guid) }
                unpinClosedPinnedSplit(leftDB: leftDB, rightDB: rightDB, insertionIndex: normalIndex)
            }
            return
        }
        if let normalTab = tabs.first(where: { $0.guidInLocalDB == pinnedGuid }) {
            // Migrate AI Chat tab association before changing identifier
            // When moving out of pinned, identifier changes from guidInLocalDB to chromium guid
            migrateAIChatTab(for: normalTab, toNewIdentifier: nil)

            normalTab.guidInLocalDB = nil
            normalTab.isPinned = false
            if let storedTitle = pinnedTab.storedTitle {
                normalTab.applyStoredTitle(storedTitle)
            }
            pinnedTab.webContentWrapper?.updateTabCustomValue("")

            insertIntoNormalTabOrder(tabGuid: normalTab.guid,
                                     at: normalIndex,
                                     syncChromiumOrder: true)
        } else {
            // New tabs are appended first, so record the intended insertion index up front.
            pendingNormalTabInsertion = PendingNormalTabInsertion(url: pinnedTab.url ?? "",
                                                                  guid: nil,
                                                                  expectedGroupToken: nil,
                                                                  index: normalIndex,
                                                                  syncChromiumOrder: true)
            ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: pinnedTab.url ?? "", at: -1, windowId: windowId, customGuid: nil)
        }

        localStore.removePinnedTab(pinnedTab)
    }

    /// Unpins both panes of a live pinned split into the normal tab list,
    /// preserving the existing `SplitGroup` so the pair keeps rendering as a
    /// merged split cell. Insertion order follows the group's primary →
    /// secondary so `splitPairPosition` resolves the same orientation in the
    /// tab list as it had while pinned. If no `SplitGroup` currently covers
    /// the panes (e.g. session restore hasn't paired them yet) the helper
    /// recreates the split after the unpin.
    private func unpinSplitPanesIntoNormalList(handleLive: Tab,
                                                partnerLive: Tab,
                                                handlePinned: Tab,
                                                partnerPinned: Tab,
                                                insertIndex: Int) {
        // Resolve which live tab is the SplitGroup's primary so insertion
        // order matches the existing split orientation.
        let existingGroup = splitGroup(forTabId: handleLive.guid)
        let primary: (live: Tab, pinned: Tab)
        let secondary: (live: Tab, pinned: Tab)
        if let group = existingGroup, group.primaryTabId == partnerLive.guid {
            primary = (partnerLive, partnerPinned)
            secondary = (handleLive, handlePinned)
        } else {
            primary = (handleLive, handlePinned)
            secondary = (partnerLive, partnerPinned)
        }

        migrateAIChatTab(for: primary.live, toNewIdentifier: nil)
        migrateAIChatTab(for: secondary.live, toNewIdentifier: nil)

        for pair in [primary, secondary] {
            pair.live.guidInLocalDB = nil
            pair.live.isPinned = false
            if let storedTitle = pair.pinned.storedTitle {
                pair.live.applyStoredTitle(storedTitle)
            }
            pair.live.webContentWrapper?.updateTabCustomValue("")
        }

        // Clear the pinned flag on the live split so its toolbar/sidebar
        // affordances stop showing the pinned-pair state.
        if let group = existingGroup,
           let splitIdx = splits.firstIndex(where: { $0.id == group.id }) {
            splits[splitIdx].isPinned = false
        }

        // When a live SplitGroup already covers the pair, the per-tab
        // `syncChromiumOrder` path would call `bridge.moveTab` for each
        // pane in turn. Chromium's `MaybeRemoveSplitsForMove` then trips
        // on the first move — relocating one split member outside its
        // adjacency dissolves the SplitTabId — and the user is left
        // with two standalone tabs at the drop site. Defer the
        // Chromium-side reorder to a single `moveSplit` below so the
        // pair travels as a unit. When no live group exists yet the
        // per-tab sync is safe (nothing to tear) and we fall through to
        // `createSplit` after the inserts.
        let preserveLiveSplit = existingGroup != nil
        insertIntoNormalTabOrder(tabGuid: primary.live.guid,
                                 at: insertIndex,
                                 syncChromiumOrder: !preserveLiveSplit)
        insertIntoNormalTabOrder(tabGuid: secondary.live.guid,
                                 at: insertIndex + 1,
                                 syncChromiumOrder: !preserveLiveSplit)

        // Drop the partner refs on the in-memory pinned records *before*
        // removing them. The store delete is async; any synchronous code
        // between here and the publisher round-trip that scans `pinnedTabs`
        // for a matching `splitPartnerGuid` (e.g. `clearPinnedSplitPartnerReference`)
        // would otherwise see two soon-to-be-deleted records still pointing
        // at each other and write the stale ref onto an unrelated tab.
        handlePinned.splitPartnerGuid = nil
        partnerPinned.splitPartnerGuid = nil

        localStore.removePinnedTab(handlePinned)
        localStore.removePinnedTab(partnerPinned)

        if let group = existingGroup {
            moveSplit(group.id, toIndex: insertIndex)
        } else {
            // Chromium hadn't yet paired the two live tabs into a split,
            // recreate one now so the unpinned pair renders as a merged cell.
            createSplit(leftTabId: primary.live.guid,
                        rightTabId: secondary.live.guid,
                        layout: .vertical)
        }
    }

    /// Moves a normal tab into bookmarks.
    /// - Parameters:
    ///   - tabId: Chromium guid of the tab to move.
    ///   - parentGuid: Destination bookmark folder guid, or nil for the root.
    ///   - index: Destination insertion index inside the parent folder.
    ///   - selectAfterMove: Whether the moved tab should remain selected.
    func moveNormalTab(tabId: Int, toBookmark parentGuid: String?, index: Int, selectAfterMove: Bool = false) {
        guard let tab = tabs.first(where: { $0.guid == tabId }),
              let url = tab.url, !url.isEmpty else {
            return
        }
        let newBookmarkGuid = UUID().uuidString
        prepareNormalTabForBookmark(tab, bookmarkGuid: newBookmarkGuid)

        localStore.createBookmark(url: url,
                                  title: tab.title,
                                  profileId: profileId,
                                  parentId: parentGuid,
                                  index: index,
                                  guid: newBookmarkGuid,
                                  favicon: tab.liveFaviconData ?? tab.cachedFaviconData)

        updateNormalTabs()
    }

    private func prepareNormalTabForBookmark(_ tab: Tab, bookmarkGuid: String) {
        // Symmetric to the detach in `moveNormalTab(toPinnd:)`. Phi's
        // bookmark-backed tab is a Mac-only concept layered on top of
        // Chromium's normal tab, so Chromium's GroupModel doesn't learn
        // that a grouped tab has been "converted" until we explicitly
        // tell it.
        if let token = tab.groupToken {
            ChromiumLauncher.sharedInstance().bridge?.removeTabsFromGroup(
                withWindowId: windowId.int64Value,
                tabIds: [NSNumber(value: Int64(tab.guid))]
            )
            tab.groupToken = nil
            if tabs.contains(where: { $0.groupToken == token }) {
                groups[token]?.objectWillChange.send()
            } else {
                groups.removeValue(forKey: token)
            }
        }

        let affectedChildren = nativeRelationGraph.directChildren(of: tab.guid)
        nativeRelationGraph.fixOpenersAfterMovingTab(tab.guid)
        for childId in affectedChildren {
            nativeRelationGraph.locallyFixedOpenerTabIds.insert(childId)
        }

        migrateAIChatTab(for: tab, toNewIdentifier: bookmarkGuid)
        tab.guidInLocalDB = bookmarkGuid
        tab.webContentWrapper?.updateTabCustomValue(bookmarkGuid)
    }
    
    /// Converts every member of a tab group into a bookmark folder,
    /// dissolving the group on Chromium's side. Members are NOT closed:
    /// each one is detached from the group and rewired to a fresh bookmark
    /// record inside the new folder, preserving the in-group order.
    /// - Parameters:
    ///   - token: Hex token of the group to dissolve.
    ///   - parentFolder: Destination bookmark folder, or nil for the root.
    ///   - index: Destination starting index inside the parent folder; nil
    ///     appends at the front (i.e. starting at 0).
    @MainActor
    func convertGroupToBookmarks(token: String,
                                  parentFolder: Bookmark?,
                                  at index: Int?) {
        let members = normalTabs.filter { $0.groupToken == token }
        guard !members.isEmpty else {
            AppLogDebug(
                "[TAB_GROUPS] convertGroupToBookmarks no members for token=\(token); skipping"
            )
            return
        }
        let folderTitle = groups[token]?.displayTitle(memberCount: members.count)
            ?? NSLocalizedString(
                "Tab Group",
                comment: "Tab Groups - Fallback bookmark folder title when converting a tab group")
        let memberGuids = members.map { $0.guid }
        let startIndex = index ?? 0
        let folderGuid = UUID().uuidString
        AppLogDebug(
            "[TAB_GROUPS] convertGroupToBookmarks token=\(token) " +
            "members=\(memberGuids) parent=\(parentFolder?.guid ?? "<root>") " +
            "startIndex=\(startIndex) folderGuid=\(folderGuid)"
        )

        var bookmarkDrafts: [(tab: Tab, title: String?, url: String, guid: String)] = []
        for tab in members {
            guard let url = tab.url, !url.isEmpty else {
                AppLogWarn(
                    "[TAB_GROUPS] convertGroupToBookmarks member has empty url " +
                    "token=\(token) tabId=\(tab.guid); skipping conversion"
                )
                return
            }
            let bookmarkGuid = UUID().uuidString
            bookmarkDrafts.append((tab: tab, title: tab.title, url: url, guid: bookmarkGuid))
        }

        for draft in bookmarkDrafts {
            prepareNormalTabForBookmark(draft.tab, bookmarkGuid: draft.guid)
        }

        localStore.createDirectoryWithBookmarks(
            folderTitle: folderTitle,
            folderGuid: folderGuid,
            profileId: profileId,
            parentId: parentFolder?.guid,
            index: startIndex,
            bookmarks: bookmarkDrafts.map {
                (title: $0.title,
                 url: $0.url,
                 guid: $0.guid,
                 favicon: $0.tab.liveFaviconData ?? $0.tab.cachedFaviconData)
            }
        )
        updateNormalTabs()
        groups.removeValue(forKey: token)
        pendingGroupClaims = pendingGroupClaims.filter { $0.value != token }

        // Chromium fires kClosed when the last member leaves the group, but
        // wire-order is async; ask Chromium to close the group explicitly so
        // the sidebar header drops without waiting on the echo. Idempotent
        // in the steady state.
        ChromiumLauncher.sharedInstance().bridge?.closeGroup(
            withWindowId: Int64(windowId),
            tokenHex: token
        )
    }

    /// Moves a pinned tab into bookmarks.
    /// - Parameters:
    ///   - pinnedGuid: Local database guid of the pinned tab.
    ///   - parentGuid: Destination bookmark folder guid, or nil for the root.
    ///   - index: Destination insertion index inside the parent folder.
    ///   - selectAfterMove: Whether the moved tab should remain selected.
    func movePinnedTabOut(pinnedGuid: String, toBookmark parentGuid: String?, index: Int, selectAfterMove: Bool = false) {
        guard let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
              let url = pinnedTab.url, !url.isEmpty else {
            return
        }

        // Split-aware: resolve the partner via the shared resolver (live
        // `isPinned` SplitGroup first, persisted `splitPartnerGuid` fallback)
        // so a split paired only by its live group — `splitPartnerGuid` not
        // yet persisted — is still saved as one split-view bookmark instead of
        // a single bookmark that strands the partner in the pinned list.
        if let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedTab) {
            let partnerDB = leftDB == pinnedGuid ? rightDB : leftDB
            if let partnerPinned = pinnedTabs.first(where: { $0.guidInLocalDB == partnerDB }),
               let partnerURL = partnerPinned.url, !partnerURL.isEmpty {
                savePinnedSplitAsBookmark(handlePinned: pinnedTab,
                                          partnerPinned: partnerPinned,
                                          parentGuid: parentGuid,
                                          index: index)
                return
            }
        }

        let newBookmarkGuid = UUID().uuidString

        // Prefer the persisted title over the KVO-driven display title.
        let titleForBookmark = pinnedTab.storedTitle ?? pinnedTab.title

        localStore.createBookmark(url: url,
                                  title: titleForBookmark,
                                  profileId: profileId,
                                  parentId: parentGuid,
                                  index: index,
                                  guid: newBookmarkGuid,
                                  favicon: pinnedTab.liveFaviconData ?? pinnedTab.cachedFaviconData)

        if pinnedTab.isOpenned, let chromiumTab = tabs.first(where: { $0.guidInLocalDB == pinnedGuid }) {
            migrateAIChatTab(for: chromiumTab, toNewIdentifier: newBookmarkGuid)

            chromiumTab.guidInLocalDB = newBookmarkGuid
            chromiumTab.isPinned = false

            if let wrapper = chromiumTab.webContentWrapper {
                wrapper.updateTabCustomValue(newBookmarkGuid)
            }
        }

        // Remove the persisted pinned entry after the Chromium tab is converted back.
        localStore.removePinnedTab(pinnedTab)

        // Rebuild normal tabs after the move completes.
        updateNormalTabs()
    }

    /// Saves both panes of a pinned split as a single split-view bookmark.
    /// Mirrors `addSplitBookmarkFromTab`: when both panes are currently live
    /// Chromium tabs, the live split is bound to the new bookmark via
    /// `splitBookmarkBindings` so the bookmark cell becomes the visible
    /// representation (matches single-tab pinned→bookmark, where the live
    /// Chromium tab is rebound to the new bookmark guid). Both panes are
    /// unpinned so they fall out of the pinned section. If one or both
    /// panes are already closed, only the persisted pinned records are
    /// removed.
    private func savePinnedSplitAsBookmark(handlePinned: Tab,
                                            partnerPinned: Tab,
                                            parentGuid: String?,
                                            index: Int) {
        guard let handleURL = handlePinned.url, !handleURL.isEmpty,
              let partnerURL = partnerPinned.url, !partnerURL.isEmpty else {
            return
        }

        let handleLive = tabs.first(where: { $0.guidInLocalDB == handlePinned.guidInLocalDB })
        let partnerLive = tabs.first(where: { $0.guidInLocalDB == partnerPinned.guidInLocalDB })

        // Resolve primary/secondary against the live SplitGroup so the
        // saved bookmark mirrors the on-screen orientation.
        let primaryPinned: Tab
        let secondaryPinned: Tab
        if let handleLive,
           let partnerLive,
           let group = splitGroup(forTabId: handleLive.guid),
           group.primaryTabId == partnerLive.guid {
            primaryPinned = partnerPinned
            secondaryPinned = handlePinned
        } else {
            primaryPinned = handlePinned
            secondaryPinned = partnerPinned
        }

        let primaryURL = primaryPinned.url ?? handleURL
        let secondaryURL = secondaryPinned.url ?? partnerURL
        let primaryTitle = primaryPinned.storedTitle ?? primaryPinned.title
        let secondaryTitle = secondaryPinned.storedTitle ?? secondaryPinned.title
        let bookmarkTitle = primaryTitle.isEmpty ? primaryURL : primaryTitle
        // Match `addSplitBookmarkFromTab`: suppress the secondary label
        // when it just duplicates the primary so the saved bookmark stays
        // compact.
        let secondaryDisplayTitle: String? = {
            if primaryTitle == secondaryTitle { return nil }
            return secondaryTitle.isEmpty ? nil : secondaryTitle
        }()

        let newBookmarkGuid = UUID().uuidString
        // Use `localStore.createBookmark` directly so we control the guid
        // and can bind the live split to the bookmark in the same tick.
        localStore.createBookmark(
            url: URLProcessor.processUserInput(primaryURL),
            title: bookmarkTitle,
            profileId: profileId,
            parentId: parentGuid,
            index: index,
            guid: newBookmarkGuid,
            secondaryUrl: URLProcessor.processUserInput(secondaryURL),
            secondaryTitle: secondaryDisplayTitle,
            favicon: primaryPinned.liveFaviconData ?? primaryPinned.cachedFaviconData
        )

        // If both panes are live, unpin them and register the bookmark→split
        // binding so the live split becomes the bookmark's opened state.
        // Closed panes have nothing to unpin — only the persisted pinned
        // records are removed below.
        if let handleLive, let partnerLive {
            migrateAIChatTab(for: handleLive, toNewIdentifier: nil)
            migrateAIChatTab(for: partnerLive, toNewIdentifier: nil)
            for (live, pinned) in [(handleLive, handlePinned), (partnerLive, partnerPinned)] {
                live.guidInLocalDB = nil
                live.isPinned = false
                if let storedTitle = pinned.storedTitle {
                    live.applyStoredTitle(storedTitle)
                }
                live.webContentWrapper?.updateTabCustomValue("")
            }
            // Resolve a SplitGroup to bind under the new bookmark. The live
            // SplitGroup is the common case; if none exists (the pinned
            // split was just opened and `tryRecreatePendingPinnedSplit`'s
            // deferred `createSplit` has not run yet, or Chromium tore the
            // split down independently while `splitPartnerGuid` still
            // pairs the records) recreate one now so the running pair
            // stays merged as the bookmark's opened representation instead
            // of falling apart into two independent normal tabs.
            let resolvedSplitId: String?
            if let splitId = splitGroup(forTabId: handleLive.guid)?.id,
               let splitIdx = splits.firstIndex(where: { $0.id == splitId }) {
                splits[splitIdx].isPinned = false
                resolvedSplitId = splitId
            } else {
                resolvedSplitId = createSplit(leftTabId: handleLive.guid,
                                              rightTabId: partnerLive.guid,
                                              layout: .vertical)
            }
            if let resolvedSplitId {
                splitBookmarkBindings[newBookmarkGuid] = resolvedSplitId
            }
        }

        localStore.removePinnedTab(handlePinned)
        localStore.removePinnedTab(partnerPinned)

        updateNormalTabs()
    }
    
    /// Moves a bookmark into the pinned tab section.
    /// - Parameters:
    ///   - bookmark: Bookmark to move.
    ///   - index: Destination index inside `pinnedTabs`.
    ///   - selectAfterMove: Whether the moved tab should be selected.
    func moveBookmarkOut(_ bookmark: Bookmark, toPinnedTabs index: Int, selectAfterMove: Bool = false) {
        guard !bookmark.isFolder, let url = bookmark.url, !url.isEmpty else {
            return
        }

        // Resolve against the current bookmark tree before mutating local state.
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return
        }

        // Split-aware: a split-view bookmark carries two URLs; pin both as
        // a paired pinned-split so the merged-cell rendering survives the
        // move (otherwise only the primary URL would be pinned and the
        // split semantics would be lost).
        if let secondaryURL = realBookmark.secondaryUrl, !secondaryURL.isEmpty {
            savePinnedSplitFromBookmark(bookmark: realBookmark, atIndex: index)
            return
        }
        
        // Map the destination index to the persisted pinned-tab ordering key.
        var afterGuid: String?
        if index > 0, !pinnedTabs.isEmpty {
            let afterTab = pinnedTabs[min(index - 1, pinnedTabs.count - 1)]
            afterGuid = afterTab.guidInLocalDB
        }
        
        // Generate a new local identifier for the pinned-tab record.
        let newPinnedGuid = UUID().uuidString
        
        // Use a temporary tab model to drive the local-store move helper.
        let tempTab = Tab(guid: -1, url: url, isActive: false, index: 0, title: bookmark.title, customGuid: nil)
        
        // Create the new pinned-tab entry in local storage.
        localStore.moveOrCreatePinnedTab(tempTab, after: afterGuid, profileId: profileId, newGuid: newPinnedGuid)
        
        // If the bookmark is already open, retarget the live Chromium tab as well.
        if realBookmark.isOpened, let chromiumTab = tabs.first(where: { $0.guidInLocalDB == bookmark.guid }) {
            // Migrate AI Chat tab association before changing identifier
            migrateAIChatTab(for: chromiumTab, toNewIdentifier: newPinnedGuid)
            
            // Point the live tab at the new pinned-tab identifier.
            chromiumTab.guidInLocalDB = newPinnedGuid
            chromiumTab.isPinned = true
            chromiumTab.title = tempTab.title
            
            // Keep the Chromium-side custom value in sync.
            if let wrapper = chromiumTab.webContentWrapper {
                wrapper.updateTabCustomValue(newPinnedGuid)
            }
        }
        
        // Remove the old bookmark entry once the pinned version exists.
        bookmarkManager.removeBookmark(realBookmark)
        
        // Rebuild normal tabs after the move completes.
        updateNormalTabs()
    }
    
    /// Moves a bookmark into the normal tab strip.
    /// - Parameters:
    ///   - bookmark: Bookmark to move.
    ///   - index: Destination index inside `normalTabs`.
    ///   - selectAfterMove: Whether the moved tab should be selected.
    func moveBookmarkOut(_ bookmark: Bookmark, toNormalTabs index: Int, selectAfterMove: Bool = false) {
        guard !bookmark.isFolder, let url = bookmark.url, !url.isEmpty else {
            return
        }

        // Resolve against the current bookmark tree before mutating local state.
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return
        }

        // Split-aware: a split-view bookmark needs both URLs to land in the
        // tab list as a split pair. The single-URL path below would only
        // place the primary pane and lose the split.
        if let secondaryURL = realBookmark.secondaryUrl, !secondaryURL.isEmpty {
            openSplitBookmarkAsTabs(bookmark: realBookmark, atIndex: index)
            return
        }

        if realBookmark.isOpened, let chromiumTab = tabs.first(where: { $0.guidInLocalDB == bookmark.guid }) {
            // Migrate AI Chat tab association before changing identifier
            // When moving out of bookmark to normal tab, identifier changes to chromium guid
            migrateAIChatTab(for: chromiumTab, toNewIdentifier: nil)
            
            // Reuse the open Chromium tab and detach it from bookmark storage.
            chromiumTab.guidInLocalDB = nil
            chromiumTab.applyStoredTitle(bookmark.title)
            
            // Keep the Chromium-side custom value in sync.
            if let wrapper = chromiumTab.webContentWrapper {
                wrapper.updateTabCustomValue("")
            }
            
            // Insert the existing tab into the desired normal-tab position.
            insertIntoNormalTabOrder(tabGuid: chromiumTab.guid,
                                     at: index,
                                     syncChromiumOrder: true)
        } else {
            // Create a new Chromium tab and let `newTab()` apply the pending insertion point.
            pendingNormalTabInsertion = PendingNormalTabInsertion(url: url,
                                                                  guid: nil,
                                                                  expectedGroupToken: nil,
                                                                  index: index,
                                                                  syncChromiumOrder: true)
            ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url,
                                                                   at: -1,
                                                                   windowId: windowId,
                                                                   customGuid: nil)
        }
        
        // Remove the old bookmark entry after migration.
        bookmarkManager.removeBookmark(realBookmark)
    }

    @discardableResult
    @MainActor
    func moveBookmarkOut(_ bookmark: Bookmark,
                         toGroup tokenHex: String,
                         groupIndex: Int,
                         normalTabsIndex: Int,
                         focusAfterCreate: Bool = false) -> Bool {
        guard let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid) else {
            return false
        }
        let moved = moveBookmarkIntoGroup(bookmark,
                                          toGroup: tokenHex,
                                          groupIndex: groupIndex,
                                          normalTabsIndex: normalTabsIndex,
                                          focusAfterCreate: focusAfterCreate)
        // Split bookmarks are consumed inside `moveSplitBookmarkIntoGroup`;
        // only the single-bookmark path still needs its entry removed here.
        if moved, realBookmark.secondaryUrl?.isEmpty != false {
            bookmarkManager.removeBookmark(realBookmark)
        }
        return moved
    }

    /// Joins a bookmark into a tab group **keeping the bookmark entry**.
    /// An already-open bookmark tab is graduated into a plain tab (custom
    /// guid + Chromium custom value cleared) and added to the group; a
    /// closed bookmark opens a fresh tab inside the group. Use this when a
    /// tab that was merely *opened from* a bookmark joins a group — the
    /// bookmark stays in the bar. `moveBookmarkOut` wraps this and also
    /// removes the single bookmark (the move-out semantics for sidebar
    /// drags). Split bookmarks are consumed by `moveSplitBookmarkIntoGroup`
    /// in either case. The detached tab keeps a live title (it follows the
    /// page), matching the closed-bookmark `createTabInGroup` path.
    @discardableResult
    @MainActor
    func moveBookmarkIntoGroup(_ bookmark: Bookmark,
                               toGroup tokenHex: String,
                               groupIndex: Int,
                               normalTabsIndex: Int,
                               focusAfterCreate: Bool = false) -> Bool {
        guard !bookmark.isFolder,
              let url = bookmark.url, !url.isEmpty,
              let realBookmark = bookmarkManager.bookmark(withGuid: bookmark.guid),
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return false
        }

        if let secondaryURL = realBookmark.secondaryUrl, !secondaryURL.isEmpty {
            return moveSplitBookmarkIntoGroup(realBookmark,
                                              primaryURL: url,
                                              secondaryURL: secondaryURL,
                                              toGroup: tokenHex,
                                              normalTabsIndex: normalTabsIndex)
        }

        if let chromiumTab = tabs.first(where: { $0.guidInLocalDB == realBookmark.guid }) {
            migrateAIChatTab(for: chromiumTab, toNewIdentifier: nil)
            chromiumTab.guidInLocalDB = nil
            chromiumTab.webContentWrapper?.updateTabCustomValue("")
            applyOptimisticGroupMembership(tabId: chromiumTab.guid, newToken: tokenHex)
            insertIntoNormalTabOrder(tabGuid: chromiumTab.guid,
                                     at: normalTabsIndex,
                                     syncChromiumOrder: true)

            let tabIds = [NSNumber(value: Int64(chromiumTab.guid))]
            bridge.addTabsToGroup(withWindowId: windowId.int64Value,
                                  tabIds: tabIds,
                                  tokenHex: tokenHex)
        } else {
            scheduleNextNormalTabInsertion(at: normalTabsIndex,
                                           syncChromiumOrder: false,
                                           expectedGroupToken: tokenHex)
            bridge.createTabInGroup(withWindowId: windowId.int64Value,
                                    tokenHex: tokenHex,
                                    url: url,
                                    groupIndex: groupIndex,
                                    focusAfterCreate: focusAfterCreate)
        }

        return true
    }

    /// Graduates a bookmark-opened tab into a plain, groupable tab by shedding
    /// its bookmark identity: clears the `Tab.guidInLocalDB` and the Chromium
    /// `custom_value` (synchronously) and migrates any AI-chat association. The
    /// bookmark itself stays in the bar — only the live tab's binding is
    /// dropped. No-op for tabs not currently bound to a bookmark. Mirrors the
    /// graduation `moveBookmarkIntoGroup` performs for the drag-into-group
    /// path, so the right-click "New Tab Group" / "Add to Group" actions can
    /// put a bookmark-opened tab into a group: Chromium's `createGroupFromTabs`
    /// / `addTabsToGroup` reject any batch that still contains a Phi-managed
    /// (non-empty `custom_value`) tab, and an ungraduated bookmark tab would be
    /// silently dropped.
    @MainActor
    func graduateBookmarkTabToPlainTab(_ tab: Tab) {
        guard let localGuid = tab.guidInLocalDB, !localGuid.isEmpty,
              bookmarkManager.bookmark(withGuid: localGuid) != nil else {
            return
        }
        migrateAIChatTab(for: tab, toNewIdentifier: nil)
        tab.guidInLocalDB = nil
        tab.webContentWrapper?.updateTabCustomValue("")
    }

    /// Drops a split-view bookmark into a tab group. A live-bound split folds
    /// its two existing panes into the group as a unit; a closed bookmark
    /// re-opens both URLs as a fresh split that joins the group once Chromium
    /// echoes the panes back. The bookmark is removed in both cases.
    @discardableResult
    @MainActor
    private func moveSplitBookmarkIntoGroup(_ bookmark: Bookmark,
                                            primaryURL: String,
                                            secondaryURL: String,
                                            toGroup tokenHex: String,
                                            normalTabsIndex: Int) -> Bool {
        if let splitId = splitBookmarkBindings[bookmark.guid],
           let group = splits.first(where: { $0.id == splitId }),
           let primaryLive = tabs.first(where: { $0.guid == group.primaryTabId }),
           let secondaryLive = tabs.first(where: { $0.guid == group.secondaryTabId }),
           let bridge = ChromiumLauncher.sharedInstance().bridge {
            // Drop the binding so the panes stop hiding behind the bookmark
            // cell, then re-seat them in the visible order. Per-tab Chromium
            // sync would tear the live SplitTabId, so insert without syncing
            // and let `addTabsToGroup` perform the strip move as a unit.
            splitBookmarkBindings.removeValue(forKey: bookmark.guid)
            applyOptimisticGroupMembership(updates: [
                (primaryLive.guid, tokenHex),
                (secondaryLive.guid, tokenHex)
            ])
            insertIntoNormalTabOrder(tabGuid: primaryLive.guid,
                                     at: normalTabsIndex,
                                     syncChromiumOrder: false)
            insertIntoNormalTabOrder(tabGuid: secondaryLive.guid,
                                     at: normalTabsIndex + 1,
                                     syncChromiumOrder: false)
            bridge.addTabsToGroup(withWindowId: windowId.int64Value,
                                  tabIds: [NSNumber(value: Int64(primaryLive.guid)),
                                           NSNumber(value: Int64(secondaryLive.guid))],
                                  tokenHex: tokenHex)
            bookmarkManager.removeBookmark(bookmark)
            return true
        }

        // `addTabsToGroup` parks the joining panes at the group's trailing
        // edge, so pass the drop position through: `handleSplitCreated`
        // relocates the finished split to it (still inside the group, since
        // the index falls within the group's run).
        openTwoURLsAsSplit(primaryURL: primaryURL,
                           secondaryURL: secondaryURL,
                           groupToken: tokenHex,
                           insertionIndex: normalTabsIndex)
        bookmarkManager.removeBookmark(bookmark)
        return true
    }

    @discardableResult
    @MainActor
    func movePinnedTabOut(pinnedGuid: String,
                          toGroup tokenHex: String,
                          groupIndex: Int,
                          normalTabsIndex: Int,
                          focusAfterCreate: Bool = false) -> Bool {
        guard let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == pinnedGuid }),
              let url = pinnedTab.url, !url.isEmpty,
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return false
        }

        if let (leftDB, rightDB) = pinnedSplitDBPair(forPinnedTab: pinnedTab) {
            let partnerGuid = leftDB == pinnedGuid ? rightDB : leftDB
            guard let partnerPinned = pinnedTabs.first(where: { $0.guidInLocalDB == partnerGuid }) else {
                return false
            }

            let handleLive = tabs.first(where: { $0.guidInLocalDB == pinnedGuid })
            let partnerLive = tabs.first(where: { $0.guidInLocalDB == partnerGuid })

            if let handleLive, let partnerLive {
                applyOptimisticGroupMembership(updates: [
                    (handleLive.guid, tokenHex),
                    (partnerLive.guid, tokenHex)
                ])
                unpinSplitPanesIntoNormalList(handleLive: handleLive,
                                              partnerLive: partnerLive,
                                              handlePinned: pinnedTab,
                                              partnerPinned: partnerPinned,
                                              insertIndex: normalTabsIndex)
                let tabIds = [
                    NSNumber(value: Int64(handleLive.guid)),
                    NSNumber(value: Int64(partnerLive.guid))
                ]
                bridge.addTabsToGroup(withWindowId: windowId.int64Value,
                                      tabIds: tabIds,
                                      tokenHex: tokenHex)
                return true
            }

            // One or both panes closed: materialize both URLs as a fresh split
            // that joins the group when Chromium echoes the panes back, then
            // drop the pinned records. Mirrors `unpinClosedPinnedSplit`. Close
            // any still-live pane first so the reopen doesn't leave a duplicate
            // tab backed by the now-deleted pinned record.
            guard let partnerURL = partnerPinned.url, !partnerURL.isEmpty else {
                return false
            }
            if let handleLive { closeTab(handleLive.guid) }
            if let partnerLive { closeTab(partnerLive.guid) }
            pinnedTab.splitPartnerGuid = nil
            partnerPinned.splitPartnerGuid = nil
            localStore.updateTabSplitPartner(pinnedGuid, partnerGuid: nil)
            localStore.updateTabSplitPartner(partnerGuid, partnerGuid: nil)
            localStore.removePinnedTab(pinnedTab)
            localStore.removePinnedTab(partnerPinned)
            openTwoURLsAsSplit(primaryURL: url,
                               secondaryURL: partnerURL,
                               groupToken: tokenHex,
                               insertionIndex: normalTabsIndex)
            return true
        }

        if let normalTab = tabs.first(where: { $0.guidInLocalDB == pinnedGuid }) {
            migrateAIChatTab(for: normalTab, toNewIdentifier: nil)
            normalTab.guidInLocalDB = nil
            normalTab.isPinned = false
            if let storedTitle = pinnedTab.storedTitle {
                normalTab.applyStoredTitle(storedTitle)
            }
            normalTab.webContentWrapper?.updateTabCustomValue("")
            applyOptimisticGroupMembership(tabId: normalTab.guid, newToken: tokenHex)
            insertIntoNormalTabOrder(tabGuid: normalTab.guid,
                                     at: normalTabsIndex,
                                     syncChromiumOrder: true)
            localStore.removePinnedTab(pinnedTab)

            let tabIds = [NSNumber(value: Int64(normalTab.guid))]
            bridge.addTabsToGroup(withWindowId: windowId.int64Value,
                                  tabIds: tabIds,
                                  tokenHex: tokenHex)
        } else {
            scheduleNextNormalTabInsertion(at: normalTabsIndex,
                                           syncChromiumOrder: false,
                                           expectedGroupToken: tokenHex)
            bridge.createTabInGroup(withWindowId: windowId.int64Value,
                                    tokenHex: tokenHex,
                                    url: url,
                                    groupIndex: groupIndex,
                                    focusAfterCreate: focusAfterCreate)
            localStore.removePinnedTab(pinnedTab)
        }

        return true
    }

    /// Closes any live Chromium tab still backed by a bookmark that is about
    /// to be deleted. The bookmark custom value is cleared before close so
    /// Chromium does not keep a stale bookmark identity while tearing the tab
    /// down. Split-backed bookmarks first remove the split through Chromium as
    /// a unit. For a folder, all descendant bookmarks are processed.
    func closeOpenTabsForRemovedBookmark(_ bookmark: Bookmark) {
        var guids: [String] = []
        func collect(_ node: Bookmark) {
            if node.isFolder {
                node.children.forEach(collect)
            } else {
                guids.append(node.guid)
            }
        }
        collect(bookmark)

        var tabIdsToClose = Set<Int>()
        var tabsToClose: [Tab] = []
        var splitIdsToRemove = Set<String>()
        var orderedSplitIdsToRemove: [String] = []
        func appendTabToClose(_ tab: Tab) {
            guard tabIdsToClose.insert(tab.guid).inserted else { return }
            tabsToClose.append(tab)
        }
        func appendSplitToRemove(_ splitId: String) {
            guard splitIdsToRemove.insert(splitId).inserted else { return }
            orderedSplitIdsToRemove.append(splitId)
        }

        for guid in guids {
            if let splitId = splitBookmarkBindings[guid] {
                splitBookmarkBindings.removeValue(forKey: guid)
                appendSplitToRemove(splitId)
                if let group = splits.first(where: { $0.id == splitId }) {
                    for tabId in [group.primaryTabId, group.secondaryTabId] {
                        if let tab = tabs.first(where: { $0.guid == tabId }) {
                            appendTabToClose(tab)
                        }
                    }
                }
                continue
            }

            if let chromiumTab = tabs.first(where: { $0.guidInLocalDB == guid }) {
                appendTabToClose(chromiumTab)
            }
        }

        for tab in tabsToClose {
            migrateAIChatTab(for: tab, toNewIdentifier: nil)
            tab.guidInLocalDB = nil
            tab.webContentWrapper?.updateTabCustomValue("")
        }

        for splitId in orderedSplitIdsToRemove {
            removeSplit(splitId)
        }

        for tab in tabsToClose {
            tab.close()
        }
    }

    /// Saves a split-view bookmark as a pinned-split pair. Two pinned-tab
    /// records are persisted side-by-side with `splitPartnerGuid` set on
    /// both, so the merged pinned cell renders immediately. When the
    /// bookmark was already open as a live split, both live panes are
    /// rebound to the new pinned guids and the live `SplitGroup.isPinned`
    /// flag is set so the split keeps running under the pinned cell.
    private func savePinnedSplitFromBookmark(bookmark: Bookmark, atIndex index: Int) {
        guard let primaryURL = bookmark.url, !primaryURL.isEmpty,
              let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty else {
            return
        }

        let bookmarkGuid = bookmark.guid

        var afterGuid: String?
        if index > 0, !pinnedTabs.isEmpty {
            let afterTab = pinnedTabs[min(index - 1, pinnedTabs.count - 1)]
            afterGuid = afterTab.guidInLocalDB
        }

        let primaryPinnedGuid = UUID().uuidString
        let secondaryPinnedGuid = UUID().uuidString

        let primaryTitle = bookmark.title
        let secondaryTitle = bookmark.secondaryTitle ?? secondaryURL

        let primaryTempTab = Tab(guid: -1, url: primaryURL, isActive: false, index: 0, title: primaryTitle, customGuid: nil)
        let secondaryTempTab = Tab(guid: -1, url: secondaryURL, isActive: false, index: 0, title: secondaryTitle, customGuid: nil)

        localStore.moveOrCreatePinnedTab(primaryTempTab, after: afterGuid, profileId: profileId, newGuid: primaryPinnedGuid)
        localStore.moveOrCreatePinnedTab(secondaryTempTab, after: primaryPinnedGuid, profileId: profileId, newGuid: secondaryPinnedGuid)

        persistPinnedSplitPair(primaryDB: primaryPinnedGuid, secondaryDB: secondaryPinnedGuid)

        // If the bookmark is open as a live split, rebind both live panes
        // to the new pinned guids so the running split carries over as a
        // pinned split (matching how a single open bookmark → pinned
        // retargets its Chromium tab).
        if let splitId = splitBookmarkBindings[bookmarkGuid],
           let groupIdx = splits.firstIndex(where: { $0.id == splitId }) {
            let group = splits[groupIdx]
            let primaryLive = tabs.first(where: { $0.guid == group.primaryTabId })
            let secondaryLive = tabs.first(where: { $0.guid == group.secondaryTabId })
            if let primaryLive {
                migrateAIChatTab(for: primaryLive, toNewIdentifier: primaryPinnedGuid)
                primaryLive.guidInLocalDB = primaryPinnedGuid
                primaryLive.isPinned = true
                primaryLive.webContentWrapper?.updateTabCustomValue(primaryPinnedGuid)
            }
            if let secondaryLive {
                migrateAIChatTab(for: secondaryLive, toNewIdentifier: secondaryPinnedGuid)
                secondaryLive.guidInLocalDB = secondaryPinnedGuid
                secondaryLive.isPinned = true
                secondaryLive.webContentWrapper?.updateTabCustomValue(secondaryPinnedGuid)
            }
            splits[groupIdx].isPinned = true
            splitBookmarkBindings.removeValue(forKey: bookmarkGuid)
        }

        bookmarkManager.removeBookmark(bookmark)
        updateNormalTabs()
    }

    /// Opens a split-view bookmark as a split pair in the normal tab list.
    /// When the bookmark was already open as a live split, both live panes
    /// are unbound from `splitBookmarkBindings` and inserted adjacent at
    /// the drop index so the merged split cell carries over. Otherwise a
    /// fresh split is opened via `openTwoURLsAsSplit` (which appends at
    /// the end of the strip — Chromium's new-tab path doesn't honor a
    /// specific tab-list index here).
    private func openSplitBookmarkAsTabs(bookmark: Bookmark, atIndex index: Int) {
        guard let primaryURL = bookmark.url, !primaryURL.isEmpty,
              let secondaryURL = bookmark.secondaryUrl, !secondaryURL.isEmpty else {
            return
        }
        let bookmarkGuid = bookmark.guid

        if let splitId = splitBookmarkBindings[bookmarkGuid],
           let group = splits.first(where: { $0.id == splitId }) {
            let primaryTabGuid = group.primaryTabId
            let secondaryTabGuid = group.secondaryTabId

            // Clearing the binding first lets `updateNormalTabs` stop
            // filtering these tab guids out of the visible list (the
            // filter keyed off `splitBookmarkBoundTabIds`).
            splitBookmarkBindings.removeValue(forKey: bookmarkGuid)

            // Per-tab `syncChromiumOrder` calls would relocate one pane
            // through Chromium's `moveTab`, tripping
            // `MaybeRemoveSplitsForMove` and dissolving the SplitTabId.
            // Insert locally without syncing, then move the whole split
            // as a unit via `moveSplit`. Mirrors `unpinSplitPanesIntoNormalList`
            // and `moveSplitPairOrderLocally`.
            insertIntoNormalTabOrder(tabGuid: primaryTabGuid,
                                     at: index,
                                     syncChromiumOrder: false)
            insertIntoNormalTabOrder(tabGuid: secondaryTabGuid,
                                     at: index + 1,
                                     syncChromiumOrder: false)
            moveSplit(splitId, toIndex: index)

            bookmarkManager.removeBookmark(bookmark)
            return
        }

        // Closed split bookmark: open both URLs as a fresh split. The two
        // panes are materialized asynchronously and land at the end of the
        // strip, so pass the drop index through — `handleSplitCreated`
        // relocates the finished pair to it.
        openTwoURLsAsSplit(primaryURL: primaryURL,
                           secondaryURL: secondaryURL,
                           insertionIndex: index)
        bookmarkManager.removeBookmark(bookmark)
    }

    func updateFavoriteTabs(_ newFavoriteTabs: [Tab]) {
        guard !isIncognito else {
            pinnedTabs = []
            return
        }
        pinnedTabs = newFavoriteTabs
    }

    func addToFavorites(_ tab: Tab) {
        guard !isIncognito else { return }
        if !pinnedTabs.contains(where: { $0.guid == tab.guid }) {
            pinnedTabs.append(tab)
        }
    }

    func removeFromFavorites(_ tab: Tab) {
        guard !isIncognito else { return }
        pinnedTabs.removeAll { $0.guid == tab.guid }
    }
    
//    - (void)addBookmarkWithURL:(NSString *)urlString title:(NSString *)title parent:(NSInteger)parentId windowId:(int64_t)windowId;
   
    
    func stopAutoCompletion() {
        ChromiumLauncher.sharedInstance().bridge?.stopAutoCompleteSuggestions(windowId.int64Value)
    }
    
}

extension BrowserState {
    static func currentState() -> BrowserState? {
        MainBrowserWindowControllersManager.shared.activeWindowController?.browserState
    }
}

extension BrowserState {
    @MainActor
    static func buildLayoutMode() -> LayoutMode {
        PhiPreferences.GeneralSettings.loadLayoutMode()
    }
}

protocol BrowserWindowAware: AnyObject {
    var unsafeBrowserWindowId: Int? { get }
    var unsafeBrowserState: BrowserState? { get }
    var unsafeBrowserWindowController: MainBrowserWindowController? { get }
}

extension NSViewController: BrowserWindowAware {
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    var unsafeBrowserWindowId: Int? { view.unsafeBrowserWindowId }
    
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    weak var unsafeBrowserState: BrowserState? { view.unsafeBrowserState }
    
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    weak var unsafeBrowserWindowController: MainBrowserWindowController? { view.unsafeBrowserWindowController }
}

extension NSView: BrowserWindowAware {
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    var unsafeBrowserWindowId: Int? { unsafeBrowserWindowController?.windowId }
    
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    weak var unsafeBrowserState: BrowserState? { unsafeBrowserWindowController?.browserState }
    
    @available(*, deprecated, message: "Not Safe, should avoid using it")
    weak var unsafeBrowserWindowController: MainBrowserWindowController? { window?.windowController as? MainBrowserWindowController }
}
