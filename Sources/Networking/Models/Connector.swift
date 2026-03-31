// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

// MARK: - OAuth Connection Models

struct OAuthConnection: Codable {
    let provider: String
    let connected: Bool
    let connectedAt: String?
    let expiresAt: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case provider, connected, scope
        case connectedAt = "connected_at"
        case expiresAt = "expires_at"
    }
}

struct GetOAuthConnectionsResponse: Codable {
    let connections: [OAuthConnection]
}

struct DeleteOAuthTokenResponse: Codable {
    let message: String
}

// MARK: - Request Models

struct CreateUserSourceRequest: Codable {
    let sourceType: String
    let configuration: [String: String]
}

struct GetConsentUrlRequest: Codable {
    let sourceType: String
    let redirectUrl: String?
}

struct GetConsentUrlResponse: Codable {
    let consentUrl: String
}

struct CompleteOAuthRequest: Codable {
    let sourceType: String
    let redirectUrl: String
    private var additionalProperties: [String: String] = [:]
    
    init(sourceType: String, redirectUrl: String, additionalProperties: [String: String] = [:]) {
        self.sourceType = sourceType
        self.redirectUrl = redirectUrl
        self.additionalProperties = additionalProperties
    }
    
    enum CodingKeys: String, CodingKey {
        case sourceType
        case redirectUrl
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKeys.self)
        try container.encode(sourceType, forKey: DynamicCodingKeys(stringValue: "sourceType")!)
        try container.encode(redirectUrl, forKey: DynamicCodingKeys(stringValue: "redirectUrl")!)
        
        // Encode additional properties
        for (key, value) in additionalProperties {
            if let codingKey = DynamicCodingKeys(stringValue: key) {
                try container.encode(value, forKey: codingKey)
            }
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        sourceType = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: "sourceType")!)
        redirectUrl = try container.decode(String.self, forKey: DynamicCodingKeys(stringValue: "redirectUrl")!)
        
        // Decode any additional properties
        additionalProperties = [:]
        for key in container.allKeys {
            if key.stringValue != "sourceType" && key.stringValue != "redirectUrl" {
                if let value = try? container.decode(String.self, forKey: key) {
                    additionalProperties[key.stringValue] = value
                }
            }
        }
    }
}

struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct CompleteOAuthResponse: Codable {
    let authPayload: OAuthPayload
    
    enum CodingKeys: String, CodingKey {
        case authPayload = "auth_payload"
    }
}

struct OAuthPayload: Codable {
    let clientId: String
    let clientSecret: String
    let refreshToken: String
    let accessToken: String?
    
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientSecret = "client_secret"
        case refreshToken = "refresh_token"
        case accessToken = "access_token"
    }
}

struct CreateConnectionRequest: Codable {
    let sourceType: String
}

struct DeleteConnectionRequest: Codable {
    let sourceType: String
}
