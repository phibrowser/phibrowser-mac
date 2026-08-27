// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - Data Models

struct TelegramPrepareResponse: Codable {
    let agent: AgentInfo
    let pairing: PairingSession

    struct AgentInfo: Codable {
        let id: String
        let token: String?
        let isNew: Bool
    }
}

struct PairingSession: Codable {
    let sessionId: String
    let deepLink: String?
    let expiresAt: Int
    let status: String
    let pairedAt: Int?
    let platform: String?
    let platformUserId: String?
    let platformUsername: String?
    let platformName: String?
}

struct ChannelPairing: Codable, Identifiable {
    let id: String
    let platform: String
    let platformUserId: String
    let platformUsername: String?
    let platformName: String?
    let pairedAt: String
    let agentId: String?
    let channelId: String?
    let localStatus: String?
}

struct CustomBotChannel: Codable, Identifiable {
    // CouchDB uses _id, but Swift prefers `id`
    let _id: String
    let channelType: String
    let name: String
    let enabled: Bool
    let config: [String: AnyCodableValue]?
    let status: String
    let statusMessage: String?
    let isRunning: Bool
    let botUsername: String?
    let createdAt: Double?
    let updatedAt: Double?

    var id: String { _id }
}

struct CustomBotListResponse: Codable {
    let channels: [CustomBotChannel]
    let connected: Bool
}

struct PairingsListResponse: Codable {
    let pairings: [ChannelPairing]?
}

/// Lightweight wrapper so arbitrary JSON values survive Codable round-trips.
enum AnyCodableValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Int.self) { self = .int(v) }
        else if let v = try? container.decode(Double.self) { self = .double(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

struct AgentPersonaResponse: Codable {
    let variables: PersonaVariables?

    struct PersonaVariables: Codable {
        let name: String?
    }
}

// MARK: - API Client

final class IMChannelAPIClient {
    static let shared = IMChannelAPIClient()

    private let transport: PhiAgentTransport

    init(transport: PhiAgentTransport = .shared) {
        self.transport = transport
    }

    private var token: String {
        AuthManager.shared.getAccessTokenSyncly() ?? ""
    }

    // MARK: Agent Persona

    func fetchAgentPersona() async throws -> AgentPersonaResponse {
        let response = try await send("/api/v1/agent-persona")
        try validateResponse(response)
        return try JSONDecoder().decode(AgentPersonaResponse.self, from: response.body)
    }

    // MARK: Official Bot

    func prepareTelegram() async throws -> TelegramPrepareResponse {
        AppLogDebug("[IMChannelAPI] POST /api/telegram/prepare — token length: \(token.count)")
        let body = try JSONEncoder().encode([String: String]())
        let response = try await send("/api/telegram/prepare", method: "POST", body: body)
        AppLogDebug("[IMChannelAPI] prepareTelegram response: \(response.statusCode), body: \(String(data: response.body.prefix(500), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(TelegramPrepareResponse.self, from: response.body)
    }

    func getPairingStatus(sessionId: String) async throws -> PairingSession {
        let response = try await send("/api/telegram/pairings/\(sessionId)")
        let bodyPreview = String(data: response.body.prefix(200), encoding: .utf8) ?? "?"
        AppLogDebug("[IMChannelAPI] GET /api/telegram/pairings/\(sessionId) → \(response.statusCode): \(bodyPreview)")
        try validateResponse(response)
        return try JSONDecoder().decode(PairingSession.self, from: response.body)
    }

    func listPairings() async throws -> [ChannelPairing] {
        AppLogDebug("[IMChannelAPI] GET /api/pairings")
        let response = try await send("/api/pairings")
        AppLogDebug("[IMChannelAPI] listPairings response: \(response.statusCode)")
        try validateResponse(response)
        let result = try JSONDecoder().decode(PairingsListResponse.self, from: response.body)
        return result.pairings ?? []
    }

    func disconnectPairing(id: String) async throws {
        let response = try await send("/api/pairings/\(id)", method: "DELETE")
        try validateResponse(response)
    }

    // MARK: Custom Bot

    func listCustomBotChannels() async throws -> CustomBotListResponse {
        AppLogDebug("[IMChannelAPI] GET /api/custom-bot/channels")
        let response = try await send("/api/custom-bot/channels")
        AppLogDebug("[IMChannelAPI] listCustomBotChannels response: \(response.statusCode), body: \(String(data: response.body.prefix(300), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotListResponse.self, from: response.body)
    }

    func createCustomBotChannel(botToken: String, enabled: Bool) async throws -> CustomBotChannel {
        let body = try JSONSerialization.data(withJSONObject: ["botToken": botToken, "enabled": enabled] as [String: Any])
        let response = try await send("/api/custom-bot/channels", method: "POST", body: body)
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: response.body)
    }

    func updateCustomBotChannel(id: String, enabled: Bool? = nil, botToken: String? = nil) async throws -> CustomBotChannel {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var bodyDict: [String: Any] = [:]
        if let enabled { bodyDict["enabled"] = enabled }
        if let botToken { bodyDict["botToken"] = botToken }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        let response = try await send("/api/custom-bot/channels/\(encoded)", method: "PUT", body: body)
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: response.body)
    }

    func verifyBotToken(botToken: String? = nil, channelId: String? = nil) async throws -> (success: Bool, error: String?) {
        var bodyDict: [String: String] = [:]
        if let botToken { bodyDict["botToken"] = botToken }
        if let channelId { bodyDict["channelId"] = channelId }
        let body = try JSONSerialization.data(withJSONObject: bodyDict)
        AppLogDebug("[IMChannelAPI] POST /api/custom-bot/verify")
        let response = try await send("/api/custom-bot/verify", method: "POST", body: body)
        AppLogDebug("[IMChannelAPI] verify response: \(response.statusCode)")
        try validateResponse(response)
        struct VerifyResult: Codable { let success: Bool; let error: String? }
        let result = try JSONDecoder().decode(VerifyResult.self, from: response.body)
        return (result.success, result.error)
    }

    func deleteCustomBotChannel(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let response = try await send("/api/custom-bot/channels/\(encoded)", method: "DELETE")
        try validateResponse(response)
    }

    // MARK: Helpers

    /// Sends one authorized phi-agent request over the route Sentinel currently
    /// prescribes. `PhiAgentTransport` owns route resolution, the loopback and
    /// broker transports, and the single retry after a re-resolve.
    private func send(
        _ path: String,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> PhiAgentHTTPResponse {
        try await transport.send(PhiAgentHTTPRequest(
            path: path,
            method: method,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
            ],
            body: body
        ))
    }

    private func validateResponse(_ response: PhiAgentHTTPResponse) throws {
        if response.statusCode == 401 {
            throw IMChannelAPIError.unauthorized
        }
        guard (200...299).contains(response.statusCode) else {
            throw IMChannelAPIError.httpError(statusCode: response.statusCode)
        }
    }
}

enum IMChannelAPIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from phi-agent"
        case .unauthorized: return "Phi session expired"
        case .httpError(let code): return "phi-agent returned HTTP \(code)"
        }
    }
}
