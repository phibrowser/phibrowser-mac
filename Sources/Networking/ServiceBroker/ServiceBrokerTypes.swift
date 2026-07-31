// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

enum BrokerService: String, Codable, Sendable {
    case phiAgent = "phi-agent"
}

struct BrokerSenderContext: Equatable, Sendable {
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

enum NativeBrokerErrorCode: String, Codable, Equatable, Sendable {
    case channelNotFound = "channel_not_found"
    case ownerMismatch = "owner_mismatch"
    case pullAlreadyPending = "pull_already_pending"
    case flowControlTimeout = "flow_control_timeout"
    case upstreamError = "upstream_error"
    case protocolError = "protocol_error"
}

enum BrokerChannelError: Error, Equatable, Sendable {
    case channelNotFound
    case ownerMismatch
    case pullAlreadyPending
    case invalidChannelKind
    case invalidConfiguration
}

enum BrokerPullEvent: Equatable, Sendable {
    case data(sequence: UInt64, data: Data)
    case end
    case timeout
    case failure(code: NativeBrokerErrorCode, message: String)
}

struct BrokerStreamOpenResponse: Equatable, Sendable {
    let channelID: String
    let statusCode: Int
    let headers: [String: String]
}

struct BrokerStreamPullResponse: Equatable, Sendable {
    let event: BrokerPullEvent
}

struct BrokerWebSocketFrame: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case binary
    }

    let kind: Kind
    let data: Data
}

enum BrokerWebSocketEvent: Equatable, Sendable {
    case frame(BrokerWebSocketFrame)
    case close(code: UInt16?, reason: String?)
    case timeout
    case failure(code: NativeBrokerErrorCode, message: String)
}

struct BrokerWebSocketOpenResponse: Equatable, Sendable {
    let channelID: String
}

struct BrokerWebSocketPullResponse: Equatable, Sendable {
    let event: BrokerWebSocketEvent
}

struct ServiceBrokerChannelConfiguration: Equatable, Sendable {
    let bridgeChunkBytes: Int
    let webSocketMessageBytes: Int
    let unacknowledgedWindowBytes: Int
    let pullTimeout: Duration
    let idleTimeout: Duration

    static let `default` = ServiceBrokerChannelConfiguration(
        bridgeChunkBytes: 256 * 1024,
        webSocketMessageBytes: 16 * 1024 * 1024,
        unacknowledgedWindowBytes: 1024 * 1024,
        pullTimeout: .seconds(25),
        idleTimeout: .seconds(60)
    )

    init(
        bridgeChunkBytes: Int,
        webSocketMessageBytes: Int,
        unacknowledgedWindowBytes: Int,
        pullTimeout: Duration,
        idleTimeout: Duration
    ) {
        self.bridgeChunkBytes = bridgeChunkBytes
        self.webSocketMessageBytes = webSocketMessageBytes
        self.unacknowledgedWindowBytes = unacknowledgedWindowBytes
        self.pullTimeout = pullTimeout
        self.idleTimeout = idleTimeout
    }

    init(limits: ServiceBrokerLimits, pullTimeout: Duration = .seconds(25), idleTimeout: Duration = .seconds(60)) {
        self.init(
            bridgeChunkBytes: limits.bridgeChunkBytes,
            webSocketMessageBytes: limits.webSocketMessageBytes,
            unacknowledgedWindowBytes: limits.unacknowledgedWindowBytes,
            pullTimeout: pullTimeout,
            idleTimeout: idleTimeout
        )
    }
}

struct BrokerHTTPStreamSource: Sendable {
    let response: BrokerHTTPResponseHead

    private let readBody: @Sendable (Int) async throws -> Data?
    private let cancelBody: @Sendable () -> Void

    init(
        response: BrokerHTTPResponseHead,
        read: @escaping @Sendable (Int) async throws -> Data?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.response = response
        readBody = read
        cancelBody = cancel
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await readBody(maxBytes)
    }

    func cancel() {
        cancelBody()
    }
}

struct BrokerWebSocketSource: Sendable {
    private let sendFrame: @Sendable (BrokerWebSocketFrame) async throws -> Void
    private let receiveEvent: @Sendable () async throws -> BrokerWebSocketEvent
    private let closeSocket: @Sendable (UInt16?, String?) async -> Void

    init(
        send: @escaping @Sendable (BrokerWebSocketFrame) async throws -> Void,
        receive: @escaping @Sendable () async throws -> BrokerWebSocketEvent,
        close: @escaping @Sendable (UInt16?, String?) async -> Void
    ) {
        sendFrame = send
        receiveEvent = receive
        closeSocket = close
    }

    func send(_ frame: BrokerWebSocketFrame) async throws {
        try await sendFrame(frame)
    }

    func receive() async throws -> BrokerWebSocketEvent {
        try await receiveEvent()
    }

    func close(code: UInt16?, reason: String?) async {
        await closeSocket(code, reason)
    }
}
