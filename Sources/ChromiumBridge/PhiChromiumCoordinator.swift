// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
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

    /// App-scoped sync key layer (M2-4). Built on first use once an account
    /// exists; nil while signed out. Write access is confined to this file so
    /// the build/invalidate lifecycle stays in one place — an outside setter
    /// could leave a previous account's keys reachable over the bridge.
    private(set) var syncKeyController: SyncKeyController?

    /// Re-resolves mappings whenever the Chromium profile list changes. The
    /// startup silent unlock fires on login, which can beat `ProfileManager`'s
    /// async profile load — leaving `localProfilesProvider` empty so nothing is
    /// delivered and a just-joined device sits Disabled with no retry. This
    /// subscription closes that gap (and the mirror case: a profile created
    /// mid-session, which previously also needed a restart to register). Bound
    /// to the controller's lifetime; torn down in `invalidateSyncKeyController`.
    private var profilesCancellable: AnyCancellable?

    // MARK: - Phi settings sync (M3-1)
    //
    // The phi settings engine rides the same lifetime as the key layer above: it is built
    // beside `syncKeyController` and torn down with it, because it consumes the account's
    // ARK (through `PhiDomainKeyManager`) and must not outlive the account it was built for.
    // Scheduling is separate from construction: the ARK is still nil at build time and only
    // arrives from the async silent unlock, so `startPhiSyncIfReady()` runs after that await.

    /// Account-wide PhiBrowser domain key holder. Held here (not only inside the engine) so
    /// sign-out can `clear()` the in-memory key rather than waiting for the engine's own
    /// deallocation.
    private var phiDomainKeys: PhiDomainKeyManager?
    /// Settings sync engine. Nil while signed out, or when the device key id could not be
    /// read (the engine cannot address the server without a client id).
    private var phiSyncEngine: PhiSyncEngine?
    /// Debounced `UserDefaults.didChangeNotification` -> push. The engine's sidecar
    /// timestamps (`<key>.phiSyncTs` / `.phiSyncVal`) are what actually suppress the echo of
    /// its own remote apply; the debounce only coalesces bursts of local edits.
    private var phiSyncPushCancellable: AnyCancellable?
    /// Periodic GetUpdates.
    private var phiSyncPullTimer: Timer?
    /// `NSApplication.didBecomeActiveNotification` token for the foreground pull. `AppController`
    /// implements no `applicationDidBecomeActive(_:)`, and an observer keeps this whole feature
    /// inside one file.
    private var phiSyncForegroundObserver: NSObjectProtocol?

    /// Cadence of the periodic pull. Settings change rarely and the foreground pull covers
    /// the case the user actually notices (switching to the browser after editing elsewhere),
    /// so this only needs to bound the staleness of a window left open all day.
    private static let phiSyncPullInterval: TimeInterval = 15 * 60
    /// Coalescing window for local edits. A settings pane can write several keys in a row
    /// (and unrelated app code writes the same domain constantly), so never push per write.
    private static let phiSyncPushDebounce: TimeInterval = 2

    /// `UserDefaults.standard` key recording which account the engine's persisted cursor
    /// belongs to. Deliberately NOT one of `PhiSyncEngine.stateKeys`: the engine wipes those
    /// itself on NOT_MY_BIRTHDAY, and losing the owner there would make the next mount look
    /// like an account switch.
    static let phiSyncCursorOwnerKey = PhiSyncEngine.statePrefix + "cursorAccount"

    /// Drops the engine's persisted cursor when `defaults` still carries a *different*
    /// account's, and records the new owner. Returns whether anything was dropped.
    ///
    /// The cursor (progress marker, entity id, version, store birthday, last-committed
    /// entity, `hasAdopted`) lives in `UserDefaults.standard`, which is not account-scoped,
    /// so without this account A's marker and entity version would be replayed against
    /// account B. Keyed on the account id rather than done unconditionally in
    /// `invalidateSyncKeyController` because `.mainAccountChanged` fires on *every* account
    /// assignment — including the ordinary launch/refresh path — and wiping the cursor there
    /// would clear `hasAdopted` on every launch, making the next pull adopt the server's
    /// entity wholesale and discard settings edited while signed out.
    @discardableResult
    static func resetPhiSyncCursorIfAccountChanged(accountId: String, defaults: UserDefaults) -> Bool {
        guard defaults.string(forKey: phiSyncCursorOwnerKey) != accountId else { return false }
        defaults.set(accountId, forKey: phiSyncCursorOwnerKey)
        let hadCursor = PhiSyncEngine.stateKeys.contains { defaults.object(forKey: $0) != nil }
        for key in PhiSyncEngine.stateKeys { defaults.removeObject(forKey: key) }
        return hadCursor
    }

    /// Builds `syncKeyController` on first call if an account is signed in;
    /// no-op if it already exists. Does not kick the silent unlock — callers
    /// that also need that should go through `ensureSyncKeyControllerAndUnlock()`.
    @MainActor
    private func buildSyncKeyControllerIfNeeded() -> SyncKeyController? {
        guard let account = AccountController.shared.account else { return nil }
        let stack = SyncKeyStack.make()
        let mappingStore = AccountProfileSyncMappingStore(defaults: account.userDefaults)
        let profileKeys = ProfileKeyManager(api: stack.api, keyManager: stack.manager, mappingStore: mappingStore)
        syncKeyController = SyncKeyController(
            manager: stack.manager, approvals: stack.approvals, profileKeys: profileKeys,
            localProfilesProvider: {
                ProfileManager.shared.userAssignableProfiles.map { ($0.profileId, $0.displayName) }
            },
            notifyChromium: {
                ChromiumLauncher.sharedInstance().bridge?.notifyPhiSyncKeysChanged?()
            })
        // Re-resolve when the profile list changes (keyed by profile ids so a
        // rename doesn't churn). `dropFirst()` skips the value present at
        // subscribe time — the startup path's own silent unlock covers that;
        // this only reacts to a *later* load/create.
        profilesCancellable = ProfileManager.shared.$profiles
            .map { $0.map(\.profileId) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.syncKeyController?.silentUnlockAndResolve()
                    // A profile arriving late can be the first unlock this process gets, so
                    // this path has to be able to start the settings scheduling too.
                    self?.startPhiSyncIfReady()
                }
            }
        buildPhiSyncEngine(stack: stack, accountId: account.userID)
        return syncKeyController
    }

    /// Builds the settings sync engine alongside the key controller. Scheduling is NOT
    /// started here — the ARK is still nil at this point (it arrives from the async silent
    /// unlock, and the Devices-pane entry point never unlocks at all), so the readiness gate
    /// lives in `startPhiSyncIfReady()`.
    @MainActor
    private func buildPhiSyncEngine(
        stack: (api: KeyEnvelopeAPIClient, manager: AccountKeyManager, approvals: DeviceApprovalService),
        accountId: String
    ) {
        let deviceKeyId: String
        do {
            // A second `DeviceKeyStore` is safe: it is stateless and reads the same Keychain
            // item the stack's own store does. `SyncKeyStack.make()` keeps its store local.
            deviceKeyId = try DeviceKeyStore().deviceKeyId()
        } catch {
            // Keychain unavailable (locked, denied). The key layer above degrades on its own;
            // settings sync simply does not run this session.
            AppLogWarn("[phi-sync] engine not built: device key id unavailable (\(error))")
            return
        }

        // Do this before the engine exists so no round can read a half-cleared cursor.
        let defaults = UserDefaults.standard
        if Self.resetPhiSyncCursorIfAccountChanged(accountId: accountId, defaults: defaults) {
            AppLogInfo("[phi-sync] dropped the previous account's settings cursor")
        }

        let domainKeys = PhiDomainKeyManager(api: stack.api, keyManager: stack.manager)
        let client = PhiSyncHTTPClient(
            tokenProvider: { AuthManager.shared.getAccessTokenSyncly() },
            deviceKeyId: deviceKeyId)
        phiDomainKeys = domainKeys
        // `UserDefaults.standard`, not `account.userDefaults`: the syncable settings are
        // `PhiPreferences` keys and every reader hardcodes the standard domain.
        phiSyncEngine = PhiSyncEngine(domainKeys: domainKeys, client: client,
                                      defaults: defaults, deviceKeyId: deviceKeyId)
    }

    /// Starts the settings sync schedule once the key layer is actually unlocked: a login
    /// pull, then a periodic pull, a foreground pull and a debounced push for local edits.
    ///
    /// Idempotent — both `.loginCompleted` and `.loginStatusRefreshCompleted` reach here on a
    /// single login, and the `$profiles` subscription can too, so a second call must not
    /// double-schedule. Gated on the ARK because every round needs the domain key: without
    /// it `PhiDomainKeyManager.domainKey()` throws `notUnlocked` and each tick would be a
    /// wasted no-op.
    @MainActor
    private func startPhiSyncIfReady() {
        guard let engine = phiSyncEngine, phiSyncPullTimer == nil else { return }
        guard syncKeyController?.manager.currentARK != nil else { return }

        phiSyncForegroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.phiSyncEngine?.pullOnce() }
        }

        phiSyncPushCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .seconds(Self.phiSyncPushDebounce), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                // The notification does not say which key changed, and the engine's own
                // remote apply writes the same domain — `handleLocalDefaultsChange()` is the
                // entry point that returns early while a remote apply is in flight and
                // commits nothing when the snapshot still matches what the server holds.
                Task { @MainActor in await self?.phiSyncEngine?.handleLocalDefaultsChange() }
            }

        phiSyncPullTimer = Timer.scheduledTimer(
            withTimeInterval: Self.phiSyncPullInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in await self?.phiSyncEngine?.pullOnce() }
        }

        AppLogInfo("[phi-sync] scheduling started interval=\(Int(Self.phiSyncPullInterval))s debounce=\(Int(Self.phiSyncPushDebounce))s")
        Task { await engine.pullOnce() }
    }

    /// Build-only entry point for consumers (the Devices pane) that just need
    /// the shared controller instance and will drive their own unlock/UI flow.
    /// Returns nil while signed out.
    @MainActor
    func syncKeyControllerCreatingIfNeeded() -> SyncKeyController? {
        syncKeyController ?? buildSyncKeyControllerIfNeeded()
    }

    /// Startup/login entry point: build the controller if needed, then
    /// fire-and-forget its silent unlock + mapping resolution.
    @MainActor
    func ensureSyncKeyControllerAndUnlock() {
        let controller = syncKeyControllerCreatingIfNeeded()
        Task { @MainActor in
            await controller?.silentUnlockAndResolve()
            // After the await, not before: the ARK the settings engine needs only exists
            // once the unlock has run.
            self.startPhiSyncIfReady()
        }
    }

    /// Drops the sync key layer on sign-out or account switch and tells
    /// Chromium to re-pull immediately (it gets nil, which closes the sync
    /// gate). The controller binds an account-scoped stack and mapping store,
    /// so it must not survive the account it was built for — otherwise the
    /// previous account's UUID + passphrase keep crossing the bridge.
    ///
    /// Rebuilding is left to the existing `.loginCompleted` /
    /// `.loginStatusRefreshCompleted` observers, both of which fire *after*
    /// `AccountController.account` is assigned, and to the Devices pane's
    /// per-access `syncKeyControllerCreatingIfNeeded()`.
    ///
    /// `clearResolved()` is called before dropping the reference because this
    /// coordinator is not necessarily the last owner — an open key-layer window
    /// captured the controller when it was presented, and that copy must stop
    /// holding the previous account's passphrases too. It may emit its own
    /// ping; the unconditional one below covers the case where the cache was
    /// already empty, and a duplicate merely makes Chromium re-pull nil twice.
    @MainActor
    func invalidateSyncKeyController() {
        profilesCancellable?.cancel()
        profilesCancellable = nil
        stopPhiSync()
        syncKeyController?.clearResolved()
        syncKeyController = nil
        ChromiumLauncher.sharedInstance().bridge?.notifyPhiSyncKeysChanged?()
    }

    /// Mirror image of `startPhiSyncIfReady()` + `buildPhiSyncEngine()`. Every schedule
    /// source is torn down and the engine dropped, so no tick can fire against the previous
    /// account. `PhiDomainKeyManager.clear()` is explicit rather than left to deallocation:
    /// an in-flight round still holds the manager, and the account's domain key must stop
    /// being reachable at sign-out, not whenever that round happens to finish.
    ///
    /// The persisted cursor is deliberately NOT wiped here — see
    /// `resetPhiSyncCursorIfAccountChanged`, which does it at the next build and only when
    /// the account actually differs.
    @MainActor
    private func stopPhiSync() {
        phiSyncPushCancellable?.cancel()
        phiSyncPushCancellable = nil
        phiSyncPullTimer?.invalidate()
        phiSyncPullTimer = nil
        if let observer = phiSyncForegroundObserver {
            NotificationCenter.default.removeObserver(observer)
            phiSyncForegroundObserver = nil
        }
        phiSyncEngine = nil
        phiDomainKeys?.clear()
        phiDomainKeys = nil
    }
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

    /// Hot path: Chromium pulls per-profile sync info synchronously on the UI
    /// thread. Mirror `showCrashPage`'s assert-and-skip convention rather than
    /// trapping if it ever arrives off-main.
    @objc(getPhiProfileSyncInfo:)
    func getPhiProfileSyncInfo(_ profileId: String) -> [String: Any]? {
        guard Thread.isMainThread else {
            assertionFailure("getPhiProfileSyncInfo off the main thread")
            return nil
        }
        return MainActor.assumeIsolated {
            guard let info = syncKeyController?.profileSyncInfo(forProfileId: profileId) else { return nil }
            return ["uuid": info.uuid, "passphrase": info.passphrase]
        }
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

        NotificationCenter.default.addObserver(
            forName: .phiAuthSessionDidChange, object: nil, queue: .main
        ) { _ in
            // Optional-chained twice: the bridge may not be up yet, and an
            // older framework may not implement the selector — both degrade
            // to Chromium's 30s poll.
            ChromiumLauncher.sharedInstance().bridge?.notifyPhiAuthStateChanged?()
        }

        // Sign-out and account switch. `.mainAccountChanged` is the minimal
        // signal that covers both: every sign-out path nils
        // `AccountController.account` (AccountSettingViewController's logout
        // and AuthManager's unrecoverable-session reset), and every sign-in /
        // switch assigns it. `.phiAuthSessionDidChange` is deliberately NOT
        // used here — it also fires on routine token renewal, which would tear
        // down a perfectly good key layer roughly hourly.
        NotificationCenter.default.addObserver(
            forName: .mainAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PhiChromiumCoordinator.shared.invalidateSyncKeyController() }
        }

        NotificationCenter.default.addObserver(
            forName: .loginStatusRefreshCompleted, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PhiChromiumCoordinator.shared.ensureSyncKeyControllerAndUnlock() }
        }
        NotificationCenter.default.addObserver(
            forName: .loginCompleted, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in PhiChromiumCoordinator.shared.ensureSyncKeyControllerAndUnlock() }
        }
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
