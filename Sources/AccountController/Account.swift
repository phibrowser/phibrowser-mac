// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
class Account {
    let userID: String
    let userInfo: User?
    lazy var localStorage: LocalStore = { LocalStore(account: self) }()
    private(set) lazy var userDefaults: AccountUserDefaults = {
        AccountUserDefaults(account: self)
    }()
    
    init(userID: String, userInfo: User? = nil) {
        self.userID = userID
        self.userInfo = userInfo
        setupLogging()
        if let userInfo {
            EventTracker.updateUserProfile(userInfo)
        }
    }
    
    var userDataStorage: URL {
        let phiDataSupportURL = URL(filePath:  FileSystemUtils.phiBrowserDataDirectory())
        return phiDataSupportURL
            .appendingPathComponent("users")
            .appendingPathComponent(userID)
    }
}

extension Account {
    static let defaultUid = "default-account-id"
    static var defaultAccount: Account {
        return Account(userID: defaultUid)
    }
}

class AccountController {
    static let shared = AccountController()
    var account: Account? {
        didSet {
            NotificationCenter.default.post(name: .mainAccountChanged, object: account)
            /// FIXME: Chromium builds the main menu before the account exists, but shortcut overrides
            /// are account-scoped. Reloading here works, but this probably deserves a cleaner hook.
            Shortcuts.reloadOverrides()
            AppLogInfo("account controller created: \(String(describing: account?.userID))")
        }
    }
    
    static var defaultAccount: Account = Account.defaultAccount
}

extension Notification.Name {
    static let mainAccountChanged = Notification.Name("mainAccountDidChange")
}
