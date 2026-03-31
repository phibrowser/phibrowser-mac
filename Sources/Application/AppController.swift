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
import Countly

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
        if let account = AccountController.shared.account {
            SentryService.configureUser(account)
        }
        
        DefaultExtensionManifestWriter.start()
        
        BrowserRestoreManager.shared.startObserving()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(phiWillTryToTerminateApplicationNotification(_:)),
                                               name: Notification.Name("PhiWillTryToTerminateApplicationNotification"),
                                               object: nil)
        
        if PhiPreferences.AISettings.launchSentinelOnLogin.loadValue() {
            SentinelHelper.register()
        }
        if PhiPreferences.AISettings.phiAIEnabled.loadValue() {
            SentinelHelper.launch()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Register defaults before any settings are read.
        UserDefaultsRegistration.registerDefaults()
        
        setupLogging()
        AppLogInfo("------------------------------  Starting: \(Self.makeClientString())  ------------------------------")
        recordLaunchVersion()
        ChromiumLauncher.sharedInstance().bridge?.applicationWillFinishLaunching(notification)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AppLogInfo("-------applicationWillTerminate----")
        ChromiumLauncher.sharedInstance().bridge?.applicationWillTerminate(notification)
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
            AuthManager.shared.renewCredentials()
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
            LoginController.shared.showLoginWindow()
        } else {
            if let url = urls.first, DeeplinkHandler.handle(url) {
                return
            }
            ChromiumLauncher.sharedInstance().bridge?.application(application, open: urls)
        }
    }
    
    func application(_ application: NSApplication, willContinueUserActivityWithType userActivityType: String) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, willContinueUserActivityWithType: userActivityType) ?? false
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        return ChromiumLauncher.sharedInstance().bridge?.application(application, continue: userActivity, restorationHandler: restorationHandler) ?? false
    }
    
    @MainActor
    @objc func phiWillTryToTerminateApplicationNotification(_ notification: Notification) {
        BrowserRestoreManager.shared.saveSnapshotIfNeeded()
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
