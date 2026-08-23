// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

struct ServiceBrokerExtensionReply: Sendable {
    struct Failure: Equatable, Sendable {
        let code: String
        let message: String
    }

    let json: String
    let error: Failure?
}

actor ServiceBrokerExtensionProtocol {
    static let allowedCanarySidecarExtensionID = "fenmfiepnpdlhplemgijlimpbebebljo"
    static let allowedCanaryLexingtonExtensionID = "pjgdkljlcbjgedgeppodjijjphfcplno"
    static let allowedCanaryKensingtonExtensionID = "pjlnhbfabokjejbhmgghmjiaknfhnima"
    private static let allowedCanaryBrokerExtensionIDs = Set([
        allowedCanarySidecarExtensionID,
        allowedCanaryLexingtonExtensionID,
        allowedCanaryKensingtonExtensionID,
    ])
    static let messageTypes = [
        "broker.capabilities",
        "broker.http.request",
        "broker.stream.open",
        "broker.stream.pull",
        "broker.stream.cancel",
        "broker.ws.open",
        "broker.ws.send",
        "broker.ws.pull",
        "broker.ws.close",
    ]
    static let shared = ServiceBrokerExtensionProtocol()

    typealias RequestExecutor = @Sendable (BrokerHTTPRequest) async throws -> BrokerHTTPResponse

    private struct Runtime: Sendable {
        let accountID: String?
        let socketPath: String?
        let limits: ServiceBrokerLimits
        let channelStore: ServiceBrokerChannelStore
        let requestExecutor: RequestExecutor
    }

    private enum FailureCode: String {
        case unauthorizedSender = "unauthorized_sender"
        case unsupportedMessage = "unsupported_message"
        case invalidPayload = "invalid_payload"
        case invalidPath = "invalid_path"
        case unsupportedMethod = "unsupported_method"
        case invalidBase64 = "invalid_base64"
        case requestTooLarge = "request_too_large"
        case responseTooLarge = "response_too_large"
        case channelNotFound = "channel_not_found"
        case ownerMismatch = "owner_mismatch"
        case pullAlreadyPending = "pull_already_pending"
        case flowControlTimeout = "flow_control_timeout"
        case upstreamError = "upstream_error"
        case protocolError = "protocol_error"
    }

    private struct ProtocolFailure: Error {
        let code: FailureCode
        let message: String
    }

    private struct HTTPPayload: Decodable {
        let path: String
        let method: String?
        let headers: [String: String]?
        let bodyBase64: String?
    }

    private struct CapabilitiesPayload: Decodable {}

    private struct ChannelPayload: Decodable {
        let channelId: String
    }

    private struct WebSocketOpenPayload: Decodable {
        let path: String
        let headers: [String: String]?
    }

    private struct WebSocketSendPayload: Decodable {
        let channelId: String
        let kind: BrokerWebSocketFrame.Kind
        let data: String
    }

    private struct WebSocketClosePayload: Decodable {
        let channelId: String
        let code: UInt16?
        let reason: String?
    }

    private struct RoutedServicePath {
        let service: BrokerService
        let path: String
    }

    private static let defaultLimits = ServiceBrokerLimits(
        bridgeChunkBytes: 512 * 1024,
        jsonRequestBytes: 16 * 1024 * 1024,
        nonStreamingResponseBytes: 64 * 1024 * 1024,
        webSocketMessageBytes: 16 * 1024 * 1024,
        unacknowledgedWindowBytes: 2 * 1024 * 1024,
        stagedFileBytes: 100 * 1024 * 1024,
        stagedAccountBytes: 500 * 1024 * 1024
    )
    private static let javascriptMaximumSafeInteger = UInt64(9_007_199_254_740_991)
    private static let supportedMethods = Set(["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
    private static let brokerExtensionHeader = "X-Phi-Extension-ID"
    private static let maximumEnvelopeMetadataBytes = 64 * 1024

    private let injectedRuntime: Runtime?
    private let socketPathProvider: @Sendable (String) throws -> String
    private let authSnapshotProvider: @Sendable () -> SharedAuthTokenSnapshot?
    private var productionRuntime: Runtime?

    private init() {
        injectedRuntime = nil
        socketPathProvider = Self.currentSocketPath
        authSnapshotProvider = { SharedAuthTokenStore.shared.authenticatedSnapshot() }
    }

    init(
        limits: ServiceBrokerLimits,
        channelStore: ServiceBrokerChannelStore,
        runtimeAccountID: String? = nil,
        requestExecutor: @escaping RequestExecutor,
        authSnapshotProvider: @escaping @Sendable () -> SharedAuthTokenSnapshot? = {
            SharedAuthTokenStore.shared.authenticatedSnapshot()
        }
    ) {
        injectedRuntime = Runtime(
            accountID: runtimeAccountID,
            socketPath: nil,
            limits: limits,
            channelStore: channelStore,
            requestExecutor: requestExecutor
        )
        socketPathProvider = { _ in throw ProtocolFailure(
            code: .upstreamError,
            message: "The service broker socket is unavailable."
        ) }
        self.authSnapshotProvider = authSnapshotProvider
    }

    static func isAllowedSidecarSender(_ senderID: String) -> Bool {
        senderID == allowedCanarySidecarExtensionID
    }

    static func isAllowedBrokerSender(_ senderID: String) -> Bool {
        allowedCanaryBrokerExtensionIDs.contains(senderID)
    }

    func handle(_ context: ExtensionMessageContext) async -> String {
        await handle(type: context.type, payload: context.payload, senderID: context.senderId).json
    }

    func handle(type: String, payload: String, senderID: String) async -> ServiceBrokerExtensionReply {
        guard Self.isAllowedBrokerSender(senderID) else {
            return failure(.unauthorizedSender, "The extension sender is not authorized.")
        }
        guard Self.messageTypes.contains(type) else {
            return failure(.unsupportedMessage, "The broker message type is not supported.")
        }
        if type == "broker.capabilities" {
            do {
                guard payload.lengthOfBytes(using: .utf8) <= Self.maximumEnvelopeMetadataBytes else {
                    throw ProtocolFailure(code: .requestTooLarge, message: "The broker request is too large.")
                }
                _ = try decode(CapabilitiesPayload.self, payload: payload, allowedKeys: [])
                return try success(["protocolVersion": 1])
            } catch let error as ProtocolFailure {
                return failure(error.code, error.message)
            } catch {
                return failure(.protocolError, "The broker capability response could not be encoded.")
            }
        }

        do {
            let authSnapshot = try requireAuthenticatedSnapshot()
            let runtime = try await resolveRuntime(expectedAccountID: authSnapshot.scope.accountID)
            try requireUnchangedAuth(authSnapshot)
            guard payload.lengthOfBytes(using: .utf8) <= Self.envelopeLimit(
                for: type,
                limits: runtime.limits
            ) else {
                throw ProtocolFailure(code: .requestTooLarge, message: "The broker request is too large.")
            }
            let owner = BrokerSenderContext(
                extensionID: senderID,
                profileID: nil,
                accountID: authSnapshot.scope.accountID,
                authRevisionID: authSnapshot.scope.revisionID
            )
            switch type {
            case "broker.http.request":
                let request = try decodeHTTPRequest(
                    payload,
                    limits: runtime.limits,
                    allowsBrokerHealth: true,
                    senderID: senderID
                )
                let response = try await runtime.requestExecutor(request)
                try requireUnchangedAuth(authSnapshot)
                guard response.body.count <= runtime.limits.nonStreamingResponseBytes else {
                    throw ProtocolFailure(code: .responseTooLarge, message: "The broker response is too large.")
                }
                return try success([
                    "status": response.statusCode,
                    "headers": headerPairs(response.headers),
                    "bodyBase64": response.body.base64EncodedString(),
                ])

            case "broker.stream.open":
                let request = try decodeHTTPRequest(
                    payload,
                    limits: runtime.limits,
                    senderID: senderID
                )
                let opened = try await runtime.channelStore.openHTTPStream(owner: owner, request: request)
                do {
                    try requireUnchangedAuth(authSnapshot)
                } catch {
                    try? await runtime.channelStore.cancelHTTP(owner: owner, channelID: opened.channelID)
                    throw error
                }
                return try success([
                    "channelId": opened.channelID,
                    "status": opened.statusCode,
                    "headers": headerPairs(opened.headers),
                ])

            case "broker.stream.pull":
                let request = try decode(
                    ChannelPayload.self,
                    payload: payload,
                    allowedKeys: ["channelId"]
                )
                try validateChannelID(request.channelId)
                let pulled = try await runtime.channelStore.pullHTTP(owner: owner, channelID: request.channelId)
                do {
                    try requireUnchangedAuth(authSnapshot)
                } catch {
                    try? await runtime.channelStore.cancelHTTP(owner: owner, channelID: request.channelId)
                    throw error
                }
                return try encode(pulled.event)

            case "broker.stream.cancel":
                let request = try decode(
                    ChannelPayload.self,
                    payload: payload,
                    allowedKeys: ["channelId"]
                )
                try validateChannelID(request.channelId)
                try await runtime.channelStore.cancelHTTP(owner: owner, channelID: request.channelId)
                try requireUnchangedAuth(authSnapshot)
                return try success(["cancelled": true])

            case "broker.ws.open":
                let request = try decode(
                    WebSocketOpenPayload.self,
                    payload: payload,
                    allowedKeys: ["path", "headers"]
                )
                let routed = try routedServicePath(from: request.path, senderID: senderID)
                let headers = try authorizedHeaders(request.headers ?? [:], senderID: senderID)
                let opened = try await runtime.channelStore.openWebSocket(
                    owner: owner,
                    service: routed.service,
                    path: routed.path,
                    headers: headers
                )
                do {
                    try requireUnchangedAuth(authSnapshot)
                } catch {
                    try? await runtime.channelStore.closeWebSocket(
                        owner: owner,
                        channelID: opened.channelID,
                        code: 1008,
                        reason: nil
                    )
                    throw error
                }
                return try success(["channelId": opened.channelID])

            case "broker.ws.send":
                let request = try decode(
                    WebSocketSendPayload.self,
                    payload: payload,
                    allowedKeys: ["channelId", "kind", "data"]
                )
                try validateEnvelopeMetadata(payload, base64Value: request.data)
                try validateChannelID(request.channelId)
                let data = try decodeBase64(request.data)
                guard data.count <= runtime.limits.webSocketMessageBytes else {
                    throw ProtocolFailure(code: .requestTooLarge, message: "The WebSocket message is too large.")
                }
                try await runtime.channelStore.sendWebSocket(
                    owner: owner,
                    channelID: request.channelId,
                    frame: BrokerWebSocketFrame(kind: request.kind, data: data)
                )
                do {
                    try requireUnchangedAuth(authSnapshot)
                } catch {
                    try? await runtime.channelStore.closeWebSocket(
                        owner: owner,
                        channelID: request.channelId,
                        code: 1008,
                        reason: nil
                    )
                    throw error
                }
                return try success(["sent": true])

            case "broker.ws.pull":
                let request = try decode(
                    ChannelPayload.self,
                    payload: payload,
                    allowedKeys: ["channelId"]
                )
                try validateChannelID(request.channelId)
                let pulled = try await runtime.channelStore.pullWebSocket(owner: owner, channelID: request.channelId)
                do {
                    try requireUnchangedAuth(authSnapshot)
                } catch {
                    try? await runtime.channelStore.closeWebSocket(
                        owner: owner,
                        channelID: request.channelId,
                        code: 1008,
                        reason: nil
                    )
                    throw error
                }
                return try encode(pulled.event)

            case "broker.ws.close":
                let request = try decode(
                    WebSocketClosePayload.self,
                    payload: payload,
                    allowedKeys: ["channelId", "code", "reason"]
                )
                try validateChannelID(request.channelId)
                guard request.reason == nil || request.code != nil else {
                    throw ProtocolFailure(code: .invalidPayload, message: "A WebSocket close reason requires a code.")
                }
                guard (request.reason?.lengthOfBytes(using: .utf8) ?? 0) <= 123 else {
                    throw ProtocolFailure(code: .invalidPayload, message: "The WebSocket close reason is too large.")
                }
                guard request.code.map(Self.isValidWebSocketCloseCode) ?? true else {
                    throw ProtocolFailure(code: .invalidPayload, message: "The WebSocket close code is invalid.")
                }
                try await runtime.channelStore.closeWebSocket(
                    owner: owner,
                    channelID: request.channelId,
                    code: request.code,
                    reason: request.reason
                )
                try requireUnchangedAuth(authSnapshot)
                return try success(["closed": true])

            default:
                throw ProtocolFailure(code: .unsupportedMessage, message: "The broker message type is not supported.")
            }
        } catch {
            return map(error)
        }
    }

    func loadImagePreviewFile(
        path: String,
        senderID: String,
        expectedAuth: SharedAuthScope
    ) async throws -> BrokerHTTPResponse {
        guard Self.isAllowedSidecarSender(senderID) else {
            throw ProtocolFailure(code: .unauthorizedSender, message: "The extension sender is not authorized.")
        }
        try validateHTTPPath(path)
        let pathname = String(path.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? "")
        guard pathname.hasPrefix("/api/v1/files/") || pathname.hasPrefix("/v1/files/") else {
            throw ProtocolFailure(code: .invalidPath, message: "The image preview path is invalid.")
        }
        let authSnapshot = try requireAuthSnapshot(matching: expectedAuth)

        let runtime = try await resolveRuntime(expectedAccountID: expectedAuth.accountID)
        guard try requireAuthSnapshot(matching: expectedAuth) == authSnapshot else {
            throw ProtocolFailure(code: .upstreamError, message: "The Phi Agent authentication changed.")
        }
        let request = BrokerHTTPRequest(
            service: .phiAgent,
            path: path,
            method: "GET",
            headers: try authorizedHeaders(
                ["Authorization": "Bearer \(authSnapshot.accessToken)"],
                senderID: senderID
            )
        )
        let response = try await runtime.requestExecutor(request)
        guard try requireAuthSnapshot(matching: expectedAuth) == authSnapshot else {
            throw ProtocolFailure(code: .upstreamError, message: "The Phi Agent authentication changed.")
        }
        guard response.body.count <= runtime.limits.nonStreamingResponseBytes else {
            throw ProtocolFailure(code: .responseTooLarge, message: "The image preview response is too large.")
        }
        return response
    }

    private func resolveRuntime(expectedAccountID: String? = nil) async throws -> Runtime {
        if let injectedRuntime {
            guard expectedAccountID == nil || injectedRuntime.accountID == expectedAccountID else {
                throw ProtocolFailure(
                    code: .upstreamError,
                    message: "The service broker runtime belongs to another account."
                )
            }
            return injectedRuntime
        }
        let accountID: String
        if let expectedAccountID {
            accountID = expectedAccountID
        } else if let currentAccountID = authSnapshotProvider()?.scope.accountID {
            accountID = currentAccountID
        } else {
            throw ProtocolFailure(
                code: .upstreamError,
                message: "The service broker account context is unavailable."
            )
        }
        let socketPath = try socketPathProvider(accountID)
        if let productionRuntime,
           productionRuntime.accountID == accountID,
           productionRuntime.socketPath == socketPath {
            return productionRuntime
        }

        let bootstrapClient = ServiceBrokerClient(
            socketPath: socketPath,
            nonStreamingResponseBytes: Self.defaultLimits.jsonRequestBytes
        )
        let versionResponse = try await bootstrapClient.request(BrokerHTTPRequest(
            service: .broker,
            path: "/version"
        ))
        guard versionResponse.statusCode == 200,
              let version = try? JSONDecoder().decode(ServiceBrokerVersionResponse.self, from: versionResponse.body),
              ServiceBrokerNegotiation.evaluate(protocolVersion: version.protocolVersion) == .broker,
              Self.valid(version.limits) else {
            throw ProtocolFailure(
                code: .protocolError,
                message: "The service broker protocol negotiation failed."
            )
        }

        let client = ServiceBrokerClient(socketPath: socketPath, limits: version.limits)
        let channelLimits = Self.channelSafeLimits(version.limits)
        let runtime = Runtime(
            accountID: accountID,
            socketPath: socketPath,
            limits: version.limits,
            channelStore: ServiceBrokerChannelStore(socketPath: socketPath, limits: channelLimits),
            requestExecutor: { request in try await client.request(request) }
        )
        productionRuntime = runtime
        return runtime
    }

    private func requireAuthSnapshot(matching expectedAuth: SharedAuthScope) throws -> SharedAuthTokenSnapshot {
        guard let snapshot = authSnapshotProvider(),
              snapshot.scope == expectedAuth,
              !snapshot.accessToken.isEmpty else {
            throw ProtocolFailure(code: .upstreamError, message: "The Phi Agent authentication changed.")
        }
        return snapshot
    }

    private func requireAuthenticatedSnapshot() throws -> SharedAuthTokenSnapshot {
        guard let snapshot = authSnapshotProvider(), !snapshot.accessToken.isEmpty else {
            throw ProtocolFailure(
                code: .upstreamError,
                message: "The Phi Agent authentication is unavailable."
            )
        }
        return snapshot
    }

    private func requireUnchangedAuth(_ expected: SharedAuthTokenSnapshot) throws {
        guard authSnapshotProvider() == expected else {
            throw ProtocolFailure(
                code: .upstreamError,
                message: "The Phi Agent authentication changed."
            )
        }
    }

    private func decodeHTTPRequest(
        _ payload: String,
        limits: ServiceBrokerLimits,
        allowsBrokerHealth: Bool = false,
        senderID: String
    ) throws -> BrokerHTTPRequest {
        let request = try decode(
            HTTPPayload.self,
            payload: payload,
            allowedKeys: ["path", "method", "headers", "bodyBase64"]
        )
        try validateEnvelopeMetadata(payload, base64Value: request.bodyBase64)
        let isBrokerHealth = allowsBrokerHealth && request.path == "/broker/healthz"
        let routed: RoutedServicePath
        if isBrokerHealth {
            routed = RoutedServicePath(service: .broker, path: "/healthz")
        } else {
            routed = try routedServicePath(from: request.path, senderID: senderID)
        }
        let method = (request.method ?? "GET").uppercased()
        guard Self.supportedMethods.contains(method) else {
            throw ProtocolFailure(code: .unsupportedMethod, message: "The HTTP method is not supported.")
        }
        let body = try request.bodyBase64.map(decodeBase64)
        guard (body?.count ?? 0) <= limits.jsonRequestBytes else {
            throw ProtocolFailure(code: .requestTooLarge, message: "The broker request body is too large.")
        }
        if isBrokerHealth, (method != "GET" || body != nil) {
            throw ProtocolFailure(code: .invalidPayload, message: "The broker health request is invalid.")
        }
        return BrokerHTTPRequest(
            service: routed.service,
            path: routed.path,
            method: method,
            headers: try authorizedHeaders(
                request.headers ?? [:],
                senderID: senderID
            ),
            body: body
        )
    }

    private func routedServicePath(from path: String, senderID: String) throws -> RoutedServicePath {
        try validateCanonicalPath(path)
        let pathname = String(path.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? "")
        let first = pathname.dropFirst().split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""

        if let service = BrokerService(rawValue: first), service != .broker {
            let prefix = "/\(service.rawValue)"
            let suffix = String(path.dropFirst(prefix.count))
            guard suffix.hasPrefix("/") else {
                throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
            }
            try validateCanonicalPath(suffix)
            return RoutedServicePath(service: service, path: suffix)
        }
        guard first != BrokerService.broker.rawValue else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }

        // Preserve the original Sidecar bridge shape while all maintained
        // extensions migrate to explicit service-prefixed paths.
        guard Self.isAllowedSidecarSender(senderID) else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }
        try validateHTTPPath(path)
        return RoutedServicePath(service: .phiAgent, path: path)
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        payload: String,
        allowedKeys: Set<String>
    ) throws -> T {
        let data = Data(payload.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: allowedKeys),
              let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw ProtocolFailure(code: .invalidPayload, message: "The broker payload is invalid.")
        }
        return decoded
    }

    private func authorizedHeaders(_ headers: [String: String], senderID: String) throws -> [String: String] {
        var result = [String: String]()
        for (name, value) in headers {
            guard Self.isHTTPToken(name), !Self.hasControlCharacters(value) else {
                throw ProtocolFailure(code: .invalidPayload, message: "The broker headers are invalid.")
            }
            if name.caseInsensitiveCompare(Self.brokerExtensionHeader) != .orderedSame {
                result[name] = value
            }
        }
        result[Self.brokerExtensionHeader] = senderID
        return result
    }

    private func decodeBase64(_ value: String) throws -> Data {
        guard let data = Data(base64Encoded: value), data.base64EncodedString() == value else {
            throw ProtocolFailure(code: .invalidBase64, message: "The broker payload contains invalid base64.")
        }
        return data
    }

    private func validateEnvelopeMetadata(_ payload: String, base64Value: String?) throws {
        let payloadBytes = payload.lengthOfBytes(using: .utf8)
        let base64Bytes = base64Value?.utf8.count ?? 0
        guard payloadBytes >= base64Bytes,
              payloadBytes - base64Bytes <= Self.maximumEnvelopeMetadataBytes else {
            throw ProtocolFailure(code: .requestTooLarge, message: "The broker request metadata is too large.")
        }
    }

    private func validateHTTPPath(_ path: String) throws {
        try validateCanonicalPath(path)
        let pathname = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let components = pathname.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first,
              first == "api" || first == "v1" || first == "ws" else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }
    }

    private func validateCanonicalPath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"),
              !path.contains("\\"), !Self.hasControlCharacters(path),
              !path.lowercased().contains("://") else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }
        let pathname = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let lowerPathname = pathname.lowercased()
        guard let decoded = pathname.removingPercentEncoding,
              !lowerPathname.contains("%2f"), !lowerPathname.contains("%5c"),
              !lowerPathname.contains("%00"),
              !Self.hasControlCharacters(decoded), !decoded.contains("\\"),
              !Self.containsEncodedOctet(decoded) else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("."), !components.contains(".."),
              components.first != nil else {
            throw ProtocolFailure(code: .invalidPath, message: "The broker request path is invalid.")
        }
    }

    private func validateChannelID(_ channelID: String) throws {
        guard !channelID.isEmpty, channelID.lengthOfBytes(using: .utf8) <= 128,
              !Self.hasControlCharacters(channelID) else {
            throw ProtocolFailure(code: .invalidPayload, message: "The broker channel ID is invalid.")
        }
    }

    private func encode(_ event: BrokerPullEvent) throws -> ServiceBrokerExtensionReply {
        let encoded: [String: Any]
        switch event {
        case .data(let sequence, let data):
            guard sequence <= Self.javascriptMaximumSafeInteger else {
                throw ProtocolFailure(code: .protocolError, message: "The broker sequence exceeds JavaScript precision.")
            }
            encoded = ["type": "data", "sequence": sequence, "data": data.base64EncodedString()]
        case .end:
            encoded = ["type": "end"]
        case .timeout:
            encoded = ["type": "timeout"]
        case .failure(let code, let message):
            encoded = ["type": "error", "code": code.rawValue, "message": message]
        }
        return try success(["events": [encoded]])
    }

    private func encode(_ event: BrokerWebSocketEvent) throws -> ServiceBrokerExtensionReply {
        let encoded: [String: Any]
        switch event {
        case .frame(let sequence, let frame):
            guard sequence <= Self.javascriptMaximumSafeInteger else {
                throw ProtocolFailure(code: .protocolError, message: "The broker sequence exceeds JavaScript precision.")
            }
            encoded = [
                "type": frame.kind.rawValue,
                "sequence": sequence,
                "data": frame.data.base64EncodedString(),
            ]
        case .close(let code, let reason):
            var close: [String: Any] = ["type": "close"]
            if let code { close["code"] = Int(code) }
            if let reason { close["reason"] = reason }
            encoded = close
        case .timeout:
            encoded = ["type": "timeout"]
        case .failure(let code, let message):
            encoded = ["type": "error", "code": code.rawValue, "message": message]
        }
        return try success(["events": [encoded]])
    }

    private func success(_ result: [String: Any]) throws -> ServiceBrokerExtensionReply {
        try Self.makeSuccess(result)
    }

    private static func makeSuccess(_ result: [String: Any]) throws -> ServiceBrokerExtensionReply {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProtocolFailure(code: .protocolError, message: "The broker response could not be encoded.")
        }
        return ServiceBrokerExtensionReply(json: json, error: nil)
    }

    private func failure(_ code: FailureCode, _ message: String) -> ServiceBrokerExtensionReply {
        Self.makeFailure(code, message)
    }

    private static func makeFailure(_ code: FailureCode, _ message: String) -> ServiceBrokerExtensionReply {
        let error = ServiceBrokerExtensionReply.Failure(code: code.rawValue, message: message)
        let object: [String: Any] = [
            "ok": false,
            "error": ["code": error.code, "message": error.message],
        ]
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ServiceBrokerExtensionReply(
            json: data.flatMap { String(data: $0, encoding: .utf8) }
                ?? #"{"error":{"code":"protocol_error","message":"The broker response could not be encoded."},"ok":false}"#,
            error: error
        )
    }

    private func map(_ error: Error) -> ServiceBrokerExtensionReply {
        if let error = error as? ProtocolFailure {
            return failure(error.code, error.message)
        }
        if let error = error as? BrokerChannelError {
            switch error {
            case .channelNotFound: return failure(.channelNotFound, "The broker channel was not found.")
            case .ownerMismatch: return failure(.ownerMismatch, "The broker channel belongs to another sender.")
            case .pullAlreadyPending: return failure(.pullAlreadyPending, "A broker pull is already pending.")
            case .invalidChannelKind: return failure(.invalidPayload, "The broker channel type is invalid.")
            case .invalidConfiguration: return failure(.protocolError, "The broker channel configuration is invalid.")
            }
        }
        if let error = error as? ServiceBrokerHTTPError {
            switch error {
            case .responseTooLarge: return failure(.responseTooLarge, "The broker response is too large.")
            case .invalidRequest: return failure(.invalidPayload, "The upstream HTTP request is invalid.")
            case .invalidResponse: return failure(.protocolError, "The upstream HTTP response is invalid.")
            case .peerAuthentication:
                return failure(.upstreamError, "The service-broker peer could not be authenticated.")
            case .timedOut:
                return failure(.upstreamError, "The upstream HTTP request timed out.")
            case .connectionClosed, .cancelled:
                return failure(.upstreamError, "The upstream HTTP connection failed.")
            }
        }
        if let error = error as? ServiceBrokerWebSocketError {
            switch error {
            case .protocolError, .invalidResponse:
                return failure(.protocolError, "The upstream WebSocket protocol failed.")
            case .invalidRequest:
                return failure(.invalidPayload, "The WebSocket request is invalid.")
            case .peerAuthentication:
                return failure(.upstreamError, "The service-broker peer could not be authenticated.")
            case .timedOut:
                return failure(.upstreamError, "The upstream WebSocket operation timed out.")
            case .connectionClosed, .cancelled:
                return failure(.upstreamError, "The upstream WebSocket connection failed.")
            }
        }
        return failure(.upstreamError, "The upstream service request failed.")
    }

    private func headerPairs(_ headers: [BrokerHTTPHeader]) -> [[String]] {
        headers.map { [$0.name, $0.value] }
    }

    private static func envelopeLimit(for type: String, limits: ServiceBrokerLimits) -> Int {
        let rawBytes: Int
        switch type {
        case "broker.http.request", "broker.stream.open":
            rawBytes = limits.jsonRequestBytes
        case "broker.ws.send":
            rawBytes = limits.webSocketMessageBytes
        default:
            rawBytes = 0
        }
        let encodedBytes: Int
        if rawBytes > ((Int.max - 2) / 4) * 3 {
            encodedBytes = Int.max
        } else {
            encodedBytes = ((rawBytes + 2) / 3) * 4
        }
        guard encodedBytes <= Int.max - maximumEnvelopeMetadataBytes else { return Int.max }
        return encodedBytes + maximumEnvelopeMetadataBytes
    }

    private static func isValidWebSocketCloseCode(_ code: UInt16) -> Bool {
        switch code {
        case 1000...1003, 1007...1014, 3000...4999: true
        default: false
        }
    }

    private static func currentSocketPath(auth0Subject: String) throws -> String {
        guard !auth0Subject.isEmpty,
              let applicationSupportPath = NSSearchPathForDirectoriesInDomains(
                  .applicationSupportDirectory,
                  .userDomainMask,
                  true
              ).first else {
            throw ProtocolFailure(
                code: .upstreamError,
                message: "The service broker account context is unavailable."
            )
        }
        let storagePath = ServiceBrokerSocketPath.sentinelStoragePath(
            applicationSupportPath: applicationSupportPath,
            browserBundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            auth0Subject: auth0Subject
        )
        return ServiceBrokerSocketPath.dataSocketPath(storagePath: storagePath)
    }

    private static func channelSafeLimits(_ limits: ServiceBrokerLimits) -> ServiceBrokerLimits {
        let envelopeReserve = 512
        let base64Budget = max(0, limits.bridgeChunkBytes - envelopeReserve)
        let rawChunkBytes = max(1, (base64Budget / 4) * 3)
        return ServiceBrokerLimits(
            bridgeChunkBytes: min(limits.bridgeChunkBytes, rawChunkBytes),
            jsonRequestBytes: limits.jsonRequestBytes,
            nonStreamingResponseBytes: limits.nonStreamingResponseBytes,
            webSocketMessageBytes: limits.webSocketMessageBytes,
            unacknowledgedWindowBytes: limits.unacknowledgedWindowBytes,
            stagedFileBytes: limits.stagedFileBytes,
            stagedAccountBytes: limits.stagedAccountBytes
        )
    }

    private static func valid(_ limits: ServiceBrokerLimits) -> Bool {
        limits.bridgeChunkBytes > 512 && limits.jsonRequestBytes > 0 &&
            limits.nonStreamingResponseBytes > 0 && limits.webSocketMessageBytes > 0 &&
            limits.unacknowledgedWindowBytes > 0 && limits.stagedFileBytes > 0 &&
            limits.stagedAccountBytes > 0
    }

    private static func isHTTPToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value < 0x7F &&
                !"()<>@,;:\\\"/[]?={} \t".unicodeScalars.contains($0)
        }
    }

    private static func hasControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func containsEncodedOctet(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 3 else { return false }
        for index in 0..<(bytes.count - 2) where bytes[index] == Character("%").asciiValue {
            if isHex(bytes[index + 1]) && isHex(bytes[index + 2]) { return true }
        }
        return false
    }

    private static func isHex(_ value: UInt8) -> Bool {
        (Character("0").asciiValue!...Character("9").asciiValue!).contains(value) ||
            (Character("a").asciiValue!...Character("f").asciiValue!).contains(value) ||
            (Character("A").asciiValue!...Character("F").asciiValue!).contains(value)
    }
}
