// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation
import Kingfisher
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
    private var activatedAuthenticatedAccount: Account?
    private var browserAccessObserver: NSObjectProtocol?

    private init() {
        browserAccessObserver = NotificationCenter.default.addObserver(
            forName: .browserAccessStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.activateAuthenticatedAccountIfNeeded()
        }
    }

    deinit {
        if let browserAccessObserver {
            NotificationCenter.default.removeObserver(browserAccessObserver)
        }
    }

    /// The account whose Native local data is available to browser UI.
    ///
    /// `account` remains a real Phi identity only. Guest Mode deliberately
    /// routes local Spaces, bookmarks, and pinned tabs through the stable
    /// default account without publishing it as the signed-in account.
    var localDataAccount: Account? {
        guard ApplicationState.shared.canUseBrowser else { return nil }

        switch ApplicationState.shared.browserAccessState {
        case .loginRequired:
            return nil
        case .guest:
            if ApplicationState.shared.isGuestAccountPromotionInProgress,
               let account {
                return account
            }
            return Self.defaultAccount
        case .signedIn:
            return account
        }
    }

    var account: Account? {
        didSet {
            if account == nil {
                activatedAuthenticatedAccount = nil
                syncTelemetryIdentity(for: nil)
            }
            NotificationCenter.default.post(name: .mainAccountChanged, object: account)
            /// FIXME: Chromium builds the main menu before the account exists, but shortcut overrides
            /// are account-scoped. Reloading here works, but this probably deserves a cleaner hook.
            Shortcuts.reloadOverrides()
            activateAuthenticatedAccountIfNeeded()
            AppLogInfo("account controller created: \(String(describing: account?.userID))")
        }
    }

    /// Publishes identity-bound side effects only after the Guest promotion
    /// fence has committed. The account object may exist earlier so Native
    /// browser controllers can bind to its migrated local data, but telemetry
    /// and account API prefetch must remain anonymous until then.
    func activateAuthenticatedAccountIfNeeded() {
        guard ApplicationState.shared.isAuthenticated,
              let account,
              activatedAuthenticatedAccount !== account else {
            return
        }
        activatedAuthenticatedAccount = account
        syncTelemetryIdentity(for: account)
        prefetchProfile(for: account)
    }

    private func syncTelemetryIdentity(for account: Account?) {
        #if !PHI_OSS_BUILD
        SentryService.configureUser(account)

        guard let bridge = ChromiumLauncher.sharedInstance().bridge,
              bridge.isMetricsReportingEnabled(),
              let sub = account?.userInfo?.sub else {
            PostHogSDK.shared.reset()
            return
        }

        let properties = bridge.getMetricsClientId().map {
            ["chromium_metrics_client_id": $0] as [String: Any]
        }
        PostHogSDK.shared.identify(sub, userProperties: properties)
        #endif
    }

    /// Best-effort refresh of the existing per-account profile cache. The
    /// conditional write preserves a newer profile saved while this GET was
    /// in flight, notably the SetName PUT response during onboarding.
    private func prefetchProfile(for account: Account?) {
        guard let account else { return }
        let key = AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
        let cachedDataAtStart = account.userDefaults.data(forKey: key)
        var cachedProfile: Profile? = account.userDefaults.codableValue(forKey: key)
        if cachedProfile?.auth0_id != account.userID {
            cachedProfile = nil
        }

        // Warm the avatar store from Kingfisher's disk cache right away:
        // the GET below (and the forced refetch after it) can be slow or
        // fail offline, while the Chromium settings bridge may query at
        // any moment. The network refresh overwrites this with fresher
        // bytes once it lands.
        if let picture = cachedProfile?.picture, let url = URL(string: picture) {
            // Hop before reading the generation so the capture happens
            // on the main thread alongside every other generation access.
            DispatchQueue.main.async {
                self.warmAvatarFromCache(url: url, for: account, generation: self.avatarGeneration)
            }
        }

        Task {
            guard let response = try? await APIClient.shared.getAccountProfile(),
                  response.code == 0,
                  self.account === account,
                  response.data.auth0_id == account.userID else {
                // The GET failed (or raced an account switch). If the cached
                // profile still matches this account, refresh the avatar from
                // it so a reachable avatar host still yields fresh bytes.
                if self.account === account, let picture = cachedProfile?.picture {
                    refreshAvatar(for: account, pictureURLString: picture)
                }
                return
            }
            account.userDefaults.set(
                response.data,
                forCodableKey: key,
                ifCurrentDataEquals: cachedDataAtStart
            )
            refreshAvatar(for: account, pictureURLString: response.data.picture)
        }
    }

    /// Drops the locally cached account identity: the cached profile and
    /// name, the avatar (both the bytes served to the Chromium settings
    /// bridge and the Kingfisher entry they are re-warmed from), and the
    /// current account reference. Purely local — nothing here talks to the
    /// network, and the remote session is the caller's business.
    ///
    /// The account reference goes last: the cached profile lives in that
    /// account's defaults store, and the avatar entry is keyed by the URL
    /// that profile carries.
    @MainActor
    func clearCachedAccount() {
        if let account {
            let key = AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
            let cachedProfile: Profile? = account.userDefaults.codableValue(forKey: key)
            if let picture = cachedProfile?.picture, let url = URL(string: picture) {
                // Only this account's entries: Kingfisher's shared cache also
                // holds every favicon. Both variants have to go — the avatar is
                // fetched unprocessed here and rounded in the settings pane, and
                // the processor identifier is part of the cache key.
                let cache = KingfisherManager.shared.cache
                cache.removeImage(forKey: url.absoluteString)
                cache.removeImage(
                    forKey: url.absoluteString,
                    processorIdentifier: Self.avatarImageProcessor.identifier
                )
            }
            account.userDefaults.set(nil, forKey: .cachedProfile)
            account.userDefaults.set(nil, forKey: .cachedUserName)
        }
        avatarPNG = nil
        avatarPNGOwnerID = nil
        account = nil
    }

    // MARK: Avatar bytes for the Chromium settings bridge

    /// The processor the account settings pane renders avatars with. Owned here
    /// rather than at the view: Kingfisher folds the processor identifier into
    /// the cache key, so `clearCachedAccount()` can only evict the rounded
    /// variant if both sides agree on one processor.
    static let avatarImageProcessor = RoundCornerImageProcessor(radius: .widthFraction(0.5))

    /// In-memory PNG bytes of the current account's avatar, answered
    /// synchronously to the Chromium settings bridge. An owned copy by
    /// design: the account settings pane force-refreshes the Kingfisher
    /// cache, so that cache is not a stable source for the bridge. Owner
    /// tagged so bytes fetched for a previous account are never served
    /// after an account switch. Main-thread confined (Kingfisher completes
    /// on main; the bridge queries on the UI thread).
    private var avatarPNG: Data?
    private var avatarPNGOwnerID: String?
    /// Bumped on every editor-supplied save. The avatar URL is stable
    /// while its content changes (and Kingfisher attaches same-URL
    /// retrieves to an already in-flight download), so URL refreshes that
    /// started before a local save could otherwise land afterwards and
    /// overwrite the newer image; fetch results only commit when their
    /// starting generation is still current.
    private var avatarGeneration = 0

    /// The current account's avatar PNG bytes, or nil when none have been
    /// fetched yet or the stored bytes belong to a different account.
    func avatarPNG(for account: Account) -> Data? {
        guard avatarPNGOwnerID == account.userID else { return nil }
        return avatarPNG
    }

    /// Stores a locally supplied avatar image (the avatar editor's save
    /// payload) as the bridge answer for `account`.
    func storeAvatarImage(_ image: NSImage, for account: Account) {
        guard self.account === account, let png = image.pngData() else { return }
        avatarPNG = png
        avatarPNGOwnerID = account.userID
        avatarGeneration += 1
    }

    /// Stores fetched bytes unless a newer locally saved avatar landed
    /// while the fetch was in flight.
    private func storeFetchedAvatarImage(
        _ image: NSImage, for account: Account, generation: Int
    ) {
        guard avatarGeneration == generation,
              self.account === account,
              let png = image.pngData() else { return }
        avatarPNG = png
        avatarPNGOwnerID = account.userID
    }

    /// Fills the avatar store from Kingfisher's disk cache (no network).
    /// Hops to the main thread; the passed generation rides along
    /// untouched — refreshAvatar's failure fallback must keep its
    /// original capture, never re-read a fresher one.
    private func warmAvatarFromCache(url: URL, for account: Account, generation: Int) {
        DispatchQueue.main.async {
            KingfisherManager.shared.retrieveImage(with: url, options: [.onlyFromCache]) { cached in
                if case .success(let value) = cached {
                    self.storeFetchedAvatarImage(value.image, for: account, generation: generation)
                }
            }
        }
    }

    /// Fetches the avatar behind `pictureURLString` into the in-memory
    /// store. The URL is stable while its content changes, so the fetch
    /// bypasses the cache (same reason the account settings pane
    /// revalidates with .forceRefresh); on network failure it falls back
    /// to Kingfisher's disk cache so an offline launch still has bytes.
    func refreshAvatar(for account: Account, pictureURLString: String) {
        guard !pictureURLString.isEmpty, let url = URL(string: pictureURLString) else { return }
        // Callers may be off the main thread (prefetchProfile's Task);
        // hop before capturing the generation so the capture and the
        // eventual store are both main-confined.
        DispatchQueue.main.async {
            let generation = self.avatarGeneration
            KingfisherManager.shared.retrieveImage(with: url, options: [.forceRefresh]) { result in
                switch result {
                case .success(let value):
                    self.storeFetchedAvatarImage(value.image, for: account, generation: generation)
                case .failure:
                    self.warmAvatarFromCache(url: url, for: account, generation: generation)
                }
            }
        }
    }

    static var defaultAccount: Account = Account.defaultAccount
}

extension Notification.Name {
    static let mainAccountChanged = Notification.Name("mainAccountDidChange")
}
