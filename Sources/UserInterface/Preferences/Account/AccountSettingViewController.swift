// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Settings
import Kingfisher
import SnapKit
import Combine

class AccountSettingViewController: NSViewController, SettingsPane {
    var paneIdentifier = Settings.PaneIdentifier.account
    var toolbarItemIcon: NSImage = NSImage(resource: .settingAccountIcon)

    private static let maxPaneTitleLength = 20

    var paneTitle: String {
        if ApplicationState.shared.isGuest {
            return NSLocalizedString(
                "settings.account.guest.paneTitle",
                value: "Guest",
                comment: "Account settings - Pane title shown while using Phi in Guest Mode"
            )
        }

        let fullName: String
        if !accountViewModel.userName.isEmpty {
            fullName = accountViewModel.userName
        } else if let cachedUserName = AccountController.shared.account?.userDefaults.string(forKey: AccountUserDefaults.DefaultsKey.cachedUserName.rawValue),
                  cachedUserName.isEmpty == false {
            fullName = cachedUserName
        } else {
            return NSLocalizedString("settings.account.displayName.fallback", value: "You", comment: "Account settings - Default display name when user name is not available")
        }

        // Truncate if exceeds max length
        if fullName.count > Self.maxPaneTitleLength {
            let index = fullName.index(fullName.startIndex, offsetBy: Self.maxPaneTitleLength)
            return String(fullName[..<index]) + "..."
        }
        return fullName
    }

    // Left side - Profile card
    private let profileCardView = ProfileCardView()

    // Right side - Settings sections
    private let defaultBrowserView: DefaultBrowserSectionView
    private let accountView: AccountCardView
    private let shareView: ShareSectionView

    private let defaultBrowserViewModel = DefaultBrowserViewModel()
    private let accountViewModel = AccountViewModel()
    private let shareViewModel = ShareViewModel()
    
    private weak var avatarWindowController: AccountWebWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindowCloseObserver: NSObjectProtocol?
    private var signedInRightContainerLeadingConstraint: Constraint?
    private var guestRightContainerLeadingConstraint: Constraint?

    private var avatarEditURL: String {
        #if DEBUG
        if AuthManager.useStagingAuth0 {
            return "https://account.stag.phibrowser.com/avatar"
        } else {
            return "https://account.phibrowser.com/avatar"
        }
        #elseif NIGHTLY_BUILD
        return "https://account.stag.phibrowser.com/avatar"
        #else
        return "https://account.phibrowser.com/avatar"
        #endif
    }

    init() {
        self.defaultBrowserView = DefaultBrowserSectionView(viewModel: defaultBrowserViewModel)
        self.accountView = AccountCardView(viewModel: accountViewModel)
        self.shareView = ShareSectionView(viewModel: shareViewModel)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.defaultBrowserView = DefaultBrowserSectionView(viewModel: defaultBrowserViewModel)
        self.accountView = AccountCardView(viewModel: accountViewModel)
        self.shareView = ShareSectionView(viewModel: shareViewModel)
        super.init(coder: coder)
    }

    deinit {
        if let settingsWindowCloseObserver {
            NotificationCenter.default.removeObserver(settingsWindowCloseObserver)
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(PhiPreferences.fixedWindowBackground)
        view.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindViewModel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        registerSettingsWindowCloseObserverIfNeeded()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        
        AppLogDebug("👁️ [AccountSettings] viewWillAppear called")

        updateAccessPresentation()
        defaultBrowserViewModel.checkDefaultBrowser()

        guard ApplicationState.shared.isAuthenticated else {
            AppLogDebug("👁️ [AccountSettings] Account is not authenticated, skipping account data load")
            return
        }

        loadAuthenticatedAccountData()
    }

    private func loadAuthenticatedAccountData() {
        AppLogDebug("👁️ [AccountSettings] Starting authenticated data load...")
        accountView.revalidateAvatar()
        Task {
            async let userInfo: Profile? = accountViewModel.loadUserInfo()

            let profile = await userInfo
            profileCardView.userInfo = profile
            accountView.revalidateAvatar()
            AppLogDebug("👁️ [AccountSettings] Data load completed")
        }
    }

    private func setupUI() {
        #if PHI_OSS_BUILD
        view.addSubview(defaultBrowserView)
        defaultBrowserView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(36)
            make.left.right.equalToSuperview().inset(36)
        }
        #else
        // Profile card on the left
        view.addSubview(profileCardView)
        profileCardView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(24)  // 36 - 12(inner padding for shadow)
            make.top.equalToSuperview().offset(36)
            make.width.equalTo(264)
        }

        // Right side container
        let rightContainer = NSView()
        view.addSubview(rightContainer)

        rightContainer.snp.makeConstraints { make in
            signedInRightContainerLeadingConstraint =
                make.left.equalTo(profileCardView.snp.right).offset(4).constraint
            make.top.equalToSuperview().offset(36)
            make.right.equalToSuperview().offset(-36)
            make.bottom.lessThanOrEqualToSuperview().offset(-36)
            make.width.greaterThanOrEqualTo(352)
        }
        rightContainer.snp.makeConstraints { make in
            guestRightContainerLeadingConstraint =
                make.left.equalToSuperview().offset(36).constraint
        }
        guestRightContainerLeadingConstraint?.deactivate()

        // Account card (top)
        rightContainer.addSubview(accountView)
        accountView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.height.equalTo(92)
        }

        // Default browser section
        rightContainer.addSubview(defaultBrowserView)
        defaultBrowserView.snp.makeConstraints { make in
            make.top.equalTo(accountView.snp.bottom).offset(20)
            make.left.right.equalToSuperview()
        }

        // Share section
        rightContainer.addSubview(shareView)
        shareView.snp.makeConstraints { make in
            make.top.equalTo(defaultBrowserView.snp.bottom).offset(20)
            make.left.right.equalToSuperview()
            make.height.equalTo(74)
            make.bottom.equalToSuperview()
        }

        // Initially hide invitation section (assuming no invitation permission)
        shareView.isHidden = true

        // Setup callback to update profile card when user name changes (optimistic update)
        accountView.onUserNameUpdated = { [weak self] newName in
            // Optimistic update: immediately update Profile Card
            guard let self = self,
                  var currentProfile = self.profileCardView.userInfo else {
                return
            }

            // Update the profile with new name immediately
            currentProfile.name = newName
            self.profileCardView.userInfo = currentProfile
        }

        // Setup avatar edit action
        accountView.onAvatarEdit = { [weak self] in
            self?.openAvatarEditor()
        }

        // Setup logout action
        accountView.logoutAction = { [weak self] in
            Task { @MainActor in
                await self?.accountViewModel.logout()
            }
        }
        accountView.loginAction = {
            Task { @MainActor in
                LoginController.shared.showLoginWindow()
            }
        }
        accountView.reauthenticationAction = {
            Task { @MainActor in
                _ = await AuthManager.shared.reauthenticateExpiredSession()
            }
        }

        updateAccessPresentation()
        #endif
    }

    private func openAvatarEditor() {
        avatarWindowController?.close()

        var avatarWasSaved = false
        // Pin the account that opened the editor: the editor window is
        // non-modal and survives logout, so a save arriving after an
        // account switch must not be stored for the new account
        // (storeAvatarImage rejects a no-longer-current instance).
        let editingAccount = AccountController.shared.account
        let windowController = AccountWebWindowController(url: avatarEditURL)
        avatarWindowController = windowController
        windowController.onAvatarSaved = { [weak self] image in
            self?.accountView.setAvatarImage(image)
            // The avatar URL is stable while its content changes, and
            // Kingfisher attaches same-URL retrieves to an in-flight
            // download — cancel any pre-save download so the post-save
            // refresh starts a fresh request instead of receiving the
            // old bytes from a task that began before this save.
            if let urlString = self?.accountViewModel.avatarURL,
               let url = URL(string: urlString) {
                KingfisherManager.shared.downloader.cancel(url: url)
            }
            // The editor's payload is the freshest copy; hand it to the
            // Chromium settings bridge without waiting for the URL refetch.
            if let editingAccount {
                AccountController.shared.storeAvatarImage(image, for: editingAccount)
            }
            avatarWasSaved = true
            Task {
                await self?.accountViewModel.loadUserInfo(showLoading: false)
            }
            self?.avatarWindowController?.close()
        }
        windowController.onWindowClosed = { [weak self] in
            if !avatarWasSaved {
                self?.accountView.revalidateAvatar()
            }
        }
        windowController.showWindow(nil)
    }

    private func bindViewModel() {
        shareViewModel.$shouldShowInvitation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShow in
                guard let self else { return }
                self.shareView.isHidden = ApplicationState.shared.isGuest || !shouldShow
            }
            .store(in: &cancellables)
        
        accountViewModel.$userName
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                guard let self else { return }
                notifyPaneTitleDidChange()
                AccountController.shared.account?.userDefaults.set(name, forKey: .cachedUserName)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .authReauthenticationStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateReauthenticationWarning()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .browserAccessStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateAccessPresentation()
                if ApplicationState.shared.isAuthenticated {
                    self.loadAuthenticatedAccountData()
                }
            }
            .store(in: &cancellables)
    }

    private func updateReauthenticationWarning() {
        accountView.updateReauthenticationWarning(
            isVisible: ApplicationState.shared.isAuthenticated
                && AuthManager.shared.requiresReauthentication
        )
    }

    private func updateAccessPresentation() {
        let isGuest = ApplicationState.shared.isGuest
        profileCardView.isHidden = isGuest
        accountView.updateGuestPresentation(isGuest)
        shareView.isHidden = isGuest || !shareViewModel.shouldShowInvitation

        if isGuest {
            signedInRightContainerLeadingConstraint?.deactivate()
            guestRightContainerLeadingConstraint?.activate()
        } else {
            guestRightContainerLeadingConstraint?.deactivate()
            signedInRightContainerLeadingConstraint?.activate()
        }

        updateReauthenticationWarning()
        notifyPaneTitleDidChange()
    }

    private func registerSettingsWindowCloseObserverIfNeeded() {
        guard settingsWindowCloseObserver == nil,
              let window = view.window else {
            return
        }

        settingsWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.accountViewModel.cancelOngoingLogoutSession(reason: .settingsWindowClosed)
            }
        }
    }
}


// MARK: - ViewModels

class DefaultBrowserViewModel: ObservableObject {
    @Published var isDefaultBrowser: Bool = false
    @Published var statusText: String = NSLocalizedString("settings.account.defaultBrowser.initialNotDefaultStatus", value: "Phi is not your default browser", comment: "Account settings - Initial status text before the current default-browser state is refreshed")
    @Published var isLoading: Bool = true

    init() {
        // Don't check immediately, wait for viewWillAppear
    }

    func checkDefaultBrowser() {
        isLoading = true
        // Check if Phi is the default browser
        // This is a placeholder implementation
        isDefaultBrowser = isPhiBrowserDefault()
        updateStatusText()
        isLoading = false
    }

    private func isPhiBrowserDefault() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let url = URL(string: "http://example.com"),
              let defaultAppURL = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() else {
            return false
        }

        let appURL = defaultAppURL as URL
        guard let defaultBundle = Bundle(url: appURL),
              let defaultBundleId = defaultBundle.bundleIdentifier else {
            return false
        }

        return defaultBundleId == bundleIdentifier
    }

    @MainActor
    func setAsDefault() async {
        await doSetAsDefaultBrowser()
        checkDefaultBrowser()
    }

    private func doSetAsDefaultBrowser() async {
        guard let appURL = Bundle.main.bundleURL as URL? else {
            return
        }

        let workspace = NSWorkspace.shared
        // macOS links the default handlers for "http" and "https" (and public.html).
        // Setting "http" is sufficient; attempting to set "https" separately may fail.

        do {
            try await workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http")
        } catch {
            AppLogError("fail to set default app: \(error.localizedDescription)")
        }
    }

    private func updateStatusText() {
        statusText = isDefaultBrowser ? NSLocalizedString("settings.account.defaultBrowser.defaultStatus", value: "Phi is your default browser", comment: "Account settings - Status text when Phi is the default browser") : NSLocalizedString("settings.account.defaultBrowser.notDefaultStatus", value: "Phi is not your default browser", comment: "Account settings - Status text when Phi is not the default browser")
    }
}

class AccountViewModel: ObservableObject {
    private static let logoutTimeoutSeconds = 90

    /// Why an in-flight logout attempt was cancelled. The two carry opposite
    /// intents: a closed settings window abandons the logout, while the
    /// timeout only gives up on the remote callback — the logout itself must
    /// still complete locally, because with the external-browser flow an
    /// unreachable Auth0 never errors out, it simply never calls back.
    enum LogoutCancelReason: String {
        case timeout
        case settingsWindowClosed = "settings_window_closed"
    }

    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var avatarURL: String = ""
    @Published var isLoading: Bool = true
    @Published var canEditUserName: Bool = false
    @Published var isLogoutInProgress: Bool = false

    var cancellables = Set<AnyCancellable>()
    private var activeLogoutAttemptID: UUID?
    private var logoutTimeoutWorkItem: DispatchWorkItem?
    private var cancelledLogoutAttempts: [UUID: LogoutCancelReason] = [:]
    
    /// Loads the cached profile from user defaults.
    private func loadCachedProfile() -> Profile? {
        guard let userDefaults = AccountController.shared.account?.userDefaults else {
            return nil
        }
        return userDefaults.codableValue(forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue)
    }
    
    /// Caches the latest profile in user defaults.
    private func cacheProfile(_ profile: Profile) {
        guard let userDefaults = AccountController.shared.account?.userDefaults else {
            return
        }
        userDefaults.set(profile, forCodableKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue)
    }

    func loadUserInfo(showLoading: Bool = true) async -> Profile? {
        guard ApplicationState.shared.isAuthenticated else { return nil }
        // Show cached data first while the fresh request is still pending.
        if let cachedProfile = loadCachedProfile() {
            await MainActor.run {
                userName = cachedProfile.name
                userEmail = cachedProfile.email
                avatarURL = cachedProfile.picture
                // Keep editing disabled until the network copy succeeds.
                isLoading = false
                canEditUserName = false
            }
            AppLogInfo("📦 [AccountSettings] Loaded cached profile: \(cachedProfile.name)")
        } else if showLoading {
            await MainActor.run {
                isLoading = true
                canEditUserName = false
            }
        }

        // Refresh the profile from the API.
        do {
            let resp = try await APIClient.shared.getAccountProfile()
            guard ApplicationState.shared.isAuthenticated else { return nil }
            if resp.code == 0 {
                let profile = resp.data
                // Refresh the cached copy with the latest network response.
                cacheProfile(profile)
                AppLogInfo("📦 [AccountSettings] Cached profile from network: \(profile.name)")
                // Keep the Chromium settings bridge's avatar copy in step
                // with this refresh.
                if let account = AccountController.shared.account,
                   profile.auth0_id == account.userID {
                    AccountController.shared.refreshAvatar(for: account, pictureURLString: profile.picture)
                }
                
                return await MainActor.run {
                    userName = profile.name
                    userEmail = profile.email
                    avatarURL = profile.picture
                    isLoading = false
                    canEditUserName = true
                    return profile
                }
            } else {
                await MainActor.run {
                    isLoading = false
                    canEditUserName = false
                }
            }
        } catch {
            AppLogError("Failed to load user profile: \(error.localizedDescription)")
            await MainActor.run {
                isLoading = false
                canEditUserName = false
            }
        }
        return nil
    }

    @MainActor
    private func showLogoutConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("settings.account.logoutConfirmation.title", value: "Sign out of Phi?", comment: "Account settings - Sign-out confirmation dialog title")
        alert.informativeText = NSLocalizedString("settings.account.logoutConfirmation.message", value: "You’ll return to the sign-in screen.", comment: "Account settings - Sign-out confirmation dialog message")
        alert.addButton(withTitle: NSLocalizedString("settings.account.logoutConfirmation.cancelButton", value: "Cancel", comment: "Account settings - Cancel button in sign-out confirmation dialog"))
        alert.addButton(withTitle: NSLocalizedString("settings.account.logoutConfirmation.logoutButton", value: "Sign out", comment: "Account settings - Sign-out button in sign-out confirmation dialog"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
    
    @MainActor
    private func showLogoutFailedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("settings.account.logoutFailure.title", value: "Sign out failed", comment: "Account settings - Alert title when sign-out fails")
        alert.informativeText = NSLocalizedString("settings.account.logoutFailure.message", value: "Something went wrong when signing out", comment: "Account settings - Alert message when sign-out fails")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("settings.account.logoutFailure.dismissButton", value: "OK", comment: "Account settings - OK button to dismiss sign-out failed alert"))
        alert.runModal()
    }

    @MainActor
    func logout() async {
        AppLogDebug("🚪 [Logout] Starting logout flow")

        guard !isLogoutInProgress else {
            AppLogDebug("🚪 [Logout] Ignoring logout request while another logout is in progress")
            return
        }
        
        // Step 1: confirm logout.
        AppLogDebug("🚪 [Logout] Step 1: Showing confirmation dialog")
        guard showLogoutConfirmation() else {
            AppLogDebug("🚪 [Logout] User cancelled logout")
            return
        }
        
        AppLogDebug("🚪 [Logout] User confirmed logout, proceeding...")
        let logoutAttemptID = UUID()
        activeLogoutAttemptID = logoutAttemptID
        isLogoutInProgress = true
        armLogoutTimeout(for: logoutAttemptID)
        
        // Step 3: clear the Auth0 session and credentials.
        AppLogDebug("🚪 [Logout] Step 3: Clearing Auth0 session and credentials")
        let success = await AuthManager.shared.logOut()
        let cancelReason = finishLogoutAttempt(logoutAttemptID)
        if !success {
            switch cancelReason {
            case .timeout:
                // Our own timeout gave up waiting for the Auth0 callback,
                // which is how an unreachable Auth0 presents itself here.
                // Giving up on the network must not leave the user logged
                // in: run the local half and carry on with the teardown.
                AppLogWarn("🚪 [Logout] Timed out waiting for Auth0, continuing with local logout")
                await AuthManager.shared.completeLogoutLocally()
            case .settingsWindowClosed:
                AppLogWarn("🚪 [Logout] Auth0 logout was cancelled")
                return
            case nil:
                // Not cancelled by us: the external browser could not be
                // launched, or another web auth transaction holds Auth0's
                // barrier. Nothing was cleared; report and abandon.
                AppLogError("🚪 [Logout] Auth0 logout failed")
                showLogoutFailedAlert()
                return
            }
        } else if cancelReason != nil {
            // The cancel landed after the logout had already gone through. Local
            // credentials and the account reference are gone by now, so bailing
            // out here would leave the browser running account-less with its
            // Space slots torn down; carry on to the login window instead.
            AppLogWarn("🚪 [Logout] Cancellation arrived after logout completed, continuing teardown")
        }
        // Not "Auth0 session cleared": the remote teardown is best effort, so
        // this point is reached even when it failed.
        AppLogDebug("🚪 [Logout] Auth0 logout returned")
        
        // Step 4: local account state — credentials, cached profile and avatar,
        // and the account reference — was cleared by `AuthManager.logOut()`.
        AppLogDebug("🚪 [Logout] Step 4: Local account state cleared")
        ApplicationState.shared.requireLogin()
        
        // Step 5: close the settings window.
        AppLogDebug("🚪 [Logout] Step 5: Closing settings window")
        if let settingsWindow = AppController.shared?.settingsWindowController?.window {
            settingsWindow.close()
            AppLogDebug("🚪 [Logout] Settings window closed")
        } else {
            AppLogDebug("🚪 [Logout] Settings window not found or already closed")
        }
        
        // Step 6: close every browser window.
        AppLogDebug("🚪 [Logout] Step 6: Closing all browser windows")
        MainBrowserWindowControllersManager.shared.closeAllWindows()
        AppLogDebug("🚪 [Logout] All browser windows close requested")
        
        // Step 7: reopen the login window and return to onboarding.
        AppLogDebug("🚪 [Logout] Step 7: Showing login window for OOBE")
        LoginController.shared.showLoginWindow()
        AppLogDebug("🚪 [Logout] ✅ Logout flow completed successfully")
    }

    @MainActor
    private func armLogoutTimeout(for attemptID: UUID) {
        logoutTimeoutWorkItem?.cancel()
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.activeLogoutAttemptID == attemptID else { return }
            AppLogWarn("🚪 [Logout] Auth0 logout timed out after \(Self.logoutTimeoutSeconds)s")
            self.cancelOngoingLogoutSession(reason: .timeout)
        }
        logoutTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Self.logoutTimeoutSeconds), execute: timeoutWorkItem)
    }

    @MainActor
    func cancelOngoingLogoutSession(reason: LogoutCancelReason) {
        guard let attemptID = activeLogoutAttemptID else {
            return
        }

        AppLogDebug("🚪 [Logout] Cancelling pending logout session reason=\(reason.rawValue)")
        cancelledLogoutAttempts[attemptID] = reason
        logoutTimeoutWorkItem?.cancel()
        logoutTimeoutWorkItem = nil
        activeLogoutAttemptID = nil
        isLogoutInProgress = false
        AuthManager.shared.cancelOngoingWebAuthentication()
    }

    /// Ends the bookkeeping for `attemptID` and answers why it was cancelled,
    /// nil meaning it was not.
    @MainActor
    private func finishLogoutAttempt(_ attemptID: UUID) -> LogoutCancelReason? {
        let cancelReason = cancelledLogoutAttempts.removeValue(forKey: attemptID)
        guard activeLogoutAttemptID == attemptID else {
            return cancelReason
        }
        logoutTimeoutWorkItem?.cancel()
        logoutTimeoutWorkItem = nil
        activeLogoutAttemptID = nil
        isLogoutInProgress = false
        return cancelReason
    }

    func updateUserName(_ newName: String) async {
        guard ApplicationState.shared.isAuthenticated else { return }
        let oldName = userName

        // Optimistic update: reflect immediately in UI
        await MainActor.run {
            userName = newName
        }

        // Revalidate via API
        do {
            let request = UpdateProfileRequest(name: newName)
            let resp = try await APIClient.shared.updateProfile(updates: request)
            guard ApplicationState.shared.isAuthenticated else { return }

            if resp.code == 0 {
                let updatedProfile = resp.data
                cacheProfile(updatedProfile)
                AppLogDebug("📦 [AccountSettings] Updated cached profile after name change: \(updatedProfile.name)")
                await MainActor.run {
                    userName = updatedProfile.name
                }
            } else {
                AppLogError("Failed to update user name: \(resp.message)")
                await MainActor.run {
                    userName = oldName
                }
            }
        } catch {
            AppLogError("Failed to update user name: \(error.localizedDescription)")
            await MainActor.run {
                userName = oldName
            }
        }
    }
}

class ShareViewModel: ObservableObject {
    @Published var shouldShowInvitation: Bool = true

    private weak var invitationWindowController: AccountWebWindowController?

    var invitationDetailsURL: String {
        #if DEBUG
        if AuthManager.useStagingAuth0 {
            return "https://account.stag.phibrowser.com/invitation-code"
        } else {
            return "https://account.phibrowser.com/invitation-code"
        }
        #elseif NIGHTLY_BUILD
        return "https://account.stag.phibrowser.com/invitation-code"
        #else
        return "https://account.phibrowser.com/invitation-code"
        #endif
    }

    func openInvitationDetails() {
        // Close existing window if it's still open
        invitationWindowController?.close()

        // Create and show new window
        let windowController = AccountWebWindowController(url: invitationDetailsURL)
        invitationWindowController = windowController
        windowController.showWindow(nil)
    }
}

// MARK: - Profile Card View

class ProfileCardView: NSView {
    private enum Metrics {
        static let cardWidth: CGFloat = 240
        static let cardHeight: CGFloat = 380
        /// Extra padding around the card so the drop shadow has room to render
        /// instead of being clipped by the surrounding layout.
        static let shadowPadding: CGFloat = 10
    }
    
    private let cardImageView = NSImageView()
    private let cardContainerView = NSView()
    private let shadowLayer = CALayer()
    private lazy var downloadButton = NSButton(title: "", target: self, action: #selector(downloadProfileImage))
    private let profileCardViewController = ProfileCardViewController()
    var userInfo: Profile? {
        didSet {
            profileCardViewController.profile = userInfo
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.masksToBounds = false

        shadowLayer.backgroundColor = NSColor.white.cgColor
        shadowLayer.cornerRadius = 8
        shadowLayer.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.15
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        shadowLayer.shadowRadius = 6
        layer?.addSublayer(shadowLayer)

        cardContainerView.wantsLayer = true
        cardContainerView.layer?.cornerRadius = 8
        cardContainerView.layer?.borderWidth = 1
        cardContainerView.layer?.masksToBounds = true
        cardContainerView.phiLayer?.setBorderColor(Mapper<CGColor>(
            NSColor(white: 0, alpha: 0.13).cgColor,
            NSColor(white: 1, alpha: 0.22).cgColor
        ))
        
        addSubview(cardContainerView)
        cardContainerView.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.centerX.equalToSuperview()
            make.width.equalTo(Metrics.cardWidth)
            make.height.equalTo(Metrics.cardHeight)
        }

        cardContainerView.addSubview(profileCardViewController.view)
        profileCardViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        downloadButton.title = NSLocalizedString("settings.account.sharing.downloadImageButton", value: "Download image", comment: "Account settings - Button to download profile card as image")
        downloadButton.bezelStyle = .rounded
        downloadButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        downloadButton.imagePosition = .imageLeading
        addSubview(downloadButton)

        downloadButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(cardContainerView.snp.bottom).offset(Metrics.shadowPadding + 4)
            make.bottom.equalToSuperview()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = cardContainerView.frame
        shadowLayer.shadowPath = CGPath(
            roundedRect: shadowLayer.bounds,
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
        CATransaction.commit()
    }
    
    @objc private func downloadProfileImage() {
        profileCardViewController.snapshotAndExport()
    }
}

// MARK: - Default Browser Section View

private final class VerticallyCenteredTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawingRect = super.drawingRect(forBounds: rect)
        let contentHeight = min(
            ceil(cellSize(forBounds: rect).height),
            drawingRect.height
        )
        drawingRect.origin.y += (drawingRect.height - contentHeight) / 2
        drawingRect.size.height = contentHeight
        return drawingRect
    }
}

private final class WrappingButtonCell: NSButtonCell {
    func singleLineTitleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect)
    }

    func wrappedTitle(_ title: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: title)
        guard result.length > 0 else {
            return result
        }

        let existingStyle = result.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let paragraphStyle = existingStyle?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byWordWrapping
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let singleLineRect = singleLineTitleRect(forBounds: rect)
        guard attributedTitle.length > 0, singleLineRect.width > 0 else {
            return singleLineRect
        }

        let measuredRect = wrappedTitle(attributedTitle).boundingRect(
            with: NSSize(width: singleLineRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let height = min(ceil(measuredRect.height), max(0, rect.height - 8))
        return NSRect(
            x: singleLineRect.minX,
            y: rect.midY - height / 2,
            width: singleLineRect.width,
            height: height
        )
    }

    override func drawTitle(
        _ title: NSAttributedString,
        withFrame frame: NSRect,
        in controlView: NSView
    ) -> NSRect {
        wrappedTitle(title).draw(
            with: frame,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return frame
    }
}

class DefaultBrowserSectionView: SettingItemBackgroundView {
    private enum Layout {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 8
        static let spacing: CGFloat = 8
        static let buttonMaxWidth: CGFloat = 145
        static let fallbackWidth: CGFloat = 352
        static let minimumControlHeight: CGFloat = 24
    }

    private let statusLabel = NSTextField(labelWithString: "")
    private let setDefaultButton = NSButton()
    private let loadingIndicator = NSProgressIndicator()

    private let viewModel: DefaultBrowserViewModel
    private var cancellables = Set<AnyCancellable>()
    private var lastLayoutWidth: CGFloat = 0

    init(viewModel: DefaultBrowserViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupUI()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let availableWidth = bounds.width > 0 ? bounds.width : Layout.fallbackWidth
        let buttonWidth = min(setDefaultButton.intrinsicContentSize.width, Layout.buttonMaxWidth)
        let statusWidth = max(
            1,
            availableWidth
                - Layout.horizontalPadding * 2
                - Layout.spacing
                - buttonWidth
        )
        let statusHeight = statusLabel.attributedStringValue.boundingRect(
            with: NSSize(width: statusWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let buttonHeight = wrappedButtonHeight(for: buttonWidth)
        let controlHeight = max(
            Layout.minimumControlHeight,
            ceil(statusHeight),
            buttonHeight
        )
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: controlHeight + Layout.verticalPadding * 2
        )
    }

    override func layout() {
        let width = bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    private func setupUI() {
        statusLabel.cell = VerticallyCenteredTextFieldCell(textCell: "")
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.cell?.usesSingleLineMode = false
        statusLabel.cell?.wraps = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(statusLabel)

        // Loading indicator
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        addSubview(loadingIndicator)
        
        loadingIndicator.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }

        let title = NSLocalizedString("settings.account.defaultBrowser.setDefaultButton", value: "Set as default", comment: "Account settings - Button to set Phi as default browser")
        setDefaultButton.cell = WrappingButtonCell(textCell: title)
        setDefaultButton.title = title
        setDefaultButton.toolTip = title
        setDefaultButton.bezelStyle = .regularSquare
        setDefaultButton.cell?.usesSingleLineMode = false
        setDefaultButton.cell?.wraps = true
        setDefaultButton.cell?.lineBreakMode = .byWordWrapping
        setDefaultButton.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        setDefaultButton.imagePosition = .imageLeading
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setDefaultTapped)
        addSubview(setDefaultButton)

        let buttonWidth = min(
            setDefaultButton.intrinsicContentSize.width,
            Layout.buttonMaxWidth
        )
        setDefaultButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-Layout.horizontalPadding)
            make.centerY.equalToSuperview()
            make.top.greaterThanOrEqualToSuperview().inset(Layout.verticalPadding)
            make.bottom.lessThanOrEqualToSuperview().inset(Layout.verticalPadding)
            make.width.lessThanOrEqualTo(Layout.buttonMaxWidth)
            make.height.equalTo(wrappedButtonHeight(for: buttonWidth))
        }
        
        statusLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(Layout.horizontalPadding)
            make.top.bottom.equalToSuperview().inset(Layout.verticalPadding)
            make.trailing.equalTo(setDefaultButton.snp.leading).offset(-Layout.spacing)
        }
        
        // Initial state: show loading
        updateLoadingState(isLoading: true)
    }

    private func bindViewModel() {
        viewModel.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.statusLabel.stringValue = text
                self?.statusLabel.toolTip = text
                self?.invalidateIntrinsicContentSize()
            }
            .store(in: &cancellables)

        viewModel.$isDefaultBrowser
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDefault in
                self?.setDefaultButton.isEnabled = !isDefault
            }
            .store(in: &cancellables)
        
        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                self?.updateLoadingState(isLoading: isLoading)
            }
            .store(in: &cancellables)
    }
    
    private func updateLoadingState(isLoading: Bool) {
        if isLoading {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
            setDefaultButton.isHidden = true
            statusLabel.stringValue = ""
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
            setDefaultButton.isHidden = false
        }
        invalidateIntrinsicContentSize()
    }

    private func wrappedButtonHeight(for width: CGFloat) -> CGFloat {
        guard let cell = setDefaultButton.cell as? WrappingButtonCell else {
            return setDefaultButton.intrinsicContentSize.height
        }

        let measurementBounds = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: Layout.minimumControlHeight
        )
        let titleWidth = cell.singleLineTitleRect(forBounds: measurementBounds).width
        guard titleWidth > 0 else {
            return setDefaultButton.intrinsicContentSize.height
        }

        let titleHeight = cell.wrappedTitle(setDefaultButton.attributedTitle).boundingRect(
            with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return max(
            setDefaultButton.intrinsicContentSize.height,
            ceil(titleHeight) + 8
        )
    }

    @MainActor
    @objc private func setDefaultTapped() {
        Task {
           await viewModel.setAsDefault()
        }
    }
}

// MARK: - Account Card View

class AccountCardView: SettingItemBackgroundView {

    // MARK: Subviews

    private let avatarContainerView = NSView()
    private let avatarImageView = NSImageView()
    private let avatarEditButton: NSView = {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = false
        container.alphaValue = 0

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit avatar")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        icon.imageScaling = .scaleNone
        icon.tag = 1001
        container.addSubview(icon)
        icon.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        return container
    }()

    private let nameHoverArea = NSView()

    private let nameLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 16, weight: .medium)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.backgroundColor = .clear
        return tf
    }()

    private let nameEditIconButton: NSButton = {
        let btn = NSButton()
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit name")
        btn.imageScaling = .scaleProportionallyUpOrDown
        btn.alphaValue = 0
        return btn
    }()

    private let emailLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.font = .systemFont(ofSize: 11, weight: .regular)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        return tf
    }()

    private let reauthenticationWarningLabel: NSTextField = {
        let tf = NSTextField(labelWithString: NSLocalizedString("settings.account.reauthentication.warning", value: "Reauthentication needed.",
            comment: "Account settings - Warning shown when account tokens require reauthentication"
        ))
        tf.font = .systemFont(ofSize: 11, weight: .medium)
        tf.textColor = .systemOrange
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isHidden = true
        tf.toolTip = NSLocalizedString("settings.account.reauthentication.tooltip", value: "Please reauthenticate to restore account features.",
            comment: "Account settings - Tooltip explaining why reauthentication is needed"
        )
        return tf
    }()

    private let logoutStatusLabel: NSTextField = {
        let tf = NSTextField(labelWithString: NSLocalizedString("settings.account.logoutProgress.browserConfirmationStatus", value: "Finish signing out in your browser.",
            comment: "Account settings - Status shown while waiting for sign-out to finish"
        ))
        tf.font = .systemFont(ofSize: 11, weight: .medium)
        tf.textColor = .secondaryLabelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.isEditable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.isHidden = true
        return tf
    }()

    private let logoutButton: NSButton = {
        let btn = NSButton()
        btn.title = NSLocalizedString("settings.account.logoutButton", value: "Sign out", comment: "Account settings - Sign-out button")
        btn.bezelStyle = .rounded
        btn.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)
        btn.imagePosition = .imageLeading
        return btn
    }()

    private let loginButton: NSButton = {
        let btn = NSButton()
        btn.title = NSLocalizedString(
            "settings.account.guest.loginButton",
            value: "Sign in",
            comment: "Account settings - Button shown in the Guest account card to open sign-in"
        )
        btn.bezelStyle = .rounded
        btn.isHidden = true
        return btn
    }()

    private let loadingIndicator: NSProgressIndicator = {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        return indicator
    }()

    // MARK: State

    var onUserNameUpdated: ((String) -> Void)?
    var onAvatarEdit: (() -> Void)?
    var logoutAction: (() -> Void)?
    var loginAction: (() -> Void)?
    var reauthenticationAction: (() -> Void)?

    private var isAvatarHovered = false
    private var isNameHovered = false
    private var canEdit = false
    private var isGuestPresentation = false
    private var showsReauthenticationWarning = false
    private var isLogoutInProgress = false
    private var avatarRevalidateTask: DownloadTask?

    private static let maxUserNameLength = 100

    private let viewModel: AccountViewModel
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    init(viewModel: AccountViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupSubviews()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Layout

    private func setupSubviews() {
        // Avatar container (56x56)
        addSubview(avatarContainerView)
        avatarContainerView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.size.equalTo(56)
        }

        // Avatar image (fills container, container's masksToBounds handles clipping)
        avatarContainerView.addSubview(avatarImageView)
        avatarImageView.imageScaling = .scaleProportionallyUpOrDown
        avatarImageView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Avatar")?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        avatarImageView.contentTintColor = .secondaryLabelColor
        avatarImageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        avatarImageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        avatarImageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        avatarImageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        avatarImageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        // Avatar edit button (16x16, bottom-right of avatar, added to self to avoid container clipping)
        addSubview(avatarEditButton)
        avatarEditButton.snp.makeConstraints { make in
            make.right.bottom.equalTo(avatarContainerView)
            make.size.equalTo(16)
        }

        // Avatar edit button click gesture
        let avatarEditClick = NSClickGestureRecognizer(target: self, action: #selector(avatarTapped))
        avatarEditButton.addGestureRecognizer(avatarEditClick)

        // Logout button (right side)
        logoutButton.target = self
        logoutButton.action = #selector(logoutTapped)
        logoutButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        logoutButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(logoutButton)
        logoutButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
        }

        loginButton.target = self
        loginButton.action = #selector(loginTapped)
        loginButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        loginButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(loginButton)
        loginButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
        }

        // Loading indicator (same position as logout button)
        addSubview(loadingIndicator)
        loadingIndicator.snp.makeConstraints { make in
            make.center.equalTo(logoutButton)
            make.size.equalTo(16)
        }

        // Name hover area (invisible, covers name + edit icon region)
        addSubview(nameHoverArea)
        nameHoverArea.snp.makeConstraints { make in
            make.left.equalTo(avatarContainerView.snp.right)
            make.top.equalToSuperview()
            make.bottom.equalTo(snp.centerY)
            make.right.equalTo(logoutButton.snp.left).offset(-4)
        }

        // Name label + edit icon
        nameHoverArea.addSubview(nameLabel)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(12)
            make.bottom.equalToSuperview().offset(-2)
        }

        nameHoverArea.addSubview(nameEditIconButton)
        nameEditIconButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameEditIconButton.target = self
        nameEditIconButton.action = #selector(nameEditTapped)
        nameEditIconButton.snp.makeConstraints { make in
            make.left.equalTo(nameLabel.snp.right).offset(4)
            make.centerY.equalTo(nameLabel)
            make.right.lessThanOrEqualToSuperview()
            make.size.equalTo(11)
        }

        // Email label
        addSubview(emailLabel)
        emailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emailLabel.snp.makeConstraints { make in
            make.left.equalTo(avatarContainerView.snp.right).offset(12)
            make.top.equalTo(snp.centerY).offset(2)
            make.right.lessThanOrEqualTo(logoutButton.snp.left).offset(-8)
        }

        addSubview(logoutStatusLabel)
        logoutStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logoutStatusLabel.snp.makeConstraints { make in
            make.left.equalTo(emailLabel)
            make.top.equalTo(emailLabel.snp.bottom).offset(2)
            make.right.lessThanOrEqualToSuperview().offset(-12)
        }

        addSubview(reauthenticationWarningLabel)
        reauthenticationWarningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        reauthenticationWarningLabel.snp.makeConstraints { make in
            make.left.equalTo(emailLabel)
            make.top.equalTo(emailLabel.snp.bottom).offset(2)
            make.right.lessThanOrEqualTo(logoutButton.snp.left).offset(-8)
        }

        setupTrackingAreas()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAvatarEditButtonAppearance()
    }

    override func layout() {
        super.layout()
        updateAvatarEditButtonAppearance()
    }

    private func updateAvatarEditButtonAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        avatarEditButton.layer?.backgroundColor = (isDark ? NSColor.darkGray : NSColor.white).cgColor
        avatarEditButton.layer?.shadowColor = NSColor.black.cgColor
        avatarEditButton.layer?.shadowOpacity = isDark ? 0.5 : 0.3
        avatarEditButton.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        avatarEditButton.layer?.shadowRadius = 1.25

        if let icon = avatarEditButton.subviews.first(where: { $0.tag == 1001 }) as? NSImageView {
            icon.contentTintColor = isDark ? .white : .black
        }
    }

    // MARK: ViewModel binding

    private func bindViewModel() {
        viewModel.$userName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                guard let self, !self.isGuestPresentation else { return }
                self.nameLabel.stringValue = name
            }
            .store(in: &cancellables)

        viewModel.$userEmail
            .receive(on: DispatchQueue.main)
            .sink { [weak self] email in
                guard let self, !self.isGuestPresentation else { return }
                self.emailLabel.stringValue = email
            }
            .store(in: &cancellables)

        viewModel.$avatarURL
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] urlString in
                guard let self,
                      !self.isGuestPresentation,
                      let url = URL(string: urlString),
                      !urlString.isEmpty else { return }
                // Use the current image as placeholder so it stays visible on cache miss
                let placeholder = self.avatarImageView.image
                    ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Avatar")?
                        .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
                let processor = AccountController.avatarImageProcessor

                // Show cached version immediately (or keep current image if no cache)
                self.avatarImageView.kf.setImage(
                    with: url,
                    placeholder: placeholder,
                    options: [
                        .processor(processor),
                        .onlyFromCache
                    ]
                )
            }
            .store(in: &cancellables)

        viewModel.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self, !self.isGuestPresentation else { return }
                self.updateLoadingState(isLoading)
            }
            .store(in: &cancellables)

        viewModel.$canEditUserName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canEdit in
                guard let self, !self.isGuestPresentation else { return }
                self.canEdit = canEdit
            }
            .store(in: &cancellables)

        viewModel.$isLogoutInProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLogoutInProgress in
                guard let self, !self.isGuestPresentation else { return }
                self.updateLogoutButtonState(isLogoutInProgress)
            }
            .store(in: &cancellables)
    }

    private func updateLoadingState(_ isLoading: Bool) {
        guard !isGuestPresentation else { return }
        if isLoading {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
            logoutButton.isHidden = true
            loginButton.isHidden = true
            nameLabel.isHidden = true
            emailLabel.isHidden = true
            logoutStatusLabel.isHidden = true
            reauthenticationWarningLabel.isHidden = true
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
            updateActionButtonVisibility()
            nameLabel.isHidden = false
            emailLabel.isHidden = false
            updateStatusLineVisibility()
        }
    }

    func updateReauthenticationWarning(isVisible: Bool) {
        showsReauthenticationWarning = isVisible
        updateActionButtonVisibility()
        updateStatusLineVisibility()
    }

    func updateGuestPresentation(_ isGuest: Bool) {
        guard isGuestPresentation != isGuest else { return }
        isGuestPresentation = isGuest
        updateNameLayout(isGuest: isGuest)
        avatarRevalidateTask?.cancel()
        avatarRevalidateTask = nil
        canEdit = isGuest ? false : viewModel.canEditUserName
        avatarEditButton.alphaValue = 0
        nameEditIconButton.alphaValue = 0

        if isGuest {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
            logoutButton.isHidden = true
            loginButton.isHidden = false
            nameLabel.isHidden = false
            emailLabel.isHidden = true
            logoutStatusLabel.isHidden = true
            reauthenticationWarningLabel.isHidden = true
            nameLabel.stringValue = NSLocalizedString(
                "settings.account.guest.title",
                value: "You’re using Phi without signing in",
                comment: "Account settings - Title of the Guest account card"
            )
            avatarImageView.image = NSImage(
                systemSymbolName: "person.crop.circle.fill",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
            avatarImageView.contentTintColor = .secondaryLabelColor
        } else {
            loginButton.isHidden = true
            nameLabel.stringValue = viewModel.userName
            emailLabel.stringValue = viewModel.userEmail
            updateLoadingState(viewModel.isLoading)
            updateLogoutButtonState(viewModel.isLogoutInProgress)
        }
    }

    private func updateNameLayout(isGuest: Bool) {
        nameHoverArea.snp.remakeConstraints { make in
            make.left.equalTo(avatarContainerView.snp.right)
            make.right.equalTo(logoutButton.snp.left).offset(-4)
            make.top.equalToSuperview()
            if isGuest {
                make.bottom.equalToSuperview()
            } else {
                make.bottom.equalTo(snp.centerY)
            }
        }

        nameLabel.snp.remakeConstraints { make in
            make.left.equalToSuperview().offset(12)
            if isGuest {
                make.centerY.equalToSuperview()
            } else {
                make.bottom.equalToSuperview().offset(-2)
            }
        }
    }

    private func updateLogoutButtonState(_ isInProgress: Bool) {
        isLogoutInProgress = isInProgress
        logoutButton.isEnabled = !isInProgress
        logoutButton.alphaValue = isInProgress ? 0.5 : 1.0
        updateStatusLineVisibility()
    }

    private func updateActionButtonVisibility() {
        guard !isGuestPresentation, loadingIndicator.isHidden else { return }
        logoutButton.isHidden = showsReauthenticationWarning
        loginButton.isHidden = !showsReauthenticationWarning
    }

    private func updateStatusLineVisibility() {
        guard !isGuestPresentation else {
            logoutStatusLabel.isHidden = true
            reauthenticationWarningLabel.isHidden = true
            return
        }
        let isLoading = !loadingIndicator.isHidden
        logoutStatusLabel.isHidden = isLoading || !isLogoutInProgress
        reauthenticationWarningLabel.isHidden = isLoading || isLogoutInProgress || !showsReauthenticationWarning
    }

    // MARK: Avatar revalidation

    func revalidateAvatar() {
        guard !isGuestPresentation else { return }
        let urlString = viewModel.avatarURL
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }

        avatarRevalidateTask?.cancel()

        let processor = AccountController.avatarImageProcessor
        avatarRevalidateTask = KingfisherManager.shared.retrieveImage(
            with: url,
            options: [
                .forceRefresh,
                .processor(processor)
            ]
        ) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result {
                DispatchQueue.main.async {
                    self.avatarImageView.image = value.image
                }
            }
        }
    }

    /// Instantly display a locally-provided avatar image (e.g. from the WKWebView editor),
    /// bypassing any network round-trip.
    func setAvatarImage(_ image: NSImage) {
        guard !isGuestPresentation else { return }
        avatarRevalidateTask?.cancel()
        let size = image.size
        let circularImage = NSImage(size: size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
        avatarImageView.image = circularImage
    }

    // MARK: Hover tracking

    private func setupTrackingAreas() {
        // Use .inVisibleRect so the tracking area automatically matches the
        // view's visible rect, even before layout has run (fixes the issue
        // where hover doesn't work when the window first appears via Cmd+,).
        let avatarArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["zone": "avatar"]
        )
        avatarContainerView.addTrackingArea(avatarArea)

        let nameArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["zone": "name"]
        )
        nameHoverArea.addTrackingArea(nameArea)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard canEdit else { return }
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "avatar" {
            isAvatarHovered = true
            animateAlpha(of: avatarEditButton, to: 1)
        } else if zone == "name" {
            isNameHovered = true
            animateAlpha(of: nameEditIconButton, to: 1)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let zone = (event.trackingArea?.userInfo?["zone"] as? String) ?? ""
        if zone == "avatar" {
            isAvatarHovered = false
            animateAlpha(of: avatarEditButton, to: 0)
        } else if zone == "name" {
            isNameHovered = false
            animateAlpha(of: nameEditIconButton, to: 0)
        }
    }

    private func animateAlpha(of view: NSView, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            view.animator().alphaValue = alpha
        }
    }

    // MARK: Avatar editing

    @objc private func avatarTapped() {
        guard canEdit else { return }
        onAvatarEdit?()
    }

    // MARK: Name editing

    @objc private func nameEditTapped() {
        guard canEdit else { return }
        showRenameDialog()
    }

    private func showRenameDialog() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("settings.account.renameDialog.title", value: "Change Name", comment: "Account settings - Dialog title for changing user name")
        alert.addButton(withTitle: NSLocalizedString("settings.account.renameDialog.saveButton", value: "Save", comment: "Account settings - Save button in rename dialog"))
        alert.addButton(withTitle: NSLocalizedString("settings.account.renameDialog.cancelButton", value: "Cancel", comment: "Account settings - Cancel button in rename dialog"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = viewModel.userName
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newValue = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if newValue.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("settings.account.renameDialog.emptyNameError.title", value: "Invalid Input", comment: "Account settings - Alert title for invalid input")
            errorAlert.informativeText = NSLocalizedString("settings.account.renameDialog.emptyNameError.message", value: "Name cannot be empty", comment: "Account settings - Error message when user name is empty")
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("settings.account.renameDialog.emptyNameError.dismissButton", value: "OK", comment: "Account settings - OK button"))
            errorAlert.runModal()
            return
        }

        if newValue.count > Self.maxUserNameLength {
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("settings.account.renameDialog.nameTooLongError.title", value: "Invalid Input", comment: "Account settings - Alert title for invalid input")
            errorAlert.informativeText = String(format: NSLocalizedString("settings.account.renameDialog.nameTooLongError.message", value: "Name cannot exceed %d characters", comment: "Account settings - Error message when user name is too long"), Self.maxUserNameLength)
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("settings.account.renameDialog.nameTooLongError.dismissButton", value: "OK", comment: "Account settings - OK button"))
            errorAlert.runModal()
            return
        }

        if newValue != viewModel.userName {
            onUserNameUpdated?(newValue)
            Task {
                await viewModel.updateUserName(newValue)
            }
        }
    }

    // MARK: Logout

    @objc private func logoutTapped() {
        guard !isLogoutInProgress else { return }
        logoutAction?()
    }

    @objc private func loginTapped() {
        if showsReauthenticationWarning {
            reauthenticationAction?()
        } else {
            loginAction?()
        }
    }
}

// MARK: - Share Section View

class ShareSectionView: NSView {
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("settings.account.sharing.sectionTitle", value: "Share", comment: "Account settings - Section title for sharing"))
    private let containerView = SettingItemBackgroundView()

    private let invitationCodeRowView = InvitationCodeRowView()

    private let viewModel: ShareViewModel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: ShareViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupUI()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        titleLabel.snp.makeConstraints { make in
            make.top.left.equalToSuperview()
            make.height.equalTo(20)
        }

        addSubview(containerView)

        containerView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(12)
            make.left.right.bottom.equalToSuperview()
        }

        containerView.addSubview(invitationCodeRowView)

        invitationCodeRowView.snp.makeConstraints { make in
            make.top.left.right.bottom.equalToSuperview()
            make.height.equalTo(42)
        }

        invitationCodeRowView.onViewDetails = { [weak self] in
            self?.viewModel.openInvitationDetails()
        }
    }

    private func bindViewModel() {
        // No bindings needed - View Details button is always visible
    }
}

// MARK: - Invitation Code Row View

class InvitationCodeRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("settings.account.invitationCode.fieldLabel", value: "Invitation Code", comment: "Account settings - Label for invitation code field"))
    private let viewDetailsButton = NSButton()

    var onViewDetails: (() -> Void)?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }
    
    private func setupUI() {
        // Title label
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)
        
        titleLabel.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview().offset(12)
        }

        // View Details button
        viewDetailsButton.title = NSLocalizedString("settings.account.invitationCode.viewDetailsButton", value: "View Details", comment: "Account settings - Button to view invitation code details")
        viewDetailsButton.bezelStyle = .rounded
        viewDetailsButton.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: nil)
        viewDetailsButton.imagePosition = .imageLeading
        viewDetailsButton.target = self
        viewDetailsButton.action = #selector(viewDetailsButtonTapped)
        addSubview(viewDetailsButton)

        viewDetailsButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
        }
    }

    @objc private func viewDetailsButtonTapped() {
        onViewDetails?()
    }
}
