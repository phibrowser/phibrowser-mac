import XCTest
@testable import Phi

final class KeyEnvelopeAPIClientTests: XCTestCase {
    private func makeClient() -> KeyEnvelopeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return KeyEnvelopeAPIClient(session: URLSession(configuration: config),
                                    tokenProvider: { "stub-token" })
    }

    func testPutAccountSuccessAndConflict() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
            return (204, Data())
        }
        let created = try await makeClient().putAccount(salt: Data([1]), kdfVersion: "v1",
            kdfParams: Data("{}".utf8), recoveryEnvelope: Data([2]))
        XCTAssertTrue(created)

        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"already_initialized","message":"x"}"#.utf8)) }
        let again = try await makeClient().putAccount(salt: Data([1]), kdfVersion: "v1",
            kdfParams: Data("{}".utf8), recoveryEnvelope: Data([2]))
        XCTAssertFalse(again)
    }

    func testGetAccountDecodesBase64AndHandles404() async throws {
        let body = #"{"recovery_salt":"AQID","kdf_version":"v1","kdf_params":{},"recovery_ark_envelope":"BAUG","ark_generation":1}"#
        StubURLProtocol.handler = { _ in (200, Data(body.utf8)) }
        let dto = try await makeClient().getAccount()
        XCTAssertEqual(dto?.recoverySalt, Data([1, 2, 3]))
        XCTAssertEqual(dto?.recoveryArkEnvelope, Data([4, 5, 6]))

        StubURLProtocol.handler = { _ in (404, Data(#"{"code":"not_initialized","message":"x"}"#.utf8)) }
        let none = try await makeClient().getAccount()
        XCTAssertNil(none)
    }

    func testGetDeviceEnvelope404IsNil() async throws {
        StubURLProtocol.handler = { _ in (404, Data(#"{"code":"device_not_found","message":"x"}"#.utf8)) }
        let env = try await makeClient().getDeviceEnvelope(deviceKeyId: "dev-abcd1234")
        XCTAssertNil(env)
    }

    func testPostJoinRequestReturnsId() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            return (200, Data(#"{"request_id":"jr-123"}"#.utf8))
        }
        let id = try await makeClient().postJoinRequest(publicKey: Data([9, 9]), name: "Mac", platform: "macos")
        XCTAssertEqual(id, "jr-123")
    }

    func testListPendingDecodes() async throws {
        let body = #"[{"request_id":"jr-1","requesting_public_key":"AQID","name":"Air","platform":"macos","status":"pending","created_at":"2026-08-26T09:29:00.123456Z"}]"#
        StubURLProtocol.handler = { _ in (200, Data(body.utf8)) }
        let items = try await makeClient().listPendingJoinRequests()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].requestId, "jr-1")
        XCTAssertEqual(items[0].requestingPublicKey, Data([1, 2, 3]))
        XCTAssertEqual(items[0].status, "pending")
    }

    func testGetJoinRequestEnvelopeEmptyThenPresent() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"request_id":"jr-1","requesting_public_key":"AQID","name":"Air","platform":"macos","status":"pending","granted_ark_envelope":"","created_at":"2026-08-26T09:29:00Z"}"#.utf8))
        }
        let pending = try await makeClient().getJoinRequest(id: "jr-1")
        XCTAssertEqual(pending.grantedArkEnvelope, Data())
        XCTAssertNil(pending.resolvedByDeviceKeyId)

        StubURLProtocol.handler = { _ in
            (200, Data(#"{"request_id":"jr-1","requesting_public_key":"AQID","name":"Air","platform":"macos","status":"approved","granted_ark_envelope":"BAUG","created_at":"2026-08-26T09:29:00Z","resolved_by_device_key_id":"dev-x"}"#.utf8))
        }
        let approved = try await makeClient().getJoinRequest(id: "jr-1")
        XCTAssertEqual(approved.grantedArkEnvelope, Data([4, 5, 6]))
        XCTAssertEqual(approved.resolvedByDeviceKeyId, "dev-x")
    }

    func testJoinErrorMapping() async throws {
        let cases: [(Int, JoinRequestError)] = [
            (429, .tooManyPending), (409, .notPending), (404, .notFound), (400, .invalidRequest)
        ]
        for (status, expected) in cases {
            StubURLProtocol.handler = { _ in (status, Data(#"{"code":"x","message":"y"}"#.utf8)) }
            do {
                _ = try await makeClient().getJoinRequest(id: "jr-1")
                XCTFail("expected throw for \(status)")
            } catch let e as JoinRequestError {
                XCTAssertEqual(e, expected)
            }
        }
    }
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
