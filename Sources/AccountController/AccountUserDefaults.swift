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
    
    init(account: Account) {
        self.account = account
        let defaultsDir = account.userDataStorage.appendingPathComponent("defaults", isDirectory: true)
        let fileURL = defaultsDir.appendingPathComponent("account_defaults.plist")
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
}

extension AccountUserDefaults {
    enum DefaultsKey: String {
        case loginPhase
        case cachedUserName
        case cachedProfile
        case cachedUserConnectors
        /// Controls whether notification cards auto-popup. Default is popup enabled.
        case notificationPopupMode
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
}

extension Notification.Name {
    /// Posted when the notification popup mode setting changes.
    static let notificationPopupModeDidChange = Notification.Name("notificationPopupModeDidChange")
}
