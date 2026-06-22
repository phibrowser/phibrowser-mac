// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import PostHog
class Account {
    let userID: String
    let userInfo: User?
    lazy var localStorage: LocalStore = {
        // Under UI testing the store is redirected to a throwaway per-launch
        // temp directory so tests never read or mutate the real account's
        // Spaces, bookmarks, or pinned tabs. See `uiTestStoreDirectoryURL`.
        if let testStoreURL = Account.uiTestStoreDirectoryURL {
            return LocalStore(account: self, storeDirectoryURL: testStoreURL)
        }
        return LocalStore(account: self)
    }()
    private(set) lazy var userDefaults: AccountUserDefaults = {
        AccountUserDefaults(account: self)
    }()
    
    init(userID: String, userInfo: User? = nil) {
        self.userID = userID
        self.userInfo = userInfo
        if let userInfo {
            EventTracker.updateUserProfile(userInfo)
            if let sub = userInfo.sub {
                PostHogSDK.shared.identify(sub)
            }
        }
        
        SentryService.configureUser(self)
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

    /// A unique-per-launch temp directory for the `LocalStore` when the app is
    /// launched for UI testing (`-uitest`); otherwise nil. Isolating the store
    /// keeps UI tests from reading or writing the real account's Spaces,
    /// bookmarks, and pinned tabs — the Chromium `--user-data-dir` does not
    /// cover this Swift-side, per-account store. Computed once per process.
    static let uiTestStoreDirectoryURL: URL? = {
        guard ProcessInfo.processInfo.arguments.contains("-uitest") else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(
                "PhiUITestStore-\(ProcessInfo.processInfo.globallyUniqueString)",
                isDirectory: true
            )
    }()
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
