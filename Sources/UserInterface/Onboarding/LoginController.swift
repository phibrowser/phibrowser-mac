// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Cocoa
import SwiftUI
import Auth0
import WebKit
import PostHog

extension Notification.Name {
    static let loginStatusRefreshCompleted = Notification.Name("LoginStatusRefreshCompleted")
}

struct PostLoginAIEnableIntent {
    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    mutating func cancel() {
        isPending = false
    }

    mutating func consume() -> Bool {
        defer { isPending = false }
        return isPending
    }

    @discardableResult
    mutating func enableAIIfRequested(
        defaults: UserDefaults = .standard,
        supportsAI: Bool = PhiBuildCapabilities.supportsAI
    ) -> Bool {
        guard consume() else { return false }
        guard supportsAI else {
            defaults.set(
                false,
                forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue
            )
            return false
        }

        defaults.set(
            true,
            forKey: PhiPreferences.AISettings.phiAIEnabled.rawValue
        )
        return true
    }
}

enum GuestModeEntryResult {
    case enteredGuestMode
    case requiresAccountRecovery
    case failed
}

class LoginController {
    /// Raw values are account-persisted. Values 0...2 and `done` stay stable;
    /// values 3...5 advance past the removed import step.
    enum Phase: Int {
        case login = 0
        case setName = 1
        case setTheme = 2
        case layoutSelection = 3
        case passwordManager = 4
        case nextStep = 5
        case done = 6
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
    private(set) var pendingAuthenticatedAccount: Account?
    var loginWindowController: OnboardingWindowController?
    private var closeObserver: NSObjectProtocol?
    private var guestMigrationRecoveryTargetUserID: String?
    private var requiresGuestMigrationTargetRecovery = false
    private var postLoginAIEnableIntent = PostLoginAIEnableIntent()
    private var preservesPostLoginAIEnableIntentOnClose = false
    @MainActor private var isCompletingAccountTransition = false

    @MainActor
    var requiresGuestMigrationRecoveryPresentation: Bool {
        ApplicationState.shared.isGuestMigrationRecoveryInProgress
            || requiresGuestMigrationTargetRecovery
    }

    private enum AccountActivationResult {
        case completed
        case guestMigrationFailed(Error)
        case guestMigrationRequiresTargetRecovery(Error)
        case completedWithDeferredGuestCleanup(Error)
    }
    
    private init() {}
    
    deinit {
        if let closeObserver = closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
    
    @MainActor
    func showLoginWindow() {
        guard PhiBuildCapabilities.supportsAuthentication else {
            ApplicationState.shared.enterGuestMode()
            GuestModePreferences.disableAI()
            return
        }

        AppLogDebug("🔐 [Login] showLoginWindow called")
        if enterGuestModeInsteadOfOnboardingIfRequested() {
            return
        }

        let presentsGuestMigrationRecovery =
            requiresGuestMigrationRecoveryPresentation
        if let loginWindowController,
           loginWindowController.presentsGuestMigrationRecovery
                != presentsGuestMigrationRecovery {
            closeLoginWindow(preservingPostLoginAIEnableIntent: true)
        }

        if loginWindowController == nil {
            loginWindowController = OnboardingWindowController(
                presentsGuestMigrationRecovery:
                    presentsGuestMigrationRecovery
            )
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
            if self?.preservesPostLoginAIEnableIntentOnClose != true {
                self?.postLoginAIEnableIntent.cancel()
            }
        }
        AppLogDebug("🔐 [Login] Login window displayed")
    }

    @MainActor
    func showLoginWindowToEnableAI() {
        guard PhiBuildCapabilities.supportsAI else {
            GuestModePreferences.disableAI()
            return
        }
        postLoginAIEnableIntent.request()
        showLoginWindow()
    }

    /// Installs the crash-recovery gate before Chromium starts creating
    /// browser windows. A pending journal may describe a Guest directory that
    /// has already been renamed to a cleanup tombstone, so opening the normal
    /// Guest store first could create a second source directory and blur the
    /// transaction boundary.
    @MainActor
    func prepareGuestMigrationRecoveryBeforeChromiumLaunch() {
        guard ApplicationState.shared.isGuest else { return }

        do {
            switch try GuestDataMigrationCoordinator
                .pendingGuestAccessDisposition() {
            case .unrestricted:
                return
            case .deferredCleanup(let targetUserID):
                let storedUserID = auth0Manager.storedUserInfo()?.sub
                if DeferredGuestMigrationRecoveryPolicy
                    .shouldSuspendGuestAccess(
                        hasRecoverableCredentials:
                            auth0Manager.hasRecoverableLoginSession(),
                        storedCredentialUserID: storedUserID,
                        journalTargetUserID: targetUserID
                    ) {
                    guard armGuestMigrationRecovery(
                        targetUserID: targetUserID
                    ) else { return }
                    MainBrowserWindowControllersManager.shared
                        .setGuestTransitionInteractionBlocked(true)
                    AppLogInfo(
                        "🔐 [GuestMigration] Matching staged credentials found " +
                        "for deferred cleanup; resuming the account transition"
                    )
                    return
                }

                // The old source has crossed its identity-derived staging
                // boundary. A new Guest directory is safe, but its next login
                // must first resume the journal-bound account.
                guestMigrationRecoveryTargetUserID = targetUserID
                requiresGuestMigrationTargetRecovery = true
                AppLogInfo(
                    "🔐 [GuestMigration] Deferred cleanup permits fresh Guest " +
                    "access; future login is bound to \(targetUserID)"
                )
            case .requiresTargetRecovery(let targetUserID):
                guard armGuestMigrationRecovery(targetUserID: targetUserID)
                else { return }
                MainBrowserWindowControllersManager.shared
                    .setGuestTransitionInteractionBlocked(true)
                AppLogInfo(
                    "🔐 [GuestMigration] Pending journal keeps Guest access " +
                    "suspended until recovery completes"
                )
            }
        } catch {
            AppLogError(
                "🔐 [GuestMigration] Failed to inspect the pending journal: " +
                error.localizedDescription
            )
            // Fail closed. The unreadable journal may describe a Guest
            // directory that has already crossed the atomic staging boundary.
            if armGuestMigrationRecovery(targetUserID: nil) {
                MainBrowserWindowControllersManager.shared
                    .setGuestTransitionInteractionBlocked(true)
            }
        }
    }

    /// Handles the explicit tertiary action on the login screen.
    ///
    /// Guest Mode is a browser-access choice, not a synthetic login. Any
    /// uncommitted Auth0 result is discarded, the account reference stays nil,
    /// and only the dedicated Guest marker is persisted. When the entry comes
    /// from the privacy confirmation page, the selected metrics preference is
    /// written after Guest state is active so Chromium refreshes its effective
    /// upload permission through the Guest consent gate.
    @discardableResult
    @MainActor
    func continueAsGuest(
        metricsReportingPreference: Bool? = nil
    ) -> GuestModeEntryResult {
        postLoginAIEnableIntent.cancel()
        // Only the running finalize blocks Guest entry. The durable credential
        // fence outlives it and must not: Guest writes no credentials, and the
        // boundary below clears the fenced ones itself.
        guard !auth0Manager.blocksGuestModeEntry else {
            AppLogWarn(
                "🗑️ [AccountDeletion] Ignoring Guest entry while the deletion " +
                "finalize is running"
            )
            return .failed
        }

        let pendingAccess: GuestDataMigrationGuestAccessDisposition
        do {
            pendingAccess = try GuestDataMigrationCoordinator
                .pendingGuestAccessDisposition()
        } catch {
            AppLogError(
                "🔐 [GuestMigration] Guest entry could not inspect the pending " +
                "journal: \(error.localizedDescription)"
            )
            pendingAccess = .requiresTargetRecovery(targetUserID: nil)
        }

        switch pendingAccess {
        case .unrestricted:
            if requiresGuestMigrationRecoveryPresentation {
                AppLogWarn(
                    "🔐 [GuestMigration] Ignoring Guest entry while an active " +
                    "recovery still requires the journal-bound account"
                )
                showLoginWindow()
                return .requiresAccountRecovery
            }
        case .deferredCleanup(let targetUserID):
            guestMigrationRecoveryTargetUserID = targetUserID
            requiresGuestMigrationTargetRecovery = true
        case .requiresTargetRecovery(let targetUserID):
            guard armGuestMigrationRecovery(targetUserID: targetUserID) else {
                showLoginWindow()
                return .requiresAccountRecovery
            }
            MainBrowserWindowControllersManager.shared
                .setGuestTransitionInteractionBlocked(true)
            showLoginWindow()
            return .requiresAccountRecovery
        }

        auth0Manager.cancelOngoingWebAuthentication()
        guard auth0Manager
            .prepareGuestSessionBoundaryBeforeServiceLaunch(
                preserveLocalRecoveryCredentials: false
        ) else {
            showGuestModeCredentialClearFailureAlert()
            return .failed
        }
        AccountController.shared.account = nil
        pendingAuthenticatedAccount = nil
        ApplicationState.shared.cancelGuestAccountPromotion()
        GuestModePreferences.disableAI()
        ApplicationState.shared.enterGuestMode()
        if let metricsReportingPreference {
            if let bridge = ChromiumLauncher.sharedInstance().bridge {
                bridge.setMetricsReportingEnabled(
                    metricsReportingPreference
                ) { _ in }
            } else {
                AppLogError(
                    "[GuestPrivacy] Unable to save metrics consent without the Chromium bridge"
                )
            }
        }
        PostHogSDK.shared.capture("guest_mode_entered")
        closeLoginWindow()
        return .enteredGuestMode
    }

    /// Returns `true` when onboarding still needs to be shown.
    @MainActor
    func orderFrontLoginWindowIfNeeded() -> Bool {
        if ApplicationState.shared.canUseBrowser {
            return false
        }
        let hasRecoverableSession = auth0Manager.hasRecoverableLoginSession()
        return LoginWindowGate.shouldShowLoginWindow(
            hasRecoverableSession: hasRecoverableSession,
            accountPhase: hasRecoverableSession ? phase : nil
        )
    }

    /// Answers a request to present onboarding with the ordinary "Continue as
    /// Guest" flow when the app was launched with `-skip-onboarding`. Returns
    /// `true` when Guest entry replaced the presentation. Guest-migration
    /// recovery keeps its journal-bound login, and requests from an already
    /// usable browser (a deliberate sign-in from Guest Mode) still present.
    @MainActor
    private func enterGuestModeInsteadOfOnboardingIfRequested() -> Bool {
        guard SkipOnboardingLaunchPolicy.shouldEnterGuestMode(
            hasLaunchArgument: ProcessInfo.processInfo.arguments
                .contains(SkipOnboardingLaunchPolicy.launchArgument),
            canUseBrowser: ApplicationState.shared.canUseBrowser,
            isAccountDeletionInProgress:
                auth0Manager.isAccountDeletionInProgress,
            presentsGuestMigrationRecovery:
                requiresGuestMigrationRecoveryPresentation
        ) else { return false }
        continueAsGuest()
        return true
    }
    
    func isLoggedin() -> Bool {
        guard AccountController.shared.account != nil,
              auth0Manager.hasRecoverableLoginSession() else {
            return false
        }

        return phase == .done
    }
    
    func refreshLoginStatusOnLaunching() {
        guard PhiBuildCapabilities.supportsAuthentication else {
            ApplicationState.shared.enterGuestMode()
            NotificationCenter.default.post(
                name: .loginStatusRefreshCompleted,
                object: nil
            )
            return
        }

        Task { @MainActor in
            if ApplicationState.shared.isGuest,
               !ApplicationState.shared.isGuestMigrationRecoveryInProgress {
                // A stable persisted Guest choice must not revive or renew an
                // Auth0 result that was never committed to an account. Besides
                // staging identity unexpectedly, an invalid refresh token
                // would enter the signed-in reauthentication/logout flow and
                // replace Guest access with the login gate.
                auth0Manager.discardUncommittedLoginCredentials()
                pendingAuthenticatedAccount = nil
                NotificationCenter.default.post(
                    name: .loginStatusRefreshCompleted,
                    object: nil
                )
                return
            }

            await AuthManager.shared.refreshAuthStatus()
            if let credentials = auth0Manager.currentCredentials {
                if !initAccountIfNeeded(credentials),
                   ApplicationState.shared
                    .isGuestMigrationRecoveryInProgress {
                    auth0Manager.discardUncommittedLoginCredentials()
                }
            } else if let storedUserInfo = auth0Manager.storedUserInfo() {
                if !initAcoountWithUserInfo(storedUserInfo),
                   ApplicationState.shared
                    .isGuestMigrationRecoveryInProgress {
                    auth0Manager.discardUncommittedLoginCredentials()
                }
            }

            let hasRecoverableSession = auth0Manager.hasRecoverableLoginSession()
            if ApplicationState.shared.isGuestMigrationRecoveryInProgress {
                if pendingAuthenticatedAccount == nil || phase != .done {
                    // Recovery owns presentation even when Chromium restores no
                    // browser window. This page keeps the ordinary Guest escape
                    // unavailable while the journal's target identity is fenced.
                    showLoginWindow()
                } else {
                    closeLoginWindow()
                }
            } else if !LoginWindowGate.shouldShowLoginWindow(
                hasRecoverableSession: hasRecoverableSession,
                accountPhase: hasRecoverableSession ? phase : nil
            ) {
                closeLoginWindow()
            }
            NotificationCenter.default.post(name: .loginStatusRefreshCompleted, object: nil)

            if ApplicationState.shared.isGuest,
               pendingAuthenticatedAccount != nil,
               phase == .done {
                // Resume an account transition interrupted after authentication
                // without surfacing the login window during an ordinary Guest
                // reopen.
                await completeCurrentLogin()
            } else if ApplicationState.shared.isAuthenticated {
                await retryPendingGuestDirectoryCleanupIfNeeded()
            }
        }
    }

    /// Commits a completed onboarding flow to browser access.
    ///
    /// Regular login only publishes the signed-in access state. Guest login
    /// first imports Native local data, then briefly publishes the target
    /// account behind a promotion fence so Space/window controllers can be
    /// rebound without closing Chromium profiles or WebContents.
    @MainActor
    func completeCurrentLogin() async {
        guard !isCompletingAccountTransition else { return }
        isCompletingAccountTransition = true
        defer { isCompletingAccountTransition = false }
        let startedInGuestMode = ApplicationState.shared.isGuest

        while true {
            let result = await activatePreparedAccount()
            switch result {
            case .completed:
                captureGuestModeExitIfNeeded(startedInGuestMode)
                finishBrowserAccessAfterLogin()
                return
            case .guestMigrationFailed(let error):
                AppLogError(
                    "🔐 [GuestMigration] Account setup failed before publication: " +
                    error.localizedDescription
                )
                if showGuestMigrationFailureAlert() {
                    continue
                }
                if abandonGuestAccountTransitionAfterFailure() {
                    closeLoginWindow()
                } else {
                    showLoginWindow()
                }
                return
            case .guestMigrationRequiresTargetRecovery(let error):
                AppLogError(
                    "🔐 [GuestMigration] Target import requires same-account recovery: " +
                    error.localizedDescription
                )
                requireSameTargetGuestMigrationRecovery()
                if showGuestMigrationTargetRecoveryAlert() {
                    continue
                }
                showLoginWindow()
                return
            case .completedWithDeferredGuestCleanup(let error):
                captureGuestModeExitIfNeeded(startedInGuestMode)
                AppLogError(
                    "🔐 [GuestMigration] Account published with deferred Guest cleanup: " +
                    error.localizedDescription
                )
                showDeferredGuestCleanupAlert()
                finishBrowserAccessAfterLogin()
                return
            }
        }
    }

    private func captureGuestModeExitIfNeeded(_ startedInGuestMode: Bool) {
        guard startedInGuestMode else { return }
        PostHogSDK.shared.capture("guest_mode_exited")
    }
    
    @discardableResult
    func initAccountIfNeeded(_ credentials: Credentials) -> Bool {
        AppLogDebug("🔐 [Login] initAccountIfNeeded called")
        let user = AuthManager.retriveUserInfo(from: credentials)
        guard let userID = user.sub, !userID.isEmpty else {
            AppLogError("🔐 [Login] Refusing to create an account without an Auth0 subject")
            return false
        }
        guard acceptsGuestMigrationRecoveryTarget(userID) else {
            return false
        }
        AppLogDebug("🔐 [Login] Retrieved user info - userID: \(userID), name: \(user.name ?? "nil"), email: \(user.email ?? "nil")")

        if let current = currentAccountWithoutRecovery() {
            AppLogDebug("🔐 [Login] Current account exists: \(current.userID)")
            if current.userID == userID {
                return true
            }
            AppLogDebug("🔐 [Login] Different user, replacing account")
        } else {
            AppLogDebug("🔐 [Login] No current account, creating new one")
        }

        installAuthenticatedAccount(Account(userID: userID, userInfo: user))
        if appPhase == .login {
            appPhase = .done
        }
        _ = currentAccount().map(accountPhase(for:))
        AppLogInfo("🔐 [Login] Account prepared for user: \(userID)")
        return true
    }

    @discardableResult
    func initAcoountWithUserInfo(_ userInfo: UserInfo) -> Bool {
        guard !userInfo.sub.isEmpty else {
            AppLogError("🔐 [Login] Refusing to create an account from empty stored user information")
            return false
        }
        guard acceptsGuestMigrationRecoveryTarget(userInfo.sub) else {
            return false
        }

        if let current = currentAccountWithoutRecovery(),
           current.userID == userInfo.sub {
            return true
        } else {
            installAuthenticatedAccount(Account(userID: userInfo.sub, userInfo: .init(userInfo)))
            if appPhase == .login {
                appPhase = .done
            }
            _ = currentAccount().map(accountPhase(for:))
            return true
        }
    }
    
    @MainActor
    func closeLoginWindow(preservingPostLoginAIEnableIntent: Bool = false) {
        if !preservingPostLoginAIEnableIntent {
            postLoginAIEnableIntent.cancel()
        }
        preservesPostLoginAIEnableIntentOnClose =
            preservingPostLoginAIEnableIntent
        loginWindowController?.window?.close()
        loginWindowController = nil
        preservesPostLoginAIEnableIntentOnClose = false
    }
    
    @MainActor
    func loginWithAuth0(with window: NSWindow? = nil, onWebViewCreated: ((WKWebView) -> Void)? = nil) async -> Credentials? {
        AppLogDebug("🔐 [Login] Logging in with default flow")
        let result = await auth0Manager.login()
        switch result {
        case .success(let credentials):
            return await MainActor.run {
                guard initAccountIfNeeded(credentials) else {
                    auth0Manager.discardUncommittedLoginCredentials()
                    return nil
                }
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
        if let account = currentAccountWithoutRecovery() {
            return account
        }

        if auth0Manager.hasRecoverableLoginSession(),
           let credentials = auth0Manager.currentCredentials {
            initAccountIfNeeded(credentials)
            return currentAccountWithoutRecovery()
        }

        if auth0Manager.hasRecoverableLoginSession(),
           let storedUserInfo = auth0Manager.storedUserInfo() {
            initAcoountWithUserInfo(storedUserInfo)
            return currentAccountWithoutRecovery()
        }

        return nil
    }

    var accountForOnboarding: Account? {
        currentAccount()
    }

    private func currentAccountWithoutRecovery() -> Account? {
        AccountController.shared.account ?? pendingAuthenticatedAccount
    }

    private func installAuthenticatedAccount(_ account: Account) {
        if ApplicationState.shared.isGuest {
            pendingAuthenticatedAccount = account
        } else {
            pendingAuthenticatedAccount = nil
            AccountController.shared.account = account
        }
    }

    private func acceptsGuestMigrationRecoveryTarget(_ userID: String) -> Bool {
        guard (ApplicationState.shared.isGuestMigrationRecoveryInProgress
                || requiresGuestMigrationTargetRecovery),
              let expectedUserID = guestMigrationRecoveryTargetUserID else {
            return true
        }
        guard userID == expectedUserID else {
            AppLogError(
                "🔐 [GuestMigration] Refusing recovery for a different " +
                "authenticated account"
            )
            return false
        }
        return true
    }

    /// Validates reauthentication without publishing a pending Guest account.
    /// During journal recovery the persisted target identity is authoritative;
    /// otherwise the already published or prepared account owns the session.
    @MainActor
    func acceptsReauthenticatedAccount(userID: String) -> Bool {
        AuthenticatedAccountIdentityPolicy.accepts(
            candidateUserID: userID,
            publishedUserID: AccountController.shared.account?.userID,
            pendingUserID: pendingAuthenticatedAccount?.userID,
            recoveryTargetUserID: guestMigrationRecoveryTargetUserID,
            isGuestMigrationRecoveryInProgress:
                ApplicationState.shared.isGuestMigrationRecoveryInProgress
                || requiresGuestMigrationTargetRecovery
        )
    }

    @MainActor
    private func requireSameTargetGuestMigrationRecovery() {
        if guestMigrationRecoveryTargetUserID == nil {
            guestMigrationRecoveryTargetUserID =
                pendingAuthenticatedAccount?.userID
        }
        requiresGuestMigrationTargetRecovery = true
        // With live controllers, preserve their slot graph until the
        // receipt-aware target rebind. The gate still changes synchronously,
        // so Dock, Chromium, and external-open probes see browser access as
        // unavailable; the transition interaction fence protects the retained
        // source binding from writes.
        _ = ApplicationState.shared.beginGuestMigrationRecovery(
            notifyBrowserAccessChange: false
        )
    }

    @MainActor
    private func armGuestMigrationRecovery(targetUserID: String?) -> Bool {
        guestMigrationRecoveryTargetUserID = targetUserID
        let hasMismatchedPendingAccount: Bool
        if let targetUserID, let pendingAuthenticatedAccount {
            hasMismatchedPendingAccount =
                pendingAuthenticatedAccount.userID != targetUserID
        } else {
            hasMismatchedPendingAccount = false
        }
        if targetUserID == nil || hasMismatchedPendingAccount {
            pendingAuthenticatedAccount = nil
            auth0Manager.discardUncommittedLoginCredentials()
        }
        if !ApplicationState.shared.isGuest {
            ApplicationState.shared.enterGuestMigrationRecovery()
        }
        guard ApplicationState.shared.beginGuestMigrationRecovery() else {
            guestMigrationRecoveryTargetUserID = nil
            return false
        }
        return true
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

    @MainActor
    private func activatePreparedAccount() async -> AccountActivationResult {
        guard let targetAccount = currentAccountWithoutRecovery() else {
            return .guestMigrationFailed(
                GuestDataMigrationError.targetStateConflict(
                    "no authenticated account is available"
                )
            )
        }

        guard let pendingAccount = pendingAuthenticatedAccount,
              ApplicationState.shared.isGuest else {
            AccountController.shared.account = targetAccount
            pendingAuthenticatedAccount = nil
            ApplicationState.shared.markSignedIn()
            AccountController.shared.activateAuthenticatedAccountIfNeeded()
            await auth0Manager.activateAuthenticatedSessionAfterAccountCommit()
            return .completed
        }

        let sourceAccount = AccountController.defaultAccount
        let windowManager = MainBrowserWindowControllersManager.shared
        windowManager.setGuestTransitionInteractionBlocked(true)
        AIChatSidebarStateStore.shared.beginGuestAccountTransition()

        let receipt: GuestDataMigrationReceipt
        do {
            receipt = try await GuestDataMigrationCoordinator.migrate(
                sourceAccount: sourceAccount,
                targetAccount: pendingAccount
            )
        } catch {
            if (error as? GuestDataMigrationError)?
                .requiresTargetRecovery == true {
                // The destination contains a complete or partial import, so
                // Guest can no longer be reopened safely. Keep the source
                // sealed, retain the staged identity, and require retry
                // against this journal-bound target.
                return .guestMigrationRequiresTargetRecovery(error)
            }

            // Migration takes a terminal FIFO snapshot of the Guest store.
            // The coordinator has proven that none of the planned target IDs
            // were imported, retired the prepared journal, and installed a
            // fresh writable default account over the intact source directory.
            let refreshedGuestAccount = AccountController.defaultAccount
            SpaceManager.shared
                .refreshGuestAccountBindingAfterMigrationRollback()
            windowManager.rebindWindowControllers(to: refreshedGuestAccount)
            AIChatSidebarStateStore.shared.endGuestAccountTransition()
            windowManager.setGuestTransitionInteractionBlocked(false)
            return .guestMigrationFailed(error)
        }

        guard ApplicationState.shared.beginGuestAccountPromotion() else {
            return .guestMigrationRequiresTargetRecovery(
                GuestDataMigrationError.targetImportRequiresRecovery(
                    "Guest access changed before account publication"
                )
            )
        }

        // The account is published only as a Native local-data owner while the
        // promotion fence keeps identity APIs, telemetry, and network prefetch
        // unavailable. Releasing a launch-recovery gate binds SpaceManager to
        // the target store; the window manager deliberately leaves recovery
        // windows dangling until the receipt-aware rebind below.
        AccountController.shared.account = pendingAccount
        guard ApplicationState.shared
            .resumeBrowserAccessForGuestAccountPromotion() else {
            return .guestMigrationRequiresTargetRecovery(
                GuestDataMigrationError.targetImportRequiresRecovery(
                    "Guest promotion access could not be resumed"
                )
            )
        }
        windowManager.rebindWindowControllers(
            to: pendingAccount,
            migrationReceipt: receipt
        )

        do {
            try await GuestDataMigrationCoordinator.finalizeSourceDirectoryCleanup(
                receipt: receipt,
                sourceAccount: sourceAccount,
                targetAccount: pendingAccount
            )
        } catch {
            // Target import and controller rebinding are already durable. The
            // identity-bound journal keeps cleanup retryable, so complete the
            // account transition and report the deferred filesystem cleanup
            // instead of attempting an unsafe rollback to Guest.
            pendingAuthenticatedAccount = nil
            ApplicationState.shared.markSignedIn()
            AccountController.shared.activateAuthenticatedAccountIfNeeded()
            await auth0Manager.activateAuthenticatedSessionAfterAccountCommit()
            AIChatSidebarStateStore.shared.endGuestAccountTransition()
            windowManager.setGuestTransitionInteractionBlocked(false)
            return .completedWithDeferredGuestCleanup(error)
        }

        pendingAuthenticatedAccount = nil
        ApplicationState.shared.markSignedIn()
        AccountController.shared.activateAuthenticatedAccountIfNeeded()
        await auth0Manager.activateAuthenticatedSessionAfterAccountCommit()
        AIChatSidebarStateStore.shared.endGuestAccountTransition()
        windowManager.setGuestTransitionInteractionBlocked(false)
        return .completed
    }

    @MainActor
    private func retryPendingGuestDirectoryCleanupIfNeeded() async {
        guard !isCompletingAccountTransition,
              let targetAccount = AccountController.shared.account else {
            return
        }

        let journal: GuestDataMigrationJournal
        do {
            guard let pendingJournal = try GuestDataMigrationCoordinator.pendingJournal()
            else {
                return
            }
            journal = pendingJournal
        } catch {
            AppLogError(
                "🔐 [GuestMigration] Failed to read pending cleanup: " +
                error.localizedDescription
            )
            showDeferredGuestCleanupAlert()
            return
        }

        guard journal.targetUserID == targetAccount.userID else {
            AppLogError(
                "🔐 [GuestMigration] Pending cleanup does not match the current account"
            )
            showDeferredGuestCleanupAlert()
            return
        }

        do {
            let receipt = try await GuestDataMigrationCoordinator.migrate(
                targetAccount: targetAccount
            )
            try await GuestDataMigrationCoordinator.finalizeSourceDirectoryCleanup(
                receipt: receipt,
                targetAccount: targetAccount
            )
        } catch {
            AppLogError(
                "🔐 [GuestMigration] Deferred cleanup retry failed: " +
                error.localizedDescription
            )
            showDeferredGuestCleanupAlert()
        }
    }

    @MainActor
    private func finishBrowserAccessAfterLogin() {
        guestMigrationRecoveryTargetUserID = nil
        requiresGuestMigrationTargetRecovery = false
        enableAIIfRequestedAfterLogin()
        closeLoginWindow()

        if MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() == nil {
            ChromiumLauncher.sharedInstance().bridge?
                .applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        } else {
            ChromiumLauncher.sharedInstance().bridge?.notifyRebuildMenuAfterLogin()
        }
        ChromiumLauncher.sharedInstance().bridge?.notifyLoginCompleted()
        NotificationCenter.default.post(name: .loginCompleted, object: nil)
    }

    private func enableAIIfRequestedAfterLogin() {
        postLoginAIEnableIntent.enableAIIfRequested()
    }

    @MainActor
    private func abandonGuestAccountTransitionAfterFailure() -> Bool {
        postLoginAIEnableIntent.cancel()
        auth0Manager.cancelOngoingWebAuthentication()
        pendingAuthenticatedAccount = nil
        guestMigrationRecoveryTargetUserID = nil
        requiresGuestMigrationTargetRecovery = false
        ApplicationState.shared.cancelGuestAccountPromotion()
        guard auth0Manager
            .prepareGuestSessionBoundaryBeforeServiceLaunch(
                preserveLocalRecoveryCredentials: false
            ) else {
            ApplicationState.shared.requireLogin()
            showGuestModeCredentialClearFailureAlert()
            return false
        }
        if ApplicationState.shared.isGuestMigrationRecoveryInProgress {
            // Every failure path has already rebound live Guest controllers to
            // a fresh default account. Releasing the gate now lets the generic
            // browser-access observer materialize cold-recovery windows there.
            ApplicationState.shared.endGuestMigrationRecovery()
        }
        return true
    }

    @MainActor
    private func showGuestMigrationFailureAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "oobe.guestMigration.failure.title",
            value: "Couldn’t finish setting up your account",
            comment: "Guest migration - Alert title when Guest data could not be moved before account publication"
        )
        alert.informativeText = NSLocalizedString(
            "oobe.guestMigration.failure.message",
            value: "Phi couldn’t move your Guest data. Your data is safe, and you can try again.",
            comment: "Guest migration - Alert message explaining that Guest data remains safe and migration can be retried"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMigration.failure.retryButton",
            value: "Try Again",
            comment: "Guest migration - Button that retries a failed Guest data migration"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMigration.failure.notNowButton",
            value: "Not Now",
            comment: "Guest migration - Button that keeps using Guest Mode after a failed migration"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showGuestModeCredentialClearFailureAlert() {
        AuthenticatedSentinelSessionLifecycle
            .suspendForUnauthenticatedSession()
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "oobe.guestMode.credentialClearFailure.title",
            value: "Couldn’t start Guest Mode",
            comment: "Guest mode - Alert title when authenticated credentials could not be cleared"
        )
        alert.informativeText = NSLocalizedString(
            "oobe.guestMode.credentialClearFailure.message",
            value: "Phi couldn’t securely clear the previous session. Try again before continuing as Guest.",
            comment: "Guest mode - Alert message asking the user to retry after credential cleanup failed"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMode.credentialClearFailure.dismissButton",
            value: "OK",
            comment: "Guest mode - Button that dismisses the credential cleanup failure alert"
        ))
        alert.runModal()
    }

    @MainActor
    private func showGuestMigrationTargetRecoveryAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "oobe.guestMigration.targetRecovery.title",
            value: "Finish moving your Guest data",
            comment: "Guest migration - Alert title when imported target data requires retrying the same account"
        )
        alert.informativeText = NSLocalizedString(
            "oobe.guestMigration.targetRecovery.message",
            value: "Some data has already been moved to this account. Phi must retry with the same account before Guest data can be used again.",
            comment: "Guest migration - Alert message explaining why the same account migration must be retried"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMigration.targetRecovery.retryButton",
            value: "Try Again",
            comment: "Guest migration - Button that retries migration for the journal-bound account"
        ))
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMigration.targetRecovery.cancelButton",
            value: "Cancel",
            comment: "Guest migration - Button that returns to the recovery login while Guest data stays locked"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private func showDeferredGuestCleanupAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "oobe.guestMigration.cleanupDeferred.title",
            value: "Guest data cleanup is incomplete",
            comment: "Guest migration - Alert title when account setup succeeded but the old Guest directory could not be removed"
        )
        alert.informativeText = NSLocalizedString(
            "oobe.guestMigration.cleanupDeferred.message",
            value: "Your account is ready and your data is safe. Phi will try to remove the old Guest data again the next time it starts.",
            comment: "Guest migration - Alert message for deferred deletion of the old Guest data directory"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString(
            "oobe.guestMigration.cleanupDeferred.dismissButton",
            value: "OK",
            comment: "Guest migration - Button that dismisses the deferred cleanup alert"
        ))
        alert.runModal()
    }
}

enum AuthenticatedAccountIdentityPolicy {
    static func accepts(
        candidateUserID: String,
        publishedUserID: String?,
        pendingUserID: String?,
        recoveryTargetUserID: String?,
        isGuestMigrationRecoveryInProgress: Bool
    ) -> Bool {
        if isGuestMigrationRecoveryInProgress {
            guard candidateUserID == recoveryTargetUserID else {
                return false
            }
            return pendingUserID == nil || candidateUserID == pendingUserID
        }

        if let publishedUserID {
            return candidateUserID == publishedUserID
        }
        if let pendingUserID {
            return candidateUserID == pendingUserID
        }
        return false
    }
}

struct LoginWindowGate {
    static func shouldShowLoginWindow(
        hasRecoverableSession: Bool,
        accountPhase: LoginController.Phase?
    ) -> Bool {
        guard hasRecoverableSession else {
            return true
        }
        return accountPhase != .done
    }
}

/// Launch-argument override for automated and development runs: whenever the
/// app is about to present onboarding, it chooses "Continue as Guest"
/// instead. Deliberate sign-in presentations from an already usable browser,
/// journal-bound Guest-migration recovery, and deletion-blocked launches keep
/// their ordinary presentation.
enum SkipOnboardingLaunchPolicy {
    static let launchArgument = "-skip-onboarding"

    static func shouldEnterGuestMode(
        hasLaunchArgument: Bool,
        canUseBrowser: Bool,
        isAccountDeletionInProgress: Bool,
        presentsGuestMigrationRecovery: Bool
    ) -> Bool {
        hasLaunchArgument
            && !canUseBrowser
            && !isAccountDeletionInProgress
            && !presentsGuestMigrationRecovery
    }
}

enum DeferredGuestMigrationRecoveryPolicy {
    static func shouldSuspendGuestAccess(
        hasRecoverableCredentials: Bool,
        storedCredentialUserID: String?,
        journalTargetUserID: String
    ) -> Bool {
        hasRecoverableCredentials
            && !journalTargetUserID.isEmpty
            && storedCredentialUserID == journalTargetUserID
    }
}
