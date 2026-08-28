// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Account-scoped preferences persisted to a plist under `account.userDataStorage/defaults`.
final class AccountUserDefaults {
    private let account: Account
    private let storeURL: URL
    private let queue: DispatchQueue
    private var storage: [String: Any]
    
    init(account: Account, storeURL overrideStoreURL: URL? = nil) {
        self.account = account
        let fileURL = overrideStoreURL
            ?? account.userDataStorage
                .appendingPathComponent("defaults", isDirectory: true)
                .appendingPathComponent("account_defaults.plist")
        let defaultsDir = fileURL.deletingLastPathComponent()
        self.storeURL = fileURL
        self.queue = DispatchQueue(label: "com.phibrowser.accountDefaults.\(account.userID)")
        
        do {
            try FileManager.default.createDirectory(at: defaultsDir, withIntermediateDirectories: true)
        } catch {
            AppLogError("Failed to create defaults directory: \(error.localizedDescription)")
        }
        
        self.storage = AccountUserDefaults.loadStore(from: fileURL)
    }
    
    // MARK: - Public API (UserDefaults-like)
    func object(forKey key: String) -> Any? {
        queue.sync {
            storage[key]
        }
    }
    
    func set(_ value: Any?, forKey key: String) {
        queue.sync {
            if let value = value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            persistLocked()
        }
    }
    
    func set(_ value: Any?, forKey key: DefaultsKey) {
        queue.sync {
            if let value = value {
                storage[key.rawValue] = value
            } else {
                storage.removeValue(forKey: key.rawValue)
            }
            persistLocked()
        }
    }
    
    func removeObject(forKey key: String) {
        set(nil, forKey: key)
    }
    
    func bool(forKey key: String) -> Bool {
        object(forKey: key) as? Bool ?? false
    }
    
    func integer(forKey key: String) -> Int {
        object(forKey: key) as? Int ?? 0
    }
    
    func double(forKey key: String) -> Double {
        object(forKey: key) as? Double ?? 0
    }
    
    func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }
    
    func data(forKey key: String) -> Data? {
        object(forKey: key) as? Data
    }
    
    func date(forKey key: String) -> Date? {
        object(forKey: key) as? Date
    }
    
    func set<T: Encodable>(_ value: T?, forCodableKey key: String) {
        guard let value = value else {
            removeObject(forKey: key)
            return
        }
        do {
            let data = try JSONEncoder().encode(value)
            set(data, forKey: key)
        } catch {
            AppLogError("Failed to encode value for key \(key): \(error.localizedDescription)")
        }
    }

    /// Atomically writes an encoded value only when the stored data has not
    /// changed since the caller captured `expectedData`.
    @discardableResult
    func set<T: Encodable>(
        _ value: T,
        forCodableKey key: String,
        ifCurrentDataEquals expectedData: Data?
    ) -> Bool {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            AppLogError("Failed to encode value for key \(key): \(error.localizedDescription)")
            return false
        }

        return queue.sync {
            guard (storage[key] as? Data) == expectedData else { return false }
            storage[key] = data
            persistLocked()
            return true
        }
    }
    
    func codableValue<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLogError("Failed to decode value for key \(key): \(error.localizedDescription)")
            return nil
        }
    }
    
    func removeAll() {
        queue.sync {
            storage.removeAll()
            persistLocked()
        }
    }
    
    // MARK: - Helpers
    private static func loadStore(from url: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return plist as? [String: Any] ?? [:]
        } catch {
            AppLogError("Failed to load account defaults: \(error.localizedDescription)")
            return [:]
        }
    }
    
    private func persistLocked() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: storage, format: .xml, options: 0)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            AppLogError("Failed to write account defaults: \(error.localizedDescription)")
        }
    }

    /// Merges only the Space-scoped visual preferences that belong to Guest
    /// data. Target values win so an account's existing appearance is never
    /// overwritten by a Guest Space that mapped onto the same identifier.
    ///
    /// Unlike the UserDefaults-like setters above, this operation reports
    /// persistence failures. Guest migration must not write its receipt until
    /// both the SwiftData transaction and these selected defaults are durable.
    func mergeGuestSpaceThemes(
        _ guestThemes: GuestDataMigrationThemeSnapshot,
        spaceIDMappings: [String: String]
    ) throws {
        try queue.sync {
            var updatedStorage = storage
            var themeIDs = (updatedStorage[DefaultsKey.spaceThemeIds.rawValue] as? [String: String]) ?? [:]
            var saturations = (updatedStorage[DefaultsKey.spaceThemeSaturations.rawValue] as? [String: [String: Double]]) ?? [:]
            var pureValues = (updatedStorage[DefaultsKey.spacePureThemeSliderValues.rawValue] as? [String: Double]) ?? [:]

            for sourceSpaceID in spaceIDMappings.keys.sorted() {
                guard let targetSpaceID = spaceIDMappings[sourceSpaceID] else { continue }
                if themeIDs[targetSpaceID] == nil,
                   let value = guestThemes.themeIDs[sourceSpaceID] {
                    themeIDs[targetSpaceID] = value
                }
                if saturations[targetSpaceID] == nil,
                   let value = guestThemes.saturations[sourceSpaceID] {
                    saturations[targetSpaceID] = value
                }
                if pureValues[targetSpaceID] == nil,
                   let value = guestThemes.pureSliderValues[sourceSpaceID] {
                    pureValues[targetSpaceID] = value
                }
            }

            updatedStorage[DefaultsKey.spaceThemeIds.rawValue] = themeIDs
            updatedStorage[DefaultsKey.spaceThemeSaturations.rawValue] = saturations
            updatedStorage[DefaultsKey.spacePureThemeSliderValues.rawValue] = pureValues
            try persistLocked(updatedStorage)
            storage = updatedStorage
        }
    }

    private func persistLocked(_ updatedStorage: [String: Any]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: updatedStorage,
            format: .xml,
            options: 0
        )
        try data.write(to: storeURL, options: .atomic)
    }

    /// Reads every Guest-migrated preference under one queue lock so cleanup
    /// cannot compare a mixture of values from different writes.
    func guestDataMigrationThemeSnapshot()
        -> GuestDataMigrationThemeSnapshot {
        queue.sync {
            GuestDataMigrationThemeSnapshot(
                themeIDs: (
                    storage[DefaultsKey.spaceThemeIds.rawValue]
                        as? [String: String]
                ) ?? [:],
                saturations: (
                    storage[DefaultsKey.spaceThemeSaturations.rawValue]
                        as? [String: [String: Double]]
                ) ?? [:],
                pureSliderValues: (
                    storage[DefaultsKey.spacePureThemeSliderValues.rawValue]
                        as? [String: Double]
                ) ?? [:]
            )
        }
    }
}

extension AccountUserDefaults {
    enum DefaultsKey: String {
        case loginPhase
        case cachedUserName
        case cachedProfile
        case cachedUserConnectors
        /// Controls whether notification cards auto-popup. Default is popup enabled.
        case notificationPopupMode
        case lastKnownSidebarWidth
        case authReauthenticationReason
        case authReauthenticationFirstDetectedAt
        case activeSpaceId
        /// Per-Space theme override map (`[spaceId: themeId]`). A spaceId
        /// missing from this map means "follow the global theme"; an entry
        /// means the Space pins itself to that theme regardless of the
        /// global selection. Stored here rather than on `SpaceModel` to
        /// avoid a schema migration for what is purely a UI preference.
        case spaceThemeIds
        /// Legacy per-Space window-overlay opacity map. ThemeSnapshot V2 no
        /// longer reads these values; the key remains only so Space deletion
        /// can clean records written by older builds.
        case spaceOverlayOpacities
        /// Per-Space theme saturation map. Overlay entries are keyed by
        /// appearance; `windowBackgroundDark` carries the matching dark
        /// window-background saturation.
        case spaceThemeSaturations
        /// Per-Space Pure-theme slider value. The shared position maps to
        /// separate light and dark brightness ranges.
        case spacePureThemeSliderValues
        /// Snapshot of the slot/window/Space layout written on every
        /// `SpaceWindowSlot.registerWindow`. Read on the next launch by
        /// `SpaceManager` so Chromium-restored windows reattach to the
        /// Space they had when the snapshot was saved, instead of all
        /// piling into the persisted-active Space.
        case slotsRestoreSnapshot
        /// The Migration Sources this account has already completed a
        /// Migration from, held as their source identifiers. A source listed
        /// here makes a second Migration from it warn before it starts.
        case migratedBrowserSources
    }
    
    /// Notification popup behavior mode.
    enum NotificationPopupMode: String {
        /// Cards automatically appear when new notifications arrive.
        case popup
        /// Cards stay hidden until the user opens them manually.
        case mute
        
        static var defaultValue: NotificationPopupMode { .popup }
    }
    
    /// Current notification popup mode.
    var notificationPopupMode: NotificationPopupMode {
        guard let rawValue = string(forKey: DefaultsKey.notificationPopupMode.rawValue),
              let mode = NotificationPopupMode(rawValue: rawValue) else {
            return .popup
        }
        return mode
    }
    
    /// Persists the notification popup mode and broadcasts the change.
    func setNotificationPopupMode(_ mode: NotificationPopupMode) {
        set(mode.rawValue, forKey: DefaultsKey.notificationPopupMode.rawValue)
        NotificationCenter.default.post(
            name: .notificationPopupModeDidChange,
            object: nil,
            userInfo: ["mode": mode]
        )
    }

    var lastKnownSidebarWidth: CGFloat {
        CGFloat(double(forKey: DefaultsKey.lastKnownSidebarWidth.rawValue))
    }

    func setLastKnownSidebarWidth(_ width: CGFloat) {
        guard width > 0 else {
            return
        }
        set(Double(width), forKey: DefaultsKey.lastKnownSidebarWidth.rawValue)
    }

    /// Snapshot of the per-Space theme override map. Returns an empty
    /// dictionary when no Spaces have a theme override set yet.
    func spaceThemeIds() -> [String: String] {
        (object(forKey: DefaultsKey.spaceThemeIds.rawValue) as? [String: String]) ?? [:]
    }

    /// Persists the per-Space theme override map verbatim. Callers should
    /// mutate a snapshot from `spaceThemeIds()` and pass the new map here.
    func setSpaceThemeIds(_ map: [String: String]) {
        set(map, forKey: DefaultsKey.spaceThemeIds.rawValue)
    }

    /// Reads legacy per-Space opacity records for cleanup only.
    func spaceOverlayOpacities() -> [String: [String: Double]] {
        (object(forKey: DefaultsKey.spaceOverlayOpacities.rawValue) as? [String: [String: Double]]) ?? [:]
    }

    /// Updates legacy per-Space opacity records during cleanup.
    func setSpaceOverlayOpacities(_ map: [String: [String: Double]]) {
        set(map, forKey: DefaultsKey.spaceOverlayOpacities.rawValue)
    }

    /// Snapshot of the per-Space theme-saturation map. Returns an empty
    /// dictionary when no Space has a custom saturation yet.
    func spaceThemeSaturations() -> [String: [String: Double]] {
        (object(forKey: DefaultsKey.spaceThemeSaturations.rawValue) as? [String: [String: Double]]) ?? [:]
    }

    /// Persists the per-Space theme-saturation map verbatim. Callers should
    /// mutate a snapshot from `spaceThemeSaturations()` and pass it back.
    func setSpaceThemeSaturations(_ map: [String: [String: Double]]) {
        set(map, forKey: DefaultsKey.spaceThemeSaturations.rawValue)
    }

    /// Snapshot of the per-Space Pure-theme slider-value map.
    func spacePureThemeSliderValues() -> [String: Double] {
        (object(forKey: DefaultsKey.spacePureThemeSliderValues.rawValue) as? [String: Double]) ?? [:]
    }

    /// Persists the per-Space Pure-theme slider-value map verbatim.
    func setSpacePureThemeSliderValues(_ map: [String: Double]) {
        set(map, forKey: DefaultsKey.spacePureThemeSliderValues.rawValue)
    }

    /// The Migration Sources this account has completed a Migration from.
    /// Empty until the first Migration finishes.
    func migratedBrowserSources() -> [String] {
        (object(forKey: DefaultsKey.migratedBrowserSources.rawValue) as? [String]) ?? []
    }

    /// Records that a Migration from `source` completed, leaving every other
    /// source's record alone. Idempotent: a third Migration from the same
    /// source leaves the list as the second one left it.
    func addMigratedBrowserSource(_ source: String) {
        var sources = migratedBrowserSources()
        guard !sources.contains(source) else { return }
        sources.append(source)
        set(sources, forKey: DefaultsKey.migratedBrowserSources.rawValue)
    }
}

extension Notification.Name {
    /// Posted when the notification popup mode setting changes.
    static let notificationPopupModeDidChange = Notification.Name("notificationPopupModeDidChange")
}
