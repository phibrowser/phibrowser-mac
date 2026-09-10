// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import Network

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
        let hosts = try Self.collectionHosts(for: host)
        try Self.validateProfileID(profileID)
        return try Self.queue.sync {
            let disabled = try load()[profileID] ?? []
            return !hosts.contains(where: disabled.contains)
        }
    }

    func setCollectionEnabled(_ enabled: Bool, for host: String, profileID: String) throws {
        let hosts = try Self.collectionHosts(for: host)
        try Self.validateProfileID(profileID)
        try Self.queue.sync(flags: .barrier) {
            var profiles = try load()
            var disabled = Set(profiles[profileID] ?? [])
            // Remove either legacy spelling and persist one entry for the pair.
            disabled.subtract(hosts)
            if !enabled { disabled.insert(hosts[0]) }
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

    private static func collectionHosts(for input: String) throws -> [String] {
        let host = try normalizedHost(input)
        guard let domain = registrableDomain(for: host),
              host == domain || host == "www.\(domain)" else { return [host] }
        return [domain, "www.\(domain)"]
    }

    private static let publicSuffixRules: Set<String>? = {
        guard let url = Bundle.main.url(forResource: "PublicSuffixes", withExtension: "dat"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var rules = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let prefix = rule.hasPrefix("!") ? "!" : rule.hasPrefix("*.") ? "*." : ""
            guard let host = URL(string: "https://\(rule.dropFirst(prefix.count))")?.host else { return nil }
            rules.insert(prefix + host.lowercased())
        }
        return rules.isEmpty ? nil : rules
    }()

    /// Matches the bundled public suffix rules, including wildcards and exceptions.
    static func registrableDomain(for input: String) -> String? {
        guard let host = try? normalizedHost(input), IPv4Address(host) == nil,
              let rules = publicSuffixRules else { return nil }
        let labels = host.split(separator: ".")
        var suffixCount = 1
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if rules.contains("!" + suffix) {
                suffixCount = labels.count - index - 1
                break
            }
            let wildcard = "*." + labels.dropFirst(index + 1).joined(separator: ".")
            if rules.contains(suffix) || rules.contains(wildcard) {
                suffixCount = max(suffixCount, labels.count - index)
            }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
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
