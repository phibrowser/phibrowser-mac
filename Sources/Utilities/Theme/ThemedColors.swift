// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

// MARK: - Predefined Themed Colors

public extension ThemedColor {

    static let themeColor = ThemedColor(role: .themeColor)
    
    static let themeColorOnHover = ThemedColor(role: .themeColorOnHover)

    static let extensionActonColor = ThemedColor(role: .extensionActonColor)

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

    /// Neutral background for the omnibox and tab search, independent of Space theme colors.
    static let searchPanelBackground = ThemedColor(lightHex: 0xFFFFFF, darkHex: 0x383838)

    /// Neutral content overlay background, independent of Space theme colors.
    static let contentOverlayBackground = ThemedColor(lightHex: 0xFFFFFF, darkHex: 0x212121)

    /// Default page backing and split gaps, matching the header's fallback surface.
    static let extensionSurfaceBackground = ThemedColor { theme, appearance in
        theme.extensionSurfaceBackground(for: appearance)
    }

    /// Shared frame around separated page and Chat/panel cards.
    static let separatedContentFrameBackground = ThemedColor { _, appearance in
        appearance.isDark
            ? NSColor.black.withAlphaComponent(0.60)
            : NSColor.white.withAlphaComponent(0.60)
    }

    /// Background for tabs in the temporary multi-selection (excluding the active tab).
    /// Pure uses a relative neutral overlay so the selection stays visible
    /// across its adjustable light-background brightness range.
    static let tabSubSelectionBackground = ThemedColor { theme, appearance in
        if theme.id == Theme.pure.id, appearance.isLight {
            return NSColor.black.withAlphaComponent(0.08)
        }

        return appearance.isLight
            ? NSColor(white: 0.9, alpha: 1)
            : NSColor.white.withAlphaComponent(0.18)
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

extension Theme {
    /// Incognito theme — dedicated theme for private browsing windows.
    static let incognito: Theme = {
        let theme = Theme(id: "incognito", name: "Incognito")
        theme.setColor(light: NSColor(hex: 0x383838).withAlphaComponent(0.8),
                       dark:  NSColor(hex: 0x383838).withAlphaComponent(0.8),
                       for: .windowOverlayBackground)
        return theme
    }()
}

private func makeDesignTheme(
    id: String,
    name: String,
    lightOverlay: Int,
    lightBackground: Int,
    lightThemeColor: Int,
    lightExtensionAction: Int,
    darkOverlay: Int,
    darkBackground: Int,
    darkThemeColor: Int,
    darkExtensionAction: Int
) -> Theme {
    let theme = Theme(id: id, name: name)
    let lightTheme = NSColor(hex: lightThemeColor)
    let darkTheme = NSColor(hex: darkThemeColor)

    theme.setColor(
        light: NSColor(hex: lightOverlay, alpha: ThemeDefaults.overlayLightOpacity),
        dark: NSColor(hex: darkOverlay, alpha: ThemeDefaults.overlayDarkOpacity),
        for: .windowOverlayBackground
    )
    theme.setColor(
        light: NSColor(hex: lightBackground),
        dark: NSColor(hex: darkBackground),
        for: .windowBackground
    )
    theme.setColor(light: lightTheme, dark: darkTheme, for: .themeColor)
    theme.setColor(
        light: NSColor(hex: lightExtensionAction),
        dark: NSColor(hex: darkExtensionAction),
        for: .extensionActonColor
    )
    theme.setColor(
        // Figma does not define hover explicitly; keep hue/saturation and adjust brightness per spec.
        light: lightTheme.adjustingBrightness(percent: -5),
        dark: darkTheme.adjustingBrightness(percent: 5),
        for: .themeColorOnHover
    )

    return theme
}

// MARK: - Built-In Themes

public extension Theme {
    static let pure = makeDesignTheme(
        id: "pure",
        name: NSLocalizedString("themes.theme.pure.name", value: "Pure", comment: "Pure theme name"),
        lightOverlay: 0xFFFFFF,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0x3AA4D5,
        lightExtensionAction: 0x2DC882,
        darkOverlay: 0x383838,
        darkBackground: 0x383838,
        darkThemeColor: 0x1E7099,
        darkExtensionAction: 0x168A55
    )

    static let mist = makeDesignTheme(
        id: "mist",
        name: NSLocalizedString("themes.theme.mist.name", value: "Mist", comment: "Mist theme color name"),
        lightOverlay: 0x66CCFF,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0x57AED9,
        lightExtensionAction: 0x2DC882,
        darkOverlay: 0x0B2938,
        darkBackground: 0x0B2938,
        darkThemeColor: 0x1E7099,
        darkExtensionAction: 0x168A55
    )
    
    static let mint = makeDesignTheme(
        id: "mint",
        name: NSLocalizedString("themes.theme.mint.name", value: "Mint", comment: "Mint theme color name"),
        lightOverlay: 0x8AE25A,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0x73BD4B,
        lightExtensionAction: 0x4BB7BD,
        darkOverlay: 0x1B380B,
        darkBackground: 0x1B380B,
        darkThemeColor: 0x48802A,
        darkExtensionAction: 0x2A7B80
    )

    static let aqua = makeDesignTheme(
        id: "aqua",
        name: NSLocalizedString("themes.theme.aqua.name", value: "Aqua", comment: "Aqua theme color name"),
        lightOverlay: 0x5BDEE3,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0x4BB9BD,
        lightExtensionAction: 0x4B84BD,
        darkOverlay: 0x0B3738,
        darkBackground: 0x0B3738,
        darkThemeColor: 0x2A7D80,
        darkExtensionAction: 0x2A5280
    )

    static let iris = makeDesignTheme(
        id: "iris",
        name: NSLocalizedString("themes.theme.iris.name", value: "Iris", comment: "Iris theme color name"),
        lightOverlay: 0x7566FF,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0x6357D9,
        lightExtensionAction: 0xB857D9,
        darkOverlay: 0x100B38,
        darkBackground: 0x100B38,
        darkThemeColor: 0x3D339C,
        darkExtensionAction: 0x82339C
    )

    static let petal = makeDesignTheme(
        id: "petal",
        name: NSLocalizedString("themes.theme.petal.name", value: "Petal", comment: "Petal theme color name"),
        lightOverlay: 0xD966FF,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0xB857D9,
        lightExtensionAction: 0x4B84BD,
        darkOverlay: 0x2D0B38,
        darkBackground: 0x2D0B38,
        darkThemeColor: 0x82339C,
        darkExtensionAction: 0x2A5280
    )

    static let coral = makeDesignTheme(
        id: "coral",
        name: NSLocalizedString("themes.theme.coral.name", value: "Coral", comment: "Coral theme color name"),
        lightOverlay: 0xFF6666,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0xD95757,
        lightExtensionAction: 0xD9B857,
        darkOverlay: 0x380B0B,
        darkBackground: 0x380B0B,
        darkThemeColor: 0x9C3E3E,
        darkExtensionAction: 0x9C8133
    )

    static let amber = makeDesignTheme(
        id: "amber",
        name: NSLocalizedString("themes.theme.amber.name", value: "Amber", comment: "Amber theme color name"),
        lightOverlay: 0xFFD966,
        lightBackground: 0xFFFFFF,
        lightThemeColor: 0xD9B857,
        lightExtensionAction: 0xD95757,
        darkOverlay: 0x382D0B,
        darkBackground: 0x382D0B,
        darkThemeColor: 0x9C8133,
        darkExtensionAction: 0x9C3E3E
    )

    static let builtInThemes: [Theme] = [
        .pure,
        .mint,
        .mist,
        .aqua,
        .iris,
        .petal,
        .coral,
        .amber
    ]
}
