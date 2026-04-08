// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

// A reusable Lottie animation button with hover effects and state control.

import SwiftUI
import AppKit
import Lottie

// MARK: - Animation Trigger Behavior

/// Defines when the Lottie animation should play
enum LottieAnimationTrigger: Equatable {
    /// Play animation when mouse enters the view
    case onHoverEnter
    /// Play animation when mouse exits the view
    case onHoverExit
    /// Play animation on click
    case onClick
    /// Play animation manually via external trigger (playCount increment)
    case manual
    /// No automatic animation trigger
    case none
}

// MARK: - Configuration

struct LottieAnimationViewConfig {
    /// Name of the Lottie animation file (without .json extension)
    var animationName: String
    /// Name of the reverse Lottie animation file (without .json extension), used when playing reverse animation
    var reverseAnimationName: String?
    /// Subdirectory in bundle where the animation file is located
    var subdirectory: String?
    /// Bundle to load animation from
    var bundle: Bundle
    /// Size of the animation view
    var size: CGSize
    /// Background color when not hovered
    var backgroundColor: Color
    /// Background color when hovered
    var hoverBackgroundColor: Color
    /// Corner radius for the background
    var cornerRadius: CGFloat
    /// Edge insets (padding)
    var edgeInsets: EdgeInsets
    /// When to trigger the animation
    var animationTrigger: LottieAnimationTrigger
    /// Optional themed tint color for the animation (supports light/dark mode)
    var themedTintColor: ThemedColor?
    /// Animation speed multiplier
    var animationSpeed: Double?
    /// Whether to enable hover scale effect
    var enableHoverScale: Bool
    /// Scale factor when hovered
    var hoverScale: CGFloat
    /// Whether to reverse animation when mouse exits (animation stays at last frame until exit)
    var reverseOnHoverExit: Bool
    
    init(
        animationName: String,
        reverseAnimationName: String? = nil,
        subdirectory: String? = "LottieFiles",
        bundle: Bundle = .main,
        size: CGSize = CGSize(width: 24, height: 24),
        backgroundColor: Color = .clear,
        hoverBackgroundColor: Color = Color.clear,
        cornerRadius: CGFloat = 6,
        edgeInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        animationTrigger: LottieAnimationTrigger = .onHoverEnter,
        themedTintColor: ThemedColor? = nil,
        animationSpeed: Double? = nil,
        enableHoverScale: Bool = false,
        hoverScale: CGFloat = 1.05,
        reverseOnHoverExit: Bool = false
    ) {
        self.animationName = animationName
        self.reverseAnimationName = reverseAnimationName
        self.subdirectory = subdirectory
        self.bundle = bundle
        self.size = size
        self.backgroundColor = backgroundColor
        self.hoverBackgroundColor = hoverBackgroundColor
        self.cornerRadius = cornerRadius
        self.edgeInsets = edgeInsets
        self.animationTrigger = animationTrigger
        self.themedTintColor = themedTintColor
        self.animationSpeed = animationSpeed
        self.enableHoverScale = enableHoverScale
        self.hoverScale = hoverScale
        self.reverseOnHoverExit = reverseOnHoverExit
    }
}

// MARK: - View State

class LottieAnimationViewState: ObservableObject {
    @Published var isEnabled: Bool
    /// Increment this to trigger forward animation when using .manual trigger mode
    @Published var playCount: Int = 0
    /// Increment this to trigger reverse animation when using .manual trigger mode
    @Published var reversePlayCount: Int = 0
    
    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
    
    /// Trigger forward animation playback (only works with .manual trigger mode)
    func triggerAnimation() {
        playCount += 1
    }
    
    /// Trigger reverse animation playback (only works with .manual trigger mode)
    func triggerReverseAnimation() {
        reversePlayCount += 1
    }
}

// MARK: - SwiftUI View

struct LottieAnimationView: View {
    let config: LottieAnimationViewConfig
    @ObservedObject var state: LottieAnimationViewState
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    let action: (() -> Void)?
    
    @State private var isHovering = false
    @State private var playbackMode: LottiePlaybackMode = .paused(at: .progress(0))
    /// Playback mode for the reverse animation file (when reverseAnimationName is provided)
    @State private var reversePlaybackMode: LottiePlaybackMode = .paused(at: .progress(0))
    /// Tracks if forward animation has completed (for reverse on exit)
    @State private var isAtEndFrame = false
    /// Tracks if currently playing in reverse direction
    @State private var isPlayingReverse = false
    /// Tracks if using separate reverse animation file
    @State private var isUsingReverseFile = false
    
    /// Resolved tint color based on current theme and appearance
    private var resolvedTintColor: NSColor? {
        guard let themedTintColor = config.themedTintColor else { return nil }
        return themedTintColor.resolver(theme, appearance)
    }
    
    init(
        config: LottieAnimationViewConfig,
        state: LottieAnimationViewState,
        action: (() -> Void)? = nil
    ) {
        self.config = config
        self.state = state
        self.action = action
    }
    
    var body: some View {
        Button(action: {
            guard state.isEnabled else { return }
            if config.animationTrigger == .onClick {
                playAnimation()
            }
            action?()
        }) {
            lottieContent
                .padding(config.edgeInsets)
                .background(
                    RoundedRectangle(cornerRadius: config.cornerRadius)
                        .fill(isHovering && state.isEnabled ? config.hoverBackgroundColor : config.backgroundColor)
                )
                .scaleEffect(isHovering && state.isEnabled && config.enableHoverScale ? config.hoverScale : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovering)
                .opacity(state.isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .onHover { hovering in
            isHovering = hovering
            handleHoverChange(hovering)
        }
        .onChange(of: state.playCount) { oldValue, newValue in
            AppLogDebug("🎬 [\(config.animationName)] playCount changed: \(oldValue) → \(newValue), trigger: \(config.animationTrigger)")
            if config.animationTrigger == .manual {
                playAnimation()
            }
        }
        .onChange(of: state.reversePlayCount) { oldValue, newValue in
            AppLogDebug("🎬 [\(config.animationName)] reversePlayCount changed: \(oldValue) → \(newValue), trigger: \(config.animationTrigger)")
            if config.animationTrigger == .manual {
                playReverseAnimation()
            }
        }
        .allowsHitTesting(state.isEnabled)
    }
    
    // MARK: - Lottie Content
    
    @ViewBuilder
    private var lottieContent: some View {
        ZStack {
            // Main animation (forward)
            LottieView(animation: .named(config.animationName, bundle: config.bundle, subdirectory: config.subdirectory))
                .playbackMode(playbackMode)
//                .animationSpeed(config.animationSpeed ?? -1)
                .animationDidFinish { completed in
                    AppLogDebug("🎬 [\(config.animationName)] animationDidFinish - completed: \(completed), isPlayingReverse: \(isPlayingReverse), isAtEndFrame: \(isAtEndFrame)")
                    guard completed else { return }
                    
                    if isPlayingReverse && config.reverseAnimationName == nil {
                        // Reverse animation finished (using same file), reset to start
                        AppLogDebug("🎬 [\(config.animationName)] Reverse finished → paused at progress(0)")
                        isAtEndFrame = false
                        isPlayingReverse = false
                        playbackMode = .paused(at: .progress(0))
                    } else if config.reverseOnHoverExit {
                        // Forward animation finished, stay at end frame
                        AppLogDebug("🎬 [\(config.animationName)] Forward finished → paused at progress(1)")
                        isAtEndFrame = true
                        playbackMode = .paused(at: .progress(1))
                    } else {
                        // Normal behavior: reset to start
                        AppLogDebug("🎬 [\(config.animationName)] Normal finished → paused at progress(0)")
                        playbackMode = .paused(at: .progress(0))
                    }
                }
                .configure { animationView in
                    // Apply themed tint color if specified
                    if let nsColor = resolvedTintColor {
                        let colorProvider = ColorValueProvider(nsColor.lottieColor)
                        // Apply to common layer types
                        animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Fill 1.Color"))
                        animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Stroke 1.Color"))
                    }
                }
                .id("\(config.animationName)-\(theme.id)-\(appearance.description)")
                .opacity(isUsingReverseFile ? 0 : 1)
            
            // Reverse animation (separate file, if provided)
            if let reverseAnimationName = config.reverseAnimationName {
                LottieView(animation: .named(reverseAnimationName, bundle: config.bundle, subdirectory: config.subdirectory))
                    .playbackMode(reversePlaybackMode)
                    .animationDidFinish { completed in
                        AppLogDebug("🎬 [\(reverseAnimationName)] reverse file animationDidFinish - completed: \(completed)")
                        guard completed else { return }
                        
                        // Reverse animation file finished, switch back to main animation
                        AppLogDebug("🎬 [\(reverseAnimationName)] Reverse file finished → switching to main animation")
                        isAtEndFrame = false
                        isPlayingReverse = false
                        isUsingReverseFile = false
                        reversePlaybackMode = .paused(at: .progress(0))
                        playbackMode = .paused(at: .progress(0))
                    }
                    .configure { animationView in
                        // Apply themed tint color if specified
                        if let nsColor = resolvedTintColor {
                            let colorProvider = ColorValueProvider(nsColor.lottieColor)
                            // Apply to common layer types
                            animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Fill 1.Color"))
                            animationView.setValueProvider(colorProvider, keypath: AnimationKeypath(keypath: "**.Stroke 1.Color"))
                        }
                    }
                    .id("\(reverseAnimationName)-\(theme.id)-\(appearance.description)")
                    .opacity(isUsingReverseFile ? 1 : 0)
            }
        }
        .frame(width: config.size.width, height: config.size.height)
    }
    
    // MARK: - Animation Control
    
    private func handleHoverChange(_ isHovering: Bool) {
        guard state.isEnabled else { return }
        
        AppLogDebug("🎬 [\(config.animationName)] handleHoverChange - isHovering: \(isHovering), trigger: \(config.animationTrigger), isAtEndFrame: \(isAtEndFrame), reverseOnHoverExit: \(config.reverseOnHoverExit)")
        
        switch config.animationTrigger {
        case .onHoverEnter:
            if isHovering {
                playAnimation()
            } else if config.reverseOnHoverExit && isAtEndFrame {
                // Mouse exited, play reverse animation
                playReverseAnimation()
            }
        case .onHoverExit:
            if !isHovering {
                playAnimation()
            }
        default:
            break
        }
    }
    
    private func playAnimation() {
        // Always start from beginning for consistent behavior
        AppLogDebug("🎬 [\(config.animationName)] playAnimation() called - playing 0 → 1")
        isAtEndFrame = false
        isPlayingReverse = false
        isUsingReverseFile = false
        playbackMode = .playing(.fromProgress(0, toProgress: 1, loopMode: .playOnce))
    }
    
    private func playReverseAnimation() {
        isPlayingReverse = true
        
        if config.reverseAnimationName != nil {
            // Use separate reverse animation file
            AppLogDebug("🎬 [\(config.animationName)] playReverseAnimation() called - using reverse file, playing 0 → 1")
            isUsingReverseFile = true
            // Pause main animation at end frame
            playbackMode = .paused(at: .progress(1))
            // Play reverse animation file from start to end
            reversePlaybackMode = .playing(.fromProgress(0, toProgress: 1, loopMode: .playOnce))
        } else {
            // Play main animation from end to beginning
            AppLogDebug("🎬 [\(config.animationName)] playReverseAnimation() called - playing 1 → 0")
            playbackMode = .playing(.fromProgress(1, toProgress: 0, loopMode: .playOnce))
        }
    }
}

// MARK: - AppKit Wrapper

final class LottieAnimationHostingView: NSHostingView<AnyView> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    
    override var safeAreaRect: NSRect {
        bounds
    }
}

class LottieAnimationNSView: NSView {
    private var hostingView: LottieAnimationHostingView?
    private let viewState: LottieAnimationViewState
    private var config: LottieAnimationViewConfig
    private var action: (() -> Void)?
    private var themeObserver = ThemeObserver.shared
    
    /// Enable/disable the button
    @objc var isEnabled: Bool {
        get { viewState.isEnabled }
        set { viewState.isEnabled = newValue }
    }
    
    // MARK: - Initialization
    
    init(config: LottieAnimationViewConfig, isEnabled: Bool = true, action: (() -> Void)? = nil) {
        self.config = config
        self.viewState = LottieAnimationViewState(isEnabled: isEnabled)
        self.action = action
        super.init(frame: .zero)
        
        let view = LottieAnimationView(config: config, state: viewState, action: action)
        setupHostingView(with: view)
    }
    
    init(
        config: LottieAnimationViewConfig,
        isEnabled: Bool = true,
        target: AnyObject?,
        selector: Selector?
    ) {
        self.config = config
        self.viewState = LottieAnimationViewState(isEnabled: isEnabled)
        super.init(frame: .zero)
        
        let view = LottieAnimationView(config: config, state: viewState) { [weak target, selector] in
            guard let target = target, let selector = selector else { return }
            if target.responds(to: selector) {
                _ = target.perform(selector)
            }
        }
        setupHostingView(with: view)
    }
    
    /// Objective-C compatible initializer
    /// - Parameters:
    ///   - animationName: Name of the Lottie animation file (without .json extension)
    ///   - size: Size of the animation view
    ///   - hoverBackgroundColor: Background color when hovered (optional)
    ///   - cornerRadius: Corner radius for the background
    ///   - target: Target for action
    ///   - selector: Selector to call on tap
    @objc convenience init(
        animationName: String,
        size: CGSize,
        hoverBackgroundColor: NSColor?,
        cornerRadius: CGFloat,
        target: AnyObject?,
        selector: Selector?
    ) {
        let config = LottieAnimationViewConfig(
            animationName: animationName,
            size: size,
            hoverBackgroundColor: hoverBackgroundColor != nil ? Color(nsColor: hoverBackgroundColor!) : Color.gray.opacity(0.2),
            cornerRadius: cornerRadius,
            animationTrigger: .onHoverEnter,
            reverseOnHoverExit: true
        )
        self.init(config: config, target: target, selector: selector)
    }
    
    /// Objective-C compatible initializer with manual trigger mode
    /// - Parameters:
    ///   - animationName: Name of the Lottie animation file (without .json extension)
    ///   - size: Size of the animation view
    ///   - manualTrigger: If true, animation must be triggered manually
    ///   - target: Target for action
    ///   - selector: Selector to call on tap
    @objc convenience init(
        animationName: String,
        size: CGSize,
        manualTrigger: Bool,
        target: AnyObject?,
        selector: Selector?
    ) {
        let config = LottieAnimationViewConfig(
            animationName: animationName,
            size: size,
            animationTrigger: manualTrigger ? .manual : .onHoverEnter,
            reverseOnHoverExit: true
        )
        self.init(config: config, target: target, selector: selector)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    
    private func setupHostingView(with view: LottieAnimationView) {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
        let hosting = LottieAnimationHostingView(rootView: AnyView(view.phiThemeObserver(themeObserver)))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        hosting.setContentHuggingPriority(.required, for: .horizontal)
        hosting.setContentHuggingPriority(.required, for: .vertical)
        hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.required, for: .vertical)
        
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        self.hostingView = hosting
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        themeObserver.rebind(to: themeStateProvider)
    }
    
    // MARK: - Public Methods
    
    /// Trigger forward animation playback (only works with .manual trigger mode)
    @objc func triggerAnimation() {
        viewState.triggerAnimation()
    }
    
    /// Trigger reverse animation playback (only works with .manual trigger mode)
    @objc func triggerReverseAnimation() {
        viewState.triggerReverseAnimation()
    }
}

// MARK: - Preview

#if DEBUG
struct LottieAnimationView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Hover trigger (default)
            LottieAnimationView(
                config: LottieAnimationViewConfig(
                    animationName: "download-button",
                    subdirectory: "LottieFiles",
                    size: CGSize(width: 32, height: 32),
                    hoverBackgroundColor: Color.blue.opacity(0.2),
                    animationTrigger: .onHoverEnter
                ),
                state: LottieAnimationViewState()
            )
            .previewDisplayName("Hover Enter Trigger")
            
            // Click trigger
            LottieAnimationView(
                config: LottieAnimationViewConfig(
                    animationName: "download-button",
                    subdirectory: "LottieFiles",
                    size: CGSize(width: 32, height: 32),
                    hoverBackgroundColor: Color.green.opacity(0.2),
                    animationTrigger: .onClick
                ),
                state: LottieAnimationViewState()
            ) {
                print("Clicked!")
            }
            .previewDisplayName("Click Trigger")
            
            // With scale effect
            LottieAnimationView(
                config: LottieAnimationViewConfig(
                    animationName: "download-button",
                    subdirectory: "LottieFiles",
                    size: CGSize(width: 32, height: 32),
                    hoverBackgroundColor: Color.orange.opacity(0.2),
                    animationTrigger: .onHoverEnter,
                    enableHoverScale: true,
                    hoverScale: 1.1
                ),
                state: LottieAnimationViewState()
            )
            .previewDisplayName("With Scale Effect")
            
            // Reverse on hover exit
            LottieAnimationView(
                config: LottieAnimationViewConfig(
                    animationName: "download-button",
                    subdirectory: "LottieFiles",
                    size: CGSize(width: 32, height: 32),
                    hoverBackgroundColor: Color.purple.opacity(0.2),
                    animationTrigger: .onHoverEnter,
                    reverseOnHoverExit: true
                ),
                state: LottieAnimationViewState()
            )
            .previewDisplayName("Reverse on Exit")
            
            // Disabled state
            LottieAnimationView(
                config: LottieAnimationViewConfig(
                    animationName: "download-button",
                    subdirectory: "LottieFiles",
                    size: CGSize(width: 32, height: 32),
                    hoverBackgroundColor: Color.red.opacity(0.2),
                    animationTrigger: .onHoverEnter
                ),
                state: LottieAnimationViewState(isEnabled: false)
            )
            .previewDisplayName("Disabled")
        }
        .padding(40)
    }
}
#endif

extension LottieColor {
    init(nsColor: NSColor) {
        self.init(r: nsColor.redComponent, g: nsColor.greenComponent, b: nsColor.blueComponent, a: nsColor.alphaComponent)
    }
}

extension NSColor {
    var lottieColor: LottieColor {
        let sRGBColor = usingColorSpace(.sRGB) ?? self
        return .init(r: sRGBColor.redComponent, g: sRGBColor.greenComponent, b: sRGBColor.blueComponent, a: sRGBColor.alphaComponent)
    }
}
