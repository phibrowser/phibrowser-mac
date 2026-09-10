// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum SiteMemoryError: Error {
    case invalidHost
    case invalidProfileID
    case accountUnavailable
    case unauthorizedSender
    case invalidResponse
    case serviceRejected(Int)
}

struct SiteMemorySettingsStore: Sendable {
    // Shared across instances: readers may overlap; a read-modify-write owns
    // the barrier until the atomic disk replacement finishes. No await under it.
    private static let queue = DispatchQueue(
        label: "com.phibrowser.siteMemorySettings", attributes: .concurrent)
    let fileURL: URL

    func collectionEnabled(for host: String, profileID: String) throws -> Bool {
        let host = try Self.normalizedHost(host)
        try Self.validateProfileID(profileID)
        return try Self.queue.sync {
            !(try load()[profileID] ?? []).contains(host)
        }
    }

    func setCollectionEnabled(_ enabled: Bool, for host: String, profileID: String) throws {
        let host = try Self.normalizedHost(host)
        try Self.validateProfileID(profileID)
        try Self.queue.sync(flags: .barrier) {
            var profiles = try load()
            var disabled = Set(profiles[profileID] ?? [])
            if enabled { disabled.remove(host) } else { disabled.insert(host) }
            if disabled.isEmpty { profiles.removeValue(forKey: profileID) }
            else { profiles[profileID] = disabled.sorted() }
            let data = try JSONEncoder().encode(profiles)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() throws -> [String: [String]] {
        do {
            return try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
    }

    // Accept a bare hostname only. Match the backend's lowercase/trailing-dot
    // semantics without turning a URL or wildcard into a broader deletion.
    static func normalizedHost(_ input: String) throws -> String {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.range(of: #"^[a-z0-9_-]+(\.[a-z0-9_-]+)*$"#, options: .regularExpression) != nil else {
            throw SiteMemoryError.invalidHost
        }
        return host
    }

    static func validateProfileID(_ profileID: String) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 255,
              profileID == profileID.trimmingCharacters(in: .whitespacesAndNewlines),
              !profileID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SiteMemoryError.invalidProfileID
        }
    }
}
