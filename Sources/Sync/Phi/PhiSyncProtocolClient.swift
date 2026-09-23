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
//   docs/architecture.md §Protocol essentials.
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

    /// The fixed client tag of the single settings entity (M3-1). A client cannot pin its own
    /// entity id — the server assigns a UUID on create — so cross-device convergence runs
    /// entirely through the `client_tag_hash` unique index.
    static let clientTag = "phi-settings"

    /// One Space = one entity, tagged `phi-space:<space_uuid>`. The SHA1 prefix
    /// (the serialized empty specifics) is per DATA TYPE, not per entity, so
    /// Spaces staying on 2000 changes nothing about the derivation.
    static let spaceTagPrefix = "phi-space:"
    static func spaceClientTag(_ spaceUuid: String) -> String { spaceTagPrefix + spaceUuid }

    /// The plaintext name the server persists for EVERY phi Space entity
    /// (`commitName` -> `entities.name`). A constant, so zero knowledge holds
    /// and the server's `IS DISTINCT FROM` idempotence check still works.
    static let spaceEntityName = "phi-space"

    /// One bookmark/folder per entity, tagged phi-bookmark:bookmark_uuid. The SHA1 prefix from empty
    /// EntitySpecifics{phi:{}} is datatype-wide and shared by kinds.
    static let bookmarkTagPrefix = "phi-bookmark:"
    static func bookmarkClientTag(_ uuid: String) -> String { bookmarkTagPrefix + uuid }
    /// Constant per-kind plaintext entities.name on the server, preserving zero knowledge and idempotency.
    static let bookmarkEntityName = "phi-bookmark"

    /// Pin identity includes lineage and owner (R-M3-3-15), so both enter the tag; one lineage across N Spaces
    /// means N entities. Normalize lineage with PinKind.lineageKey first, matching index seeds and landing.
    /// Uppercase input yields an incompatible hash and §2.5 rejects every pin as forged.
    static let pinTagPrefix = "phi-pin:"
    static func pinClientTag(_ lineage: String, ownerKey: String) -> String {
        pinTagPrefix + lineage + ":" + ownerKey
    }
    static let pinEntityName = "phi-pin"

    /// One URL Rule per entity, tagged phi-urlrule:rule_uuid. Identity is only rule_uuid, excluding target
    /// Space (D13), so this single-argument API matches Space/bookmark tags rather than pin's owner-dependent
    /// tag.
    static let urlRuleTagPrefix = "phi-urlrule:"
    static func urlRuleClientTag(_ uuid: String) -> String { urlRuleTagPrefix + uuid }
    /// Constant per-kind plaintext entities.name on the server, preserving zero knowledge and idempotency.
    static let urlRuleEntityName = "phi-urlrule"

    /// Chromium's rule: `base64(SHA1(<serialized empty specifics for the type> + client_tag))`.
    /// The server treats it as an opaque uniqueness key, but keeping the Chromium derivation
    /// means a fork client computing it the standard way lands on the same entity.
    static func clientTagHash(for tag: String) -> String {
        var specifics = SyncPb_EntitySpecifics()
        specifics.phi = SyncPb_PhiSpecifics()
        // Deterministic and non-throwing in practice (no required fields); the literal
        // fallback is the same three bytes: tag 2000 (0x82 0x7D), length 0.
        let prefix = (try? specifics.serializedData()) ?? Data([0x82, 0x7D, 0x00])
        return Data(Insecure.SHA1.hash(data: prefix + Data(tag.utf8))).base64EncodedString()
    }

    /// Renamed from `clientTagHash` now that the derivation is parameterized.
    /// Its VALUE is unchanged and pinned by test.
    static let settingsClientTagHash: String = clientTagHash(for: clientTag)
}

/// One entity as the server handed it back.
struct PhiRemoteEntity {
    let entityId: String
    let clientTagHash: String
    let version: Int64
    let ciphertext: Data
    let deleted: Bool
}

/// One entry of a batch commit. `ciphertext == nil` + `deleted == true` is a
/// tombstone: the server backfills the type's default specifics itself.
struct PhiCommitEntry {
    let entityId: String?      // nil on create
    let clientTagHash: String
    /// Per-kind plaintext server entities.name constant: phi-settings, phi-space, phi-bookmark, phi-pin or
    /// phi-urlrule.
    let name: String
    let ciphertext: Data?      // nil for a tombstone
    let deleted: Bool
    let baseVersion: Int64     // 0 on create
}

/// What the server's per-entry response collapses to. Only `.conflict` may drive the engine's
/// pull-and-retry loop.
enum PhiCommitOutcome {
    case applied(entityId: String, version: Int64, storeBirthday: String)
    /// `entityId` is the live row the server refused to write over, when it named one: a create
    /// whose client tag already matches a live row holding different content is answered with
    /// that row's identity and version, so the engine can retry as an update instead of a
    /// second create. Both stay nil when the response carried neither.
    case conflict(entityId: String?, serverVersion: Int64?)
    /// Per-entry now, not a thrown error: one bad entry must not abandon the
    /// other twenty-four in the batch (§5.1).
    case invalidMessage
    case rejected(SyncPb_CommitResponse.ResponseType)
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

    /// A batch commit. Outcomes are paired to `entries` BY INDEX -- the server
    /// allocates `responses` at `len(entries)`, fills illegal entries in place
    /// and writes each store result back at its own index
    /// (`internal/chromiumsync/commit.go:112-136`). A different count is a
    /// broken peer, not a partial success, so it throws.
    ///
    /// An entry's `entityId` is nil (and `baseVersion` 0) for the first commit of that entity,
    /// which creates it under `clientTagHash`; afterwards both come from the server.
    func commit(entries: [PhiCommitEntry], storeBirthday: String) async throws -> [PhiCommitOutcome]

    /// AM-2: the `Date` response header of the most recent SUCCESSFUL GetUpdates or Commit, as
    /// epoch milliseconds, or nil when the header was absent or unparseable.
    ///
    /// A property rather than a third return value on both calls: the engine reads it
    /// immediately after each round, the transport is the only thing that can know it, and
    /// widening two tuples would change every call site for a value only the clock uses.
    /// Pull-before-commit guarantees the engine has seen a fresh one before any commit is sent.
    ///
    /// The default is nil, so a client that models only the protocol (the engine tests' fake)
    /// leaves the correction off and behaves exactly as it did before AM-2.
    var lastServerDateMs: Int64? { get }
}

extension PhiSyncProtocolClient {
    var lastServerDateMs: Int64? { nil }
}

/// The real transport. Mirrors `KeyEnvelopeAPIClient`'s shape (injected session, injected
/// async token provider, environment-resolved base URL) but posts protobuf bytes rather than
/// JSON, so it does not reuse that type's private JSON `request` helper.
final class PhiSyncHTTPClient: PhiSyncProtocolClient {
    private let session: URLSession
    private let baseURL: String
    private let tokenProvider: () async -> String?
    private let deviceKeyIDProvider: () async throws -> String

    /// AM-2. Written by `send` on every 200 that parsed, so a failed round leaves the previous
    /// estimate in place rather than erasing it.
    private(set) var lastServerDateMs: Int64?

    init(session: URLSession = .shared,
         baseURL: String = KeyEnvelopeAPIClient.syncBaseURL,
         tokenProvider: @escaping () async -> String?,
         deviceKeyId: String,
         deviceKeyIDProvider: (() async throws -> String)? = nil) {
        self.session = session
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.deviceKeyIDProvider = deviceKeyIDProvider ?? { deviceKeyId }
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

    func commit(entries: [PhiCommitEntry], storeBirthday: String) async throws -> [PhiCommitOutcome] {
        guard !entries.isEmpty else { return [] }
        var commitMessage = SyncPb_CommitMessage()
        commitMessage.entries = entries.map { entry in
            var wire = SyncPb_SyncEntity()
            if let entityId = entry.entityId { wire.idString = entityId }
            wire.version = entry.baseVersion
            wire.clientTagHash = entry.clientTagHash
            // A stable name keeps the server's "did anything change" comparison from bumping
            // the version on an otherwise identical commit from another device — which is why
            // it is a per-type constant and never a user-visible string.
            wire.name = entry.name
            // Set only when true, so a live commit's bytes stay exactly what they were before
            // the field existed here (proto2 serializes any explicitly-set field, default or not).
            if entry.deleted { wire.deleted = true }
            if let ciphertext = entry.ciphertext {
                wire.specifics.phi.ciphertext = ciphertext
            }
            return wire
        }
        commitMessage.cacheGuid = try await deviceKeyIDProvider()

        var message = Self.newMessage(storeBirthday: storeBirthday)
        message.messageContents = .commit
        message.commit = commitMessage

        let response = try await send(message)
        let responses = response.commit.entryResponse
        guard responses.count == entries.count else {
            AppLogError("[phi-sync] commit response count \(responses.count) != \(entries.count)")
            throw PhiSyncProtocolError.malformedResponse
        }
        let outcomes: [PhiCommitOutcome] = responses.map { entryResponse in
            switch entryResponse.responseType {
            case .success:
                return .applied(entityId: entryResponse.idString,
                                version: entryResponse.version,
                                storeBirthday: response.storeBirthday)
            case .conflict:
                // An empty id_string carries no identity — read it exactly as `.applied` does,
                // so it can never overwrite a cursor's own id with nothing.
                return .conflict(entityId: entryResponse.idString.isEmpty ? nil : entryResponse.idString,
                                 serverVersion: entryResponse.hasVersion ? entryResponse.version : nil)
            case .invalidMessage:
                return .invalidMessage
            default:
                return .rejected(entryResponse.responseType)
            }
        }
        let applied = outcomes.filter { if case .applied = $0 { return true } else { return false } }.count
        AppLogInfo("[phi-sync] commit entries=\(entries.count) applied=\(applied) bytes=\(entries.compactMap(\.ciphertext).reduce(0) { $0 + $1.count })")
        return outcomes
    }

    // MARK: - Transport

    func streamInvalidations(receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        try await PhiSyncInvalidationHTTPStream.run(session: session, baseURL: baseURL,
                                                    deviceID: try await deviceKeyIDProvider(), tokenProvider: tokenProvider,
                                                    receive: receive)
    }

    /// The three HTTP-date formats RFC 7231 §7.1.1.1 requires a recipient to accept: the
    /// preferred IMF-fixdate, and the two obsolete forms (RFC 850 and asctime) a proxy or an
    /// older intermediary may still emit. All three are fixed-width C-locale formats, so they are
    /// parsed with `en_US_POSIX` and GMT and never with the device's locale or time zone —
    /// reading a server clock through the user's calendar is how this would silently start
    /// returning dates that are out by hours on exactly the devices AM-2 exists for.
    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",     // Sun, 06 Nov 1994 08:49:37 GMT
        "EEEE, dd-MMM-yy HH:mm:ss zzz",      // Sunday, 06-Nov-94 08:49:37 GMT
        "EEE MMM d HH:mm:ss yyyy",           // Sun Nov  6 08:49:37 1994
    ]

    private static let httpDateParsers: [DateFormatter] = httpDateFormats.map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = format
        return formatter
    }

    /// AM-2: an HTTP-date header as epoch milliseconds; nil when it is absent or unparseable.
    /// Internal rather than private so the header contract is pinned by its own test.
    static func serverDateMs(from header: String?) -> Int64? {
        guard let header, !header.isEmpty else { return nil }
        // asctime pads a single-digit day with a second space ("Sun Nov  6 ..."), which the
        // fixed literal space in the pattern does not match. Collapsing runs of spaces is safe
        // for the other two forms, which contain no double space.
        let normalized = header.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        for parser in httpDateParsers {
            guard let date = parser.date(from: normalized) else { continue }
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
        return nil
    }

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
        components.queryItems = [URLQueryItem(name: "client_id", value: try await deviceKeyIDProvider())]
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
        // AM-2: record the server's clock before the error branches. A NOT_MY_BIRTHDAY or a
        // typed server error is still a well-formed 200 whose `Date` header is as good an
        // estimate as any other; only a transport failure leaves the previous one standing.
        lastServerDateMs = Self.serverDateMs(
            from: (urlResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"))
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
