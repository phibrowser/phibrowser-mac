// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

// MARK: - ThemedColor Extensions for Mapper Conversion

public extension ThemedColor {
    /// Converts the themed color into an optional `NSColor` mapper.
    var nsColorMapper: Mapper<NSColor?> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance)
        }.optional
    }
    
    /// Converts the themed color into an optional `CGColor` mapper.
    var cgColorMapperOptional: Mapper<CGColor?> {
        Mapper { theme, appearance in
            self.resolver(theme, appearance).cgColor
        }.optional
    }
}

// MARK: - NSView as ThemeSource

extension NSView: ThemeSource {
    /// Subscribes to theme and appearance changes.
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        return _subscribeToThemeChanges(action)
    }
    
    /// Current appearance resolved from `effectiveAppearance`.
    public var currentAppearance: Appearance {
        themeStateProvider.currentAppearance
    }
    
    /// Theme binder that uses this view as its source.
    public var phi: Phi<NSView> {
        get { Phi(self, self) }
        set {}
    }
    
    /// Convenience access to the layer binder.
    public var phiLayer: Phi<CALayer>? {
        guard let layer = layer else { return nil }
        return layer.phi(source: self)
    }
}

// MARK: - NSApplication as ThemeSource

extension NSApplication: ThemeSource {
    /// Subscribes to theme and appearance changes.
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        return _subscribeToThemeChanges(action)
    }
    
    /// Current appearance resolved from `effectiveAppearance`.
    public var currentAppearance: Appearance {
        ThemeManager.shared.currentAppearance
    }
    
    /// Whether the current appearance is dark.
    @objc public var isDarkMode: Bool {
        currentAppearance.isDark
    }
}

// MARK: - Private Subscription Helpers

private final class ViewThemeObservation {
    private weak var view: NSView?
    private let action: (Theme, Appearance) -> Void
    private weak var currentProvider: ThemeStateProvider?
    private var providerSubscription: AnyObject?
    private var appearanceObservation: NSKeyValueObservation?
    private var windowObservation: NSKeyValueObservation?
    
    init(view: NSView, action: @escaping (Theme, Appearance) -> Void) {
        self.view = view
        self.action = action
        
        bindProviderIfNeeded()
        emitCurrentState()
        
        if #available(macOS 10.14, *) {
            appearanceObservation = view.observe(\.effectiveAppearance, options: [.old, .new]) { [weak self] _, change in
                guard let self, change.oldValue != change.newValue else { return }
                self.bindProviderIfNeeded()
                self.emitCurrentState()
            }
        }
        
        windowObservation = view.observe(\.window, options: [.old, .new]) { [weak self] _, change in
            guard let self else { return }
            let oldWindow = change.oldValue ?? nil
            let newWindow = change.newValue ?? nil
            if oldWindow === newWindow {
                return
            }
            self.bindProviderIfNeeded()
            self.emitCurrentState()
        }
    }
    
    private func bindProviderIfNeeded() {
        guard let view else { return }
        let provider = view.themeStateProvider
        guard currentProvider !== provider else { return }
        
        currentProvider = provider
        providerSubscription = provider.subscribe { [weak self] _, _ in
            self?.emitCurrentState()
        }
    }
    
    private func emitCurrentState() {
        guard let view else { return }
        let provider = view.themeStateProvider
        action(provider.currentTheme, provider.currentAppearance)
    }
}

private extension NSView {
    func _subscribeToThemeChanges(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        ViewThemeObservation(view: self, action: action)
    }
}

private extension NSApplication {
    func _subscribeToThemeChanges(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        let manager = ThemeManager.shared
        
        // Apply the current state immediately.
        action(manager.currentTheme, manager.currentAppearance)
        
        var observations: [AnyObject] = []
        
        if #available(macOS 10.14, *) {
            let appearanceObs = observe(\.effectiveAppearance, options: [.old, .new]) { _, change in
                guard change.oldValue != change.newValue else { return }
                action(manager.currentTheme, self.currentAppearance)
            }
            observations.append(appearanceObs)
        }
        
        let providerSubscription = manager.subscribe { theme, _ in
            action(theme, self.currentAppearance)
        }
        observations.append(providerSubscription)
        
        return CompoundObservation(observations)
    }
}

// MARK: - NSTextField Phi Extensions

public extension Phi where Base: NSTextField {
    /// Sets the text color from a themed color.
    func setTextColor(_ value: ThemedColor) {
        self[\.textColor] = value.nsColorMapper
    }
    
    /// Sets the text color from a non-optional mapper.
    func setTextColor(_ value: Mapper<NSColor>) {
        self[\.textColor] = value.optional
    }
    
    /// Sets the text color from an optional mapper.
    func setTextColor(_ value: Mapper<NSColor?>) {
        self[\.textColor] = value
    }
    
    /// Sets the background color from a themed color.
    func setBackgroundColor(_ value: ThemedColor) {
        self[\.backgroundColor] = value.nsColorMapper
    }
    
    /// Sets the background color from a non-optional mapper.
    func setBackgroundColor(_ value: Mapper<NSColor>) {
        self[\.backgroundColor] = value.optional
    }
    
    /// Sets the background color from an optional mapper.
    func setBackgroundColor(_ value: Mapper<NSColor?>) {
        self[\.backgroundColor] = value
    }
    
    /// Raw mapper access for `textColor`.
    var textColor: Mapper<NSColor?>? {
        get { self[\.textColor] }
        nonmutating set { self[\.textColor] = newValue }
    }
    
    /// Raw mapper access for `backgroundColor`.
    var backgroundColor: Mapper<NSColor?>? {
        get { self[\.backgroundColor] }
        nonmutating set { self[\.backgroundColor] = newValue }
    }
}

// MARK: - NSButton Phi Extensions

public extension Phi where Base: NSButton {
    /// Sets the content tint color from a themed color.
    func setContentTintColor(_ value: ThemedColor) {
        self[\.contentTintColor] = value.nsColorMapper
    }
    
    /// Sets the content tint color from a non-optional mapper.
    func setContentTintColor(_ value: Mapper<NSColor>) {
        self[\.contentTintColor] = value.optional
    }
    
    /// Sets the content tint color from an optional mapper.
    func setContentTintColor(_ value: Mapper<NSColor?>) {
        self[\.contentTintColor] = value
    }
    
    /// Raw mapper access for `title`.
    var title: Mapper<String>? {
        get { self[\.title] }
        nonmutating set { self[\.title] = newValue }
    }
    
    /// Raw mapper access for `attributedTitle`.
    var attributedTitle: Mapper<NSAttributedString>? {
        get { self[\.attributedTitle] }
        nonmutating set { self[\.attributedTitle] = newValue }
    }
    
    /// Raw mapper access for `contentTintColor`.
    var contentTintColor: Mapper<NSColor?>? {
        get { self[\.contentTintColor] }
        nonmutating set { self[\.contentTintColor] = newValue }
    }
}

// MARK: - NSView Phi Extensions

public extension Phi where Base: NSView {
    /// Raw mapper access for `isHidden`.
    var isHidden: Mapper<Bool>? {
        get { self[\.isHidden] }
        nonmutating set { self[\.isHidden] = newValue }
    }
    
    /// Raw mapper access for `alphaValue`.
    var alphaValue: Mapper<CGFloat>? {
        get { self[\.alphaValue] }
        nonmutating set { self[\.alphaValue] = newValue }
    }
}

// MARK: - NSImageView Phi Extensions

public extension Phi where Base: NSImageView {
    /// Sets the content tint color from a themed color.
    func setContentTintColor(_ value: ThemedColor) {
        self[\.contentTintColor] = value.nsColorMapper
    }
    
    /// Sets the content tint color from a non-optional mapper.
    func setContentTintColor(_ value: Mapper<NSColor>) {
        self[\.contentTintColor] = value.optional
    }
    
    /// Sets the content tint color from an optional mapper.
    func setContentTintColor(_ value: Mapper<NSColor?>) {
        self[\.contentTintColor] = value
    }
    
    /// Raw mapper access for `image`.
    var image: Mapper<NSImage?>? {
        get { self[\.image] }
        nonmutating set { self[\.image] = newValue }
    }
    
    /// Raw mapper access for `contentTintColor`.
    var contentTintColor: Mapper<NSColor?>? {
        get { self[\.contentTintColor] }
        nonmutating set { self[\.contentTintColor] = newValue }
    }
}

// MARK: - CALayer Phi Extensions

public extension Phi where Base: CALayer {
    /// Sets the background color from a themed color.
    func setBackgroundColor(_ value: ThemedColor) {
        self[\.backgroundColor] = value.cgColorMapperOptional
    }

    /// Sets the background color from a non-optional mapper.
    func setBackgroundColor(_ value: Mapper<CGColor>) {
        self[\.backgroundColor] = value.optional
    }
    
    /// Sets the background color from an optional mapper.
    func setBackgroundColor(_ value: Mapper<CGColor?>) {
        self[\.backgroundColor] = value
    }
    
    /// Sets the border color from a themed color.
    func setBorderColor(_ value: ThemedColor) {
        self[\.borderColor] = value.cgColorMapperOptional
    }
    
    /// Sets the border color from a non-optional mapper.
    func setBorderColor(_ value: Mapper<CGColor>) {
        self[\.borderColor] = value.optional
    }
    
    /// Sets the border color from an optional mapper.
    func setBorderColor(_ value: Mapper<CGColor?>) {
        self[\.borderColor] = value
    }
    
    /// Sets the shadow color from a themed color.
    func setShadowColor(_ value: ThemedColor) {
        self[\.shadowColor] = value.cgColorMapperOptional
    }
    
    /// Sets the shadow color from a non-optional mapper.
    func setShadowColor(_ value: Mapper<CGColor>) {
        self[\.shadowColor] = value.optional
    }
    
    /// Sets the shadow color from an optional mapper.
    func setShadowColor(_ value: Mapper<CGColor?>) {
        self[\.shadowColor] = value
    }
    
    /// Raw mapper access for `backgroundColor`.
    var backgroundColor: Mapper<CGColor?>? {
        get { self[\.backgroundColor] }
        nonmutating set { self[\.backgroundColor] = newValue }
    }
    
    /// Raw mapper access for `borderColor`.
    var borderColor: Mapper<CGColor?>? {
        get { self[\.borderColor] }
        nonmutating set { self[\.borderColor] = newValue }
    }
    
    /// Raw mapper access for `shadowColor`.
    var shadowColor: Mapper<CGColor?>? {
        get { self[\.shadowColor] }
        nonmutating set { self[\.shadowColor] = newValue }
    }
}
