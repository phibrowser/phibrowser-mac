// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// One request to the local phi-agent, expressed independently of the route it
/// will travel: `path` is a phi-agent path plus optional query, never a full
/// URL, because the broker route has no scheme or host to put one in.
struct PhiAgentHTTPRequest: Sendable {
    let path: String
    let method: String
    let headers: [String: String]
    let body: Data?

    init(path: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
    }
}

struct PhiAgentHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

enum PhiAgentTransportError: Error, LocalizedError {
    /// A broker route is prescribed but there is no signed-in account to scope
    /// the socket to.
    case accountUnavailable
    /// The request never produced an HTTP response over the prescribed route.
    case unreachable(route: PhiAgentRoute, underlying: Error)
    /// The route answered with something that is not an HTTP response.
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .accountUnavailable:
            return "No signed-in Phi account is available for the local agent connection"
        case .unreachable(_, let underlying):
            return "The local Phi agent is unreachable: \(underlying.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from phi-agent"
        }
    }
}

/// Sends one HTTP request to the local phi-agent over the route Sentinel
/// currently prescribes: direct loopback when `transport_mode` is `legacy`,
/// otherwise the account-scoped Service Broker UDS (`/phi-agent/<path>`).
final class PhiAgentTransport: Sendable {
    static let shared = PhiAgentTransport()

    /// A failure that says nothing about phi-agent itself, only that the route
    /// did not carry the request. It is the sole trigger for re-resolving the
    /// route and retrying once, so it is kept out of the public error surface.
    private struct RouteFailure: Error {
        let underlying: Error
    }

    private let resolver: PhiAgentEndpointResolver
    private let session: URLSession
    private let brokerClientFactory: @Sendable (String) -> ServiceBrokerClient

    init(
        resolver: PhiAgentEndpointResolver = .shared,
        session: URLSession = .shared,
        brokerClientFactory: @escaping @Sendable (String) -> ServiceBrokerClient = {
            ServiceBrokerClient(socketPath: $0)
        }
    ) {
        self.resolver = resolver
        self.session = session
        self.brokerClientFactory = brokerClientFactory
    }

    /// Performs `request` over the prescribed route. A transport-level failure
    /// buys exactly one re-resolve: if the route changed, the request is sent
    /// once more over the new one; if it did not, there is nothing left to try.
    /// Every other error — a broker size or validation failure, a decoding
    /// failure — reaches the caller unchanged.
    func send(_ request: PhiAgentHTTPRequest) async throws -> PhiAgentHTTPResponse {
        let route = try await resolver.currentRoute()
        do {
            return try await perform(request, over: route)
        } catch let failure as RouteFailure {
            await resolver.invalidate()
            let retryRoute = try await resolver.currentRoute()
            guard retryRoute != route else {
                throw PhiAgentTransportError.unreachable(route: route, underlying: failure.underlying)
            }
            AppLogDebug("[PhiAgentTransport] route changed after a transport failure; retrying once")
            do {
                return try await perform(request, over: retryRoute)
            } catch let retryFailure as RouteFailure {
                throw PhiAgentTransportError.unreachable(
                    route: retryRoute,
                    underlying: retryFailure.underlying
                )
            }
        }
    }

    // MARK: - Private

    private func perform(
        _ request: PhiAgentHTTPRequest,
        over route: PhiAgentRoute
    ) async throws -> PhiAgentHTTPResponse {
        switch route {
        case .loopback(let baseURL):
            return try await performLoopback(request, baseURL: baseURL)
        case .broker(let socketPath):
            return try await performBroker(request, socketPath: socketPath)
        }
    }

    private func performLoopback(
        _ request: PhiAgentHTTPRequest,
        baseURL: String
    ) async throws -> PhiAgentHTTPResponse {
        guard let url = URL(string: baseURL + request.path) else {
            throw URLError(.badURL)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where Self.isLoopbackRouteFailure(error) {
            AppLogDebug("[PhiAgentTransport] loopback route failed: \(error.code.rawValue)")
            throw RouteFailure(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PhiAgentTransportError.invalidResponse
        }
        return PhiAgentHTTPResponse(statusCode: http.statusCode, body: data)
    }

    // The broker's own `/version` negotiation is deliberately skipped here: the
    // `ServiceBrokerClient` defaults (16 MiB non-streaming cap, 30 s I/O budget,
    // production peer authenticator) are sufficient for these small JSON
    // exchanges, and the broker enforces its own limits regardless. Broker-level
    // failures such as `E_BROKER_SERVICE_UNAVAILABLE` arrive as HTTP 5xx JSON
    // bodies, which callers already treat as "service unavailable".
    private func performBroker(
        _ request: PhiAgentHTTPRequest,
        socketPath: String
    ) async throws -> PhiAgentHTTPResponse {
        let client = brokerClientFactory(socketPath)
        do {
            let response = try await client.request(BrokerHTTPRequest(
                service: .phiAgent,
                path: request.path,
                method: request.method,
                headers: request.headers,
                body: request.body
            ))
            return PhiAgentHTTPResponse(statusCode: response.statusCode, body: response.body)
        } catch let error as ServiceBrokerHTTPError {
            switch error {
            case .connectionClosed, .timedOut, .peerAuthentication, .invalidResponse:
                AppLogDebug("[PhiAgentTransport] broker route failed: \(error)")
                throw RouteFailure(underlying: error)
            case .cancelled:
                throw CancellationError()
            case .invalidRequest, .responseTooLarge:
                throw error
            }
        }
    }

    private static func isLoopbackRouteFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            return true
        default:
            return false
        }
    }
}
