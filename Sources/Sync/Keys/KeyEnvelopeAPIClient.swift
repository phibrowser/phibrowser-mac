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
