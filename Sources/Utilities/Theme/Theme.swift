// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// A semantic color pair for light and dark appearance.
public struct ColorPair: Hashable {
    public let light: NSColor
    public let dark: NSColor
    
    public init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }
    
    /// Initializes a color pair that uses the same color for both appearances.
    public init(_ color: NSColor) {
        self.light = color
        self.dark = color
    }
    
    /// Resolves the color for a specific appearance.
    public func color(for appearance: Appearance) -> NSColor {
        appearance.isDark ? dark : light
    }
}

/// Theme definition backed by semantic color roles.
public class Theme: NSObject {
    public let id: String
    public let name: String
    private var colorPalette: [ColorRole: ColorPair]
    
    public init(id: String, name: String, colorPalette: [ColorRole: ColorPair] = [:]) {
        self.id = id
        self.name = name
        self.colorPalette = colorPalette
        super.init()
    }
    
    /// Resolves a color for the given role and appearance.
    public func color(for role: ColorRole, appearance: Appearance) -> NSColor {
        guard let pair = colorPalette[role] else {
            return DefaultColors.color(for: role, appearance: appearance)
        }
        return pair.color(for: appearance)
    }
    
    /// Sets the color pair for a semantic role.
    public func setColor(_ pair: ColorPair, for role: ColorRole) {
        colorPalette[role] = pair
    }
    
    /// Sets light and dark colors for a semantic role.
    public func setColor(light: NSColor, dark: NSColor, for role: ColorRole) {
        colorPalette[role] = ColorPair(light: light, dark: dark)
    }
    
    // MARK: - Hashable
    
    public override var hash: Int {
        id.hashValue
    }
    
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Theme else { return false }
        return id == other.id
    }
}

// MARK: - Default Theme

public extension Theme {
    /// Default built-in theme.
    static let `default` = Theme(id: "default", name: "Default")
}
