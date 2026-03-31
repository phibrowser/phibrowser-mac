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

    private let baseURL = "http://127.0.0.1:8788"

    private var token: String {
        AuthManager.shared.getAccessTokenSyncly() ?? ""
    }

    private func authorizedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: Agent Persona

    func fetchAgentPersona() async throws -> AgentPersonaResponse {
        let url = URL(string: "\(baseURL)/api/v1/agent-persona")!
        let request = authorizedRequest(url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(AgentPersonaResponse.self, from: data)
    }

    // MARK: Official Bot

    func prepareTelegram() async throws -> TelegramPrepareResponse {
        let url = URL(string: "\(baseURL)/api/telegram/prepare")!
        var request = authorizedRequest(url, method: "POST")
        request.httpBody = try JSONEncoder().encode([String: String]())
        AppLogDebug("[IMChannelAPI] POST /api/telegram/prepare — token length: \(token.count)")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] prepareTelegram response: \(statusCode), body: \(String(data: data.prefix(500), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(TelegramPrepareResponse.self, from: data)
    }

    func getPairingStatus(sessionId: String) async throws -> PairingSession {
        let url = URL(string: "\(baseURL)/api/telegram/pairings/\(sessionId)")!
        let request = authorizedRequest(url)
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyPreview = String(data: data.prefix(200), encoding: .utf8) ?? "?"
        AppLogDebug("[IMChannelAPI] GET /api/telegram/pairings/\(sessionId) → \(statusCode): \(bodyPreview)")
        try validateResponse(response)
        return try JSONDecoder().decode(PairingSession.self, from: data)
    }

    func listPairings() async throws -> [ChannelPairing] {
        let url = URL(string: "\(baseURL)/api/pairings")!
        let request = authorizedRequest(url)
        AppLogDebug("[IMChannelAPI] GET /api/pairings")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] listPairings response: \(statusCode)")
        try validateResponse(response)
        let result = try JSONDecoder().decode(PairingsListResponse.self, from: data)
        return result.pairings ?? []
    }

    func disconnectPairing(id: String) async throws {
        let url = URL(string: "\(baseURL)/api/pairings/\(id)")!
        let request = authorizedRequest(url, method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: Custom Bot

    func listCustomBotChannels() async throws -> CustomBotListResponse {
        let url = URL(string: "\(baseURL)/api/custom-bot/channels")!
        let request = authorizedRequest(url)
        AppLogDebug("[IMChannelAPI] GET /api/custom-bot/channels")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] listCustomBotChannels response: \(statusCode), body: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotListResponse.self, from: data)
    }

    func createCustomBotChannel(botToken: String, enabled: Bool) async throws -> CustomBotChannel {
        let url = URL(string: "\(baseURL)/api/custom-bot/channels")!
        var request = authorizedRequest(url, method: "POST")
        let body: [String: Any] = ["botToken": botToken, "enabled": enabled]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: data)
    }

    func updateCustomBotChannel(id: String, enabled: Bool? = nil, botToken: String? = nil) async throws -> CustomBotChannel {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "\(baseURL)/api/custom-bot/channels/\(encoded)")!
        var request = authorizedRequest(url, method: "PUT")
        var body: [String: Any] = [:]
        if let enabled { body["enabled"] = enabled }
        if let botToken { body["botToken"] = botToken }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode(CustomBotChannel.self, from: data)
    }

    func verifyBotToken(botToken: String? = nil, channelId: String? = nil) async throws -> (success: Bool, error: String?) {
        let url = URL(string: "\(baseURL)/api/custom-bot/verify")!
        var request = authorizedRequest(url, method: "POST")
        var body: [String: String] = [:]
        if let botToken { body["botToken"] = botToken }
        if let channelId { body["channelId"] = channelId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogDebug("[IMChannelAPI] POST /api/custom-bot/verify")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        AppLogDebug("[IMChannelAPI] verify response: \(statusCode)")
        try validateResponse(response)
        struct VerifyResult: Codable { let success: Bool; let error: String? }
        let result = try JSONDecoder().decode(VerifyResult.self, from: data)
        return (result.success, result.error)
    }

    func deleteCustomBotChannel(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "\(baseURL)/api/custom-bot/channels/\(encoded)")!
        let request = authorizedRequest(url, method: "DELETE")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: Helpers

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw IMChannelAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw IMChannelAPIError.httpError(statusCode: http.statusCode)
        }
    }
}

enum IMChannelAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from phi-agent"
        case .httpError(let code): return "phi-agent returned HTTP \(code)"
        }
    }
}
