// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import SwiftUI
import Auth0
import WebKit
class LoginController {
    enum Phase: Int {
        case login = 0
        case setName
        case setTheme
        case importData
        case layoutSelection
        case passwordManager
        case done
    }

    private let appPhaseKey = PhiPreferences.phiLoginPhase.rawValue
    private let accountPhaseKey = AccountUserDefaults.DefaultsKey.loginPhase.rawValue
    
    var phase: Phase {
        set {
            if newValue == .login {
                appPhase = .login
                return
            }

            appPhase = .done
            currentAccount()?.userDefaults.set(newValue.rawValue, forKey: accountPhaseKey)
        }
        get {
            if appPhase == .login {
                if let account = currentAccount() {
                    return accountPhase(for: account)
                }
                return .login
            }

            guard let account = currentAccount() else {
                return .login
            }

            return accountPhase(for: account)
        }
    }

    static let shared = LoginController()
    let auth0Manager = AuthManager.shared
    private(set) var acctiveAccount: Account?
    var loginWindowController: OnboardingWindowController?
    private var closeObserver: NSObjectProtocol?
    
    private init() {}
    
    deinit {
        if let closeObserver = closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
    
    @MainActor
    func showLoginWindow() {
        AppLogDebug("🔐 [Login] showLoginWindow called")

        if loginWindowController == nil {
            loginWindowController = OnboardingWindowController()
            AppLogDebug("🔐 [Login] Creating new LoginWindowController")
        } else {
            AppLogDebug("🔐 [Login] Reusing existing LoginWindowController")
        }

        loginWindowController?.window?.makeKeyAndOrderFront(nil)
        loginWindowController?.window?.center()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: loginWindowController?.window, queue: nil) { [weak self] _ in
            AppLogDebug("🔐 [Login] Login window will close notification received")
            self?.auth0Manager.cancelOngoingWebAuthentication()
            self?.loginWindowController = nil
        }
        AppLogDebug("🔐 [Login] Login window displayed")
    }


    /// Returns `true` when onboarding still needs to be shown.
    @MainActor
    func orderFrontLoginWindowIfNeeded() -> Bool {
        guard auth0Manager.hasRecoverableLoginSession() else {
            return true
        }

        return phase != .done
    }
    
    func isLoggedin() -> Bool {
        guard auth0Manager.hasRecoverableLoginSession() else {
            return false
        }

        return phase == .done
    }
    
    func refreshLoginStatusOnLaunching() {
        Task {
            await AuthManager.shared.refreshAuthStatus()
            if let credentials = auth0Manager.currentCredentials {
                initAccountIfNeeded(credentials)
            }
        }
    }
    
    func initAccountIfNeeded(_ credentials: Credentials) {
        AppLogDebug("🔐 [Login] initAccountIfNeeded called")
        let user = AuthManager.retriveUserInfo(from: credentials)
        let userID = user.sub ?? Account.defaultUid
        AppLogDebug("🔐 [Login] Retrieved user info - userID: \(userID), name: \(user.name ?? "nil"), email: \(user.email ?? "nil")")

        if let current = AccountController.shared.account {
            AppLogDebug("🔐 [Login] Current account exists: \(current.userID)")
            if current.userID == userID {
                return
            }
            AppLogDebug("🔐 [Login] Different user, replacing account")
        } else {
            AppLogDebug("🔐 [Login] No current account, creating new one")
        }
        
        AccountController.shared.account = Account(userID: userID, userInfo: user)
        if appPhase == .login {
            appPhase = .done
        }
        _ = currentAccount().map(accountPhase(for:))
        AppLogInfo("🔐 [Login] Account created and set for user: \(userID)")
    }

    
    func initAcoountWithUserInfo(_ userInfo: UserInfo) {
        if let current = AccountController.shared.account,
           current.userID == userInfo.sub {
            return
        } else {
            AccountController.shared.account = Account(userID: userInfo.sub, userInfo: .init(userInfo))
            if appPhase == .login {
                appPhase = .done
            }
            _ = currentAccount().map(accountPhase(for:))
        }
    }
    
    @MainActor
    func closeLoginWindow() {
        loginWindowController?.window?.close()
        loginWindowController = nil
    }
    
    @MainActor
    func loginWithAuth0(with window: NSWindow? = nil, onWebViewCreated: ((WKWebView) -> Void)? = nil) async -> Credentials? {
        AppLogDebug("🔐 [Login] Logging in with default flow")
        let result = await auth0Manager.login()
        switch result {
        case .success(let credentials):
            return await MainActor.run {
                initAccountIfNeeded(credentials)
                return credentials
            }
        case .failure(let error):
            AppLogError("🔐 [Login] ❌ Login failed: \(error.localizedDescription)")
        }
        return nil
    }

    private var appPhase: Phase {
        get {
            let rawValue = UserDefaults.standard.integer(forKey: appPhaseKey)
            return rawValue == Phase.login.rawValue ? .login : .done
        }
        set {
            let rawValue = newValue == .login ? Phase.login.rawValue : Phase.done.rawValue
            UserDefaults.standard.set(rawValue, forKey: appPhaseKey)
        }
    }

    private func currentAccount() -> Account? {
        if let account = AccountController.shared.account {
            return account
        }

        if auth0Manager.hasRecoverableLoginSession(),
           let credentials = auth0Manager.getActiveCredentialsSyncly() {
            initAccountIfNeeded(credentials)
            return AccountController.shared.account
        }

        return nil
    }

    private func accountPhase(for account: Account) -> Phase {
        if let storedPhase = storedAccountPhase(for: account) {
            return storedPhase
        }

        account.userDefaults.set(Phase.setName.rawValue, forKey: accountPhaseKey)
        return .setName
    }

    private func storedAccountPhase(for account: Account) -> Phase? {
        guard account.userDefaults.object(forKey: accountPhaseKey) != nil else {
            return nil
        }

        let rawValue = account.userDefaults.integer(forKey: accountPhaseKey)
        return Phase(rawValue: rawValue)
    }
}
