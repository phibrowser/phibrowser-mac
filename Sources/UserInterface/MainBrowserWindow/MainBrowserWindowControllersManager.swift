// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation

protocol MainBrowserWindowLookup {
    func controller(for windowId: Int) -> MainBrowserWindowController?
}

/// Represents a browser window created before browser access is available.
/// These windows are held until either Guest Mode or signed-in access is ready.
struct DanglingWindow {
    let window: NSWindow
    let windowId: Int
    let browserType: ChromiumBrowserType
    let profileId: String
    let spaceId: String
    /// Slot resolved at window-creation time (pre-login). Captured here so
    /// `processDanglingWindow` hands it to the real `MainBrowserWindowController`
    /// without re-resolving — the slot already holds any pending spawn
    /// intent / frame for this windowId.
    weak var slot: SpaceWindowSlot?
    /// Tabs created before browser access, replayed once access is available.
    var pendingTabs: [Tab] = []
    /// Tab-group events emitted before the window's BrowserState exists
    /// (e.g., Chromium replays an existing-group state right after the
    /// window is created but before browser access). Replayed after the pending
    /// tabs in `processDanglingWindow` so kCreated handlers find the
    /// already-arrived members.
    var pendingGroupActions: [TabGroupEvent.TabGroupAction] = []
}

class MainBrowserWindowControllersManager: MainBrowserWindowLookup {
    private struct RebindGroupSnapshot {
        let token: String
        let title: String
        let color: GroupColor
        let isCollapsed: Bool
        let tabIds: [Int]
    }

    private struct RebindWindowPresentation {
        let frame: NSRect
        let level: NSWindow.Level
        let alphaValue: CGFloat
        let wasVisible: Bool
        let wasMiniaturized: Bool
        let wasKey: Bool
    }

    static let shared = MainBrowserWindowControllersManager()
    private(set) var activeWindowController: MainBrowserWindowController? {
        didSet {
            guard oldValue !== activeWindowController else { return }
            NotificationCenter.default.post(
                name: .activeBrowserWindowDidChange,
                object: activeWindowController
            )
        }
    }
    private var windowControllers: Set<MainBrowserWindowController> = []
    
    /// Windows waiting to be converted to MainBrowserWindowController.
    private var danglingWindows: [DanglingWindow] = []

    /// Original per-window interaction state captured while Guest-to-account
    /// migration temporarily freezes browser input.
    private var guestTransitionOriginalIgnoresMouseEvents: [ObjectIdentifier: Bool] = [:]
    private(set) var isGuestTransitionInteractionBlocked = false
    
    private init() {
        // Listen for login completion to process dangling windows
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLoginCompleted),
            name: .loginCompleted,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBrowserAccessStateDidChange),
            name: .browserAccessStateDidChange,
            object: nil
        )
    }
    
    /// Add a window created before browser access is available.
    /// The window stays hidden until Guest or signed-in access is granted.
    /// - Parameters:
    ///   - window: The NSWindow created by Chromium
    ///   - windowId: The window identifier
    ///   - browserType: The type of browser window (normal, incognito, etc.)
    func addDanglingWindow(_ window: NSWindow,
                           windowId: Int,
                           browserType: ChromiumBrowserType,
                           profileId: String,
                           spaceId: String = LocalStore.defaultSpaceId,
                           slot: SpaceWindowSlot? = nil) {
        assert(Thread.isMainThread)
        AppLogInfo("🪟 [WindowManager] Adding dangling window - windowId: \(windowId), type: \(browserType.rawValue)")

        // Hide the window until browser access is available.
        hideDanglingWindow(window)

        let danglingWindow = DanglingWindow(window: window,
                                            windowId: windowId,
                                            browserType: browserType,
                                            profileId: profileId,
                                            spaceId: spaceId,
                                            slot: slot)
        danglingWindows.append(danglingWindow)
        applyGuestTransitionInteractionBlockIfNeeded(to: window)

        AppLogInfo("🪟 [WindowManager] Dangling windows count: \(danglingWindows.count)")
    }
    
    /// Add a pending tab to a dangling window.
    /// The tab is replayed when browser access creates the window controller.
    /// - Parameters:
    ///   - tab: The tab created by Chromium
    ///   - windowId: The window identifier to associate the tab with
    /// - Returns: true if the tab was added to a dangling window, false if no matching window found
    @discardableResult
    func addPendingTabToDanglingWindow(_ tab: Tab, windowId: Int) -> Bool {
        assert(Thread.isMainThread)
        
        guard let index = danglingWindows.firstIndex(where: { $0.windowId == windowId }) else {
            AppLogWarn("🪟 [WindowManager] No dangling window found for windowId: \(windowId)")
            return false
        }
        
        danglingWindows[index].pendingTabs.append(tab)
        AppLogInfo("🪟 [WindowManager] Added pending tab to dangling window - windowId: \(windowId), tabGuid: \(tab.guid), total pending tabs: \(danglingWindows[index].pendingTabs.count)")
        return true
    }
    
    /// Check if a dangling window exists for the given window ID
    /// - Parameter windowId: The window identifier to check
    /// - Returns: true if a dangling window exists for the given ID
    func hasDanglingWindow(for windowId: Int) -> Bool {
        return danglingWindows.contains { $0.windowId == windowId }
    }

    /// Buffer a tab-group action for a dangling window so it can be
    /// replayed once the window's BrowserState comes up. Without this,
    /// any group event (kCreated/kClosed/kJoined/kLeft/kVisualsChanged)
    /// that arrives between window creation and login is silently
    /// dropped by `EventBus.handleWindowEvent`'s "Window not found"
    /// guard, permanently flattening grouped tabs on cold start.
    @discardableResult
    func addPendingGroupActionToDanglingWindow(_ action: TabGroupEvent.TabGroupAction,
                                                windowId: Int) -> Bool {
        assert(Thread.isMainThread)
        guard let index = danglingWindows.firstIndex(where: { $0.windowId == windowId }) else {
            return false
        }
        danglingWindows[index].pendingGroupActions.append(action)
        AppLogInfo(
            "🪟 [WindowManager] Buffered group action for dangling window " +
            "windowId=\(windowId) total=\(danglingWindows[index].pendingGroupActions.count)"
        )
        return true
    }
    
    /// Hide a dangling window completely
    private func hideDanglingWindow(_ window: NSWindow) {
        // Set window level to behind everything to prevent it from stealing focus
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
        // Hide the window completely
        window.setFrame(NSRect(origin: .zero, size: .zero), display: false)
        window.setIsVisible(false)
        window.alphaValue = 0
        window.orderOut(nil)
    }
    
    /// Process all dangling windows after login or explicit Guest entry.
    @MainActor
    @objc private func handleLoginCompleted() {
        processDanglingWindowsIfBrowserAccessIsAvailable()
    }

    /// Guest entry grants the same Native-window access without emitting a
    /// semantically false login-completed event.
    @MainActor
    @objc private func handleBrowserAccessStateDidChange() {
        // Crash recovery releases browser access while the promotion fence is
        // still active. The receipt-aware rebind below owns those dangling
        // windows so they cannot be constructed and shown once with Guest
        // identifiers before immediately being rebuilt with target identifiers.
        guard !ApplicationState.shared.isGuestAccountPromotionInProgress else {
            return
        }
        // SpaceManager consumes the same notification to bind the new
        // local-data owner. Defer one turn so correctness never depends on
        // NotificationCenter observer registration order.
        DispatchQueue.main.async { [weak self] in
            self?.processDanglingWindowsIfBrowserAccessIsAvailable()
        }
    }

    @MainActor
    private func processDanglingWindowsIfBrowserAccessIsAvailable() {
        assert(Thread.isMainThread)
        guard ApplicationState.shared.canUseBrowser,
              let account = AccountController.shared.localDataAccount else {
            return
        }
        materializeDanglingWindows(to: account, migrationReceipt: nil)
    }

    @MainActor
    private func materializeDanglingWindows(
        to account: Account,
        migrationReceipt: GuestDataMigrationReceipt?
    ) {
        assert(Thread.isMainThread)
        AppLogInfo(
            "🪟 [WindowManager] Browser access granted - processing " +
            "\(danglingWindows.count) dangling window(s)"
        )

        var danglingSlots: [SpaceWindowSlot] = []
        for danglingWindow in danglingWindows {
            guard let slot = danglingWindow.slot,
                  !danglingSlots.contains(where: { $0 === slot }) else {
                continue
            }
            danglingSlots.append(slot)
        }

        for danglingWindow in danglingWindows {
            processDanglingWindow(
                danglingWindow,
                account: account,
                migrationReceipt: migrationReceipt
            )
        }

        // Clear dangling windows after processing
        danglingWindows.removeAll()
        removeEmptyDanglingSlots(danglingSlots)
        AppLogInfo("🪟 [WindowManager] All dangling windows processed")
    }
    
    /// Restore a dangling window, or close it if no tabs arrived before access.
    @MainActor
    private func processDanglingWindow(
        _ danglingWindow: DanglingWindow,
        account: Account,
        migrationReceipt: GuestDataMigrationReceipt?
    ) {
        AppLogInfo("🪟 [WindowManager] Processing dangling window - windowId: \(danglingWindow.windowId), pending tabs: \(danglingWindow.pendingTabs.count)")
        guard !danglingWindow.pendingTabs.isEmpty else {
            closeEmptyDanglingWindow(danglingWindow)
            return
        }

        let destinationProfileId =
            migrationReceipt?.profileIDs[danglingWindow.profileId]
            ?? danglingWindow.profileId
        let destinationSpaceId =
            migrationReceipt?.spaceIDs[danglingWindow.spaceId]
            ?? danglingWindow.spaceId
        let customValueUpdates: [(tab: Tab, guid: String)]
        if let migrationReceipt {
            danglingWindow.slot?.prepareAccountTransitionPendingWindow(
                from: danglingWindow.spaceId,
                to: destinationSpaceId
            )
            customValueUpdates = remapLiveLocalDataIdentifiers(
                in: danglingWindow.pendingTabs,
                destinationProfileId: destinationProfileId,
                destinationSpaceId: destinationSpaceId,
                receipt: migrationReceipt
            )
            for tab in danglingWindow.pendingTabs {
                tab.profileId = destinationProfileId
            }
        } else {
            customValueUpdates = []
        }

        // Create the MainBrowserWindowController now that browser access is ready.
        // The slot was resolved at addDanglingWindow time; if it was dropped
        // by the manager in the meantime (unlikely pre-login but defensive),
        // fall back to a fresh slot for `.normal` windows so the new
        // controller still has somewhere to register.
        let slot: SpaceWindowSlot?
        if danglingWindow.browserType == .normal || danglingWindow.browserType == .agentSpace {
            slot = danglingWindow.slot
                ?? SpaceManager.shared.createSlot(initialSpaceId: destinationSpaceId)
        } else {
            slot = nil
        }
        let windowController = createWindowController(
            window: danglingWindow.window,
            windowId: danglingWindow.windowId,
            browserType: danglingWindow.browserType,
            profileId: destinationProfileId,
            spaceId: destinationSpaceId,
            account: account,
            slot: slot
        )
        
        // Process pending tabs that were created before browser access.
        for tab in danglingWindow.pendingTabs {
            AppLogInfo("🪟 [WindowManager] Processing pending tab - tabGuid: \(tab.guid)")
            if tab.url?.hasPrefix("chrome://newtab") ?? false {
                tab.title = "New Tab"
            }
            windowController.browserState.handleNewTabFromChromium(tab)
        }

        // Replay buffered tab-group actions AFTER the tabs are in place so
        // kCreated / kJoined handlers see their members already on
        // `BrowserState.tabs` (or, for races, populate the
        // `pendingGroupClaims` map for backfill on later arrival).
        if !danglingWindow.pendingGroupActions.isEmpty {
            AppLogInfo(
                "🪟 [WindowManager] Replaying \(danglingWindow.pendingGroupActions.count) " +
                "buffered group action(s) for windowId=\(danglingWindow.windowId)"
            )
            for action in danglingWindow.pendingGroupActions {
                EventBus.shared.send(TabGroupEvent(browserId: danglingWindow.windowId,
                                                    action: action))
            }
        }

        if windowController.browserState.focusingTab == nil,
            let last = danglingWindow.pendingTabs.last {
            windowController.browserState.focuseTab(last)
        }
        for update in customValueUpdates {
            update.tab.webContentWrapper?.updateTabCustomValue(update.guid)
        }
        // Restore and show the window
        windowController.restoreAndShowWindow()
        
        AppLogInfo("🪟 [WindowManager] Dangling window processed and displayed - windowId: \(danglingWindow.windowId)")
    }

    @MainActor
    private func closeEmptyDanglingWindow(_ danglingWindow: DanglingWindow) {
        AppLogInfo("🪟 [WindowManager] Closing empty dangling window - windowId: \(danglingWindow.windowId)")
        if let bridge = ChromiumLauncher.sharedInstance().bridge {
            bridge.executeCommand(
                Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue),
                windowId: Int64(danglingWindow.windowId)
            )
        } else {
            danglingWindow.window.close()
        }
    }

    @MainActor
    private func removeEmptyDanglingSlots(_ slots: [SpaceWindowSlot]) {
        for slot in slots where slot.windowsBySpaceId.isEmpty {
            SpaceManager.shared.removeSlot(slot)
        }
    }
    
    func retainWindowControllerUntilWindowClosed(_ windowController: MainBrowserWindowController) {
        assert(Thread.isMainThread)
        guard !windowControllers.contains(windowController), let window = windowController.window else {
            return
        }
        
        if windowControllers.isEmpty {
            activeWindowController = windowController
        }
        
        windowControllers.insert(windowController)
        applyGuestTransitionInteractionBlockIfNeeded(to: window)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)
    }

    /// Creates the native owner matching Chromium's semantic window type.
    /// Keeping this decision in the registry preserves specialized state and
    /// presentation when a dangling window is materialized or an account
    /// transition rebinds an existing NSWindow.
    @MainActor
    @discardableResult
    func createWindowController(
        window: NSWindow,
        windowId: Int,
        browserType: ChromiumBrowserType,
        profileId: String,
        spaceId: String = LocalStore.defaultSpaceId,
        account: Account = AccountController.shared.account
            ?? AccountController.defaultAccount,
        slot: SpaceWindowSlot? = nil
    ) -> MainBrowserWindowController {
        if browserType == .kiosk || browserType == .kioskIncognito {
            return KioskBrowserWindowController(
                window: window,
                windowId: windowId,
                browserType: browserType,
                profileId: profileId,
                account: account
            )
        }
        return MainBrowserWindowController(
            window: window,
            windowId: windowId,
            browserType: browserType,
            profileId: profileId,
            spaceId: spaceId,
            account: account,
            slot: slot
        )
    }

    /// Freezes or restores browser-window mouse interaction during the
    /// Guest-to-account transaction. Each window's prior value is preserved,
    /// including windows that arrive while the transaction is in progress.
    @MainActor
    func setGuestTransitionInteractionBlocked(_ blocked: Bool) {
        assert(Thread.isMainThread)
        guard blocked != isGuestTransitionInteractionBlocked else { return }
        isGuestTransitionInteractionBlocked = blocked

        let windows = trackedWindows()
        if blocked {
            for window in windows {
                applyGuestTransitionInteractionBlockIfNeeded(to: window)
            }
            return
        }

        for window in windows {
            let identifier = ObjectIdentifier(window)
            guard let originalValue = guestTransitionOriginalIgnoresMouseEvents[identifier] else {
                continue
            }
            window.ignoresMouseEvents = originalValue
        }
        guestTransitionOriginalIgnoresMouseEvents.removeAll()
    }

    /// Rebuilds Native browser controllers against a new local-data account
    /// while preserving the existing NSWindows and Chromium WebContents.
    ///
    /// This is the commit seam for Guest-to-account migration: callers first
    /// migrate local data, then invoke this method with the destination
    /// account. No Chromium window is closed or recreated.
    @MainActor
    func rebindWindowControllers(to account: Account) {
        performWindowControllerRebind(to: account, migrationReceipt: nil)
    }

    /// Guest migration variant of `rebindWindowControllers(to:)`. Identifier
    /// mappings are applied to the Native controller configuration and to
    /// every live Chromium tab's persisted custom value before replay.
    @MainActor
    func rebindWindowControllers(
        to account: Account,
        migrationReceipt: GuestDataMigrationReceipt
    ) {
        performWindowControllerRebind(
            to: account,
            migrationReceipt: migrationReceipt
        )
    }

    @MainActor
    private func performWindowControllerRebind(
        to account: Account,
        migrationReceipt: GuestDataMigrationReceipt?
    ) {
        assert(Thread.isMainThread)
        let controllers = Array(windowControllers)
            .filter { migrationReceipt != nil || $0.account !== account }
            .sorted { $0.windowId < $1.windowId }
        let shouldMaterializeDanglingWindows =
            migrationReceipt != nil && !danglingWindows.isEmpty
        guard !controllers.isEmpty || shouldMaterializeDanglingWindows else {
            return
        }

        let wasAlreadyBlocked = isGuestTransitionInteractionBlocked
        if !wasAlreadyBlocked {
            setGuestTransitionInteractionBlocked(true)
        }
        defer {
            if !wasAlreadyBlocked {
                setGuestTransitionInteractionBlocked(false)
            }
        }

        AppLogInfo(
            "🪟 [WindowManager] Rebinding \(controllers.count) window controller(s) " +
            "and materializing " +
            "\(shouldMaterializeDanglingWindows ? danglingWindows.count : 0) " +
            "dangling window(s) to account \(account.userID)"
        )

        for oldController in controllers {
            rebindWindowController(
                oldController,
                to: account,
                migrationReceipt: migrationReceipt
            )
        }
        if let migrationReceipt {
            // The promotion observer intentionally left recovery windows
            // dangling. SpaceManager has now consumed the access notification
            // and bound the target store, so map every identifier before the
            // first controller construction and show each window only once.
            materializeDanglingWindows(
                to: account,
                migrationReceipt: migrationReceipt
            )
        }
    }

    @MainActor
    private func rebindWindowController(
        _ oldController: MainBrowserWindowController,
        to account: Account,
        migrationReceipt: GuestDataMigrationReceipt?
    ) {
        guard let window = oldController.window else {
            windowControllers.remove(oldController)
            if activeWindowController === oldController {
                activeWindowController = nil
            }
            return
        }

        let oldState = oldController.browserState
        let tabs = oldState.tabs
        let aiChatTabs = Array(oldState.aiChatTabs.values)
        let activeTabId = oldState.focusingTab?.guid
        let groups = oldState.groups.values
            .map { info in
                RebindGroupSnapshot(
                    token: info.token,
                    title: info.title,
                    color: info.color,
                    isCollapsed: info.isCollapsed,
                    tabIds: tabs.filter { $0.groupToken == info.token }.map(\.guid)
                )
            }
            .sorted { $0.token < $1.token }
        let splits = oldState.splits
        let selectedTabIds = oldState.multiSelection.guids
        let selectedBookmarkGuids = Set(oldState.multiSelection.bookmarkGuids.map {
            migrationReceipt?.mappings.bookmarkGUIDs[$0] ?? $0
        })
        let destinationProfileId =
            migrationReceipt?.profileIDs[oldController.profileId]
            ?? oldController.profileId
        let destinationSpaceId =
            migrationReceipt?.spaceIDs[oldController.spaceId]
            ?? oldController.spaceId
        let presentation = RebindWindowPresentation(
            frame: window.frame,
            level: window.level,
            alphaValue: window.alphaValue,
            wasVisible: window.isVisible,
            wasMiniaturized: window.isMiniaturized,
            wasKey: window.isKeyWindow
        )
        let wasActiveController = activeWindowController === oldController

        // Eviction is deliberately side-effect-light: unlike unregisterWindow,
        // it neither hands the slot to a sibling nor starts a close cascade.
        if oldController.browserType == .normal
            || oldController.browserType == .incognitoSpace
            || oldController.browserType == .agentSpace {
            _ = oldController.slot?.prepareAccountTransitionWindowReplacement(
                oldController,
                from: oldController.spaceId,
                to: destinationSpaceId
            )
        }
        detachWindowControllerForRebind(oldController, window: window)

        let customValueUpdates: [(tab: Tab, guid: String)]
        if let migrationReceipt {
            customValueUpdates = remapLiveLocalDataIdentifiers(
                in: tabs + aiChatTabs,
                destinationProfileId: destinationProfileId,
                destinationSpaceId: destinationSpaceId,
                receipt: migrationReceipt
            )
        } else {
            customValueUpdates = []
        }
        for tab in tabs + aiChatTabs {
            tab.profileId = destinationProfileId
        }

        let replacement = createWindowController(
            window: window,
            windowId: oldController.windowId,
            browserType: oldController.browserType,
            profileId: destinationProfileId,
            spaceId: destinationSpaceId,
            account: account,
            slot: oldController.slot
        )
        let newState = replacement.browserState

        for split in splits where split.isPinned {
            newState.pendingPinnedSplitMarkByCreateId.insert(split.id)
        }

        var previousTabId: Int?
        var restoredTabs: [(tab: Tab, context: NativeTabCreationContext)] = []
        restoredTabs.reserveCapacity(tabs.count + aiChatTabs.count)
        for tab in tabs {
            restoredTabs.append((
                tab: tab,
                context: NativeTabCreationContext(
                    isActiveAtCreation: tab.guid == activeTabId,
                    creationKind: .restore,
                    insertAfterTabId: previousTabId
                )
            ))
            previousTabId = tab.guid
        }
        for tab in aiChatTabs {
            restoredTabs.append((
                tab: tab,
                context: NativeTabCreationContext(creationKind: .restore)
            ))
        }

        let splitActions = splits.map {
            SplitEvent.SplitAction.created(
                splitId: $0.id,
                primaryTabId: $0.primaryTabId,
                secondaryTabId: $0.secondaryTabId,
                layout: $0.layout,
                ratio: $0.ratio
            )
        }
        newState.handleRestoredWindowSnapshot(
            BrowserState.RestoredWindowSnapshot(
                tabs: restoredTabs,
                activeTabId: activeTabId,
                splitActions: splitActions
            )
        )

        for group in groups {
            newState.handleTabGroupCreated(
                token: group.token,
                title: group.title,
                color: group.color,
                isCollapsed: group.isCollapsed,
                initialTabIds: group.tabIds
            )
        }
        _ = newState.replaceMultiSelection(
            tabIds: selectedTabIds,
            bookmarkGuids: selectedBookmarkGuids
        )
        for update in customValueUpdates {
            update.tab.webContentWrapper?.updateTabCustomValue(update.guid)
        }

        window.setFrame(presentation.frame, display: true)
        window.level = presentation.level
        window.alphaValue = presentation.alphaValue
        if presentation.wasMiniaturized {
            window.miniaturize(nil)
        } else if presentation.wasVisible {
            if presentation.wasKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        } else {
            window.orderOut(nil)
        }
        if wasActiveController {
            activeWindowController = replacement
        }

        AppLogInfo(
            "🪟 [WindowManager] Rebound windowId=\(replacement.windowId) " +
            "profileId=\(destinationProfileId) spaceId=\(destinationSpaceId) " +
            "tabs=\(tabs.count) groups=\(groups.count) splits=\(splits.count)"
        )
    }

    private func remapLiveLocalDataIdentifiers(
        in tabs: [Tab],
        destinationProfileId: String,
        destinationSpaceId: String,
        receipt: GuestDataMigrationReceipt
    ) -> [(tab: Tab, guid: String)] {
        var customValueUpdates: [(tab: Tab, guid: String)] = []
        let targetScope =
            PinnedTabScope(rawValue: receipt.mappings.targetPinnedTabScopeRawValue)
            ?? .profile
        let pinnedOwner: (profileId: String?, spaceId: String?)
        switch targetScope {
        case .space:
            pinnedOwner = (destinationProfileId, destinationSpaceId)
        case .profile:
            pinnedOwner = (destinationProfileId, nil)
        case .app:
            pinnedOwner = (nil, nil)
        }

        for tab in tabs {
            if let sourceLineageId = tab.pinnedLineageId,
               let targetLineageId = receipt.mappings.pinLineageIDs[sourceLineageId] {
                tab.pinnedLineageId = targetLineageId
            }
            guard let sourceGUID = tab.guidInLocalDB, !sourceGUID.isEmpty else {
                continue
            }

            let pinnedTargets = receipt.mappings.pinnedTargets(for: sourceGUID)
            let pinnedTarget = receipt.mappings.pinnedTarget(
                for: sourceGUID,
                profileID: pinnedOwner.profileId,
                spaceID: pinnedOwner.spaceId
            ) ?? (pinnedTargets.count == 1 ? pinnedTargets[0] : nil)
            let targetGUID: String?
            if let pinnedTarget {
                targetGUID = pinnedTarget.targetGUID
                tab.splitPartnerGuid = pinnedTarget.targetSplitPartnerGUID
            } else if pinnedTargets.isEmpty {
                targetGUID = receipt.mappings.bookmarkGUIDs[sourceGUID]
            } else {
                targetGUID = nil
                AppLogError(
                    "🪟 [WindowManager] Ambiguous pinned GUID migration for " +
                    "source=\(sourceGUID) profile=\(destinationProfileId) " +
                    "space=\(destinationSpaceId)"
                )
            }

            guard let targetGUID, targetGUID != sourceGUID else { continue }
            tab.guidInLocalDB = targetGUID
            customValueUpdates.append((tab, targetGUID))
        }
        return customValueUpdates
    }

    private func detachWindowControllerForRebind(
        _ controller: MainBrowserWindowController,
        window: NSWindow
    ) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.removeObserver(controller, name: nil, object: window)
        controller.cancellables.removeAll()
        WindowThemeMessageRouter.shared.stopObservingWindow(windowId: controller.windowId)
        windowControllers.remove(controller)
    }

    private func trackedWindows() -> [NSWindow] {
        var result: [NSWindow] = []
        var identifiers = Set<ObjectIdentifier>()
        let browserWindows = windowControllers.compactMap(\.window)
            + danglingWindows.map(\.window)
        let otherPhiWindows = NSApp.windows.filter { window in
            // Recovery/onboarding remains usable; failure alerts are created
            // after this snapshot and therefore are not frozen.
            !(window.windowController is OnboardingWindowController)
        }
        for window in browserWindows + otherPhiWindows {
            if identifiers.insert(ObjectIdentifier(window)).inserted {
                result.append(window)
            }
        }
        return result
    }

    private func applyGuestTransitionInteractionBlockIfNeeded(to window: NSWindow) {
        guard isGuestTransitionInteractionBlocked else { return }
        let identifier = ObjectIdentifier(window)
        if guestTransitionOriginalIgnoresMouseEvents[identifier] == nil {
            guestTransitionOriginalIgnoresMouseEvents[identifier] = window.ignoresMouseEvents
        }
        if window.isKeyWindow {
            window.makeFirstResponder(nil)
        }
        window.ignoresMouseEvents = true
    }
    
    @objc private func windowWillClose(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = window.windowController as? MainBrowserWindowController else {
            return
        }
        WindowThemeMessageRouter.shared.stopObservingWindow(windowId: windowController.windowId)
        OverlayToastCenter.shared.clearWindow(windowId: windowController.windowId)
        // Normal, Incognito Space, and agent-Space windows live in slots
        // (mirrors the registerWindow gate in MainBrowserWindowController.init).
        // Skipping the Incognito Space's window here left its dead controller
        // registered: a window-driven cascade that included the Incognito Space
        // never drained its last entry, so the cascade-veto recovery "recovered"
        // onto the already-closed NSWindow and surfaced a blank shell. Agent
        // Space windows register too, so they must unregister here as well.
        if windowController.browserType == .normal || windowController.browserType == .incognitoSpace || windowController.browserType == .agentSpace {
            // Slot.unregisterWindow handles the per-slot "surface another
            // visible controller if this was the visible one" logic and
            // asks SpaceManager to drop the slot when it becomes empty. Agent
            // Space windows register (see MainBrowserWindowController.init), so
            // they must unregister here too or their slot/window leaks when the
            // Space is closed.
            windowController.slot?.unregisterWindow(windowController, for: windowController.spaceId)
        }
        // Shadow windows live outside slots entirely (see
        // AgentSpaceManager+Shadow.swift). Chromium can still tear one down on
        // its own — closing its last tab does, since shadow browsers skip
        // placeholder mode — so drop the registry entry or a re-bind would
        // hand its driver a dead windowId.
        if windowController.browserType == .shadow {
            MainActor.assumeIsolated {
                AgentSpaceManager.shared.shadowWindowDidClose(
                    windowId: windowController.windowId)
            }
        }
        windowControllers.remove(windowController)
        if activeWindowController === windowController {
            activeWindowController = windowControllers.first(where: {
                $0.window?.isVisible == true
            }) ?? windowControllers.first
        }
        // Chromium keeps every window close pending until it is told the gesture
        // is over; a cascade in flight makes this a no-op (see
        // `SpaceManager.reportWindowGroupCloseSettled`).
        SpaceManager.shared.reportWindowGroupCloseSettled()
    }
    
    @objc private func windowDidBecomeKey(_ noti: NSNotification) {
        guard let window = noti.object as? NSWindow,
              let windowController = window.windowController as? MainBrowserWindowController else {
            return
        }
        activeWindowController = windowController
        AppLogDebug("window did become key window: \(windowController.windowId)")
    }
    
    func getBrowserState(for browserId: Int) -> BrowserState? {
        return windowControllers.first(where: { $0.windowId == browserId })?.browserState
    }

    func controller(for windowId: Int) -> MainBrowserWindowController? {
        windowControllers.first(where: { $0.windowId == windowId })
    }
    
    func findControllerWith(window: NSWindow) -> MainBrowserWindowController? {
        return windowControllers.first {  $0.window === window }
    }
    
    func getActiveWindowState() -> BrowserState? { activeWindowController?.browserState }
    
    /// Returns every tracked browser window controller.
    func getAllWindows() -> [MainBrowserWindowController] {
        return Array(windowControllers)
    }

    /// True only after a user-facing regular browser window has completed its
    /// Chromium Show() call. Kiosk cold opens wait for this so their later
    /// activating show wins the foreground order.
    var hasVisibleRegularBrowserWindow: Bool {
        windowControllers.contains { controller in
            switch controller.browserType {
            case .normal:
                return controller.window?.isVisible == true
            default:
                return false
            }
        }
    }
    
    /// Get the first available window ID, checking both active windows and dangling windows
    /// This is useful before Guest entry or login has completed.
    /// - Returns: The first available window ID, or nil if no windows exist
    func getFirstAvailableWindowId() -> Int? {
        // First try to get from active window controllers
        if let windowId = windowControllers.first?.windowId {
            return windowId
        }
        // Fall back to windows waiting for browser access.
        return danglingWindows.first?.windowId
    }
    
    /// Closes every browser window, for example during logout flows.
    @MainActor
    func closeAllWindows() {
        AppLogInfo("🪟 [WindowManager] closeAllWindows called")
        AppLogInfo("🪟 [WindowManager] Current window count: \(windowControllers.count)")
        
        // Copy first so window teardown cannot mutate the set during iteration.
        let controllers = Array(windowControllers)
        
        // Use `performClose` so Chromium gets the same lifecycle as a user-initiated close.
        for (index, controller) in controllers.enumerated() {
            AppLogInfo("🪟 [WindowManager] Closing window \(index + 1)/\(controllers.count) (windowId: \(controller.windowId))")
            if let window = controller.window {
                window.performClose(nil)
                AppLogInfo("🪟 [WindowManager] Window \(controller.windowId) performClose called")
            } else {
                AppLogInfo("🪟 [WindowManager] Window \(controller.windowId) has no window object")
            }
        }
        
        // Clear the active-window reference once close requests are issued.
        activeWindowController = nil
        AppLogInfo("🪟 [WindowManager] Active window controller cleared")
        AppLogInfo("🪟 [WindowManager] closeAllWindows completed")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    /// Posted when the focused browser window changes (or is cleared). Menu
    /// state that depends on the active window — e.g. the menu-bar Spaces
    /// menu, which is hidden for incognito windows — refreshes on this.
    static let activeBrowserWindowDidChange = Notification.Name("activeBrowserWindowDidChange")
}
