// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Auth0

extension NSNotification.Name {
    static let loginCompleted = NSNotification.Name("LoginCompleted")
}

class OnboardingWindowController: NSWindowController {
    private lazy var loginViewController: LoginViewController = {
        let vc = LoginViewController()
        vc.onLoginSuccess = { [weak self] credentials in
            guard let credentials, let self else { return }
            self.routeToCurrentPhase(using: credentials)
        }
        return vc
    }()
    
    private lazy var welcomeViewController: OnboardingWelcomeViewController = {
        let vc = OnboardingWelcomeViewController()
        vc.nextClosure = { [weak self] _ in
            guard let self else { return }
            LoginController.shared.phase = .layoutSelection
            ChromiumLauncher.sharedInstance().bridge?.notifyLoginCompleted()
            setContent(layoutSelectionViewController)
        }
        return vc
    }()

    private lazy var layoutSelectionViewController: LayoutSelectionViewController = {
        let vc = LayoutSelectionViewController()
        vc.nextClosure = { [weak self] next in
            guard let self else { return }
            if next {
                LoginController.shared.phase = .importData
                setContent(importViewController)
            } else {
                self.showPasswordManagerPage()
            }
        }
        return vc
    }()

    private lazy var importViewController: ImportFromOtherBrowserViewController = {
        let vc = ImportFromOtherBrowserViewController()
        vc.onBrowserSelected = { [weak self] browser, chromeDir in
            guard let self else { return }
            self.showDataTypePage(for: browser, chromeProfileDir: chromeDir)
        }
        vc.onCompletion = { [weak self] in
            guard let self else { return }
            self.showPasswordManagerPage()
        }
        vc.nextClosure = { [weak self] next in
            guard let self else { return }
            if !next {
                self.showPasswordManagerPage()
            }
        }
        return vc
    }()

    private lazy var passwordManagerViewController: PasswordManagerViewController = {
        let vc = PasswordManagerViewController()
        vc.nextClosure = { [weak self] _ in
            guard let self else { return }
            self.finish()
        }
        return vc
    }()

    private lazy var setNameViewController: SetNameViewController = {
        let vc = SetNameViewController()
        vc.newNameSettled = { [weak self] name in
            guard let self else { return }
            LoginController.shared.phase = .setTheme
            welcomeViewController.userName = name
            setContent(welcomeViewController)
        }
        return vc
    }()
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.animationBehavior = .default

        
        self.init(window: window)        
        setupContentViewController()
    }

    private func setupContentViewController() {
        let contentVc: NSViewController = {
            if let credentials = AuthManager.shared.currentCredentials {
                LoginController.shared.initAccountIfNeeded(credentials)
                let loginPhase = LoginController.shared.phase
                guard loginPhase != .done else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finish()
                    }
                    return loginViewController
                }
                return viewController(for: loginPhase, credentials: credentials, isFirstPage: true)
            } else {
                return loginViewController
            }
        }()
        contentViewController = contentVc
    }
    
    // MARK: - Import Data Type Flow

    private var dataTypeVCs: [BrowserType: ImportDataTypeViewController] = [:]
    private var chromeProfileDirectories: [BrowserType: String] = [:]

    private func showDataTypePage(for browser: BrowserType, chromeProfileDir: String?) {
        // If Chrome profile changed, discard previous data type VC
        if browser == .chrome,
           let oldDir = chromeProfileDirectories[.chrome],
           oldDir != chromeProfileDir {
            dataTypeVCs.removeValue(forKey: browser)
        }

        if let dir = chromeProfileDir {
            chromeProfileDirectories[browser] = dir
        }

        let vc = dataTypeVC(for: browser)
        setContent(vc)
    }

    private func dataTypeVC(for browser: BrowserType) -> ImportDataTypeViewController {
        if let existing = dataTypeVCs[browser] {
            return existing
        }

        let vc = ImportDataTypeViewController(browserType: browser)

        vc.onReturn = { [weak self] hasSelection in
            guard let self else { return }
            if hasSelection {
                self.importViewController.markBrowserConfigured(browser)
            } else {
                self.importViewController.unmarkBrowserConfigured(browser)
                self.dataTypeVCs.removeValue(forKey: browser)
            }
            self.updateDataTypesOnImportVC()
            self.setContent(self.importViewController)
        }

        dataTypeVCs[browser] = vc
        return vc
    }

    private func updateDataTypesOnImportVC() {
        var dataTypesPerBrowser: [BrowserType: [String]] = [:]
        for (browser, vc) in dataTypeVCs {
            dataTypesPerBrowser[browser] = vc.selectedDataTypeStrings()
        }
        importViewController.dataTypesPerBrowser = dataTypesPerBrowser.isEmpty ? nil : dataTypesPerBrowser
    }

    // MARK: - Content Management

    private func setContent(_ vc: NSViewController) {
        window?.contentViewController = vc
    }
    
    private func routeToCurrentPhase(using credentials: Credentials) {
        let loginPhase = LoginController.shared.phase
        guard loginPhase != .done else {
            finish()
            return
        }

        setContent(viewController(for: loginPhase, credentials: credentials, isFirstPage: false))
    }

    private func viewController(for phase: LoginController.Phase, credentials: Credentials, isFirstPage: Bool) -> NSViewController {
        setNameViewController.isFisrtPage = false
        importViewController.isFisrtPage = false
        passwordManagerViewController.isFisrtPage = false

        switch phase {
        case .login:
            return loginViewController
        case .setName:
            setNameViewController.credentials = credentials
            setNameViewController.isFisrtPage = isFirstPage
            return setNameViewController
        case .setTheme:
            let user = AuthManager.retriveUserInfo(from: credentials)
            welcomeViewController.userName = user.name
            return welcomeViewController
        case .layoutSelection:
            return layoutSelectionViewController
        case .importData:
            importViewController.isFisrtPage = isFirstPage
            return importViewController
        case .passwordManager:
            passwordManagerViewController.isFisrtPage = isFirstPage
            return passwordManagerViewController
        case .done:
            return loginViewController
        }
    }

    private func showPasswordManagerPage() {
        LoginController.shared.phase = .passwordManager
        setContent(passwordManagerViewController)
    }

    private func finish() {
        LoginController.shared.phase = .done
        close()
        
        if MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() == nil {
            ChromiumLauncher.sharedInstance().bridge?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        } else {
            ChromiumLauncher.sharedInstance().bridge?.notifyRebuildMenuAfterLogin()
            NotificationCenter.default.post(name: .loginCompleted, object: nil)
        }
    }
}
