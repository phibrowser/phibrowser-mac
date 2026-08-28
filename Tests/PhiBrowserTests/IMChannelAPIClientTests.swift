import Foundation
import XCTest
@testable import Phi

/// The Phi Link settings client over the broker route. `AuthManager` has no
/// session in a unit test, so the Authorization header is empty by design; what
/// matters here is the request path and how HTTP statuses become API errors.
final class IMChannelAPIClientTests: XCTestCase {
    func testListPairingsDecodesTheBrokerResponse() async throws {
        let body = #"""
        {"pairings":[{"id":"p1","platform":"telegram","platformUserId":"42","platformUsername":"nova","platformName":"Nova","pairedAt":"2026-08-01T00:00:00Z","agentId":"a1","channelId":"c1","localStatus":"active"}]}
        """#
        let server = UnixHTTPTestServer(response: response(status: "200 OK", body: body))
        let client = IMChannelAPIClient(transport: makeTransport(socketPath: server.socketPath))

        let pairings = try await client.listPairings()

        XCTAssertEqual(server.requestMethod, "GET")
        XCTAssertEqual(server.requestTarget, "/phi-agent/api/pairings")
        XCTAssertEqual(pairings.map(\.id), ["p1"])
        XCTAssertEqual(pairings.first?.platformUsername, "nova")
    }

    func testUnauthorizedStatusBecomesUnauthorized() async {
        let server = UnixHTTPTestServer(response: response(status: "401 Unauthorized", body: ""))
        let client = IMChannelAPIClient(transport: makeTransport(socketPath: server.socketPath))

        do {
            _ = try await client.listPairings()
            XCTFail("Expected IMChannelAPIError.unauthorized.")
        } catch let error as IMChannelAPIError {
            guard case .unauthorized = error else {
                return XCTFail("Expected .unauthorized, got \(error).")
            }
        } catch {
            XCTFail("Expected .unauthorized, got \(error).")
        }
    }

    func testServiceUnavailableStatusBecomesHTTPError() async {
        let server = UnixHTTPTestServer(response: response(status: "503 Service Unavailable", body: ""))
        let client = IMChannelAPIClient(transport: makeTransport(socketPath: server.socketPath))

        do {
            _ = try await client.listPairings()
            XCTFail("Expected IMChannelAPIError.httpError.")
        } catch let error as IMChannelAPIError {
            guard case .httpError(let statusCode) = error else {
                return XCTFail("Expected .httpError, got \(error).")
            }
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Expected .httpError, got \(error).")
        }
    }

    // MARK: - Helpers

    private func response(status: String, body: String) -> String {
        "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private func makeTransport(socketPath: String) -> PhiAgentTransport {
        PhiAgentTransport(
            resolver: PhiAgentEndpointResolver(
                exportsProvider: {
                    SentinelComponentExports(
                        exportsJSON: #"{"phi-agent":{"api_base":"http://127.0.0.1:9788"}}"#,
                        transportMode: .uds
                    )
                },
                accountIDProvider: { "auth0|link" },
                socketPathProvider: { _ in socketPath }
            ),
            brokerClientFactory: {
                ServiceBrokerClient(socketPath: $0, peerAuthenticator: .allowingTests)
            }
        )
    }
}
