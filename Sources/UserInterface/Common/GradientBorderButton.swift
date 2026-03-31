// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

// MARK: - Button State (Observable)
class GradientBorderButtonState: ObservableObject {
    @Published var title: String = ""
    @Published var titleColor: Color = .white
    @Published var backgroundColor: Color = .clear
    @Published var isEnabled: Bool = true
    /// Border colors for gradient. Use single color array for solid border.
    @Published var borderColors: [Color] = GradientBorderButtonState.defaultGradientColors
    @Published var borderWidth: CGFloat = 1
    /// If nil, the button will fill available space
    @Published var width: CGFloat?
    /// If nil, the button will fill available space
    @Published var height: CGFloat?
    @Published var cornerRadius: CGFloat = 20
    
    var clickAction: (() -> Void)?
    
    // Default angular gradient colors
    static let defaultGradientColors: [Color] = [
        Color(hexString: "#FFCAE5"),
        Color(hexString: "#00AAFF"),
        Color(hexString: "#9452F9"),
        Color(hexString: "#FF8EC7"),
        Color(hexString: "#FFCAE5")
    ]
    
    init() {}
    
    init(
        title: String,
        titleColor: Color = .white,
        backgroundColor: Color = .clear,
        isEnabled: Bool = true,
        borderColors: [Color]? = nil,
        borderWidth: CGFloat = 1,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        cornerRadius: CGFloat = 20,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.titleColor = titleColor
        self.backgroundColor = backgroundColor
        self.isEnabled = isEnabled
        self.borderColors = borderColors ?? GradientBorderButtonState.defaultGradientColors
        self.borderWidth = borderWidth
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        self.clickAction = action
    }
}

// MARK: - SwiftUI Gradient Border Button
struct GradientBorderButtonView: View {
    @ObservedObject var state: GradientBorderButtonState
    
    /// Primary initializer with state object for dynamic updates
    init(state: GradientBorderButtonState) {
        self.state = state
    }
    
    /// Convenience initializer for simpler usage
    init(
        title: String,
        titleColor: Color = .white,
        backgroundColor: Color = .clear,
        isEnabled: Bool = true,
        borderColors: [Color]? = nil,
        borderWidth: CGFloat = 1,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        cornerRadius: CGFloat = 20,
        action: @escaping () -> Void
    ) {
        let state = GradientBorderButtonState(
            title: title,
            titleColor: titleColor,
            backgroundColor: backgroundColor,
            isEnabled: isEnabled,
            borderColors: borderColors,
            borderWidth: borderWidth,
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            action: action
        )
        self.state = state
    }
    
    /// Convenience initializer for single border color (no gradient)
    init(
        title: String,
        titleColor: Color = .white,
        backgroundColor: Color = .clear,
        isEnabled: Bool = true,
        borderColor: Color,
        borderWidth: CGFloat = 1,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        cornerRadius: CGFloat = 20,
        action: @escaping () -> Void
    ) {
        let state = GradientBorderButtonState(
            title: title,
            titleColor: titleColor,
            backgroundColor: backgroundColor,
            isEnabled: isEnabled,
            borderColors: [borderColor],
            borderWidth: borderWidth,
            width: width,
            height: height,
            cornerRadius: cornerRadius,
            action: action
        )
        self.state = state
    }
    
    private var borderStyle: some ShapeStyle {
        if state.borderColors.count == 1 {
            return AnyShapeStyle(state.borderColors[0])
        } else {
            return AnyShapeStyle(
                AngularGradient(
                    gradient: Gradient(colors: state.borderColors),
                    center: .center
                )
            )
        }
    }
    
    var body: some View {
        Button(action: { state.clickAction?() }) {
            Text(state.title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(state.titleColor)
                .frame(
                    minWidth: state.width,
                    maxWidth: state.width ?? .infinity,
                    minHeight: state.height,
                    maxHeight: state.height ?? .infinity
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!state.isEnabled)
        .background(
            RoundedRectangle(cornerRadius: state.cornerRadius)
                .fill(state.backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: state.cornerRadius)
                .stroke(borderStyle, lineWidth: state.borderWidth)
        )
    }
}

// MARK: - Preview
#Preview("Gradient Border - Flexible") {
    GradientBorderButtonView(
        title: "Next",
        isEnabled: true,
        action: {}
    )
    .frame(width: 150, height: 44)  // Size controlled by external frame
    .padding(40)
    .background(Color.black)
}

#Preview("Single Color Border") {
    GradientBorderButtonView(
        title: "Next",
        isEnabled: true,
        borderColor: .white,
        action: {}
    )
    .frame(width: 120, height: 40)
    .padding(40)
    .background(Color.black)
}

#Preview("Custom Border Width") {
    GradientBorderButtonView(
        title: "Continue",
        isEnabled: true,
        borderWidth: 2,
        width: 200,
        height: 50,
        cornerRadius: 25,
        action: {}
    )
    .padding(40)
    .background(Color.black)
}

// MARK: - NSView Wrapper for AppKit
class GradientBorderButton: NSView {
    private let state = GradientBorderButtonState()
    private var hostingView: NSHostingView<GradientBorderButtonView>?
    
    var title: String {
        get { state.title }
        set { state.title = newValue }
    }
    
    var titleColor: Color {
        get { state.titleColor }
        set { state.titleColor = newValue }
    }
    
    var backgroundColor: Color {
        get { state.backgroundColor }
        set { state.backgroundColor = newValue }
    }
    
    var isEnabled: Bool {
        get { state.isEnabled }
        set { state.isEnabled = newValue }
    }
    
    /// Set colors for gradient border. Use single color array for solid border.
    var borderColors: [Color] {
        get { state.borderColors }
        set { state.borderColors = newValue }
    }
    
    var borderWidth: CGFloat {
        get { state.borderWidth }
        set { state.borderWidth = newValue }
    }
    
    /// If nil, button fills available width from constraints
    var buttonWidth: CGFloat? {
        get { state.width }
        set { state.width = newValue }
    }
    
    /// If nil, button fills available height from constraints
    var buttonHeight: CGFloat? {
        get { state.height }
        set { state.height = newValue }
    }
    
    var cornerRadius: CGFloat {
        get { state.cornerRadius }
        set { state.cornerRadius = newValue }
    }
    
    var clickAction: (() -> Void)? {
        get { state.clickAction }
        set { state.clickAction = newValue }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
    }
    
    private func setupHostingView() {
        let swiftUIView = GradientBorderButtonView(state: state)
        
        let hosting = NSHostingView(rootView: swiftUIView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        
        hostingView = hosting
    }
}

