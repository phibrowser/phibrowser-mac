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
    /// URLProtocol sees an uploaded body as a stream, not `httpBody`.
    static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

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

        // Account reset and legacy revoke: refusals are matched on the body code.
        let operation = UUID()
        DeviceProtocol.status = 200
        DeviceProtocol.body = Data(#"{"operation_id":"x","device_key_id":"a","outcome":"reset"}"#.utf8)
        try await client.resetAccount(operationId: operation, deviceKeyId: "a")
        let reset = DeviceProtocol.requests.last!
        precondition(reset.httpMethod == "PUT"
            && reset.url?.path == "/keys/v1/reset-operations/\(operation.uuidString.lowercased())")
        precondition(reset.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let sent = try JSONSerialization.jsonObject(with: Self.body(of: reset)) as? [String: String]
        precondition(sent == ["device_key_id": "a"])
        DeviceProtocol.body = Data(#"{"outcome":"something_else"}"#.utf8)
        do { try await client.resetAccount(operationId: operation, deviceKeyId: "a"); preconditionFailure("unknown outcome") }
        catch KeyAPIError.decode {}
        DeviceProtocol.status = 409
        DeviceProtocol.body = Data(#"{"code":"not_last_device","message":"another device is still active"}"#.utf8)
        do { try await client.resetAccount(operationId: operation, deviceKeyId: "a"); preconditionFailure("409") }
        catch KeyAPIError.notLastDevice {}
        DeviceProtocol.body = Data(#"{"code":"conflict","message":"x"}"#.utf8)
        do { try await client.resetAccount(operationId: operation, deviceKeyId: "a"); preconditionFailure("409") }
        catch KeyAPIError.http(409, _) {}
        DeviceProtocol.status = 404
        DeviceProtocol.body = Data(#"{"code":"device_not_found","message":"x"}"#.utf8)
        do { try await client.resetAccount(operationId: operation, deviceKeyId: "a"); preconditionFailure("404") }
        catch KeyAPIError.deviceNotFound {}
        DeviceProtocol.body = Data("404 page not found".utf8)
        do { try await client.resetAccount(operationId: operation, deviceKeyId: "a"); preconditionFailure("404") }
        catch KeyAPIError.http(404, _) {}
        DeviceProtocol.status = 409
        DeviceProtocol.body = Data(#"{"code":"last_device","message":"cannot revoke the last active device"}"#.utf8)
        do { try await client.revokeDevice(deviceKeyId: "a"); preconditionFailure("409") }
        catch KeyAPIError.lastActiveDevice {}
        DeviceProtocol.body = Data(#"{"code":"operation_conflict","message":"x"}"#.utf8)
        do { try await client.revokeDevice(deviceKeyId: "a"); preconditionFailure("409") }
        catch KeyAPIError.http(409, _) {}
        print("PASS reset: PUT path and body, outcome check, not_last_device, device_not_found, other 409/404; revoke last_device only")
    }
}
