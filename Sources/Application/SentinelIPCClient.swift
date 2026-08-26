// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import CryptoKit

/// Lightweight IPC client for communicating with the Sentinel runner process
/// via Unix Domain Socket. Used by the browser to forward extension requests
/// to the runner (e.g., fetching service component exports).
final class SentinelIPCClient: Sendable {
    static let shared = SentinelIPCClient()

    private let clientVersion = "1.0.0"
    private let protocolVersion = 1

    /// Wire key of Sentinel's additive transport-mode signal.
    private static let transportModeKey = "transport_mode"

    private init() {}

    // MARK: - Public API

    /// Fetches component exports from the Sentinel runner, together with the
    /// transport mode Sentinel reports alongside them.
    /// - Returns: The exports JSON string plus the decoded transport mode.
    func getComponentExports() async throws -> SentinelComponentExports {
        let response = try await sendRequest(method: "getComponentExports", params: [:])

        guard let ok = response["ok"] as? Bool, ok else {
            if let error = response["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw IPCError.runnerError(message: message)
            }
            throw IPCError.runnerError(message: "Failed to get component exports")
        }

        return SentinelComponentExports(
            exportsJSON: try Self.exportsJSON(fromResponse: response),
            transportMode: Self.transportMode(fromResponse: response)
        )
    }

    /// Re-serializes the exports object of a `getComponentExports` response.
    ///
    /// The object is forwarded to extensions and to ``PhiAgentEndpointResolver``
    /// as Sentinel sent it, with exactly one deliberate exception: the additive
    /// `transport_mode` key is removed. That key is a browser-facing routing
    /// signal, not a component export, and it is a bare string sitting among
    /// component-ID objects — consumers that walk the exports object must never
    /// meet it. It is surfaced instead as
    /// ``SentinelComponentExports/transportMode``.
    static func exportsJSON(fromResponse response: [String: Any]) throws -> String {
        var result = response["result"] ?? [String: Any]()
        if var exports = result as? [String: Any], exports[transportModeKey] != nil {
            exports.removeValue(forKey: transportModeKey)
            result = exports
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Extracts the additive `transport_mode` from a `getComponentExports`
    /// response. Sentinel may place the field at the envelope root (next to
    /// `result`) or inside the exports object (next to the component IDs); both
    /// are accepted, envelope root first, first recognised value wins. An
    /// absent, non-string, or unrecognised value reads as
    /// ``SentinelTransportMode/fallback``, so a Sentinel that never reports a
    /// mode behaves exactly as before the field existed.
    static func transportMode(fromResponse response: [String: Any]) -> SentinelTransportMode {
        if let raw = response[transportModeKey] as? String,
           let mode = SentinelTransportMode(rawValue: raw) {
            return mode
        }
        if let result = response["result"] as? [String: Any],
           let raw = result[transportModeKey] as? String,
           let mode = SentinelTransportMode(rawValue: raw) {
            return mode
        }
        return .fallback
    }

    // MARK: - Socket Path Resolution

    /// Resolves the runner IPC socket path.
    /// The socket lives at /tmp/phi-sentinel-<hash>/runner.sock where hash is
    /// derived from the Sentinel's user-specific storage path. Falls back to the
    /// legacy $TMPDIR-rooted path when only a pre-migration Sentinel is running.
    private func socketPath() -> String? {
        guard let storagePath = sentinelStoragePath() else { return nil }
        return ipcSocketPath(for: storagePath)
    }

    /// Computes the Sentinel user-specific storage path from the browser side.
    /// Path: ~/Library/Application Support/<sentinelBundleId>/<userSub>/
    private func sentinelStoragePath() -> String? {
        guard let auth0Sub = currentAuth0Sub(), !auth0Sub.isEmpty else { return nil }

        let sentinelBundleId = sentinelBundleIdentifier()
        guard let appSupportURL = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }

        let safeSub = sanitizePathComponent(auth0Sub)
        let storagePath = appSupportURL
            .appendingPathComponent(sentinelBundleId, isDirectory: true)
            .appendingPathComponent(safeSub, isDirectory: true)
            .path

        guard FileManager.default.fileExists(atPath: storagePath) else { return nil }
        return storagePath
    }

    private func sentinelBundleIdentifier() -> String {
        let mainBundleID = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        if mainBundleID.contains("canary") {
            return "com.phibrowser.canary.Sentinel"
        }
        return "com.phibrowser.Sentinel"
    }

    private func currentAuth0Sub() -> String? {
        if let token = SharedAuthTokenStore.shared.read() {
            return token.auth0Sub
        }
        return nil
    }

    /// Mirrors FileSystemUtils.sanitizePathComponent from Sentinel.
    private func sanitizePathComponent(_ component: String) -> String {
        var result = component
        let problematicChars: [Character] = ["/", ":", "|", "\\", "*", "?", "\"", "<", ">"]
        for char in problematicChars {
            result = result.replacingOccurrences(of: String(char), with: "_")
        }
        return result
    }

    /// Mirrors FileSystemUtils.ipcSocketPath from Sentinel: the current path is
    /// rooted at a fixed /tmp (keeps the UDS path under the 104-byte limit).
    /// Falls back to the legacy NSTemporaryDirectory()/$TMPDIR root so a browser
    /// updated ahead of Sentinel can still reach a pre-migration runner.
    private func ipcSocketPath(for storagePath: String) -> String {
        let data = Data(storagePath.utf8)
        let hash = SHA256.hash(data: data)
        let shortHash = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let dirName = "phi-sentinel-\(shortHash)"
        let current = (("/tmp" as NSString).appendingPathComponent(dirName) as NSString)
            .appendingPathComponent("runner.sock")
        if FileManager.default.fileExists(atPath: current) { return current }
        let legacy = ((NSTemporaryDirectory() as NSString).appendingPathComponent(dirName) as NSString)
            .appendingPathComponent("runner.sock")
        if FileManager.default.fileExists(atPath: legacy) { return legacy }
        return current
    }

    // MARK: - IPC Transport

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let sockPath = socketPath() else {
            throw IPCError.socketNotFound
        }

        guard FileManager.default.fileExists(atPath: sockPath) else {
            throw IPCError.socketNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do {
                    let result = try self.performIPCRequest(socketPath: sockPath, method: method, params: params)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performIPCRequest(socketPath sockPath: String, method: String, params: [String: Any]) throws -> [String: Any] {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw IPCError.connectionFailed
        }
        defer { close(sock) }
        configureSocketTimeout(sock, timeoutSeconds: 5)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            sockPath.withCString { cString in
                strcpy(ptr, cString)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw IPCError.connectionFailed
        }

        try performHandshake(socket: sock)

        let requestId = UUID().uuidString
        let request: [String: Any] = [
            "protocol_version": protocolVersion,
            "request_id": requestId,
            "method": method,
            "params": params
        ]

        try sendFrame(socket: sock, data: request)
        return try readFrame(socket: sock)
    }

    private func configureSocketTimeout(_ socket: Int32, timeoutSeconds: Int) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, ptr, timeoutSize)
            _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, ptr, timeoutSize)
        }
    }

    private func performHandshake(socket: Int32) throws {
        let hello = try readFrame(socket: socket)

        guard let challenge = hello["challenge"] as? String else {
            throw IPCError.handshakeFailed
        }

        let ack: [String: Any] = [
            "challenge_response": challenge,
            "client_version": clientVersion,
            "protocol_version": protocolVersion
        ]

        try sendFrame(socket: socket, data: ack)
    }

    private func sendFrame(socket: Int32, data: [String: Any]) throws {
        let jsonData = try JSONSerialization.data(withJSONObject: data)

        var length = UInt32(jsonData.count).bigEndian
        let lengthWritten = withUnsafeBytes(of: &length) { ptr in
            Darwin.write(socket, ptr.baseAddress!, 4)
        }
        guard lengthWritten == 4 else {
            throw IPCError.writeFailed
        }

        var totalWritten = 0
        while totalWritten < jsonData.count {
            let bytesWritten = jsonData.withUnsafeBytes { ptr in
                Darwin.write(socket, ptr.baseAddress! + totalWritten, jsonData.count - totalWritten)
            }
            guard bytesWritten > 0 else {
                throw IPCError.writeFailed
            }
            totalWritten += bytesWritten
        }
    }

    private func readFrame(socket: Int32) throws -> [String: Any] {
        var lengthBE: UInt32 = 0
        let lengthRead = withUnsafeMutableBytes(of: &lengthBE) { ptr in
            Darwin.read(socket, ptr.baseAddress!, 4)
        }
        guard lengthRead == 4 else {
            throw IPCError.readFailed
        }

        let length = Int(UInt32(bigEndian: lengthBE))
        guard length > 0, length < 4 * 1024 * 1024 else {
            throw IPCError.frameTooLarge
        }

        var data = Data(count: length)
        var totalRead = 0
        while totalRead < length {
            let bytesRead = data.withUnsafeMutableBytes { ptr in
                Darwin.read(socket, ptr.baseAddress! + totalRead, length - totalRead)
            }
            guard bytesRead > 0 else {
                throw IPCError.readFailed
            }
            totalRead += bytesRead
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPCError.invalidResponse
        }
        return json
    }

    // MARK: - Errors

    enum IPCError: LocalizedError {
        case socketNotFound
        case connectionFailed
        case handshakeFailed
        case writeFailed
        case readFailed
        case frameTooLarge
        case invalidResponse
        case runnerError(message: String)

        var errorDescription: String? {
            switch self {
            case .socketNotFound: return "Sentinel runner IPC socket not found"
            case .connectionFailed: return "Failed to connect to Sentinel runner"
            case .handshakeFailed: return "Sentinel runner handshake failed"
            case .writeFailed: return "Failed to write to Sentinel runner"
            case .readFailed: return "Failed to read from Sentinel runner"
            case .frameTooLarge: return "Sentinel runner response frame too large"
            case .invalidResponse: return "Invalid response from Sentinel runner"
            case .runnerError(let message): return "Sentinel runner error: \(message)"
            }
        }
    }
}

/// The client-routing policy Sentinel currently applies, reported as an
/// additive `transport_mode` field on the `getComponentExports` IPC response.
///
/// `legacy` means clients must not use the Service Broker at all and should use
/// the pre-broker direct loopback path; `uds` and `full_uds` both mean the
/// broker path is in use. Sentinel builds older than the staged-rollout change
/// omit the field entirely.
enum SentinelTransportMode: String, Sendable, Equatable, CaseIterable {
    case legacy
    case uds
    case fullUDS = "full_uds"

    /// The mode assumed when Sentinel reports nothing usable: an absent field
    /// (any Sentinel released before the field existed, all of which run the
    /// broker) or an unrecognised value (only a newer Sentinel can produce one,
    /// and `legacy` is the single explicitly named opt-out). Reading either as
    /// `legacy` would disable a working transport for everyone; reading them as
    /// `uds` preserves today's behaviour and still fails safely if the broker is
    /// genuinely unavailable.
    static let fallback: SentinelTransportMode = .uds
}

/// A `getComponentExports` reply: the exports object as Sentinel sent it, plus
/// the transport mode that came with it.
struct SentinelComponentExports: Sendable, Equatable {
    /// The response's `result` object, re-serialized for forwarding. Component
    /// entries are untouched; only the additive `transport_mode` key is removed,
    /// because it is a browser-facing signal rather than a component export.
    let exportsJSON: String
    let transportMode: SentinelTransportMode
}
