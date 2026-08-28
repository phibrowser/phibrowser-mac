import Foundation
import XCTest
@testable import Phi

/// Fixture-driven tests for the additive `transport_mode` signal Sentinel
/// attaches to the `getComponentExports` IPC response. The exact placement is
/// chosen by Sentinel; the browser tolerates the envelope root and the exports
/// object, and treats anything it cannot recognise as `uds` (today's behaviour).
final class SentinelTransportModeTests: XCTestCase {
    func testWireValuesMatchTheSentinelContract() {
        XCTAssertEqual(SentinelTransportMode.legacy.rawValue, "legacy")
        XCTAssertEqual(SentinelTransportMode.uds.rawValue, "uds")
        XCTAssertEqual(SentinelTransportMode.fullUDS.rawValue, "full_uds")
        XCTAssertEqual(SentinelTransportMode.fallback, .uds)
    }

    func testReadsTransportModeFromTheEnvelopeRoot() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"}},"transport_mode":"legacy"}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testReadsTransportModeFromTheExportsObject() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"transport_mode":"legacy"}}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testReadsEveryDeclaredMode() throws {
        let cases: [(String, SentinelTransportMode)] = [
            ("legacy", .legacy),
            ("uds", .uds),
            ("full_uds", .fullUDS),
        ]

        for (raw, expected) in cases {
            let root = try envelope(#"{"ok":true,"result":{},"transport_mode":"\#(raw)"}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: root), expected, "root: \(raw)")

            let nested = try envelope(#"{"ok":true,"result":{"transport_mode":"\#(raw)"}}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: nested), expected, "result: \(raw)")
        }
    }

    func testAbsentTransportModeReadsAsUDS() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"phi-memory":{"api_base":"http://127.0.0.1:8790"}}}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .uds)
    }

    func testUnrecognisedTransportModeReadsAsUDS() throws {
        for raw in ["banana", "", "LEGACY", "full-uds"] {
            let response = try envelope(#"{"ok":true,"result":{},"transport_mode":"\#(raw)"}"#)
            XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .uds, "raw: \(raw)")
        }
    }

    func testNonStringTransportModeReadsAsUDS() throws {
        let number = try envelope(#"{"ok":true,"result":{},"transport_mode":7}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: number), .uds)

        let object = try envelope(#"{"ok":true,"result":{},"transport_mode":{"mode":"legacy"}}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: object), .uds)

        let null = try envelope(#"{"ok":true,"result":{},"transport_mode":null}"#)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: null), .uds)
    }

    func testUnusableEnvelopeValueFallsThroughToTheExportsObject() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"transport_mode":"legacy"},"transport_mode":"banana"}
        """#)

        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testExportsJSONIsUnaffectedByTheAddedField() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788/"},"transport_mode":"legacy"}}
        """#)
        let exportsJSON = try SentinelIPCClient.exportsJSON(fromResponse: response)

        XCTAssertEqual(
            PhiAgentEndpointResolver.parsePhiAgentApiBase(from: exportsJSON),
            "http://127.0.0.1:8788"
        )
    }

    // MARK: - The exports object handed to extensions never carries the signal

    /// `transport_mode` is a browser-facing routing signal, not a component
    /// export. It is the one key the browser removes from the exports object
    /// before forwarding it, so extensions never see a stray string among the
    /// component-ID objects.
    func testExportsJSONDropsTheTransportModeKeyFromTheExportsObject() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"transport_mode":"legacy"}}
        """#)

        let exports = try decodedExports(from: response)
        XCTAssertNil(exports["transport_mode"])
        XCTAssertNotNil(exports["phi-agent"])
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .legacy)
    }

    func testExportsJSONDropsANonStringTransportModeKeyToo() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"transport_mode":7}}
        """#)

        let exports = try decodedExports(from: response)
        XCTAssertNil(exports["transport_mode"])
        XCTAssertNotNil(exports["phi-agent"])
        XCTAssertEqual(SentinelIPCClient.transportMode(fromResponse: response), .uds)
    }

    func testExportsJSONForwardsEveryOtherComponentVerbatim() throws {
        let response = try envelope(#"""
        {"ok":true,"result":{"phi-agent":{"api_base":"http://127.0.0.1:8788"},"phi-memory":{"api_base":"http://127.0.0.1:8790"}},"transport_mode":"legacy"}
        """#)

        let exports = try decodedExports(from: response)
        XCTAssertNil(exports["transport_mode"])
        XCTAssertEqual(Set(exports.keys), ["phi-agent", "phi-memory"])
    }

    func testExportsJSONOfAnEmptyResultIsAnEmptyObject() throws {
        let response = try envelope(#"{"ok":true,"result":{},"transport_mode":"legacy"}"#)

        XCTAssertEqual(try SentinelIPCClient.exportsJSON(fromResponse: response), "{}")
    }

    // MARK: - Helpers

    private func envelope(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func decodedExports(from response: [String: Any]) throws -> [String: Any] {
        let json = try SentinelIPCClient.exportsJSON(fromResponse: response)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
