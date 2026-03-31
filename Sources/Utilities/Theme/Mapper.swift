// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Resolves a value from the active theme and appearance.
public struct Mapper<V> {
    public let transform: (Theme, Appearance) -> V
    
    /// Returns the value for a specific theme and appearance.
    public subscript(_ theme: Theme, _ appearance: Appearance) -> V {
        transform(theme, appearance)
    }
    
    /// Returns the value for a specific appearance using the current theme.
    public subscript(_ appearance: Appearance) -> V {
        transform(ThemeManager.shared.currentTheme, appearance)
    }
    
    // MARK: - Initializers
    
    /// Creates a mapper from a custom transform.
    public init(_ transform: @escaping (Theme, Appearance) -> V) {
        self.transform = transform
    }
    
    /// Creates a mapper from a light and dark pair.
    public init(_ lightValue: V, _ darkValue: V) {
        self.init { _, appearance in
            appearance.isDark ? darkValue : lightValue
        }
    }
    
    /// Creates a mapper that always returns the same value.
    public init(_ value: V) {
        self.init { _, _ in value }
    }
    
    // MARK: - Transformations
    
    /// Maps the resolved value into a new type.
    public func map<T>(_ transform: @escaping (V) -> T) -> Mapper<T> {
        Mapper<T> { theme, appearance in
            transform(self.transform(theme, appearance))
        }
    }
    
    /// Runs a side effect when the mapper resolves.
    public func `do`(_ action: @escaping (Theme, Appearance) -> Void) -> Mapper<V> {
        Mapper { theme, appearance in
            action(theme, appearance)
            return self.transform(theme, appearance)
        }
    }
    
    /// Logs resolved values in debug builds.
    public func debug(_ identifier: Any = #function) -> Mapper<V> {
        #if DEBUG
        return `do` { theme, appearance in
            print("\(identifier) - Theme: \(theme.id), Appearance: \(appearance) -> \(self[theme, appearance])")
        }
        #else
        return self
        #endif
    }
    
    /// Wraps the resolved value in an optional.
    public var optional: Mapper<V?> {
        map { .some($0) }
    }
    
    /// Precomputes light and dark values for the current theme.
    public func evaluated() -> Mapper<V> {
        let light = transform(ThemeManager.shared.currentTheme, .light)
        let dark = transform(ThemeManager.shared.currentTheme, .dark)
        return Mapper(light, dark)
    }
    
    /// Returns the value for the current theme manager state.
    public var currentValue: V {
        let manager = ThemeManager.shared
        return transform(manager.currentTheme, manager.currentAppearance)
    }
}

// MARK: - <> Operator

infix operator <>: AdditionPrecedence

/// Creates a mapper from a light and dark pair.
/// Use `.optional` when an optional mapper is required.
public func <> <V>(light: V, dark: V) -> Mapper<V> {
    Mapper(light, dark)
}

// MARK: - Color Specific Operators

/// Builds color mappers from `ColorConvertible` values.
public extension ColorConvertible {
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<NSColor> {
        Mapper(lhs.asColor(), rhs.asColor())
    }
    
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<NSColor?> {
        Mapper(lhs.asColor(), rhs.asColor()).optional
    }
    
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<CGColor> {
        Mapper(lhs.asColor(), rhs.asColor()).map { $0.cgColor }
    }
    
    static func <> <D: ColorConvertible>(lhs: Self, rhs: D) -> Mapper<CGColor?> {
        Mapper(lhs.asColor(), rhs.asColor()).map { $0.cgColor }.optional
    }
}

// MARK: - CGColor Extension

public extension Mapper where V: ColorConvertible {
    var cgColor: Mapper<CGColor> {
        map { $0.asColor().cgColor }
    }
}

public extension Mapper where V == NSColor? {
    var cgColor: Mapper<CGColor?> {
        map { $0?.cgColor }
    }
}

// MARK: - ThemedColor to Mapper Conversion

public extension ThemedColor {
    /// Converts the themed color into an `NSColor` mapper.
    var mapper: Mapper<NSColor> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance)
        }
    }
}

// MARK: - Mapper Convertible

public protocol MapperConvertible {}

extension MapperConvertible {
    public func asMapper() -> Mapper<Self> {
        Mapper(self)
    }
}

extension NSObject: MapperConvertible {}

extension CGColor: MapperConvertible {}
