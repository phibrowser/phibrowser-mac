// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine

/// Theme change notifications.
public extension Notification.Name {
    static let themeDidChange = Notification.Name("PhiThemeDidChangeNotification")
    static let appearanceDidChange = Notification.Name("PhiAppearanceDidChangeNotification")
}

/// User-selectable appearance modes.
public enum UserAppearanceChoice: Int, CaseIterable, Codable {
    case system = 0
    case light = 1
    case dark = 2
    
    public var localizedName: String {
        switch self {
        case .system:
            return NSLocalizedString("System", comment: "Appearance choice: follow system setting")
        case .light:
            return NSLocalizedString("Light", comment: "Appearance choice: always light mode")
        case .dark:
            return NSLocalizedString("Dark", comment: "Appearance choice: always dark mode")
        }
    }
}

/// Coordinates the active theme and appearance settings.
public final class ThemeManager: NSObject, ThemeSource {
    
    // MARK: - Singleton
    @MainActor
    public static let shared = ThemeManager()
    
    // MARK: - Properties
    
    /// Currently selected theme.
    @objc dynamic public var currentTheme: Theme {
        didSet {
            if currentTheme != oldValue {
                UserDefaults.standard.set(currentTheme.id, forKey: PhiPreferences.ThemeSettings.currentThemeId.rawValue)
                notifyThemeChange()
            }
        }
    }
    
    /// User-selected appearance mode.
    public var userAppearanceChoice: UserAppearanceChoice = .system {
        didSet {
            if userAppearanceChoice != oldValue {
                UserDefaults.standard.set(userAppearanceChoice.rawValue, forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue)
                updateAppearanceMode()
                notifyAppearanceChange()
            }
        }
    }
    
    /// Internal appearance mode derived from the user preference.
    public enum AppearanceMode {
        case system
        case manual(Appearance)
    }
    
    /// Current appearance mode derived from `userAppearanceChoice`.
    public private(set) var appearanceMode: AppearanceMode = .system
    
    /// Effective appearance resolved from the current mode.
    public var currentAppearance: Appearance {
        switch appearanceMode {
        case .system:
            return appAppearance
        case .manual(let appearance):
            return appearance
        }
    }
    
    /// Registered themes keyed by theme identifier.
    private(set) public var registeredThemes: [String: Theme] = [:]
    
    /// Theme ID to restore once that theme is registered.
    private var pendingThemeId: String?
    
    /// Observation token for system appearance changes.
    private var appearanceObservation: NSKeyValueObservation?
    
    // MARK: - Combine Publishers
    
    /// Publishes theme changes.
    public let themePublisher = PassthroughSubject<Theme, Never>()
    
    /// Publishes appearance changes.
    public let appearancePublisher = PassthroughSubject<Appearance, Never>()
    
    /// Publishes combined theme and appearance updates.
    public let themeAppearancePublisher = PassthroughSubject<(Theme, Appearance), Never>()
    
    // MARK: - Initialization
    
    private override init() {
        self.currentTheme = Theme.default
        super.init()
        
        Theme.builtInThemes.forEach(registerTheme)
        
        restoreUserPreferences()
        
        setupAppearanceObservation()
    }
    
    /// Restores saved theme and appearance preferences from `UserDefaults`.
    private func restoreUserPreferences() {
        let savedChoice = UserDefaults.standard.integer(forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue)
        if let choice = UserAppearanceChoice(rawValue: savedChoice) {
            userAppearanceChoice = choice
        }
        updateAppearanceMode()
        
        if let themeId = UserDefaults.standard.string(forKey: PhiPreferences.ThemeSettings.currentThemeId.rawValue) {
            if let theme = registeredThemes[themeId] {
                currentTheme = theme
            } else {
                pendingThemeId = themeId
            }
        }
    }
    
    /// Updates the active appearance mode from the user preference.
    private func updateAppearanceMode() {
        switch userAppearanceChoice {
        case .system:
            appearanceMode = .system
            NSApp.appearance = nil
        case .light:
            appearanceMode = .manual(.light)
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            appearanceMode = .manual(.dark)
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
    
    // MARK: - Theme Registration
    
    /// Registers a theme.
    public func registerTheme(_ theme: Theme) {
        registeredThemes[theme.id] = theme
        
        if let pending = pendingThemeId, pending == theme.id {
            currentTheme = theme
            pendingThemeId = nil
        }
    }
    
    /// Unregisters a non-default theme.
    public func unregisterTheme(id: String) {
        guard id != Theme.default.id else { return }
        registeredThemes.removeValue(forKey: id)
    }
    
    /// Switches to a registered theme.
    public func switchTheme(to themeId: String) {
        guard let theme = registeredThemes[themeId] else { return }
        currentTheme = theme
    }
    
    // MARK: - Appearance
    
    /// Sets the user appearance preference.
    public func setUserAppearanceChoice(_ choice: UserAppearanceChoice) {
        userAppearanceChoice = choice
    }
    
    /// Switches appearance handling back to the system setting.
    public func followSystemAppearance() {
        userAppearanceChoice = .system
    }
    
    /// Forces a specific appearance.
    public func setAppearance(_ appearance: Appearance) {
        switch appearance {
        case .light:
            userAppearanceChoice = .light
        case .dark:
            userAppearanceChoice = .dark
        }
    }
    
    // MARK: - ThemeSource Protocol
    
    public func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject {
        action(currentTheme, currentAppearance)
        
        let themeObservation = observe(\.currentTheme, options: [.new]) { [weak self] _, _ in
            guard let self = self else { return }
            action(self.currentTheme, self.currentAppearance)
        }
        
        let notificationObserver = NotificationCenter.default.addObserver(
            forName: .appearanceDidChange,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            action(self.currentTheme, self.currentAppearance)
        }
        
        return CompoundObservation([themeObservation, notificationObserver as AnyObject])
    }
    
    // MARK: - Private Methods
    
    private func setupAppearanceObservation() {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.old, .new]) { [weak self] _, change in
            guard let self = self else { return }
            guard change.oldValue != change.newValue else { return }
            
            if case .system = self.appearanceMode {
                self.notifyAppearanceChange()
            }
        }
    }
    
    private func notifyThemeChange() {
        themePublisher.send(currentTheme)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
        NotificationCenter.default.post(name: .themeDidChange, object: self)
    }
    
    private func notifyAppearanceChange() {
        appearancePublisher.send(currentAppearance)
        themeAppearancePublisher.send((currentTheme, currentAppearance))
        NotificationCenter.default.post(name: .appearanceDidChange, object: self)
    }
}

// MARK: - ThemeSource Protocol

/// Protocol for objects that provide theme and appearance updates.
@objc(PhiThemeSource)
public protocol ThemeSource: AnyObject {
    /// Subscribes to theme and appearance changes. Retain the return value.
    func subscribe(_ action: @escaping (Theme, Appearance) -> Void) -> AnyObject
}

// MARK: - CompoundObservation

/// Groups multiple observations into a single retained object.
public final class CompoundObservation {
    private let observations: [AnyObject]
    
    public init(_ observations: [AnyObject]) {
        self.observations = observations
    }
}

/// Placeholder subscription used when no teardown is required.
public let emptySubscription: AnyObject = {
    class EmptySubscription: CustomStringConvertible {
        var description: String {
            "EmptySubscription - nothing to tear down"
        }
    }
    return EmptySubscription()
}()
