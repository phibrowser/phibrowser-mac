// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

// MARK: - Display Mode
enum HoverableButtonDisplayMode {
    case titleOnly
    case imageOnly
    case both(imagePosition: ImagePosition)
    
    enum ImagePosition {
        case left
        case right
    }
}

// MARK: - Configuration
struct HoverableButtonConfig {
    var title: String
    var image: NSImage?
    var displayMode: HoverableButtonDisplayMode
    var backgroundColor: ThemedColor
    var hoverBackgroundColor: ThemedColor
    var titleColor: ThemedColor
    var imageTintColor: ThemedColor?
    var titleFont: Font
    var enableHoverScale: Bool
    var hoverScale: CGFloat
    var spacing: CGFloat
    var edgeInsets: EdgeInsets
    var cornerRadius: CGFloat
    var imageSize: NSSize?

    /// SF Symbol name; when set, uses `Image(systemName:)` which supports `symbolEffect`.
    var systemName: String?
    /// SF Symbol name for triggered state (e.g. "checkmark" after copy).
    var triggeredSystemName: String?
    /// Font weight for SF Symbol rendering; defaults to `.medium`.
    var symbolWeight: Font.Weight?

    /// NSImage shown after trigger (ignored when `triggeredSystemName` is set).
    var triggeredImage: NSImage?
    var triggeredImageTintColor: ThemedColor?
    /// Content transition applied to the image (e.g. `.symbolEffect(.replace)`).
    var imageContentTransition: ContentTransition?
    /// Auto-revert delay in seconds; `nil` means the triggered state persists.
    var triggeredRevertDelay: TimeInterval?

    init(
        title: String = "",
        image: NSImage? = nil,
        imageSize: NSSize? = nil,
        systemName: String? = nil,
        triggeredSystemName: String? = nil,
        symbolWeight: Font.Weight? = nil,
        triggeredImage: NSImage? = nil,
        triggeredImageTintColor: ThemedColor? = nil,
        imageContentTransition: ContentTransition? = nil,
        triggeredRevertDelay: TimeInterval? = nil,
        displayMode: HoverableButtonDisplayMode = .imageOnly,
        backgroundColor: ThemedColor = .clear,
        hoverBackgroundColor: ThemedColor = .hover,
        titleColor: ThemedColor = .textPrimary,
        imageTintColor: ThemedColor? = nil,
        titleFont: Font = .body,
        enableHoverScale: Bool = false,
        hoverScale: CGFloat = 1.05,
        spacing: CGFloat = 8,
        edgeInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        cornerRadius: CGFloat = 6
    ) {
        self.title = title
        self.image = image
        self.displayMode = displayMode
        self.backgroundColor = backgroundColor
        self.hoverBackgroundColor = hoverBackgroundColor
        self.titleColor = titleColor
        self.imageTintColor = imageTintColor
        self.titleFont = titleFont
        self.enableHoverScale = enableHoverScale
        self.hoverScale = hoverScale
        self.spacing = spacing
        self.edgeInsets = edgeInsets
        self.cornerRadius = cornerRadius
        self.imageSize = imageSize
        self.systemName = systemName
        self.triggeredSystemName = triggeredSystemName
        self.symbolWeight = symbolWeight
        self.triggeredImage = triggeredImage
        self.triggeredImageTintColor = triggeredImageTintColor
        self.imageContentTransition = imageContentTransition
        self.triggeredRevertDelay = triggeredRevertDelay
    }
}

// MARK: - Button State
class HoverableButtonState: ObservableObject {
    @Published var isEnabled: Bool
    
    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

// MARK: - SwiftUI Button
struct HoverableButton: View {
    let config: HoverableButtonConfig
    @ObservedObject var state: HoverableButtonState
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    let action: () -> Void
    
    @State private var isHovering = false
    @State private var isTriggered = false
    
    init(config: HoverableButtonConfig, state: HoverableButtonState, action: @escaping () -> Void) {
        self.config = config
        self.state = state
        self.action = action
    }
    
    // MARK: - Resolved Colors
    
    private var resolvedBackgroundColor: Color {
        config.backgroundColor.swiftUIColor(theme: theme, appearance: appearance)
    }
    
    private var resolvedHoverBackgroundColor: Color {
        config.hoverBackgroundColor.swiftUIColor(theme: theme, appearance: appearance)
    }
    
    private var resolvedTitleColor: Color {
        config.titleColor.swiftUIColor(theme: theme, appearance: appearance)
    }
    
    private var resolvedImageTintColor: Color? {
        guard let imageTintColor = config.imageTintColor else { return nil }
        return imageTintColor.swiftUIColor(theme: theme, appearance: appearance)
    }

    private var displaySystemName: String? {
        if isTriggered, let name = config.triggeredSystemName { return name }
        return config.systemName
    }

    private var displayImage: NSImage? {
        if isTriggered, let img = config.triggeredImage { return img }
        return config.image
    }

    private var resolvedDisplayImageTintColor: Color? {
        if isTriggered, let tint = config.triggeredImageTintColor {
            return tint.swiftUIColor(theme: theme, appearance: appearance)
        }
        return resolvedImageTintColor
    }
    
    var body: some View {
        Button(action: {
            if state.isEnabled {
                action()
                if config.triggeredImage != nil || config.triggeredSystemName != nil {
                    isTriggered = true
                    if let delay = config.triggeredRevertDelay {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            isTriggered = false
                        }
                    }
                }
            }
        }) {
            contentView
                .padding(config.edgeInsets)
                .background(isHovering && state.isEnabled ? resolvedHoverBackgroundColor : resolvedBackgroundColor)
                .cornerRadius(config.cornerRadius)
                .scaleEffect(isHovering && state.isEnabled && config.enableHoverScale ? config.hoverScale : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isHovering)
                .opacity(state.isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!state.isEnabled)
        .onHover { hovering in
            isHovering = hovering
        }
        .allowsHitTesting(state.isEnabled)
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch config.displayMode {
        case .titleOnly:
            Text(config.title)
                .foregroundColor(resolvedTitleColor)
                .font(config.titleFont)
        case .imageOnly:
            if let name = displaySystemName {
                symbolImageView(name)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = displayImage {
                imageView(image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .both(let imagePosition):
            HStack(spacing: config.spacing) {
                if imagePosition == .left {
                    currentImageContent
                    Text(config.title)
                        .foregroundColor(resolvedTitleColor)
                        .font(config.titleFont)
                } else {
                    Text(config.title)
                        .foregroundColor(resolvedTitleColor)
                        .font(config.titleFont)
                    currentImageContent
                }
            }
        }
    }

    @ViewBuilder
    private var currentImageContent: some View {
        if let name = displaySystemName {
            symbolImageView(name)
        } else if let image = displayImage {
            imageView(image)
        }
    }
    
    @ViewBuilder
    private func symbolImageView(_ name: String) -> some View {
        let tintColor = resolvedDisplayImageTintColor ?? .primary
        let transition = config.imageContentTransition ?? .identity

        Image(systemName: name)
            .font(.system(size: config.imageSize?.height ?? 16, weight: config.symbolWeight ?? .medium))
            .foregroundStyle(tintColor)
            .contentTransition(transition)
    }

    @ViewBuilder
    private func imageView(_ image: NSImage) -> some View {
        let tintColor = resolvedDisplayImageTintColor
        let transition = config.imageContentTransition ?? .identity

        if let imageSize = config.imageSize {
            if let tintColor {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tintColor)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .contentTransition(transition)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .contentTransition(transition)
            }
        } else {
            if let tintColor {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tintColor)
                    .contentTransition(transition)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .contentTransition(transition)
            }
        }
    }
}

// MARK: - AppKit Wrapper
final class HoverableHostingView: NSHostingView<AnyView> {
    // Remove SwiftUI safe-area insets so titlebar-hosted controls align correctly.
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    
    override var safeAreaRect: NSRect {
        bounds
    }
}

struct SecondaryClickPassthrough: NSViewRepresentable {
    let onSecondaryClick: (() -> Void)?

    func makeNSView(context: Context) -> SecondaryClickPassthroughNSView {
        let view = SecondaryClickPassthroughNSView()
        view.onSecondaryClick = onSecondaryClick
        return view
    }

    func updateNSView(_ nsView: SecondaryClickPassthroughNSView, context: Context) {
        nsView.onSecondaryClick = onSecondaryClick
    }
}

struct SecondaryClickContainer<Content: View>: NSViewRepresentable {
    let onSecondaryClick: (() -> Void)?
    let content: Content

    init(
        onSecondaryClick: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.onSecondaryClick = onSecondaryClick
        self.content = content()
    }

    func makeNSView(context: Context) -> SecondaryClickContainerNSView {
        let view = SecondaryClickContainerNSView()
        view.onSecondaryClick = onSecondaryClick
        view.setRootView(AnyView(content))
        return view
    }

    func updateNSView(_ nsView: SecondaryClickContainerNSView, context: Context) {
        nsView.onSecondaryClick = onSecondaryClick
        nsView.setRootView(AnyView(content))
    }
}

final class SecondaryClickPassthroughNSView: NSView {
    var onSecondaryClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onSecondaryClick != nil else { return nil }
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        onSecondaryClick()
    }
}

final class SecondaryClickContainerNSView: NSView {
    private let hostingView = HoverableHostingView(rootView: AnyView(EmptyView()))

    var onSecondaryClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRootView(_ rootView: AnyView) {
        hostingView.rootView = rootView
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onSecondaryClick != nil else { return super.hitTest(point) }
        guard let event = NSApp.currentEvent else { return super.hitTest(point) }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return self
        default:
            return super.hitTest(point)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else {
            super.rightMouseDown(with: event)
            return
        }
        onSecondaryClick()
    }

    private func setupHostingView() {
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

class HoverableButtonNSView: NSView {
    private var hostingView: HoverableHostingView?
    private var button: HoverableButton!
    private weak var target: AnyObject?
    private var selector: Selector?
    private let buttonState: HoverableButtonState
    private var themeObserver = ThemeObserver.shared

    var secondaryAction: (() -> Void)?
    
    var isEnabled: Bool {
        get { buttonState.isEnabled }
        set { buttonState.isEnabled = newValue }
    }
    
    init(
        config: HoverableButtonConfig,
        isEnabled: Bool = true,
        target: AnyObject? = nil,
        selector: Selector? = nil
    ) {
        self.target = target
        self.selector = selector
        self.buttonState = HoverableButtonState(isEnabled: isEnabled)
        
        super.init(frame: .zero)
        
        self.button = HoverableButton(config: config, state: buttonState) { [weak self, weak target, selector] in
            if let target = target, let selector = selector {
                if target.responds(to: selector) {
                    _ = target.perform(selector, with: self)
                }
            }   
        }
        
        setupHostingView()
    }
    
    init(config: HoverableButtonConfig, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.buttonState = HoverableButtonState(isEnabled: isEnabled)
        super.init(frame: .zero)
        self.button = HoverableButton(config: config, state: buttonState, action: action)
        setupHostingView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupHostingView() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
        let hosting = HoverableHostingView(rootView: AnyView(button.phiThemeObserver(themeObserver)))
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

    override func rightMouseDown(with event: NSEvent) {
        guard buttonState.isEnabled else { return }
        guard let secondaryAction else {
            super.rightMouseDown(with: event)
            return
        }
        secondaryAction()
    }
}

// MARK: - Preview
#Preview("HoverableButton Examples") {
    VStack(spacing: 20) {
        // Title Only
        HoverableButton(
            config: HoverableButtonConfig(
                title: "Title Only",
                displayMode: .titleOnly,
                backgroundColor: .custom(light: .blue.withAlphaComponent(0.1), dark: .blue.withAlphaComponent(0.2)),
                hoverBackgroundColor: .custom(light: .blue.withAlphaComponent(0.3), dark: .blue.withAlphaComponent(0.4)),
                titleColor: .textPrimary,
                titleFont: .headline
            ),
            state: HoverableButtonState()
        ) {
            print("Title only clicked")
        }
        
        // Image Only
        HoverableButton(
            config: HoverableButtonConfig(
                image: NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil),
                displayMode: .imageOnly,
                backgroundColor: .custom(lightHex: 0xE8F5E9, darkHex: 0x1B5E20),
                hoverBackgroundColor: .custom(lightHex: 0xC8E6C9, darkHex: 0x2E7D32),
                imageTintColor: .custom(lightHex: 0x2E7D32, darkHex: 0x81C784)
            ),
            state: HoverableButtonState()
        ) {
            print("Image only clicked")
        }
        
        // Both - Image Left
        HoverableButton(
            config: HoverableButtonConfig(
                title: "Image Left",
                image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil),
                displayMode: .both(imagePosition: .left),
                backgroundColor: .sidebarTabSelectedBackground,
                hoverBackgroundColor: .hover,
                titleColor: .custom(lightHex: 0xD32F2F, darkHex: 0xEF5350),
                imageTintColor: .custom(lightHex: 0xD32F2F, darkHex: 0xEF5350),
                titleFont: .body,
                spacing: 8
            ),
            state: HoverableButtonState()
        ) {
            print("Image left clicked")
        }
        
        // Both - Image Right
        HoverableButton(
            config: HoverableButtonConfig(
                title: "Image Right",
                image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil),
                displayMode: .both(imagePosition: .right),
                backgroundColor: .windowBackground,
                hoverBackgroundColor: .hover,
                titleColor: .textSecondary,
                titleFont: .subheadline,
                spacing: 8
            ),
            state: HoverableButtonState()
        ) {
            print("Image right clicked")
        }
        
        // With hover scale and custom colors.
        HoverableButton(
            config: HoverableButtonConfig(
                title: "Hover to Scale",
                image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil),
                displayMode: .both(imagePosition: .left),
                backgroundColor: .custom(light: .orange.withAlphaComponent(0.1), dark: .orange.withAlphaComponent(0.2)),
                hoverBackgroundColor: .custom(light: .orange.withAlphaComponent(0.3), dark: .orange.withAlphaComponent(0.4)),
                titleColor: .custom(lightHex: 0xE65100, darkHex: 0xFFB74D),
                imageTintColor: .custom(lightHex: 0xE65100, darkHex: 0xFFB74D),
                titleFont: .title3,
                enableHoverScale: true,
                hoverScale: 1.1,
                spacing: 8
            ),
            state: HoverableButtonState()
        ) {
            print("Scaled button clicked")
        }
    }
    .padding()
    .frame(width: 300)
}
