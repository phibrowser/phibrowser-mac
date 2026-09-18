// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Account-scoped preferences persisted to a plist under `account.userDataStorage/defaults`.
///
/// **内存永不领先磁盘（R-M3-4a-83）。** 六个写入面全部在同一个 `queue.sync` 块内先拍
/// 一份 `storage` 的快照，落盘失败就把快照写回去。于是进程内的字典与 plist 永远是同一
/// 份：一次失败的写不会在内存里留下一个「已经改过」的值，让下一轮的读-改-写以为没有
/// 变化而早退——那正是 §2.7「plist 写失败之后的第二轮」整行的病根。
///
/// 六个面里只有四个自带 `queue.sync`（两个 `set(_:forKey:)` 重载、CAS 面、`removeAll()`）；
/// `removeObject(forKey:)` 与 `set(_:forCodableKey:)` 是转发面，**不各开一个块**：再套
/// 一层会让快照跨两次入队，中间可以插进另一个写者，回滚就会把别人的写一起抹掉。它们的
/// 快照与回滚发生在被转发的那个块里。
///
/// 返回值的语义：前五个面是「**已落盘**」，第六个（`ifCurrentDataEquals:` 的 CAS 面）
/// 是「**已改变且已落盘**」。前五个带 `@discardableResult`，所以非同步调用方一处不改。
final class AccountUserDefaults {
    private let account: Account
    private let storeURL: URL
    private let queue: DispatchQueue
    private var storage: [String: Any]
    
    init(account: Account, storeURL overrideStoreURL: URL? = nil) {
        self.account = account
        let fileURL = overrideStoreURL ?? Self.storeURL(for: account)
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
    
    /// true = 已落盘。失败时 `storage` 回到写之前那一份（R-M3-4a-83）。
    @discardableResult
    func set(_ value: Any?, forKey key: String) -> Bool {
        queue.sync {
            let previous = storage
            if let value = value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
            guard persistLocked() else {
                storage = previous
                return false
            }
            return true
        }
    }

    /// `DefaultsKey` 重载有**自己的** `queue.sync` 块，所以回滚也要自己写一遍：
    /// 只改一个重载在类型上完全无声。
    @discardableResult
    func set(_ value: Any?, forKey key: DefaultsKey) -> Bool {
        queue.sync {
            let previous = storage
            if let value = value {
                storage[key.rawValue] = value
            } else {
                storage.removeValue(forKey: key.rawValue)
            }
            guard persistLocked() else {
                storage = previous
                return false
            }
            return true
        }
    }

    /// 转发面：快照与回滚在 `set(_:forKey:)` 的那个 `queue.sync` 块里，这里只把
    /// Bool 转出来。
    @discardableResult
    func removeObject(forKey key: String) -> Bool {
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
    
    /// 第二个转发面：编码之后走 `set(_:forKey:)`，回滚同样在那个块里。编码抛错是
    /// 「一个字节都没写」，回 false。
    @discardableResult
    func set<T: Encodable>(_ value: T?, forCodableKey key: String) -> Bool {
        guard let value = value else {
            return removeObject(forKey: key)
        }
        do {
            let data = try JSONEncoder().encode(value)
            return set(data, forKey: key)
        } catch {
            AppLogError("Failed to encode value for key \(key): \(error.localizedDescription)")
            return false
        }
    }

    /// Atomically writes an encoded value only when the stored data has not
    /// changed since the caller captured `expectedData`.
    ///
    /// **这一个面的 true 是「已改变 *且* 已落盘」**（R-M3-4a-83）：比不中回 false 并且
    /// 磁盘零写，比中但落盘失败也回 false 并把 `storage` 还原——后者今天是一次假阳，
    /// 值进了内存、没进 plist。
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
            let previous = storage
            guard (storage[key] as? Data) == expectedData else { return false }
            storage[key] = data
            guard persistLocked() else {
                storage = previous
                return false
            }
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
    
    /// 失败时还原的是**整张字典**，不是被碰过的那一个键：这个面的失败态是整份账户
    /// 偏好在内存里凭空消失。
    @discardableResult
    func removeAll() -> Bool {
        queue.sync {
            let previous = storage
            storage.removeAll()
            guard persistLocked() else {
                storage = previous
                return false
            }
            return true
        }
    }
    
    // MARK: - Helpers
    /// Where `account`'s defaults plist lives.
    static func storeURL(for account: Account) -> URL {
        account.userDataStorage
            .appendingPathComponent("defaults", isDirectory: true)
            .appendingPathComponent("account_defaults.plist")
    }

    /// One value straight off the plist of the account with `userID`, without
    /// opening a store: no directory is created and nothing is retained. For
    /// the launch-time read that runs before any account is bound
    /// (`SpaceManager.coldStartPreferredProfiles`).
    static func storedObject(forKey key: DefaultsKey, ofAccountWithUserID userID: String) -> Any? {
        loadStore(from: storeURL(for: Account(userID: userID)))[key.rawValue]
    }

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
    
    /// 调用方**必须**已经持有 `queue`，并且必须处理 false：六个写入面按它回滚。
    private func persistLocked() -> Bool {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: storage, format: .xml, options: 0)
            try data.write(to: storeURL, options: .atomic)
            return true
        } catch {
            AppLogError("Failed to write account defaults: \(error.localizedDescription)")
            return false
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
        case authReauthenticationIncidentID
        case activeSpaceId
        /// The Space currently holding the "default" role (see
        /// `SpaceManager.currentDefaultSpaceId`). Absent until the user
        /// deletes the well-known `default-space`, whose id is the
        /// implicit initial value; deletion hands the role to another
        /// Space and records it here so it survives relaunches.
        case defaultSpaceId
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
