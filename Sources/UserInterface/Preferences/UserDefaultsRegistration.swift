// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

//  Central place to register all UserDefaults default values.
//  Call `UserDefaultsRegistration.registerDefaults()` early in app launch
//  (e.g., in applicationWillFinishLaunching).

import Foundation

/// Registers all app-wide `UserDefaults` defaults in one place.
enum UserDefaultsRegistration {
    
    /// Registers every default value during app launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: allDefaults)
    }
    
    /// Merges defaults contributed by each settings namespace.
    private static var allDefaults: [String: Any] {
        var defaults = [String: Any]()
        
        // General Settings
        defaults.merge(generalSettingsDefaults) { _, new in new }
        
        // AI Settings
        defaults.merge(aiSettingsDefaults) { _, new in new }
        
        // Theme Settings
        defaults.merge(themeDefaults) { _, new in new }
        
        return defaults
    }
    
    // MARK: - General Settings
    
    private static var generalSettingsDefaults: [String: Any] {
        var defaults = [String: Any]()
        for setting in PhiPreferences.GeneralSettings.allCases {
            defaults[setting.rawValue] = setting.defaultValue
        }
        return defaults
    }
    
    // MARK: - AI Settings
    
    private static var aiSettingsDefaults: [String: Any] {
        var defaults = [String: Any]()
        for setting in PhiPreferences.AISettings.allCases {
            defaults[setting.rawValue] = setting.defaultValue
        }
        return defaults
    }
    
    // MARK: - Theme Settings
    
    private static var themeDefaults: [String: Any] {
        var defaults = [String: Any]()
        for setting in PhiPreferences.ThemeSettings.allCases {
            defaults[setting.rawValue] = setting.defaultValue
        }
        return defaults
    }
}
