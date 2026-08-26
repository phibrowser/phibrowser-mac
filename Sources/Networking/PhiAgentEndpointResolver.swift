// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Resolves the local phi-agent HTTP base URL by asking the Sentinel runner
/// for its component exports. Sentinel may remap phi-agent to a different
/// port when the default is occupied, so callers must not assume a fixed port.
///
/// Mirrors the strategy used by the Sentinel UI in
/// `sentinel/ui/src/services/phi-agent-client.ts`:
///   1. Ask Sentinel via IPC for `phi-agent.api_base`.
///   2. Cache the result in-process; collapse concurrent callers onto one
///      lookup using a single Task.
///   3. On any failure (no Sentinel, not signed in, malformed export, IPC
///      timeout) fall back to the historical local default so the existing
///      UI "Service issue" path still surfaces a meaningful error to the
///      user instead of an opaque resolver failure.
///   4. Callers invalidate the cache when an HTTP request fails with a
///      transport-level error so the next call re-reads exports.
final actor PhiAgentEndpointResolver {
    static let shared = PhiAgentEndpointResolver()

    /// Last-resort base URL used when Sentinel cannot answer. Matches the
    /// historical hard-coded value so behaviour is unchanged when Sentinel
    /// is unavailable (not running, user not signed in, debug build whose
    /// bundle id does not match a known Sentinel bundle, etc.).
    static let fallbackBaseURL = "http://127.0.0.1:8788"

    private let ipcClient: SentinelIPCClient
    private var cachedBaseURL: String?
    private var inflight: Task<String, Never>?

    init(ipcClient: SentinelIPCClient = .shared) {
        self.ipcClient = ipcClient
    }

    /// Returns the current phi-agent base URL. Always succeeds — falls back
    /// to ``fallbackBaseURL`` rather than throwing so HTTP callers can treat
    /// resolution as a non-error step.
    func currentBaseURL() async -> String {
        if let cached = cachedBaseURL {
            return cached
        }
        if let inflight {
            return await inflight.value
        }

        let task = Task<String, Never> { [ipcClient] in
            let resolved = await Self.resolve(using: ipcClient)
            return resolved
        }
        inflight = task
        let value = await task.value
        cachedBaseURL = value
        inflight = nil
        return value
    }

    /// Drops the cached endpoint so the next ``currentBaseURL()`` re-asks
    /// Sentinel. Call this from HTTP error paths when a transport-level
    /// failure suggests the previously resolved endpoint is stale.
    func invalidate() {
        cachedBaseURL = nil
    }

    // MARK: - Private

    private static func resolve(using ipcClient: SentinelIPCClient) async -> String {
        do {
            let exports = try await ipcClient.getComponentExports()
            if let url = parsePhiAgentApiBase(from: exports.exportsJSON) {
                AppLogDebug("[PhiAgentEndpoint] resolved via Sentinel: \(url)")
                return url
            }
            AppLogDebug("[PhiAgentEndpoint] phi-agent.api_base missing or invalid; using fallback")
        } catch {
            AppLogDebug("[PhiAgentEndpoint] IPC lookup failed (\(error.localizedDescription)); using fallback")
        }
        return fallbackBaseURL
    }

    /// Extracts and normalizes `phi-agent.api_base` from the JSON string
    /// returned by `SentinelIPCClient.getComponentExports()` as `exportsJSON`.
    /// Returns nil when the field is absent, not a string, or not a valid URL.
    static func parsePhiAgentApiBase(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phiAgent = root["phi-agent"] as? [String: Any],
              let raw = phiAgent["api_base"] as? String
        else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            return nil
        }

        // Strip trailing slashes so callers can append "/api/..." uniformly,
        // matching how the Sentinel UI normalizes the same value.
        var normalized = trimmed
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
