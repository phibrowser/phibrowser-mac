// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
final class AIChatSidebarStateStore {
    struct AIChatSidebarState: Codable {
        var isCollapsed: Bool
        var width: Double
        var lastSeenDate: Date
        var version: Int
    }

    static let shared = AIChatSidebarStateStore()

    enum URLCacheMode {
        case origin
        case fullURL
    }

    enum FeatureFlags {
        static let cacheMode: URLCacheMode = .origin
        static let autoRestoreExpandedSidebarEnabled = false
        static let writeDebounceSeconds: TimeInterval = 0.8
        static let maxEntries = 2000
        static let staleAfterDays = 14
    }

    private enum Constants {
        static let cacheDirectoryName = "cache"
        static let cacheFileName = "ai_chat_sidebar_state_v1.json"
    }

    private let queue = DispatchQueue(label: "com.phi.aiChatSidebarStateStore")
    private var storage: [String: AIChatSidebarState] = [:]
    private var loadedAccountID: String?
    private var loadedStoreURL: URL?
    private var pendingPersistWorkItem: DispatchWorkItem?
    private var hasDirtyChanges = false

    private init() {}

    func state(for urlString: String) -> AIChatSidebarState? {
        queue.sync {
            ensureStoreLoadedLocked()
            guard let key = cacheKeyLocked(for: urlString), var state = storage[key] else { return nil }
            state.lastSeenDate = Date()
            storage[key] = state
            hasDirtyChanges = true
            schedulePersistLocked()
            return state
        }
    }

    func cachedState(for urlString: String) -> AIChatSidebarState? {
        queue.sync {
            ensureStoreLoadedLocked()
            guard let key = cacheKeyLocked(for: urlString) else { return nil }
            return storage[key]
        }
    }

    func record(urlString: String, isCollapsed: Bool, width: CGFloat) {
        queue.async {
            self.ensureStoreLoadedLocked()
            guard let key = self.cacheKeyLocked(for: urlString) else { return }

            let state = AIChatSidebarState(
                isCollapsed: isCollapsed,
                width: Double(width),
                lastSeenDate: Date(),
                version: 1
            )
            self.storage[key] = state
            self.hasDirtyChanges = true
            self.pruneLocked()
            self.schedulePersistLocked()
        }
    }

    private func ensureStoreLoadedLocked() {
        let account = currentAccountLocked()
        guard loadedAccountID != account.userID else { return }

        flushPendingPersistLocked()
        loadedAccountID = account.userID
        loadedStoreURL = cacheStoreURL(for: account)
        storage = loadStorageLocked(from: loadedStoreURL) ?? [:]
        pruneLocked()
        schedulePersistLocked()
    }

    private func currentAccountLocked() -> Account {
        AccountController.shared.account ?? AccountController.defaultAccount
    }

    private func flushPendingPersistLocked() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        persistLocked()
    }

    private func persistLocked() {
        guard hasDirtyChanges, let loadedStoreURL else { return }
        do {
            let data = try JSONEncoder().encode(storage)
            try FileManager.default.createDirectory(
                at: loadedStoreURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: loadedStoreURL, options: .atomic)
        } catch {
            AppLogError("Failed to persist AI chat sidebar state cache: \(error.localizedDescription)")
        }
        hasDirtyChanges = false
    }

    private func schedulePersistLocked() {
        pendingPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistLocked()
            self.pendingPersistWorkItem = nil
        }
        pendingPersistWorkItem = workItem
        queue.asyncAfter(deadline: .now() + FeatureFlags.writeDebounceSeconds, execute: workItem)
    }

    private func pruneLocked() {
        let countBefore = storage.count
        let staleCutoff = Date().addingTimeInterval(TimeInterval(-FeatureFlags.staleAfterDays * 24 * 60 * 60))
        storage = storage.filter { $0.value.lastSeenDate >= staleCutoff }

        let overflowCount = storage.count - FeatureFlags.maxEntries
        if overflowCount > 0 {
            let keysToDrop = storage
                .sorted { $0.value.lastSeenDate < $1.value.lastSeenDate }
                .prefix(overflowCount)
                .map(\.key)
            keysToDrop.forEach { storage.removeValue(forKey: $0) }
        }

        if storage.count != countBefore {
            hasDirtyChanges = true
        }
    }

    private func cacheStoreURL(for account: Account) -> URL {
        account.userDataStorage
            .appendingPathComponent(Constants.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(Constants.cacheFileName, isDirectory: false)
    }

    private func loadStorageLocked(from url: URL?) -> [String: AIChatSidebarState]? {
        guard let url else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: AIChatSidebarState].self, from: data)
        } catch {
            AppLogError("Failed to load AI chat sidebar state cache: \(error.localizedDescription)")
            return nil
        }
    }

    private func cacheKeyLocked(for rawURL: String) -> String? {
        guard let normalizedURL = normalizeURL(from: rawURL) else { return nil }
        switch FeatureFlags.cacheMode {
        case .origin:
            return originKey(from: normalizedURL)
        case .fullURL:
            return "full:\(normalizedURL.absoluteString)"
        }
    }

    private func normalizeURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func originKey(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        var origin = "\(scheme)://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        return "origin:\(origin)"
    }
}
