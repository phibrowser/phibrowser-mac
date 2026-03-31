// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import Combine

// MARK: - Theme Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = ThemeManager.shared.currentTheme
}

private struct AppearanceKey: EnvironmentKey {
    static let defaultValue: Appearance = ThemeManager.shared.currentAppearance
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
}

// MARK: - ThemeObserver

/// ObservableObject that mirrors theme and appearance changes.
@available(macOS 10.15, *)
public final class ThemeObserver: ObservableObject {
    /// Shared observer used by SwiftUI views to avoid duplicate subscriptions.
    public static let shared = ThemeObserver()
    
    @Published public var theme: Theme
    @Published public var appearance: Appearance
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        let manager = ThemeManager.shared
        self.theme = manager.currentTheme
        self.appearance = manager.currentAppearance
        
        // Observe explicit theme switches.
        manager.themePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.theme = theme
            }
            .store(in: &cancellables)
        
        // Observe appearance updates.
        manager.appearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                self?.appearance = appearance
            }
            .store(in: &cancellables)
        
        // Observe system appearance changes when the manager follows the system.
        NotificationCenter.default.publisher(for: .appearanceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.appearance = manager.currentAppearance
            }
            .store(in: &cancellables)
    }
    
    /// Resolves a themed color into a SwiftUI color.
    public func resolve(_ themedColor: ThemedColor) -> Color {
        themedColor.resolver(theme, appearance).swiftUIColor
    }
}

// MARK: - ThemedColor to SwiftUI Color

@available(macOS 10.15, *)
public extension ThemedColor {
    /// Resolves a SwiftUI color for a specific theme and appearance.
    func swiftUIColor(theme: Theme, appearance: Appearance) -> Color {
        resolver(theme, appearance).swiftUIColor
    }
    
    /// Resolves a SwiftUI color from the current theme manager state.
    var color: Color {
        let manager = ThemeManager.shared
        return resolver(manager.currentTheme, manager.currentAppearance).swiftUIColor
    }
}

// MARK: - NSColor to SwiftUI Color Extension

@available(macOS 10.15, *)
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

/// Applies a themed foreground color.
struct ThemedForegroundModifier: ViewModifier {
    let themedColor: ThemedColor
    @ObservedObject var observer = ThemeObserver.shared
    
    func body(content: Content) -> some View {
        content.foregroundColor(observer.resolve(themedColor))
    }
}

/// Applies a themed background color.
struct ThemedBackgroundModifier: ViewModifier {
    let themedColor: ThemedColor
    @ObservedObject var observer = ThemeObserver.shared
    
    func body(content: Content) -> some View {
        content.background(observer.resolve(themedColor))
    }
}

/// Applies a themed tint color.
struct ThemedTintModifier: ViewModifier {
    let themedColor: ThemedColor
    @ObservedObject var observer = ThemeObserver.shared
    
    func body(content: Content) -> some View {
        if #available(macOS 12.0, *) {
            content.tint(observer.resolve(themedColor))
        } else {
            content.accentColor(observer.resolve(themedColor))
        }
    }
}

/// Applies a themed border.
struct ThemedBorderModifier: ViewModifier {
    let themedColor: ThemedColor
    let width: CGFloat
    @ObservedObject var observer = ThemeObserver.shared
    
    func body(content: Content) -> some View {
        content.border(observer.resolve(themedColor), width: width)
    }
}

/// Applies a themed shadow color.
struct ThemedShadowModifier: ViewModifier {
    let themedColor: ThemedColor
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
    @ObservedObject var observer = ThemeObserver.shared
    
    func body(content: Content) -> some View {
        content.shadow(color: observer.resolve(themedColor), radius: radius, x: x, y: y)
    }
}

// MARK: - View Extensions

public extension View {
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
    @ObservedObject var observer = ThemeObserver.shared
    
    var body: some View {
        shape.fill(observer.resolve(themedColor))
    }
}

/// Shape stroke view backed by a themed color.
struct ThemedShapeStroke<S: Shape>: View {
    let shape: S
    let themedColor: ThemedColor
    let lineWidth: CGFloat
    @ObservedObject var observer = ThemeObserver.shared
    
    var body: some View {
        shape.stroke(observer.resolve(themedColor), lineWidth: lineWidth)
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
    @ObservedObject var observer = ThemeObserver.shared
    
    public init(_ text: String, color: ThemedColor) {
        self.text = text
        self.themedColor = color
    }
    
    public var body: some View {
        Text(text)
            .foregroundColor(observer.resolve(themedColor))
    }
}
