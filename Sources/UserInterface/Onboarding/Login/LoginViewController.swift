// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import AVFoundation
import WebKit
import Auth0
import SwiftUI
import PostHog

class LoginViewController: NSViewController {
    enum Phase {
        case login, waiting
    }

    enum PresentationMode: Equatable {
        case standard
        case guestMigrationRecovery
    }
    
    var onLoginSuccess: ((Credentials?) -> Void)?
    var onContinueAsGuest: (() -> Void)?
    var presentationMode: PresentationMode = .standard
    var isGuestModeActiveProvider: () -> Bool = {
        ApplicationState.shared.isGuest
    }
    var shouldShowContinueAsGuest: Bool {
        presentationMode == .standard && !isGuestModeActiveProvider()
    }
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private var videoDuration: CMTime = .zero
    
    // When the video reaches 1.07s (1s + 70ms), reveal the controls with a fade
    private let revealTime: CMTime = CMTime(seconds: 1.07, preferredTimescale: 1000)
    private var didRevealControls: Bool = false
    private let loginTimeoutSeconds: UInt64 = 90
    private var activeLoginAttemptID: UUID?
    private var loginTimeoutWorkItem: DispatchWorkItem?
    
    /// Blurred video snapshot shown during the waiting phase.
    private lazy var blurOverlayView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.alphaValue = 0
        imageView.isHidden = true
        return imageView
    }()
    
    /// Blur radius applied to the waiting overlay.
    private let blurRadius: CGFloat = 60.0
    
    private lazy var controlContainer: NSView = {
        let bg = NSView()
        bg.wantsLayer = true
        bg.addSubview(loginImage)
        bg.addSubview(loginButton)
        bg.addSubview(continueAsGuestButton)
        bg.addSubview(guestMigrationRecoveryLabel)
        loginImage.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview()
        }
        loginButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(continueAsGuestButton.snp.top).offset(-12)
            make.size.equalTo(NSSize(width: 120, height: 40))
        }
        continueAsGuestButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview()
            make.height.equalTo(22)
        }
        guestMigrationRecoveryLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(loginButton.snp.top).offset(-18)
            make.leading.greaterThanOrEqualToSuperview().offset(72)
            make.trailing.lessThanOrEqualToSuperview().offset(-72)
        }
        bg.alphaValue = 0
        return bg
    }()
    
    private let loginImage: NSImageView = NSImageView(image: .brand)
    
    private lazy var loginButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("oobe.login.loginButton", value: "Sign in", comment: "Onboarding sign-in button title")
        button.clickAction = { [weak self] in
            self?.loginAction()
        }
        return button
    }()

    private lazy var continueAsGuestButton: NSButton = {
        let title = NSLocalizedString(
            "oobe.login.continueAsGuestButton",
            value: "Explore Phi without signing in",
            comment: "Onboarding sign-in - Tertiary button that enters persistent Guest Mode"
        )
        let button = NSButton(title: title, target: self, action: #selector(continueAsGuestAction))
        button.isBordered = false
        button.font = .systemFont(ofSize: 13)
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white.withAlphaComponent(0.65)
            ]
        )
        button.focusRingType = .default
        button.setAccessibilityLabel(title)
        return button
    }()

    private lazy var guestMigrationRecoveryLabel: NSTextField = {
        let label = NSTextField(labelWithString: NSLocalizedString(
            "oobe.guestMigration.recovery.loginMessage",
            value: "Sign in to the account you previously selected to finish moving your Guest data.",
            comment: "Guest migration recovery - Guidance shown when the original target account must sign in again"
        ))
        label.font = .systemFont(ofSize: 14)
        label.textColor = .white.withAlphaComponent(0.78)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isHidden = true
        return label
    }()
    
    private lazy var waitingView: NSView = {
        let container = NSView()
        container.wantsLayer = true
        
        container.addSubview(waitingTitleLabel)
        waitingTitleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.centerX.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(40)
            make.trailing.lessThanOrEqualToSuperview().offset(-40)
        }
        
        container.addSubview(retryHintView)
        retryHintView.snp.makeConstraints { make in
            make.top.equalTo(waitingTitleLabel.snp.bottom).offset(36)
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview()
        }
        
        container.alphaValue = 0
        container.isHidden = true
        return container
    }()
    
    private lazy var waitingTitleLabel: NSTextField = {
        let title = NSLocalizedString("oobe.login.progressTitle", value: "Finish signing in in your browser", comment: "Waiting view title shown during sign-in process in onboarding")
        let label = NSTextField(labelWithString: title)
        label.font = .brandDisplay("IvyPresto Display", size: 40, renders: title)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        if let font = label.font, let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as NSFont? {
            label.font = italicFont
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: label.font as Any,
            .foregroundColor: NSColor.white,
            .kern: 0.8,
            .paragraphStyle: paragraphStyle
        ]
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: attributes)
        return label
    }()
    
    /// Retry hint shown after a failed login attempt.
    private lazy var retryHintView: NSView = {
        let container = NSView()
        container.wantsLayer = true
        
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 0
        stackView.alignment = .centerY
        
        let hintLabel = NSTextField(labelWithString: NSLocalizedString("oobe.login.failureHintPrefix", value: "Something went wrong? ", comment: "Retry hint prefix text shown when login fails in onboarding"))
        hintLabel.font = NSFont.systemFont(ofSize: 15)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        hintLabel.alignment = .center
        
        let retryLink = GradientColorLabel(
            text: NSLocalizedString("oobe.login.failureLink", value: "Go back and try again", comment: "Retry link text shown when login fails in onboarding"),
            gradientColors: [
                Color(hexString: "#9452F9"),
                Color(hexString: "#E8C0FF")
            ],
            fontSize: 15
        )
        retryLink.clickAction = { [weak self] in
            self?.handleRetryAction()
        }
        
        stackView.addArrangedSubview(hintLabel)
        stackView.addArrangedSubview(retryLink)
        
        container.addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        container.alphaValue = 0
        container.isHidden = true
        return container
    }()
    
    override func loadView() {
        self.view = NSView()
        self.view.wantsLayer = true
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupVideoBackground()
        setupUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateLoginPresentation()
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.layoutSubtreeIfNeeded()
        view.window?.center()
        startPlaybackOnce()
    }
    
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        resetVideo()
    }
    
    private func setupVideoBackground() {
        guard let url = Bundle.main.url(forResource: "login-bg", withExtension: "mp4") else {
            assertionFailure("Missing resource: login-bg.mp4")
            return
        }
        
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        
        let layer = AVPlayerLayer(player: player)
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill
        
        if let rootLayer = view.layer {
            rootLayer.insertSublayer(layer, at: 0)
        }
        
        self.player = player
        self.playerLayer = layer
        Task {
            self.videoDuration = try! await item.asset.load(.duration)
        }
    }
    
    private func setupUI() {
        updateLoginPresentation()

        view.snp.makeConstraints { make in
            make.size.equalTo(NSSize(width: 640, height: 800))
        }
        
        view.addSubview(blurOverlayView)
        blurOverlayView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        view.addSubview(controlContainer)
        controlContainer.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(91)
            make.bottom.equalToSuperview().offset(-91)
            make.width.equalToSuperview()
        }
        
        view.addSubview(waitingView)
        waitingView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().offset(40)
            make.trailing.lessThanOrEqualToSuperview().offset(-40)
        }
    }

    private func updateLoginPresentation() {
        let showsContinueAsGuest = shouldShowContinueAsGuest
        continueAsGuestButton.isHidden = !showsContinueAsGuest
        continueAsGuestButton.isEnabled = showsContinueAsGuest
        guestMigrationRecoveryLabel.isHidden =
            presentationMode != .guestMigrationRecovery
    }
    
    private func startPlaybackOnce() {
        guard let player = player else { return }

        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }

        player.seek(to: .zero)
        player.play()

        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] currentTime in
            guard let self else { return }
            let durationSeconds = self.videoDuration.isNumeric ? CMTimeGetSeconds(self.videoDuration) : CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
            guard durationSeconds.isFinite && durationSeconds > 0 else { return }
            
            // Reveal controls at 1s + 70ms with a 2s fade-in
            if !self.didRevealControls && CMTimeCompare(currentTime, self.revealTime) >= 0 {
                self.didRevealControls = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 2.0
                    self.controlContainer.animator().alphaValue = 1.0
                } completionHandler: {
                    self.controlContainer.alphaValue = 1
                }
            }
        }
    }
    
    private func resetVideo() {
        guard let player = player else { return }
        player.pause()
        if let token = timeObserver {
            player.removeTimeObserver(token)
            timeObserver = nil
        }
        player.seek(to: .zero)
        // Reset controls for next show
        didRevealControls = false
        controlContainer.alphaValue = 0.0
    }

    private func loginAction() {
        // Switch to waiting phase
        updateUI(with: .waiting)
        hideRetryHint()

        let attemptID = UUID()
        activeLoginAttemptID = attemptID

        loginTimeoutWorkItem?.cancel()
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, self.activeLoginAttemptID == attemptID else { return }
            self.showRetryHint()
        }
        loginTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int(loginTimeoutSeconds)), execute: timeoutWorkItem)

        Task { [weak self] in
            let credentials = await LoginController.shared.loginWithAuth0()
            await MainActor.run {
                guard let self, self.activeLoginAttemptID == attemptID else { return }
                self.loginTimeoutWorkItem?.cancel()
                self.loginTimeoutWorkItem = nil

                if let credentials {
                    self.activeLoginAttemptID = nil
                    PostHogSDK.shared.capture("user_logged_in")
                    self.onLoginSuccess?(credentials)
                } else {
                    self.showRetryHint()
                }
            }
        }
    }

    @objc func continueAsGuestAction() {
        guard shouldShowContinueAsGuest else { return }
        onContinueAsGuest?()
    }
    
    private func attachWebView(_ webView: WKWebView) {
        #if DEBUG || NIGHTLY_BUILD
        webView.isInspectable = true
        #endif
        self.view.window?.contentView = webView
    }
    
    /// Captures the current video frame and applies a Gaussian blur.
    private func captureAndBlurVideoFrame() {
        guard let player = player,
              let currentItem = player.currentItem else { return }
        
        let currentTime = player.currentTime()
        let imageGenerator = AVAssetImageGenerator(asset: currentItem.asset)
        imageGenerator.appliesPreferredTrackTransform = true
        imageGenerator.requestedTimeToleranceAfter = .zero
        imageGenerator.requestedTimeToleranceBefore = .zero
        
        Task {
            do {
                let (cgImage, _) = try await imageGenerator.image(at: currentTime)
                let originalImage = NSImage(cgImage: cgImage, size: view.bounds.size)
                
                if let blurredImage = applyGaussianBlur(to: originalImage, radius: blurRadius) {
                    await MainActor.run {
                        blurOverlayView.image = blurredImage
                    }
                }
            } catch {
                await MainActor.run {
                    captureAndBlurViewLayer()
                }
            }
        }
    }
    
    /// Fallback path that snapshots the view hierarchy and blurs it.
    private func captureAndBlurViewLayer() {
        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmapRep)
        
        if let blurredImage = applyGaussianBlur(to: image, radius: blurRadius) {
            blurOverlayView.image = blurredImage
        }
    }
    
    /// Applies a Gaussian blur to an image using Core Image.
    private func applyGaussianBlur(to image: NSImage, radius: CGFloat) -> NSImage? {
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return nil
        }
        
        guard let blurFilter = CIFilter(name: "CIGaussianBlur") else {
            return nil
        }
        
        blurFilter.setValue(ciImage, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        
        guard let outputImage = blurFilter.outputImage else {
            return nil
        }
        
        let croppedImage = outputImage.cropped(to: ciImage.extent)
        
        let ciContext = CIContext(options: nil)
        guard let cgImage = ciContext.createCGImage(croppedImage, from: croppedImage.extent) else {
            return nil
        }
        
        return NSImage(cgImage: cgImage, size: image.size)
    }
}

extension LoginViewController {
    final class LoginButton: HoverableView {
        let bgImageView = NSImageView(image: .loginBtnBg)
        let arrowImageView = NSImageView(image: .arrow)
        
        override init(frame frameRect: NSRect = .zero, clickAction: (() -> Void)? = nil) {
            super.init(frame: frameRect, clickAction: clickAction)
            setupSubViews()
        }
        
        @MainActor required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        private func setupSubViews() {
            backgroundColor = .clear
            hoveredColor = .clear
            responseToClickAction = true
            hoverStateChanged = { [weak self] hover in
                if hover {
                    self?.bgImageView.image = .loginBtnBgHover
                } else {
                    self?.bgImageView.image = .loginBtnBg
                }
            }
            
            addSubview(bgImageView)
            addSubview(arrowImageView)
            bgImageView.snp.makeConstraints { make in
                make.edges.equalToSuperview()
            }
            
            arrowImageView.snp.makeConstraints { make in
                make.center.equalToSuperview()
            }
        }
    }
}

extension LoginViewController {
    private func updateUI(with phase: Phase) {
        switch phase {
        case .login:
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                controlContainer.animator().alphaValue = 1.0
                waitingView.animator().alphaValue = 0.0
                blurOverlayView.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                self?.waitingView.isHidden = true
                self?.blurOverlayView.isHidden = true
                self?.blurOverlayView.image = nil
                self?.controlContainer.isHidden = false
            }
            
        case .waiting:
            captureAndBlurVideoFrame()
            
            waitingView.isHidden = false
            blurOverlayView.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.5
                controlContainer.animator().alphaValue = 0.0
                waitingView.animator().alphaValue = 1.0
                blurOverlayView.animator().alphaValue = 1.0
            } completionHandler: { [weak self] in
                self?.controlContainer.isHidden = true
            }
        }
    }
    
    /// Shows the retry hint view with animation
    func showRetryHint() {
        retryHintView.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            retryHintView.animator().alphaValue = 1.0
        }
    }
    
    /// Hides the retry hint view
    func hideRetryHint() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            retryHintView.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            self?.retryHintView.isHidden = true
        }
    }
    
    /// Handle retry action - go back to login phase
    private func handleRetryAction() {
        activeLoginAttemptID = nil
        loginTimeoutWorkItem?.cancel()
        loginTimeoutWorkItem = nil
        AuthManager.shared.cancelOngoingWebAuthentication()
        hideRetryHint()
        // PostHog: Capture login retry event
        PostHogSDK.shared.capture("login_retried")
        updateUI(with: .login)
    }
}
