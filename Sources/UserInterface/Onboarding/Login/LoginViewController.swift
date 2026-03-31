// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import AVFoundation
import WebKit
import Auth0
import SwiftUI

class LoginViewController: NSViewController {
    enum Phase {
        case login, waiting
    }
    
    var onLoginSuccess: ((Credentials?) -> Void)?
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
        loginImage.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.top.equalToSuperview()
        }
        loginButton.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview()
            make.size.equalTo(NSSize(width: 120, height: 40))
        }
        bg.alphaValue = 0
        return bg
    }()
    
    private let loginImage: NSImageView = NSImageView(image: .brand)
    
    private lazy var loginButton: GradientBorderButton = {
        let button = GradientBorderButton()
        button.title = NSLocalizedString("Log in", comment: "Onboarding Login button title")
        button.clickAction = { [weak self] in
            self?.loginAction()
        }
        return button
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
        let label = NSTextField(labelWithString: NSLocalizedString("Go to the browser to complete log in", comment: "Waiting view title shown during login process in onboarding"))
        label.font = NSFont(name: "IvyPresto Display", size: 40)
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
        
        let hintLabel = NSTextField(labelWithString: NSLocalizedString("Something went wrong? ", comment: "Retry hint prefix text shown when login fails in onboarding"))
        hintLabel.font = NSFont.systemFont(ofSize: 15)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        hintLabel.alignment = .center
        
        let retryLink = GradientColorLabel(
            text: NSLocalizedString("Go back and try again", comment: "Retry link text shown when login fails in onboarding"),
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
                    self.onLoginSuccess?(credentials)
                } else {
                    self.showRetryHint()
                }
            }
        }
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
        updateUI(with: .login)
    }
}
