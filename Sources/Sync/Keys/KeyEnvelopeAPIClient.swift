import Foundation

enum KeyAPIError: Error { case http(Int, String), transport(Error), decode }

/// Binary fields are base64(std)-encoded strings on the wire; `kdf_params` is passed through
/// as raw JSON bytes. Note: /keys/v1 responses are NOT wrapped in the shared `Response<T>`
/// envelope (`{code,message,data}`) used elsewhere — the account state is returned at the
/// top level directly.
struct AccountKeyStateDTO: Codable {
    let recoverySalt: Data
    let kdfVersion: String
    let kdfParams: Data          // raw JSON bytes, passed through as-is
    let recoveryArkEnvelope: Data
    let arkGeneration: Int

    enum CodingKeys: String, CodingKey {
        case recoverySalt = "recovery_salt", kdfVersion = "kdf_version"
        case kdfParams = "kdf_params", recoveryArkEnvelope = "recovery_ark_envelope"
        case arkGeneration = "ark_generation"
    }
    // Custom init(from:) below suppresses the synthesized memberwise initializer, so it is
    // declared explicitly for callers (e.g. fakes in tests) that construct values directly.
    init(recoverySalt: Data, kdfVersion: String, kdfParams: Data, recoveryArkEnvelope: Data, arkGeneration: Int) {
        self.recoverySalt = recoverySalt
        self.kdfVersion = kdfVersion
        self.kdfParams = kdfParams
        self.recoveryArkEnvelope = recoveryArkEnvelope
        self.arkGeneration = arkGeneration
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        recoverySalt = try KeyEnvelopeAPIClient.b64(c, .recoverySalt)
        kdfVersion = try c.decode(String.self, forKey: .kdfVersion)
        kdfParams = try JSONSerialization.data(withJSONObject:
            try c.decode(JSONValue.self, forKey: .kdfParams).any)
        recoveryArkEnvelope = try KeyEnvelopeAPIClient.b64(c, .recoveryArkEnvelope)
        arkGeneration = try c.decode(Int.self, forKey: .arkGeneration)
    }
    func encode(to e: Encoder) throws {}  // decode-only
}

/// Request payload shape for `POST /keys/v1/devices`. Not currently encoded via `Codable`
/// (the client builds the JSON body directly), kept here to document the wire contract.
struct DeviceRegistrationDTO: Codable {
    let deviceKeyId: String
    let publicKey: Data
    let name: String
    let platform: String
    let arkEnvelope: Data?

    enum CodingKeys: String, CodingKey {
        case deviceKeyId = "device_key_id", publicKey = "public_key"
        case name, platform, arkEnvelope = "ark_envelope"
    }
}

/// Response payload shape for `GET /keys/v1/devices/{id}/envelope`.
struct DeviceEnvelopeDTO: Codable {
    let arkEnvelope: Data

    enum CodingKeys: String, CodingKey {
        case arkEnvelope = "ark_envelope"
    }
}

enum JoinRequestError: Error, Equatable { case tooManyPending, notPending, notFound, invalidRequest }

/// Response item for `GET /keys/v1/join-requests?status=pending` (no envelope).
struct JoinRequestSummaryDTO: Decodable {
    let requestId: String
    let requestingPublicKey: Data
    let name: String
    let platform: String
    let status: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", requestingPublicKey = "requesting_public_key"
        case name, platform, status, createdAt = "created_at"
    }
    init(requestId: String, requestingPublicKey: Data, name: String, platform: String, status: String, createdAt: Date) {
        self.requestId = requestId; self.requestingPublicKey = requestingPublicKey
        self.name = name; self.platform = platform; self.status = status; self.createdAt = createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        guard let pk = Data(base64Encoded: try c.decode(String.self, forKey: .requestingPublicKey)) else { throw KeyAPIError.decode }
        requestingPublicKey = pk
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(String.self, forKey: .platform)
        status = try c.decode(String.self, forKey: .status)
        guard let created = KeyEnvelopeAPIClient.parseRFC3339(try c.decode(String.self, forKey: .createdAt)) else { throw KeyAPIError.decode }
        createdAt = created
    }
}

/// Response for `GET /keys/v1/join-requests/{id}` (envelope field always present, "" until approved).
struct JoinRequestDTO: Decodable {
    let requestId: String
    let requestingPublicKey: Data
    let name: String
    let platform: String
    let status: String
    let grantedArkEnvelope: Data
    let createdAt: Date
    let resolvedByDeviceKeyId: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", requestingPublicKey = "requesting_public_key"
        case name, platform, status
        case grantedArkEnvelope = "granted_ark_envelope"
        case createdAt = "created_at", resolvedByDeviceKeyId = "resolved_by_device_key_id"
    }
    init(requestId: String, requestingPublicKey: Data, name: String, platform: String,
         status: String, grantedArkEnvelope: Data, createdAt: Date, resolvedByDeviceKeyId: String?) {
        self.requestId = requestId; self.requestingPublicKey = requestingPublicKey
        self.name = name; self.platform = platform; self.status = status
        self.grantedArkEnvelope = grantedArkEnvelope; self.createdAt = createdAt
        self.resolvedByDeviceKeyId = resolvedByDeviceKeyId
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        guard let pk = Data(base64Encoded: try c.decode(String.self, forKey: .requestingPublicKey)) else { throw KeyAPIError.decode }
        requestingPublicKey = pk
        name = try c.decode(String.self, forKey: .name)
        platform = try c.decode(String.self, forKey: .platform)
        status = try c.decode(String.self, forKey: .status)
        let rawEnv = (try c.decodeIfPresent(String.self, forKey: .grantedArkEnvelope)) ?? ""
        if rawEnv.isEmpty { grantedArkEnvelope = Data() }
        else {
            guard let e = Data(base64Encoded: rawEnv) else { throw KeyAPIError.decode }
            grantedArkEnvelope = e
        }
        guard let created = KeyEnvelopeAPIClient.parseRFC3339(try c.decode(String.self, forKey: .createdAt)) else { throw KeyAPIError.decode }
        createdAt = created
        resolvedByDeviceKeyId = try c.decodeIfPresent(String.self, forKey: .resolvedByDeviceKeyId)
    }
}

/// Response item for `GET /keys/v1/profiles`.
struct ProfileSummaryDTO: Decodable {
    let profileUuid: String
    let hasEnvelope: Bool
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case profileUuid = "profile_uuid", hasEnvelope = "has_envelope", createdAt = "created_at"
    }
    init(profileUuid: String, hasEnvelope: Bool, createdAt: Date) {
        self.profileUuid = profileUuid; self.hasEnvelope = hasEnvelope; self.createdAt = createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        profileUuid = try c.decode(String.self, forKey: .profileUuid)
        hasEnvelope = try c.decode(Bool.self, forKey: .hasEnvelope)
        guard let created = KeyEnvelopeAPIClient.parseRFC3339(try c.decode(String.self, forKey: .createdAt)) else { throw KeyAPIError.decode }
        createdAt = created
    }
}

/// Response for `GET /keys/v1/profiles/{uuid}`.
struct ProfileKeyDTO: Decodable {
    let profileUuid: String
    let profileKeyEnvelope: Data
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case profileUuid = "profile_uuid", profileKeyEnvelope = "profile_key_envelope", createdAt = "created_at"
    }
    init(profileUuid: String, profileKeyEnvelope: Data, createdAt: Date) {
        self.profileUuid = profileUuid; self.profileKeyEnvelope = profileKeyEnvelope; self.createdAt = createdAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        profileUuid = try c.decode(String.self, forKey: .profileUuid)
        guard let e = Data(base64Encoded: try c.decode(String.self, forKey: .profileKeyEnvelope)) else { throw KeyAPIError.decode }
        profileKeyEnvelope = e
        guard let created = KeyEnvelopeAPIClient.parseRFC3339(try c.decode(String.self, forKey: .createdAt)) else { throw KeyAPIError.decode }
        createdAt = created
    }
}

final class KeyEnvelopeAPIClient {
    private let session: URLSession
    private let tokenProvider: () async -> String?

    init(session: URLSession = .shared, tokenProvider: @escaping () async -> String?) {
        self.session = session
        self.tokenProvider = tokenProvider
    }

    private var baseURL: String {
        #if DEBUG
        return AuthManager.useStagingAuth0 ? "https://sync.stag.phibrowser.com" : "https://sync.phibrowser.com"
        #elseif NIGHTLY_BUILD
        return "https://sync.stag.phibrowser.com"
        #else
        return "https://sync.phibrowser.com"
        #endif
    }

    static func b64(_ c: KeyedDecodingContainer<AccountKeyStateDTO.CodingKeys>,
                    _ key: AccountKeyStateDTO.CodingKeys) throws -> Data {
        guard let d = Data(base64Encoded: try c.decode(String.self, forKey: key)) else {
            throw KeyAPIError.decode
        }
        return d
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        guard let url = URL(string: baseURL + path) else { throw KeyAPIError.decode }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(await tokenProvider() ?? "")", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await session.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch { throw KeyAPIError.transport(error) }
    }

    /// Returns `true` if the account key state was created, `false` if it already existed (409).
    func putAccount(salt: Data, kdfVersion: String, kdfParams: Data, recoveryEnvelope: Data) async throws -> Bool {
        let params = (try? JSONSerialization.jsonObject(with: kdfParams)) ?? [:]
        let (status, data) = try await request("PUT", "/keys/v1/account", body: [
            "recovery_salt": salt.base64EncodedString(),
            "kdf_version": kdfVersion,
            "kdf_params": params,
            "recovery_ark_envelope": recoveryEnvelope.base64EncodedString()])
        switch status {
        case 200, 204: return true
        case 409: return false
        default: throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Returns `nil` if the account has not been initialized yet (404).
    func getAccount() async throws -> AccountKeyStateDTO? {
        let (status, data) = try await request("GET", "/keys/v1/account")
        switch status {
        case 200: return try JSONDecoder().decode(AccountKeyStateDTO.self, from: data)
        case 404: return nil
        default: throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func postDevice(deviceKeyId: String, publicKey: Data, name: String, platform: String, arkEnvelope: Data?) async throws {
        var body: [String: Any] = [
            "device_key_id": deviceKeyId, "public_key": publicKey.base64EncodedString(),
            "name": name, "platform": platform]
        if let arkEnvelope { body["ark_envelope"] = arkEnvelope.base64EncodedString() }
        let (status, data) = try await request("POST", "/keys/v1/devices", body: body)
        guard status == 200 || status == 204 else {
            throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Returns `nil` if the device has no envelope yet (404).
    func getDeviceEnvelope(deviceKeyId: String) async throws -> Data? {
        let (status, data) = try await request("GET", "/keys/v1/devices/\(deviceKeyId)/envelope")
        switch status {
        case 200:
            let dto = try JSONDecoder().decode(DeviceEnvelopeDTO.self, from: data)
            return dto.arkEnvelope
        case 404: return nil
        default: throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func listProfiles() async throws -> [ProfileSummaryDTO] {
        let (status, data) = try await request("GET", "/keys/v1/profiles")
        guard status == 200 else { throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode([ProfileSummaryDTO].self, from: data)
    }

    /// Returns `nil` if no profile key is registered under this uuid (404).
    func getProfileKey(uuid: String) async throws -> ProfileKeyDTO? {
        let (status, data) = try await request("GET", "/keys/v1/profiles/\(uuid)")
        switch status {
        case 200: return try JSONDecoder().decode(ProfileKeyDTO.self, from: data)
        case 404: return nil
        default: throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Returns `true` if created, `false` if an envelope already exists (409) —
    /// the concurrent-registration arbitration point: the loser re-GETs and adopts.
    func putProfileKey(uuid: String, envelope: Data) async throws -> Bool {
        let (status, data) = try await request("PUT", "/keys/v1/profiles/\(uuid)",
            body: ["profile_key_envelope": envelope.base64EncodedString()])
        switch status {
        case 200, 204: return true
        case 409: return false
        default: throw KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func parseRFC3339(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // RFC3339Nano emits 1-9 fractional digits; ISO8601DateFormatter's fractional parsing is
        // unreliable across digit counts. Strip the fractional component and retry at second precision.
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            let stripped = s.replacingCharacters(in: dot..<end, with: "")
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: stripped)
        }
        return nil
    }

    private func mapJoinError(_ status: Int, _ data: Data) -> Error {
        switch status {
        case 429: return JoinRequestError.tooManyPending
        case 409: return JoinRequestError.notPending
        case 404: return JoinRequestError.notFound
        case 400: return JoinRequestError.invalidRequest
        default:  return KeyAPIError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func postJoinRequest(publicKey: Data, name: String, platform: String) async throws -> String {
        let (status, data) = try await request("POST", "/keys/v1/join-requests", body: [
            "requesting_public_key": publicKey.base64EncodedString(), "name": name, "platform": platform])
        guard status == 200 || status == 204 else { throw mapJoinError(status, data) }
        guard let obj = try? JSONDecoder().decode([String: String].self, from: data), let id = obj["request_id"] else {
            throw KeyAPIError.decode
        }
        return id
    }

    func listPendingJoinRequests() async throws -> [JoinRequestSummaryDTO] {
        let (status, data) = try await request("GET", "/keys/v1/join-requests?status=pending")
        guard status == 200 else { throw mapJoinError(status, data) }
        return try JSONDecoder().decode([JoinRequestSummaryDTO].self, from: data)
    }

    func getJoinRequest(id: String) async throws -> JoinRequestDTO {
        let (status, data) = try await request("GET", "/keys/v1/join-requests/\(id)")
        guard status == 200 else { throw mapJoinError(status, data) }
        return try JSONDecoder().decode(JoinRequestDTO.self, from: data)
    }

    func approveJoinRequest(id: String, grantedArkEnvelope: Data, resolvedByDeviceKeyId: String) async throws {
        let (status, data) = try await request("POST", "/keys/v1/join-requests/\(id)/approve", body: [
            "granted_ark_envelope": grantedArkEnvelope.base64EncodedString(),
            "resolved_by_device_key_id": resolvedByDeviceKeyId])
        guard status == 200 || status == 204 else { throw mapJoinError(status, data) }
    }

    func denyJoinRequest(id: String) async throws {
        let (status, data) = try await request("POST", "/keys/v1/join-requests/\(id)/deny")
        guard status == 200 || status == 204 else { throw mapJoinError(status, data) }
    }
}

/// Minimal JSON value type used to pass `kdf_params` through untouched.
enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String)
    case number(Double), bool(Bool), null
    var any: Any {
        switch self {
        case .object(let o): return o.mapValues { $0.any }
        case .array(let a): return a.map { $0.any }
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}
