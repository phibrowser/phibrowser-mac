// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

public enum DefaultColors {
    public static let themeColor = ColorPair(
        light: NSColor(hex: 0x3AA4D5),
        dark: NSColor(hex: 0x1E7099)
    )
    
    public static let extensionActonColor = ColorPair(
        light: NSColor(hex: 0x2DC882),
        dark: NSColor(hex: 0x168A55)
    )
    
    public static let themeColorOnHover = ColorPair(
        light: NSColor(hex: 0x248AB9),
        dark: NSColor(hex: 0x368CB7)
    )
    
    public static let textPrimary = ColorPair(
        light: .black.withAlphaComponent(0.85),
        dark: .white.withAlphaComponent(0.8)
    )
    
    public static let textPrimaryStrong = ColorPair(
        light: .black.withAlphaComponent(1),
        dark: .white.withAlphaComponent(1)
    )
    
    public static let textSecondary = ColorPair(
        light: NSColor(white: 0.4, alpha: 1),
        dark: NSColor(white: 0.7, alpha: 1)
    )
    
    public static let textTertiary = ColorPair(
        light: NSColor(white: 0, alpha: 0.3),
        dark: NSColor(white: 1, alpha: 0.3)
    )
    
    public static let windowOverlayBackground = ColorPair(
        light: NSColor(hex: 0xCCCCCC, alpha: 0.4),
        dark:  NSColor(hex: 0x0B2938, alpha: 0.6)
    )
    
    public static let windowBackground = ColorPair(
        light:  NSColor(hex: 0xEAEAEA),
        dark: NSColor(hex: 0x252525)
    )
    
    public static let settingItemBackground = ColorPair(
        light:  NSColor.black.withAlphaComponent(0.02),
        dark: NSColor.white.withAlphaComponent(0.02)
    )
    
    public static let sidebarTabSelectedBackground = ColorPair(
        light: NSColor(white: 1, alpha: 1),
        dark: NSColor(white: 0, alpha: 0.3)
    )
    
    public static let sidebarTabHoveredBackground = ColorPair(
        light: NSColor(white: 0, alpha: 0.04),
        dark: NSColor(white: 1, alpha: 0.04)
    )
    
    public static let border = ColorPair(
        light: NSColor(white: 0, alpha:0.08),
        dark: NSColor(white: 1, alpha:0.08)
    )
    
    public static let separator = ColorPair(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    
    public static func colorPair(for role: ColorRole) -> ColorPair {
        switch role {
        case .themeColor:                   return themeColor
        case .themeColorOnHover:            return themeColorOnHover
        case .textPrimary:                  return textPrimary
        case .textPrimaryStrong:            return textPrimaryStrong
        case .textSecondary:                return textSecondary
        case .textTertiary:                 return textTertiary
        case .windowOverlayBackground:      return windowOverlayBackground
        case .windowBackground:             return windowBackground
        case .settingItemBackground:        return settingItemBackground
        case .sidebarTabSelectedBackground: return sidebarTabSelectedBackground
        case .sidebarTabHoveredBackground:  return sidebarTabHoveredBackground
        case .border:                       return border
        case .separator:                    return separator
        case .extensionActonColor:          return extensionActonColor
        }
    }
    
    public static func color(for role: ColorRole, appearance: Appearance) -> NSColor {
        colorPair(for: role).color(for: appearance)
    }
}
