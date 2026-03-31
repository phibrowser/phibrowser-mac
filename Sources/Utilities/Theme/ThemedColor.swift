// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Theme-aware color that resolves against the current theme and appearance.
public struct ThemedColor {
    /// Resolver that produces the final NSColor.
    public let resolver: (Theme, Appearance) -> NSColor
    
    // MARK: - Initializers
    
    /// Creates a themed color from a custom resolver.
    public init(_ resolver: @escaping (Theme, Appearance) -> NSColor) {
        self.resolver = resolver
    }
    
    /// Creates a themed color from a color role.
    public init(role: ColorRole) {
        self.resolver = { theme, appearance in
            theme.color(for: role, appearance: appearance)
        }
    }
    
    /// Creates a themed color from explicit light/dark variants.
    public init(light: NSColor, dark: NSColor) {
        self.resolver = { _, appearance in
            appearance.isDark ? dark : light
        }
    }
    
    /// Creates a themed color that always resolves to the same NSColor.
    public init(_ color: NSColor) {
        self.resolver = { _, _ in color }
    }
    
    /// Creates a themed color from light and dark hex values.
    public init(lightHex: Int, darkHex: Int) {
        let light = NSColor(hex: lightHex)
        let dark = NSColor(hex: darkHex)
        self.init(light: light, dark: dark)
    }
    
    // MARK: - Custom Color Factory
    
    /// Creates a custom color that does not vary with appearance.
    public static func custom(_ color: NSColor) -> ThemedColor {
        ThemedColor(color)
    }
    
    /// Creates a custom light/dark color pair.
    public static func custom(light: NSColor, dark: NSColor) -> ThemedColor {
        ThemedColor(light: light, dark: dark)
    }
    
    /// Creates a custom color from hex values.
    public static func custom(lightHex: Int, darkHex: Int) -> ThemedColor {
        ThemedColor(lightHex: lightHex, darkHex: darkHex)
    }
    
    // MARK: - Resolve
    
    /// Resolves the color using the supplied theme and appearance.
    public func resolve(theme: Theme, appearance: Appearance) -> NSColor {
        resolver(theme, appearance)
    }
    
    /// Resolves the color using the current theme and appearance.
    public func resolved() -> NSColor {
        let manager = ThemeManager.shared
        return resolver(manager.currentTheme, manager.currentAppearance)
    }
    
    /// Creates an NSColor that tracks theme and appearance changes.
    public func dynamicColor() -> NSColor {
        if #available(macOS 10.15, *) {
            return NSColor(name: nil) { appearance in
                let manager = ThemeManager.shared
                let phiAppearance = appearance.phiAppearance
                return self.resolver(manager.currentTheme, phiAppearance)
            }
        } else {
            return resolved()
        }
    }
    
    // MARK: - Alpha Modification
    
    /// Returns a themed color with the supplied alpha applied.
    public func withAlphaComponent(_ alpha: CGFloat) -> ThemedColor {
        let originalResolver = self.resolver
        return ThemedColor { theme, appearance in
            originalResolver(theme, appearance).withAlphaComponent(alpha)
        }
    }
    
    /// Returns a themed color with SwiftUI-style opacity naming.
    public func opacity(_ opacity: CGFloat) -> ThemedColor {
        withAlphaComponent(opacity)
    }
}

// MARK: - Color Convertible Protocol

/// Protocol for values that can be converted to NSColor.
public protocol ColorConvertible {
    func asColor() -> NSColor
}

extension NSColor: ColorConvertible {
    public func asColor() -> NSColor { self }
}

extension Int: ColorConvertible {
    public func asColor() -> NSColor {
        NSColor(hex: self)
    }
}

extension String: ColorConvertible {
    public func asColor() -> NSColor {
        NSColor(hexString: self)
    }
}

// MARK: - NSColor Hex Extension

public extension NSColor {
    /// Creates a color from a hex integer.
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
    
}
