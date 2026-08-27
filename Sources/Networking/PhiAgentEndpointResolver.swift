// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Where the browser must send a phi-agent request, as prescribed by Sentinel's
/// transport mode.
enum PhiAgentRoute: Equatable, Sendable {
    case loopback(baseURL: String)
    case broker(socketPath: String)
}

/// Resolves how in-app callers reach the local phi-agent, by asking the
/// Sentinel runner for its component exports. The exports carry both the
/// loopback base URL (Sentinel may remap phi-agent to a different port when the
/// default is occupied, so callers must not assume a fixed port) and the
/// transport mode Sentinel currently applies to clients.
///
/// The mode maps to a route with the same semantics as the extension
/// capability handshake documented in
/// `docs/service-broker-extension-boundary.md`:
///   - `legacy` — direct loopback HTTP against `phi-agent.api_base`.
///   - `uds`, `full_uds`, an absent field, an unrecognised value, or a failed
///     lookup — the account-scoped Service Broker Unix domain socket. Reading
///     an unusable answer as `legacy` would disable a working transport for
///     everyone; reading it as the broker preserves today's behaviour and still
///     fails on its own terms when the broker is genuinely unavailable.
///
/// Mirrors the caching strategy used by the Sentinel UI in
/// `sentinel/ui/src/services/phi-agent-client.ts`:
///   1. Ask Sentinel via IPC for the exports and the mode.
///   2. Cache the result in-process; collapse concurrent callers onto one
///      lookup using a single Task.
///   3. On any failure (no Sentinel, not signed in, malformed export, IPC
///      timeout) fall back to the historical local default and the fallback
///      mode so the existing UI "Service issue" path still surfaces a
///      meaningful error to the user instead of an opaque resolver failure.
///   4. Callers invalidate the cache when a request fails with a
///      transport-level error so the next call re-reads exports.
final actor PhiAgentEndpointResolver {
    static let shared = PhiAgentEndpointResolver()

    /// Last-resort base URL used when Sentinel cannot answer. Matches the
    /// historical hard-coded value so behaviour is unchanged when Sentinel
    /// is unavailable (not running, user not signed in, debug build whose
    /// bundle id does not match a known Sentinel bundle, etc.).
    static let fallbackBaseURL = "http://127.0.0.1:8788"

    private typealias Resolution = (baseURL: String, transportMode: SentinelTransportMode)

    private let exportsProvider: @Sendable () async throws -> SentinelComponentExports
    private let accountIDProvider: @Sendable () -> String?
    private let socketPathProvider: @Sendable (String) -> String?
    private var cached: Resolution?
    private var inflight: Task<Resolution, Never>?

    init(
        exportsProvider: @escaping @Sendable () async throws -> SentinelComponentExports,
        accountIDProvider: @escaping @Sendable () -> String?,
        socketPathProvider: @escaping @Sendable (String) -> String?
    ) {
        self.exportsProvider = exportsProvider
        self.accountIDProvider = accountIDProvider
        self.socketPathProvider = socketPathProvider
    }

    /// Production wiring. The providers are closures because `SentinelIPCClient`
    /// is a final class with a private init, so it cannot be substituted in
    /// tests by conforming a fake to its type.
    init(ipcClient: SentinelIPCClient = .shared) {
        self.init(
            exportsProvider: { try await ipcClient.getComponentExports() },
            accountIDProvider: { SharedAuthTokenStore.shared.authenticatedSnapshot()?.scope.accountID },
            socketPathProvider: { ServiceBrokerSocketPath.currentDataSocketPath(auth0Subject: $0) }
        )
    }

    /// Returns the route Sentinel currently prescribes for phi-agent requests.
    /// - Throws: ``PhiAgentTransportError/accountUnavailable`` when the broker
    ///   route is prescribed but no signed-in account (auth0 subject) or socket
    ///   path is available.
    func currentRoute() async throws -> PhiAgentRoute {
        let resolved = await resolution()
        guard resolved.transportMode != .legacy else {
            return .loopback(baseURL: resolved.baseURL)
        }
        guard let accountID = accountIDProvider(), !accountID.isEmpty,
              let socketPath = socketPathProvider(accountID) else {
            throw PhiAgentTransportError.accountUnavailable
        }
        return .broker(socketPath: socketPath)
    }

    /// Drops the cached resolution so the next lookup re-asks Sentinel. Call
    /// this from request error paths when a transport-level failure suggests
    /// the previously resolved route is stale.
    func invalidate() {
        cached = nil
    }

    // MARK: - Private

    private func resolution() async -> Resolution {
        if let cached {
            return cached
        }
        if let inflight {
            return await inflight.value
        }

        let task = Task<Resolution, Never> { [exportsProvider] in
            await Self.resolve(using: exportsProvider)
        }
        inflight = task
        let value = await task.value
        cached = value
        inflight = nil
        return value
    }

    private static func resolve(
        using exportsProvider: @Sendable () async throws -> SentinelComponentExports
    ) async -> Resolution {
        do {
            let exports = try await exportsProvider()
            let mode = exports.transportMode
            if let url = parsePhiAgentApiBase(from: exports.exportsJSON) {
                AppLogDebug("[PhiAgentEndpoint] resolved via Sentinel: \(url) (transport mode: \(mode.rawValue))")
                return (url, mode)
            }
            AppLogDebug("[PhiAgentEndpoint] phi-agent.api_base missing or invalid; using fallback")
            return (fallbackBaseURL, mode)
        } catch {
            AppLogDebug("[PhiAgentEndpoint] IPC lookup failed (\(error.localizedDescription)); using fallback")
            return (fallbackBaseURL, SentinelTransportMode.fallback)
        }
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
