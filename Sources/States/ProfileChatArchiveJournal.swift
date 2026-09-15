// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation

/// Delivery state only; conversations and archive receipts belong to phi-agent.
/// Each journal lives inside one account's local data directory, never preferences.
struct ProfileChatArchiveJournal {
    struct Entry: Codable, Equatable {
        let operationId: String
        let profileId: String
        var confirmed: Bool
    }

    let fileURL: URL

    static func deliveryAllowed(aiEnabled: Bool, authenticated: Bool) -> Bool {
        aiEnabled && authenticated
    }

    func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL))
    }

    func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func prepare(profileId: String) throws -> Entry {
        var entries = try load()
        let entry = Entry(operationId: UUID().uuidString, profileId: profileId, confirmed: false)
        entries.append(entry)
        try save(entries)
        return entry
    }

    func finish(_ operationId: String, deleted: Bool) throws {
        var entries = try load()
        if deleted {
            if let index = entries.firstIndex(where: { $0.operationId == operationId }) {
                entries[index].confirmed = true
            }
        } else {
            entries.removeAll { $0.operationId == operationId }
        }
        try save(entries)
    }

    /// Recover a crash after Chromium deletion but before its callback was saved.
    /// Only call with an authoritative, available native Profile list.
    func ready(existingProfileIds: Set<String>) throws -> [Entry] {
        let entries = try load()
        return entries.filter { $0.confirmed || !existingProfileIds.contains($0.profileId) }
    }
}
