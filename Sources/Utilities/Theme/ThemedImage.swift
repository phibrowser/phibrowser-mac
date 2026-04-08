// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

// MARK: - NSImage Tinting Extension

public extension NSImage {}

// MARK: - ThemedImage

/// Theme-aware image wrapper that resolves against the current theme and appearance.
public struct ThemedImage {
    /// Image resolver.
    public let resolver: (Theme, Appearance) -> NSImage?
    
    // MARK: - Initializers
    
    /// Creates a themed image from a custom resolver.
    public init(_ resolver: @escaping (Theme, Appearance) -> NSImage?) {
        self.resolver = resolver
    }
    
    /// Creates a themed image by tinting with a `ThemedColor`.
    /// - Parameters:
    ///   - image: Source image.
    ///   - tint: Theme-aware tint color.
    public init(_ image: NSImage, tint: ThemedColor) {
        self.resolver = { theme, appearance in
            let color = tint.resolver(theme, appearance)
            return image.tinted(with: color)
        }
    }
    
    /// Creates a themed image by tinting with a mapped `NSColor`.
    /// - Parameters:
    ///   - image: Source image.
    ///   - tint: Color mapper.
    public init(_ image: NSImage, tint: Mapper<NSColor>) {
        self.resolver = { theme, appearance in
            let color = tint[theme, appearance]
            return image.tinted(with: color)
        }
    }
    
    /// Creates a themed image from separate light and dark assets.
    /// - Parameters:
    ///   - light: Image used in light appearance.
    ///   - dark: Image used in dark appearance.
    public init(light: NSImage?, dark: NSImage?) {
        self.resolver = { _, appearance in
            appearance.isDark ? dark : light
        }
    }
    
    /// Creates a themed image from a single non-tinted asset.
    public init(_ image: NSImage?) {
        self.resolver = { _, _ in image }
    }
    
    // MARK: - Mapper Conversion
    
    /// Converts the resolver into an optional `Mapper`.
    public var mapper: Mapper<NSImage?> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance)
        }
    }
    
    /// Converts the resolver into a non-optional `Mapper` with a placeholder.
    public func mapper(placeholder: NSImage) -> Mapper<NSImage> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance) ?? placeholder
        }
    }
    
    // MARK: - Resolve
    
    /// Resolves the image using the current theme manager state.
    public func resolved() -> NSImage? {
        let manager = ThemeManager.shared
        return resolver(manager.currentTheme, manager.currentAppearance)
    }
}

// MARK: - NSImage Themed Extension (Style B)

public extension NSImage {
    /// Creates a themed tint mapper using `ThemedColor`.
    func themed(tint: ThemedColor) -> Mapper<NSImage?> {
        ThemedImage(self, tint: tint).mapper
    }
    
    /// Creates a themed tint mapper using a color mapper.
    func themed(tint: Mapper<NSColor>) -> Mapper<NSImage?> {
        ThemedImage(self, tint: tint).mapper
    }
    
    /// Creates a mapper that switches between light and dark assets.
    func themed(dark: NSImage?) -> Mapper<NSImage?> {
        ThemedImage(light: self, dark: dark).mapper
    }
}

// MARK: - Phi NSButton Image Extension

public extension Phi where Base: NSButton {
    /// Raw mapper access for `image`.
    var image: Mapper<NSImage?>? {
        get { self[\.image] }
        nonmutating set { self[\.image] = newValue }
    }
}

// MARK: - SwiftUI Image Themed Extension

/// Applies a theme-aware tint to SwiftUI images.
struct ThemedImageTintModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content
            .foregroundColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}

/// Applies the themed rendering color to SwiftUI images.
struct ThemedImageRenderingModifier: ViewModifier {
    let themedColor: ThemedColor
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    func body(content: Content) -> some View {
        content
            .foregroundColor(themedColor.swiftUIColor(theme: theme, appearance: appearance))
    }
}

public extension Image {
    /// Applies a theme-aware tint to the image.
    func themedTint(_ color: ThemedColor) -> some View {
        self.renderingMode(.template)
            .modifier(ThemedImageTintModifier(themedColor: color))
    }
}

// MARK: - SwiftUI View for Themed NSImage

/// SwiftUI view that renders a themed `NSImage`.
public struct ThemedImageView: View {
    let themedImage: ThemedImage
    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    
    public init(_ themedImage: ThemedImage) {
        self.themedImage = themedImage
    }
    
    public init(_ image: NSImage, tint: ThemedColor) {
        self.themedImage = ThemedImage(image, tint: tint)
    }
    
    public init(light: NSImage?, dark: NSImage?) {
        self.themedImage = ThemedImage(light: light, dark: dark)
    }
    
    public var body: some View {
        if let nsImage = themedImage.resolver(theme, appearance) {
            Image(nsImage: nsImage)
                .resizable()
        } else {
            EmptyView()
        }
    }
}

// MARK: - Convenience Extensions

public extension ThemedImage {
    /// Creates a themed image from an SF Symbol.
    @available(macOS 11.0, *)
    static func symbol(_ name: String, tint: ThemedColor) -> ThemedImage {
        ThemedImage { theme, appearance in
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                return nil
            }
            let color = tint.resolver(theme, appearance)
            return image.tinted(with: color)
        }
    }
    
    /// Creates a themed image from an asset catalog entry.
    static func asset(_ name: String, tint: ThemedColor? = nil) -> ThemedImage {
        ThemedImage { theme, appearance in
            guard let image = NSImage(named: name) else {
                return nil
            }
            if let tint = tint {
                let color = tint.resolver(theme, appearance)
                return image.tinted(with: color)
            }
            return image
        }
    }
}
