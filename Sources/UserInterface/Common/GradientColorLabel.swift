// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import SwiftUI

// MARK: - Gradient Direction
enum GradientDirection {
    case horizontal
    case vertical
    case diagonal(start: UnitPoint, end: UnitPoint)
    
    var startPoint: UnitPoint {
        switch self {
        case .horizontal:
            return .leading
        case .vertical:
            return .top
        case .diagonal(let start, _):
            return start
        }
    }
    
    var endPoint: UnitPoint {
        switch self {
        case .horizontal:
            return .trailing
        case .vertical:
            return .bottom
        case .diagonal(_, let end):
            return end
        }
    }
}

// MARK: - Label State (Observable)
class GradientColorLabelState: ObservableObject {
    @Published var text: String = ""
    
    /// Colors for gradient. Use single color array for solid color text.
    @Published var gradientColors: [Color] = GradientColorLabelState.defaultGradientColors
    
    /// Direction of the linear gradient
    @Published var gradientDirection: GradientDirection = .horizontal
    
    /// Font size
    @Published var fontSize: CGFloat = 16
    
    /// Font weight
    @Published var fontWeight: Font.Weight = .regular
    
    /// Custom font name (optional). If nil, uses system font.
    @Published var fontName: String?
    
    /// Text alignment
    @Published var alignment: TextAlignment = .center
    
    /// Line limit (nil for unlimited)
    @Published var lineLimit: Int?
    
    /// Minimum scale factor for text fitting
    @Published var minimumScaleFactor: CGFloat = 1.0
    
    /// Kerning (letter spacing)
    @Published var kerning: CGFloat = 0
    
    /// Whether the label is tappable
    @Published var isTappable: Bool = false
    
    /// Click action callback
    var clickAction: (() -> Void)?
    
    // Default gradient colors
    static let defaultGradientColors: [Color] = [
        Color(hexString: "#FFCAE5"),
        Color(hexString: "#00AAFF"),
        Color(hexString: "#9452F9")
    ]
    
    init() {}
    
    init(
        text: String,
        gradientColors: [Color]? = nil,
        gradientDirection: GradientDirection = .horizontal,
        fontSize: CGFloat = 16,
        fontWeight: Font.Weight = .regular,
        fontName: String? = nil,
        alignment: TextAlignment = .center,
        lineLimit: Int? = nil,
        minimumScaleFactor: CGFloat = 1.0,
        kerning: CGFloat = 0,
        action: (() -> Void)? = nil
    ) {
        self.text = text
        self.gradientColors = gradientColors ?? GradientColorLabelState.defaultGradientColors
        self.gradientDirection = gradientDirection
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontName = fontName
        self.alignment = alignment
        self.lineLimit = lineLimit
        self.minimumScaleFactor = minimumScaleFactor
        self.kerning = kerning
        self.clickAction = action
        self.isTappable = action != nil
    }
}

// MARK: - SwiftUI Gradient Color Label
struct GradientColorLabelView: View {
    @ObservedObject var state: GradientColorLabelState
    
    /// Primary initializer with state object for dynamic updates
    init(state: GradientColorLabelState) {
        self.state = state
    }
    
    /// Convenience initializer for simpler usage
    init(
        text: String,
        gradientColors: [Color]? = nil,
        gradientDirection: GradientDirection = .horizontal,
        fontSize: CGFloat = 16,
        fontWeight: Font.Weight = .regular,
        fontName: String? = nil,
        alignment: TextAlignment = .center,
        lineLimit: Int? = nil,
        minimumScaleFactor: CGFloat = 1.0,
        kerning: CGFloat = 0,
        action: (() -> Void)? = nil
    ) {
        let state = GradientColorLabelState(
            text: text,
            gradientColors: gradientColors,
            gradientDirection: gradientDirection,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontName: fontName,
            alignment: alignment,
            lineLimit: lineLimit,
            minimumScaleFactor: minimumScaleFactor,
            kerning: kerning,
            action: action
        )
        self.state = state
    }
    
    /// Convenience initializer for single color (no gradient)
    init(
        text: String,
        color: Color,
        fontSize: CGFloat = 16,
        fontWeight: Font.Weight = .regular,
        fontName: String? = nil,
        alignment: TextAlignment = .center,
        lineLimit: Int? = nil,
        minimumScaleFactor: CGFloat = 1.0,
        kerning: CGFloat = 0,
        action: (() -> Void)? = nil
    ) {
        let state = GradientColorLabelState(
            text: text,
            gradientColors: [color],
            gradientDirection: .horizontal,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontName: fontName,
            alignment: alignment,
            lineLimit: lineLimit,
            minimumScaleFactor: minimumScaleFactor,
            kerning: kerning,
            action: action
        )
        self.state = state
    }
    
    private var font: Font {
        if let fontName = state.fontName {
            return Font.custom(fontName, size: state.fontSize).weight(state.fontWeight)
        } else {
            return Font.system(size: state.fontSize, weight: state.fontWeight)
        }
    }
    
    private var gradientStyle: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: state.gradientColors),
            startPoint: state.gradientDirection.startPoint,
            endPoint: state.gradientDirection.endPoint
        )
    }
    
    var body: some View {
        labelContent
            .contentShape(Rectangle())
            .onTapGesture {
                if state.isTappable {
                    state.clickAction?()
                }
            }
    }
    
    @ViewBuilder
    private var labelContent: some View {
        if state.gradientColors.count == 1 {
            // Single color - no gradient needed
            textContent
                .foregroundColor(state.gradientColors[0])
        } else {
            // Gradient text using mask technique
            textContent
                .foregroundColor(.white)
                .mask(textContent)
                .overlay(
                    gradientStyle.mask(textContent)
                )
        }
    }
    
    private var textContent: some View {
        Text(state.text)
            .font(font)
            .kerning(state.kerning)
            .multilineTextAlignment(state.alignment)
            .lineLimit(state.lineLimit)
            .minimumScaleFactor(state.minimumScaleFactor)
    }
}

// MARK: - Preview
#Preview("Gradient Horizontal") {
    VStack(spacing: 20) {
        GradientColorLabelView(
            text: "Hello Gradient World",
            fontSize: 32,
            fontWeight: .bold
        )
        
        GradientColorLabelView(
            text: "Vertical Gradient",
            gradientDirection: .vertical,
            fontSize: 28,
            fontWeight: .medium
        )
        
        GradientColorLabelView(
            text: "Diagonal Gradient",
            gradientDirection: .diagonal(start: .topLeading, end: .bottomTrailing),
            fontSize: 24,
            fontWeight: .semibold
        )
    }
    .padding(40)
    .background(Color.black)
}

#Preview("Custom Colors") {
    VStack(spacing: 20) {
        GradientColorLabelView(
            text: "Rainbow Text",
            gradientColors: [.red, .orange, .yellow, .green, .blue, .purple],
            fontSize: 36,
            fontWeight: .heavy
        )
        
        GradientColorLabelView(
            text: "Ocean Vibes",
            gradientColors: [Color(hexString: "#00D4FF"), Color(hexString: "#0066FF"), Color(hexString: "#5E00FF")],
            fontSize: 28,
            fontWeight: .bold
        )
        
        GradientColorLabelView(
            text: "Sunset Glow",
            gradientColors: [Color(hexString: "#FF6B6B"), Color(hexString: "#FFE66D")],
            fontSize: 24,
            fontWeight: .medium
        )
    }
    .padding(40)
    .background(Color.black)
}

#Preview("Single Color") {
    GradientColorLabelView(
        text: "Single Color Text",
        color: .cyan,
        fontSize: 24,
        fontWeight: .bold
    )
    .padding(40)
    .background(Color.black)
}

#Preview("With Kerning") {
    VStack(spacing: 20) {
        GradientColorLabelView(
            text: "NORMAL SPACING",
            fontSize: 20,
            fontWeight: .bold,
            kerning: 0
        )
        
        GradientColorLabelView(
            text: "WIDE SPACING",
            fontSize: 20,
            fontWeight: .bold,
            kerning: 5
        )
        
        GradientColorLabelView(
            text: "TIGHT SPACING",
            fontSize: 20,
            fontWeight: .bold,
            kerning: -1
        )
    }
    .padding(40)
    .background(Color.black)
}

#Preview("Tappable Label") {
    VStack(spacing: 20) {
        GradientColorLabelView(
            text: "Tap Me!",
            gradientColors: [.pink, .purple, .blue],
            fontSize: 28,
            fontWeight: .bold
        ) {
            print("Label tapped!")
        }
        
        GradientColorLabelView(
            text: "Click for Action",
            gradientColors: [.green, .cyan],
            fontSize: 24,
            fontWeight: .semibold,
            action: {
                print("Action triggered!")
            }
        )
    }
    .padding(40)
    .background(Color.black)
}

// MARK: - NSView Wrapper for AppKit
class GradientColorLabel: NSView {
    private let state = GradientColorLabelState()
    private var hostingView: NSHostingView<GradientColorLabelView>?
    
    var text: String {
        get { state.text }
        set { state.text = newValue }
    }
    
    /// Set colors for gradient text. Use single color array for solid color.
    var gradientColors: [Color] {
        get { state.gradientColors }
        set { state.gradientColors = newValue }
    }
    
    var gradientDirection: GradientDirection {
        get { state.gradientDirection }
        set { state.gradientDirection = newValue }
    }
    
    var fontSize: CGFloat {
        get { state.fontSize }
        set { state.fontSize = newValue }
    }
    
    var fontWeight: Font.Weight {
        get { state.fontWeight }
        set { state.fontWeight = newValue }
    }
    
    /// Custom font name. If nil, uses system font.
    var fontName: String? {
        get { state.fontName }
        set { state.fontName = newValue }
    }
    
    var alignment: TextAlignment {
        get { state.alignment }
        set { state.alignment = newValue }
    }
    
    var lineLimit: Int? {
        get { state.lineLimit }
        set { state.lineLimit = newValue }
    }
    
    var minimumScaleFactor: CGFloat {
        get { state.minimumScaleFactor }
        set { state.minimumScaleFactor = newValue }
    }
    
    var kerning: CGFloat {
        get { state.kerning }
        set { state.kerning = newValue }
    }
    
    /// Click action callback
    var clickAction: (() -> Void)? {
        get { state.clickAction }
        set {
            state.clickAction = newValue
            state.isTappable = newValue != nil
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupHostingView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupHostingView()
    }
    
    /// Convenience initializer with configuration
    convenience init(
        text: String,
        gradientColors: [Color]? = nil,
        gradientDirection: GradientDirection = .horizontal,
        fontSize: CGFloat = 16,
        fontWeight: Font.Weight = .regular,
        fontName: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(frame: .zero)
        self.text = text
        if let colors = gradientColors {
            self.gradientColors = colors
        }
        self.gradientDirection = gradientDirection
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontName = fontName
        self.clickAction = action
    }
    
    private func setupHostingView() {
        let swiftUIView = GradientColorLabelView(state: state)
        
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
