import Foundation
import Observation

@MainActor
@Observable
final class ApplicationState {
    static let shared = ApplicationState()
    var isAuthenticated = true
    var isGuest = false
}

final class AuthManager {
    static let shared = AuthManager()
    func getAccessTokenSyncly() -> String? { "fixture-token" }
}

func AppLogDebug(_ message: String) {}

struct PhiAgentHTTPRequest {
    var path: String
    var method: String
    var headers: [String: String]
    var body: Data?
}

struct PhiAgentHTTPResponse {
    var statusCode: Int
    var body: Data
}

final class PhiAgentTransport {
    static let shared = PhiAgentTransport()
    var requests: [PhiAgentHTTPRequest] = []
    var handler: @MainActor (PhiAgentHTTPRequest) async throws -> PhiAgentHTTPResponse = { _ in
        throw URLError(.badServerResponse)
    }

    @MainActor
    func send(_ request: PhiAgentHTTPRequest) async throws -> PhiAgentHTTPResponse {
        requests.append(request)
        return try await handler(request)
    }
}

enum PhiAgentTransportError: Error {
    case accountUnavailable
    case unreachable
    case invalidResponse
}
