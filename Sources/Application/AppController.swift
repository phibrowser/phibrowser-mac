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
    
    var container: ModelContainer?
    var updaterController: SPUStandardUpdaterController?
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
    private var coldOpenURLForwardWorkItem: DispatchWorkItem?
    private var pendingColdOpenForwardURLs: [URL] = []
    private var pendingOpenURLsAwaitingLoginStatus: [URL] = []
    /// Cached in `applicationWillFinishLaunching`; weak — owned by `ChromiumLauncher`, not AppController.
    private weak var chromiumBridge: (any PhiChromiumBridgeProtocol)?

    override init() {
        super.init()
        Self.shared = self
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Chromium may query login state before launch completes, so refresh it first.
        LoginController.shared.refreshLoginStatusOnLaunching()
        
        //        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self
        
        ChromiumLauncher.sharedInstance().bridge?.applicationDidFinishLaunching(notification)
        
        //        ASWebAuthenticationSessionWebBrowserSessionManager.shared.sessionHandler = self
        
        setupSparkle()
        setupKinfisherCache()
        
        SentryService.setup()
        
        MemoryUsageMonitor.shared.start()
        
        DefaultExtensionManifestWriter.start()
        FeedbackOutboxUploader.shared.start()
        
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
        
        if PhiPreferences.AISettings.launchSentinelOnLogin.loadValue() {
            SentinelHelper.register()
        }
        if PhiPreferences.AISettings.phiAIEnabled.loadValue() {
            SentinelHelper.launch()
        }
        Task.detached(priority: .utility) {
            await SentinelVersionGuard.shared.runStartupCheck()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        bindChromiumBridgeIfNeeded()

        // Register defaults before any settings are read.
        UserDefaultsRegistration.registerDefaults()
        
        setupLogging()
        // Wire the shared keychain store into AppLog so its keychain errors and
        // retry recoveries land in the same log file as the rest of the app.
        // Must happen before any auth flow (login / renew / launch recovery)
        // touches `SharedAuthTokenStore`.
        SharedAuthTokenStore.shared.logDelegate = SharedAuthTokenStoreLogBridge.shared
        AppLogInfo("------------------------------  Starting: \(Self.makeClientString())  ------------------------------")
        recordLaunchVersion()

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
                guard event.event == "$app_opened" else { return event }
                event.properties["layout_mode"] = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue
                event.properties["ai_enabled"] = PhiPreferences.AISettings.phiAIEnabled.loadValue()
                return event
            }
            PostHogSDK.shared.setup(postHogConfig)
        } else {
            AppLogInfo("PostHog: project token or host not set in PostHogConfig.generated.swift; skipping init")
        }

        chromiumBridge?.applicationWillFinishLaunching(notification)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        coldOpenURLForwardWorkItem?.cancel()
        coldOpenURLForwardWorkItem = nil
        AppLogInfo("-------applicationWillTerminate----")
        MemoryUsageMonitor.shared.stop()
        if let chromiumBridge {
            chromiumBridge.applicationWillTerminate(notification)
        } else {
            AppLogWarn("[AppController] applicationWillTerminate: chromium bridge not cached; using launcher fallback")
            ChromiumLauncher.sharedInstance().bridge?.applicationWillTerminate(notification)
        }
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogInfo("-----------------------------  Quitting: \(Self.makeClientString()) ------------------------------")
        return .terminateNow
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // FIXME: Closing the final window via the title-bar button can bypass Chromium's tab-close
        // notifications. We likely need a more explicit cleanup and restore strategy here.
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if LoginController.shared.orderFrontLoginWindowIfNeeded() {
            LoginController.shared.showLoginWindow()
            return true
        } else {
            // Only renew on reopen when the access token is actually close to
            // expiring. Calling `renewCredentials()` on every reopen turned a
            // routine UX gesture into a high-frequency RT-exchange trigger and
            // amplified ferrt risk on stale RTs (see Auth0 incident
            // 2026-04-22). The periodic renew timer still handles long-term
            // freshness; this gate just removes the redundant burst on reopen.
            if AuthManager.shared.shouldRenewOnReopen() {
                AuthManager.shared.renewCredentials()
            } else {
                AppLogDebug("reopen: access token still fresh, skipping renew")
            }
            return ChromiumLauncher.sharedInstance().bridge?.applicationShouldHandleReopen(sender, hasVisibleWindows: hasVisibleWindows) ?? false
        }
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard LoginController.shared.isLoggedin() else {
            return nil
        }
        let menu = ChromiumLauncher.sharedInstance().bridge?.applicationDockMenu(sender)
        return menu
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where AuthManager.shared.resumeExternalBrowserAuthentication(with: url) {
            return
        }

        if LoginController.shared.orderFrontLoginWindowIfNeeded() {
            if AuthManager.shared.hasRecoverableLoginSession() {
                pendingOpenURLsAwaitingLoginStatus.append(contentsOf: urls)
            }
            LoginController.shared.showLoginWindow()
        } else {
            if let url = urls.first, DeeplinkHandler.handle(url) {
                return
            }
            scheduleForwardOpenURLsToChromium(application: application, urls: urls)
        }
    }

    /// Forwards `application(_:open:)` URLs to Chromium. Cold launch defers ~600ms so
    /// `StartupBrowserCreator` / session restore can register a browser before
    /// `PhiOpenUrlsInBrowser` would otherwise call `Browser::Create` again.
    private func scheduleForwardOpenURLsToChromium(application: NSApplication, urls: [URL]) {
        let manager = MainBrowserWindowControllersManager.shared
        if manager.getFirstAvailableWindowId() != nil {
            let urlsToForward = pendingColdOpenForwardURLs + urls
            pendingColdOpenForwardURLs.removeAll()
            coldOpenURLForwardWorkItem?.cancel()
            coldOpenURLForwardWorkItem = nil
            forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "immediate")
            return
        }

        pendingColdOpenForwardURLs.append(contentsOf: urls)
        guard coldOpenURLForwardWorkItem == nil else {
            AppLogDebug("[coldopen] urls appended to pending bridge forward queue")
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coldOpenURLForwardWorkItem = nil
            let urlsToForward = self.pendingColdOpenForwardURLs
            self.pendingColdOpenForwardURLs.removeAll()
            self.forwardOpenURLsToChromium(application: application, urls: urlsToForward, label: "deferred-600ms")
        }
        coldOpenURLForwardWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldOpenURLForwardDelay, execute: work)
        AppLogDebug("[coldopen] urls call bridge scheduled in \(Self.coldOpenURLForwardDelay)s")
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
    }

    @objc private func loginStatusRefreshCompleted(_ notification: Notification) {
        Task { @MainActor in
            self.flushPendingOpenURLsAwaitingLoginStatus()
        }
    }

    @objc private func loginCompleted(_ notification: Notification) {
        Task { @MainActor in
            self.flushPendingOpenURLsAwaitingLoginStatus()
        }
    }

    private func bindChromiumBridgeIfNeeded() {
        if chromiumBridge == nil {
            chromiumBridge = ChromiumLauncher.sharedInstance().bridge
        }
    }

    @MainActor
    private func flushPendingOpenURLsAwaitingLoginStatus() {
        guard !pendingOpenURLsAwaitingLoginStatus.isEmpty else {
            return
        }

        guard AuthManager.shared.hasRecoverableLoginSession() else {
            pendingOpenURLsAwaitingLoginStatus.removeAll()
            return
        }

        guard !LoginController.shared.orderFrontLoginWindowIfNeeded() else {
            return
        }

        let urls = pendingOpenURLsAwaitingLoginStatus
        pendingOpenURLsAwaitingLoginStatus.removeAll()
        if let url = urls.first, DeeplinkHandler.handle(url) {
            return
        }
        scheduleForwardOpenURLsToChromium(application: NSApp, urls: urls)
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
