import CryptoKit
import Foundation
import SwiftProtobuf

// One Commit / GetUpdates round against the Phi sync backend.
//
// Endpoint: POST {baseURL}/chromium-sync/phi/command/?client_id={deviceKeyId}
//   - The literal path segment `phi` is what selects the server namespace `chromium:phi`
//     (internal/transport/sync_handler.go: NamespaceForProfile). The bare
//     /chromium-sync/command/ route falls back to `chromium:default`, the legacy namespace
//     shared with pre-profile-UUID fork builds, so it must never be used for Phi settings.
//   - The account is taken from the JWT, never from the path; `client_id` carries this
//     device's cache guid.
//   - Body and response are raw serialized protobuf (application/octet-stream).
//
// Namespace contract — agreed with the server, and documented on both sides:
//   Phi settings are an account-level store, but they do not get an account-level route. They
//   reuse the existing profile-segment route with the literal segment `phi`, so the namespace
//   goes through `NamespaceForProfile` (internal/transport/sync_handler.go) like any other and
//   comes out as `chromium:phi`. That is the namespace M3-1 ships (ruling R6), and it is what
//   sync-service now documents: docs/database.md §namespace (the `chromium:phi` row) and
//   docs/architecture.md §协议要点.
//   The consequence both sides record: **`phi` is a RESERVED profile segment.**
//   `profileIDPattern` accepts it as an ordinary profile id, so a Chromium profile literally
//   named `phi` would land in this same namespace. Real profile segments are UUIDs, so nothing
//   collides today, but any change that lets a profile id be chosen must keep `phi` out.
//
// Zero knowledge: the only payload that crosses this boundary is the domain-key-sealed
// ciphertext in `PhiSpecifics.ciphertext` (EntitySpecifics field 2000). Nothing here ever
// sees plaintext settings or key material, and nothing here is logged beyond metadata.

/// Identity of the single Phi settings entity, shared by the engine, the client and the tests.
enum PhiSyncEntity {
    /// `EntitySpecifics.phi`'s field number, which is also the sync data type id
    /// (`DataTypePhi` in the server's registry).
    static let dataTypeID: Int32 = 2000

    /// The fixed client tag. A client cannot pin its own entity id — the server assigns a
    /// UUID on create — so cross-device convergence runs entirely through the
    /// `client_tag_hash` unique index.
    static let clientTag = "phi-settings"

    /// Chromium's rule: `base64(SHA1(<serialized empty specifics for the type> + client_tag))`.
    /// The server treats it as an opaque uniqueness key, but keeping the Chromium derivation
    /// means a fork client computing it the standard way lands on the same entity.
    static let clientTagHash: String = {
        var specifics = SyncPb_EntitySpecifics()
        specifics.phi = SyncPb_PhiSpecifics()
        // Deterministic and non-throwing in practice (no required fields); the literal
        // fallback is the same three bytes: tag 2000 (0x82 0x7D), length 0.
        let prefix = (try? specifics.serializedData()) ?? Data([0x82, 0x7D, 0x00])
        return Data(Insecure.SHA1.hash(data: prefix + Data(clientTag.utf8))).base64EncodedString()
    }()
}

/// One entity as the server handed it back.
struct PhiRemoteEntity {
    let entityId: String
    let clientTagHash: String
    let version: Int64
    let ciphertext: Data
    let deleted: Bool
}

/// The four outcomes the server's per-entry response collapses to for a single-entry commit.
/// INVALID_MESSAGE / TRANSIENT_ERROR are thrown rather than represented here: only `.conflict`
/// may drive the engine's pull-and-retry loop.
enum PhiCommitOutcome {
    case applied(entityId: String, version: Int64, storeBirthday: String)
    case conflict(serverVersion: Int64?)
}

enum PhiSyncProtocolError: Error, Equatable {
    case badURL
    case http(Int)
    /// Top-level `NOT_MY_BIRTHDAY`: every persisted cursor for this account is void.
    case notMyBirthday
    case server(SyncPb_SyncEnums.ErrorType)
    case commitRejected(SyncPb_CommitResponse.ResponseType)
    case malformedResponse
}

protocol PhiSyncProtocolClient {
    /// One GetUpdates round for the phi data type. `storeBirthday` is the empty string on
    /// first contact and the server's value echoed verbatim afterwards.
    func getUpdates(marker: Data?, storeBirthday: String) async throws
        -> (entities: [PhiRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool)

    /// One single-entry Commit. `entityId` is nil (and `baseVersion` 0) for the first commit,
    /// which creates the entity under `clientTagHash`; afterwards both come from the server.
    func commit(entityId: String?, clientTagHash: String, ciphertext: Data,
                baseVersion: Int64, storeBirthday: String) async throws -> PhiCommitOutcome
}

/// The real transport. Mirrors `KeyEnvelopeAPIClient`'s shape (injected session, injected
/// async token provider, environment-resolved base URL) but posts protobuf bytes rather than
/// JSON, so it does not reuse that type's private JSON `request` helper.
final class PhiSyncHTTPClient: PhiSyncProtocolClient {
    private let session: URLSession
    private let baseURL: String
    private let tokenProvider: () async -> String?
    private let deviceKeyId: String

    init(session: URLSession = .shared,
         baseURL: String = KeyEnvelopeAPIClient.syncBaseURL,
         tokenProvider: @escaping () async -> String?,
         deviceKeyId: String) {
        self.session = session
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.deviceKeyId = deviceKeyId
    }

    func getUpdates(marker: Data?, storeBirthday: String) async throws
        -> (entities: [PhiRemoteEntity], newMarker: Data, storeBirthday: String, changesRemaining: Bool) {
        var progressMarker = SyncPb_DataTypeProgressMarker()
        progressMarker.dataTypeID = PhiSyncEntity.dataTypeID
        progressMarker.token = marker ?? Data()

        var getUpdates = SyncPb_GetUpdatesMessage()
        // The server iterates only over the markers the client sends: without this entry the
        // response carries no phi entities at all.
        getUpdates.fromProgressMarker = [progressMarker]
        getUpdates.getUpdatesOrigin = .periodic

        var message = Self.newMessage(storeBirthday: storeBirthday)
        message.messageContents = .getUpdates
        message.getUpdates = getUpdates

        let response = try await send(message)
        let updates = response.getUpdates
        let entities = updates.entries.map {
            PhiRemoteEntity(entityId: $0.idString,
                            clientTagHash: $0.clientTagHash,
                            version: $0.version,
                            ciphertext: $0.specifics.phi.ciphertext,
                            deleted: $0.deleted)
        }
        // No marker for our type means "no new watermark": keep the one we sent rather than
        // silently rewinding to a full resync.
        let newMarker = updates.newProgressMarker
            .first { $0.dataTypeID == PhiSyncEntity.dataTypeID }?.token ?? (marker ?? Data())
        AppLogInfo("[phi-sync] get_updates data_type=\(PhiSyncEntity.dataTypeID) entities=\(entities.count) changes_remaining=\(updates.changesRemaining)")
        return (entities, newMarker, response.storeBirthday, updates.changesRemaining > 0)
    }

    func commit(entityId: String?, clientTagHash: String, ciphertext: Data,
                baseVersion: Int64, storeBirthday: String) async throws -> PhiCommitOutcome {
        var entry = SyncPb_SyncEntity()
        if let entityId { entry.idString = entityId }
        entry.version = baseVersion
        entry.clientTagHash = clientTagHash
        // A stable name keeps the server's "did anything change" comparison from bumping the
        // version on an otherwise identical commit from another device.
        entry.name = PhiSyncEntity.clientTag
        entry.specifics.phi.ciphertext = ciphertext

        var commitMessage = SyncPb_CommitMessage()
        commitMessage.entries = [entry]
        commitMessage.cacheGuid = deviceKeyId

        var message = Self.newMessage(storeBirthday: storeBirthday)
        message.messageContents = .commit
        message.commit = commitMessage

        let response = try await send(message)
        guard let entryResponse = response.commit.entryResponse.first else {
            throw PhiSyncProtocolError.malformedResponse
        }
        switch entryResponse.responseType {
        case .success:
            AppLogInfo("[phi-sync] commit applied version=\(entryResponse.version) ciphertext_bytes=\(ciphertext.count)")
            return .applied(entityId: entryResponse.idString,
                            version: entryResponse.version,
                            storeBirthday: response.storeBirthday)
        case .conflict:
            AppLogInfo("[phi-sync] commit conflict base_version=\(baseVersion) server_version=\(entryResponse.version)")
            return .conflict(serverVersion: entryResponse.hasVersion ? entryResponse.version : nil)
        default:
            AppLogError("[phi-sync] commit rejected response_type=\(entryResponse.responseType)")
            throw PhiSyncProtocolError.commitRejected(entryResponse.responseType)
        }
    }

    // MARK: - Transport

    /// `share` and `message_contents` are proto2 `required`: leaving either unset makes
    /// `serializedData()` throw before a request is ever made.
    private static func newMessage(storeBirthday: String) -> SyncPb_ClientToServerMessage {
        var message = SyncPb_ClientToServerMessage()
        message.share = ""
        // Sent explicitly rather than left implicit, read from the generated proto2 default so
        // the number lives in the schema and not in this file.
        message.protocolVersion = SyncPb_ClientToServerMessage().protocolVersion
        message.storeBirthday = storeBirthday
        return message
    }

    private func send(_ message: SyncPb_ClientToServerMessage) async throws -> SyncPb_ClientToServerResponse {
        guard var components = URLComponents(string: baseURL + "/chromium-sync/phi/command/") else {
            throw PhiSyncProtocolError.badURL
        }
        components.queryItems = [URLQueryItem(name: "client_id", value: deviceKeyId)]
        guard let url = components.url else { throw PhiSyncProtocolError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(await tokenProvider() ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try message.serializedData()

        let (data, urlResponse) = try await session.data(for: request)
        let status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            AppLogError("[phi-sync] http status=\(status) body_bytes=\(data.count)")
            throw PhiSyncProtocolError.http(status)
        }

        let response = try SyncPb_ClientToServerResponse(serializedBytes: data)
        if response.hasErrorCode, response.errorCode != .success {
            if response.errorCode == .notMyBirthday {
                AppLogWarn("[phi-sync] server reported NOT_MY_BIRTHDAY; dropping the local sync cursor")
                throw PhiSyncProtocolError.notMyBirthday
            }
            AppLogError("[phi-sync] server error_code=\(response.errorCode)")
            throw PhiSyncProtocolError.server(response.errorCode)
        }
        return response
    }
}
