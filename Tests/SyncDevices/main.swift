import Foundation

final class DeviceProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct DeviceTests {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceProtocol.self]
        let session = URLSession(configuration: config)
        let client = KeyEnvelopeAPIClient(session: session, tokenProvider: { "test-token" })
        DeviceProtocol.body = Data(#"[{"device_key_id":"a","name":"Mac","platform":"macos","status":"active","created_at":"2026-09-23T01:00:00.123456Z","public_key":"unused"},{"device_key_id":"b","name":"Mac","platform":"macos","status":"revoked","created_at":"2026-09-22T01:00:00Z","revoked_at":"2026-09-23T01:00:00Z"}]"#.utf8)
        let devices = try await client.listDevices()
        precondition(devices.map(\.deviceKeyID) == ["a", "b"])
        precondition(devices[0].status == "active" && devices[1].revokedAt != nil)
        let request = DeviceProtocol.requests[0]
        precondition(request.httpMethod == "GET" && request.url?.path == "/keys/v1/devices")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
        precondition(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        DeviceProtocol.body = Data("[]".utf8)
        let empty = try await client.listDevices()
        precondition(empty.isEmpty && DeviceProtocol.requests.count == 2)
        DeviceProtocol.status = 503
        do { _ = try await client.listDevices(); preconditionFailure("503 must not become an empty list") }
        catch KeyAPIError.http(503, _) {}
        let requests = DeviceProtocol.requests.count
        let signedOut = KeyEnvelopeAPIClient(session: session, tokenProvider: { nil })
        do { _ = try await signedOut.listDevices(); preconditionFailure("nil token must fail") }
        catch KeyAPIError.transport {}
        precondition(DeviceProtocol.requests.count == requests)
        print("PASS devices: DTO, fractional dates, identities, fresh GET, empty versus failure, missing token")
    }
}
