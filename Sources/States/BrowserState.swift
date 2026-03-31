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
    
    /// Native ordering for non-pinned tabs, stored as Chromium guids.
    private var normalTabOrder: [Int] = []
    
    /// Pending requests to mark the next created tab as a native NTP (incognito only).
    private var pendingNativeNtpCount: Int = 0

    private struct PendingNormalTabInsertion {
        let url: String?
        let guid: Int?
        let index: Int
        
        func matches(tab: Tab) -> Bool {
            if let guid { return tab.guid == guid }
            guard let url else { return false }
            return url.isEmpty || tab.url == url
        }
    }
    /// Pending insertion state for tabs created by drag/drop into the normal-tab section.
    private var pendingNormalTabInsertion: PendingNormalTabInsertion?

    private var lastLegacyLayout: Bool?
    @Published var layoutMode: LayoutMode = .performance
    @Published var lastPhiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.loadValue()
    private var lastSentinelOnLogin: Bool = PhiPreferences.AISettings.launchSentinelOnLogin.loadValue()
    
    /// Currently focused tab.
    @Published var focusingTab: Tab?

    /// Visible bookmark items in the sidebar bookmark section.
    /// This list is maintained by `SidebarTabListViewController` and is ordered by the current
    /// visual order in the sidebar (top-to-bottom).
    ///
    /// Note: This contains *all visible bookmark items* (opened or not). Switching to an unopened
    /// bookmark will open a new tab via `openBookmark(_:)`.
    @Published var visibleBookmarkTabs: [Bookmark] = []
    
    /// AI Chat tabs keyed by the associated tab identifier.
    @Published var aiChatTabs: [String: Tab] = [:]
    
    @Published var sidebarCollapsed = false
    @Published var sidebarWidth: CGFloat = 0
    @Published var aiChatCollapsed = true
    @Published var isInFullScreenMode = false
    @Published var targetURL: String = ""

    @Published var isDraggingTab = false
    let imagePreviewState: BrowserImagePreviewState

    /// Tracks in-flight tab dragging within this BrowserState (not a singleton).
    @MainActor private(set) lazy var tabDraggingSession: TabDraggingSession = { .init(state: self) }()
    
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
        self.layoutMode = Self.buildLayoutMode()
        self.addPinnedTabObserver()
        self.tabDraggingSession.isDraggingPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                self?.isDraggingTab = isDragging
            }
            .store(in: &cancellables)
        _ = bookmarkManager
        _ = extensionManager

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let newLayoutMode = Self.buildLayoutMode()
                if self.layoutMode != newLayoutMode {
                    self.layoutMode = newLayoutMode
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
    
    @MainActor func addPinnedTabObserver() {
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
        pinnedTabs = localTabs.map { localTab in
            if let existing = pinnedTabs.first(where: { $0.guidInLocalDB == localTab.guidInLocalDB }) {
                return existing
            }
            return localTab
        }

        // Re-sync every pinned tab against the currently open Chromium tabs.
        syncAllPinnedTabsState()
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
        let allBookmarks = bookmarkManager.getAllBookmarks()
        for bookmark in allBookmarks {
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
        let openedPinnedGuids = Set(pinnedTabs.filter{ $0.isOpenned }.compactMap { $0.guidInLocalDB })
        let openedBookmarkGuids = Set(bookmarkManager.getAllBookmarks().filter{ $0.isOpened }.map { $0.guid })
        
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
            return tab.guid
        }
        let normalTabGuidSet = Set(normalTabGuids)
        
        normalTabOrder.removeAll { !normalTabGuidSet.contains($0) }
        
        for guid in normalTabGuids where !normalTabOrder.contains(guid) {
            normalTabOrder.append(guid)
        }
        
        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }
    }
    
    
    func openOrFocusPinnedTab(_ tab: Tab) {
        // FIXME: FavoriteTabViewController can hand back a different object instance for the same
        // logical tab because it uses DifferenceDatasource. Resolve against `pinnedTabs` first.
        guard let guid = tab.guidInLocalDB, let realTab = pinnedTabs.first(where: { $0.guidInLocalDB == guid }) else {
            return
        }
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
        // Dispatch to the focusing tab's AI Chat state
        focusingTab?.toggleAIChat(collapse)
        
        // Also update the global state for backward compatibility
        // (e.g., for AIChatViewController in non-traditional layout)
        if let collapse {
            aiChatCollapsed = collapse
        } else {
            aiChatCollapsed.toggle()
        }
    }
    
    func toggleFullScreenMode(_ fullScreen: Bool) {
        if fullScreen != isInFullScreenMode {
            isInFullScreenMode.toggle()
        }
    }
    
    func focuseTab(_ tab: Tab) {
        // AI Chat Tab cannot become focusingTab
        if let customGuid = tab.guidInLocalDB, Self.isAIChatId(customGuid) {
            return
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
        focusingTab = tab
    }
    
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

        let customGuid = Self.aiChatId(for: identifier)
        createTab("chrome-extension://fenmfiepnpdlhplemgijlimpbebebljo/index.html?is_sidebar=1&tabId=\(chromeTabId)", customGuid: customGuid, focusAfterCreate: false)
    }
    
    /// Close the AI Chat tab associated with the specified identifier
    /// - Parameter identifier: The tab identifier whose AI Chat tab should be closed
    func closeAIChatTab(for identifier: String) {
        if let aiTab = aiChatTabs[identifier] {
            aiTab.close()
            aiChatTabs.removeValue(forKey: identifier)
        }
    }
    
    /// Close the normal tab associated with the specified identifier (called when AI Chat tab is closed)
    /// - Parameter identifier: The tab identifier of the normal tab to close
    private func closeAssociatedTab(for identifier: String) {
        if let tab = findTabByIdentifier(identifier) {
            tab.close()
        }
    }
    
    func handleNewTabFromChromium(_ tab: Tab) {
        // Check if this is an AI Chat Tab
        if let customGuid = tab.guidInLocalDB,
           Self.isAIChatId(customGuid),
           let identifier = Self.associatedIdentifier(from: customGuid) {
            aiChatTabs[identifier] = tab
            return  // Don't add to regular tabs
        }

        if consumePendingNativeNTP() {
            tab.usesNativeNTP = true
        }
        
        tabs.append(tab)

        // Reattach to a pinned tab entry when the local guid matches.
        if let localGuid = tab.guidInLocalDB,
           let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == localGuid }) {
            pinnedTab.isOpenned = true
            pinnedTab.setWebContentsWrapper(wrapper: tab.webContentWrapper)
            pinnedTab.guid = tab.guid
        }
        
        // Reattach to a bookmark entry when the local guid matches.
        handleBookmarkTabOpened(tab)

        // Honor any pending insertion target for tabs promoted into the normal tab list.
        if let pending = pendingNormalTabInsertion {
            if pending.matches(tab: tab) {
                insertIntoNormalTabOrder(tabGuid: tab.guid, at: pending.index)
                pendingNormalTabInsertion = nil
                return
            }
        }
        
        updateNormalTabs()
    }
    
    func closeTab(_ tabId: Int) {
        // When an AI Chat tab closes, also clear its association and close the linked content tab.
        for (identifier, aiTab) in aiChatTabs {
            if aiTab.guid == tabId {
                aiChatTabs.removeValue(forKey: identifier)
                // Delay the linked tab close so Chromium can finish its selection updates first.
                DispatchQueue.main.async { [weak self] in
                    self?.closeAssociatedTab(for: identifier)
                }
                return
            }
        }
        
        // Resolve the normal tab after AI Chat-tab handling has been ruled out.
        guard let closedTab = tabs.first(where: { $0.guid == tabId }) else { return }

        // Delay the linked AI Chat close so Chromium can finish its selection updates first.
        let identifier = getTabIdentifier(for: closedTab)
        DispatchQueue.main.async { [weak self] in
            self?.closeAIChatTab(for: identifier)
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

        // Remove the tab from the in-memory list after linked state is updated.
        tabs.removeAll { $0.guid == tabId }
        updateNormalTabs()
    }
    
    func closeTabs(keeping: Set<Int>) {
        for tab in tabs {
            if !keeping.contains(tab.guid) {
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
    
    func toggleTabPinStatus(_ tabId: Int, guidInDB: String?) {
        if let opennedTab = tabs.first(where: { $0.guid == tabId }) {
            if opennedTab.isPinned || opennedTab.guidInLocalDB?.isEmpty == false {
                // Migrate AI Chat tab association before changing identifier
                // When unpinning, identifier changes from guidInLocalDB to chromium guid
                migrateAIChatTab(for: opennedTab, toNewIdentifier: nil)
                
                localStore.removePinnedTab(opennedTab)
                opennedTab.guidInLocalDB = nil
                if let wrapper = opennedTab.webContentWrapper {
                    wrapper.updateTabCustomValue("")
                }
                opennedTab.isPinned = false
                updateNormalTabs()
            } else {
                // create Local tab
                // Note: moveNormalTab already handles AI Chat tab migration
                moveNormalTab(tabId: opennedTab.guid, toPinnd: -1, selectAfterMove: opennedTab.isActive)
                opennedTab.isPinned = true
                updateNormalTabs()
            }
        } else if let pinnedTab = pinnedTabs.first(where: { $0.guidInLocalDB == guidInDB }) {
            localStore.removePinnedTab(pinnedTab)
            createTab(pinnedTab.url ?? "", customGuid: nil, focusAfterCreate: false)
        }
    }
    
    func createTab(_ url: String?, customGuid: String? = nil, focusAfterCreate: Bool = true) {
        AppLogInfo("🪟 [Restore] createTab request windowId=\(windowId) focus=\(focusAfterCreate) url=\(url ?? "") customGuid=\(customGuid ?? "nil")")
        ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url ?? "",
                                                               windowId: windowId.int64Value,
                                                               customGuid: customGuid,
                                                               focusAfterCreate: focusAfterCreate)
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
        updateNormalTabs()
    }
    
    func move(tab: Tab, to newIndex: Int, selectAfterMove: Bool) {
        guard let wrapper = tab.webContentWrapper else {
            return
        }
        wrapper.moveSelf(to: newIndex, selectAfterMove: selectAfterMove)
    }
    
    /// Reorders normal tabs locally without notifying Chromium.
    /// - Parameters:
    ///   - fromIndex: Source index inside `normalTabs`.
    ///   - toIndex: Destination insertion index inside `normalTabs`.
    func moveNormalTabLocally(from fromIndex: Int, to toIndex: Int) {
        guard fromIndex >= 0, fromIndex < normalTabOrder.count else { return }
        
        let guid = normalTabOrder.remove(at: fromIndex)
        
        var insertIndex = toIndex
        if fromIndex < toIndex {
            insertIndex = max(0, toIndex - 1)
        }
        insertIndex = min(insertIndex, normalTabOrder.count)
        
        normalTabOrder.insert(guid, at: insertIndex)
        
        normalTabs = normalTabOrder.compactMap { guid in
            tabs.first { $0.guid == guid }
        }
    }
    
    func scheduleNormalTabInsertion(tabGuid: Int, at index: Int) {
        pendingNormalTabInsertion = PendingNormalTabInsertion(url: nil, guid: tabGuid, index: index)
    }
    
    /// Inserts a tab guid into `normalTabOrder` at the requested index.
    /// - Parameters:
    ///   - tabGuid: Chromium tab guid.
    ///   - index: Destination index relative to `normalTabs`.
    private func insertIntoNormalTabOrder(tabGuid: Int, at index: Int) {
        normalTabOrder.removeAll { $0 == tabGuid }
        
        let insertIndex = min(max(0, index), normalTabOrder.count)
        normalTabOrder.insert(tabGuid, at: insertIndex)
        
        updateNormalTabs()
    }
    
    /// Reorder pinned  tab
    func movePinnedTab(tab: Tab, to newIndex: Int, selectAfterMove: Bool) {
        var after: String?
        if newIndex > 0, !pinnedTabs.isEmpty {
            let tab = pinnedTabs[newIndex - 1]
            after = tab.guidInLocalDB
        }
        
        localStore.moveOrCreatePinnedTab(tab, after: after, profileId: profileId)
//        if !tab.isOpenned {
//            openOrFocusPinnedTab(tab)
//        }
    }
    
    func moveNormalTab(tabId: Int, toPinnd pinnedIndex: Int, selectAfterMove: Bool = false) {
        guard let tab = tabs.first(where: { $0.guid == tabId }) else {
            return
        }
        var afterGuid: String?
        if pinnedIndex > 0, !pinnedTabs.isEmpty {
            let afterTab = pinnedTabs[pinnedIndex - 1]
            afterGuid = afterTab.guidInLocalDB
        } else if pinnedIndex == -1, !pinnedTabs.isEmpty {
            let afterTab = pinnedTabs.last!
            afterGuid = afterTab.guidInLocalDB
        }
        
        let newGuid = UUID().uuidString
        
        // Migrate AI Chat tab association before changing identifier
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
            
            insertIntoNormalTabOrder(tabGuid: normalTab.guid, at: normalIndex)
        } else {
            // New tabs are appended first, so record the intended insertion index up front.
            pendingNormalTabInsertion = PendingNormalTabInsertion(url: pinnedTab.url ?? "", guid: nil, index: normalIndex)
            ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: pinnedTab.url ?? "", at: -1, windowId: windowId, customGuid: nil)
        }
      
        localStore.removePinnedTab(pinnedTab)
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
        
        // Migrate AI Chat tab association before changing identifier
        migrateAIChatTab(for: tab, toNewIdentifier: newBookmarkGuid)
        
        localStore.createBookmark(url: url,
                                  title: tab.title,
                                  profileId: profileId,
                                  parentId: parentGuid,
                                  index: index,
                                  guid: newBookmarkGuid)
        
        tab.guidInLocalDB = newBookmarkGuid
        
        if let wrapper = tab.webContentWrapper {
            wrapper.updateTabCustomValue(newBookmarkGuid)
        }
        
        updateNormalTabs()
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
        
        let newBookmarkGuid = UUID().uuidString
        
        // Prefer the persisted title over the KVO-driven display title.
        let titleForBookmark = pinnedTab.storedTitle ?? pinnedTab.title
        
        localStore.createBookmark(url: url,
                                  title: titleForBookmark,
                                  profileId: profileId,
                                  parentId: parentGuid,
                                  index: index,
                                  guid: newBookmarkGuid)
        
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
            insertIntoNormalTabOrder(tabGuid: chromiumTab.guid, at: index)
        } else {
            // Create a new Chromium tab and let `newTab()` apply the pending insertion point.
            pendingNormalTabInsertion = PendingNormalTabInsertion(url: url, guid: nil, index: index)
            ChromiumLauncher.sharedInstance().bridge?.createNewTab(withUrl: url,
                                                                   at: -1,
                                                                   windowId: windowId,
                                                                   customGuid: nil)
        }
        
        // Remove the old bookmark entry after migration.
        bookmarkManager.removeBookmark(realBookmark)
    }
    
    func updateFavoriteTabs(_ newFavoriteTabs: [Tab]) {
        pinnedTabs = newFavoriteTabs
    }

    func addToFavorites(_ tab: Tab) {
        if !pinnedTabs.contains(where: { $0.guid == tab.guid }) {
            pinnedTabs.append(tab)
        }
    }

    func removeFromFavorites(_ tab: Tab) {
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
