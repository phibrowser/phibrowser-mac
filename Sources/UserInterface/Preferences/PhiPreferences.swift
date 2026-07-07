// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

extension UserDefaults {
    /// Returns the Bool for `key`, falling back to `default` when the key has never been set.
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard object(forKey: key) != nil else { return defaultValue }
        return bool(forKey: key)
    }
}

enum LayoutMode: String, CaseIterable, Identifiable {
    case balanced     // vertical tabs + address bar at the top of webcontent
    case performance  // vertical tabs
    case comfortable  // horizontal tabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .performance:
            return NSLocalizedString("Performance", comment: "Layout option - Vertical tabs with address bar at side bar")
        case .balanced:
            return NSLocalizedString("Balanced", comment: "Layout option - Vertical tabs with address bar at the top of webcontent")
        case .comfortable:
            return NSLocalizedString("Comfortable", comment: "Layout option - Horizontal tabs")
        }
    }

    var isTraditional: Bool { self == .comfortable }
    var showsNavigationAtTop: Bool { self != .performance }
}

enum PhiPreferences: String {
    case phiMainDebugMenuEnabled
    case phiLoginPhase
    case preferedUserName
    case accentColor
    case needImportDataFromOtherBrowsers

    static let fixedWindowBackground = ThemedColor { _, appearance in
        DefaultColors.windowBackground.color(for: appearance)
    }
}

extension PhiPreferences {
    enum GeneralSettings: String, CaseIterable {
        case openNewTabPageOnCmdT
        case navigationAtTop  // Whether to show navigation and address bar in content header (Layout 2)
        case traditionalLayout  // Traditional layout, show tabs and (maybe) bookmark bar at  top (Layout 3)
        case alwaysShowBookmarkBar // In traditional layout, always show bookmark bar below address bar
        case showBookmarkBarOnNewTabPage // In traditional layout, show bookmark bar on new tab page
        case alwaysShowURLPath // In address bar menu, always show full URL path
        case spacesFeatureEnabled // Master gate for Spaces + profile management UI; defaults on, no user-facing toggle
        case incognitoSpaceEnabled // Surfaces the built-in Incognito Space (dedicated OTR-profile backed); toggled in Spaces settings

        var defaultValue: Bool {
            switch self {
            case .openNewTabPageOnCmdT:
                return true
            case .navigationAtTop:
                return true
            case .traditionalLayout:
                return false
            case .alwaysShowBookmarkBar:
                return false
            case .showBookmarkBarOnNewTabPage:
                return true
            case .alwaysShowURLPath:
                return false
            case .spacesFeatureEnabled:
                return true
            case .incognitoSpaceEnabled:
                return false
            }
        }
        
        func loadValue() -> Bool {
            UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        static let layoutModeKey = "layoutMode"

        static func loadLayoutMode() -> LayoutMode {
            let defaults = UserDefaults.standard

            if let rawValue = defaults.string(forKey: Self.layoutModeKey),
               let mode = LayoutMode(rawValue: rawValue) {
                return mode
            }

            // Backward compatibility for old dual-bool encoding.
            let traditionalLayout = UserDefaults.standard.value(forKey: Self.traditionalLayout.rawValue) as? Bool
            let navigationAtTop = UserDefaults.standard.value(forKey: Self.navigationAtTop.rawValue) as? Bool
            if traditionalLayout == true {
                return .comfortable
            } else if navigationAtTop == true {
                return .balanced
            } else {
                // default value
                return .performance
            }
        }

        static func saveLayoutMode(_ mode: LayoutMode) {
            let defaults = UserDefaults.standard
            defaults.set(mode.rawValue, forKey: Self.layoutModeKey)
        }

        /// Duration of the cross-Space swap animation, in seconds. Drives the
        /// horizontal-layout slide and the vertical-layout sidebar tint
        /// cross-fade. The horizontal slide is the longer, more prominent
        /// motion; vertical's tint cross-fade is shorter.
        static func loadSwitchSpaceAnimationDuration() -> TimeInterval {
            loadLayoutMode().isTraditional
                ? Self.horizontalSwitchSpaceAnimationDuration
                : Self.verticalSwitchSpaceAnimationDuration
        }

        /// Cross-Space animation duration in the horizontal (Comfortable) layout.
        static let horizontalSwitchSpaceAnimationDuration: TimeInterval = 0.4
        /// Cross-Space animation duration in the vertical (Performance /
        /// Balanced) layouts.
        static let verticalSwitchSpaceAnimationDuration: TimeInterval = 0.3

        /// Which window's traffic-light buttons the horizontal-layout
        /// cross-Space slide suppresses. `source` (the ship default) fades
        /// the leaving window's buttons before its snapshot is captured so
        /// the sliding snapshot carries none; `target` keeps them in the
        /// snapshot and instead hides the destination window's live buttons
        /// until the slide finishes; `both` combines the two.
        enum SwitchSpaceTrafficLightHiding: String, CaseIterable {
            case source
            case target
            case both

            var hidesSource: Bool { self != .target }
            var hidesTarget: Bool { self != .source }
        }

        /// The horizontal cross-Space slide always hides the *source* window's
        /// traffic lights before snapshotting it, so the sliding snapshot
        /// carries none.
        static func loadSwitchSpaceTrafficLightHiding() -> SwitchSpaceTrafficLightHiding {
            .source
        }
    }
    
    enum AISettings: String, CaseIterable {
        case phiAIEnabled, enableConnectors, enableConnectorContext , enableChatWithTabs, enableBrowserMemories, launchSentinelOnLogin, enableProactiveSuggestionsOnNTP

        var defaultValue: Bool {
            switch self {
            case .phiAIEnabled:
                return true
            case .enableConnectors:
                return true
            case .enableConnectorContext:
                return true
            case .enableChatWithTabs:
                return true
            case .enableBrowserMemories:
                return true
            case .launchSentinelOnLogin:
                return true
            case .enableProactiveSuggestionsOnNTP:
                return true
            }
        }

        func loadValue() -> Bool {
            UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        static func buildConfig() -> String {
            var result = [String: Any]()
            allCases
                .filter { $0 != .enableBrowserMemories}
                .forEach {
                result[$0.rawValue] = UserDefaults.standard.bool(forKey: $0.rawValue)
            }
            let data = try? JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
        }
    }
    
    // MARK: - Agent Spaces

    enum AgentSpaces {
        private static let autoCloseKey = "PhiAgentSpaceAutoCloseOnSuccess"
        private static let remoteDebuggingPortKey = "PhiRemoteDebuggingPort"

        /// When `true`, a successfully completed agent Space that the user never
        /// visited is closed automatically instead of lingering with a badge.
        /// Default `false`.
        static var autoCloseOnSuccess: Bool {
            get { UserDefaults.standard.bool(forKey: autoCloseKey) }
            set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
        }

        /// Opt-in CDP endpoint for agent tooling, consumed by ChromiumLauncher
        /// at process launch (a relaunch is required for changes to apply).
        /// nil (key absent) = disabled; 0 = ephemeral port written to
        /// `<user data dir>/DevToolsActivePort`; >0 = fixed port.
        static var remoteDebuggingPort: Int? {
            get {
                guard UserDefaults.standard.object(forKey: remoteDebuggingPortKey) != nil else {
                    return nil
                }
                return UserDefaults.standard.integer(forKey: remoteDebuggingPortKey)
            }
            set {
                if let newValue {
                    UserDefaults.standard.set(newValue, forKey: remoteDebuggingPortKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: remoteDebuggingPortKey)
                }
            }
        }
    }

    // MARK: - Theme Settings

    enum ThemeSettings: String, CaseIterable {
        /// User-selected appearance mode. `0 = system`, `1 = light`, `2 = dark`.
        case userAppearanceChoice = "PhiUserAppearanceChoice"
        /// Current theme identifier.
        case currentThemeId = "PhiCurrentThemeId"
        /// Archived snapshots for themes customized by the user.
        case themeSnapshots = "PhiThemeSnapshots"
        /// When `true`, the Mirage extension applies the window theme's accent
        /// to `::selection` on every web page; when `false`, it leaves the
        /// page's native selection color alone. Default `true`.
        case selectionTintEnabled = "PhiSelectionTintEnabled"

        var defaultValue: Any {
            switch self {
            case .userAppearanceChoice:
                return 0  // .system
            case .currentThemeId:
                return "default"
            case .themeSnapshots:
                return Data()
            case .selectionTintEnabled:
                return true
            }
        }
        
        /// Registers default preference values.
        static func registerDefaults() {
            var defaults = [String: Any]()
            for setting in allCases {
                defaults[setting.rawValue] = setting.defaultValue
            }
            UserDefaults.standard.register(defaults: defaults)
        }
    }

    // MARK: - Password Manager Settings

    /// Records the user's OOBE password-manager choice so newly created
    /// profiles can mirror it. `true` when the user picked iCloud Passwords
    /// during onboarding; new profiles then auto-install the iCloud extension.
    enum PasswordManagerSettings: String, CaseIterable {
        case autoInstallICloudPasswords

        var defaultValue: Bool {
            switch self {
            case .autoInstallICloudPasswords:
                return false
            }
        }

        func loadValue() -> Bool {
            UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        /// Whether the user's choice has ever been recorded — distinguishes a
        /// real `false` from "never set", which gates the existing-user backfill.
        var isSet: Bool {
            UserDefaults.standard.object(forKey: rawValue) != nil
        }

        func save(_ value: Bool) {
            UserDefaults.standard.set(value, forKey: rawValue)
        }
    }
}
