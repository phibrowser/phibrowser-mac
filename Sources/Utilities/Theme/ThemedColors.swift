// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

// MARK: - Predefined Themed Colors

public extension ThemedColor {

    static let themeColor = ThemedColor(role: .themeColor)
    
    static let themeColorOnHover = ThemedColor(role: .themeColorOnHover)
    // MARK: - Text Colors
    
    /// Primary text color.
    static let textPrimary = ThemedColor(role: .textPrimary)
    
    static let textPrimaryStrong = ThemedColor(role: .textPrimaryStrong)
    
    /// Secondary text color.
    static let textSecondary = ThemedColor(role: .textSecondary)
    
    /// Tertiary text color.
    static let textTertiary = ThemedColor(role: .textTertiary)
    
    
    // MARK: - Window Colors
    
    /// Window overlay background color.
    static let windowOverlayBackground = ThemedColor(role: .windowOverlayBackground)
    
    /// Default window background color.
    static let windowBackground = ThemedColor(role: .windowBackground)

    /// Opaque content overlay background shared by the address bar, bookmark bar, active tab, and split views.
    static let contentOverlayBackground = ThemedColor { theme, appearance in
        if appearance.isLight {
            return .white
        } else {
            return windowOverlayBackground.resolve(theme: theme, appearance: appearance).withAlphaComponent(1)
        }
    }
    
    // MARK: - Sidebar Colors
    
    /// Selected sidebar tab background color.
    static let sidebarTabSelectedBackground = ThemedColor(role: .sidebarTabSelectedBackground)
    
    /// Hovered sidebar tab background color.
    static let sidebarTabHoveredBackground = ThemedColor(role: .sidebarTabHoveredBackground)
    
    static let settingItemBackground = ThemedColor(role: .settingItemBackground)
    
    /// Alias for the generic hover background color.
    static let hover = ThemedColor(role: .sidebarTabHoveredBackground)
    
    // MARK: - Border & Separator
    
    /// Border color.
    static let border = ThemedColor(role: .border)
    
    /// Separator color.
    static let separator = ThemedColor(role: .separator)
    
    // MARK: - Convenience Initializers
    
    /// Creates a themed color from a light and dark pair.
    static func pair(_ light: NSColor, _ dark: NSColor) -> ThemedColor {
        ThemedColor(light: light, dark: dark)
    }
    
    /// Creates a themed color from light and dark hex values.
    static func hex(light: Int, dark: Int) -> ThemedColor {
        ThemedColor(lightHex: light, darkHex: dark)
    }
    
    /// Transparent themed color.
    static let clear = ThemedColor(.clear)
    
    /// White themed color.
    static let white = ThemedColor(.white)
    
    /// Black themed color.
    static let black = ThemedColor(.black)
}

// MARK: - ColorConvertible to ThemedColor

public extension ColorConvertible {
    /// Wraps the value as a fixed themed color.
    var themed: ThemedColor {
        ThemedColor(asColor())
    }
}

// MARK: - NSColor Themed Extension

public extension NSColor {
    /// Creates a fixed themed color.
    var themed: ThemedColor {
        ThemedColor(self)
    }
    
    /// Creates a light and dark themed color pair.
    func themedWith(dark: NSColor) -> ThemedColor {
        ThemedColor(light: self, dark: dark)
    }
}

// MARK: - Sample Themes

public extension Theme {
    /// Ocean theme with deep blue tones.
    static let ocean: Theme = {
        let theme = Theme(id: "ocean", name: "Ocean")
        theme.setColor(light: NSColor(hex: 0xE0F7FA), dark: NSColor(hex: 0x0A1929), for: .windowOverlayBackground)
        theme.setColor(light: NSColor(hex: 0xF0FDFF), dark: NSColor(hex: 0x0D2137), for: .windowBackground)
        theme.setColor(light: NSColor(hex: 0x03045E), dark: NSColor(hex: 0xCAF0F8), for: .textPrimary)
        theme.setColor(light: NSColor(hex: 0x0077B6), dark: NSColor(hex: 0x90E0EF), for: .textSecondary)
        theme.setColor(light: NSColor(hex: 0x48CAE4), dark: NSColor(hex: 0x48CAE4), for: .textTertiary)
        return theme
    }()
    
    /// Forest theme with natural green tones.
    static let forest: Theme = {
        let theme = Theme(id: "forest", name: "Forest")
        theme.setColor(light: NSColor(hex: 0xE8F5E9), dark: NSColor(hex: 0x0D1F17), for: .windowOverlayBackground)
        theme.setColor(light: NSColor(hex: 0xF1F8E9), dark: NSColor(hex: 0x1B4332), for: .windowBackground)
        theme.setColor(light: NSColor(hex: 0x1B4332), dark: NSColor(hex: 0xD8F3DC), for: .textPrimary)
        theme.setColor(light: NSColor(hex: 0x2D6A4F), dark: NSColor(hex: 0xB7E4C7), for: .textSecondary)
        theme.setColor(light: NSColor(hex: 0x52B788), dark: NSColor(hex: 0x74C69D), for: .textTertiary)
        return theme
    }()
    
    /// Sunset theme with warm orange tones.
    static let sunset: Theme = {
        let theme = Theme(id: "sunset", name: "Sunset")
        theme.setColor(light: NSColor(hex: 0xFFF3E0).withAlphaComponent(0.4), dark: NSColor(hex: 0x1A0A00), for: .windowOverlayBackground)
        theme.setColor(light: NSColor(hex: 0xFFF8E1), dark: NSColor(hex: 0x2D1810), for: .windowBackground)
        theme.setColor(light: NSColor(hex: 0x370617), dark: NSColor(hex: 0xFFE8D6), for: .textPrimary)
        theme.setColor(light: NSColor(hex: 0x6A040F), dark: NSColor(hex: 0xFFD7BA), for: .textSecondary)
        theme.setColor(light: NSColor(hex: 0x9D0208), dark: NSColor(hex: 0xF9C784), for: .textTertiary)
        return theme
    }()
    
    /// Violet theme with rich purple tones.
    static let violet: Theme = {
        let theme = Theme(id: "violet", name: "Violet")
        theme.setColor(light: NSColor(hex: 0xF3E5F5), dark: NSColor(hex: 0x120A1F), for: .windowOverlayBackground)
        theme.setColor(light: NSColor(hex: 0xFCE4EC), dark: NSColor(hex: 0x1E1033), for: .windowBackground)
        theme.setColor(light: NSColor(hex: 0x240046), dark: NSColor(hex: 0xF3E8FF), for: .textPrimary)
        theme.setColor(light: NSColor(hex: 0x5A189A), dark: NSColor(hex: 0xE0AAFF), for: .textSecondary)
        theme.setColor(light: NSColor(hex: 0x7B2CBF), dark: NSColor(hex: 0xC77DFF), for: .textTertiary)
        return theme
    }()
}
