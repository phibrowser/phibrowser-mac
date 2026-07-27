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
    /// Crash payloads that arrived before their (cross-window-dragged) tab was
    /// created on the Mac side, keyed by Chromium tab guid. Drained by
    /// `BrowserState.handleNewTabFromChromium` when the tab appears.
    private var pendingCrashBuffer: [Int: CrashPageData] = [:]

    /// True while a backup import is creating Chromium profiles; read via the
    /// bridge by preinstalled apps to defer extension preinstall. Main-thread only.
    var isBackupImportInProgress = false
}

extension PhiChromiumCoordinator: PhiChromiumBridgeDelegate {
    func shouldEnablePhiExtensions() -> Bool { PhiPreferences.AISettings.phiAIEnabled.loadValue() }

    /// Source of truth for the browser-process DevTools gate that blocks
    /// remote-debugging clients from the user's own Spaces. Read live per gated
    /// command, so the Settings toggle applies without a relaunch.
    func agentUserSpaceOperationsEnabled() -> Bool {
        PhiPreferences.AgentSpaces.userSpaceOperationsEnabled
    }

    func isBackupImporting() -> Bool { isBackupImportInProgress }

    func shouldAutoInstallICloudPasswords() -> Bool {
        PhiPreferences.PasswordManagerSettings.autoInstallICloudPasswords.loadValue()
    }

    func isAutoPictureInPictureEnabled() -> Bool {
        PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode() != .off
    }

    func isAutoPipParkEnabled() -> Bool {
        PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode() == .parked
    }
    
    func handleExtensionMessage(_ type: String, payload: String, requestId: String, senderId: String) -> String? {
        return ExtensionMessageRouter.shared.handle(type: type, payload: payload, requestId: requestId, senderId: senderId)
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
    func askSpace(forURL urlString: String, defaultSpaceId: String, sourceWindowId: Int64, sourceIsNewTab: Bool) {
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
                                      sourceWindowId: sourceWindowId,
                                      sourceIsNewTab: sourceIsNewTab)
                return
            }

            // List the current Space first, then the rest in their order.
            // Live Incognito Spaces collapse into ONE generic "Incognito"
            // choice: its id is the rules' generic target, which
            // `routeAskedURL` resolves to the first live Incognito Space —
            // creating one when none exists — so the choice is always
            // offered. It leads when the navigation started in an Incognito
            // Space (that Space is then the resolution target) and trails
            // the user Spaces otherwise.
            let currentSpaceId = controller.spaceId
            let currentIsIncognito = SpaceManager.isIncognitoSpaceId(currentSpaceId)
            let userSpaces = spaces.filter { !SpaceManager.isIncognitoSpaceId($0.spaceId) }
            var ordered = userSpaces.filter { $0.spaceId == currentSpaceId }
                + userSpaces.filter { $0.spaceId != currentSpaceId }
            let incognitoTarget = manager.incognitoRuleTargetSpace()
            if currentIsIncognito {
                ordered.insert(incognitoTarget, at: 0)
            } else {
                ordered.append(incognitoTarget)
            }

            // Resolve each Space's theme (pinned theme + custom overlay
            // opacity) for the source window's appearance, so a row's tint
            // matches what that Space actually looks like.
            let appearance = sourceWindow.effectiveAppearance.phiAppearance
            let items: [SpaceChooserItem] = ordered.map { space in
                let theme = manager.resolvedTheme(forSpaceId: space.spaceId)
                let themeNSColor = theme.color(for: .themeColor, appearance: appearance)
                // Contrast is computed on the opaque color, then the row is
                // tinted with the theme's overlay opacity (the Opacity setting)
                // so the item background is translucent like the box.
                let legible: NSColor = themeNSColor.isLight() ? .black : .white
                let opacity = theme.windowOverlayOpacity(for: appearance)
                // The generic Incognito choice is "current" whenever the
                // navigation started in any Incognito Space — that Space is
                // what the choice resolves to.
                let isCurrent = space.spaceId == currentSpaceId
                    || (currentIsIncognito && space.spaceId == SpaceManager.incognitoRuleTargetId)
                return SpaceChooserItem(
                    id: space.spaceId,
                    name: space.name,
                    iconName: space.iconName,
                    isCurrent: isCurrent,
                    themeColor: Color(nsColor: themeNSColor.withAlphaComponent(opacity)),
                    textColor: Color(nsColor: legible))
            }

            // The box's translucency follows the current Space's resolved
            // overlay opacity, so it matches the window it sits over.
            let currentTheme = manager.resolvedTheme(forSpaceId: currentSpaceId)
            let boxBackground = Color(
                nsColor: currentTheme.color(for: .windowOverlayBackground, appearance: appearance))

            // Replace any prompt already up for this window.
            self.dismissChooser(windowId: sourceWindowId)

            let chooser = SpaceChooserView(items: items, boxBackground: boxBackground) { [weak self] chosen in
                self?.dismissChooser(windowId: sourceWindowId)
                SpaceManager.shared.routeAskedURL(urlString,
                                                  toSpaceId: chosen,
                                                  sourceWindowId: sourceWindowId,
                                                  sourceIsNewTab: sourceIsNewTab)
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
            // Right-click "Open link as <Space>" always originates from a real
            // page (you right-clicked a link), never a new tab — so no in-place
            // open / NTP reset.
            SpaceManager.shared.routeAskedURL(urlString,
                                              toSpaceId: spaceId,
                                              sourceWindowId: sourceWindowId,
                                              sourceIsNewTab: false)
        }
    }

    /// A silent Space URL rule auto-routed `urlString` to `spaceId`, but that
    /// Space had no open window, so Chromium cancelled the navigation and asked
    /// us to surface the Space. Reuse the ask-Space routing path, which
    /// activates (cold-spawning if needed) the target Space's window in the
    /// source window's slot and opens the URL there, bypassing Space URL
    /// routing for the re-open so the same rule doesn't re-match in a loop.
    func routeURL(inSpace spaceId: String, url urlString: String, sourceWindowId: Int64) {
        Task { @MainActor in
            // Silent auto-route to a Space with no open window. The stranded
            // source NTP (if any) is reset on the Chromium side via
            // `refreshNewTabInWindow`, so pass false here to avoid resetting it
            // twice; this path is always a Space switch, never an in-place open.
            SpaceManager.shared.routeAskedURL(urlString,
                                              toSpaceId: spaceId,
                                              sourceWindowId: sourceWindowId,
                                              sourceIsNewTab: false)
        }
    }

    /// A Space URL rule routed a new-tab navigation to a different Space (the
    /// URL opened elsewhere). Reset the source window's active new-tab page back
    /// to a clean state. Used by the auto-route-to-an-open-window path, which is
    /// handled entirely on the Chromium side and so signals the refresh here.
    func refreshNewTab(inWindow windowId: Int64) {
        Task { @MainActor in
            SpaceManager.shared.refreshActiveNewTab(inWindow: windowId)
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

    /// Returns the current Phi account identity from the same per-account
    /// profile cache used by the Mac account settings page. The ID-token
    /// identity covers the short window before the init prefetch completes.
    func getPhiAccountInfo() -> [String: Any]? {
        guard let account = AccountController.shared.account else { return nil }
        let profile: Profile? = account.userDefaults.codableValue(
            forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
        )

        var info: [String: Any] = [:]
        if let profile, profile.auth0_id == account.userID {
            if !profile.name.isEmpty { info["nickname"] = profile.name }
            if !profile.email.isEmpty { info["email"] = profile.email }
        } else if let user = account.userInfo {
            if let name = user.name, !name.isEmpty { info["nickname"] = name }
            if let email = user.email, !email.isEmpty { info["email"] = email }
        }
        if let avatarPNG = AccountController.shared.avatarPNG(for: account) {
            info["avatarPNG"] = avatarPNG
        }
        return info.isEmpty ? nil : info
    }
    
    func showLoginUI() {
        AppLogInfo("🌐 [Chromium] showLoginUI called by Chromium")
        Task { @MainActor in
            LoginController.shared.showLoginWindow()
        }
    }

    /// The settings page asked to delete the Phi account and its data. The
    /// hop off this call is required: presenting from inside it would run a
    /// sheet while a Chromium message handler is still on the stack.
    func startPhiAccountDeletion() {
        AppLogInfo("🌐 [Chromium] startPhiAccountDeletion called by Chromium")
        Task { @MainActor in
            AccountDeletionController.shared.start()
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


        guard browserType == .normal || browserType == .incognito
                || browserType == .incognitoSpace || browserType == .shadow
                || browserType == .agentSpace else {
            AppLogInfo("🌐 [Chromium] Ignoring window type: \(browserType.rawValue) (not normal/incognito/incognitoSpace/agentSpace)")
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
        // Tracks whether this window came back through Chromium session restore
        // — the only path that surfaces several windows into one slot, and so
        // the only one that needs the post-restore visibility reconcile below.
        var isRestoredWindow = false
        // Incognito Space windows take the same slot-resolution path as
        // normal ones: they are spawned by a slot with a pending spawn
        // intent, and `spaceId(boundTo:preferring:)` passes through because
        // the synthetic Incognito Space's profileId IS the wire id Chromium
        // reports for them. Standalone incognito stays orthogonal below.
        // Agent Space windows resolve the same way — registered into a slot via
        // the pending-spawn claim from `spawnHiddenWindow` so the user can later
        // switch to them; they differ only in that Chromium never Show()s them
        // (agent-mode browsers), so the window stays ordered out until surfaced.
        if browserType == .normal || browserType == .incognitoSpace || browserType == .agentSpace {
            if let claim = SpaceManager.shared.claimPendingSpawn(forWindowId: Int(windowId)) {
                resolvedSlot = claim.slot
                spaceId = SpaceManager.shared.spaceId(boundTo: profileId,
                                                      preferring: claim.spaceId)
            } else if let restored = SpaceManager.shared.claimRestoredWindow(
                forRestoredFromWindowId: Int(restoredFromWindowId),
                profileId: profileId) {
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
                isRestoredWindow = true
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
                // invariant. Cold-launch restored active windows are left to
                // Chromium's Show() to surface (see note above); slot-SPAWNED
                // windows are created `hidden: true` and revealed by the
                // slot's own spawn path once seeded (see `activate`'s spawn
                // branch); only siblings are explicitly hidden here.
                let isActiveForSlot: Bool = {
                    guard let resolvedSlot else { return true }
                    return resolvedSlot.activeSpaceId == spaceId
                }()
                if !isActiveForSlot {
                    if let resolvedSlot {
                        resolvedSlot.orderOutIfNotManagedBySlotTabGroup(mainWindowController)
                    } else {
                        mainWindowController.window?.orderOut(nil)
                    }
                    AppLogInfo("🌐 [Chromium] Restored sibling Space window kept hidden — spaceId=\(spaceId), activeSpaceId=\(resolvedSlot?.activeSpaceId ?? "nil")")
                }
                // The eager hide above runs INSIDE Chromium's window-created
                // callback — before Chromium's post-construction
                // ShowInactive()/Show() re-orders this NSWindow on screen (see
                // the note above). On session restore a slot owns several
                // windows and Chromium surfaces every one, so that later
                // re-order undoes the eager hide and the inactive Space windows
                // linger. Re-assert the slot's one-visible-window invariant on
                // the next runloop turn, after Chromium finishes showing them.
                if isRestoredWindow {
                    resolvedSlot?.scheduleRestoreVisibilityReconcile()
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

    /// Renderer crash page arrived for `tabId` in `windowId` (both pre-resolved
    /// by Chromium; the WebContents may be mid-teardown). Resolve the tab and
    /// install the crash state synchronously so show/hide stay ordered. Must be
    /// `@objc`: this is an optional protocol selector and Chromium gates the
    /// whole crash page on `respondsToSelector:` for it.
    @objc func showCrashPage(_ tabId: Int64, windowId: Int64, data: [AnyHashable : Any]) {
        // Runs on Chromium's UI/main thread today (= AppKit main = MainActor), but
        // that isn't type-enforced. Mirror tabWillBeRemove: assert and skip rather
        // than trap if it ever arrives off-main — a crash notification must never
        // take down the browser process.
        guard Thread.isMainThread else {
            assertionFailure("showCrashPage off the main thread; skipping crash page")
            return
        }
        MainActor.assumeIsolated {
            guard let windowController = MainBrowserWindowControllersManager.shared
                    .getAllWindows()
                    .first(where: { $0.windowId == Int(windowId) }),
                  let tab = windowController.browserState.resolveTab(Int(tabId)) else {
                // Cross-window drag can replay a crash before the destination
                // window's tab exists on the Mac side. Buffer it; the tab's
                // creation (BrowserState.handleNewTabFromChromium) drains it.
                pendingCrashBuffer[Int(tabId)] = CrashPageData(dictionary: data)
                return
            }
            tab.crashState = CrashPageData(dictionary: data)
        }
    }

    /// Remove and return a buffered crash payload for a tab that has now been
    /// created (cross-window drag). Returns nil if none was buffered.
    func drainPendingCrash(tabId: Int) -> CrashPageData? {
        pendingCrashBuffer.removeValue(forKey: tabId)
    }

    /// Renderer recovered (committed a non-crashed navigation). Clear the crash
    /// state for `tabId`. Optional selector → `@objc` required.
    @objc func hideCrashPage(_ tabId: Int64, windowId: Int64) {
        guard Thread.isMainThread else {
            assertionFailure("hideCrashPage off the main thread; skipping crash page teardown")
            return
        }
        MainActor.assumeIsolated {
            guard let windowController = MainBrowserWindowControllersManager.shared
                    .getAllWindows()
                    .first(where: { $0.windowId == Int(windowId) }),
                  let tab = windowController.browserState.resolveTab(Int(tabId)) else {
                // The crash may have been buffered before the tab existed (a
                // cross-window drag replays show before creation). Recovery can
                // arrive in that same pre-creation window — drop the stale
                // payload so the tab's later creation doesn't replay a crash the
                // renderer has already recovered from.
                pendingCrashBuffer.removeValue(forKey: Int(tabId))
                return
            }
            // Clear immediately by design: a renderer crash is rare, and a brief
            // blank while the page reloads usefully signals the reload is under
            // way (rather than looking stuck). No fixed delay / staleness token
            // is needed — bridge show/hide run synchronously and in order here.
            tab.crashState = nil
        }
    }
    
    /// Builds the (Tab, NativeTabCreationContext) pair from one
    /// newTabCreatedWithInfo-shaped bridge payload. Shared by the per-tab
    /// path and the restored-window snapshot path (T3A) so the two parses
    /// cannot drift.
    private func makeTab(fromBridgeInfo tabInfo: [AnyHashable: Any],
                         windowId: Int64) -> (tab: Tab, context: NativeTabCreationContext) {
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
        return (tab, creationContext)
    }

    func newTabCreated(withInfo tabInfo: [AnyHashable : Any], windowId: Int64) {
        AppLogDebug("[Tab] newTabCreated: \(tabInfo) \n, windowId: \(windowId)")

        let (tab, creationContext) = makeTab(fromBridgeInfo: tabInfo, windowId: windowId)
        let id = tab.guid
        AppLogDebug(
            "[NativeTab] mac newTabCreated " +
            "tabId=\(id) windowId=\(windowId) index=\(tab.index) " +
            "creationPayload=\((tabInfo["creationContext"] as? [AnyHashable: Any]) ?? tabInfo)"
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

    /// One restored saved window delivered as a single batch (T3A snapshot
    /// seam). Called SYNCHRONOUSLY inside Chromium's session-restore replay
    /// stack: parse, take ownership, and apply the whole payload here in the
    /// same stack (T3B) — data and the visible list no longer wait for the
    /// main queue to drain the replay backlog. Deliberately NOT routed
    /// through EventBus (T3A amendment decision 1). The applied transaction
    /// must never call back into Chromium synchronously; BrowserState's
    /// snapshot transaction owns that discipline.
    @objc(restoredWindowSnapshot:windowId:)
    func restoredWindowSnapshot(_ snapshot: [String: Any], windowId: Int64) {
        let tabInfos = (snapshot["tabs"] as? [[AnyHashable: Any]]) ?? []
        let items = tabInfos.map { makeTab(fromBridgeInfo: $0, windowId: windowId) }
        let activeTabId = snapshot["activeTabId"] as? Int
        let splitActions = parseSplitActions(fromBridgeEvents: snapshot["splitEvents"])

        guard !items.isEmpty else { return }

        if MainBrowserWindowControllersManager.shared.hasDanglingWindow(for: windowId.intValue) {
            // Pre-login dangling window: mirror the per-tab path's dangling
            // semantics (tabs buffered; split/active events were never
            // buffered for dangling windows).
            for item in items {
                MainBrowserWindowControllersManager.shared
                    .addPendingTabToDanglingWindow(item.tab, windowId: windowId.intValue)
            }
            AppLogInfo("🪟 [Chromium] Restored snapshot buffered to dangling window - windowId: \(windowId), tabs: \(items.count)")
            return
        }

        let payload = BrowserState.RestoredWindowSnapshot(tabs: items,
                                                          activeTabId: activeTabId,
                                                          splitActions: splitActions)
        // T3B: apply synchronously in this replay stack. The bridge calls on
        // Chromium's UI thread (= AppKit main = MainActor) but that isn't
        // type-enforced — mirror showCrashPage's assert-and-degrade rather
        // than trap; the off-main fallback keeps the T3A task shape so the
        // window still restores.
        guard Thread.isMainThread else {
            assertionFailure("restoredWindowSnapshot off the main thread; deferring application")
            Task { @MainActor in
                self.applyRestoredWindowSnapshot(payload, windowId: windowId)
            }
            return
        }
        MainActor.assumeIsolated {
            applyRestoredWindowSnapshot(payload, windowId: windowId)
        }
    }

    @MainActor
    private func applyRestoredWindowSnapshot(_ payload: BrowserState.RestoredWindowSnapshot,
                                             windowId: Int64) {
        guard let browserState = MainBrowserWindowControllersManager.shared
            .getBrowserState(for: windowId.intValue) else {
            // Same drop semantics as a queued event whose window closed:
            // the payload (tabs + wrappers) is simply released.
            AppLogWarn("Window not found for restored snapshot: \(windowId)")
            return
        }
        browserState.handleRestoredWindowSnapshot(payload)
    }

    /// Decodes the snapshot's buffered split events into the same actions
    /// the individual split delegate methods would have sent.
    private func parseSplitActions(fromBridgeEvents events: Any?) -> [SplitEvent.SplitAction] {
        guard let dicts = events as? [[AnyHashable: Any]], !dicts.isEmpty else { return [] }
        return dicts.compactMap { event in
            guard let type = event["type"] as? String,
                  let splitId = event["splitId"] as? String else {
                AppLogError("[Split] restored snapshot: malformed split event \(event)")
                return nil
            }
            switch type {
            case "created":
                guard let primary = event["primaryTabId"] as? Int,
                      let secondary = event["secondaryTabId"] as? Int,
                      let layout = event["layout"] as? String,
                      let ratio = event["ratio"] as? Double else {
                    AppLogError("[Split] restored snapshot: malformed created event \(event)")
                    return nil
                }
                return .created(splitId: splitId,
                                primaryTabId: primary,
                                secondaryTabId: secondary,
                                layout: parseBridgeLayout(layout),
                                ratio: ratio)
            case "visualsChanged":
                guard let layout = event["layout"] as? String,
                      let ratio = event["ratio"] as? Double else {
                    AppLogError("[Split] restored snapshot: malformed visualsChanged event \(event)")
                    return nil
                }
                return .visualsChanged(splitId: splitId,
                                       layout: parseBridgeLayout(layout),
                                       ratio: ratio)
            case "contentsChanged":
                guard let primary = event["primaryTabId"] as? Int,
                      let secondary = event["secondaryTabId"] as? Int else {
                    AppLogError("[Split] restored snapshot: malformed contentsChanged event \(event)")
                    return nil
                }
                return .contentsChanged(splitId: splitId,
                                        primaryTabId: primary,
                                        secondaryTabId: secondary)
            case "removed":
                return .removed(splitId: splitId)
            default:
                AppLogError("[Split] restored snapshot: unknown split event type \(type)")
                return nil
            }
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
    
    @MainActor
    func runQuitConfirmAlert() -> Bool {
        PhiAlert.runQuitAlert()
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
