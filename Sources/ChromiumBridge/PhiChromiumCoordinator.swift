// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Foundation
import SwiftUI
@objc class PhiChromiumCoordinator: NSObject {
    @objc static var shared = PhiChromiumCoordinator()

    /// Live ask-Space overlays keyed by the source windowId, so a second
    /// match for the same window replaces (rather than stacks) the prompt and
    /// dismissal can tear the right one down.
    private var activeChoosers: [Int64: NSWindow] = [:]
    /// `willClose` observers for the source windows hosting an active chooser,
    /// keyed the same way. Drained in lockstep with `activeChoosers` so a
    /// source window closing mid-prompt can't leak its overlay NSWindow (the
    /// overlay is `isReleasedWhenClosed = false` and AppKit only detaches it
    /// from the parent, it doesn't drop our dictionary reference).
    private var chooserCloseObservers: [Int64: NSObjectProtocol] = [:]
}

extension PhiChromiumCoordinator: PhiChromiumBridgeDelegate {
    func shouldEnablePhiExtensions() -> Bool { PhiPreferences.AISettings.phiAIEnabled.loadValue() }
    
    func handleExtensionMessage(_ type: String, payload: String, requestId: String, senderId: String) -> String? {
        return ExtensionMessageRouter.shared.handle(type: type, payload: payload, requestId: requestId)
    }

    func toggleChatSidebar(_ show: NSNumber?) {
        guard let state = MainBrowserWindowControllersManager.shared.activeWindowController?.browserState else {
            return
        }
        if let show {
            state.toggleAIChat(!show.boolValue)
        } else {
            state.toggleAIChat()
        }
    }

    func showFeedbackDialog() {
        MainBrowserWindowControllersManager.shared.activeWindowController?.showFeedbackWindow()
    }

    func downloadEventOccurred(_ eventType: DownloadEventType, guid: String, downloadItem: (any DownloadItemWrapper)?) {
        let eventName: String
        switch eventType {
        case .created: eventName = "CREATED"
        case .updated: eventName = "UPDATED"
        case .completed: eventName = "COMPLETED"
        case .cancelled: eventName = "CANCELLED"
        case .interrupted: eventName = "INTERRUPTED"
        case .paused: eventName = "PAUSED"
        case .resumed: eventName = "RESUMED"
        case .removed: eventName = "REMOVED"
        case .destroyed: eventName = "DESTROYED"
        case .opened: eventName = "OPENED"
        @unknown default: eventName = "UNKNOWN"
        }
        
        if let item = downloadItem {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), File: \(item.fileNameToReportUser), Progress: \(item.percentComplete)%, State: \(item.state), Speed: \(item.currentSpeed) B/s")
        } else {
            AppLogDebug("📥 [Download] Event: \(eventName), GUID: \(guid), Item: nil")
        }
        
        // Downloads are profile-scoped, so every open window needs the update.
        for controller in MainBrowserWindowControllersManager.shared.getAllWindows() {
            controller.browserState.downloadsManager.handleDownloadEvent(
                eventType: eventType,
                guid: guid,
                wrapper: downloadItem
            )
        }
    }
    
    func keyEquivalentOverride(forCommand commandId: Int32) -> [String : Any]? {
        let id = Int(commandId)

        // Suppress Chromium's Ctrl+Tab binding for IDC_SELECT_NEXT/PREVIOUS_TAB
        // because PHI_TAB_SWITCHER_FORWARD/BACKWARD owns those keys now.
        if id == CommandWrapper.IDC_SELECT_NEXT_TAB.rawValue ||
           id == CommandWrapper.IDC_SELECT_PREVIOUS_TAB.rawValue {
            return ["keyEquivalent": "", "modifierFlags": 0]
        }

        guard let state = Shortcuts.overrideState(for: id) else {
            return nil
        }
        
        if let key = state {
            return [
                "keyEquivalent": key.characters,
                "modifierFlags": key.modifiersRaw
            ]
        } else {
            return [
                "keyEquivalent": "",
                "modifierFlags": 0
            ]
        }
    }
    
    func getNativeSettings() -> String {
        return PhiPreferences.AISettings.buildConfig()
    }
    
    func handleDeeplink(withUrlString urlString: String, windowId: Int64) -> Bool {
        return DeeplinkHandler.handle(urlString)
    }

    /// A navigation matched a Space URL rule whose action is "ask every time"
    /// and Chromium cancelled it. Dims the source window and presents the
    /// Space chooser (current Space first); opens the URL in the chosen Space,
    /// or keeps it in the source window if the user declines. Owns the prompt
    /// + routing so Chromium stays out of the UI and Space-window lifecycle.
    func askSpace(forURL urlString: String, defaultSpaceId: String, sourceWindowId: Int64) {
        Task { @MainActor in
            let manager = SpaceManager.shared
            let spaces = manager.spaces
            guard !spaces.isEmpty,
                  let controller = MainBrowserWindowControllersManager.shared
                      .controller(for: Int(sourceWindowId)),
                  let sourceWindow = controller.window else {
                // No Spaces to choose from, or the source window is gone — fall
                // back to the rule's default Space rather than dropping the URL.
                manager.routeAskedURL(urlString,
                                      toSpaceId: spaces.isEmpty ? nil : defaultSpaceId,
                                      sourceWindowId: sourceWindowId)
                return
            }

            // List the current Space first, then the rest in their order.
            let currentSpaceId = controller.spaceId
            let ordered = spaces.filter { $0.spaceId == currentSpaceId }
                + spaces.filter { $0.spaceId != currentSpaceId }

            // Resolve each Space's theme color (its pinned theme, or the
            // current theme when none) for the source window's appearance, so a
            // row's tint matches what that Space actually looks like.
            let appearance = sourceWindow.effectiveAppearance.phiAppearance
            let items: [SpaceChooserItem] = ordered.map { space in
                let theme: Theme
                if let pinnedId = manager.themeId(forSpaceId: space.spaceId),
                   let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
                    theme = pinned
                } else {
                    theme = ThemeManager.shared.currentTheme
                }
                let themeNSColor = theme.color(for: .themeColor, appearance: appearance)
                // Contrast is computed on the opaque color, then the row is
                // tinted with the theme's overlay opacity (the Opacity setting)
                // so the item background is translucent like the box.
                let legible: NSColor = themeNSColor.isLight() ? .black : .white
                let opacity = theme.windowOverlayOpacity(for: appearance)
                return SpaceChooserItem(
                    id: space.spaceId,
                    name: space.name,
                    iconName: space.iconName,
                    isCurrent: space.spaceId == currentSpaceId,
                    themeColor: Color(nsColor: themeNSColor.withAlphaComponent(opacity)),
                    textColor: Color(nsColor: legible))
            }

            // The box's translucency follows the current Space's theme overlay
            // opacity (the Opacity setting in General settings), so it matches
            // the window it sits over.
            let currentTheme: Theme
            if let pinnedId = manager.themeId(forSpaceId: currentSpaceId),
               let pinned = ThemeManager.shared.registeredThemes[pinnedId] {
                currentTheme = pinned
            } else {
                currentTheme = ThemeManager.shared.currentTheme
            }
            let boxBackground = Color(
                nsColor: currentTheme.color(for: .windowOverlayBackground, appearance: appearance))

            // Replace any prompt already up for this window.
            self.dismissChooser(windowId: sourceWindowId)

            let chooser = SpaceChooserView(items: items, boxBackground: boxBackground) { [weak self] chosen in
                self?.dismissChooser(windowId: sourceWindowId)
                SpaceManager.shared.routeAskedURL(urlString,
                                                  toSpaceId: chosen,
                                                  sourceWindowId: sourceWindowId)
            }

            // Borderless child window over the source window: a child window
            // sits above the parent (and its accelerated web-content surface)
            // and moves with it, so the dim reliably covers the whole window.
            let overlay = SpaceChooserOverlayWindow(
                contentRect: sourceWindow.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.hasShadow = false
            overlay.isReleasedWhenClosed = false
            overlay.contentView = NSHostingView(rootView: chooser)
            overlay.setFrame(sourceWindow.frame, display: false)

            sourceWindow.addChildWindow(overlay, ordered: .above)
            overlay.makeKeyAndOrderFront(nil)
            self.activeChoosers[sourceWindowId] = overlay
            // Tear the prompt down if the source window closes underneath it,
            // so a stranded entry can't accumulate for the session. The token
            // is removed in `dismissChooser`.
            self.chooserCloseObservers[sourceWindowId] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: sourceWindow,
                queue: .main) { [weak self] _ in
                    self?.dismissChooser(windowId: sourceWindowId)
                }
        }
    }

    /// The user picked a Space from the web-content right-click "Open link as"
    /// submenu. Open `urlString` in that Space, reusing the ask-Space routing
    /// path which activates (cold-spawning if needed) the target Space's window
    /// and opens the URL there, bypassing Space URL routing for the re-open.
    func openLink(inSpace spaceId: String, url urlString: String, sourceWindowId: Int64) {
        Task { @MainActor in
            SpaceManager.shared.routeAskedURL(urlString,
                                              toSpaceId: spaceId,
                                              sourceWindowId: sourceWindowId)
        }
    }

    /// Tears down the ask-Space overlay for `windowId`, if any, and returns
    /// key focus to the parent window. Always called on the main thread (the
    /// presenting Task and the SwiftUI button actions both run there).
    private func dismissChooser(windowId: Int64) {
        if let token = chooserCloseObservers.removeValue(forKey: windowId) {
            NotificationCenter.default.removeObserver(token)
        }
        guard let overlay = activeChoosers.removeValue(forKey: windowId) else { return }
        let parent = overlay.parent
        parent?.removeChildWindow(overlay)
        overlay.orderOut(nil)
        parent?.makeKey()
    }
    
    func importStarted(_ browserType: BrowserType) {
        AppLogDebug("importStarted type: \(browserType)")
    }
    
    func importItemProgress(_ browserType: BrowserType, started: Bool) {
        AppLogDebug("importItemProgress type: \(browserType), started: \(started)")
    }
    
    func importCompleted(_ browserType: BrowserType, success: Bool) {
        AppLogDebug("importCompleted type: \(browserType), success: \(success)")
        
        NotificationCenter.default.post(
            name: .browserImportCompleted,
            object: nil,
            userInfo: [
                "browserType": browserType.rawValue,
                "success": success
            ]
        )
    }
    
    func isUserLoggedIn() -> Bool {
        let isLoggedIn = AuthManager.shared.checkLoginStatusOnChromiumLaunch()
        AppLogDebug("🌐 [Chromium] isUserLoggedIn check: \(isLoggedIn)")
        return isLoggedIn
    }
    
    func showLoginUI() {
        AppLogInfo("🌐 [Chromium] showLoginUI called by Chromium")
        Task { @MainActor in
            LoginController.shared.showLoginWindow()
        }
    }
    
    func getAuth0AccessTokenSyncly() -> String {
        let token = AuthManager.shared.getAccessTokenSyncly() ?? ""
        let hasToken = !token.isEmpty
        AppLogDebug("🌐 [Chromium] getAuth0AccessTokenSyncly called - hasToken: \(hasToken)")
        return token
    }
    
    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64) {
        // Legacy entry point kept for framework/client version skew: a Phi
        // Framework built before `restoredFromWindowId` was added calls this
        // selector. Zero means "not a session-restore re-creation", so the
        // restore-snapshot claim below never fires on this path.
        mainBrowserWindowCreated(window,
                                 type: browserType,
                                 profileId: profileId,
                                 windowId: windowId,
                                 restoredFromWindowId: 0)
    }

    func mainBrowserWindowCreated(_ window: NSWindow, type browserType: ChromiumBrowserType, profileId: String, windowId: Int64, restoredFromWindowId: Int64) {
        AppLogInfo("🌐 [Chromium] mainBrowserWindowCreated called - windowId: \(windowId), restoredFrom: \(restoredFromWindowId), type: \(browserType.rawValue)")


        guard browserType == .normal || browserType == .incognito || browserType == .shadow else {
            AppLogInfo("🌐 [Chromium] Ignoring window type: \(browserType.rawValue) (not normal or incognito)")
            return
        }

        // Check login status BEFORE creating window controller
        let userLoggedIn = isUserLoggedIn()

        // Chromium has no concept of Spaces or slots. Resolve which slot
        // (i.e. which user-perceived browser window) this Chromium window
        // belongs to, and what Space it should be tagged with:
        //   1. If some slot has a pending spawn intent for this windowId,
        //      that slot owns the window and the intent carries the spaceId
        //      — covers the "user clicked a Space pip, Chromium spawned a
        //      window for us" path, and stays correct even if the user
        //      clicked another Space in the gap before this async callback.
        //   2. Otherwise this is a Chromium-initiated window: Cmd+N from
        //      the macOS menu bar, session restore, target=_blank with
        //      new-window disposition, etc. Always create a NEW slot so
        //      the new window is its own independent "window group" — if
        //      we attached to the existing keySlot, the new controller
        //      would silently overwrite `keySlot.windowsBySpaceId[spaceId]`
        //      and orphan the original window, leaving its sidebar
        //      routing pip clicks to the wrong window. The new slot
        //      inherits the keySlot's current Space for "Cmd+N opens in
        //      the same context" continuity.
        //
        // Whatever path resolves it, the Space must be bound to the
        // window's actual Chromium profile: pinned tabs and bookmarks are
        // loaded from the controller's profileId, so tagging a window with
        // another profile's Space surfaces that profile's pinned tabs
        // inside the Space. `spaceId(boundTo:preferring:)` re-resolves any
        // inconsistent pair — the spawn path requested the Space's own
        // profile so it's a pass-through there, but the fallback and
        // restore paths pair Chromium's profile with a Swift-chosen Space
        // and the two can disagree.
        let resolvedSlot: SpaceWindowSlot?
        let spaceId: String
        if browserType == .normal {
            if let claim = SpaceManager.shared.claimPendingSpawn(forWindowId: Int(windowId)) {
                resolvedSlot = claim.slot
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: claim.spaceId)
            } else if let restored = SpaceManager.shared.claimRestoredWindow(
                forRestoredFromWindowId: Int(restoredFromWindowId)) {
                // Session-restore path: Chromium replays each saved window
                // as a separate `mainBrowserWindowCreated` callback with no
                // pending spawn, reporting the PREVIOUS session's windowId
                // as `restoredFromWindowId` (the per-run `windowId` never
                // matches the persisted snapshot). Without this lookup every
                // restored window would inherit `keySlot.activeSpaceId` and
                // tabs from non-active Spaces would migrate into the active
                // one.
                resolvedSlot = restored.slot
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: restored.spaceId)
            } else {
                let initial = SpaceManager.shared.keySlot?.activeSpaceId
                    ?? SpaceManager.shared.persistedActiveSpaceId
                    ?? LocalStore.defaultSpaceId
                // Correct BEFORE creating the slot so it starts on the
                // resolved Space and the window surfaces as the slot's
                // active window below.
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: initial)
                resolvedSlot = SpaceManager.shared.createSlot(initialSpaceId: spaceId)
            }
        } else {
            // Incognito / shadow windows are orthogonal to Spaces.
            resolvedSlot = nil
            spaceId = SpaceManager.shared.persistedActiveSpaceId ?? LocalStore.defaultSpaceId
        }

        if userLoggedIn, MainBrowserWindowControllersManager.shared.findControllerWith(window: window) == nil {
            let mainWindowController = MainBrowserWindowController(
                window: window,
                windowId: Int(windowId),
                browserType: browserType,
                profileId: profileId,
                spaceId: spaceId,
                slot: resolvedSlot
            )
            // Do NOT force key/front for the active window here. Chromium's
            // BrowserWindow Show() / ShowInactive() runs post-ctor on this same
            // NSWindow and drives visibility + activation with the correct
            // intent; forcing makeKeyAndOrderFront here made
            // chrome.windows.create({focused:false}) come to the foreground (the
            // focused param was effectively ignored).
            if browserType != .shadow {
                // On cold-launch session restore a slot can own multiple
                // Chromium windows (one per Space ever surfaced). Only the
                // window matching `slot.activeSpaceId` belongs on screen;
                // siblings stay hidden until the user pip-switches to them,
                // matching the steady-state "one slot, one visible window"
                // invariant. The active window is left to Chromium's Show() to
                // surface (see note above); only siblings are explicitly hidden.
                let isActiveForSlot: Bool = {
                    guard let resolvedSlot else { return true }
                    return resolvedSlot.activeSpaceId == spaceId
                }()
                if !isActiveForSlot {
                    mainWindowController.window?.orderOut(nil)
                    AppLogInfo("🌐 [Chromium] Restored sibling Space window kept hidden — spaceId=\(spaceId), activeSpaceId=\(resolvedSlot?.activeSpaceId ?? "nil")")
                }
            } else {
                AppLogInfo("🌐 Shadow window controller initialized but hidden.")
            }
            AppLogInfo("🌐 [Chromium] ✅ Window controller created and displayed (user logged in)")
        } else {
            AppLogInfo("🌐 [Chromium] User not logged in, adding window as dangling window")
            MainBrowserWindowControllersManager.shared.addDanglingWindow(
                window,
                windowId: Int(windowId),
                browserType: browserType,
                profileId: profileId,
                spaceId: spaceId,
                slot: resolvedSlot
            )
            
            DispatchQueue.main.async {
                LoginController.shared.showLoginWindow()
                if let loginWindow = LoginController.shared.loginWindowController?.window {
                    loginWindow.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            AppLogInfo("🌐 [Chromium] ✅ Window stored as dangling, login window will be shown")
        }
    }
    
    var extensionChangedCallback: (([[AnyHashable : Any]], Int64) -> Void)? {
        return { extensions ,windowId in
            EventBus.shared.send(ExtensionEvent(browserId: windowId.intValue, action: .extensionChanged(info: extensions)))
        }
    }

    // Explicit @objc so the optional-protocol selectors are guaranteed visible
    // to the ObjC bridge's respondsToSelector: dispatch (matches the codebase's
    // tabRelationshipSnapshotChanged precedent).
    @objc func badgeInfoChanged(_ info: [AnyHashable : Any]) {
        let windowId = (info["windowId"] as? NSNumber)?.intValue ?? 0
        EventBus.shared.send(ExtensionEvent(browserId: windowId, action: .badgeChanged(info: info)))
    }

    @objc func actionIconChanged(_ info: [AnyHashable : Any]) {
        let windowId = (info["windowId"] as? NSNumber)?.intValue ?? 0
        EventBus.shared.send(ExtensionEvent(browserId: windowId, action: .iconChanged(info: info)))
    }
    
    func newTabCreated(withInfo tabInfo: [AnyHashable : Any], windowId: Int64) {
        AppLogDebug("[Tab] newTabCreated: \(tabInfo) \n, windowId: \(windowId)")
        
        let title = tabInfo["title"] as? String
        let url = tabInfo["url"] as? String
        let index = tabInfo["index"] as? Int ?? -1
        let id = tabInfo["id"] as? Int ?? -1
        let active = false // fixeme
        let contentView = tabInfo["webView"] as? (WebContentWrapper & NSObject)
        let customGuid = tabInfo["customGuid"] as? String
        // Empty string means "not in any group" — the chromium bridge always
        // emits the key, so absence (older builds) is also treated as none.
        let groupIdHex = (tabInfo["groupIdHex"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let tab = Tab(guid: id,
                      url: url,
                      isActive: active,
                      index: index,
                      title: title,
                      webContentView: contentView,
                      customGuid: customGuid,
                      windowId: Int(windowId))
        // Apply the group affiliation eagerly so the sidebar's first render
        // after `tabs.append(tab)` already places this tab inside its group —
        // no transient "outside group" frame for tabs created directly into a
        // group (createTabInGroup, future regroup-on-create flows).
        if let groupIdHex {
            tab.groupToken = groupIdHex
        }
        let creationPayload = (tabInfo["creationContext"] as? [AnyHashable: Any]) ?? tabInfo
        let creationContext = NativeTabCreationContext(dictionary: creationPayload)
        AppLogDebug(
            "[NativeTab] mac newTabCreated " +
            "tabId=\(id) windowId=\(windowId) index=\(index) " +
            "creationPayload=\(creationPayload)"
        )
        
        if MainBrowserWindowControllersManager.shared.hasDanglingWindow(for: windowId.intValue) {
            MainBrowserWindowControllersManager.shared.addPendingTabToDanglingWindow(tab, windowId: windowId.intValue)
            AppLogInfo("🪟 [Chromium] Tab added to dangling window pending tabs - windowId: \(windowId), tabGuid: \(id)")
        } else {
            EventBus.shared
                .send(TabEvent(browserId: windowId.intValue,
                               action: .newTabWithContext(tab, context: creationContext)))
        }
    }

    @objc(tabRelationshipSnapshotChanged:windowId:version:)
    func tabRelationshipSnapshotChanged(_ snapshotInfo: [AnyHashable : Any], windowId: Int64, version: Int64) {
        AppLogDebug("[Tab] tabRelationshipSnapshotChanged: \(snapshotInfo), windowId: \(windowId)")
        let openerByTabId = (snapshotInfo["openerByTabId"] as? [AnyHashable: Any]) ?? snapshotInfo
        let resetOnActiveChangeTabIds = (snapshotInfo["resetOnActiveChangeTabIds"] as? [Any]) ?? []
        AppLogDebug(
            "[NativeTab] mac relationshipSnapshot " +
            "windowId=\(windowId) version=\(version) " +
            "openerByTabId=\(openerByTabId) " +
            "resetOnActiveChangeTabIds=\(resetOnActiveChangeTabIds)"
        )
        guard let snapshot = NativeTabRelationshipSnapshot(
            dictionary: [
                "windowId": windowId,
                "version": version,
                "openerByTabId": openerByTabId,
                "resetOnActiveChangeTabIds": resetOnActiveChangeTabIds,
            ],
            fallbackWindowId: windowId.intValue
        ) else {
            AppLogWarn("[Tab] Failed to parse relationship snapshot for windowId: \(windowId)")
            return
        }
        EventBus.shared.send(
            TabEvent(
                browserId: windowId.intValue,
                action: .updateTabRelationships(snapshot)
            )
        )
    }
    
    func tabWillBeRemove(_ tabId: Int64, windowId: Int64) {
        AppLogDebug("tabWillBeRemove: \(tabId)")
        // Snapshot the closing active tab SYNCHRONOUSLY, before the async EventBus
        // close dispatch. This bridge callback runs on the UI/main thread inside
        // Chromium's synchronous close turn while the WebContents is still alive;
        // the EventBus close (Task { @MainActor }) runs only AFTER Chromium has
        // destroyed it, when CGWindowList would capture blank. MainActor.assumeIsolated
        // mirrors windowDidEnterPlaceholderMode's synchronous-detach pattern.
        // The contract above holds today (BrowserThread::UI = the AppKit main thread =
        // MainActor), but it isn't type-enforced. Assert it; if Chromium ever delivers
        // this off-main, skip the best-effort mask rather than trapping — the EventBus
        // close below must still fire.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                // nil window (already torn down) → skip silently; the mask is best-effort.
                MainBrowserWindowControllersManager.shared
                    .controller(for: windowId.intValue)?
                    .mainSplitViewController.webContentContainerViewController
                    .maskClosingTab(tabId: tabId.intValue)
            }
        } else {
            assertionFailure("tabWillBeRemove off the main thread; skipping best-effort close mask")
        }
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .closeTab(tabId.intValue)))
    }
    
    func getWebContentSuperView() -> NSView? {
        return nil
    }
    
    
    func tabTitleUpdated(_ tabId: Int64, title: String, windowId: Int64) {
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .updateTabTitle(tabId: tabId.intValue, newTitle: title)))
    }
    
    @objc func initApplication() {
        enum _Store {
            static var app: AppController?
        }
        let controller = AppController()
        _Store.app = controller
        NSApp = PhiApplication.shared
        NSApp.delegate = controller
        controller.startObservingMainMenu()
    }
    
    func runQuitConfirmAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Phi?", comment: "Quit Phi?")
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel"))
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
    
    func activeTabChanged(_ tabId: Int64, index: Int32, windowId: Int64) {
        AppLogDebug("[Tab]: activeTabChanged: \(tabId), atIndex:\(index), window:\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                         action: .focusTabWithTabId(tabId.intValue)))
    }
    
    func tabIndicesUpdated(_ tabIndices: [NSNumber : NSNumber], windowId: Int64) {
        AppLogDebug("[Tab] tabIndicesUpdated: \(tabIndices), window:\(windowId)")
        let map: [Int: Int] = tabIndices.reduce(into: [:]) { partialResult, element in
            partialResult[element.key.intValue] = element.value.intValue
        }
        let targetWindowId: Int?
        if windowId != 0 {
            targetWindowId = windowId.intValue
        } else {
            targetWindowId = MainBrowserWindowControllersManager.shared.activeWindowController?.windowId
        }
        guard let targetWindowId else {
            return
        }
        EventBus.shared
            .send(TabEvent(browserId: targetWindowId,
                         action: .updateTabIndex(map)))
    }

    // =========================================================================
    // DevTools embedding
    // =========================================================================

    /// Called by Chromium when DevTools has attached (docked) to a tab.
    func devToolsDidAttach(toTab tabId: Int64, windowId: Int64, devToolsView: NSView) {
        guard let windowController = MainBrowserWindowControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleDevToolsDidAttach(tabId: Int(tabId), devToolsView: devToolsView)
    }

    /// Called by Chromium when DevTools has detached from a tab (closed or undocked).
    func devToolsDidDetach(fromTab tabId: Int64, windowId: Int64) {
        guard let windowController = MainBrowserWindowControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleDevToolsDidDetach(tabId: Int(tabId))
    }

    /// Called by Chromium when the inspected page bounds change.
    func updateInspectedPageBounds(_ bounds: CGRect, forTabId tabId: Int64, windowId: Int64, hideInspectedContents hide: Bool) {
        guard let windowController = MainBrowserWindowControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else { return }
        windowController.handleUpdateInspectedPageBounds(tabId: Int(tabId), bounds: bounds, hide: hide)
    }

    // =========================================================================
    // Flicker fix: Tab visibility synchronization
    // =========================================================================

    /// Called by Chromium after hiding the previous WebContents.
    /// Mac should clean up the previous tab's NSView from the view hierarchy.
    func previousTabReady(forCleanup tabId: Int64, windowId: Int64) {
        AppLogDebug("[Tab] previousTabReadyForCleanup: tabId=\(tabId), windowId=\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .previousTabReadyForCleanup(tabId.intValue)))
    }

    /// Called by Chromium when a new tab has completed its first visually non-empty paint.
    /// Mac should bring the new tab's view to the front.
    func tabReady(toDisplay tabId: Int64, windowId: Int64) {
        // AppLogDebug("[FlickerFix][Coordinator] tabReadyToDisplay: tabId=\(tabId), windowId=\(windowId)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .tabReadyToDisplay(tabId.intValue)))
    }

    // =========================================================================
    // Content fullscreen (HTML5 requestFullscreen)
    // =========================================================================

    /// Called when a tab enters or exits HTML5 content fullscreen.
    /// Routed through EventBus to the owning BrowserState, which drives the
    /// re-parent of that tab's hostView to cover the window.
    func tabContentFullscreenChanged(_ tabId: Int64,
                                     windowId: Int64,
                                     isFullscreen: Bool) {
        AppLogDebug("[Fullscreen] tabContentFullscreenChanged: tabId=\(tabId), windowId=\(windowId), isFullscreen=\(isFullscreen)")
        EventBus.shared
            .send(TabEvent(browserId: windowId.intValue,
                           action: .tabContentFullscreenChanged(
                               tabId: tabId.intValue,
                               isFullscreen: isFullscreen)))
    }

    // =========================================================================
    // Placeholder mode (last-tab close → chrome://dino shell)
    //
    // Mirrors the Chromium-side bridge in
    // chrome/browser/phinomenon/phi_app_bridge/PhiChromiumBridgeHeader.h.
    // The synchronous detach contract (spec §9.1) requires the BrowserState
    // state flip + NSView detach to complete BEFORE returning to Chromium,
    // hence MainActor.assumeIsolated rather than Task { @MainActor in ... }.
    // =========================================================================

    func windowDidEnterPlaceholderMode(_ windowId: Int64,
                                       placeholderView wrapper: any WebContentWrapper) {
        AppLogInfo("🦖 [Coordinator] enterPlaceholderMode windowId=\(windowId)")
        guard let windowController = MainBrowserWindowControllersManager.shared
                .getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            AppLogWarn("🦖 [Coordinator] no controller for windowId=\(windowId)")
            return
        }
        guard let nsWrapper = wrapper as? (WebContentWrapper & NSObject) else {
            AppLogWarn("🦖 [Coordinator] wrapper cast failed")
            return
        }
        // Synchronous (NOT Task { @MainActor in ... }) so state flips before
        // returning to Chromium.
        MainActor.assumeIsolated {
            windowController.browserState.enterPlaceholderMode(wrapper: nsWrapper)
        }
    }

    func windowDidExitPlaceholderMode(_ windowId: Int64) {
        AppLogInfo("🦖 [Coordinator] exitPlaceholderMode windowId=\(windowId)")
        guard let windowController = MainBrowserWindowControllersManager.shared
                .getAllWindows()
                .first(where: { $0.windowId == Int(windowId) }) else {
            AppLogWarn("🦖 [Coordinator] no controller for windowId=\(windowId)")
            return
        }
        MainActor.assumeIsolated {
            windowController.browserState.exitPlaceholderMode()
        }
    }

    // =========================================================================
    // Tab groups (Chromium → Mac)
    //
    // Forwards all 5 bridge callbacks through EventBus, matching the
    // dispatch shape used by TabEvent / BookmarkEvent. The actual state
    // updates happen in `BrowserState.handleTabGroup*`.
    // =========================================================================

    private func decodeGroupColor(_ wire: String, context: String) -> GroupColor {
        if let color = GroupColor(rawValue: wire) {
            return color
        }
        AppLogWarn(
            "[TAB_GROUPS] unknown wire color \"\(wire)\" in \(context); falling back to .grey"
        )
        return .grey
    }

    /// Routes a tab-group action: if the destination window is dangling
    /// (created pre-login, no BrowserState yet), the action is buffered
    /// for replay after `processDanglingWindow`. Otherwise it goes straight
    /// onto the EventBus. Without buffering, group events dropped during
    /// the dangling window flatten grouped tabs permanently on cold start.
    private func dispatchGroupAction(_ action: TabGroupEvent.TabGroupAction,
                                      windowId: Int64) {
        let id = windowId.intValue
        let manager = MainBrowserWindowControllersManager.shared
        if manager.hasDanglingWindow(for: id) {
            manager.addPendingGroupActionToDanglingWindow(action, windowId: id)
            return
        }
        EventBus.shared.send(TabGroupEvent(browserId: id, action: action))
    }

    func tabGroupCreated(_ windowId: Int64,
                         tokenHex: String,
                         title: String,
                         color: String,
                         isCollapsed: Bool,
                         initialTabIds: [NSNumber]) {
        let decodedColor = decodeGroupColor(color, context: "tabGroupCreated token=\(tokenHex)")
        let tabIds = initialTabIds.map { $0.intValue }
        dispatchGroupAction(.groupCreated(token: tokenHex,
                                           title: title,
                                           color: decodedColor,
                                           isCollapsed: isCollapsed,
                                           initialTabIds: tabIds),
                            windowId: windowId)
    }

    func tabGroupVisualDataChanged(_ windowId: Int64,
                                    tokenHex: String,
                                    title: String,
                                    color: String,
                                    isCollapsed: Bool) {
        let decodedColor = decodeGroupColor(
            color,
            context: "tabGroupVisualDataChanged token=\(tokenHex)")
        dispatchGroupAction(.groupVisualDataChanged(token: tokenHex,
                                                     title: title,
                                                     color: decodedColor,
                                                     isCollapsed: isCollapsed),
                            windowId: windowId)
    }

    func tabGroupClosed(_ windowId: Int64, tokenHex: String) {
        dispatchGroupAction(.groupClosed(token: tokenHex), windowId: windowId)
    }

    func tabJoinedGroup(_ windowId: Int64, tabId: Int64, tokenHex: String) {
        dispatchGroupAction(.tabJoinedGroup(tabId: tabId.intValue, token: tokenHex),
                            windowId: windowId)
    }

    func tabLeftGroup(_ windowId: Int64, tabId: Int64, tokenHex: String) {
        dispatchGroupAction(.tabLeftGroup(tabId: tabId.intValue, token: tokenHex),
                            windowId: windowId)
    }

    func targetURLChanged(_ tabId: Int64, windowId: Int64, url: String) {
        guard let windowController = MainBrowserWindowControllersManager.shared
            .getAllWindows()
            .first(where: { $0.windowId == Int(windowId) }) else {
            return
        }

        DispatchQueue.main.async {
            let shouldDisplay = !url.isEmpty &&
                              !url.hasPrefix("about:") &&
                              !url.hasPrefix("chrome:")
            windowController.browserState.targetURL = shouldDisplay ? url : ""
        }
    }
}

extension PhiChromiumCoordinator {
    @MainActor
    func dispatchCommand(_ commandId: Int32, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(commandId, window: window)
    }
    
    @MainActor
    func commandDispatch(_ sender: Any, window: NSWindow) -> Bool {
        return CommandDispatcher.dispatchCommand(sender, window: window)
    }
    
    @MainActor
    func handleKeyEquivalent(_ event: NSEvent, window: NSWindow) -> Bool {
        return CommandDispatcher.handleKeyEquivalent(event, window: window)
    }
}

extension PhiChromiumCoordinator {
    func extensionsLoaded(_ extensions: [[AnyHashable : Any]]) {

    }
    
    func extensionTriggered(_ extensionId: String) {

    }
    
    func extensionPinned(_ extensionId: String) {

    }
    
    func extensionUnpinned(_ extensionId: String) {

    }
    
    func extensionMoved(_ extensionId: String, to newIndex: Int32) {

    }

    func extensionInstallResult(_ extensionId: String, status: String) {
    }

}

extension PhiChromiumCoordinator {
    func bookmarksLoaded(_ windowId: Int64) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarksLoaded))
    }
    
    func bookmarksChanged(_ newNodes: [any BookmarkWrapper], windowId: Int64) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarksChanged(newNodes)))
    }
    
    func bookmarkInfoChanged(withWindowId windowId: Int64, bookmarkId id: Int64, title: String?, url: String?, facicon favicon_url: String?) {
        EventBus.shared.send(BookmarkEvent(browserId: windowId.intValue,
                                           action: .bookmarkInfoChanged(id: id, title: title, url: url, faviconUrl: favicon_url)))
    }
}

extension PhiChromiumCoordinator {
    func omniboxResultChanged(_ matches: [[AnyHashable : Any]], originalInput: String, windowId: Int64) {
        guard let infos = matches as? [[String: Any]] else {
            return
        }
        EventBus.shared.send(OmniEvent(browserId: Int(windowId),
                                       action: .searchSuggestionResultChanged(suggestions: infos,
                                                                              originalInput: originalInput)))
    }
}

// MARK: - Split view notifications

extension PhiChromiumCoordinator {
    func splitCreated(_ splitId: String,
                      primaryTabId: Int64,
                      secondaryTabId: Int64,
                      layout: String,
                      ratio: Double,
                      windowId: Int64) {
        AppLogDebug("[Split] created: id=\(splitId) primary=\(primaryTabId) secondary=\(secondaryTabId) layout=\(layout) ratio=\(ratio) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .created(splitId: splitId,
                             primaryTabId: primaryTabId.intValue,
                             secondaryTabId: secondaryTabId.intValue,
                             layout: parseBridgeLayout(layout),
                             ratio: ratio)))
    }

    func splitVisualsChanged(_ splitId: String,
                             layout: String,
                             ratio: Double,
                             windowId: Int64) {
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .visualsChanged(splitId: splitId,
                                    layout: parseBridgeLayout(layout),
                                    ratio: ratio)))
    }

    private func parseBridgeLayout(_ raw: String) -> SplitLayout {
        if let layout = SplitLayout(bridgeString: raw) { return layout }
        AppLogError("[Split] unknown bridge layout string '\(raw)' — defaulting to vertical")
        return .vertical
    }

    func splitContentsChanged(_ splitId: String,
                              primaryTabId: Int64,
                              secondaryTabId: Int64,
                              windowId: Int64) {
        AppLogDebug("[Split] contentsChanged: id=\(splitId) primary=\(primaryTabId) secondary=\(secondaryTabId) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .contentsChanged(splitId: splitId,
                                     primaryTabId: primaryTabId.intValue,
                                     secondaryTabId: secondaryTabId.intValue)))
    }

    func splitRemoved(_ splitId: String, windowId: Int64) {
        AppLogDebug("[Split] removed: id=\(splitId) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .removed(splitId: splitId)))
    }

    func openLinkAsSplitPartner(withPartnerTabId partnerTabId: Int64,
                                url: String,
                                windowId: Int64) {
        AppLogDebug("[Split] openLinkAsSplitPartner: partner=\(partnerTabId) url=\(url) window=\(windowId)")
        EventBus.shared.send(SplitEvent(
            browserId: windowId.intValue,
            action: .openLinkAsSplitPartner(partnerTabId: partnerTabId.intValue,
                                            url: url)))
    }
}

extension Int64 {
    var intValue: Int { Int(self) }
}

extension Int {
    var int64Value: Int64 { Int64(self) }
}
