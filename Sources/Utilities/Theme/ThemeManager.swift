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
    /// Posted by `SpaceManager` when a Space's pinned theme or custom
    /// overlay color adjustment changes (`userInfo["spaceId"]`), so the
    /// settings panes can resync values edited from another surface.
    static let spaceThemeDidChange = Notification.Name("PhiSpaceThemeDidChangeNotification")
}

/// User-selectable appearance modes.
public enum UserAppearanceChoice: Int, CaseIterable, Codable {
    case system = 0
    case light = 1
    case dark = 2
    
    public var localizedName: String {
        switch self {
        case .system:
            return NSLocalizedString("themes.appearance.systemOption", value: "System", comment: "Appearance choice: follow system setting")
        case .light:
            return NSLocalizedString("themes.appearance.lightOption", value: "Light", comment: "Appearance choice: always light mode")
        case .dark:
            return NSLocalizedString("themes.appearance.darkOption", value: "Dark", comment: "Appearance choice: always dark mode")
        }
    }
}

/// Coordinates the active theme and appearance settings.
public final class ThemeManager: NSObject, ThemeSource {
    
    // MARK: - Singleton
    @MainActor
    public static let shared = ThemeManager()

    /// Immutable-at-runtime source copies for matching persisted IDs. Every
    /// restore starts from one of these copies rather than from the mutable
    /// registry or the public built-in singleton instances.
    private static let canonicalBuiltInThemesByID: [String: Theme] = Dictionary(
        uniqueKeysWithValues: Theme.builtInThemes.map {
            ($0.id, $0.duplicating())
        }
    )

    private static func canonicalBuiltInTheme(matching persistedID: String) -> Theme? {
        let canonicalID = persistedID == "default" ? Theme.default.id : persistedID
        return canonicalBuiltInThemesByID[canonicalID]?.duplicating()
    }
    
    // MARK: - Properties
    
    /// Currently selected theme.
    @objc dynamic public var currentTheme: Theme {
        didSet {
            if currentTheme !== oldValue {
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

    /// Built-in themes in their canonical display order — the single ordering
    /// used by the settings Theme → Color picker and every Space theme menu —
    /// resolved to the registered (possibly user-edited) instances.
    public var orderedThemes: [Theme] {
        Theme.builtInThemes.map { registeredThemes[$0.id] ?? $0 }
    }

    /// Theme ID to restore once that theme is registered.
    private var pendingThemeId: String?

    /// Theme identifiers that should be archived and restored from local storage.
    private var persistedThemeIDs = Set<String>()

    /// A newer snapshot version makes this store read-only for the current
    /// build so unknown fields cannot be lost by decoding and re-encoding.
    private var hasUnsupportedThemeSnapshots = false
    
    /// Observation token for system appearance changes.
    private var appearanceObservation: NSKeyValueObservation?

    /// Observer for settings pulled by the Phi sync engine (M3-1). Both theme preferences are
    /// cached in memory here and written back from the `didSet`s above, so a value the engine
    /// writes straight into `UserDefaults` would otherwise not reach the UI until the next
    /// launch — and could then be overwritten by this stale cache.
    private var syncedSettingsObservation: NSObjectProtocol?

    // MARK: - Combine Publishers
    
    /// Publishes theme changes.
    public let themePublisher = PassthroughSubject<Theme, Never>()
    
    /// Publishes appearance changes.
    public let appearancePublisher = PassthroughSubject<Appearance, Never>()
    
    /// Publishes combined theme and appearance updates.
    public let themeAppearancePublisher = PassthroughSubject<(Theme, Appearance), Never>()
    
    // MARK: - Initialization
    
    private override init() {
        let builtInThemes = Theme.builtInThemes.compactMap { theme in
            ThemeManager.canonicalBuiltInTheme(matching: theme.id).map {
                ThemeColorAdjustment.applyingDefaultColorComponent(to: $0)
            }
        }
        self.currentTheme = builtInThemes.first(where: { $0.id == Theme.default.id })
            ?? Theme.default.duplicating()
        super.init()
        
        builtInThemes.forEach(registerTheme)
        restorePersistedThemes()
        
        restoreUserPreferences()

        setupAppearanceObservation()
        setupSyncedSettingsObservation()
    }

    /// Re-reads the two synced theme preferences when the Phi sync engine applies a pulled
    /// value for them.
    ///
    /// `restoreUserPreferences()` is idempotent and both setters below it are guarded by
    /// `!= oldValue`, so a notification that changed nothing writes nothing back — and a write
    /// that does happen re-persists the value the engine just stored, whose sidecars
    /// `SyncableSettings.apply` has already refreshed, so it is not detected as a local edit
    /// and not echoed back to the account.
    private func setupSyncedSettingsObservation() {
        syncedSettingsObservation = NotificationCenter.default.addObserver(
            forName: .phiSyncedSettingsDidApply, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let applied = notification.userInfo?[SyncableSettings.appliedKeysUserInfoKey] as? [String] ?? []
            guard applied.contains(PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue)
                    || applied.contains(PhiPreferences.ThemeSettings.currentThemeId.rawValue) else { return }
            self.restoreUserPreferences()
        }
    }

    /// Restores saved theme and appearance preferences from `UserDefaults`.
    private func restoreUserPreferences() {
        let savedChoice = UserDefaults.standard.integer(forKey: PhiPreferences.ThemeSettings.userAppearanceChoice.rawValue)
        if let choice = UserAppearanceChoice(rawValue: savedChoice) {
            userAppearanceChoice = choice
        }
        updateAppearanceMode()
        
        if var themeId = UserDefaults.standard.string(forKey: PhiPreferences.ThemeSettings.currentThemeId.rawValue) {
            if themeId == "default" {
                themeId = Theme.default.id
            }
            if let theme = registeredThemes[themeId] {
                currentTheme = theme
            } else {
                pendingThemeId = themeId
            }
        } else if let theme = registeredThemes[currentTheme.id] {
            currentTheme = theme
        }
    }

    private func restorePersistedThemes() {
        guard let data = UserDefaults.standard.data(forKey: PhiPreferences.ThemeSettings.themeSnapshots.rawValue) else {
            return
        }

        let decoder = JSONDecoder()
        guard let snapshots = try? decoder.decode([ThemeSnapshot].self, from: data) else {
            return
        }

        var snapshotsToPersist: [ThemeSnapshot] = []
        var persistedIndexByThemeID: [String: Int] = [:]
        var needsRewrite = false

        for snapshot in snapshots {
            let canonicalTheme = Self.canonicalBuiltInTheme(matching: snapshot.id)
            guard let migratedSnapshot = snapshot.migratedToCurrentVersion(
                matching: canonicalTheme
            ) else {
                hasUnsupportedThemeSnapshots = true
                snapshotsToPersist.append(snapshot)
                continue
            }

            let theme = migratedSnapshot.makeTheme(matching: canonicalTheme)
            let normalizedSnapshot: ThemeSnapshot
            if snapshot.version == ThemeSnapshot.currentVersion,
               snapshot.id == theme.id {
                normalizedSnapshot = migratedSnapshot
                if normalizedSnapshot != snapshot {
                    needsRewrite = true
                }
            } else {
                normalizedSnapshot = theme.makeSnapshot()
                needsRewrite = true
            }

            persistedThemeIDs.insert(theme.id)
            registeredThemes[theme.id] = theme

            if let existingIndex = persistedIndexByThemeID[theme.id] {
                snapshotsToPersist[existingIndex] = normalizedSnapshot
                needsRewrite = true
            } else {
                persistedIndexByThemeID[theme.id] = snapshotsToPersist.count
                snapshotsToPersist.append(normalizedSnapshot)
            }
        }

        if needsRewrite, !hasUnsupportedThemeSnapshots {
            writeThemeSnapshots(snapshotsToPersist)
        }
    }

    private func persistThemeSnapshots() {
        guard !hasUnsupportedThemeSnapshots else {
            AppLogWarn("[ThemeSnapshot] Keeping newer snapshot data unchanged")
            return
        }
        let currentSnapshots = persistedThemeIDs
            .sorted()
            .compactMap { registeredThemes[$0]?.makeSnapshot() }

        writeThemeSnapshots(currentSnapshots)
    }

    private func writeThemeSnapshots(_ snapshots: [ThemeSnapshot]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: PhiPreferences.ThemeSettings.themeSnapshots.rawValue)
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
        let standardizedTheme = ThemeColorAdjustment.applyingStandardAlpha(to: theme)
        registeredThemes[standardizedTheme.id] = standardizedTheme
        
        if let pending = pendingThemeId, pending == standardizedTheme.id {
            currentTheme = standardizedTheme
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

    @MainActor
    func applyThemeSnapshot(_ snapshot: ThemeSnapshot) {
        let canonicalTheme = Self.canonicalBuiltInTheme(matching: snapshot.id)
        guard let migratedSnapshot = snapshot.migratedToCurrentVersion(
            matching: canonicalTheme
        ) else {
            AppLogWarn("[ThemeSnapshot] Ignoring unsupported version \(snapshot.version) for \(snapshot.id)")
            return
        }
        let theme = migratedSnapshot.makeTheme(matching: canonicalTheme)
        AppLogDebug("[ThemeAlpha] applyThemeSnapshot id=\(theme.id) lightAlpha=\(theme.windowOverlayOpacity(for: .light)) darkAlpha=\(theme.windowOverlayOpacity(for: .dark))")
        registeredThemes[theme.id] = theme
        persistedThemeIDs.insert(theme.id)
        persistThemeSnapshots()
        currentTheme = theme
    }

    @MainActor
    @available(*, deprecated, message: "Theme overlay alpha is fixed at 0.8 in ThemeSnapshot V2.")
    public func updateCurrentThemeOverlayOpacity(_ opacity: CGFloat, for appearance: Appearance? = nil) {
        // Retain the old entry point for source compatibility, but V2 no longer
        // accepts user-defined alpha. Normalize every registered theme instead
        // of applying the requested value or appearance.
        var refreshedCurrent: Theme?
        for (themeId, theme) in registeredThemes {
            let updatedTheme = ThemeColorAdjustment.applyingStandardAlpha(to: theme)
            registeredThemes[themeId] = updatedTheme
            persistedThemeIDs.insert(themeId)
            if themeId == currentTheme.id {
                refreshedCurrent = updatedTheme
            }
        }
        persistThemeSnapshots()
        AppLogDebug("[ThemeAlpha] ignored legacy opacity=\(opacity) appearance=\(String(describing: appearance)) themes=\(registeredThemes.count)")
        if let refreshedCurrent {
            currentTheme = refreshedCurrent
        }
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
