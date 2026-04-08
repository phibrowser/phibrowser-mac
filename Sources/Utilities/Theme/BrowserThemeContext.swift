// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// Shared theme state shape used by both the global manager and window-scoped contexts.
public protocol ThemeStateProvider: ThemeSource {
    var currentTheme: Theme { get }
    var currentAppearance: Appearance { get }
    var userAppearanceChoice: UserAppearanceChoice { get }
    var themeAppearancePublisher: PassthroughSubject<(Theme, Appearance), Never> { get }
}

extension ThemeManager: ThemeStateProvider {}

/// Initial theme configuration for a browser window.
public struct BrowserThemeConfiguration {
    public let currentTheme: Theme
    public let userAppearanceChoice: UserAppearanceChoice
    public let mirrorsSharedTheme: Bool
    public let mirrorsSharedAppearance: Bool
    
    public init(
        currentTheme: Theme,
        userAppearanceChoice: UserAppearanceChoice,
        mirrorsSharedTheme: Bool,
        mirrorsSharedAppearance: Bool
    ) {
        self.currentTheme = currentTheme
        self.userAppearanceChoice = userAppearanceChoice
        self.mirrorsSharedTheme = mirrorsSharedTheme
        self.mirrorsSharedAppearance = mirrorsSharedAppearance
    }
}

/// Resolves the initial theme configuration for a browser window.
enum BrowserThemeConfigurationResolver {
    @MainActor
    static func resolve(isIncognito: Bool) -> BrowserThemeConfiguration {
        if isIncognito {
            return BrowserThemeConfiguration(
                currentTheme: .incognito,
                userAppearanceChoice: .dark,
                mirrorsSharedTheme: false,
                mirrorsSharedAppearance: false
            )
        }
        let manager = ThemeManager.shared
        let theme = resolveTheme(id: manager.currentTheme.id, manager: manager)
        return BrowserThemeConfiguration(
            currentTheme: theme,
            userAppearanceChoice: manager.userAppearanceChoice,
            mirrorsSharedTheme: true,
            mirrorsSharedAppearance: true
        )
    }
    
    @MainActor
    private static func resolveTheme(id: String, manager: ThemeManager) -> Theme {
        if let theme = manager.registeredThemes[id] {
            return theme
        }
        if manager.currentTheme.id == id {
            return manager.currentTheme
        }
        return .default
    }
}

/// Window-scoped theme source for one browser window.
public final class BrowserThemeContext: NSObject, ThemeStateProvider {
    public private(set) var currentTheme: Theme {
        didSet {
            guard currentTheme != oldValue else { return }
            notifyThemeChange()
        }
    }
    
    public private(set) var userAppearanceChoice: UserAppearanceChoice {
        didSet {
            guard userAppearanceChoice != oldValue else { return }
            notifyAppearanceChange()
        }
    }
    
    public var currentAppearance: Appearance {
        switch userAppearanceChoice {
        case .system:
            return appAppearance
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
    
    public var windowAppearance: NSAppearance? {
        switch userAppearanceChoice {
        case .system:
            return nil
        case .light:
            return Appearance.light.nsAppearance
        case .dark:
            return Appearance.dark.nsAppearance
        }
    }
    
    public var hasFixedWindowAppearance: Bool {
        windowAppearance != nil
    }
    
    public let themePublisher = PassthroughSubject<Theme, Never>()
    public let appearancePublisher = PassthroughSubject<Appearance, Never>()
    public let themeAppearancePublisher = PassthroughSubject<(Theme, Appearance), Never>()
    
    private let mirrorsSharedTheme: Bool
    private let mirrorsSharedAppearance: Bool
    private var cancellables = Set<AnyCancellable>()
    
    @MainActor
    public init(configuration: BrowserThemeConfiguration) {
        self.currentTheme = configuration.currentTheme
        self.userAppearanceChoice = configuration.userAppearanceChoice
        self.mirrorsSharedTheme = configuration.mirrorsSharedTheme
        self.mirrorsSharedAppearance = configuration.mirrorsSharedAppearance
        super.init()
        bindSharedThemeIfNeeded()
    }
    
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        action(currentTheme, currentAppearance)
        
        let themeCancellable = themePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                guard let self else { return }
                action(theme, self.currentAppearance)
            }
        
        let appearanceCancellable = appearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                guard let self else { return }
                action(self.currentTheme, appearance)
            }
        
        return CompoundObservation([
            themeCancellable as AnyObject,
            appearanceCancellable as AnyObject
        ])
    }
    
    public func setTheme(_ theme: Theme) {
        currentTheme = theme
    }
    
    public func setUserAppearanceChoice(_ choice: UserAppearanceChoice) {
        userAppearanceChoice = choice
    }
    
    @MainActor
    private func bindSharedThemeIfNeeded() {
        let manager = ThemeManager.shared
        
        if mirrorsSharedTheme {
            manager.themePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] theme in
                    self?.currentTheme = theme
                }
                .store(in: &cancellables)
        }
        
        guard mirrorsSharedAppearance else { return }
        
        NotificationCenter.default.publisher(for: .appearanceDidChange, object: manager)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let sharedChoice = manager.userAppearanceChoice
                if self.userAppearanceChoice != sharedChoice {
                    self.userAppearanceChoice = sharedChoice
                } else if sharedChoice == .system {
                    self.notifyAppearanceChange()
                }
            }
            .store(in: &cancellables)
    }
    
    private func notifyThemeChange() {
        themePublisher.send(currentTheme)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
    }
    
    private func notifyAppearanceChange() {
        appearancePublisher.send(currentAppearance)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
    }
}

public extension NSWindow {
    var browserThemeContext: BrowserThemeContext? {
        (windowController as? MainBrowserWindowController)?.browserState.themeContext
    }
    
    var themeStateProvider: ThemeStateProvider {
        browserThemeContext ?? ThemeManager.shared
    }
}

public extension NSView {
    var browserThemeContext: BrowserThemeContext? {
        window?.browserThemeContext
    }
    
    var themeStateProvider: ThemeStateProvider {
        browserThemeContext ?? ThemeManager.shared
    }
}

public extension ThemedColor {
    func resolve(in view: NSView?) -> NSColor {
        let provider = view?.themeStateProvider ?? ThemeManager.shared
        let theme = provider.currentTheme
        let appearance = provider.currentAppearance
        return resolver(theme, appearance)
    }
    
    func resolve(in window: NSWindow?) -> NSColor {
        let provider = window?.themeStateProvider ?? ThemeManager.shared
        let theme = provider.currentTheme
        let appearance = provider.currentAppearance
        return resolver(theme, appearance)
    }
}
