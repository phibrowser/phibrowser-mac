import XCTest
@testable import Phi

final class KeyEnvelopeAPIClientTests: XCTestCase {
    private func makeClient() -> KeyEnvelopeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return KeyEnvelopeAPIClient(session: URLSession(configuration: config),
                                    tokenProvider: { "stub-token" })
    }

    /// PR #145 review P1 ("bind key API requests to the stack's account identity"): a request
    /// whose token provider answers nil — the stack's account is no longer the signed-in one, or
    /// the token is mid-renewal — is never sent. Before, it went out as `Bearer ` (empty), the
    /// server answered 401, and callers read that as a sign-out.
    func testANilTokenNeverSendsTheRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = KeyEnvelopeAPIClient(session: URLSession(configuration: config), tokenProvider: { nil })
        StubURLProtocol.handler = { req in
            XCTFail("no request may be sent without a token; got \(req.httpMethod ?? "?") \(req.url?.path ?? "")")
            return (500, Data())
        }
        do {
            _ = try await client.getDeviceEnvelope(deviceKeyId: "dev-abcd1234")
            XCTFail("expected a transport error")
        } catch KeyAPIError.transport(let underlying) {
            XCTAssertEqual((underlying as? URLError)?.code, .userAuthenticationRequired)
        }
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

    func testParseRFC3339VariableFractionalDigits() {
        let base = KeyEnvelopeAPIClient.parseRFC3339("2026-08-26T09:29:00Z")
        XCTAssertNotNil(base)
        for s in ["2026-08-26T09:29:00.1Z", "2026-08-26T09:29:00.123456789Z", "2026-08-26T09:29:00.123Z"] {
            let d = KeyEnvelopeAPIClient.parseRFC3339(s)
            XCTAssertNotNil(d, "failed to parse \(s)")
            XCTAssertEqual(d!.timeIntervalSince1970, base!.timeIntervalSince1970, accuracy: 1.0, "second mismatch for \(s)")
        }
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

    /// The account reset and the legacy revoke match their refusals on the body
    /// `code`, never on the status alone.
    func testResetAndRevokeRefusalMapping() async throws {
        let operation = UUID()
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/keys/v1/reset-operations/\(operation.uuidString.lowercased())")
            return (200, Data(#"{"operation_id":"o","device_key_id":"d","outcome":"reset"}"#.utf8))
        }
        try await makeClient().resetAccount(operationId: operation, deviceKeyId: "d")

        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"not_last_device","message":"x"}"#.utf8)) }
        do { try await makeClient().resetAccount(operationId: operation, deviceKeyId: "d"); XCTFail("409") }
        catch KeyAPIError.notLastDevice {}
        StubURLProtocol.handler = { _ in (404, Data(#"{"code":"device_not_found","message":"x"}"#.utf8)) }
        do { try await makeClient().resetAccount(operationId: operation, deviceKeyId: "d"); XCTFail("404") }
        catch KeyAPIError.deviceNotFound {}
        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"other","message":"x"}"#.utf8)) }
        do { try await makeClient().resetAccount(operationId: operation, deviceKeyId: "d"); XCTFail("409") }
        catch KeyAPIError.http(409, _) {}

        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"last_device","message":"x"}"#.utf8)) }
        do { try await makeClient().revokeDevice(deviceKeyId: "d"); XCTFail("409") }
        catch KeyAPIError.lastActiveDevice {}
        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"other","message":"x"}"#.utf8)) }
        do { try await makeClient().revokeDevice(deviceKeyId: "d"); XCTFail("409") }
        catch KeyAPIError.http(409, _) {}
    }

    /// PHI-2002: the reset-request routes, their body and the refusal codes with `details`.
    func testResetRequestRoutesAndRefusalMapping() async throws {
        let operation = UUID()
        let path = "/keys/v1/reset-requests/\(operation.uuidString.lowercased())"
        let row = #"{"operation_id":"o","device_key_id":"d","requesting_public_key":"AQID","requesting_name":"Mac","requesting_platform":"macos","status":"pending","created_at":"2026-11-12T10:00:00.123456Z","execute_after":"2026-11-14T10:00:00.123456Z","join_request_id":"jr-9"}"#
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, path)
            let body = Self.jsonBody(req)
            XCTAssertEqual(body["device_key_id"] as? String, "d")
            XCTAssertEqual(body["requesting_public_key"] as? String, "CQk=")
            XCTAssertEqual(body["name"] as? String, "Mac")
            XCTAssertEqual(body["platform"] as? String, "macos")
            return (200, Data(row.utf8))
        }
        let created = try await makeClient().putResetRequest(operationId: operation, deviceKeyId: "d",
            publicKey: Data([9, 9]), name: "Mac", platform: "macos")
        XCTAssertEqual(created.status, "pending")
        XCTAssertEqual(created.joinRequestId, "jr-9")
        XCTAssertEqual(created.executeAfter, KeyEnvelopeAPIClient.parseRFC3339("2026-11-14T10:00:00.123456Z"))

        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.url?.path, path)
            return (200, Data(row.replacingOccurrences(of: "pending", with: "expired").utf8))
        }
        let read = try await makeClient().getResetRequest(operationId: operation)
        XCTAssertEqual(read.status, "expired")

        let posts: [(String, (KeyEnvelopeAPIClient) async throws -> Void)] = [
            ("/cancel", { try await $0.cancelResetRequest(operationId: operation, deviceKeyId: "d") }),
            ("/execute", { try await $0.executeResetRequest(operationId: operation, deviceKeyId: "d") })]
        for (route, call) in posts {
            StubURLProtocol.handler = { req in
                XCTAssertEqual(req.httpMethod, "POST")
                XCTAssertEqual(req.url?.path, path + route)
                XCTAssertEqual(Self.jsonBody(req)["device_key_id"] as? String, "d")
                return (200, Data(#"{"operation_id":"o","status":"cancelled"}"#.utf8))
            }
            try await call(makeClient())
        }

        func refusal(_ status: Int, _ body: String) -> Error {
            KeyEnvelopeAPIClient.mapResetRequestError(status, Data(body.utf8))
        }
        let active = refusal(409, #"{"code":"devices_active","message":"x","details":{"last_active_at":"2026-11-01T08:00:00Z","device_name":"Old Mac"}}"#)
        XCTAssertEqual(active as? ResetRequestError, .devicesActive(
            lastActiveAt: KeyEnvelopeAPIClient.parseRFC3339("2026-11-01T08:00:00Z"), deviceName: "Old Mac"))
        XCTAssertEqual(refusal(409, #"{"code":"devices_active","message":"x","details":{"last_active_at":"2026-11-01T08:00:00Z"}}"#) as? ResetRequestError,
                       .devicesActive(lastActiveAt: KeyEnvelopeAPIClient.parseRFC3339("2026-11-01T08:00:00Z"), deviceName: nil))
        XCTAssertEqual(refusal(409, #"{"code":"reset_request_exists","message":"x","details":{"execute_after":"2026-11-14T10:00:00.5Z"}}"#) as? ResetRequestError,
                       .requestExists(executeAfter: KeyEnvelopeAPIClient.parseRFC3339("2026-11-14T10:00:00.5Z")))
        XCTAssertEqual(refusal(409, #"{"code":"too_early","message":"x","details":{"execute_after":"2026-11-14T10:00:00Z"}}"#) as? ResetRequestError,
                       .tooEarly(executeAfter: KeyEnvelopeAPIClient.parseRFC3339("2026-11-14T10:00:00Z")))
        XCTAssertEqual(refusal(409, #"{"code":"not_pending","message":"x","details":{"status":"approved"}}"#) as? ResetRequestError,
                       .notPending(status: "approved"))
        XCTAssertEqual(refusal(409, #"{"code":"reset_request_conflict","message":"x"}"#) as? ResetRequestError, .conflict)
        XCTAssertEqual(refusal(403, #"{"code":"stale_authentication","message":"x"}"#) as? ResetRequestError, .staleAuthentication)
        XCTAssertEqual(refusal(403, #"{"code":"not_requester","message":"x"}"#) as? ResetRequestError, .notRequester)
        XCTAssertEqual(refusal(404, #"{"code":"account_not_found","message":"x"}"#) as? ResetRequestError, .accountNotFound)
        XCTAssertEqual(refusal(404, #"{"code":"reset_request_not_found","message":"x"}"#) as? ResetRequestError, .notFound)
        XCTAssertEqual(refusal(400, #"{"code":"device_known","message":"x"}"#) as? ResetRequestError, .deviceKnown)
        guard case KeyAPIError.http(500, _) = refusal(500, #"{"code":"internal_error","message":"x"}"#) else {
            return XCTFail("an unknown refusal stays an HTTP error")
        }
    }

    private static func jsonBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testListProfilesDecodes() async throws {
        let body = #"[{"profile_uuid":"11111111-1111-4111-8111-111111111111","has_envelope":true,"created_at":"2026-08-27T09:00:00.123456Z"}]"#
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            return (200, Data(body.utf8))
        }
        let items = try await makeClient().listProfiles()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].profileUuid, "11111111-1111-4111-8111-111111111111")
        XCTAssertTrue(items[0].hasEnvelope)
    }

    func testGetProfileKey404IsNilAnd200Decodes() async throws {
        StubURLProtocol.handler = { _ in (404, Data(#"{"code":"profile_not_found","message":"x"}"#.utf8)) }
        let none = try await makeClient().getProfileKey(uuid: "u-1")
        XCTAssertNil(none)

        StubURLProtocol.handler = { _ in
            (200, Data(#"{"profile_uuid":"u-1","profile_key_envelope":"AQID","created_at":"2026-08-27T09:00:00Z"}"#.utf8))
        }
        let dto = try await makeClient().getProfileKey(uuid: "u-1")
        XCTAssertEqual(dto?.profileKeyEnvelope, Data([1, 2, 3]))
    }

    func testPutProfileKeyCreatedAndConflict() async throws {
        StubURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            return (204, Data())
        }
        let created = try await makeClient().putProfileKey(uuid: "u-1", envelope: Data([9]))
        XCTAssertTrue(created)

        StubURLProtocol.handler = { _ in (409, Data(#"{"code":"already_exists","message":"x"}"#.utf8)) }
        let again = try await makeClient().putProfileKey(uuid: "u-1", envelope: Data([9]))
        XCTAssertFalse(again)
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
