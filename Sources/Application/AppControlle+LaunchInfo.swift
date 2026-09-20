// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import AppKit
import PostHog

/// Rate-limits the activation-driven `Application Opened` PostHog event.
///
/// The SDK's lifecycle integration fired it on every `didBecomeActive` — every
/// Cmd-Tab — and a launch-only event starves active-day metrics for users who
/// never quit the browser. This sits in between: launch always emits, and a
/// later activation emits only once `minimumInterval` has passed since the
/// last emission. The last-emission time is persisted so the throttle survives
/// a relaunch. The clock and the store are injectable for tests.
final class ApplicationOpenedThrottle {
    /// Lei Zhang's review of e748d9f4: once an hour keeps daily-active metrics
    /// alive for never-quit users without the per-Cmd-Tab flood.
    static let minimumInterval: TimeInterval = 3600

    /// UserDefaults key for the last emission date.
    static let lastEmissionKey = "posthogApplicationOpenedLastEmission"

    private let now: () -> Date
    private let defaults: UserDefaults

    init(now: @escaping () -> Date = Date.init, defaults: UserDefaults = .standard) {
        self.now = now
        self.defaults = defaults
    }

    var lastEmission: Date? {
        defaults.object(forKey: Self.lastEmissionKey) as? Date
    }

    /// Whether an activation-driven emission is due: never emitted, or the
    /// last emission is at least `minimumInterval` old. An emission recorded
    /// moments ago — the launch emission, seen by the startup activation —
    /// is therefore skipped, which is what keeps launch from emitting twice.
    static func shouldEmit(lastEmission: Date?, now: Date) -> Bool {
        guard let lastEmission else { return true }
        return now.timeIntervalSince(lastEmission) >= minimumInterval
    }

    func shouldEmit() -> Bool {
        Self.shouldEmit(lastEmission: lastEmission, now: now())
    }

    func recordEmission() {
        defaults.set(now(), forKey: Self.lastEmissionKey)
    }
}

/// Reproduces the PostHog SDK's `Application Installed` / `Application
/// Updated` launch events, which the SDK's lifecycle integration stopped
/// sending when `captureApplicationLifecycleEvents` was turned off (e748d9f4).
///
/// Same UserDefaults keys, event names, property names and value types as
/// `PostHogAppLifeCycleIntegration.captureAppInstallOrUpdated`, so a user
/// upgrading from a build where the SDK wrote the keys is seen as Updated,
/// not Installed, and existing dashboards keep working. The decision is keyed
/// on the build, as in the SDK: no stored build is an install, an unchanged
/// build is nothing, anything else is an update. Store and bundle values are
/// injectable for tests.
final class ApplicationVersionEventTracker {
    static let versionKey = "PHGVersionKey"
    static let buildKey = "PHGBuildKeyV2"
    static let installedEvent = "Application Installed"
    static let updatedEvent = "Application Updated"

    private let defaults: UserDefaults
    private let currentVersion: String?
    private let currentBuild: String?

    init(defaults: UserDefaults = .standard,
         currentVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
         currentBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
    }

    /// The event this launch should send, if any, then records the current
    /// version and build so the next launch compares against them.
    func consumeLaunch() -> (event: String, properties: [String: Any])? {
        let previousVersion = defaults.string(forKey: Self.versionKey)
        let previousBuild = defaults.string(forKey: Self.buildKey)

        var properties: [String: Any] = [:]
        let event: String
        if let previousBuild {
            // Do not send version updates if its the same (SDK wording).
            if previousBuild == currentBuild { return nil }
            event = Self.updatedEvent
            if let previousVersion {
                properties["previous_version"] = previousVersion
            }
            properties["previous_build"] = Self.buildValue(previousBuild)
        } else {
            event = Self.installedEvent
        }

        if let currentVersion {
            properties["version"] = currentVersion
            defaults.set(currentVersion, forKey: Self.versionKey)
        }
        if let currentBuild {
            properties["build"] = Self.buildValue(currentBuild)
            defaults.set(currentBuild, forKey: Self.buildKey)
        }
        return (event, properties)
    }

    /// The SDK sends a build as an Int when it parses as one, else the string.
    private static func buildValue(_ build: String) -> Any {
        if let int = Int(build) { return int }
        return build
    }
}

extension AppController {
    /// Public read-only launch context exposed to the rest of the app.
    struct LaunchContext {
        let currentVersion: String
        let currentBuild: String
        let previousVersion: String?
        let previousBuild: String?
        let previousLaunchDate: Date?
        let firstLaunchDate: Date
        let launchCount: Int
        let isFirstLaunchEver: Bool
        let isFirstLaunchForVersion: Bool
        let isFirstLaunchForBuild: Bool
        let didUpgrade: Bool
        let didDowngrade: Bool
    }
    
    static private(set) var launchContext: LaunchContext?
    
    private static let launchIOQueue = DispatchQueue(label: "cc.phi.app.launchIO", qos: .utility)
    
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        return v1.compare(v2, options: [.numeric, .caseInsensitive])
    }
    
    func recordLaunchVersion() {
        let info = Bundle.main.infoDictionary ?? [:]
        let currentVersion = (info["CFBundleShortVersionString"] as? String) ?? "0"
        let currentBuild = (info["CFBundleVersion"] as? String) ?? "0"
        
        Self.launchIOQueue.async { [currentVersion, currentBuild] in
            let fm = FileManager.default
            let baseDir = FileSystemUtils.phiBrowserDataDirectory()
            let dirURL = URL(fileURLWithPath: baseDir, isDirectory: true)
            let fileURL = dirURL.appendingPathComponent("launch_info.json", conformingTo: .json)
            
            // Ensure directory exists
            do { try fm.createDirectory(at: dirURL, withIntermediateDirectories: true) } catch { /* ignore */ }
            
            struct LaunchRecord: Codable {
                var lastVersion: String?
                var lastBuild: String?
                var lastLaunchDate: Date?
                var firstLaunchDate: Date?
                var launchCount: Int
                var perVersionCount: [String: Int]
            }
            
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            
            var record: LaunchRecord = {
                guard let data = try? Data(contentsOf: fileURL), let decoded = try? decoder.decode(LaunchRecord.self, from: data) else {
                    return LaunchRecord(lastVersion: nil, lastBuild: nil, lastLaunchDate: nil, firstLaunchDate: nil, launchCount: 0, perVersionCount: [:])
                }
                return decoded
            }()
            
            let previousVersion = record.lastVersion
            let previousBuild = record.lastBuild
            let previousLaunchDate = record.lastLaunchDate
            let now = Date()
            let firstLaunchDate = record.firstLaunchDate ?? now
            
            record.launchCount += 1
            var perVersionCount = record.perVersionCount
            perVersionCount[currentVersion] = (perVersionCount[currentVersion] ?? 0) + 1
            record.perVersionCount = perVersionCount
            
            record.lastVersion = currentVersion
            record.lastBuild = currentBuild
            record.lastLaunchDate = now
            record.firstLaunchDate = firstLaunchDate
            
            let isFirstLaunchEver = (previousVersion == nil && previousBuild == nil)
            let isFirstLaunchForVersion = (previousVersion != currentVersion)
            let isFirstLaunchForBuild = (previousBuild != currentBuild)
            
            var didUpgrade = false
            var didDowngrade = false
            if let pv = previousVersion, pv != currentVersion {
                let cmp = self.compareVersions(currentVersion, pv)
                didUpgrade = (cmp == .orderedDescending)
                didDowngrade = (cmp == .orderedAscending)
            } else if let pb = previousBuild, pb != currentBuild, let prev = Int(pb), let curr = Int(currentBuild) {
                didUpgrade = curr > prev
                didDowngrade = curr < prev
            }
            
            if let data = try? encoder.encode(record) {
                _ = try? data.write(to: fileURL, options: .atomic)
            }
            
            let ctx = LaunchContext(
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                previousVersion: previousVersion,
                previousBuild: previousBuild,
                previousLaunchDate: previousLaunchDate,
                firstLaunchDate: firstLaunchDate,
                launchCount: record.launchCount,
                isFirstLaunchEver: isFirstLaunchEver,
                isFirstLaunchForVersion: isFirstLaunchForVersion,
                isFirstLaunchForBuild: isFirstLaunchForBuild,
                didUpgrade: didUpgrade,
                didDowngrade: didDowngrade
            )
            
            DispatchQueue.main.async {
                Self.launchContext = ctx
                AppLogInfo("LaunchContext => version=\(currentVersion) build=\(currentBuild) prevVersion=\(previousVersion ?? "-") prevBuild=\(previousBuild ?? "-") firstEver=\(isFirstLaunchEver) firstForVersion=\(isFirstLaunchForVersion) firstForBuild=\(isFirstLaunchForBuild) upgraded=\(didUpgrade) downgraded=\(didDowngrade) launchCount=\(record.launchCount) perVersionCount=\(perVersionCount[currentVersion] ?? 0)")
            }
        }
    }
    
    // MARK: - Default Browser Detection
    
    /// Information about the current default browser.
    struct DefaultBrowserInfo {
        /// Display name of the default browser.
        let name: String
        /// Bundle identifier of the default browser.
        let bundleIdentifier: String?
        /// Whether Phi is currently the default browser.
        let isPhiDefault: Bool
    }
    
    /// Returns information about the current default browser for HTTP/HTTPS URLs.
    static func getDefaultBrowserInfo() -> DefaultBrowserInfo {
        guard let url = URL(string: "http://example.com"),
              let defaultAppURL = LSCopyDefaultApplicationURLForURL(url as CFURL, .all, nil)?.takeRetainedValue() else {
            return DefaultBrowserInfo(name: "Unknown", bundleIdentifier: nil, isPhiDefault: false)
        }
        
        let appURL = defaultAppURL as URL
        
        guard let defaultBundle = Bundle(url: appURL) else {
            let appName = appURL.deletingPathExtension().lastPathComponent
            return DefaultBrowserInfo(name: appName.isEmpty ? "Unknown" : appName, bundleIdentifier: nil, isPhiDefault: false)
        }
        
        let bundleId = defaultBundle.bundleIdentifier
        let phiBundleId = Bundle.main.bundleIdentifier
        let isPhiDefault = (bundleId != nil && bundleId == phiBundleId)
        
        let displayName: String = {
            if let localizedName = defaultBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !localizedName.isEmpty {
                return localizedName
            }
            if let bundleName = defaultBundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !bundleName.isEmpty {
                return bundleName
            }
            return appURL.deletingPathExtension().lastPathComponent
        }()
        
        return DefaultBrowserInfo(name: displayName, bundleIdentifier: bundleId, isPhiDefault: isPhiDefault)
    }
    
    /// Returns whether Phi is currently the default browser.
    static func isPhiDefaultBrowser() -> Bool {
        return getDefaultBrowserInfo().isPhiDefault
    }
    
    /// Returns the display name of the current default browser.
    static func getDefaultBrowserName() -> String {
        return getDefaultBrowserInfo().name
    }

    // MARK: - Launch Preferences Analytics

    /// Captures `Application Installed` or `Application Updated` once per
    /// launch when the build changed, exactly as the SDK's lifecycle
    /// integration did before it was turned off. Runs before the launch
    /// `Application Opened`, where the SDK's `didFinishLaunching` hook sat.
    func captureApplicationInstallOrUpdate() {
        guard let launchEvent = ApplicationVersionEventTracker().consumeLaunch() else { return }
        PostHogSDK.shared.capture(launchEvent.event, properties: launchEvent.properties)
    }

    /// Captures `Application Opened` in the shape the PostHog SDK's lifecycle
    /// integration gave it (`from_background`, plus the bundle version and
    /// build on launch) so existing dashboards keep working. The SDK
    /// integration itself is off: on macOS it re-fired this on every
    /// `didBecomeActive`, i.e. every Cmd-Tab. Launch calls this unthrottled;
    /// later activations go through `captureApplicationOpenedIfDue`.
    /// `layout_mode`, `ai_enabled` and `is_guest_mode` are added by the
    /// `beforeSend` hook in `applicationWillFinishLaunching`, keyed on the
    /// event name, exactly as they were for the SDK-emitted event.
    func captureApplicationOpened(fromBackground: Bool = false) {
        var properties: [String: Any] = ["from_background": fromBackground]
        if !fromBackground {
            let info = Bundle.main.infoDictionary
            if let version = info?["CFBundleShortVersionString"] as? String {
                properties["version"] = version
            }
            if let build = info?["CFBundleVersion"] as? String {
                properties["build"] = build
            }
        }
        applicationOpenedThrottle.recordEmission()
        PostHogSDK.shared.capture("Application Opened", properties: properties)
    }

    /// Activation-driven `Application Opened`, at most once per
    /// `ApplicationOpenedThrottle.minimumInterval`. The launch emission
    /// records its own timestamp, so the activation macOS delivers as part of
    /// startup lands inside the interval and is skipped — launch never emits
    /// twice.
    func captureApplicationOpenedIfDue() {
        guard applicationOpenedThrottle.shouldEmit() else { return }
        captureApplicationOpened(fromBackground: true)
    }

    /// Emits the throttled activation event on every `didBecomeActive` for
    /// the rest of the process. Installed only once PostHog is configured.
    func observeApplicationActivationForAnalytics() {
        guard applicationActivationObservation == nil else { return }
        applicationActivationObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureApplicationOpenedIfDue() }
        }
    }

    /// Captures the user's current preference selections once per app launch.
    func captureUserDefaultsSnapshot() {
        let defaultBrowser = Self.getDefaultBrowserInfo()
        let appearanceRawValue = UserDefaults.standard.integer(
            forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue
        )
        let appearance = UserAppearanceChoice(rawValue: appearanceRawValue) ?? .system

        PostHogSDK.shared.capture("user_defaults_snapshot", properties: [
            "new_tab_behavior": PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.loadValue()
                ? "ntp"
                : "omnibox",
            "layout_mode": PhiPreferences.GeneralSettings.loadLayoutMode().rawValue,
            "app_language": PhiPreferences.GeneralSettings
                .activeProcessAppLanguage().rawValue,
            "appearance": Self.analyticsValue(for: appearance),
            "selection_tint_enabled": UserDefaults.standard.bool(
                forKey: PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue,
                default: true
            ),
            "default_browser_name": defaultBrowser.name,
            "default_browser_bundle_id": defaultBrowser.bundleIdentifier ?? "unknown",
            "is_phi_default_browser": defaultBrowser.isPhiDefault,
            "proactive_suggestions_enabled": PhiPreferences.AISettings.enableProactiveSuggestionsOnNTP.loadValue(),
            "automatically_add_context_enabled": PhiPreferences.AISettings.enableChatWithTabs.loadValue(),
            "peek_view_enabled": PhiPreferences.GeneralSettings.peekViewEnabled.loadValue(),
            "always_show_full_url": PhiPreferences.GeneralSettings.alwaysShowURLPath.loadValue(),
            "show_tab_previews": PhiPreferences.GeneralSettings.showTabPreviews.loadValue(),
            "show_open_tab_indicators": PhiPreferences.GeneralSettings.showOpenTabIndicators.loadValue(),
            "dim_unloaded_tab_icons": PhiPreferences.GeneralSettings.showUnloadedTabIndicators.loadValue(),
            "restore_last_session_enabled": SessionRestorePreference.isEnabled,
            "short_highlight_links_enabled": PhiPreferences.GeneralSettings.shortHighlightLinksEnabled.loadValue(),
            "auto_picture_in_picture_mode": PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode().rawValue,
            "developer_mode_enabled": PhiPreferences.AgentSpaces.developerModeEnabled,
            "cdp_agent_access_enabled": PhiPreferences.AgentSpaces.cdpAgentAccessEnabled,
            "bitwarden_enabled": PhiPreferences.PasswordManagerSettings.bitwardenEnabled.loadValue(),
            "open_external_links_in_kiosk": PhiPreferences.GeneralSettings.openExternalLinksInKiosk.loadValue(),
            "open_kiosk_on_command_option_click": PhiPreferences.GeneralSettings.openKioskOnCommandOptionClick.loadValue()
        ])
    }

    private static func analyticsValue(for appearance: UserAppearanceChoice) -> String {
        switch appearance {
        case .system:
            return "system"
        case .light:
            return "light"
        case .dark:
            return "dark"
        }
    }
}
