import Foundation
import XCTest
@testable import Phi

/// Transport behaviour for in-app phi-agent callers: the prescribed route is
/// used as-is, a transport failure buys exactly one re-resolve, and broker
/// failures that are not transport-level reach the caller unchanged.
final class PhiAgentTransportTests: XCTestCase {
    func testBrokerRouteSendsThePrefixedPathAndAuthorizationHeader() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"pairings\":[]}")
        let transport = makeTransport(resolver: makeResolver(socketPath: server.socketPath))

        let response = try await transport.send(PhiAgentHTTPRequest(
            path: "/api/pairings",
            headers: ["Authorization": "Bearer t"]
        ))

        XCTAssertEqual(server.requestMethod, "GET")
        XCTAssertEqual(server.requestTarget, "/phi-agent/api/pairings")
        XCTAssertEqual(server.requestHeaders["authorization"], "Bearer t")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data(#"{"pairings":[]}"#.utf8))
    }

    func testUnchangedBrokerRouteAfterInvalidateReportsUnreachable() async {
        let log = PhiAgentProviderLog()
        let missingSocketPath = "/tmp/phi-link-missing-\(UUID().uuidString).sock"
        let transport = makeTransport(
            resolver: makeResolver(socketPath: missingSocketPath, exportsLog: log)
        )

        do {
            _ = try await transport.send(PhiAgentHTTPRequest(path: "/api/pairings"))
            XCTFail("Expected a missing broker socket to be unreachable.")
        } catch let error as PhiAgentTransportError {
            guard case .unreachable(let route, _) = error else {
                return XCTFail("Expected .unreachable, got \(error).")
            }
            XCTAssertEqual(route, .broker(socketPath: missingSocketPath))
        } catch {
            XCTFail("Expected .unreachable, got \(error).")
        }

        XCTAssertEqual(log.count, 2, "The route must be re-resolved exactly once.")
    }

    func testRetryFollowsARouteThatChangedAfterInvalidate() async throws {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        let log = PhiAgentProviderLog()
        // First resolution reports the loopback route, whose session always
        // fails to connect; the second reports the broker route.
        let resolver = PhiAgentEndpointResolver(
            exportsProvider: {
                let invocation = log.record("exports")
                return SentinelComponentExports(
                    exportsJSON: #"{"phi-agent":{"api_base":"http://127.0.0.1:9788"}}"#,
                    transportMode: invocation == 1 ? .legacy : .uds
                )
            },
            accountIDProvider: { "auth0|link" },
            socketPathProvider: { _ in server.socketPath }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnreachableLoopbackURLProtocol.self]
        let transport = makeTransport(
            resolver: resolver,
            session: URLSession(configuration: configuration)
        )

        let response = try await transport.send(PhiAgentHTTPRequest(path: "/api/pairings"))

        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(server.requestTarget, "/phi-agent/api/pairings")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("ok".utf8))
    }

    func testBrokerResponseTooLargePropagatesUnchanged() async {
        let server = UnixHTTPTestServer(response:
            "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n12345678")
        let transport = PhiAgentTransport(
            resolver: makeResolver(socketPath: server.socketPath),
            brokerClientFactory: {
                ServiceBrokerClient(
                    socketPath: $0,
                    nonStreamingResponseBytes: 4,
                    peerAuthenticator: .allowingTests
                )
            }
        )

        do {
            _ = try await transport.send(PhiAgentHTTPRequest(path: "/api/pairings"))
            XCTFail("Expected ServiceBrokerHTTPError.responseTooLarge.")
        } catch let error as ServiceBrokerHTTPError {
            XCTAssertEqual(error, .responseTooLarge)
        } catch {
            XCTFail("Expected ServiceBrokerHTTPError.responseTooLarge, got \(error).")
        }
    }

    // MARK: - Helpers

    private func makeResolver(
        socketPath: String,
        transportMode: SentinelTransportMode = .uds,
        exportsLog: PhiAgentProviderLog? = nil
    ) -> PhiAgentEndpointResolver {
        PhiAgentEndpointResolver(
            exportsProvider: {
                _ = exportsLog?.record("exports")
                return SentinelComponentExports(
                    exportsJSON: #"{"phi-agent":{"api_base":"http://127.0.0.1:9788"}}"#,
                    transportMode: transportMode
                )
            },
            accountIDProvider: { "auth0|link" },
            socketPathProvider: { _ in socketPath }
        )
    }

    private func makeTransport(
        resolver: PhiAgentEndpointResolver,
        session: URLSession = .shared
    ) -> PhiAgentTransport {
        PhiAgentTransport(
            resolver: resolver,
            session: session,
            brokerClientFactory: {
                ServiceBrokerClient(socketPath: $0, peerAuthenticator: .allowingTests)
            }
        )
    }
}

/// Fails every loopback request the way a phi-agent listener that is no longer
/// there does. Deterministic where binding and closing a real TCP port is not.
final class UnreachableLoopbackURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}
