// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

// MARK: - Theme Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = ThemeManager.shared.currentTheme
}

private struct AppearanceKey: EnvironmentKey {
    static let defaultValue: Appearance = ThemeManager.shared.currentAppearance
}

private struct ThemeObserverKey: EnvironmentKey {
    static let defaultValue: ThemeObserver = .shared
}

public extension EnvironmentValues {
    var phiTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    
    var phiAppearance: Appearance {
        get { self[AppearanceKey.self] }
        set { self[AppearanceKey.self] = newValue }
    }
    
    var phiThemeObserver: ThemeObserver {
        get { self[ThemeObserverKey.self] }
        set { self[ThemeObserverKey.self] = newValue }
    }
}

// MARK: - ThemeObserver

/// ObservableObject that mirrors theme and appearance changes.
public final class ThemeObserver: ObservableObject {
    /// Shared observer used by SwiftUI views to avoid duplicate subscriptions.
    public static let shared = ThemeObserver(themeSource: ThemeManager.shared)
    
    @Published public var theme: Theme
    @Published public var appearance: Appearance
    
    private var subscription: AnyObject?
    private var generation: UInt = 0
    
    public init(themeSource: ThemeStateProvider = ThemeManager.shared) {
        self.theme = themeSource.currentTheme
        self.appearance = themeSource.currentAppearance
        bindSubscription(to: themeSource)
    }
    
    /// Rebinds this observer to a different theme source without replacing the object.
    /// Existing SwiftUI environment references stay valid.
    public func rebind(to source: ThemeStateProvider) {
        AppLogDebug("[ThemeDebug] rebind: source=\(type(of: source)), theme=\(source.currentTheme.id), appearance=\(source.currentAppearance)")
        self.theme = source.currentTheme
        self.appearance = source.currentAppearance
        bindSubscription(to: source)
    }
    
    private func bindSubscription(to source: ThemeStateProvider) {
        generation &+= 1
        let expectedGeneration = generation
        self.subscription = source.subscribe { [weak self] theme, appearance in
            DispatchQueue.main.async {
                guard let self, self.generation == expectedGeneration else { return }
                self.theme = theme
                self.appearance = appearance
            }
        }
    }

    /// Resolves a themed color into a SwiftUI color.
    public func resolve(_ themedColor: ThemedColor, appearance override: Appearance? = nil) -> Color {
        themedColor.resolver(theme, override ?? appearance).swiftUIColor
    }
    
    public func resolveNSColor(_ themedColor: ThemedColor, appearance override: Appearance? = nil) -> NSColor {
        themedColor.resolver(theme, override ?? appearance)
    }
}

extension ColorScheme {
    var phiAppearance: Appearance {
        self == .dark ? .dark : .light
    }
}

// MARK: - ThemedColor to SwiftUI Color

public extension ThemedColor {
    /// Resolves a SwiftUI color for a specific theme and appearance.
    func swiftUIColor(theme: Theme, appearance: Appearance) -> Color {
        resolver(theme, appearance).swiftUIColor
    }
    
    /// Resolves a SwiftUI color from the current theme manager state.
    var color: Color {
        dynamicColor().swiftUIColor
    }
}

// MARK: - NSColor to SwiftUI Color Extension

public extension NSColor {
    /// Converts the AppKit color into a SwiftUI color.
    var swiftUIColor: Color {
        if #available(macOS 12.0, *) {
            return Color(nsColor: self)
        } else {
            // Fallback for macOS 10.15 - 11
            // Convert through RGB components
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if let rgbColor = self.usingColorSpace(.sRGB) {
                rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
                return Color(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
            }
            return Color.black
        }
    }
}

// MARK: - View Modifiers

private struct ThemeObserverEnvironmentBridge: ViewModifier {
    @ObservedObject private var observer: ThemeObserver
    
    init(observer: ThemeObserver) {
        _observer = ObservedObject(wrappedValue: observer)
    }
    
    func body(content: Content) -> some View {
        content
            .environment(\.phiThemeObserver, observer)
            .environment(\.phiTheme, observer.theme)
            .environment(\.phiAppearance, observer.appearance)
    }
}

/// Applies a themed foreground color.
struct ThemedForegroundModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content.foregroundColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}

/// Applies a themed background color.
struct ThemedBackgroundModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content.background(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}

/// Applies a themed tint color.
struct ThemedTintModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.tint(themedColor.swiftUIColor(theme: theme, appearance: appearance))
        } else {
            content.accentColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
        }
    }
}

/// Applies a themed border.
struct ThemedBorderModifier: ViewModifier {
    let themedColor: ThemedColor
    let width: CGFloat
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content.border(themedColor.swiftUIColor(theme: theme, appearance: appearance), width: width)
    }
}

/// Applies a themed shadow color.
struct ThemedShadowModifier: ViewModifier {
    let themedColor: ThemedColor
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content.shadow(
            color: themedColor.swiftUIColor(theme: theme, appearance: appearance),
            radius: radius,
            x: x,
            y: y
        )
    }
}

// MARK: - View Extensions

public extension View {
    func phiThemeObserver(_ observer: ThemeObserver) -> some View {
        modifier(ThemeObserverEnvironmentBridge(observer: observer))
    }
    
    /// Applies a themed foreground color.
    func themedForeground(_ themedColor: ThemedColor) -> some View {
        modifier(ThemedForegroundModifier(themedColor: themedColor))
    }
    
    /// Applies a themed background color.
    func themedBackground(_ themedColor: ThemedColor) -> some View {
        modifier(ThemedBackgroundModifier(themedColor: themedColor))
    }
    
    /// Applies a themed tint color.
    func themedTint(_ themedColor: ThemedColor) -> some View {
        modifier(ThemedTintModifier(themedColor: themedColor))
    }
    
    /// Applies a themed border.
    func themedBorder(_ themedColor: ThemedColor, width: CGFloat = 1) -> some View {
        modifier(ThemedBorderModifier(themedColor: themedColor, width: width))
    }
    
    /// Applies a themed shadow.
    func themedShadow(
        _ themedColor: ThemedColor,
        radius: CGFloat,
        x: CGFloat = 0,
        y: CGFloat = 0
    ) -> some View {
        modifier(ThemedShadowModifier(themedColor: themedColor, radius: radius, x: x, y: y))
    }
}

// MARK: - Shape Extensions

public extension Shape {
    /// Fills the shape with a themed color.
    func themedFill(_ themedColor: ThemedColor) -> some View {
        ThemedShapeFill(shape: self, themedColor: themedColor)
    }
    
    /// Strokes the shape with a themed color.
    func themedStroke(_ themedColor: ThemedColor, lineWidth: CGFloat = 1) -> some View {
        ThemedShapeStroke(shape: self, themedColor: themedColor, lineWidth: lineWidth)
    }
}

/// Shape fill view backed by a themed color.
struct ThemedShapeFill<S: Shape>: View {
    let shape: S
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    var body: some View {
        shape.fill(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}

/// Shape stroke view backed by a themed color.
struct ThemedShapeStroke<S: Shape>: View {
    let shape: S
    let themedColor: ThemedColor
    let lineWidth: CGFloat
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    var body: some View {
        shape.stroke(themedColor.swiftUIColor(theme: theme, appearance: appearance), lineWidth: lineWidth)
    }
}

// MARK: - Themed Hosting

/// NSHostingController that automatically injects window-scoped theme environment.
///
/// Resolves theme source in order: explicit parameter → active browser window → ThemeManager.shared.
///
///     // Auto-resolve from active window (settings pages, standalone panels)
///     let hc = ThemedHostingController(rootView: MySettingView())
///
///     // Explicit source (browser window components)
///     let hc = ThemedHostingController(rootView: MyView(), themeSource: browserState.themeContext)
///
public class ThemedHostingController<Content: View>: NSHostingController<AnyView> {
    private let themeObserver: ThemeObserver

    public init(rootView content: Content, themeSource: ThemeStateProvider? = nil) {
        let source = themeSource ?? Self.resolveNonIncognitoContext()
        let observer = ThemeObserver(themeSource: source)
        self.themeObserver = observer
        super.init(rootView: AnyView(content.phiThemeObserver(observer)))
    }

    private static func resolveNonIncognitoContext() -> ThemeStateProvider {
        if let controller = MainBrowserWindowControllersManager.shared.activeWindowController,
           !controller.browserState.isIncognito {
            return controller.browserState.themeContext
        }
        return ThemeManager.shared
    }

    @MainActor @preconcurrency required dynamic public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// NSHostingView subclass that automatically injects and rebinds window-scoped theme environment.
///
/// On `viewDidMoveToWindow`, the observer rebinds to the window's `themeStateProvider`
/// so existing SwiftUI environment references stay valid without rebuilding the root view.
///
///     // Auto-resolve from active window
///     let hosting = ThemedHostingView(rootView: MySwiftUIView())
///
///     // Explicit source
///     let hosting = ThemedHostingView(rootView: MyView(), themeSource: browserState.themeContext)
///
public class ThemedHostingView: NSHostingView<AnyView> {
    private var themeObserver: ThemeObserver

    public init<Content: View>(rootView content: Content, themeSource: ThemeStateProvider? = nil) {
        let source = themeSource ?? Self.resolveNonIncognitoContext()
        let observer = ThemeObserver(themeSource: source)
        self.themeObserver = observer
        super.init(rootView: AnyView(content.phiThemeObserver(observer)))
    }

    @MainActor @preconcurrency required public init(rootView: AnyView) {
        self.themeObserver = ThemeObserver(themeSource: ThemeManager.shared)
        super.init(rootView: rootView)
    }

    private static func resolveNonIncognitoContext() -> ThemeStateProvider {
        if let controller = MainBrowserWindowControllersManager.shared.activeWindowController,
           !controller.browserState.isIncognito {
            return controller.browserState.themeContext
        }
        return ThemeManager.shared
    }

    @MainActor @preconcurrency required dynamic public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        themeObserver.rebind(to: themeStateProvider)
    }

    /// Updates the hosted content while preserving theme injection.
    public func setThemedContent<Content: View>(_ content: Content) {
        rootView = AnyView(content.phiThemeObserver(themeObserver))
    }
}

// MARK: - Convenience Color Extension

public extension Color {
    /// Creates a static SwiftUI color from a themed color.
    static func themed(_ themedColor: ThemedColor) -> Color {
        themedColor.color
    }
}

// MARK: - ThemedText

/// `Text` wrapper that tracks themed foreground colors.
public struct ThemedText: View {
    let text: String
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    public init(_ text: String, color: ThemedColor) {
        self.text = text
        self.themedColor = color
    }
    
    public var body: some View {
        Text(text)
            .foregroundColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}
