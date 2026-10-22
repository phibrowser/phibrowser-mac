import AppKit
import Foundation
import SwiftUI

@main struct AvatarTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        let rendered = ImageRenderer(content: NotificationCardAgentAvatarView(refreshID: "fixture")).nsImage
        let bitmap = rendered?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        var visibleInterior = false
        if let bitmap {
            for x in 4..<14 { for y in 4..<14 {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visibleInterior = true }
            } }
        }
        check(visibleInterior, "missing avatar must render a local fallback inside the border")
        let invalid = await NotificationCardAgentAvatarView.loadImage { Data("not an image".utf8) }
        check(invalid == nil, "undecodable response must select fallback")
        let offline = await NotificationCardAgentAvatarView.loadImage { throw URLError(.notConnectedToInternet) }
        check(offline == nil, "network failure must select fallback")
        let rejected = await NotificationCardAgentAvatarView.loadImage { throw APIError.httpError(statusCode: 401) }
        check(rejected == nil, "HTTP failure must select fallback")
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'><rect width='18' height='18' fill='blue'/></svg>".utf8)
        let decoded = await NotificationCardAgentAvatarView.loadImage { svg }
        check(decoded?.isValid == true, "valid SVG must render instead of fallback")
        let client = APIClient()
        for source in ["/api/v1/files/test", "/v1/files/test?download=1", "http://127.0.0.1:9876/api/v1/files/test", "http://localhost:9876/v1/files/test", "http://[::1]:9876/api/v1/files/test"] {
            client.avatarURL = source
            client.paths = []
            do {
                let payload = try await client.getAgentAvatarImageData()
                check(payload.data == Data("image".utf8), "service bytes must reach caller")
                check(client.paths.first?.hasPrefix("/api/v1/files/") == true || client.paths.first?.hasPrefix("/v1/files/") == true, "service receives a file path")
                check(client.paths.count == 1, "file must use service transport: \(source)")
            } catch { check(false, "service avatar failed: \(source)") }
        }
        check(APIClient.agentAvatarFilePath("http://127.0.0.2:9876/api/v1/files/test%20name?download=1") == "/api/v1/files/test%20name?download=1", "retain encoded path and query")
        for source in ["//images.example.invalid/api/v1/files/test", "http://127.0.0.1.evil.invalid/api/v1/files/test", "https://images.example.invalid/api/v1/files/test", "/api/v1/account", "http://user:password@localhost/api/v1/files/test"] {
            check(APIClient.agentAvatarFilePath(source) == nil, "unrelated URL must not use service auth")
        }
        for source in ["data:image/png;base64,aW1hZ2U=", "data:image/svg+xml,%3Csvg%2F%3E"] {
            client.avatarURL = source
            client.paths = []
            do {
                let result = try await client.getAgentAvatarImageData()
                check(!result.data.isEmpty && client.paths.isEmpty, "data URLs must decode locally")
            } catch { check(false, "data URL failed") }
        }
        _ = URLProtocol.registerClass(ExternalImageProtocol.self)
        client.avatarURL = "https://images.example.invalid/api/v1/files/test"
        do {
            _ = try await client.getAgentAvatarImageData()
            check(ExternalImageProtocol.authorization == nil, "external image must not receive Phi Bearer")
        } catch { check(false, "external image request failed") }
        print("Avatar tests: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

final class ExternalImageProtocol: URLProtocol {
    static var authorization: String?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "images.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("image".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
