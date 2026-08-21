// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Native owner for Chromium browsers carrying the Kiosk semantic type.
final class KioskBrowserWindowController: MainBrowserWindowController {
    private static let toolbarIdentifier = NSToolbar.Identifier("KioskBrowserToolbar")
    private static let profileReplacementTimeout: TimeInterval = 1.5
    private static let profileReplacementClosePollInterval: TimeInterval = 0.5
    private static let profileReplacementHandoffDelay: TimeInterval = 0.05
    private static let profileReplacementSnapshotHoldDuration: TimeInterval = 0.08
    private static let profileReplacementSnapshotFadeDuration: TimeInterval = 0.08

    private var pendingProfileId: String?
    private weak var profileReplacementSource: KioskBrowserWindowController?
    private var profileReplacementSourceWindowId: Int?
    private var profileReplacementInheritedFrame: NSRect?
    private var profileReplacementTimeoutWorkItem: DispatchWorkItem?
    private var profileReplacementClosePollWorkItem: DispatchWorkItem?
    private var profileReplacementIsAwaitingSourceClose = false
    private var profileReplacementSourceWasKey = false
    private var profileReplacementSourceCloseObserver: NSObjectProtocol?
    private var profileReplacementSourceFullscreenObserver: NSObjectProtocol?
    private var profileReplacementTargetCloseObserver: NSObjectProtocol?

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    init(window: NSWindow,
         windowId: Int,
         browserType: ChromiumBrowserType,
         profileId: String,
         account: Account = AccountController.shared.account
            ?? AccountController.defaultAccount) {
        let state = KioskBrowserState(
            windowId: windowId,
            localStore: account.localStorage,
            profileId: profileId,
            isIncognito: browserType == .kioskIncognito
        )
        super.init(
            window: window,
            windowId: windowId,
            browserType: browserType,
            profileId: profileId,
            spaceId: LocalStore.defaultSpaceId,
            account: account,
            slot: nil,
            browserState: state
        )
        configureKioskWindow(window)
        configureKioskActions()
    }

    @MainActor
    func handleCommand(_ command: CommandWrapper) -> Bool {
        switch command {
        case .IDC_BACK:
            browserState.focusingTab?.goBack()
            return true
        case .IDC_FORWARD:
            browserState.focusingTab?.goForward()
            return true
        case .IDC_RELOAD:
            browserState.focusingTab?.reload()
            return true
        case .IDC_RELOAD_BYPASSING_CACHE:
            browserState.focusingTab?.reloadBypassingCache()
            return true
        case .IDC_STOP:
            browserState.focusingTab?.stopLoading()
            return true
        case .IDC_FOCUS_LOCATION:
            presentOmniBox(fromAddressBar: true)
            return true
        case .IDC_NEW_TAB, .IDC_NEW_TAB_TO_RIGHT, .IDC_FOCUS_SEARCH:
            presentOmniBox(fromAddressBar: false)
            return true
        case .IDC_CLOSE_TAB:
            ChromiumLauncher.sharedInstance().bridge?.executeCommand(
                Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue),
                windowId: Int64(windowId)
            )
            return true
        case .IDC_TAB_SEARCH, .IDC_DUPLICATE_TAB, .IDC_WINDOW_PIN_TAB,
             .IDC_DEV_TOOLS, .IDC_DEV_TOOLS_INSPECT,
             .IDC_DEV_TOOLS_CONSOLE, .PHI_TOGGLE_SIDEBAR,
             .PHI_TOGGLE_CHATBAR,
             .IDC_SELECT_PREVIOUS_TAB, .IDC_SELECT_NEXT_TAB,
             .IDC_SELECT_LAST_TAB, .PHI_TAB_SWITCHER_FORWARD,
             .PHI_TAB_SWITCHER_BACKWARD, .PHI_SELECT_NEXT_SPACE,
             .PHI_SELECT_PREVIOUS_SPACE:
            return true
        case let command where command.spaceSelectionIndex != nil:
            return true
        case let command
            where command.rawValue >= CommandWrapper.IDC_SELECT_TAB_0.rawValue
                && command.rawValue <= CommandWrapper.IDC_SELECT_TAB_7.rawValue:
            return true
        default:
            return false
        }
    }

    override func handleTabReadyToDisplay(tabId: Int) {
        super.handleTabReadyToDisplay(tabId: tabId)
        guard browserState.focusingTab?.guid == tabId else { return }
        completeProfileReplacementIfNeeded()
    }

    @MainActor
    func switchProfile(to targetProfileId: String) {
        guard targetProfileId != profileId,
              pendingProfileId == nil,
              window?.styleMask.contains(.fullScreen) != true,
              ProfileManager.shared.userAssignableProfiles.contains(where: {
                  $0.profileId == targetProfileId
              }),
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            return
        }

        let currentURL = browserState.focusingTab?.url
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "about:blank"
        let inheritedFrame = window?.frame
        pendingProfileId = targetProfileId

        bridge.ensureProfileLoaded(targetProfileId) { [weak self] success in
            DispatchQueue.main.async {
                guard let self,
                      self.pendingProfileId == targetProfileId,
                      ApplicationState.shared.canOpenExternalLinksInKiosk,
                      self.window?.styleMask.contains(.fullScreen) != true,
                      let bridge = ChromiumLauncher.sharedInstance().bridge,
                      MainBrowserWindowControllersManager.shared
                        .controller(for: self.windowId) === self else {
                    self?.pendingProfileId = nil
                    return
                }
                guard success else {
                    AppLogWarn("[Kiosk] Failed to load profile \(targetProfileId)")
                    self.pendingProfileId = nil
                    return
                }
                self.createProfileReplacement(
                    profileId: targetProfileId,
                    url: currentURL,
                    inheritedFrame: inheritedFrame,
                    bridge: bridge
                )
            }
        }
    }

    @MainActor
    private func createProfileReplacement(
        profileId targetProfileId: String,
        url: String,
        inheritedFrame: NSRect?,
        bridge: PhiChromiumBridgeProtocol
    ) {
        guard pendingProfileId == targetProfileId else { return }
        guard let result = bridge.createBrowser(
            withWindowType: browserType,
            profileId: targetProfileId,
            hidden: true
        ) else {
            AppLogWarn("[Kiosk] Failed to create replacement browser")
            pendingProfileId = nil
            return
        }

        let replacementWindowId = (result["windowId"] as? NSNumber)?.intValue
        guard let replacementWindowId,
              let replacementWindow = result["window"] as? NSWindow,
              let replacement = MainBrowserWindowControllersManager.shared
                .controller(for: replacementWindowId) as? KioskBrowserWindowController,
              let reportedProfileId = result["profileId"] as? String,
              let reportedWindowType = result["windowType"] as? NSNumber,
              reportedProfileId == targetProfileId,
              reportedWindowType.uintValue == browserType.rawValue,
              replacement.profileId == targetProfileId,
              replacement.browserType == browserType,
              replacement.window === replacementWindow else {
            AppLogWarn("[Kiosk] Replacement browser was not registered")
            if let replacementWindowId {
                closeChromiumWindow(replacementWindowId)
            }
            pendingProfileId = nil
            return
        }

        replacement.prepareForProfileReplacement(
            from: self,
            inheritedFrame: inheritedFrame,
            replacementWindow: replacementWindow
        )
        guard bridge.responds(
            to: #selector(
                PhiChromiumBridgeProtocol.createNewTabStrictly(
                    withUrl:windowId:focusAfterCreate:
                )
            )
        ), bridge.createNewTabStrictly(
            withUrl: url,
            windowId: Int64(replacementWindowId),
            focusAfterCreate: true
        ) else {
            AppLogWarn("[Kiosk] Strict replacement navigation is unavailable")
            replacement.abortProfileReplacement()
            return
        }
    }

    @MainActor
    private func prepareForProfileReplacement(
        from source: KioskBrowserWindowController,
        inheritedFrame: NSRect?,
        replacementWindow: NSWindow
    ) {
        profileReplacementSource = source
        profileReplacementSourceWindowId = source.windowId
        profileReplacementInheritedFrame = inheritedFrame
        profileReplacementSourceWasKey = false
        if let inheritedFrame {
            replacementWindow.setFrame(inheritedFrame, display: false)
        }
        replacementWindow.alphaValue = 0
        replacementWindow.ignoresMouseEvents = true
        if let sourceWindow = source.window, sourceWindow.windowNumber > 0 {
            replacementWindow.order(.below, relativeTo: sourceWindow.windowNumber)
        } else {
            replacementWindow.orderFront(nil)
        }

        if let sourceWindow = source.window {
            profileReplacementSourceCloseObserver = NotificationCenter.default
                .addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: sourceWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.profileReplacementSourceWillClose()
                    }
                }
            profileReplacementSourceFullscreenObserver = NotificationCenter.default
                .addObserver(
                    forName: NSWindow.willEnterFullScreenNotification,
                    object: sourceWindow,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.abortProfileReplacement()
                    }
                }
        }
        profileReplacementTargetCloseObserver = NotificationCenter.default
            .addObserver(
                forName: NSWindow.willCloseNotification,
                object: replacementWindow,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.profileReplacementTargetDidClose()
                }
            }

        profileReplacementTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.completeProfileReplacementIfNeeded()
        }
        profileReplacementTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.profileReplacementTimeout,
            execute: workItem
        )
    }

    @MainActor
    private func completeProfileReplacementIfNeeded() {
        guard profileReplacementSourceWindowId != nil,
              !profileReplacementIsAwaitingSourceClose else { return }
        guard let source = profileReplacementSource else {
            abortProfileReplacement()
            return
        }
        guard MainBrowserWindowControllersManager.shared
            .controller(for: source.windowId) === source,
              browserState.focusingTab != nil,
              let replacementWindow = window,
              let sourceWindow = source.window,
              sourceWindow.windowNumber > 0 else {
            abortProfileReplacement()
            return
        }

        profileReplacementTimeoutWorkItem?.cancel()
        profileReplacementTimeoutWorkItem = nil
        // Chromium detaches the source WebContents before AppKit removes its
        // window, and a hidden target can also briefly lose its remote surface
        // when promoted onscreen. Mask both gaps with the last source frame.
        let sourceContent = source.contentViewController
            as? KioskBrowserContentViewController
        let replacementContent = contentViewController
            as? KioskBrowserContentViewController
        if let snapshot = sourceContent?.captureProfileReplacementSnapshot() {
            sourceContent?.showProfileReplacementSnapshot(snapshot)
            replacementContent?.showProfileReplacementSnapshot(snapshot)
        }

        // Make the prepared replacement compositable beneath the source before
        // asking Chromium to close the source.
        profileReplacementInheritedFrame = sourceWindow.frame
        replacementWindow.setFrame(sourceWindow.frame, display: false)
        replacementWindow.ignoresMouseEvents = true
        replacementWindow.alphaValue = 1
        replacementWindow.order(
            .below,
            relativeTo: sourceWindow.windowNumber
        )
        replacementWindow.displayIfNeeded()
        // Capture focus immediately before requesting source closure. A profile
        // load or first paint may have taken long enough for the user to focus
        // another window since the replacement was prepared.
        profileReplacementSourceWasKey = sourceWindow.isKeyWindow
        profileReplacementIsAwaitingSourceClose = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.profileReplacementHandoffDelay
        ) { [weak self, weak source] in
            guard let self, let source,
                  self.profileReplacementIsAwaitingSourceClose,
                  self.profileReplacementSource === source else { return }
            self.scheduleProfileReplacementClosePoll()
            self.closeChromiumWindow(source.windowId)
        }
    }

    @MainActor
    private func profileReplacementSourceWillClose() {
        guard profileReplacementSourceWindowId != nil else { return }
        guard profileReplacementIsAwaitingSourceClose else {
            abortProfileReplacement()
            return
        }
        guard let replacementWindow = window else {
            abortProfileReplacement()
            return
        }

        // The target is already ordered beneath the source. Keep it opaque in
        // the same close transaction, then defer only focus and interaction so
        // AppKit teardown cannot expose an empty frame or be re-entered.
        replacementWindow.alphaValue = 1
        replacementWindow.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.profileReplacementIsAwaitingSourceClose else {
                return
            }
            self.revealProfileReplacement()
        }
    }

    @MainActor
    private func revealProfileReplacement() {
        // A source-close notification and the close-state poll can both reach
        // this method. The first successful reveal clears the transaction; any
        // already-enqueued second callback must be an idempotent no-op.
        guard profileReplacementSourceWindowId != nil else { return }
        guard let replacementWindow = window else {
            abortProfileReplacement()
            return
        }

        profileReplacementTimeoutWorkItem?.cancel()
        profileReplacementTimeoutWorkItem = nil
        profileReplacementClosePollWorkItem?.cancel()
        profileReplacementClosePollWorkItem = nil
        removeProfileReplacementObservers()
        let source = profileReplacementSource
        let shouldBecomeKey = source?.window?.isKeyWindow == true
            || profileReplacementSourceWasKey
        profileReplacementSource = nil
        profileReplacementSourceWindowId = nil
        profileReplacementIsAwaitingSourceClose = false
        profileReplacementSourceWasKey = false
        source?.pendingProfileId = nil

        if let profileReplacementInheritedFrame {
            replacementWindow.setFrame(
                profileReplacementInheritedFrame,
                display: false
            )
        }
        profileReplacementInheritedFrame = nil
        replacementWindow.ignoresMouseEvents = false
        replacementWindow.alphaValue = 1
        if shouldBecomeKey {
            replacementWindow.makeKeyAndOrderFront(nil)
        } else {
            replacementWindow.orderFront(nil)
        }
        replacementWindow.displayIfNeeded()
        (contentViewController as? KioskBrowserContentViewController)?
            .dismissProfileReplacementSnapshot(
                after: Self.profileReplacementSnapshotHoldDuration,
                duration: Self.profileReplacementSnapshotFadeDuration
            )
        (source?.contentViewController as? KioskBrowserContentViewController)?
            .clearProfileReplacementSnapshot()
    }

    @MainActor
    private func scheduleProfileReplacementClosePoll() {
        profileReplacementClosePollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollProfileReplacementCloseState()
        }
        profileReplacementClosePollWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.profileReplacementClosePollInterval,
            execute: workItem
        )
    }

    @MainActor
    private func pollProfileReplacementCloseState() {
        // A cancelled work item may already be executing after a successful
        // reveal. Treat the cleared transaction as terminal, not as failure.
        guard profileReplacementIsAwaitingSourceClose else { return }
        guard let sourceWindowId = profileReplacementSourceWindowId,
              let bridge = ChromiumLauncher.sharedInstance().bridge else {
            abortProfileReplacement()
            return
        }

        switch bridge.windowCloseState(forWindowId: Int64(sourceWindowId)) {
        case .gone:
            revealProfileReplacement()
        case .attemptingClose:
            scheduleProfileReplacementClosePoll()
        case .notAttempting:
            AppLogInfo("[Kiosk] Profile replacement cancelled by beforeunload")
            abortProfileReplacement()
        @unknown default:
            scheduleProfileReplacementClosePoll()
        }
    }

    @MainActor
    private func abortProfileReplacement() {
        profileReplacementTimeoutWorkItem?.cancel()
        profileReplacementTimeoutWorkItem = nil
        profileReplacementClosePollWorkItem?.cancel()
        profileReplacementClosePollWorkItem = nil
        removeProfileReplacementObservers()
        let source = profileReplacementSource
        profileReplacementSource = nil
        profileReplacementSourceWindowId = nil
        profileReplacementInheritedFrame = nil
        profileReplacementIsAwaitingSourceClose = false
        profileReplacementSourceWasKey = false
        source?.pendingProfileId = nil
        (source?.contentViewController as? KioskBrowserContentViewController)?
            .clearProfileReplacementSnapshot()
        (contentViewController as? KioskBrowserContentViewController)?
            .clearProfileReplacementSnapshot()
        window?.orderOut(nil)
        let targetWindowId = windowId
        DispatchQueue.main.async { [weak self] in
            self?.closeChromiumWindow(targetWindowId)
        }
    }

    @MainActor
    private func profileReplacementTargetDidClose() {
        guard profileReplacementSourceWindowId != nil else { return }
        profileReplacementTimeoutWorkItem?.cancel()
        profileReplacementTimeoutWorkItem = nil
        profileReplacementClosePollWorkItem?.cancel()
        profileReplacementClosePollWorkItem = nil
        removeProfileReplacementObservers()
        profileReplacementSource?.pendingProfileId = nil
        (profileReplacementSource?.contentViewController
            as? KioskBrowserContentViewController)?
            .clearProfileReplacementSnapshot()
        (contentViewController as? KioskBrowserContentViewController)?
            .clearProfileReplacementSnapshot()
        profileReplacementSource = nil
        profileReplacementSourceWindowId = nil
        profileReplacementInheritedFrame = nil
        profileReplacementIsAwaitingSourceClose = false
        profileReplacementSourceWasKey = false
    }

    private func removeProfileReplacementObservers() {
        if let profileReplacementSourceCloseObserver {
            NotificationCenter.default.removeObserver(
                profileReplacementSourceCloseObserver
            )
            self.profileReplacementSourceCloseObserver = nil
        }
        if let profileReplacementTargetCloseObserver {
            NotificationCenter.default.removeObserver(
                profileReplacementTargetCloseObserver
            )
            self.profileReplacementTargetCloseObserver = nil
        }
        if let profileReplacementSourceFullscreenObserver {
            NotificationCenter.default.removeObserver(
                profileReplacementSourceFullscreenObserver
            )
            self.profileReplacementSourceFullscreenObserver = nil
        }
    }

    private func closeChromiumWindow(_ windowId: Int) {
        ChromiumLauncher.sharedInstance().bridge?.executeCommand(
            Int32(CommandWrapper.IDC_CLOSE_WINDOW.rawValue),
            windowId: Int64(windowId)
        )
    }

    private func configureKioskWindow(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 640, height: 420)
        if window.frame.width < 640 || window.frame.height < 480 {
            window.setContentSize(NSSize(width: 900, height: 640))
        }
        
        window.backgroundColor = NSColor.windowBackgroundColor
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.animationBehavior = .none
    }

    @MainActor
    private func configureKioskActions() {
        (contentViewController as? KioskBrowserContentViewController)?
            .configureActions(
                onProfileSelection: { [weak self] profileId in
                    self?.switchProfile(to: profileId)
                },
                onSpaceSelection: { [weak self] spaceId in
                    guard let self,
                          !self.browserState.isIncognito,
                          let tab = self.browserState.focusingTab else {
                        return
                    }
                    SpaceManager.shared.moveTab(tab, toSpaceId: spaceId)
                },
                onOmniBoxRequest: { [weak self] in
                    self?.presentOmniBox(fromAddressBar: true)
                }
            )
    }

    @MainActor
    private func presentOmniBox(fromAddressBar: Bool) {
        let contentController = contentViewController
            as? KioskBrowserContentViewController
        toggleOmniBox(
            fromAddressBar: fromAddressBar,
            addressView: fromAddressBar
                ? contentController?.addressBarAnchorView
                : nil
        )
    }
}
