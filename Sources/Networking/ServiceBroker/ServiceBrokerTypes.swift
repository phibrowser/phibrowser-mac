// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum BrokerService: String, Codable, Sendable {
    case phiAgent = "phi-agent"
}

struct BrokerSenderContext: Sendable {
    let extensionID: String
    let profileID: String?
    let accountID: String?
}

struct BrokerHTTPRequest: Sendable {
    let service: BrokerService
    let path: String
    let method: String
    let headers: [String: String]
    let body: Data?

    init(
        service: BrokerService,
        path: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.service = service
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
    }
}

struct BrokerHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

struct BrokerHTTPResponseHead: Sendable {
    let statusCode: Int
    let headers: [String: String]
}

enum ServiceBrokerHTTPError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case connectionClosed
    case cancelled
}

struct ServiceBrokerLimits: Codable, Equatable, Sendable {
    let bridgeChunkBytes: Int
    let jsonRequestBytes: Int
    let nonStreamingResponseBytes: Int
    let webSocketMessageBytes: Int
    let unacknowledgedWindowBytes: Int
    let stagedFileBytes: Int
    let stagedAccountBytes: Int

    enum CodingKeys: String, CodingKey {
        case bridgeChunkBytes = "bridge_chunk_bytes"
        case jsonRequestBytes = "json_request_bytes"
        case nonStreamingResponseBytes = "non_streaming_response_bytes"
        case webSocketMessageBytes = "websocket_message_bytes"
        case unacknowledgedWindowBytes = "unacknowledged_window_bytes"
        case stagedFileBytes = "staged_file_bytes"
        case stagedAccountBytes = "staged_account_bytes"
    }
}

struct ServiceBrokerVersionResponse: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let features: [String]
    let limits: ServiceBrokerLimits

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case features
        case limits
    }
}

enum ServiceBrokerErrorCode: String, Codable, Sendable {
    case protocolUnsupported = "E_BROKER_PROTOCOL_UNSUPPORTED"
    case peerAuthentication = "E_BROKER_PEER_AUTHENTICATION"
    case invalidRequest = "E_BROKER_INVALID_REQUEST"
    case pathRejected = "E_BROKER_PATH_REJECTED"
    case unauthorized = "E_BROKER_UNAUTHORIZED"
    case serviceUnavailable = "E_BROKER_SERVICE_UNAVAILABLE"
    case requestTooLarge = "E_BROKER_REQUEST_TOO_LARGE"
    case responseTooLarge = "E_BROKER_RESPONSE_TOO_LARGE"
    case flowControlTimeout = "E_BROKER_FLOW_CONTROL_TIMEOUT"
    case stagingRejected = "E_BROKER_STAGING_REJECTED"
    case upstreamProtocol = "E_BROKER_UPSTREAM_PROTOCOL"
}

struct ServiceBrokerErrorPayload: Codable, Error, Sendable {
    let code: ServiceBrokerErrorCode
    let message: String
    let retry: Bool?
}

enum ServiceBrokerCompatibility: Equatable, Sendable {
    case broker
    case protocolUnsupported
}

enum ServiceBrokerNegotiation {
    static let protocolVersion = 1

    static func evaluate(protocolVersion: Int) -> ServiceBrokerCompatibility {
        protocolVersion == self.protocolVersion ? .broker : .protocolUnsupported
    }
}

enum ServiceBrokerFallbackReason: Sendable {
    case brokerUnavailable
    case protocolUnsupported
    case signedCompatibilityConfig
    case authorizationDenied
    case invalidRequest
    case sizeLimitExceeded

    var allowsLoopback: Bool {
        switch self {
        case .brokerUnavailable, .protocolUnsupported, .signedCompatibilityConfig:
            true
        case .authorizationDenied, .invalidRequest, .sizeLimitExceeded:
            false
        }
    }
}
