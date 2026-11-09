// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// The last choice per input in the V2 omnibox, one file per account and
/// profile. It lives outside SwiftData and the omnibox FIFO, so a
/// write never makes displayed results stale, and it is never synced.
@MainActor
final class OmniboxLearningStore {
    struct Limits {
        var maxEntries = 2000
        var maxTextBytes = 256
        var window: TimeInterval = 90 * 24 * 60 * 60
        var maxSnapshotBytes = 256 * 1024
        var saveDelay: Duration = .seconds(1)
    }

    private struct File: Codable {
        static let currentVersion = 2
        var version = currentVersion
        var entries: [OmniboxNativeLearningEntry]
    }

    private static var stores: [URL: OmniboxLearningStore] = [:]
    private static let ioQueue = DispatchQueue(label: "com.phibrowser.omnibox-learning", qos: .utility)

    /// One cache per file, shared by every window of the profile.
    static func store(directory: URL, profileID: String) -> OmniboxLearningStore {
        let name = profileID.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        let url = directory.appendingPathComponent("OmniboxLearning-\(name).json")
        if let store = stores[url] { return store }
        let store = OmniboxLearningStore(fileURL: url)
        stores[url] = store
        return store
    }

    let fileURL: URL
    private let limits: Limits
    private(set) var entries: [OmniboxNativeLearningEntry]
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL, limits: Limits = Limits(), now: Date = Date()) {
        self.fileURL = fileURL
        self.limits = limits
        entries = Self.load(fileURL)
        let cutoff = now.timeIntervalSince1970 - limits.window
        entries.removeAll { $0.lastUsed < cutoff }
    }

    /// Replaces the previous choice for `text`. A nil `entityID` records an
    /// ordinary row.
    func record(text: String, kind: OmniboxNativeEntityKind?, entityID: String?, now: Date = Date()) {
        guard !text.isEmpty, text.utf8.count <= limits.maxTextBytes,
              (kind == nil) == (entityID == nil), entityID?.isEmpty != true else { return }
        entries.removeAll { $0.text == text }
        entries.append(.init(text: text, kind: kind, entityID: entityID, lastUsed: now.timeIntervalSince1970))
        if entries.count > limits.maxEntries {
            entries.sort { $0.lastUsed > $1.lastUsed }
            entries.removeLast(entries.count - limits.maxEntries)
        }
        scheduleSave()
    }

    /// Ordinary choices and choices of the given `kind:entityID` keys inside
    /// the decay window, most recent first, within the snapshot byte budget.
    func snapshotEntries(for keys: Set<String>, now: Date = Date()) -> [OmniboxNativeLearningEntry] {
        let cutoff = now.timeIntervalSince1970 - limits.window
        let encoder = JSONEncoder()
        var bytes = 2
        var result: [OmniboxNativeLearningEntry] = []
        for entry in entries.sorted(by: { $0.lastUsed > $1.lastUsed })
        where entry.lastUsed >= cutoff && entry.isIncluded(in: keys) {
            guard let size = try? encoder.encode(entry).count else { continue }
            bytes += size + 1
            guard bytes <= limits.maxSnapshotBytes else { break }
            result.append(entry)
        }
        return result
    }

    /// History in [begin, end) was deleted; inputs last used there go with it.
    func removeEntries(lastUsedFrom begin: Double, to end: Double) {
        let count = entries.count
        entries.removeAll { $0.lastUsed >= begin && $0.lastUsed < end }
        guard entries.count != count else { return }
        AppLogInfo("[OmniboxLearning] removed \(count - entries.count) entries after history deletion")
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = limits.saveDelay
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.save()
        }
    }

    private func save() {
        saveTask = nil
        guard let data = try? JSONEncoder().encode(File(entries: entries)) else { return }
        let url = fileURL
        Self.ioQueue.async {
            // No intermediate directories: a removed account directory stays removed.
            do { try data.write(to: url, options: .atomic) } catch {
                AppLogWarn("[OmniboxLearning] save failed: \(error.localizedDescription)")
            }
        }
    }

    private static func load(_ url: URL) -> [OmniboxNativeLearningEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let file = try JSONDecoder().decode(File.self, from: data)
            return file.version == File.currentVersion ? file.entries : []
        } catch {
            AppLogWarn("[OmniboxLearning] unreadable file moved aside: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            return []
        }
    }
}

private extension OmniboxNativeLearningEntry {
    func isIncluded(in keys: Set<String>) -> Bool {
        guard let kind, let entityID else { return true }
        return keys.contains("\(kind.rawValue):\(entityID)")
    }
}
