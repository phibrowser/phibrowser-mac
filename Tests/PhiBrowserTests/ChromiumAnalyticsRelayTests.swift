// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Locks the relay rules for Chromium-originated analytics events: reserved
/// PostHog names are rejected, accepted events are provenance-stamped and
/// logged, and the SDK call is skipped when PostHog was never initialized.
/// The relay is driven through its public entry with an injected capture
/// closure — no network, no SDK setup.
@MainActor
final class ChromiumAnalyticsRelayTests: XCTestCase {
    private var capturedEvents: [(name: String, properties: [String: Any])] = []
    private var loggedLines: [String] = []

    override func setUp() {
        super.setUp()
        capturedEvents = []
        loggedLines = []
    }

    private func makeRelay(isPostHogInitialized: Bool = true) -> ChromiumAnalyticsRelay {
        ChromiumAnalyticsRelay(
            isPostHogInitialized: { isPostHogInitialized },
            capture: { name, properties in
                self.capturedEvents.append((name: name, properties: properties))
            },
            logger: { self.loggedLines.append($0) }
        )
    }

    // MARK: - Reserved-name rule

    func testReservedNameIsDroppedWithLog() {
        let relay = makeRelay()

        relay.relay(eventName: "$app_opened", module: "memory_saver", properties: [:])

        XCTAssertTrue(capturedEvents.isEmpty)
        XCTAssertEqual(loggedLines.count, 1)
        XCTAssertTrue(loggedLines[0].contains("dropped"))
        XCTAssertTrue(loggedLines[0].contains("$app_opened"))
    }

    // MARK: - Provenance stamping

    func testAcceptedEventCarriesSourceAndModuleWithPropertiesIntact() {
        let relay = makeRelay()

        relay.relay(
            eventName: "memory_saver_state",
            module: "memory_saver",
            properties: ["enabled": true, "aggressiveness": "medium"]
        )

        XCTAssertEqual(capturedEvents.count, 1)
        XCTAssertEqual(capturedEvents[0].name, "memory_saver_state")
        let properties = capturedEvents[0].properties
        XCTAssertEqual(properties["source"] as? String, "chromium")
        XCTAssertEqual(properties["module"] as? String, "memory_saver")
        XCTAssertEqual(properties["enabled"] as? Bool, true)
        XCTAssertEqual(properties["aggressiveness"] as? String, "medium")
    }

    func testStampsOverrideCallerSuppliedSourceAndModule() {
        let relay = makeRelay()

        relay.relay(
            eventName: "memory_saver_state",
            module: "memory_saver",
            properties: ["source": "forged", "module": "forged"]
        )

        XCTAssertEqual(capturedEvents.count, 1)
        XCTAssertEqual(capturedEvents[0].properties["source"] as? String, "chromium")
        XCTAssertEqual(capturedEvents[0].properties["module"] as? String, "memory_saver")
    }

    // MARK: - Accepted-capture log

    func testAcceptedCaptureProducesLogLine() {
        let relay = makeRelay()

        relay.relay(eventName: "memory_saver_state", module: "memory_saver", properties: [:])

        XCTAssertEqual(loggedLines.count, 1)
        XCTAssertTrue(loggedLines[0].contains("accepted"))
        XCTAssertTrue(loggedLines[0].contains("memory_saver/memory_saver_state"))
    }

    // MARK: - Uninitialized PostHog

    func testUninitializedPostHogSkipsSDKButStillLogsAcceptance() {
        let relay = makeRelay(isPostHogInitialized: false)

        relay.relay(eventName: "memory_saver_state", module: "memory_saver", properties: [:])

        // The SDK call is the only thing gated on initialization: the accepted
        // log line must still appear — it is the end-to-end observable on
        // local builds, which carry no PostHog token.
        XCTAssertTrue(capturedEvents.isEmpty)
        XCTAssertEqual(loggedLines.count, 1)
        XCTAssertTrue(loggedLines[0].contains("accepted"))
    }
}
