// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct AgentAvatarResponse: Codable {
    enum Source: String, Codable {
        case `default`
        case custom
    }

    let url: String
    let source: Source
    let mimeType: String
    let filename: String
    let updatedAt: String?
}

struct AgentAvatarImagePayload {
    let metadata: AgentAvatarResponse
    let data: Data
}

class APIClient {
    static let shared = APIClient()
    #if DEBUG
    private var accountBaseURL: String {
        if AuthManager.useStagingAuth0 {
            return "https://account.stag.phibrowser.com"
        } else {
            return "https://account.phibrowser.com"
        }
    }
    private var connectorBaseURL: String {
        if AuthManager.useStagingAuth0 {
            return "https://ai.stag.phibrowser.com/data"
        } else {
            return "https://ai.phibrowser.com/data"
        }
    }
    #elseif NIGHTLY_BUILD
    private let accountBaseURL = "https://account.stag.phibrowser.com"
    private let connectorBaseURL = "https://ai.stag.phibrowser.com/data"
    #else
    private let accountBaseURL = "https://account.phibrowser.com"
    private let connectorBaseURL = "https://ai.phibrowser.com/data"
    #endif
    private let agentBaseURL = "http://127.0.0.1:8788"

    private var token: String {
        let accessToken = AuthManager.shared.getAccessTokenSyncly()

        if accessToken == nil {
            AppLogError("Failed to get Auth0 token")
        }

        return accessToken ?? ""
    }

    func getAccountProfile() async throws -> Response<Profile> {
        let url = URL(string: "\(accountBaseURL)/api/auth/profile")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<Profile>.self, from: data)
    }

    func updateProfile(updates: UpdateProfileRequest) async throws -> Response<UpdateProfileResponse> {
        let url = URL(string: "\(accountBaseURL)/api/auth/profile")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(updates)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<UpdateProfileResponse>.self, from: data)
    }

    // MARK: - Agent Persona

    func getAgentAvatar() async throws -> AgentAvatarResponse {
        let url = URL(string: "\(agentBaseURL)/api/v1/agent-persona/avatar")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(AgentAvatarResponse.self, from: data)
    }

    func getAgentAvatarImageData() async throws -> AgentAvatarImagePayload {
        let avatar = try await getAgentAvatar()

        if let data = Self.decodeAgentAvatarDataURL(avatar.url) {
            return AgentAvatarImagePayload(metadata: avatar, data: data)
        }

        guard let url = URL(string: avatar.url) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return AgentAvatarImagePayload(metadata: avatar, data: data)
    }

    static func decodeAgentAvatarDataURL(_ url: String) -> Data? {
        guard url.hasPrefix("data:"),
              let commaIndex = url.firstIndex(of: ",") else {
            return nil
        }

        let header = url[..<commaIndex]
        let payload = String(url[url.index(after: commaIndex)...])

        if header.localizedCaseInsensitiveContains(";base64") {
            return Data(base64Encoded: payload)
        }

        guard let decodedPayload = payload.removingPercentEncoding else {
            return nil
        }

        return decodedPayload.data(using: .utf8)
    }
    
    // MARK: - Invitation APIs
    
    /// Get user's activation information and invitation details
    func getActivationInfo() async throws -> Response<ActivationInfo> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-details")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<ActivationInfo>.self, from: data)
    }
    
    /// Get user's invitation quota information
    func getInviteQuota() async throws -> Response<InviteQuota> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invite-quota")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InviteQuota>.self, from: data)
    }

    /// Get user's invitation codes
    func getInvitationCodes() async throws -> Response<[InvitationCode]> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-codes")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<[InvitationCode]>.self, from: data)
    }
    
    /// Create a new invitation code
    func createInvitationCode(request: CreateInvitationCodeRequest) async throws -> Response<InvitationCode> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-codes")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }
    
    /// Get details of a specific invitation code
    func getInvitationCodeById(codeId: Int) async throws -> Response<InvitationCode> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-codes/\(codeId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }
    
    /// Deactivate an invitation code
    func deactivateInvitationCode(codeId: Int) async throws -> Response<String> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-codes/\(codeId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(Response<String>.self, from: data)
    }
    
    /// Get or create default invitation code
    func getDefaultInvitationCode() async throws -> Response<InvitationCode> {
        let url = URL(string: "\(accountBaseURL)/api/auth/invitation-codes/default")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<InvitationCode>.self, from: data)
    }

    /// Validate an invitation code during account activation
    func validateInvite(request: InviteValidationRequest) async throws -> Response<InviteValidationResponse> {
        let url = URL(string: "\(accountBaseURL)/api/invite/validate")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(request.sessionToken, forHTTPHeaderField: "X-Session-Token")

        let encoder = JSONEncoder()
        let jsonBody = ["invite_code": request.inviteCode]
        urlRequest.httpBody = try encoder.encode(jsonBody)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<InviteValidationResponse>.self, from: data)
    }
    
    // MARK: - Connector APIs

    func getOAuthConnections() async throws -> Response<GetOAuthConnectionsResponse> {
        let url = URL(string: "\(accountBaseURL)/api/auth/oauth/connections")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<GetOAuthConnectionsResponse>.self, from: data)
    }
    
    /// Create or update a user source
    func createUserSource(request: CreateUserSourceRequest) async throws -> AirbyteResponse<String> {
        let url = URL(string: "\(connectorBaseURL)/create-or-update-source")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<String>.self, from: data)
    }
    
    /// Get OAuth consent URL for a connector
    func getConsentUrl(request: GetConsentUrlRequest) async throws -> AirbyteResponse<GetConsentUrlResponse> {
        let url = URL(string: "\(connectorBaseURL)/oauth/consent-url")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<GetConsentUrlResponse>.self, from: data)
    }
    
    /// Complete OAuth flow for a connector
    func completeOAuth(request: CompleteOAuthRequest) async throws -> AirbyteResponse<CompleteOAuthResponse> {
        let url = URL(string: "\(connectorBaseURL)/oauth/complete-oauth")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<CompleteOAuthResponse>.self, from: data)
    }
    
    /// Create a connection for a source
    func createConnection(request: CreateConnectionRequest) async throws -> AirbyteResponse<String> {
        let url = URL(string: "\(connectorBaseURL)/create-connection")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try JSONDecoder().decode(AirbyteResponse<String>.self, from: data)
    }
    
    func deleteOAuthToken(provider: String) async throws -> Response<DeleteOAuthTokenResponse> {
        let url = URL(string: "\(accountBaseURL)/api/auth/oauth/tokens/\(provider)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "DELETE"
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(Response<DeleteOAuthTokenResponse>.self, from: data)
    }
}

enum APIError: Error {
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError
}
