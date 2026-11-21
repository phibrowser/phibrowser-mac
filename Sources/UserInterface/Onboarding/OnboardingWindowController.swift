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
    private(set) var presentsGuestMigrationRecovery = false
    private let analyticsSession = OOBEAnalyticsSession()

    private(set) lazy var loginViewController: LoginViewController = {
        let vc = LoginViewController()
        vc.presentationMode = presentsGuestMigrationRecovery
            ? .guestMigrationRecovery
            : .standard
        vc.onLoginSuccess = { [weak self] credentials in
            guard let credentials, let self else { return }
            self.routeToCurrentPhase(using: credentials)
        }
        vc.onContinueAsGuest = { [weak self] in
            self?.showGuestPrivacyConfirmation()
        }
        return vc
    }()

    private lazy var guestPrivacyConfirmationViewController: GuestPrivacyConfirmationViewController = {
        let vc = GuestPrivacyConfirmationViewController()
        vc.onSignIn = { [weak self] in
            guard let self else { return }
            self.setContent(self.loginViewController, completesCurrentStep: false)
        }
        vc.onConfirm = { [weak self, weak vc] sharesUsageMetrics in
            Task { @MainActor [weak self, weak vc] in
                guard ChromiumLauncher.sharedInstance().bridge != nil else {
                    AppLogError(
                        "[GuestPrivacy] Cannot enter Guest Mode before the Chromium bridge is ready"
                    )
                    vc?.resetAfterGuestEntryFailure()
                    return
                }

                let result = LoginController.shared.continueAsGuest(
                    metricsReportingPreference: sharesUsageMetrics
                )
                switch result {
                case .enteredGuestMode:
                    return
                case .requiresAccountRecovery:
                    guard let self else { return }
                    self.setContent(
                        self.loginViewController,
                        completesCurrentStep: false
                    )
                case .failed:
                    vc?.resetAfterGuestEntryFailure()
                }
            }
        }
        return vc
    }()
    
    private lazy var welcomeViewController: OnboardingWelcomeViewController = {
        let vc = OnboardingWelcomeViewController()
        vc.leftButtonClosure = { [weak self] in
            self?.showPreviousStep(.setName)
        }
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
        vc.leftButtonClosure = { [weak self] in
            self?.showPreviousStep(.setTheme)
        }
        vc.nextClosure = { [weak self] _ in
            guard let self else { return }
            self.showPasswordManagerPage()
        }
        return vc
    }()

    private lazy var passwordManagerViewController: PasswordManagerViewController = {
        let vc = PasswordManagerViewController()
        vc.leftButtonClosure = { [weak self] in
            self?.showPreviousStep(.layoutSelection)
        }
        vc.nextClosure = { [weak self] _ in
            self?.showNextStepPage()
        }
        return vc
    }()

    private lazy var nextStepViewController: NextStepViewController = {
        let vc = NextStepViewController()
        vc.leftButtonClosure = { [weak self] in
            self?.showPreviousStep(.passwordManager)
        }
        vc.nextClosure = { [weak self] _ in
            self?.finish()
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
    
    /// Hosts every page at the fixed design size and scales it down to fit
    /// the screen. Nil for a window supplied by the caller, whose pages are
    /// set as its content view controller directly.
    private var scalingContainer: OnboardingScalingContainerViewController?

    convenience init(presentsGuestMigrationRecovery: Bool = false) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingScalingContainerViewController.designSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.animationBehavior = .default

        
        self.init(window: window)
        HolographicCardView.prepareArtwork()
        self.presentsGuestMigrationRecovery = presentsGuestMigrationRecovery
        let container = OnboardingScalingContainerViewController()
        scalingContainer = container
        contentViewController = container
        setupContentViewController()
        fitToScreen()
    }

    /// Scales the window so the whole page fits the target screen's visible
    /// frame (between the menu bar and the Dock). Full size wherever 640×800
    /// already fits; uniformly smaller on short displays such as a 13" laptop.
    func fitToScreen(_ screen: NSScreen? = nil) {
        guard let window, let scalingContainer,
              let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let size = scalingContainer.fittedSize(in: visible)
        guard window.contentRect(forFrameRect: window.frame).size != size else { return }
        window.setContentSize(size)
    }

    /// The page on screen, whether hosted in the scaling container or set
    /// directly as the window's content view controller.
    private var currentPage: NSViewController? {
        scalingContainer?.page ?? window?.contentViewController
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
            }

            if let storedUserInfo = AuthManager.shared.storedUserInfo() {
                LoginController.shared.initAcoountWithUserInfo(storedUserInfo)
                let loginPhase = LoginController.shared.phase
                guard loginPhase != .done else {
                    DispatchQueue.main.async { [weak self] in
                        self?.finish()
                    }
                    return loginViewController
                }
                return viewController(for: loginPhase, credentials: nil, isFirstPage: true)
            }

            return loginViewController
        }()
        show(contentVc)
    }

    private func show(_ page: NSViewController) {
        if let scalingContainer {
            scalingContainer.show(page)
        } else {
            window?.contentViewController = page
        }
    }
    
    // MARK: - Content Management

    private func setContent(
        _ vc: NSViewController,
        completesCurrentStep: Bool = true
    ) {
        if completesCurrentStep {
            analyticsSession.completeCurrentStep()
        }
        show(vc)
        recordCurrentStepViewed()
    }

    func recordCurrentStepViewed() {
        guard window?.isVisible == true,
              let viewController = currentPage,
              let step = analyticsStep(for: viewController) else {
            return
        }
        analyticsSession.present(step)
    }

    func completeAuthenticatedOOBE() {
        analyticsSession.finish(isGuest: false)
    }

    func completeGuestOOBE() {
        PhiPreferences.GeneralSettings.saveLayoutMode(.comfortable)
        UserDefaults.standard.set(false, forKey: PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
        analyticsSession.finish(isGuest: true, stepsCompleted: 2)
    }

    func recordUserInterruption() {
        analyticsSession.interrupt(reason: .windowClosed)
    }

    func recordAppTermination() {
        analyticsSession.interrupt(reason: .appTerminated)
    }

    func suppressOOBEInterruption() {
        analyticsSession.suppressInterruption()
    }

    private func analyticsStep(
        for viewController: NSViewController
    ) -> OOBEAnalyticsSession.Step? {
        switch viewController {
        case is LoginViewController:
            return .login
        case is SetNameViewController:
            return .setName
        case is OnboardingWelcomeViewController:
            return .setTheme
        case is LayoutSelectionViewController:
            return .layoutSelection
        case is PasswordManagerViewController:
            return .passwordManager
        case is NextStepViewController:
            return .nextStep
        case is GuestPrivacyConfirmationViewController:
            return .guestPrivacy
        default:
            return nil
        }
    }
    
    private func routeToCurrentPhase(using credentials: Credentials) {
        let loginPhase = LoginController.shared.phase
        guard loginPhase != .done else {
            finish()
            return
        }

        setContent(viewController(for: loginPhase, credentials: credentials, isFirstPage: false))
    }

    func viewController(for phase: LoginController.Phase, credentials: Credentials?, isFirstPage: Bool) -> NSViewController {
        setNameViewController.isFisrtPage = false
        welcomeViewController.isFisrtPage = false
        passwordManagerViewController.isFisrtPage = false
        nextStepViewController.isFisrtPage = false

        switch phase {
        case .login:
            return loginViewController
        case .setName:
            if let name = welcomeViewController.userName {
                setNameViewController.applySavedName(name)
            }
            if let credentials {
                setNameViewController.credentials = credentials
            }
            setNameViewController.isFisrtPage = isFirstPage
            return setNameViewController
        case .setTheme:
            // Preserve the name supplied by SetName when navigating back here.
            // On resume, prefer the saved profile over stale ID-token claims.
            if welcomeViewController.userName == nil {
                let account = LoginController.shared.accountForOnboarding
                let profile: Profile? = account?.userDefaults.codableValue(
                    forKey: AccountUserDefaults.DefaultsKey.cachedProfile.rawValue
                )
                if let profile, profile.auth0_id == account?.userID {
                    welcomeViewController.userName = profile.name
                } else if let credentials {
                    welcomeViewController.userName = AuthManager.retriveUserInfo(from: credentials).name
                } else {
                    welcomeViewController.userName = account?.userInfo?.name
                }
            }
            welcomeViewController.isFisrtPage = isFirstPage
            return welcomeViewController
        case .layoutSelection:
            return layoutSelectionViewController
        case .passwordManager:
            passwordManagerViewController.isFisrtPage = isFirstPage
            return passwordManagerViewController
        case .nextStep:
            nextStepViewController.isFisrtPage = isFirstPage
            return nextStepViewController
        case .done:
            return loginViewController
        }
    }

    private func showPreviousStep(_ phase: LoginController.Phase) {
        LoginController.shared.phase = phase
        setContent(
            viewController(for: phase, credentials: nil, isFirstPage: false),
            completesCurrentStep: false
        )
    }

    private func showPasswordManagerPage() {
        LoginController.shared.phase = .passwordManager
        setContent(passwordManagerViewController)
    }

    private func showNextStepPage() {
        LoginController.shared.phase = .nextStep
        setContent(nextStepViewController)
    }

    func showGuestPrivacyConfirmation() {
        setContent(guestPrivacyConfirmationViewController)
    }

    private func finish() {
        analyticsSession.completeCurrentStep()
        LoginController.shared.phase = .done

        Task { @MainActor in
            await LoginController.shared.completeCurrentLogin()
        }
    }
}

/// Hosts one onboarding page at its fixed design size and scales it
/// uniformly to the container's frame. Every page is laid out for exactly
/// 640×800; on a display whose visible frame is shorter than that (PHI-1472)
/// the whole design shrinks to fit instead of running under the Dock.
/// Scaling is done with the view's bounds, the same mechanism NSScrollView
/// magnification uses, so drawing, layers and hit testing all follow it.
final class OnboardingScalingContainerViewController: NSViewController {
    static let designSize = NSSize(width: 640, height: 800)

    private(set) var page: NSViewController?

    override func loadView() {
        view = OnboardingScalingView(designSize: Self.designSize)
    }

    func show(_ newPage: NSViewController) {
        guard newPage !== page else { return }
        if let page {
            page.view.removeFromSuperview()
            page.removeFromParent()
        }
        addChild(newPage)
        // The page pins its own size with constraints; position it by frame
        // in the container's design-space bounds.
        let pageView = newPage.view
        pageView.translatesAutoresizingMaskIntoConstraints = true
        pageView.autoresizingMask = []
        pageView.frame = NSRect(origin: .zero, size: Self.designSize)
        view.addSubview(pageView)
        page = newPage
    }

    /// The largest size with the design's aspect ratio that fits `visibleFrame`,
    /// never larger than the design itself.
    func fittedSize(in visibleFrame: NSRect) -> NSSize {
        let design = Self.designSize
        let scale = min(1,
                        visibleFrame.width / design.width,
                        visibleFrame.height / design.height)
        return NSSize(width: (design.width * scale).rounded(.down),
                      height: (design.height * scale).rounded(.down))
    }
}

private final class OnboardingScalingView: NSView {
    private let designSize: NSSize

    init(designSize: NSSize) {
        self.designSize = designSize
        super.init(frame: NSRect(origin: .zero, size: designSize))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Keep the coordinate space at the design size whatever the frame,
        // so the hosted page always lays out at 640×800 and is drawn scaled.
        if bounds.size != designSize {
            setBoundsSize(designSize)
        }
    }
}
