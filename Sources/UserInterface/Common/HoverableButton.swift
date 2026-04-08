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
    
    init(
        title: String = "",
        image: NSImage? = nil,
        imageSize: NSSize? = nil,
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
    
    var body: some View {
        Button(action: {
            if state.isEnabled {
                action()
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
            if let image = config.image {
                imageView(image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .both(let imagePosition):
            HStack(spacing: config.spacing) {
                if imagePosition == .left {
                    if let image = config.image {
                        imageView(image)
                    }
                    Text(config.title)
                        .foregroundColor(resolvedTitleColor)
                        .font(config.titleFont)
                } else {
                    Text(config.title)
                        .foregroundColor(resolvedTitleColor)
                        .font(config.titleFont)
                    if let image = config.image {
                        imageView(image)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func imageView(_ image: NSImage) -> some View {
        if let imageSize = config.imageSize {
            if let tintColor = resolvedImageTintColor {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tintColor)
                    .frame(width: imageSize.width, height: imageSize.height)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageSize.width, height: imageSize.height)
            }
        } else {
            if let tintColor = resolvedImageTintColor {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tintColor)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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

class HoverableButtonNSView: NSView {
    private var hostingView: HoverableHostingView?
    private var button: HoverableButton!
    private weak var target: AnyObject?
    private var selector: Selector?
    private let buttonState: HoverableButtonState
    private var themeObserver = ThemeObserver.shared
    
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
        updateThemeObserver()
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
        updateThemeObserver()
        hostingView?.rootView = AnyView(button.phiThemeObserver(themeObserver))
    }
    
    private func updateThemeObserver() {
        themeObserver = ThemeObserver(themeSource: themeStateProvider)
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
