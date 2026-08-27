import Foundation
import XCTest
@testable import Phi

/// Route resolution for in-app phi-agent callers: `PhiAgentEndpointResolver`
/// turns the transport mode Sentinel reports into the concrete route a caller
/// must use, and keeps the single-flight caching the base-URL lookup had.
final class PhiAgentEndpointResolverRouteTests: XCTestCase {
    func testLegacyModeResolvesToTheLoopbackBaseURL() async throws {
        let resolver = makeResolver(apiBase: "http://127.0.0.1:9788/", transportMode: .legacy)

        let route = try await resolver.currentRoute()

        XCTAssertEqual(route, .loopback(baseURL: "http://127.0.0.1:9788"))
    }

    func testBrokerModesResolveToTheAccountScopedSocket() async throws {
        for mode in [SentinelTransportMode.uds, .fullUDS] {
            let requestedAccountIDs = PhiAgentProviderLog()
            let resolver = makeResolver(
                transportMode: mode,
                accountID: "auth0|link",
                socketPathProvider: { accountID in
                    _ = requestedAccountIDs.record(accountID)
                    return "/tmp/phi-link-\(accountID).sock"
                }
            )

            let route = try await resolver.currentRoute()

            XCTAssertEqual(
                route,
                .broker(socketPath: "/tmp/phi-link-auth0|link.sock"),
                "mode: \(mode.rawValue)"
            )
            XCTAssertEqual(requestedAccountIDs.values, ["auth0|link"], "mode: \(mode.rawValue)")
        }
    }

    func testExportsFailureResolvesToTheBrokerRoute() async throws {
        let resolver = makeResolver(
            exportsFailure: .unavailable,
            accountID: "auth0|link",
            socketPathProvider: { _ in "/tmp/phi-link-fallback.sock" }
        )

        let route = try await resolver.currentRoute()

        XCTAssertEqual(route, .broker(socketPath: "/tmp/phi-link-fallback.sock"))
    }

    func testBrokerRouteWithoutAnAccountThrowsAccountUnavailable() async {
        for accountID in [nil, ""] as [String?] {
            let resolver = makeResolver(transportMode: .uds, accountID: accountID)

            await assertAccountUnavailable("account: \(accountID ?? "nil")") {
                _ = try await resolver.currentRoute()
            }
        }
    }

    func testBrokerRouteWithoutASocketPathThrowsAccountUnavailable() async {
        let resolver = makeResolver(
            transportMode: .uds,
            accountID: "auth0|link",
            socketPathProvider: { _ in nil }
        )

        await assertAccountUnavailable {
            _ = try await resolver.currentRoute()
        }
    }

    func testInvalidateForcesAFreshLookup() async throws {
        let log = PhiAgentProviderLog()
        let resolver = makeResolver(transportMode: .uds, exportsLog: log)

        _ = try await resolver.currentRoute()
        _ = try await resolver.currentRoute()
        XCTAssertEqual(log.count, 1)

        await resolver.invalidate()
        _ = try await resolver.currentRoute()

        XCTAssertEqual(log.count, 2)
    }

    func testConcurrentRouteLookupsShareOneProviderInvocation() async throws {
        let log = PhiAgentProviderLog()
        let resolver = makeResolver(
            transportMode: .uds,
            exportsDelay: .milliseconds(50),
            exportsLog: log
        )

        async let first = resolver.currentRoute()
        async let second = resolver.currentRoute()
        let routes = try await [first, second]

        XCTAssertEqual(routes.first, routes.last)
        XCTAssertEqual(log.count, 1)
    }

    // MARK: - Helpers

    private func makeResolver(
        apiBase: String? = "http://127.0.0.1:9788",
        transportMode: SentinelTransportMode = .uds,
        exportsFailure: PhiAgentProviderFailure? = nil,
        exportsDelay: Duration? = nil,
        exportsLog: PhiAgentProviderLog? = nil,
        accountID: String? = "auth0|link",
        socketPathProvider: (@Sendable (String) -> String?)? = nil
    ) -> PhiAgentEndpointResolver {
        let exportsJSON = apiBase.map { #"{"phi-agent":{"api_base":"\#($0)"}}"# } ?? "{}"
        return PhiAgentEndpointResolver(
            exportsProvider: {
                _ = exportsLog?.record("exports")
                if let exportsDelay {
                    try? await Task.sleep(for: exportsDelay)
                }
                if let exportsFailure {
                    throw exportsFailure
                }
                return SentinelComponentExports(
                    exportsJSON: exportsJSON,
                    transportMode: transportMode
                )
            },
            accountIDProvider: { accountID },
            socketPathProvider: socketPathProvider ?? { _ in "/tmp/phi-link-test.sock" }
        )
    }

    private func assertAccountUnavailable(
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected PhiAgentTransportError.accountUnavailable. \(message)", file: file, line: line)
        } catch let error as PhiAgentTransportError {
            guard case .accountUnavailable = error else {
                return XCTFail("Expected .accountUnavailable, got \(error). \(message)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected .accountUnavailable, got \(error). \(message)", file: file, line: line)
        }
    }
}

enum PhiAgentProviderFailure: Error {
    case unavailable
}

/// Thread-safe record of the values a resolver provider was called with.
/// Providers run on whichever executor resolution happens to use, so the
/// counting itself must not race with the assertions.
final class PhiAgentProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    /// Appends `value` and returns the number of records made so far.
    @discardableResult
    func record(_ value: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(value)
        return recorded.count
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var count: Int { values.count }
}
