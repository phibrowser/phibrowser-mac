// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import AuthenticationServices
import SwiftData
import CocoaLumberjackSwift
import Kingfisher
import Auth0
import Sparkle
import WebKit
import Settings
import PostHog

@objc class AppController: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!
    @objc static private(set)var shared: AppController!
    
    var settingsWindowController: SettingsWindowController?
    /// Whether `settingsWindowController` was built with the Developer pane.
    /// The pane list is fixed at window creation, so this goes stale when the
    /// General-tab "Developer mode" toggle changes while the window is open;
    /// `developerModeDidChange()` consults it to rebuild the window.
    var settingsPanesIncludeDeveloper = false

    var container: ModelContainer?
    var updater: SPUUpdater?
    var sparkleUserDriver: PhiSparkleUserDriver?
    /// Sparkle update state
    var updateState: UpdateState = .idle {
        didSet {
            DispatchQueue.main.async {
                self.updateCheckForUpdateMenuItem()
            }
        }
    }
    
    var menuObservation: NSKeyValueObservation?

    // MARK: - Auth0 login gating
    private var pendingLaunchAfterLogin: Bool = true

    /// Defer forwarding cold-launch URLs until Chromium session restore registers
    /// the first tabbed `Browser` (see `OpenUrlsInBrowserWithProfile`).
    private static let coldOpenURLForwardDelay: TimeInterval = 0.5
    /// Upper bound on cold-open forward deferrals (attempts × delay ≈ 4s).
    /// After that the URLs are forwarded regardless of readiness — a late,
    /// possibly unrouted open beats silently dropping the user's link.
    private static let coldOpenURLForwardMaxAttempts = 8
    private var coldOpenURLForwardWorkItem: DispatchWorkItem?
    private var coldOpenURLForwardAttempts = 0
    private var pendingColdOpenForwardURLs: [URL] = []
    private var pendingOpenURLsAwaitingBrowserAccess: [URL] = []
    /// Cached in `applicationWillFinishLaunching`; weak — owned by `ChromiumLauncher`, not AppController.
    private weak var chromiumBridge: (any PhiChromiumBridgeProtocol)?

    override init() {
        super.init()
        Self.shared = self
        // Opt out of AppKit's window-state restoration. macOS otherwise
        // re-enters native fullscreen on a previously-fullscreen window a few
        // seconds into the next launch (its own Spaces/saved-state restoration),
        // independent of Chromium's restored show-state and the window's
        // `isRestorable` — leaving restored windows fullscreen (and the reconcile
        // then orphans empty fullscreen Spaces). Chromium owns tab/session
        // restore and Phi owns window frame/Space affinity, so AppKit's
        // window-state restoration is redundant here; turning it off makes
        // restored windows come back as normal windows. Set in `init` (before
        // `applicationWillFinishLaunching`) so it lands before AppKit reads it.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resolve the synchronous browser-access gate before Chromium asks
        // whether its windows may be shown. The async refresh below can still
        // recover a fresher shared credential snapshot afterwards.
        resolveBrowserAccessFromAuthentication(checkChromiumLaunchStatus: true)
        if ApplicationState.shared.isGuest {
            GuestModePreferences.disableAI()
        }
        LoginController.shared.prepareGuestMigrationRecoveryBeforeChromiumLaunch()
        let permitsSentinelLaunch: Bool
        if ApplicationState.shared.isGuest {
            permitsSentinelLaunch =
                AuthManager.shared
                    .prepareGuestSessionBoundaryBeforeServiceLaunch(
                        preserveLocalRecoveryCredentials:
                            ApplicationState.shared
                                .isGuestMigrationRecoveryInProgress
                    )
        } else {
            permitsSentinelLaunch = true
        }
        LoginController.shared.refreshLoginStatusOnLaunching()
        
        //        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self
        
        ChromiumLauncher.sharedInstance().bridge?.applicationDidFinishLaunching(notification)
        SentinelTelemetryConsentPublisher.shared.start()
        
        //        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self
        
        setupSparkle()
        setupKinfisherCache()
        
        SentryService.setup()
        
        MemoryUsageMonitor.shared.start()

        DefaultExtensionManifestWriter.start()
        FeedbackOutboxUploader.shared.start()

        // The agent CDP socket listens for the whole app session, whether or
        // not agent browser control is switched on: an agent that connects
        // while it is off gets a consent prompt offering to turn it on, rather
        // than an endpoint that isn't there (see AgentCDPListener).
        AgentCDPListener.shared.start()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(phiWillTryToTerminateApplicationNotification(_:)),
                                               name: Notification.Name("PhiWillTryToTerminateApplicationNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(loginStatusRefreshCompleted(_:)),
                                               name: .loginStatusRefreshCompleted,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(loginCompleted(_:)),
                                               name: .loginCompleted,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(browserAccessStateDidChange(_:)),
                                               name: .browserAccessStateDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(mainAccountChanged(_:)),
                                               name: .mainAccountChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshSpacesMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(refreshBookmarksMenuVisibility),
                                               name: .activeBrowserWindowDidChange,
                                               object: nil)
        
        if permitsSentinelLaunch,
           ApplicationState.shared.isAuthenticated {
            AuthenticatedSentinelSessionLifecycle.reconcile()
            Task.detached(priority: .utility) {
                await SentinelVersionGuard.shared.runStartupCheck()
            }
        } else {
            AuthenticatedSentinelSessionLifecycle.reconcile()
            if !permitsSentinelLaunch {
                AppLogError(
                    "Sentinel launch suppressed because the Guest " +
                    "shared-token boundary could not be established"
                )
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        bindChromiumBridgeIfNeeded()

        // Register defaults before any settings are read.
        UserDefaultsRegistration.registerDefaults()
        
        setupLogging()
        SentinelLanguagePreferenceSync.persistCurrentPreference()
        // Wire the shared keychain store into AppLog so its keychain errors and
        // retry recoveries land in the same log file as the rest of the app.
        // Must happen before any auth flow (login / renew / launch recovery)
        // touches `SharedAuthTokenStore`.
        SharedAuthTokenStore.shared.logDelegate = SharedAuthTokenStoreLogBridge.shared
        AppLogInfo("------------------------------  Starting: \(Self.makeClientString())  ------------------------------")
        recordLaunchVersion()

        // The startup takeover for the user-data removal mechanism runs in
        // main() (UserDataRemovalBootstrap), before Chromium reads any state.

        // Set up PostHog before `didFinishLaunchingNotification` fires so the
        // SDK can observe the app-opened lifecycle event. If either value is
        // missing the app runs without analytics.
        if let token = PostHogEnv.projectToken.value,
           let host = PostHogEnv.host.value {
            let postHogConfig = PostHogConfig(apiKey: token, host: host)
            postHogConfig.captureApplicationLifecycleEvents = true
            #if DEBUG
            postHogConfig.debug = true
            #endif
            postHogConfig.setBeforeSend { event in
                guard event.event == "Application Opened" else { return event }
                event.properties["layout_mode"] = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue
                event.properties["ai_enabled"] = PhiPreferences.AISettings.phiAIEnabled.loadValue()
                event.properties["is_guest_mode"] = ApplicationState.shared.isGuest
                return event
            }
            PostHogSDK.shared.setup(postHogConfig)
            captureUserDefaultsSnapshot()
        } else {
            AppLogInfo("PostHog: project token or host not set in PostHogConfig.generated.swift; skipping init")
        }

        chromiumBridge?.applicationWillFinishLaunching(notification)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coldOpenURLForwardWorkItem?.cancel()
        coldOpenURLForwardWorkItem = nil
        SentinelTelemetryConsentPublisher.shared.stop()
        AppLogInfo("-------applicationWillTerminate----")
        MemoryUsageMonitor.shared.stop()
        AgentCDPListener.shared.stop()
        if let chromiumBridge {
            chromiumBridge.applicationWillTerminate(notification)
        } else {
            AppLogWarn("[AppController] applicationWillTerminate: chromium bridge not cached; using launcher fallback")
            ChromiumLauncher.sharedInstance().bridge?.applicationWillTerminate(notification)
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogInfo("-----------------------------  Quitting: \(Self.makeClientString()) ------------------------------")
        // Note: on Cmd+Q this fires AFTER Chromium's window teardown; the restore
        // snapshot is frozen earlier, in phiWillTryToTerminateApplicationNotification.
        // Re-assert here as a backstop for any quit path that reaches this hook.
        SpaceManager.shared.markTerminating()
        // A bookmark-export write may still be running on a background queue
        // (slow network/cloud destination); dying now would silently drop a
        // save the user already confirmed. The write's completion handler
        // resumes termination via reply(toApplicationShouldTerminate:).
        if Self.inFlightBookmarkExportWrites > 0 {
            Self.bookmarkExportTerminationPending = true
            return .terminateLater
        }
        return .terminateNow
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window keeps the app alive, and the session data
        // behind that close is safe: Chromium defers every close in the
        // window group until SpaceManager reports the teardown settled
        // (windowGroupCloseDidSettle), so a title-bar close stores the same
        // session quitting does and a Dock reopen restores it.
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !ApplicationState.shared.canUseBrowser {
            if !ApplicationState.shared.isGuestMigrationRecoveryInProgress {
                LoginController.shared.showLoginWindow()
            }
            return true
        } else {
            // Only renew on reopen when the access token is actually close to
            // expiring. Calling `renewCredentials()` on every reopen turned a
            // routine UX gesture into a high-frequency RT-exchange trigger and
            // amplified ferrt risk on stale RTs (see Auth0 incident
            // 2026-04-22). The periodic renew timer still handles long-term
            // freshness; this gate just removes the redundant burst on reopen.
            if ApplicationState.shared.isAuthenticated,
               AuthManager.shared.shouldRenewOnReopen() {
                AuthManager.shared.renewCredentials()
            } else {
                AppLogDebug("reopen: Guest Mode or fresh access token, skipping renew")
            }
            // With no surviving browser window, spawn the persisted
            // last-active Space ourselves instead of letting Chromium's
            // reopen create the window: Chromium seeds it from its own
            // last-used-profile pref, which the window-close cascade
            // pollutes, and the coordinator then re-resolves the Space to
            // match that profile — reopening on the default Space instead
            // of the one the user closed. See
            // `SpaceManager.reopenOnPersistedSpaceIfWindowless`.
            if SpaceManager.shared.reopenOnPersistedSpaceIfWindowless() {
                return true
            }
            let handled = ChromiumLauncher.sharedInstance().bridge?.applicationShouldHandleReopen(sender, hasVisibleWindows: hasVisibleWindows) ?? false
            // Chromium's reopen surfaces every browser window it owns, which
            // un-hides the slots' hidden sibling Space windows. Re-assert the
            // one-visible-window-per-slot invariant so only the active Space
            // stays on screen.
            SpaceManager.shared.reconcileSlotVisibilityAfterReopen()
            return handled
        }
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard ApplicationState.shared.canUseBrowser else {
            return nil
        }
        let menu = ChromiumLauncher.sharedInstance().bridge?.applicationDockMenu(sender)
        return menu
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AuthManager.shared.resumeExternalBrowserAuthentication(with: url) {
            return
        }

        if !ApplicationState.shared.canUseBrowser {
            pendingOpenURLsAwaitingBrowserAccess.append(contentsOf: urls)
            if !ApplicationState.shared.isGuestMigrationRecoveryInProgress {
                LoginController.shared.showLoginWindow()
            }
        } else {
            if let url = urls.first, DeeplinkHandler.handle(url) {
                return
            }
            scheduleForwardOpenURLsToChromium(application: application, urls: urls)
        }
    }

    /// Forwards `application(_:open:)` URLs to Chromium once the app can
    /// honor Space URL rules for them: a browser window is registered (so
    /// `PhiOpenUrlsInBrowser` doesn't call `Browser::Create` against a
    /// mid-restore session) AND the initial rule snapshot has been pushed to
    /// Chromium's routing table (forwarding earlier would resolve the URL
    /// against an empty table and open it unrouted in the last-active
    /// window). Cold launch retries in `coldOpenURLForwardDelay` steps up to
    /// `coldOpenURLForwardMaxAttempts`, then forwards anyway.
    private func scheduleForwardOpenURLsToChromium(application: NSApplication, urls: [URL]) {
        // No window but a restorable history and the switch is on: bring the
        // previous session back first so the link lands as a new tab in the
        // restored active window instead of a bare new one. The queue below
        // then forwards once a (restored) window exists. A no-op otherwise.
        SpaceManager.shared.beginSessionRestoreForExternalOpenIfEligible()

        if isReadyToForwardOpenURLs {
            let urlsToForward = pendingColdOpenForwardURLs + urls
            pendingColdOpenForwardURLs.removeAll()
            coldOpenURLForwardWorkItem?.cancel()
            coldOpenURLForwardWorkItem = nil
            coldOpenURLForwardAttempts = 0
            forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "immediate")
            return
        }

        pendingColdOpenForwardURLs.append(contentsOf: urls)
        scheduleColdOpenForwardRetry(application: application)
    }

    private var isReadyToForwardOpenURLs: Bool {
        MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() != nil
            && SpaceManager.shared.hasLoadedURLRules
    }

    private func scheduleColdOpenForwardRetry(application: NSApplication) {
        guard coldOpenURLForwardWorkItem == nil else {
            AppLogDebug("[coldopen] urls appended to pending bridge forward queue")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coldOpenURLForwardWorkItem = nil
            self.coldOpenURLForwardAttempts += 1
            if !self.isReadyToForwardOpenURLs,
               self.coldOpenURLForwardAttempts < Self.coldOpenURLForwardMaxAttempts {
                self.scheduleColdOpenForwardRetry(application: application)
                return
            }
            let label = self.isReadyToForwardOpenURLs ? "deferred" : "deferred-timeout"
            let urlsToForward = self.pendingColdOpenForwardURLs
            self.pendingColdOpenForwardURLs.removeAll()
            self.coldOpenURLForwardAttempts = 0
            self.forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: label)
        }
        coldOpenURLForwardWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldOpenURLForwardDelay, execute: work)
        AppLogDebug("[coldopen] urls call bridge scheduled in \(Self.coldOpenURLForwardDelay)s (attempt \(coldOpenURLForwardAttempts + 1)/\(Self.coldOpenURLForwardMaxAttempts))")
    }

    private func forwardOpenURLsToChromium(application: NSApplication, urls: [URL], label: String) {
        AppLogDebug("[coldopen] urls call bridge (\(label))")
        ChromiumLauncher.sharedInstance().bridge?.application(application, open: urls)
    }
    
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, willContinueUserActivityWithType: userActivityType) ?? false
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, continue: userActivity, restorationHandler: restorationHandler) ?? false
    }
    
    @MainActor
    @objc func phiWillTryToTerminateApplicationNotification(_ notification: Notification) {
        // Posted (synchronously, main thread) by phi_app_controller_mac.mm's
        // -tryToTerminateApplication: BEFORE chrome::CloseAllBrowsers() tears the
        // windows down. This is the only quit signal that fires ahead of that
        // teardown cascade (the AppKit applicationWillTerminate hook runs after
        // it). Freeze the restore snapshot here so the closing windows can't
        // drain it — the next launch then regroups restored windows into their
        // slots and re-enters fullscreen.
        SpaceManager.shared.markTerminating()
    }

    @objc private func loginStatusRefreshCompleted(_ notification: Notification) {
        resolveBrowserAccessFromAuthentication(checkChromiumLaunchStatus: false)
        Task { @MainActor in
            self.flushPendingOpenURLsAwaitingBrowserAccess()
        }
    }

    @objc private func loginCompleted(_ notification: Notification) {
        if LoginController.shared.isLoggedin() {
            ApplicationState.shared.markSignedIn()
        } else {
            resolveBrowserAccessFromAuthentication(checkChromiumLaunchStatus: false)
        }
        Task { @MainActor in
            self.flushPendingOpenURLsAwaitingBrowserAccess()
        }
    }

    @objc private func browserAccessStateDidChange(_ notification: Notification) {
        Task { @MainActor in
            AuthenticatedSentinelSessionLifecycle.reconcile()
            guard ApplicationState.shared.canUseBrowser,
                  !ApplicationState.shared
                    .isGuestAccountPromotionInProgress else {
                return
            }

            self.flushPendingOpenURLsAwaitingBrowserAccess()
            ChromiumLauncher.sharedInstance().bridge?.notifyRebuildMenuAfterLogin()

            // Guest entry can happen before Chromium has created a dangling
            // window. Ask Chromium to create/reopen one only when neither a
            // live nor a dangling browser already exists.
            if MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() == nil {
                ChromiumLauncher.sharedInstance().bridge?
                    .applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            }
        }
    }

    @objc private func mainAccountChanged(_ notification: Notification) {
        resolveBrowserAccessFromAuthentication(checkChromiumLaunchStatus: false)
    }

    private func bindChromiumBridgeIfNeeded() {
        if chromiumBridge == nil {
            chromiumBridge = ChromiumLauncher.sharedInstance().bridge
        }
    }

    @MainActor
    private func flushPendingOpenURLsAwaitingBrowserAccess() {
        guard !pendingOpenURLsAwaitingBrowserAccess.isEmpty else {
            return
        }

        guard ApplicationState.shared.canUseBrowser else {
            return
        }

        let urls = pendingOpenURLsAwaitingBrowserAccess
        pendingOpenURLsAwaitingBrowserAccess.removeAll()
        if let url = urls.first, DeeplinkHandler.handle(url) {
            return
        }
        scheduleForwardOpenURLsToChromium(application: NSApp, urls: urls)
    }

    private func resolveBrowserAccessFromAuthentication(
        checkChromiumLaunchStatus: Bool
    ) {
        // A persisted Guest choice deliberately outranks credentials that were
        // staged but never committed. LoginController performs the one
        // identity-bound recovery when a migration journal exists; ordinary
        // browser-access probes must not revive that session.
        let isPersistedGuest = ApplicationState.shared.isGuest
        let isAuthenticated: Bool
        if isPersistedGuest {
            isAuthenticated = false
        } else {
            isAuthenticated = checkChromiumLaunchStatus
                ? AuthManager.shared.checkLoginStatusOnChromiumLaunch()
                : LoginController.shared.isLoggedin()
        }
        ApplicationState.shared.resolveInitialAccess(
            isAuthenticationBlocked: AuthManager.shared.isAccountDeletionInProgress,
            hasRecoverableLoginSession: isPersistedGuest
                ? false
                : AuthManager.shared.hasRecoverableLoginSession(),
            isAuthenticated: isAuthenticated
        )
    }
}

extension AppController {
    static var clientString: String?
    static func makeClientString() -> String {
        if clientString != nil { return clientString! }

        let preferredLang: String = {
            if let id = Locale.preferredLanguages.first, let lang = id.split(separator: "-").first {
                return String(lang)
            }
            return Locale.current.language.languageCode?.identifier ?? "en"
        }()

        let country = (Locale.current as NSLocale).object(forKey: .countryCode) as? String ?? "US"
        let localeStr = "\(preferredLang)-\(country)"

        let info = Bundle.main.infoDictionary ?? [:]
        let buildVersion = info["CFBundleVersion"] as? String ?? "0"
        let marketingVersion = info["CFBundleShortVersionString"] as? String ?? "0"

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let marketingWithChannel = marketingVersion

        let name = "Phi /\(buildVersion) \(marketingWithChannel) (\(localeStr)); MacOS/\(osVersion);"
        clientString = name
        return name
    }
}

extension AppController {
    private func setupKinfisherCache() {
        FaviconDataProvider.setupCache()
    }
}

extension AppController: ASWebAuthenticationSessionWebBrowserSessionHandling {
    func begin(_ request: ASWebAuthenticationSessionRequest!) {
        ChromiumLauncher.sharedInstance().bridge?.beginHandling(request)
    }
    
    func cancel(_ request: ASWebAuthenticationSessionRequest!)  {
        ChromiumLauncher.sharedInstance().bridge?.cancel(request)
    }
}
