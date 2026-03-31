// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Represents the system appearance mode.
@objc(PhiAppearance)
public enum Appearance: Int, RawRepresentable, Equatable, CustomStringConvertible {
    case light = 1
    case dark
    
    public var description: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        }
    }
    
    public mutating func toggle() {
        self = opposite
    }
    
    public var opposite: Appearance {
        switch self {
        case .light: return .dark
        case .dark: return .light
        }
    }
    
    public var isLight: Bool { self == .light }
    public var isDark: Bool { self == .dark }
}

// MARK: - NSAppearance Extension

public extension NSAppearance {
    /// Returns the mapped `Appearance` value for the current NSAppearance.
    var phiAppearance: Appearance {
        if #available(macOS 10.14, *) {
            return bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        } else {
            return .light
        }
    }
}

public extension Appearance {
    /// Converts the appearance value to `NSAppearance`.
    var nsAppearance: NSAppearance? {
        if #available(macOS 10.14, *) {
            return NSAppearance(named: isLight ? .aqua : .darkAqua)
        } else {
            return isLight ? NSAppearance(named: .aqua) : nil
        }
    }
}

/// Returns the current application appearance.
public var appAppearance: Appearance {
    NSApp.effectiveAppearance.phiAppearance
}
