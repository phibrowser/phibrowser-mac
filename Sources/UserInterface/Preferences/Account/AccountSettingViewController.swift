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
        let fullName: String
        if !accountViewModel.userName.isEmpty {
            fullName = accountViewModel.userName
        } else if let cachedUserName = AccountController.shared.account?.userDefaults.string(forKey: AccountUserDefaults.DefaultsKey.cachedUserName.rawValue),
                  cachedUserName.isEmpty == false {
            fullName = cachedUserName
        } else {
            return NSLocalizedString("You", comment: "Account settings - Default display name when user name is not available")
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

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.phiLayer?.setBackgroundColor(.windowBackground)
        view.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 680, height: 561))
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindViewModel()
    }


    override func viewWillAppear() {
        super.viewWillAppear()
        
        AppLogDebug("👁️ [AccountSettings] viewWillAppear called")
        
        // Check if user is logged in before loading data
        let isLoggedIn = LoginController.shared.isLoggedin()
        AppLogDebug("👁️ [AccountSettings] Login status check: \(isLoggedIn)")
        
        guard isLoggedIn else {
            AppLogDebug("👁️ [AccountSettings] Not logged in, skipping data load")
            return
        }
        
        AppLogDebug("👁️ [AccountSettings] Starting data load...")
        accountView.revalidateAvatar()
        Task {
            // Load all data in parallel using async let
            async let userInfo: Profile? = accountViewModel.loadUserInfo()

            // Start browser check immediately (it's not async)
            defaultBrowserViewModel.checkDefaultBrowser()
            let profile = await userInfo
            profileCardView.userInfo = profile
            // Revalidate avatar after user info is loaded (avatarURL may have been empty before)
            accountView.revalidateAvatar()
            AppLogDebug("👁️ [AccountSettings] Data load completed")
        }
    }

    private func setupUI() {
        // Profile card on the left
        view.addSubview(profileCardView)
        profileCardView.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(36)
            make.top.equalToSuperview().offset(36)
            make.width.equalTo(240)
        }

        // Right side container
        let rightContainer = NSView()
        view.addSubview(rightContainer)

        rightContainer.snp.makeConstraints { make in
            make.left.equalTo(profileCardView.snp.right).offset(16)
            make.top.equalToSuperview().offset(36)
            make.right.equalToSuperview().offset(-36)
            make.bottom.lessThanOrEqualToSuperview().offset(-36)
            make.width.greaterThanOrEqualTo(352)
        }

        // Account card (top)
        rightContainer.addSubview(accountView)
        accountView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.height.equalTo(80)
        }

        // Default browser section
        rightContainer.addSubview(defaultBrowserView)
        defaultBrowserView.snp.makeConstraints { make in
            make.top.equalTo(accountView.snp.bottom).offset(20)
            make.left.right.equalToSuperview()
            make.height.equalTo(42)
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
    }

    private func openAvatarEditor() {
        avatarWindowController?.close()

        var avatarWasSaved = false
        let windowController = AccountWebWindowController(url: avatarEditURL)
        avatarWindowController = windowController
        windowController.onAvatarSaved = { [weak self] image in
            self?.accountView.setAvatarImage(image)
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
                self?.shareView.isHidden = !shouldShow
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
    }
}


// MARK: - ViewModels

class DefaultBrowserViewModel: ObservableObject {
    @Published var isDefaultBrowser: Bool = false
    @Published var statusText: String = NSLocalizedString("Phi is not your default browser", comment: "Account settings - Status text when Phi is not the default browser")
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
        statusText = isDefaultBrowser ? NSLocalizedString("Phi is your default browser", comment: "Account settings - Status text when Phi is the default browser") : NSLocalizedString("Phi is not your default browser", comment: "Account settings - Status text when Phi is not the default browser")
    }
}

class AccountViewModel: ObservableObject {
    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var avatarURL: String = ""
    @Published var isLoading: Bool = true
    @Published var canEditUserName: Bool = false

    var cancellables = Set<AnyCancellable>()
    
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
            if resp.code == 0 {
                let profile = resp.data
                // Refresh the cached copy with the latest network response.
                cacheProfile(profile)
                AppLogInfo("📦 [AccountSettings] Cached profile from network: \(profile.name)")
                
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
        alert.messageText = NSLocalizedString("Confirm Logout", comment: "Account settings - Logout confirmation dialog title")
        alert.informativeText = NSLocalizedString("You will be logged out and returned to the login screen. Are you sure?", comment: "Account settings - Logout confirmation dialog message")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Account settings - Cancel button in logout confirmation dialog"))
        alert.addButton(withTitle: NSLocalizedString("Logout", comment: "Account settings - Logout button in logout confirmation dialog"))
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
    
    @MainActor
    private func showLogoutFailedAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Logout Failed", comment: "Account settings - Alert title when logout fails")
        alert.informativeText = NSLocalizedString("Something went wrong when logging out", comment: "Account settings - Alert message when logout fails")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Account settings - OK button to dismiss logout failed alert"))
        alert.runModal()
    }

    @MainActor
    func logout() async {
        AppLogDebug("🚪 [Logout] Starting logout flow")
        
        // Step 1: confirm logout.
        AppLogDebug("🚪 [Logout] Step 1: Showing confirmation dialog")
        guard showLogoutConfirmation() else {
            AppLogDebug("🚪 [Logout] User cancelled logout")
            return
        }
        
        AppLogDebug("🚪 [Logout] User confirmed logout, proceeding...")
        
        // Step 3: clear the Auth0 session and credentials.
        AppLogDebug("🚪 [Logout] Step 3: Clearing Auth0 session and credentials")
        let success = await AuthManager.shared.logOut()
        guard success else {
            AppLogError("🚪 [Logout] Auth0 logout failed")
            showLogoutFailedAlert()
            return
        }
        AppLogDebug("🚪 [Logout] Auth0 session cleared")
        
        // Step 4: clear local account state.
        AppLogDebug("🚪 [Logout] Step 4: Clearing account controller state")
        let previousAccount = AccountController.shared.account?.userID
        AccountController.shared.account = nil
        AppLogDebug("🚪 [Logout] Account state cleared (was: \(previousAccount ?? "nil"))")
        
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

    func updateUserName(_ newName: String) async {
        let oldName = userName

        // Optimistic update: reflect immediately in UI
        await MainActor.run {
            userName = newName
        }

        // Revalidate via API
        do {
            let request = UpdateProfileRequest(name: newName)
            let resp = try await APIClient.shared.updateProfile(updates: request)

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
    private let cardImageView = NSImageView()
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
        
        addSubview(profileCardViewController.view)
        profileCardViewController.view.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.height.equalTo(380)
        }

        downloadButton.title = NSLocalizedString("Download images", comment: "Account settings - Button to download profile card as image")
        downloadButton.bezelStyle = .rounded
        downloadButton.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        downloadButton.imagePosition = .imageLeading
        addSubview(downloadButton)

        downloadButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalTo(profileCardViewController.view.snp.bottom).offset(10)
            make.bottom.equalToSuperview()
        }
    }
    
    @objc private func downloadProfileImage() {
        profileCardViewController.snapshotAndExport()
    }
}

// MARK: - Default Browser Section View

class DefaultBrowserSectionView: SettingItemBackgroundView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let setDefaultButton = NSButton()
    private let loadingIndicator = NSProgressIndicator()

    private let viewModel: DefaultBrowserViewModel
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: DefaultBrowserViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        setupUI()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        addSubview(statusLabel)

        statusLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
        }

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

        setDefaultButton.title = NSLocalizedString("Set as default", comment: "Account settings - Button to set Phi as default browser")
        setDefaultButton.bezelStyle = .rounded
        setDefaultButton.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
        setDefaultButton.imagePosition = .imageLeading
        setDefaultButton.target = self
        setDefaultButton.action = #selector(setDefaultTapped)
        addSubview(setDefaultButton)

        setDefaultButton.snp.makeConstraints { make in
            make.right.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
        }
        
        // Initial state: show loading
        updateLoadingState(isLoading: true)
    }

    private func bindViewModel() {
        viewModel.$statusText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.statusLabel.stringValue = text
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

    private let logoutButton: NSButton = {
        let btn = NSButton()
        btn.title = NSLocalizedString("Logout", comment: "Account settings - Logout button")
        btn.bezelStyle = .rounded
        btn.image = NSImage(systemSymbolName: "rectangle.portrait.and.arrow.right", accessibilityDescription: nil)
        btn.imagePosition = .imageLeading
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

    private var isAvatarHovered = false
    private var isNameHovered = false
    private var canEdit = false
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
        addSubview(logoutButton)
        logoutButton.snp.makeConstraints { make in
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
        nameLabel.snp.makeConstraints { make in
            make.left.equalToSuperview().offset(12)
            make.bottom.equalToSuperview().offset(-2)
        }

        nameHoverArea.addSubview(nameEditIconButton)
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
        emailLabel.snp.makeConstraints { make in
            make.left.equalTo(avatarContainerView.snp.right).offset(12)
            make.top.equalTo(snp.centerY).offset(2)
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
                self?.nameLabel.stringValue = name
            }
            .store(in: &cancellables)

        viewModel.$userEmail
            .receive(on: DispatchQueue.main)
            .sink { [weak self] email in
                self?.emailLabel.stringValue = email
            }
            .store(in: &cancellables)

        viewModel.$avatarURL
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] urlString in
                guard let self, let url = URL(string: urlString), !urlString.isEmpty else { return }
                // Use the current image as placeholder so it stays visible on cache miss
                let placeholder = self.avatarImageView.image
                    ?? NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: "Avatar")?
                        .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
                let processor = RoundCornerImageProcessor(radius: .widthFraction(0.5))

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
                self?.updateLoadingState(isLoading)
            }
            .store(in: &cancellables)

        viewModel.$canEditUserName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canEdit in
                self?.canEdit = canEdit
            }
            .store(in: &cancellables)
    }

    private func updateLoadingState(_ isLoading: Bool) {
        if isLoading {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
            logoutButton.isHidden = true
            nameLabel.isHidden = true
            emailLabel.isHidden = true
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
            logoutButton.isHidden = false
            nameLabel.isHidden = false
            emailLabel.isHidden = false
        }
    }

    // MARK: Avatar revalidation

    func revalidateAvatar() {
        let urlString = viewModel.avatarURL
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }

        avatarRevalidateTask?.cancel()

        let processor = RoundCornerImageProcessor(radius: .widthFraction(0.5))
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
        alert.messageText = NSLocalizedString("Change Name", comment: "Account settings - Dialog title for changing user name")
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Account settings - Save button in rename dialog"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Account settings - Cancel button in rename dialog"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = viewModel.userName
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newValue = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if newValue.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("Invalid Input", comment: "Account settings - Alert title for invalid input")
            errorAlert.informativeText = NSLocalizedString("Name cannot be empty", comment: "Account settings - Error message when user name is empty")
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("OK", comment: "Account settings - OK button"))
            errorAlert.runModal()
            return
        }

        if newValue.count > Self.maxUserNameLength {
            let errorAlert = NSAlert()
            errorAlert.messageText = NSLocalizedString("Invalid Input", comment: "Account settings - Alert title for invalid input")
            errorAlert.informativeText = String(format: NSLocalizedString("Name cannot exceed %d characters", comment: "Account settings - Error message when user name is too long"), Self.maxUserNameLength)
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: NSLocalizedString("OK", comment: "Account settings - OK button"))
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
        logoutAction?()
    }
}

// MARK: - Share Section View

class ShareSectionView: NSView {
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("Share", comment: "Account settings - Section title for sharing"))
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
    private let titleLabel = NSTextField(labelWithString: NSLocalizedString("Invitation Code", comment: "Account settings - Label for invitation code field"))
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
        viewDetailsButton.title = NSLocalizedString("View Details", comment: "Account settings - Button to view invitation code details")
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
