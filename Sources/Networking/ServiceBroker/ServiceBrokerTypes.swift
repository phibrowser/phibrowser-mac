// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Security

enum BrokerService: String, Codable, Sendable {
    case phiAgent = "phi-agent"
    case phiMemory = "phi-memory"
    case piAgent = "pi-agent"
    case aiGateway = "ai-gateway"
    case broker
}

struct BrokerSenderContext: Equatable, Sendable {
    let extensionID: String
    let profileID: String?
    let accountID: String?
    let authRevisionID: UUID?

    init(
        extensionID: String,
        profileID: String?,
        accountID: String?,
        authRevisionID: UUID? = nil
    ) {
        self.extensionID = extensionID
        self.profileID = profileID
        self.accountID = accountID
        self.authRevisionID = authRevisionID
    }
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
    let headers: [BrokerHTTPHeader]
    let body: Data
}

struct BrokerHTTPHeader: Equatable, Sendable {
    let name: String
    let value: String
}

struct BrokerHTTPResponseHead: Sendable {
    let statusCode: Int
    let headers: [BrokerHTTPHeader]
}

enum ServiceBrokerHTTPError: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case connectionClosed
    case cancelled
    case peerAuthentication
    case timedOut
}

struct ServiceBrokerDeadline: Sendable {
    /// A budget that never expires. Poll slices stay bounded by
    /// `pollTimeoutMilliseconds(maximumSlice:)`, so callers still observe
    /// cancellation promptly; only the timeout itself is removed.
    static let never = ServiceBrokerDeadline(expirationNanoseconds: .max)

    private let expirationNanoseconds: UInt64

    init(timeoutMilliseconds: Int) {
        let milliseconds = UInt64(max(1, timeoutMilliseconds))
        let (duration, durationOverflow) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (expiration, expirationOverflow) = now.addingReportingOverflow(duration)
        expirationNanoseconds = durationOverflow || expirationOverflow ? UInt64.max : expiration
    }

    private init(expirationNanoseconds: UInt64) {
        self.expirationNanoseconds = expirationNanoseconds
    }

    func pollTimeoutMilliseconds(maximumSlice: Int32 = 100) -> Int32? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < expirationNanoseconds else { return nil }
        let remainingNanoseconds = expirationNanoseconds - now
        let wholeMilliseconds = remainingNanoseconds / 1_000_000
        let partialMillisecond = remainingNanoseconds % 1_000_000 == 0 ? 0 : 1
        let remainingMilliseconds = max(1, wholeMilliseconds + UInt64(partialMillisecond))
        return Int32(min(UInt64(maximumSlice), remainingMilliseconds))
    }
}

struct ServiceBrokerPeerAuthenticator: Sendable {
    private let authenticatePeer: @Sendable (Int32) throws -> Void

    init(_ authenticate: @escaping @Sendable (Int32) throws -> Void) {
        authenticatePeer = authenticate
    }

    func authenticate(fileDescriptor: Int32) throws {
        try authenticatePeer(fileDescriptor)
    }

    static let production = ServiceBrokerPeerAuthenticator { descriptor in
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == geteuid(),
              let pidBefore = peerProcessID(descriptor) else {
            throw ServiceBrokerHTTPError.peerAuthentication
        }

        let requirementText = "anchor apple generic and identifier \"service-broker\""
            + " and certificate leaf[subject.OU] = \"87DQ3HMK5G\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw ServiceBrokerHTTPError.peerAuthentication
        }

        let attributes = [kSecGuestAttributePid: pidBefore] as CFDictionary
        var code: SecCode?
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess,
              peerProcessID(descriptor) == pidBefore else {
            throw ServiceBrokerHTTPError.peerAuthentication
        }
    }

    private static func peerProcessID(_ descriptor: Int32) -> pid_t? {
        var pid: pid_t = -1
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              pid > 0 else {
            return nil
        }
        return pid
    }
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
    /// Reachable for HTTP stream channels only. A WebSocket channel that fills
    /// its queue pauses its upstream read loop instead of failing, so this code
    /// is never produced for `broker.ws.pull`. It stays part of the stable
    /// extension error set.
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
    let headers: [BrokerHTTPHeader]
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
    case frame(sequence: UInt64, BrokerWebSocketFrame)
    case close(code: UInt16?, reason: String?)
    case timeout
    case failure(code: NativeBrokerErrorCode, message: String)
}

struct BrokerWebSocketOpenResponse: Equatable, Sendable {
    let channelID: String
}

struct BrokerWebSocketPullResponse: Equatable, Sendable {
    /// The events one pull drained, in queue order and with contiguous frame
    /// sequences. Never empty, and a terminal event is always the last element.
    let events: [BrokerWebSocketEvent]

    init(events: [BrokerWebSocketEvent]) {
        self.events = events
    }

    init(event: BrokerWebSocketEvent) {
        events = [event]
    }
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
