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
            return NSLocalizedString("settings.general.layoutMode.performanceOption", value: "Performance", comment: "Layout option - Vertical tabs with address bar at side bar")
        case .balanced:
            return NSLocalizedString("settings.general.layoutMode.balancedOption", value: "Balanced", comment: "Layout option - Vertical tabs with address bar at the top of webcontent")
        case .comfortable:
            return NSLocalizedString("settings.general.layoutMode.comfortableOption", value: "Comfortable", comment: "Layout option - Horizontal tabs")
        }
    }

    var isTraditional: Bool { self == .comfortable }
    var showsNavigationAtTop: Bool { self != .performance }
}

/// Three-state auto picture-in-picture behavior. Stored as a single enum so
/// the illegal "off but parked" combination cannot be represented; Chromium
/// reads it through two bridge getters derived from the mode. Manual
/// picture-in-picture is unaffected in every mode.
enum AutoPictureInPictureMode: String, CaseIterable, Identifiable {
    case off     // never pop out automatically
    case normal  // pop out and stay where it appears (default)
    case parked  // pop out, then park at the screen edge until clicked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return NSLocalizedString("settings.general.pictureInPicture.offOption", value: "Off", comment: "Auto picture-in-picture option - never pop out automatically; manual picture-in-picture is unaffected")
        case .normal:
            return NSLocalizedString("settings.general.pictureInPicture.normalOption", value: "Normal", comment: "Auto picture-in-picture option - pop out and stay in place")
        case .parked:
            return NSLocalizedString("settings.general.pictureInPicture.parkAtEdgeOption", value: "Park at edge", comment: "Auto picture-in-picture option - pop out, then park at the screen edge until clicked")
        }
    }
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
        case suppressCloseIncognitoSpaceWarning // "Do not ask again" on the close-Incognito-Space confirmation

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
            case .suppressCloseIncognitoSpaceWarning:
                return false
            }
        }

        func loadValue() -> Bool {
            UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        static let autoPictureInPictureModeKey = "autoPictureInPictureMode"

        static func loadAutoPictureInPictureMode(
            from defaults: UserDefaults = .standard
        ) -> AutoPictureInPictureMode {
            if let rawValue = defaults.string(forKey: Self.autoPictureInPictureModeKey),
               let mode = AutoPictureInPictureMode(rawValue: rawValue) {
                return mode
            }
            return .normal
        }

        static func saveAutoPictureInPictureMode(
            _ mode: AutoPictureInPictureMode,
            to defaults: UserDefaults = .standard
        ) {
            defaults.set(mode.rawValue, forKey: Self.autoPictureInPictureModeKey)
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
        static let horizontalSwitchSpaceAnimationDuration: TimeInterval = 0.2
        /// Cross-Space animation duration in the vertical (Performance /
        /// Balanced) layouts.
        static let verticalSwitchSpaceAnimationDuration: TimeInterval = 0.15

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
                return PhiBuildCapabilities.supportsAI
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
            if self == .phiAIEnabled && !PhiBuildCapabilities.supportsAI {
                return false
            }
            return UserDefaults.standard.bool(forKey: rawValue, default: defaultValue)
        }

        static func buildConfig() -> String {
            var result = [String: Any]()
            allCases
                .filter { $0 != .enableBrowserMemories}
                .forEach {
                result[$0.rawValue] = $0.loadValue()
            }
            let data = try? JSONSerialization.data(withJSONObject: result, options: [])
            return String(data: data ?? Data(), encoding: .utf8) ?? "{}"
        }
    }
    
    // MARK: - Agent Spaces

    enum AgentSpaces {
        private static let autoCloseKey = "PhiAgentSpaceAutoCloseOnSuccess"
        private static let developerModeKey = "PhiDeveloperModeEnabled"
        private static let cdpAgentAccessKey = "PhiCDPAgentAccessEnabled"
        private static let rememberedAgentGrantsKey = "PhiCDPRememberedAgentGrants"
        private static let agentDenialsKey = "PhiCDPAgentDenials"
        private static let autoViewKey = "PhiAgentSpaceAutoView"
        private static let userSpaceOperationsKey = "PhiAgentUserSpaceOperationsEnabled"
        private static let disallowedAgentProfilesKey = "PhiAgentDisallowedProfileIds"
        private static let agentFallbackProfileKey = "PhiAgentFallbackProfileId"

        /// Master gate for the developer surfaces — the Developer settings tab
        /// and the features configured there. Driven by the "Developer mode"
        /// toggle in Settings ▸ General. Turning it OFF is a kill-switch, not
        /// just UI hiding: agent CDP access and the agent password manager are
        /// disabled with it, AND every standing agent permission is revoked —
        /// the allowed-agent list and all credential approvals, persisted ones
        /// included (see `AppController.setDeveloperModeEnabled`). Turning it
        /// back ON re-enables nothing and restores no permission: each feature
        /// is re-enabled individually in the Developer tab, and every agent
        /// asks for consent again from scratch. Defaults off,
        /// with a backfill: while the toggle was never touched, a user who
        /// already enabled agent CDP access or the agent password manager
        /// (pre-default-off users, or Bitwarden picked during onboarding) has
        /// opted into the developer surfaces, so `true` is adopted and
        /// persisted on first read — the features they enabled must not
        /// vanish behind a hidden tab.
        static var developerModeEnabled: Bool {
            get {
                guard UserDefaults.standard.object(forKey: developerModeKey) == nil else {
                    return UserDefaults.standard.bool(forKey: developerModeKey)
                }
                let alreadyOptedIn = cdpAgentAccessEnabled
                    || PasswordManagerSettings.bitwardenEnabled.loadValue()
                guard alreadyOptedIn else { return false }
                UserDefaults.standard.set(true, forKey: developerModeKey)
                return true
            }
            set { UserDefaults.standard.set(newValue, forKey: developerModeKey) }
        }

        /// Settings ▸ Developer ▸ Agent control: whether agent tooling may
        /// operate the user's own browsing data and windows over the
        /// management surface — Spaces, profiles, URL rules, pinned tabs,
        /// bookmarks, and the tab layout of user windows. When off, agents can
        /// only work inside their own agent Spaces. Read live by the message
        /// router, so changes apply without a relaunch. Default on.
        static var userSpaceOperationsEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: userSpaceOperationsKey, default: true) }
            set { UserDefaults.standard.set(newValue, forKey: userSpaceOperationsKey) }
        }

        /// Settings ▸ Developer ▸ Agent control: profiles the agent may NOT
        /// create agent Spaces in, by profileId. Stored as a blocklist so the
        /// default (empty) preserves "any profile allowed"; the UI presents it
        /// as a per-profile "allow" toggle. Keyed by profileId (stable across
        /// renames). Enforced at `agentSpace.create`.
        static var disallowedAgentProfileIds: Set<String> {
            get { Set(UserDefaults.standard.stringArray(forKey: disallowedAgentProfilesKey) ?? []) }
            set {
                if newValue.isEmpty {
                    UserDefaults.standard.removeObject(forKey: disallowedAgentProfilesKey)
                } else {
                    UserDefaults.standard.set(Array(newValue), forKey: disallowedAgentProfilesKey)
                }
            }
        }

        /// Whether the agent may create agent Spaces bound to `profileId`.
        static func isProfileAgentSpaceAllowed(_ profileId: String) -> Bool {
            !disallowedAgentProfileIds.contains(profileId)
        }

        /// Reserved display name of the agent's fallback profile. Deliberately
        /// one a user would not normally pick, so identifying the profile by
        /// name never hides a user's own profile.
        static let agentFallbackProfileName = "Phi Agent (reserved)"

        /// Profile the app auto-created as the agent's fallback (see
        /// `AgentSpaceManager.ensureAgentFallbackProfile`), recorded so it can
        /// still be identified after a rename — that profile belongs to the
        /// agent. nil when no fallback has been created.
        static var agentFallbackProfileId: String? {
            get { UserDefaults.standard.string(forKey: agentFallbackProfileKey) }
            set {
                if let newValue, !newValue.isEmpty {
                    UserDefaults.standard.set(newValue, forKey: agentFallbackProfileKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: agentFallbackProfileKey)
                }
            }
        }

        /// THE single source of truth for "is this the agent's fallback
        /// profile" — by reserved name or recorded id. Everything that lists
        /// profiles for the user to choose from filters on this so the agent
        /// profile never appears in a user picker.
        static func isAgentFallbackProfile(profileId: String, displayName: String) -> Bool {
            displayName == agentFallbackProfileName
                || (!profileId.isEmpty && profileId == agentFallbackProfileId)
        }

        /// When `true`, a successfully completed agent Space that the user never
        /// visited is closed automatically instead of lingering with a badge.
        /// Default `false`.
        static var autoCloseOnSuccess: Bool {
            get { UserDefaults.standard.bool(forKey: autoCloseKey) }
            set { UserDefaults.standard.set(newValue, forKey: autoCloseKey) }
        }

        /// View ▸ Agent Autoview: when `true`, the focused window follows the
        /// operating agent — a running agent Space is surfaced (watch mode)
        /// unless the user is already watching a running one, which is never
        /// preempted (see `AgentSpaceManager.autoViewReevaluate`). Default
        /// `false`.
        static var autoViewEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: autoViewKey) }
            set { UserDefaults.standard.set(newValue, forKey: autoViewKey) }
        }

        /// Settings ▸ Developer ▸ Remote debugging: master switch for agent CDP
        /// access over the app-owned Unix-domain socket (see
        /// `AgentCDPListener`). Read live — flipping it off severs every live
        /// agent connection immediately, no relaunch, and shows or hides the
        /// View ▸ Agent Autoview / Agent Transcript menu items. Default off:
        /// while on, an approved agent process can drive the browser. The
        /// socket listens either way, so an agent that connects while this is
        /// off reaches the consent prompt, which offers to turn it on — that
        /// prompt is the only thing outside Settings that may set it.
        static var cdpAgentAccessEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: cdpAgentAccessKey) }
            set { UserDefaults.standard.set(newValue, forKey: cdpAgentAccessKey) }
        }

        /// Agent code-signing identities the user chose to remember (Allow &
        /// Remember in the CDP consent prompt), so a returning agent connects
        /// without re-prompting. Each entry is an `AgentIdentity.key`
        /// ("teamId:signingId", or "unsigned:path" for an unsigned peer).
        /// Empty by default; removing an entry here is how the Settings list
        /// revokes a remembered agent.
        static var rememberedAgentGrants: Set<String> {
            get { Set(UserDefaults.standard.stringArray(forKey: rememberedAgentGrantsKey) ?? []) }
            set {
                if newValue.isEmpty {
                    UserDefaults.standard.removeObject(forKey: rememberedAgentGrantsKey)
                } else {
                    UserDefaults.standard.set(Array(newValue), forKey: rememberedAgentGrantsKey)
                }
            }
        }

        /// Standing refusals from the consent prompt's deny options — "Don't
        /// ask for 30 min" and "Never ask again", each optionally widened to
        /// all agents. A covered peer is turned away without a prompt (see
        /// `AgentCDPListener.evaluate`). Timed entries are persisted, not
        /// session-scoped: see `AgentDenial` for why a denial must not be
        /// forgotten at relaunch the way a grant is. Empty by default; the
        /// Settings "Blocked agents" list and re-enabling the CDP switch are
        /// the two ways back.
        static var agentDenials: [AgentDenial] {
            get {
                guard let data = UserDefaults.standard.data(forKey: agentDenialsKey),
                      let decoded = try? JSONDecoder().decode([AgentDenial].self, from: data)
                else { return [] }
                return decoded
            }
            set {
                guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else {
                    UserDefaults.standard.removeObject(forKey: agentDenialsKey)
                    return
                }
                UserDefaults.standard.set(data, forKey: agentDenialsKey)
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
        /// `true` when the user enabled Bitwarden (onboarding or the Phi & AI
        /// settings card). Drives the master toggle and, like
        /// `autoInstallICloudPasswords`, is the OOBE choice that newly created
        /// profiles mirror to auto-install the Bitwarden extension.
        case bitwardenEnabled

        var defaultValue: Bool {
            switch self {
            case .autoInstallICloudPasswords:
                return false
            case .bitwardenEnabled:
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

/// Applies the settings boundary required by Guest Mode. Kept with the
/// preference definitions so launch and login lifecycle code do not depend on
/// either settings view.
enum GuestModePreferences {
    static let aiEnabledKey = PhiPreferences.AISettings.phiAIEnabled.rawValue

    @discardableResult
    static func disableAI(
        defaults: UserDefaults = .standard
    ) -> Bool {
        let didChange = defaults.bool(
            forKey: aiEnabledKey,
            default: PhiPreferences.AISettings.phiAIEnabled.defaultValue
        )

        defaults.set(false, forKey: aiEnabledKey)
        return didChange
    }
}
