import Foundation
import XCTest
@testable import Phi

final class ServiceBrokerExtensionProtocolTests: XCTestCase {
    private let allowedSender = "fenmfiepnpdlhplemgijlimpbebebljo"
    private let lexingtonSender = "pjgdkljlcbjgedgeppodjijjphfcplno"
    private let kensingtonSender = "pjlnhbfabokjejbhmgghmjiaknfhnima"

    func testCapabilityHandshakeIsExplicitAndDoesNotRequireRuntimeAuth() async throws {
        let handler = makeHandler(authSnapshot: nil, runtimeAccountID: nil)
        let reply = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)

        let denied = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(denied.error?.code, "unauthorized_sender")

        let malformed = await handler.handle(
            type: "broker.capabilities",
            payload: #"{"unexpected":true}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(malformed.error?.code, "invalid_payload")
    }

    func testCapabilityHandshakeIsUnsupportedInLegacyTransportMode() async throws {
        let handler = makeHandler(transportMode: .legacy)

        for sender in [allowedSender, lexingtonSender, kensingtonSender] {
            let reply = await handler.handle(
                type: "broker.capabilities",
                payload: "{}",
                senderID: sender
            )

            XCTAssertEqual(reply.error?.code, "unsupported_message", "sender: \(sender)")
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any]
            )
            XCTAssertEqual(root["ok"] as? Bool, false, "sender: \(sender)")
        }
    }

    func testCapabilityHandshakeAnswerIsWiredForEveryTransportMode() async throws {
        // `allCases` plus an exhaustive switch: a mode added to
        // `SentinelTransportMode` later cannot compile until its handshake
        // answer is decided here, and it is exercised automatically once it is.
        for mode in SentinelTransportMode.allCases {
            let handler = makeHandler(transportMode: mode)
            let reply = await handler.handle(
                type: "broker.capabilities",
                payload: "{}",
                senderID: allowedSender
            )

            switch mode {
            case .legacy:
                XCTAssertEqual(reply.error?.code, "unsupported_message", "mode: \(mode)")
            case .uds, .fullUDS:
                XCTAssertNil(reply.error, "mode: \(mode)")
                XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1, "mode: \(mode)")
            }
        }

        // `.fallback` is what Task 1's decoder returns when Sentinel omits the
        // field entirely or reports a value this browser does not recognise, and
        // is what a failed or timed-out lookup returns. It must never be the one
        // mode that withdraws the broker.
        XCTAssertNotEqual(SentinelTransportMode.fallback, .legacy)
    }

    func testCapabilityHandshakeAnswersProtocolVersionWhenTheTransportModeLookupFails() async throws {
        let handler = makeHandler(transportModeProvider: { throw TestUpstreamError() })

        let reply = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)
    }

    func testCapabilityHandshakeAnswersProtocolVersionWhenTheTransportModeLookupHangs() async throws {
        // Models a hung-but-connectable Sentinel. `SentinelIPCClient` blocks in
        // `Darwin.read`, which does not observe task cancellation, so the lookup
        // can neither finish nor be cancelled — the case a task-group race would
        // deadlock on, because the group awaits its children before returning.
        // Answering `.legacy` makes the failure mode loud: if the handshake ever
        // waited for this provider it would answer `unsupported_message` instead
        // of the documented `protocolVersion: 1`.
        let handler = makeHandler(
            transportModeProvider: {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return .legacy
            },
            transportModeBudgetMilliseconds: 20
        )

        let start = DispatchTime.now().uptimeNanoseconds
        let reply = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertNil(reply.error)
        XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)
        // The browser-local budget bounds the handshake — not Sentinel's
        // 5-second socket timeout, and comfortably inside the extension's
        // 1.5 s (1,500 ms)-per-attempt capability probe budget.
        XCTAssertLessThan(elapsedMilliseconds, 1_500)
    }

    func testCapabilityHandshakeAnswersProtocolVersionWhenTheLookupOutrunsItsBudget() async throws {
        // Slower than the budget but far faster than Sentinel's socket timeout:
        // the deadline wins and the late `.legacy` answer is dropped, not applied.
        let handler = makeHandler(
            transportModeProvider: {
                try await Task.sleep(nanoseconds: 300_000_000)
                return .legacy
            },
            transportModeBudgetMilliseconds: 20
        )

        let reply = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)
    }

    func testConcurrentCapabilityHandshakesShareOneTransportModeLookup() async throws {
        // Abandoning a lookup at the budget frees the handshake but not the
        // `DispatchQueue.global(qos: .userInitiated)` thread that
        // `SentinelIPCClient` parks in `Darwin.connect`. Unbounded concurrent
        // handshakes would therefore park unbounded threads; they must coalesce.
        let calls = TransportModeCallLog()
        let started = AsyncTestSignal()
        let handler = makeHandler(
            transportModeProvider: {
                _ = await calls.record()
                await started.signal()
                // Holds the lookup in flight long enough for a second handshake
                // to join it — orders of magnitude more than the actor hop needs.
                try await Task.sleep(nanoseconds: 250_000_000)
                return .uds
            },
            transportModeBudgetMilliseconds: 10_000
        )

        async let first = handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )
        // The second handshake may only be started once the first lookup is
        // genuinely in flight, otherwise it would legitimately start its own.
        await started.wait()
        async let second = handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: lexingtonSender
        )

        let replies = await [first, second]
        for reply in replies {
            XCTAssertNil(reply.error)
            XCTAssertEqual(try successResult(reply)["protocolVersion"] as? Int, 1)
        }
        let callCount = await calls.callCount
        XCTAssertEqual(callCount, 1, "concurrent handshakes must share one Sentinel round trip")
    }

    func testTransportModeLookupIsSuppressedDuringTheCoolDownAfterATimeout() async throws {
        let calls = TransportModeCallLog()
        let handler = makeHandler(
            transportModeProvider: {
                _ = await calls.record()
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return .legacy
            },
            transportModeBudgetMilliseconds: 20,
            transportModeCoolDownMilliseconds: 5_000
        )

        let first = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )
        XCTAssertEqual(try successResult(first)["protocolVersion"] as? Int, 1)
        let afterFirst = await calls.callCount
        XCTAssertEqual(afterFirst, 1)

        let second = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )

        // Same answer, but no new IPC: the cool-down is observably identical to
        // a fresh timeout, and that is the point — it costs no parked thread.
        XCTAssertEqual(try successResult(second)["protocolVersion"] as? Int, 1)
        let afterSecond = await calls.callCount
        XCTAssertEqual(afterSecond, 1, "a handshake inside the cool-down must not start Sentinel IPC")
    }

    func testTransportModeLookupResumesAfterTheCoolDownExpires() async throws {
        let calls = TransportModeCallLog()
        let handler = makeHandler(
            transportModeProvider: {
                let call = await calls.record()
                if call == 1 {
                    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                }
                return .legacy
            },
            transportModeBudgetMilliseconds: 20,
            transportModeCoolDownMilliseconds: 40
        )

        let first = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )
        XCTAssertEqual(try successResult(first)["protocolVersion"] as? Int, 1)

        try await Task.sleep(nanoseconds: 150_000_000)

        // The cool-down has lapsed, so this handshake pays for a real lookup —
        // and the mode it reads now actually changes the answer.
        let second = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: allowedSender
        )
        XCTAssertEqual(second.error?.code, "unsupported_message")
        let callCount = await calls.callCount
        XCTAssertEqual(callCount, 2)
    }

    func testCapabilityHandshakeRereadsTheTransportModeEveryTime() async throws {
        let probe = TransportModeProbe([.uds, .legacy, .uds])
        let handler = makeHandler(transportModeProvider: { await probe.next() })

        let first = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)
        let second = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)
        let third = await handler.handle(type: "broker.capabilities", payload: "{}", senderID: allowedSender)

        XCTAssertEqual(try successResult(first)["protocolVersion"] as? Int, 1)
        XCTAssertEqual(second.error?.code, "unsupported_message")
        XCTAssertEqual(try successResult(third)["protocolVersion"] as? Int, 1)
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 3)
    }

    func testLegacyTransportModeDoesNotChangeSenderOrPayloadRejections() async throws {
        let probe = TransportModeProbe([.legacy])
        let handler = makeHandler(transportModeProvider: { await probe.next() })

        let denied = await handler.handle(
            type: "broker.capabilities",
            payload: "{}",
            senderID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertEqual(denied.error?.code, "unauthorized_sender")

        let malformed = await handler.handle(
            type: "broker.capabilities",
            payload: #"{"unexpected":true}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(malformed.error?.code, "invalid_payload")

        // Neither rejection may cost a Sentinel IPC round trip: the mode is read
        // only once the sender and payload have been accepted.
        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLegacyTransportModeDoesNotAffectOtherBrokerMessages() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder, transportMode: .legacy)

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/broker/healthz","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let recordedRequest = await recorder.lastRequest()
        XCTAssertNotNil(recordedRequest)
    }

    func testAcceptsPinnedFirstPartyBrokerSendersAndPinsTheirIdentity() async throws {
        XCTAssertEqual(ServiceBrokerExtensionProtocol.allowedCanarySidecarExtensionID, allowedSender)
        XCTAssertEqual(ServiceBrokerExtensionProtocol.allowedCanaryLexingtonExtensionID, lexingtonSender)
        XCTAssertEqual(ServiceBrokerExtensionProtocol.allowedCanaryKensingtonExtensionID, kensingtonSender)

        for sender in [allowedSender, lexingtonSender, kensingtonSender] {
            let recorder = BrokerRequestRecorder()
            let handler = makeHandler(recorder: recorder)

            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/broker/healthz","method":"GET"}"#,
                senderID: sender
            )

            XCTAssertNil(reply.error, "sender: \(sender)")
            let lastRequest = await recorder.lastRequest()
            let recordedRequest = try XCTUnwrap(lastRequest)
            XCTAssertEqual(recordedRequest.headers["X-Phi-Extension-ID"], sender)
        }
    }

    func testAcceptsOnlyPinnedCanarySidecarSenderAndPinsServiceIdentity() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder)

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/v1/chats","method":"post","headers":{"Authorization":"Bearer token","x-phi-extension-id":"attacker"},"bodyBase64":"aGk="}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let result = try successResult(reply)
        XCTAssertEqual(result["status"] as? Int, 401)
        XCTAssertEqual(result["bodyBase64"] as? String, "e30=")
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.service, .phiAgent)
        XCTAssertEqual(request.path, "/api/v1/chats")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, Data("hi".utf8))
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        XCTAssertNil(request.headers["x-phi-extension-id"])
        XCTAssertEqual(request.headers["X-Phi-Extension-ID"], allowedSender)
        XCTAssertEqual(ServiceBrokerExtensionProtocol.allowedCanarySidecarExtensionID, allowedSender)
    }

    func testRoutesServicePrefixedHTTPPathToPhiAgent() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder)

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/phi-agent/api/v1/chats","method":"POST"}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.service, .phiAgent)
        XCTAssertEqual(request.path, "/api/v1/chats")
    }

    func testRoutesEveryMaintainedServicePrefixAndPinsTheActualSender() async throws {
        let cases: [(String, String, BrokerService, String)] = [
            (lexingtonSender, "/phi-memory/v1/skill/read", .phiMemory, "/v1/skill/read"),
            (lexingtonSender, "/ai-gateway/v1/models", .aiGateway, "/v1/models"),
            (kensingtonSender, "/phi-agent/api/health", .phiAgent, "/api/health"),
            (allowedSender, "/pi-agent/api/tasks", .piAgent, "/api/tasks"),
        ]

        for (sender, path, service, upstreamPath) in cases {
            let recorder = BrokerRequestRecorder()
            let handler = makeHandler(recorder: recorder)
            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"\#(path)","method":"GET"}"#,
                senderID: sender
            )

            XCTAssertNil(reply.error, "path: \(path)")
            let lastRequest = await recorder.lastRequest()
            let request = try XCTUnwrap(lastRequest)
            XCTAssertEqual(request.service, service)
            XCTAssertEqual(request.path, upstreamPath)
            XCTAssertEqual(request.headers["X-Phi-Extension-ID"], sender)
        }
    }

    func testLegacyUnprefixedPhiAgentPathsRemainSidecarOnly() async {
        let handler = makeHandler()

        let sidecar = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/health","method":"GET"}"#,
            senderID: allowedSender
        )
        XCTAssertNil(sidecar.error)

        for sender in [lexingtonSender, kensingtonSender] {
            let http = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/api/health","method":"GET"}"#,
                senderID: sender
            )
            XCTAssertEqual(http.error?.code, "invalid_path", "sender: \(sender)")

            let webSocket = await handler.handle(
                type: "broker.ws.open",
                payload: #"{"path":"/ws/phi-agent/execute"}"#,
                senderID: sender
            )
            XCTAssertEqual(webSocket.error?.code, "invalid_path", "sender: \(sender)")
        }
    }

    func testRejectsEveryNonFirstPartyBrokerSenderBeforeTransportAccess() async {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(recorder: recorder)

        for sender in ["", "cdp", "debug-extension", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                       allowedSender.uppercased()] {
            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/api/health","method":"GET"}"#,
                senderID: sender
            )
            XCTAssertEqual(reply.error?.code, "unauthorized_sender", "sender: \(sender)")
        }
        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 0)
    }

    func testRejectsHTTPReplyWhenAuthRevisionChangesDuringRequest() async {
        let accountA = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a",
            generation: 1
        )
        let rotatedA = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-rotated",
            generation: 2
        )
        let authState = ImagePreviewAuthSnapshotBox(accountA)
        let handler = makeHandler(
            requestExecutor: { _ in
                authState.set(rotatedA)
                await Task.yield()
                return BrokerHTTPResponse(statusCode: 200, headers: [], body: Data("secret".utf8))
            },
            authSnapshotProvider: { authState.current() },
            runtimeAccountID: accountA.scope.accountID
        )

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/private","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertEqual(reply.error?.code, "upstream_error")
    }

    func testAuthRevisionOwnsChannelAndRejectsPullAfterTokenRotation() async throws {
        let accountA = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a",
            generation: 1
        )
        let rotatedA = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-rotated",
            generation: 2
        )
        let authState = ImagePreviewAuthSnapshotBox(accountA)
        let store = makeStore(httpReader: HTTPChunkReader([Data("secret".utf8), nil]))
        let handler = makeHandler(
            channelStore: store,
            authSnapshotProvider: { authState.current() },
            runtimeAccountID: accountA.scope.accountID
        )
        let opened = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/private"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)

        authState.set(rotatedA)
        let pulled = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)

        XCTAssertEqual(pulled.error?.code, "owner_mismatch")
    }

    func testImagePreviewItemsUseBrokerOnlyForExactSidecarSenderAndFilePath() {
        let addresses = [
            "/api/v1/files/image-1?variant=full",
            "https://images.example/image.png",
        ]

        let allowed = ImagePreviewItem.items(
            fromAddressStrings: addresses,
            authorizedPhiAgentSenderID: allowedSender
        )
        XCTAssertEqual(
            allowed.first?.source,
            .phiAgentFile(
                path: "/api/v1/files/image-1?variant=full",
                senderID: allowedSender
            )
        )
        XCTAssertEqual(
            allowed.last?.source,
            .remoteURL(URL(string: "https://images.example/image.png")!)
        )

        for sender in ["", "cdp", "debug-extension", "other-extension"] {
            let rejected = ImagePreviewItem.items(
                fromAddressStrings: addresses,
                authorizedPhiAgentSenderID: sender
            )
            XCTAssertEqual(
                rejected.first?.source,
                .localFile(URL(fileURLWithPath: "/api/v1/files/image-1?variant=full"))
            )
        }
    }

    func testImagePreviewFileFetchRequiresExactSenderAndUsesBrokerAuth() async throws {
        let recorder = BrokerRequestRecorder()
        let expectedAuth = authSnapshot(
            accountID: "auth0|test-account",
            accessToken: "native-access-token",
            generation: 1
        )
        let handler = makeHandler(recorder: recorder, authSnapshot: expectedAuth)

        for sender in ["", "cdp", "debug-extension", "other-extension"] {
            do {
                _ = try await handler.loadImagePreviewFile(
                    path: "/api/v1/files/image-1",
                    senderID: sender,
                    expectedAuth: expectedAuth.scope
                )
                XCTFail("Expected unauthorized sender: \(sender)")
            } catch {}
        }
        let rejectedRequestCount = await recorder.count()
        XCTAssertEqual(rejectedRequestCount, 0)

        let response = try await handler.loadImagePreviewFile(
            path: "/api/v1/files/image-1?variant=full",
            senderID: allowedSender,
            expectedAuth: expectedAuth.scope
        )
        XCTAssertEqual(response.statusCode, 401)
        let recordedRequest = await recorder.lastRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.service, .phiAgent)
        XCTAssertEqual(request.path, "/api/v1/files/image-1?variant=full")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Authorization"], "Bearer native-access-token")
        XCTAssertEqual(request.headers["X-Phi-Extension-ID"], allowedSender)
    }

    func testImagePreviewFileFetchRejectsAuthOrRuntimeAccountMismatchBeforeBrokerRequest() async {
        let expectedAuth = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a",
            generation: 1
        )
        let currentOtherAccount = authSnapshot(
            accountID: "auth0|account-b",
            accessToken: "token-b",
            generation: 2
        )
        let authMismatchRecorder = BrokerRequestRecorder()
        let runtimeMismatchRecorder = BrokerRequestRecorder()

        for (handler, recorder) in [
            (
                makeHandler(
                    recorder: authMismatchRecorder,
                    authSnapshot: currentOtherAccount,
                    runtimeAccountID: expectedAuth.scope.accountID
                ),
                authMismatchRecorder
            ),
            (
                makeHandler(
                    recorder: runtimeMismatchRecorder,
                    authSnapshot: expectedAuth,
                    runtimeAccountID: currentOtherAccount.scope.accountID
                ),
                runtimeMismatchRecorder
            ),
        ] {
            do {
                _ = try await handler.loadImagePreviewFile(
                    path: "/api/v1/files/image-1",
                    senderID: allowedSender,
                    expectedAuth: expectedAuth.scope
                )
                XCTFail("Expected mismatched authenticated runtime scope to fail closed")
            } catch {}
            let requestCount = await recorder.count()
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testImagePreviewFileFetchRejectsNonFilePathsAndOversizedResponses() async {
        let recorder = BrokerRequestRecorder()
        let expectedAuth = authSnapshot(
            accountID: "auth0|test-account",
            accessToken: "native-access-token",
            generation: 1
        )
        let handler = makeHandler(
            limits: limits(nonStreamingResponseBytes: 4),
            response: BrokerHTTPResponse(
                statusCode: 200,
                headers: [],
                body: Data(repeating: 0x41, count: 5)
            ),
            recorder: recorder,
            authSnapshot: expectedAuth
        )

        for path in ["/api/v1/chats", "/api/v1/files/../secret", "https://localhost/api/v1/files/x"] {
            do {
                _ = try await handler.loadImagePreviewFile(
                    path: path,
                    senderID: allowedSender,
                    expectedAuth: expectedAuth.scope
                )
                XCTFail("Expected rejected path: \(path)")
            } catch {}
        }
        let invalidPathRequestCount = await recorder.count()
        XCTAssertEqual(invalidPathRequestCount, 0)

        do {
            _ = try await handler.loadImagePreviewFile(
                path: "/api/v1/files/too-large",
                senderID: allowedSender,
                expectedAuth: expectedAuth.scope
            )
            XCTFail("Expected oversized response rejection")
        } catch {}
        let oversizedRequestCount = await recorder.count()
        XCTAssertEqual(oversizedRequestCount, 1)
    }

    func testImagePreviewLoaderDecodesBrokerFileWithoutURLSession() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let calls = ImagePreviewBrokerLoadRecorder(response: BrokerHTTPResponse(
            statusCode: 200,
            headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
            body: png
        ))
        let expectedAuth = authSnapshot(
            accountID: "auth0|test-account",
            accessToken: "native-access-token",
            generation: 1
        )
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { expectedAuth.scope },
            phiAgentFileLoader: { path, senderID, _ in
                try await calls.load(path: path, senderID: senderID)
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image",
            source: .phiAgentFile(path: "/api/v1/files/image-1", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        let asset = try await loader.load(item)

        XCTAssertEqual(asset.pixelSize, CGSize(width: 1, height: 1))
        let loadedPath = await calls.lastPath()
        let loadedSenderID = await calls.lastSenderID()
        XCTAssertEqual(loadedPath, "/api/v1/files/image-1")
        XCTAssertEqual(loadedSenderID, allowedSender)
    }

    func testImagePreviewLoaderRefetchesSamePathAfterAccountSwitch() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let accountA = authSnapshot(accountID: "auth0|account-a", accessToken: "token-a", generation: 1)
        let accountB = authSnapshot(accountID: "auth0|account-b", accessToken: "token-b", generation: 2)
        let authState = ImagePreviewAuthSnapshotBox(accountA)
        let calls = ImagePreviewBrokerAccountSwitchRecorder(response: BrokerHTTPResponse(
            statusCode: 200,
            headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
            body: png
        ))
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope },
            phiAgentFileLoader: { path, senderID, _ in
                try await calls.load(path: path, senderID: senderID)
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-account-scope",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        let first = try await loader.load(item)
        let sameAccount = try await loader.load(item)
        XCTAssertTrue(first.image === sameAccount.image)
        let sameAccountCallCount = await calls.count()
        XCTAssertEqual(sameAccountCallCount, 1)

        authState.set(accountB)
        do {
            _ = try await loader.load(item)
            XCTFail("Expected account B broker failure instead of account A cached bytes")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }
        let switchedAccountCallCount = await calls.count()
        XCTAssertEqual(switchedAccountCallCount, 2)
    }

    func testImagePreviewLoaderDoesNotReturnPrivilegedCacheAfterLogout() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let accountA = authSnapshot(accountID: "auth0|account-a", accessToken: "token-a", generation: 1)
        let authState = ImagePreviewAuthSnapshotBox(accountA)
        let calls = ImagePreviewBrokerLoadRecorder(response: BrokerHTTPResponse(
            statusCode: 200,
            headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
            body: png
        ))
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope },
            phiAgentFileLoader: { path, senderID, _ in
                try await calls.load(path: path, senderID: senderID)
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-logout",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        _ = try await loader.load(item)
        authState.set(nil)

        do {
            _ = try await loader.load(item)
            XCTFail("Expected logout to reject account A cached bytes")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }
        let brokerCallCount = await calls.count()
        XCTAssertEqual(brokerCallCount, 1)
    }

    func testImagePreviewLoaderRejectsBytesWhenAccountChangesDuringBrokerLoad() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let accountA = authSnapshot(accountID: "auth0|account-a", accessToken: "token-a", generation: 1)
        let accountB = authSnapshot(accountID: "auth0|account-b", accessToken: "token-b", generation: 2)
        let authState = ImagePreviewAuthSnapshotBox(accountA)
        let calls = ImagePreviewBrokerLoadRecorder(response: BrokerHTTPResponse(
            statusCode: 200,
            headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
            body: png
        ))
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope },
            phiAgentFileLoader: { path, senderID, _ in
                let response = try await calls.load(path: path, senderID: senderID)
                authState.set(accountB)
                return response
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-account-race",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        do {
            _ = try await loader.load(item)
            XCTFail("Expected account change during load to reject account A bytes")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }
        let brokerCallCount = await calls.count()
        XCTAssertEqual(brokerCallCount, 1)
    }

    func testImagePreviewLoaderRejectsABASwitchBytesWithoutCachingThemUnderOriginalAccount() async throws {
        let accountAImage = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let accountBImage = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAABAAAAAQAAAACJcORAAAAADklEQVQIHWP4z8DwHwQBEPgD/dkGjrgAAAAASUVORK5CYII="))
        let accountAInitial = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-initial",
            generation: 1
        )
        let accountB = authSnapshot(
            accountID: "auth0|account-b",
            accessToken: "token-b",
            generation: 2
        )
        let accountARestored = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-restored",
            generation: 3
        )
        let authState = ImagePreviewAuthSnapshotBox(accountAInitial)
        let calls = ImagePreviewBrokerABARecorder(
            authState: authState,
            accountB: accountB,
            accountARestored: accountARestored,
            accountAResponse: BrokerHTTPResponse(
                statusCode: 200,
                headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
                body: accountAImage
            ),
            accountBResponse: BrokerHTTPResponse(
                statusCode: 200,
                headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
                body: accountBImage
            )
        )
        let handler = makeHandler(
            requestExecutor: { request in await calls.execute(request) },
            authSnapshotProvider: { authState.current() },
            runtimeAccountID: accountAInitial.scope.accountID
        )
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope },
            phiAgentFileLoader: { path, senderID, expectedAuth in
                let response = try await handler.loadImagePreviewFile(
                    path: path,
                    senderID: senderID,
                    expectedAuth: expectedAuth
                )
                await calls.recordProtocolReturn()
                return response
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-account-aba-race",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        do {
            let leakedAsset = try await loader.load(item)
            XCTFail("Expected A-B-A auth transition to reject B bytes, got \(leakedAsset.pixelSize)")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }

        let accountAAsset = try await loader.load(item)
        XCTAssertEqual(accountAAsset.pixelSize, CGSize(width: 1, height: 1))
        let brokerCallCount = await calls.count()
        XCTAssertEqual(brokerCallCount, 2)
        let protocolReturnCount = await calls.protocolReturnCount()
        XCTAssertEqual(protocolReturnCount, 1)
        let authorizationHeaders = await calls.authorizationHeaders()
        XCTAssertEqual(authorizationHeaders, [
            "Bearer token-a-initial",
            "Bearer token-a-restored",
        ])
    }

    func testImagePreviewLoaderRejectsSameAccountTokenRotationDuringBrokerLoad() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let initialAuth = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-initial",
            generation: 1
        )
        let rotatedAuth = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-rotated",
            generation: 2
        )
        let authState = ImagePreviewAuthSnapshotBox(initialAuth)
        let calls = ImagePreviewBrokerTokenRotationRecorder(
            authState: authState,
            rotatedAuth: rotatedAuth,
            response: BrokerHTTPResponse(
                statusCode: 200,
                headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
                body: png
            )
        )
        let handler = makeHandler(
            requestExecutor: { request in await calls.execute(request) },
            authSnapshotProvider: { authState.current() },
            runtimeAccountID: initialAuth.scope.accountID
        )
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope },
            phiAgentFileLoader: { path, senderID, expectedAuth in
                let response = try await handler.loadImagePreviewFile(
                    path: path,
                    senderID: senderID,
                    expectedAuth: expectedAuth
                )
                await calls.recordProtocolReturn()
                return response
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-token-rotation",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        do {
            _ = try await loader.load(item)
            XCTFail("Expected same-account token rotation to reject in-flight bytes")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }

        _ = try await loader.load(item)
        let brokerCallCount = await calls.count()
        XCTAssertEqual(brokerCallCount, 2)
        let protocolReturnCount = await calls.protocolReturnCount()
        XCTAssertEqual(protocolReturnCount, 1)
        let authorizationHeaders = await calls.authorizationHeaders()
        XCTAssertEqual(authorizationHeaders, [
            "Bearer token-a-initial",
            "Bearer token-a-rotated",
        ])
    }

    func testImagePreviewLoaderRevalidatesAuthSnapshotBeforeReturningCacheHit() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let initialAuth = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-initial",
            generation: 1
        )
        let restoredAuth = authSnapshot(
            accountID: "auth0|account-a",
            accessToken: "token-a-restored",
            generation: 2
        )
        let authSequence = ImagePreviewAuthSnapshotSequence([
            initialAuth,
            initialAuth,
            initialAuth,
            restoredAuth,
        ])
        let calls = ImagePreviewBrokerLoadRecorder(response: BrokerHTTPResponse(
            statusCode: 200,
            headers: [BrokerHTTPHeader(name: "content-type", value: "image/png")],
            body: png
        ))
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authSequence.next()?.scope },
            phiAgentFileLoader: { path, senderID, _ in
                try await calls.load(path: path, senderID: senderID)
            }
        )
        let item = ImagePreviewItem(
            id: "broker-image-cache-hit-auth-race",
            source: .phiAgentFile(path: "/api/v1/files/shared-path", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        _ = try await loader.load(item)
        do {
            _ = try await loader.load(item)
            XCTFail("Expected changed auth generation to reject the cache hit")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }
        let brokerCallCount = await calls.count()
        XCTAssertEqual(brokerCallCount, 1)
    }

    func testImagePreviewLoaderKeepsNonPrivilegedCacheIndependentOfAccountScope() async throws {
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let authState = ImagePreviewAuthSnapshotBox(nil)
        let loader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { authState.current()?.scope }
        )
        let item = ImagePreviewItem(
            id: "inline-image",
            source: .rawData(png, mimeType: "image/png"),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )

        let first = try await loader.load(item)
        authState.set(authSnapshot(accountID: "auth0|account-b", accessToken: "token-b", generation: 2))
        let second = try await loader.load(item)

        XCTAssertTrue(first.image === second.image)
        XCTAssertEqual(authState.readCount(), 0)
    }

    func testImagePreviewLoaderMapsBrokerStatusAndTransportFailures() async {
        let expectedAuth = authSnapshot(
            accountID: "auth0|test-account",
            accessToken: "native-access-token",
            generation: 1
        )
        let item = ImagePreviewItem(
            id: "broker-image-error",
            source: .phiAgentFile(path: "/api/v1/files/image-1", senderID: allowedSender),
            title: nil,
            mimeType: nil,
            suggestedFilename: nil
        )
        let statusLoader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { expectedAuth.scope },
            phiAgentFileLoader: { _, _, _ in
                BrokerHTTPResponse(statusCode: 404, headers: [], body: Data())
            }
        )
        let transportLoader = ImagePreviewLoader(
            phiAgentAuthSnapshotProvider: { expectedAuth.scope },
            phiAgentFileLoader: { _, _, _ in
                throw TestUpstreamError()
            }
        )

        do {
            _ = try await statusLoader.load(item)
            XCTFail("Expected non-success broker status to fail")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }

        do {
            _ = try await transportLoader.load(item)
            XCTFail("Expected broker transport failure to fail")
        } catch {
            XCTAssertEqual(error as? ImagePreviewError, .networkFailed)
        }
    }

    func testRejectsUnknownMessageAndForbiddenTransportSelectorFields() async {
        let handler = makeHandler()

        let unknown = await handler.handle(type: "broker.unknown", payload: "{}", senderID: allowedSender)
        XCTAssertEqual(unknown.error?.code, "unsupported_message")
        for selector in ["service", "socket", "socketPath", "host", "port"] {
            let payload = #"{"path":"/api/health","method":"GET","PLACEHOLDER":"value"}"#
                .replacingOccurrences(of: "PLACEHOLDER", with: selector)
            let reply = await handler.handle(
                type: "broker.http.request", payload: payload, senderID: allowedSender)
            XCTAssertEqual(reply.error?.code, "invalid_payload", "selector: \(selector)")
        }
    }

    func testBrokerHealthReadinessUsesOnlyTheReservedBrokerEndpoint() async throws {
        let recorder = BrokerRequestRecorder()
        let handler = makeHandler(
            response: BrokerHTTPResponse(
                statusCode: 200,
                headers: [BrokerHTTPHeader(name: "content-type", value: "application/json")],
                body: Data(#"{"ready":true}"#.utf8)
            ),
            recorder: recorder
        )

        let health = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/broker/healthz","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertEqual(try successResult(health)["status"] as? Int, 200)
        let lastRequest = await recorder.lastRequest()
        let recorded = try XCTUnwrap(lastRequest)
        XCTAssertEqual(recorded.service, .broker)
        XCTAssertEqual(recorded.path, "/healthz")

        let version = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/broker/version","method":"GET"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(version.error?.code, "invalid_path")

        let rejected: [(type: String, payload: String, code: String)] = [
            (
                "broker.http.request",
                #"{"path":"/broker/healthz?probe=1","method":"GET"}"#,
                "invalid_path"
            ),
            (
                "broker.http.request",
                #"{"path":"/%62roker/healthz","method":"GET"}"#,
                "invalid_path"
            ),
            (
                "broker.http.request",
                #"{"path":"/broker%2Fhealthz","method":"GET"}"#,
                "invalid_path"
            ),
            (
                "broker.http.request",
                #"{"path":"/broker//healthz","method":"GET"}"#,
                "invalid_path"
            ),
            (
                "broker.http.request",
                #"{"path":"/broker/healthz","method":"POST"}"#,
                "invalid_payload"
            ),
            (
                "broker.http.request",
                #"{"path":"/broker/healthz","method":"GET","bodyBase64":"e30="}"#,
                "invalid_payload"
            ),
            (
                "broker.stream.open",
                #"{"path":"/broker/healthz","method":"GET"}"#,
                "invalid_path"
            ),
        ]

        for item in rejected {
            let response = await handler.handle(
                type: item.type,
                payload: item.payload,
                senderID: allowedSender
            )
            XCTAssertEqual(response.error?.code, item.code, "\(item.type): \(item.payload)")
        }
        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 1)
    }

    func testRejectsMalformedPayloadPathsMethodsBase64AndOversizedBodies() async {
        let handler = makeHandler(limits: limits(jsonRequestBytes: 96))
        let oversizedBody = Data(repeating: 0x00, count: 97).base64EncodedString()
        let cases: [(String, String)] = [
            ("not-json", "invalid_payload"),
            (#"{"path":"https://localhost/api","method":"GET"}"#, "invalid_path"),
            (#"{"path":"//api/health","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/api/../secret","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/broker/version","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/not-authorized","method":"GET"}"#, "invalid_path"),
            (#"{"path":"/api/health","method":"CONNECT"}"#, "unsupported_method"),
            (#"{"path":"/api/health","method":"POST","bodyBase64":"%%%"}"#, "invalid_base64"),
            (#"{"path":"/api/health","method":"POST","bodyBase64":"\#(oversizedBody)"}"#, "request_too_large"),
        ]

        for (payload, expectedCode) in cases {
            let reply = await handler.handle(
                type: "broker.http.request", payload: payload, senderID: allowedSender)
            XCTAssertEqual(reply.error?.code, expectedCode, "payload: \(payload)")
        }
    }

    func testHTTPStatusAndHeadersRemainSuccessfulEnvelope() async throws {
        let handler = makeHandler(response: BrokerHTTPResponse(
            statusCode: 401,
            headers: [
                BrokerHTTPHeader(name: "set-cookie", value: "first=1"),
                BrokerHTTPHeader(name: "www-authenticate", value: "Bearer realm=one"),
                BrokerHTTPHeader(name: "set-cookie", value: "second=2"),
                BrokerHTTPHeader(name: "www-authenticate", value: "Basic realm=two"),
                BrokerHTTPHeader(name: "content-type", value: "application/json"),
            ],
            body: Data(#"{"error":"expired"}"#.utf8)
        ))

        let reply = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/v1/chats","method":"GET"}"#,
            senderID: allowedSender
        )

        XCTAssertNil(reply.error)
        let result = try successResult(reply)
        XCTAssertEqual(result["status"] as? Int, 401)
        XCTAssertEqual(
            result["headers"] as? [[String]],
            [
                ["set-cookie", "first=1"],
                ["www-authenticate", "Bearer realm=one"],
                ["set-cookie", "second=2"],
                ["www-authenticate", "Basic realm=two"],
                ["content-type", "application/json"],
            ]
        )
        XCTAssertEqual(
            Data(base64Encoded: try XCTUnwrap(result["bodyBase64"] as? String)),
            Data(#"{"error":"expired"}"#.utf8)
        )
    }

    func testDecodedHTTPAndWebSocketPayloadLimitsIgnoreBase64EnvelopeOverhead() async throws {
        let exact = Data(repeating: 0x41, count: 12).base64EncodedString()
        let over = Data(repeating: 0x41, count: 13).base64EncodedString()
        let socket = FakeProtocolWebSocket(events: [])
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(
            limits: limits(jsonRequestBytes: 12, webSocketMessageBytes: 12),
            channelStore: store
        )

        let exactHTTP = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/upload","method":"POST","bodyBase64":"\#(exact)"}"#,
            senderID: allowedSender
        )
        XCTAssertNil(exactHTTP.error)
        let overHTTP = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/upload","method":"POST","bodyBase64":"\#(over)"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(overHTTP.error?.code, "request_too_large")

        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        let exactWebSocket = await handler.handle(
            type: "broker.ws.send",
            payload: #"{"channelId":"\#(channelID)","kind":"binary","data":"\#(exact)"}"#,
            senderID: allowedSender
        )
        XCTAssertNil(exactWebSocket.error)
        let overWebSocket = await handler.handle(
            type: "broker.ws.send",
            payload: #"{"channelId":"\#(channelID)","kind":"binary","data":"\#(over)"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(overWebSocket.error?.code, "request_too_large")
    }

    func testRequestEnvelopeMetadataRemainsBoundedAndBase64Canonical() async {
        let handler = makeHandler(limits: limits(
            jsonRequestBytes: 1_048_576,
            webSocketMessageBytes: 1_048_576
        ))
        let oversizedMetadata = String(repeating: "a", count: 65_537)
        let metadata = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/\#(oversizedMetadata)","method":"GET"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(metadata.error?.code, "request_too_large")

        let nonCanonical = await handler.handle(
            type: "broker.http.request",
            payload: #"{"path":"/api/upload","method":"POST","bodyBase64":"QQ"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(nonCanonical.error?.code, "invalid_base64")
    }

    func testCancelAndCloseRejectTheWrongChannelKind() async throws {
        let reader = HTTPChunkReader([])
        let socket = FakeProtocolWebSocket(events: [])
        let store = makeStore(httpReader: reader, webSocket: socket)
        let handler = makeHandler(channelStore: store)
        let stream = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream"}"#,
            senderID: allowedSender
        )
        let streamID = try XCTUnwrap(try successResult(stream)["channelId"] as? String)
        let webSocket = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let webSocketID = try XCTUnwrap(try successResult(webSocket)["channelId"] as? String)

        let closeStream = await handler.handle(
            type: "broker.ws.close",
            payload: #"{"channelId":"\#(streamID)","code":1000}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(closeStream.error?.code, "invalid_payload")
        let cancelWebSocket = await handler.handle(
            type: "broker.stream.cancel",
            payload: #"{"channelId":"\#(webSocketID)"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(cancelWebSocket.error?.code, "invalid_payload")

        let cancelStream = await handler.handle(
            type: "broker.stream.cancel",
            payload: #"{"channelId":"\#(streamID)"}"#,
            senderID: allowedSender
        )
        XCTAssertNil(cancelStream.error)
        let closeWebSocket = await handler.handle(
            type: "broker.ws.close",
            payload: #"{"channelId":"\#(webSocketID)","code":1000}"#,
            senderID: allowedSender
        )
        XCTAssertNil(closeWebSocket.error)
    }

    func testInvalidWebSocketCloseCodeDoesNotRemoveChannel() async throws {
        let socket = FakeProtocolWebSocket(events: [])
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(channelStore: store)
        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)

        for code in [999, 1005, 1015, 2000, 5000] {
            let invalid = await handler.handle(
                type: "broker.ws.close",
                payload: #"{"channelId":"\#(channelID)","code":\#(code)}"#,
                senderID: allowedSender
            )
            XCTAssertEqual(invalid.error?.code, "invalid_payload", "code: \(code)")
        }

        let valid = await handler.handle(
            type: "broker.ws.close",
            payload: #"{"channelId":"\#(channelID)","code":1000}"#,
            senderID: allowedSender
        )
        XCTAssertNil(valid.error)
    }

    func testWebSocketSequenceComesFromChannelLifecycle() async throws {
        let socket = FakeProtocolWebSocket(events: [
            .frame(sequence: 41, BrokerWebSocketFrame(kind: .binary, data: Data([1]))),
        ])
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(channelStore: store)
        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)

        let pulled = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)

        XCTAssertEqual(try firstEvent(pulled)["sequence"] as? Int, 41)
    }

    func testStreamOpenPullAndCancelUseExactJSONMapping() async throws {
        let reader = HTTPChunkReader([Data("one".utf8), Data("two".utf8), nil])
        let store = makeStore(httpReader: reader)
        let handler = makeHandler(channelStore: store)

        let opened = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/proactive-greeting","method":"POST"}"#,
            senderID: allowedSender
        )
        let openResult = try successResult(opened)
        let channelID = try XCTUnwrap(openResult["channelId"] as? String)
        XCTAssertEqual(openResult["status"] as? Int, 200)
        XCTAssertEqual(openResult["headers"] as? [[String]], [["content-type", "text/event-stream"]])

        let first = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        let second = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        let end = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(try firstEvent(first)["type"] as? String, "data")
        XCTAssertEqual(try firstEvent(first)["sequence"] as? Int, 0)
        XCTAssertEqual(try firstEvent(first)["data"] as? String, "b25l")
        XCTAssertEqual(try firstEvent(second)["sequence"] as? Int, 1)
        XCTAssertEqual(try firstEvent(second)["data"] as? String, "dHdv")
        XCTAssertEqual(try firstEvent(end)["type"] as? String, "end")

        let cancelled = await handler.handle(
            type: "broker.stream.cancel",
            payload: #"{"channelId":"\#(channelID)"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(cancelled.error?.code, "channel_not_found")
    }

    func testWebSocketOpenSendPullAndCloseUseExactJSONMapping() async throws {
        let socket = FakeProtocolWebSocket(events: [])
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(channelStore: store)

        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/phi-agent/ws/phi-agent/execute","headers":{"Authorization":"Bearer token"}}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        let sent = await handler.handle(
            type: "broker.ws.send",
            payload: #"{"channelId":"\#(channelID)","kind":"binary","data":"BAU="}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(try successResult(sent)["sent"] as? Bool, true)
        let sentFrames = await socket.sentFrames()
        XCTAssertEqual(sentFrames, [
            BrokerWebSocketFrame(kind: .binary, data: Data([4, 5])),
        ])

        await socket.enqueue(
            .frame(sequence: 0, BrokerWebSocketFrame(
                kind: .text, data: Data(#"{"type":"event"}"#.utf8))))
        let text = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        await socket.enqueue(
            .frame(sequence: 1, BrokerWebSocketFrame(kind: .binary, data: Data([1, 2, 3]))))
        let binary = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        await socket.enqueue(.close(code: 1000, reason: "done"))
        let close = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(try firstEvent(text)["type"] as? String, "text")
        XCTAssertEqual(try firstEvent(text)["sequence"] as? Int, 0)
        XCTAssertEqual(try firstEvent(binary)["type"] as? String, "binary")
        XCTAssertEqual(try firstEvent(binary)["sequence"] as? Int, 1)
        XCTAssertEqual(try firstEvent(close)["type"] as? String, "close")
        XCTAssertEqual(try firstEvent(close)["code"] as? Int, 1000)
        XCTAssertEqual(try firstEvent(close)["reason"] as? String, "done")

        let closed = await handler.handle(
            type: "broker.ws.close",
            payload: #"{"channelId":"\#(channelID)","code":1000,"reason":"done"}"#,
            senderID: allowedSender
        )
        XCTAssertEqual(closed.error?.code, "channel_not_found")
    }

    func testWebSocketPullEncodesEveryEventOfADrainedBatch() async throws {
        let queued = (0..<4).map {
            BrokerWebSocketEvent.frame(
                sequence: UInt64($0),
                BrokerWebSocketFrame(kind: .text, data: Data("delta-\($0)".utf8))
            )
        }
        let socket = FakeProtocolWebSocket(events: queued)
        let store = makeStore(webSocket: socket)
        let handler = makeHandler(channelStore: store)
        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        await socket.waitUntilReceiveCalls(queued.count + 1)

        let pulled = await pull(type: "broker.ws.pull", channelID: channelID, handler: handler)

        let events = try XCTUnwrap(try successResult(pulled)["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, queued.count)
        XCTAssertEqual(events.map { $0["sequence"] as? Int }, [0, 1, 2, 3])
        XCTAssertEqual(events.map { $0["type"] as? String }, ["text", "text", "text", "text"])
        XCTAssertEqual(
            events.map { $0["data"] as? String },
            (0..<4).map { Data("delta-\($0)".utf8).base64EncodedString() }
        )
    }

    func testKensingtonCanOpenItsAuthorizedPhiAgentWebSocketPath() async throws {
        let socket = FakeProtocolWebSocket(events: [])
        let recorder = BrokerWebSocketOpenRecorder()
        let store = makeStore(webSocket: socket, webSocketOpenRecorder: recorder)
        let handler = makeHandler(channelStore: store)

        let opened = await handler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/phi-agent/agents/phi-agent/kensington-user?token=token"}"#,
            senderID: kensingtonSender
        )

        XCTAssertNil(opened.error)
        XCTAssertNotNil(try successResult(opened)["channelId"] as? String)
        let lastOpen = await recorder.lastOpen()
        let recorded = try XCTUnwrap(lastOpen)
        XCTAssertEqual(recorded.path, "/phi-agent/agents/phi-agent/kensington-user?token=token")
        XCTAssertEqual(recorded.headers["X-Phi-Extension-ID"], kensingtonSender)
    }

    func testUnknownAndCrossOwnerChannelsHaveStableErrors() async throws {
        let reader = HTTPChunkReader([nil])
        let store = makeStore(httpReader: reader)
        let handler = makeHandler(channelStore: store)

        let unknown = await pull(type: "broker.stream.pull", channelID: "missing", handler: handler)
        XCTAssertEqual(unknown.error?.code, "channel_not_found")

        let opened = try await store.openHTTPStream(
            owner: BrokerSenderContext(extensionID: allowedSender, profileID: "other-profile", accountID: nil),
            request: BrokerHTTPRequest(service: .phiAgent, path: "/api/stream")
        )
        let crossOwner = await pull(type: "broker.stream.pull", channelID: opened.channelID, handler: handler)
        XCTAssertEqual(crossOwner.error?.code, "owner_mismatch")
    }

    func testPendingPullAndTerminalEventsExposeEveryStableChannelErrorCode() async throws {
        let signal = AsyncTestSignal()
        let blockedReader = HTTPChunkReader([])
        let store = makeStore(httpReader: blockedReader, pendingPull: signal)
        let handler = makeHandler(channelStore: store)
        let opened = await handler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let channelID = try XCTUnwrap(try successResult(opened)["channelId"] as? String)
        let pending = Task { await self.pull(type: "broker.stream.pull", channelID: channelID, handler: handler) }
        await signal.wait()
        let duplicate = await pull(type: "broker.stream.pull", channelID: channelID, handler: handler)
        XCTAssertEqual(duplicate.error?.code, "pull_already_pending")
        try await store.cancelHTTP(
            owner: BrokerSenderContext(
                extensionID: allowedSender,
                profileID: nil,
                accountID: "auth0|test-account",
                authRevisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            channelID: channelID
        )
        _ = await pending.value

        let flowStore = makeStore(httpReader: HTTPChunkReader([Data(repeating: 0, count: 1_025)]))
        let flowHandler = makeHandler(channelStore: flowStore)
        let flowOpened = await flowHandler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let flowChannelID = try XCTUnwrap(try successResult(flowOpened)["channelId"] as? String)
        let flow = await pull(type: "broker.stream.pull", channelID: flowChannelID, handler: flowHandler)
        XCTAssertEqual(try firstEvent(flow)["code"] as? String, "flow_control_timeout")

        let upstreamStore = makeStore(httpReader: HTTPChunkReader([], failure: TestUpstreamError()))
        let upstreamHandler = makeHandler(channelStore: upstreamStore)
        let upstreamOpened = await upstreamHandler.handle(
            type: "broker.stream.open",
            payload: #"{"path":"/api/stream","method":"GET"}"#,
            senderID: allowedSender
        )
        let upstreamChannelID = try XCTUnwrap(try successResult(upstreamOpened)["channelId"] as? String)
        let upstream = await pull(
            type: "broker.stream.pull", channelID: upstreamChannelID, handler: upstreamHandler)
        XCTAssertEqual(try firstEvent(upstream)["code"] as? String, "upstream_error")

        let protocolSocket = FakeProtocolWebSocket(events: [
            .failure(code: .protocolError, message: "failure"),
        ])
        let protocolStore = makeStore(webSocket: protocolSocket)
        let protocolHandler = makeHandler(channelStore: protocolStore)
        let protocolOpened = await protocolHandler.handle(
            type: "broker.ws.open",
            payload: #"{"path":"/ws/phi-agent/execute"}"#,
            senderID: allowedSender
        )
        let protocolChannelID = try XCTUnwrap(try successResult(protocolOpened)["channelId"] as? String)
        let protocolFailure = await pull(
            type: "broker.ws.pull", channelID: protocolChannelID, handler: protocolHandler)
        XCTAssertEqual(try firstEvent(protocolFailure)["code"] as? String, "protocol_error")
    }

    func testTransportFailuresHaveStableEnvelopeErrors() async {
        let cases: [(Error, String)] = [
            (ServiceBrokerHTTPError.responseTooLarge, "response_too_large"),
            (ServiceBrokerHTTPError.invalidResponse, "protocol_error"),
            (ServiceBrokerHTTPError.connectionClosed, "upstream_error"),
        ]
        for (error, code) in cases {
            let handler = makeHandler(error: error)
            let reply = await handler.handle(
                type: "broker.http.request",
                payload: #"{"path":"/api/health","method":"GET"}"#,
                senderID: allowedSender
            )
            XCTAssertEqual(reply.error?.code, code)
        }
    }

    private func authSnapshot(
        accountID: String,
        accessToken: String,
        generation: TimeInterval
    ) -> SharedAuthTokenSnapshot {
        let suffix = String(format: "%012lld", Int64(generation))
        let revisionID = UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        return SharedAuthTokenSnapshot(
            scope: SharedAuthScope(accountID: accountID, revisionID: revisionID),
            accessToken: accessToken
        )
    }

    private func makeHandler(
        limits: ServiceBrokerLimits? = nil,
        response: BrokerHTTPResponse = BrokerHTTPResponse(
            statusCode: 401,
            headers: [BrokerHTTPHeader(name: "content-type", value: "application/json")],
            body: Data("{}".utf8)
        ),
        error: Error? = nil,
        recorder: BrokerRequestRecorder = BrokerRequestRecorder(),
        channelStore: ServiceBrokerChannelStore? = nil,
        requestExecutor: (@Sendable (BrokerHTTPRequest) async throws -> BrokerHTTPResponse)? = nil,
        authSnapshot: SharedAuthTokenSnapshot? = SharedAuthTokenSnapshot(
            scope: SharedAuthScope(
                accountID: "auth0|test-account",
                revisionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            accessToken: "test-access-token"
        ),
        authSnapshotProvider: (@Sendable () -> SharedAuthTokenSnapshot?)? = nil,
        transportMode: SentinelTransportMode = .uds,
        transportModeProvider: (@Sendable () async throws -> SentinelTransportMode)? = nil,
        transportModeBudgetMilliseconds: Int =
            ServiceBrokerExtensionProtocol.transportModeLookupBudgetMilliseconds,
        transportModeCoolDownMilliseconds: Int =
            ServiceBrokerExtensionProtocol.transportModeLookupCoolDownMilliseconds,
        runtimeAccountID: String? = "auth0|test-account"
    ) -> ServiceBrokerExtensionProtocol {
        let resolvedLimits = limits ?? self.limits()
        let resolvedStore = channelStore ?? makeStore(httpReader: HTTPChunkReader([nil]))
        let resolvedExecutor: @Sendable (BrokerHTTPRequest) async throws -> BrokerHTTPResponse
        if let requestExecutor {
            resolvedExecutor = requestExecutor
        } else {
            resolvedExecutor = { request in
                await recorder.record(request)
                if let error { throw error }
                return response
            }
        }
        let resolvedAuthSnapshotProvider = authSnapshotProvider ?? { authSnapshot }
        // Spelled out rather than `??`: the provider is an `async throws`
        // function type, which does not infer through the coalescing operator.
        let resolvedTransportModeProvider: ServiceBrokerExtensionProtocol.TransportModeProvider
        if let transportModeProvider {
            resolvedTransportModeProvider = transportModeProvider
        } else {
            resolvedTransportModeProvider = { transportMode }
        }
        return ServiceBrokerExtensionProtocol(
            limits: resolvedLimits,
            channelStore: resolvedStore,
            runtimeAccountID: runtimeAccountID,
            requestExecutor: resolvedExecutor,
            authSnapshotProvider: resolvedAuthSnapshotProvider,
            transportModeProvider: resolvedTransportModeProvider,
            transportModeBudgetMilliseconds: transportModeBudgetMilliseconds,
            transportModeCoolDownMilliseconds: transportModeCoolDownMilliseconds
        )
    }

    private func makeStore(
        httpReader: HTTPChunkReader? = nil,
        webSocket: FakeProtocolWebSocket? = nil,
        webSocketOpenRecorder: BrokerWebSocketOpenRecorder? = nil,
        pendingPull: AsyncTestSignal? = nil
    ) -> ServiceBrokerChannelStore {
        ServiceBrokerChannelStore(
            configuration: ServiceBrokerChannelConfiguration(
                bridgeChunkBytes: 64,
                webSocketMessageBytes: 1_024,
                unacknowledgedWindowBytes: 1_024,
                pullTimeout: .seconds(1),
                idleTimeout: .seconds(10)
            ),
            httpStreamOpener: { _ in
                let reader = try XCTUnwrap(httpReader)
                return BrokerHTTPStreamSource(
                    response: BrokerHTTPResponseHead(
                        statusCode: 200,
                        headers: [BrokerHTTPHeader(name: "content-type", value: "text/event-stream")]
                    ),
                    read: { maxBytes in try await reader.read(maxBytes: maxBytes) },
                    cancel: { Task { await reader.cancel() } }
                )
            },
            webSocketOpener: { path, headers in
                if let webSocketOpenRecorder {
                    await webSocketOpenRecorder.record(path: path, headers: headers)
                }
                return try XCTUnwrap(webSocket).source
            },
            pendingPullObserver: { _ in
                guard let pendingPull else { return }
                Task { await pendingPull.signal() }
            }
        )
    }

    private func limits(
        jsonRequestBytes: Int = 1_024,
        webSocketMessageBytes: Int = 1_024,
        nonStreamingResponseBytes: Int = 1_024
    ) -> ServiceBrokerLimits {
        ServiceBrokerLimits(
            bridgeChunkBytes: 512,
            jsonRequestBytes: jsonRequestBytes,
            nonStreamingResponseBytes: nonStreamingResponseBytes,
            webSocketMessageBytes: webSocketMessageBytes,
            unacknowledgedWindowBytes: 1_024,
            stagedFileBytes: 1_024,
            stagedAccountBytes: 1_024
        )
    }

    private func pull(
        type: String,
        channelID: String,
        handler: ServiceBrokerExtensionProtocol
    ) async -> ServiceBrokerExtensionReply {
        await handler.handle(
            type: type,
            payload: #"{"channelId":"\#(channelID)"}"#,
            senderID: allowedSender
        )
    }

    private func successResult(
        _ reply: ServiceBrokerExtensionReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        XCTAssertNil(reply.error, file: file, line: line)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any],
            file: file,
            line: line
        )
        XCTAssertEqual(root["ok"] as? Bool, true, file: file, line: line)
        return try XCTUnwrap(root["result"] as? [String: Any], file: file, line: line)
    }

    private func firstEvent(
        _ reply: ServiceBrokerExtensionReply,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let result = try successResult(reply, file: file, line: line)
        let events = try XCTUnwrap(result["events"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(events.first, file: file, line: line)
    }
}

private actor BrokerRequestRecorder {
    private var requests = [BrokerHTTPRequest]()

    func record(_ request: BrokerHTTPRequest) {
        requests.append(request)
    }

    func lastRequest() -> BrokerHTTPRequest? {
        requests.last
    }

    func count() -> Int {
        requests.count
    }
}

private actor ImagePreviewBrokerLoadRecorder {
    private let response: BrokerHTTPResponse
    private var path: String?
    private var senderID: String?
    private var calls = 0

    init(response: BrokerHTTPResponse) {
        self.response = response
    }

    func load(path: String, senderID: String) throws -> BrokerHTTPResponse {
        self.path = path
        self.senderID = senderID
        calls += 1
        return response
    }

    func count() -> Int {
        calls
    }

    func lastPath() -> String? {
        path
    }

    func lastSenderID() -> String? {
        senderID
    }
}

private actor ImagePreviewBrokerAccountSwitchRecorder {
    private let response: BrokerHTTPResponse
    private var calls = 0

    init(response: BrokerHTTPResponse) {
        self.response = response
    }

    func load(path: String, senderID: String) throws -> BrokerHTTPResponse {
        calls += 1
        if calls == 1 {
            return response
        }
        throw TestUpstreamError()
    }

    func count() -> Int {
        calls
    }
}

private actor ImagePreviewBrokerABARecorder {
    private let authState: ImagePreviewAuthSnapshotBox
    private let accountB: SharedAuthTokenSnapshot
    private let accountARestored: SharedAuthTokenSnapshot
    private let accountAResponse: BrokerHTTPResponse
    private let accountBResponse: BrokerHTTPResponse
    private var requests = [BrokerHTTPRequest]()
    private var calls = 0
    private var returnedResponses = 0

    init(
        authState: ImagePreviewAuthSnapshotBox,
        accountB: SharedAuthTokenSnapshot,
        accountARestored: SharedAuthTokenSnapshot,
        accountAResponse: BrokerHTTPResponse,
        accountBResponse: BrokerHTTPResponse
    ) {
        self.authState = authState
        self.accountB = accountB
        self.accountARestored = accountARestored
        self.accountAResponse = accountAResponse
        self.accountBResponse = accountBResponse
    }

    func execute(_ request: BrokerHTTPRequest) async -> BrokerHTTPResponse {
        requests.append(request)
        calls += 1
        if calls == 1 {
            authState.set(accountB)
            await Task.yield()
            authState.set(accountARestored)
            return accountBResponse
        }
        return accountAResponse
    }

    func count() -> Int {
        calls
    }

    func recordProtocolReturn() {
        returnedResponses += 1
    }

    func protocolReturnCount() -> Int {
        returnedResponses
    }

    func authorizationHeaders() -> [String?] {
        requests.map { $0.headers["Authorization"] }
    }
}

private actor ImagePreviewBrokerTokenRotationRecorder {
    private let authState: ImagePreviewAuthSnapshotBox
    private let rotatedAuth: SharedAuthTokenSnapshot
    private let response: BrokerHTTPResponse
    private var requests = [BrokerHTTPRequest]()
    private var returnedResponses = 0

    init(
        authState: ImagePreviewAuthSnapshotBox,
        rotatedAuth: SharedAuthTokenSnapshot,
        response: BrokerHTTPResponse
    ) {
        self.authState = authState
        self.rotatedAuth = rotatedAuth
        self.response = response
    }

    func execute(_ request: BrokerHTTPRequest) async -> BrokerHTTPResponse {
        requests.append(request)
        if requests.count == 1 {
            authState.set(rotatedAuth)
            await Task.yield()
        }
        return response
    }

    func count() -> Int {
        requests.count
    }

    func recordProtocolReturn() {
        returnedResponses += 1
    }

    func protocolReturnCount() -> Int {
        returnedResponses
    }

    func authorizationHeaders() -> [String?] {
        requests.map { $0.headers["Authorization"] }
    }
}

private final class ImagePreviewAuthSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SharedAuthTokenSnapshot?
    private var reads = 0

    init(_ value: SharedAuthTokenSnapshot?) {
        self.value = value
    }

    func current() -> SharedAuthTokenSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return value
    }

    func set(_ value: SharedAuthTokenSnapshot?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func readCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}

private final class ImagePreviewAuthSnapshotSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SharedAuthTokenSnapshot?]

    init(_ values: [SharedAuthTokenSnapshot?]) {
        self.values = values
    }

    func next() -> SharedAuthTokenSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor HTTPChunkReader {
    private var chunks: [Data?]
    private var failure: (any Error)?
    private var waiters = [CheckedContinuation<Data?, Never>]()

    init(_ chunks: [Data?], failure: (any Error)? = nil) {
        self.chunks = chunks
        self.failure = failure
    }

    func read(maxBytes: Int) async throws -> Data? {
        if !chunks.isEmpty {
            return chunks.removeFirst()
        }
        if let failure {
            self.failure = nil
            throw failure
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel() {
        for waiter in waiters { waiter.resume(returning: nil) }
        waiters.removeAll()
    }
}

private actor BrokerWebSocketOpenRecorder {
    private var opens = [(path: String, headers: [String: String])]()

    func record(path: String, headers: [String: String]) {
        opens.append((path, headers))
    }

    func lastOpen() -> (path: String, headers: [String: String])? {
        opens.last
    }
}

private actor FakeProtocolWebSocket {
    private var events: [BrokerWebSocketEvent]
    private var sent = [BrokerWebSocketFrame]()
    private var waiters = [CheckedContinuation<BrokerWebSocketEvent, Never>]()
    private var receiveCalls = 0
    private var callWaiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()

    init(events: [BrokerWebSocketEvent]) {
        self.events = events
    }

    nonisolated var source: BrokerWebSocketSource {
        BrokerWebSocketSource(
            send: { frame in await self.record(frame) },
            receive: { await self.next() },
            close: { code, reason in await self.finish(code: code, reason: reason) }
        )
    }

    func sentFrames() -> [BrokerWebSocketFrame] {
        sent
    }

    /// Waits until the channel store's read loop has asked for its `count`-th
    /// frame. Call `n + 1` starts only after event `n` was queued, so this is a
    /// race-free way to observe a full queue.
    func waitUntilReceiveCalls(_ count: Int) async {
        if receiveCalls >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }

    func enqueue(_ event: BrokerWebSocketEvent) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: event)
        } else {
            events.append(event)
        }
    }

    private func record(_ frame: BrokerWebSocketFrame) {
        sent.append(frame)
    }

    private func next() async -> BrokerWebSocketEvent {
        receiveCalls += 1
        let ready = callWaiters.filter { $0.count <= receiveCalls }
        callWaiters.removeAll { $0.count <= receiveCalls }
        ready.forEach { $0.continuation.resume() }
        if !events.isEmpty {
            return events.removeFirst()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func finish(code: UInt16?, reason: String?) {
        for waiter in waiters { waiter.resume(returning: .close(code: code, reason: reason)) }
        waiters.removeAll()
    }
}

private actor AsyncTestSignal {
    private var signalled = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct TestUpstreamError: Error {}

/// Counts how many times the handshake actually reached the transport-mode
/// provider, so a test can prove lookups were coalesced or suppressed.
private actor TransportModeCallLog {
    private(set) var callCount = 0

    @discardableResult
    func record() -> Int {
        callCount += 1
        return callCount
    }
}

/// Serves a scripted sequence of transport modes and counts how many times the
/// handshake asked, so a test can prove the mode is re-read per handshake.
private actor TransportModeProbe {
    private let modes: [SentinelTransportMode]
    private(set) var callCount = 0

    init(_ modes: [SentinelTransportMode]) {
        precondition(!modes.isEmpty, "TransportModeProbe needs at least one mode")
        self.modes = modes
    }

    /// Returns the mode for this handshake, repeating the last entry once the
    /// scripted sequence is exhausted.
    func next() -> SentinelTransportMode {
        let mode = modes[min(callCount, modes.count - 1)]
        callCount += 1
        return mode
    }
}
