import XCTest
@testable import Phi

/// Covers the real HTTP client against the `StubURLProtocol` seam already in this target:
/// the URL it posts to, the `ClientToServerMessage` it builds, and how it reads the server's
/// `ClientToServerResponse` back.
final class PhiSyncProtocolClientTests: XCTestCase {
    private let baseURL = "https://sync.example.test"

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> PhiSyncHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return PhiSyncHTTPClient(session: URLSession(configuration: config),
                                 baseURL: baseURL,
                                 tokenProvider: { "stub-token" },
                                 deviceKeyId: "dev-A")
    }

    /// `URLProtocol` sees an uploaded body as a stream, not as `httpBody`.
    private func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }

    private func response(_ build: (inout SyncPb_ClientToServerResponse) -> Void) -> Data {
        var response = SyncPb_ClientToServerResponse()
        response.errorCode = .success
        response.storeBirthday = "birthday-1"
        build(&response)
        return (try? response.serializedData()) ?? Data()
    }

    /// R7: the client tag hash is Chromium's `base64(SHA1(<empty phi specifics> + tag))`.
    /// Pinned so a change to the tag or to the specifics prefix cannot silently fork the
    /// entity identity across devices.
    func testClientTagHashIsPinned() {
        XCTAssertEqual(PhiSyncEntity.clientTag, "phi-settings")
        XCTAssertEqual(PhiSyncEntity.clientTagHash, "0bjDcWaaKM/1uIOEEoacv38mMKg=")
        XCTAssertEqual(PhiSyncEntity.dataTypeID, 2000)
    }

    /// The profile segment `phi` is what gives the server namespace `chromium:phi`; the bare
    /// `/chromium-sync/command/` route would land Phi settings in `chromium:default`.
    func testGetUpdatesPostsToThePhiProfileRouteWithTheDeviceGuid() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString,
                           "https://sync.example.test/chromium-sync/phi/command/?client_id=dev-A")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stub-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            return (200, Data())
        }
        _ = try await makeClient().getUpdates(marker: nil, storeBirthday: "")
    }

    /// proto2 `required` fields plus the one progress marker the server iterates over.
    func testGetUpdatesSendsTheRequiredFieldsAndThePhiProgressMarker() async throws {
        var captured = Data()
        StubURLProtocol.handler = { [self] request in
            captured = body(of: request)
            return (200, response { _ in })
        }
        _ = try await makeClient().getUpdates(marker: Data("token-1".utf8), storeBirthday: "birthday-1")

        let message = try SyncPb_ClientToServerMessage(serializedBytes: captured)
        XCTAssertTrue(message.hasShare)
        XCTAssertEqual(message.share, "")
        XCTAssertTrue(message.hasMessageContents)
        XCTAssertEqual(message.messageContents, .getUpdates)
        XCTAssertTrue(message.hasProtocolVersion)
        XCTAssertEqual(message.storeBirthday, "birthday-1")
        XCTAssertEqual(message.getUpdates.fromProgressMarker.count, 1)
        XCTAssertEqual(message.getUpdates.fromProgressMarker[0].dataTypeID, 2000)
        XCTAssertEqual(message.getUpdates.fromProgressMarker[0].token, Data("token-1".utf8))
    }

    func testGetUpdatesParsesEntitiesMarkerBirthdayAndChangesRemaining() async throws {
        StubURLProtocol.handler = { [self] _ in
            (200, response { response in
                var entity = SyncPb_SyncEntity()
                entity.idString = "srv-1"
                entity.clientTagHash = PhiSyncEntity.clientTagHash
                entity.version = 42
                entity.deleted = false
                entity.specifics.phi.ciphertext = Data([1, 2, 3])
                var marker = SyncPb_DataTypeProgressMarker()
                marker.dataTypeID = 2000
                marker.token = Data("token-2".utf8)
                var updates = SyncPb_GetUpdatesResponse()
                updates.entries = [entity]
                updates.newProgressMarker = [marker]
                updates.changesRemaining = 3
                response.getUpdates = updates
            })
        }

        let page = try await makeClient().getUpdates(marker: nil, storeBirthday: "")

        XCTAssertEqual(page.entities.count, 1)
        XCTAssertEqual(page.entities[0].entityId, "srv-1")
        XCTAssertEqual(page.entities[0].clientTagHash, PhiSyncEntity.clientTagHash)
        XCTAssertEqual(page.entities[0].version, 42)
        XCTAssertEqual(page.entities[0].ciphertext, Data([1, 2, 3]))
        XCTAssertFalse(page.entities[0].deleted)
        XCTAssertEqual(page.newMarker, Data("token-2".utf8))
        XCTAssertEqual(page.storeBirthday, "birthday-1")
        XCTAssertTrue(page.changesRemaining)
    }

    /// A response that carries no phi marker must not reset the client's watermark.
    func testGetUpdatesKeepsTheOldMarkerWhenTheServerReturnsNone() async throws {
        StubURLProtocol.handler = { [self] _ in (200, response { _ in }) }
        let page = try await makeClient().getUpdates(marker: Data("token-1".utf8), storeBirthday: "")
        XCTAssertEqual(page.newMarker, Data("token-1".utf8))
        XCTAssertFalse(page.changesRemaining)
    }

    func testCommitSendsTheCiphertextUnderTheClientTag() async throws {
        var captured = Data()
        StubURLProtocol.handler = { [self] request in
            captured = body(of: request)
            return (200, response { response in
                var entry = SyncPb_CommitResponse.EntryResponse()
                entry.responseType = .success
                entry.idString = "srv-9"
                entry.version = 77
                response.commit.entryResponse = [entry]
            })
        }

        let outcome = try await makeClient().commit(entityId: nil,
                                                    clientTagHash: PhiSyncEntity.clientTagHash,
                                                    ciphertext: Data([9, 9]),
                                                    baseVersion: 0,
                                                    storeBirthday: "birthday-1")

        let message = try SyncPb_ClientToServerMessage(serializedBytes: captured)
        XCTAssertEqual(message.messageContents, .commit)
        XCTAssertEqual(message.commit.cacheGuid, "dev-A")
        XCTAssertEqual(message.commit.entries.count, 1)
        let entry = message.commit.entries[0]
        XCTAssertFalse(entry.hasIDString, "a create must let the server assign the entity id")
        XCTAssertEqual(entry.version, 0)
        XCTAssertEqual(entry.clientTagHash, PhiSyncEntity.clientTagHash)
        XCTAssertTrue(entry.specifics.hasPhi)
        XCTAssertEqual(entry.specifics.phi.ciphertext, Data([9, 9]))

        guard case .applied(let entityId, let version, let birthday) = outcome else {
            return XCTFail("expected .applied, got \(outcome)")
        }
        XCTAssertEqual(entityId, "srv-9")
        XCTAssertEqual(version, 77)
        XCTAssertEqual(birthday, "birthday-1")
    }

    func testCommitOfAnExistingEntitySendsIdAndBaseVersion() async throws {
        var captured = Data()
        StubURLProtocol.handler = { [self] request in
            captured = body(of: request)
            return (200, response { response in
                var entry = SyncPb_CommitResponse.EntryResponse()
                entry.responseType = .success
                entry.idString = "srv-9"
                entry.version = 78
                response.commit.entryResponse = [entry]
            })
        }

        _ = try await makeClient().commit(entityId: "srv-9", clientTagHash: PhiSyncEntity.clientTagHash,
                                          ciphertext: Data([1]), baseVersion: 77, storeBirthday: "b")

        let entry = try SyncPb_ClientToServerMessage(serializedBytes: captured).commit.entries[0]
        XCTAssertEqual(entry.idString, "srv-9")
        XCTAssertEqual(entry.version, 77)
    }

    func testCommitConflictCarriesTheServerVersion() async throws {
        StubURLProtocol.handler = { [self] _ in
            (200, response { response in
                var entry = SyncPb_CommitResponse.EntryResponse()
                entry.responseType = .conflict
                entry.idString = "srv-9"
                entry.version = 80
                response.commit.entryResponse = [entry]
            })
        }

        let outcome = try await makeClient().commit(entityId: "srv-9", clientTagHash: PhiSyncEntity.clientTagHash,
                                                    ciphertext: Data([1]), baseVersion: 77, storeBirthday: "b")

        guard case .conflict(let serverVersion) = outcome else {
            return XCTFail("expected .conflict, got \(outcome)")
        }
        XCTAssertEqual(serverVersion, 80)
    }

    /// INVALID_MESSAGE / TRANSIENT_ERROR must throw — mapping them onto `.conflict` would put
    /// the engine into an endless pull-and-retry loop.
    func testCommitInvalidMessageThrows() async {
        StubURLProtocol.handler = { [self] _ in
            (200, response { response in
                var entry = SyncPb_CommitResponse.EntryResponse()
                entry.responseType = .invalidMessage
                response.commit.entryResponse = [entry]
            })
        }
        do {
            _ = try await makeClient().commit(entityId: "srv-9", clientTagHash: PhiSyncEntity.clientTagHash,
                                              ciphertext: Data([1]), baseVersion: 77, storeBirthday: "b")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.commitRejected(let type) {
            XCTAssertEqual(type, .invalidMessage)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNotMyBirthdayIsItsOwnError() async {
        StubURLProtocol.handler = { _ in
            var response = SyncPb_ClientToServerResponse()
            response.errorCode = .notMyBirthday
            response.storeBirthday = "birthday-2"
            return (200, (try? response.serializedData()) ?? Data())
        }
        do {
            _ = try await makeClient().getUpdates(marker: nil, storeBirthday: "birthday-1")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.notMyBirthday {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTopLevelErrorCodeThrows() async {
        StubURLProtocol.handler = { _ in
            var response = SyncPb_ClientToServerResponse()
            response.errorCode = .partialFailure
            return (200, (try? response.serializedData()) ?? Data())
        }
        do {
            _ = try await makeClient().getUpdates(marker: nil, storeBirthday: "")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.server(let code) {
            XCTAssertEqual(code, .partialFailure)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testNon200StatusThrows() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await makeClient().getUpdates(marker: nil, storeBirthday: "")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.http(let status) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCommitWithNoEntryResponseThrows() async {
        StubURLProtocol.handler = { [self] _ in (200, response { _ in }) }
        do {
            _ = try await makeClient().commit(entityId: nil, clientTagHash: PhiSyncEntity.clientTagHash,
                                              ciphertext: Data([1]), baseVersion: 0, storeBirthday: "")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
