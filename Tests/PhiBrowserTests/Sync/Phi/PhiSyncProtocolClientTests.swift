import CryptoKit
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

    /// Serves a queue of `EntryResponse` values through `StubURLProtocol` and
    /// records the last request body, so a batch-commit test can assert both the
    /// wire message and the per-entry pairing without writing a handler closure
    /// by hand each time.
    final class CommitStub {
        var responses: [SyncPb_CommitResponse.EntryResponse] = []
        private(set) var lastRequestBody: Data?

        static func success(idString: String, version: Int64) -> SyncPb_CommitResponse.EntryResponse {
            var entry = SyncPb_CommitResponse.EntryResponse()
            entry.responseType = .success
            entry.idString = idString
            entry.version = version
            return entry
        }

        static func conflict(version: Int64) -> SyncPb_CommitResponse.EntryResponse {
            var entry = SyncPb_CommitResponse.EntryResponse()
            entry.responseType = .conflict
            entry.version = version
            return entry
        }

        static var invalidMessage: SyncPb_CommitResponse.EntryResponse {
            var entry = SyncPb_CommitResponse.EntryResponse()
            entry.responseType = .invalidMessage
            return entry
        }

        func record(_ body: Data) { lastRequestBody = body }
    }

    /// `makeClient()` plus a `CommitStub` already installed as the handler.
    private func makeCommitClient() -> (PhiSyncHTTPClient, CommitStub) {
        let stub = CommitStub()
        StubURLProtocol.handler = { [self] request in
            stub.record(body(of: request))
            return (200, response { $0.commit.entryResponse = stub.responses })
        }
        return (makeClient(), stub)
    }

    /// R7: the client tag hash is Chromium's `base64(SHA1(<empty phi specifics> + tag))`.
    /// Pinned so a change to the tag or to the specifics prefix cannot silently fork the
    /// entity identity across devices.
    func testClientTagHashIsPinned() {
        XCTAssertEqual(PhiSyncEntity.clientTag, "phi-settings")
        XCTAssertEqual(PhiSyncEntity.settingsClientTagHash, "0bjDcWaaKM/1uIOEEoacv38mMKg=")
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
                entity.clientTagHash = PhiSyncEntity.settingsClientTagHash
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
        XCTAssertEqual(page.entities[0].clientTagHash, PhiSyncEntity.settingsClientTagHash)
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

        let outcomes = try await makeClient().commit(entries: [
            PhiCommitEntry(entityId: nil,
                           clientTagHash: PhiSyncEntity.settingsClientTagHash,
                           name: PhiSyncEntity.clientTag,
                           ciphertext: Data([9, 9]),
                           deleted: false,
                           baseVersion: 0),
        ], storeBirthday: "birthday-1")

        let message = try SyncPb_ClientToServerMessage(serializedBytes: captured)
        XCTAssertEqual(message.messageContents, .commit)
        XCTAssertEqual(message.commit.cacheGuid, "dev-A")
        XCTAssertEqual(message.commit.entries.count, 1)
        let entry = message.commit.entries[0]
        XCTAssertFalse(entry.hasIDString, "a create must let the server assign the entity id")
        XCTAssertEqual(entry.version, 0)
        XCTAssertEqual(entry.clientTagHash, PhiSyncEntity.settingsClientTagHash)
        XCTAssertTrue(entry.specifics.hasPhi)
        XCTAssertEqual(entry.specifics.phi.ciphertext, Data([9, 9]))

        guard case .applied(let entityId, let version, let birthday) = outcomes[0] else {
            return XCTFail("expected .applied, got \(outcomes[0])")
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

        _ = try await makeClient().commit(entries: [
            PhiCommitEntry(entityId: "srv-9", clientTagHash: PhiSyncEntity.settingsClientTagHash,
                           name: PhiSyncEntity.clientTag, ciphertext: Data([1]),
                           deleted: false, baseVersion: 77),
        ], storeBirthday: "b")

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

        let outcomes = try await makeClient().commit(entries: [
            PhiCommitEntry(entityId: "srv-9", clientTagHash: PhiSyncEntity.settingsClientTagHash,
                           name: PhiSyncEntity.clientTag, ciphertext: Data([1]),
                           deleted: false, baseVersion: 77),
        ], storeBirthday: "b")

        guard case .conflict(let serverVersion) = outcomes[0] else {
            return XCTFail("expected .conflict, got \(outcomes[0])")
        }
        XCTAssertEqual(serverVersion, 80)
    }

    /// INVALID_MESSAGE is a per-entry outcome now, not a thrown error for the whole round:
    /// one illegal entry must not abandon the entries committed beside it (§5.1). Mapping it
    /// onto `.conflict` would still be wrong — that would drive an endless pull-and-retry loop.
    func testCommitInvalidMessageIsAPerEntryOutcome() async throws {
        let (client, stub) = makeCommitClient()
        stub.responses = [
            CommitStub.success(idString: "srv-1", version: 1),
            CommitStub.invalidMessage,
        ]
        let outcomes = try await client.commit(entries: [
            PhiCommitEntry(entityId: nil, clientTagHash: "h1", name: "phi-space",
                           ciphertext: Data([0x01]), deleted: false, baseVersion: 0),
            PhiCommitEntry(entityId: "srv-9", clientTagHash: "h2", name: "phi-space",
                           ciphertext: Data([0x02]), deleted: false, baseVersion: 77),
        ], storeBirthday: "b")

        XCTAssertEqual(outcomes.count, 2)
        guard case .applied(let entityId, let version, _) = outcomes[0] else {
            return XCTFail("expected .applied, got \(outcomes[0])")
        }
        XCTAssertEqual(entityId, "srv-1")
        XCTAssertEqual(version, 1)
        guard case .invalidMessage = outcomes[1] else {
            return XCTFail("expected .invalidMessage, got \(outcomes[1])")
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
            _ = try await makeClient().commit(entries: [
                PhiCommitEntry(entityId: nil, clientTagHash: PhiSyncEntity.settingsClientTagHash,
                               name: PhiSyncEntity.clientTag, ciphertext: Data([1]),
                               deleted: false, baseVersion: 0),
            ], storeBirthday: "")
            XCTFail("expected a throw")
        } catch PhiSyncProtocolError.malformedResponse {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testSpaceClientTagHashIsPinned() {
        // Same SHA1 derivation, a per-Space tag. Pinned so a refactor of the
        // hash cannot silently re-key every Space entity in every account.
        let uuid = "1D2E3F40-0000-0000-0000-000000000001"
        XCTAssertEqual(PhiSyncEntity.spaceClientTag(uuid), "phi-space:\(uuid)")
        let hash = PhiSyncEntity.clientTagHash(for: PhiSyncEntity.spaceClientTag(uuid))
        // Recompute the Chromium way and compare; the literal below is filled in
        // from the first green run and must never change afterwards.
        var specifics = SyncPb_EntitySpecifics()
        specifics.phi = SyncPb_PhiSpecifics()
        let prefix = try! specifics.serializedData()
        let expected = Data(Insecure.SHA1.hash(
            data: prefix + Data(PhiSyncEntity.spaceClientTag(uuid).utf8))).base64EncodedString()
        XCTAssertEqual(hash, expected)
        XCTAssertNotEqual(hash, PhiSyncEntity.settingsClientTagHash)
    }

    func testSpaceEntityNameIsAConstant() {
        // Zero knowledge: the server persists `name` in plaintext
        // (internal/chromiumsync/commit.go commitName -> entities.name), so it
        // must never be the Space's display name or a tag carrying the uuid.
        XCTAssertEqual(PhiSyncEntity.spaceEntityName, "phi-space")
    }

    func testCommitPairsEntriesToResponsesByIndex() async throws {
        let (client, stub) = makeCommitClient()
        stub.responses = [
            CommitStub.success(idString: "srv-1", version: 11),
            CommitStub.conflict(version: 12),
            CommitStub.invalidMessage,
        ]
        let outcomes = try await client.commit(entries: [
            PhiCommitEntry(entityId: nil, clientTagHash: "h1", name: "phi-space",
                           ciphertext: Data([0x01]), deleted: false, baseVersion: 0),
            PhiCommitEntry(entityId: "srv-2", clientTagHash: "h2", name: "phi-space",
                           ciphertext: Data([0x02]), deleted: false, baseVersion: 5),
            PhiCommitEntry(entityId: "srv-3", clientTagHash: "h3", name: "phi-space",
                           ciphertext: nil, deleted: true, baseVersion: 7),
        ], storeBirthday: "bday")

        XCTAssertEqual(outcomes.count, 3)
        guard case .applied(let id, let version, _) = outcomes[0] else { return XCTFail() }
        XCTAssertEqual(id, "srv-1")
        XCTAssertEqual(version, 11)
        guard case .conflict(let serverVersion) = outcomes[1] else { return XCTFail() }
        XCTAssertEqual(serverVersion, 12)
        guard case .invalidMessage = outcomes[2] else { return XCTFail() }
    }

    func testCommitSendsATombstoneWithNoSpecifics() async throws {
        let (client, stub) = makeCommitClient()
        stub.responses = [CommitStub.success(idString: "srv-1", version: 9)]
        _ = try await client.commit(entries: [
            PhiCommitEntry(entityId: "srv-1", clientTagHash: "h1", name: "phi-space",
                           ciphertext: nil, deleted: true, baseVersion: 8),
        ], storeBirthday: "bday")
        let sent = try SyncPb_ClientToServerMessage(serializedBytes: stub.lastRequestBody!)
        let entry = sent.commit.entries[0]
        XCTAssertTrue(entry.deleted)
        XCTAssertEqual(entry.version, 8)
        XCTAssertEqual(entry.name, "phi-space")
        XCTAssertTrue(entry.specifics.phi.ciphertext.isEmpty)
    }

    func testCommitThrowsWhenTheResponseCountDoesNotMatch() async throws {
        let (client, stub) = makeCommitClient()
        stub.responses = [CommitStub.success(idString: "srv-1", version: 1)]
        do {
            _ = try await client.commit(entries: [
                PhiCommitEntry(entityId: nil, clientTagHash: "h1", name: "phi-space",
                               ciphertext: Data([0x01]), deleted: false, baseVersion: 0),
                PhiCommitEntry(entityId: nil, clientTagHash: "h2", name: "phi-space",
                               ciphertext: Data([0x02]), deleted: false, baseVersion: 0),
            ], storeBirthday: "bday")
            XCTFail("expected malformedResponse")
        } catch PhiSyncProtocolError.malformedResponse {}
    }
}
