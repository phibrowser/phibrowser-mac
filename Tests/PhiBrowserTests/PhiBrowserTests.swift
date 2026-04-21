// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
import AppKit
@testable import Phi

final class PhiBrowserTests: XCTestCase {
    func testAuthFailureTraceBufferKeepsMostRecentEntries() {
        let baseDate = Date(timeIntervalSince1970: 1_713_600_000)
        var tick: TimeInterval = 0
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: {
                defer { tick += 1 }
                return baseDate.addingTimeInterval(tick)
            }
        )

        buffer.record("launch-recovery", details: ["result": "skipped"])
        buffer.record("credentials", details: ["result": "loaded"])
        buffer.record("renew", details: ["result": "failed"])

        let rendered = buffer.renderedTrace()

        XCTAssertFalse(
            rendered.contains("launch-recovery"),
            "The oldest auth trace entry should be discarded once the buffer reaches capacity."
        )
        XCTAssertTrue(rendered.contains("credentials"))
        XCTAssertTrue(rendered.contains("renew"))
    }

    func testAuthFailureTraceBufferRendersCallSiteAndSortedDetails() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 4,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_100) }
        )

        buffer.record(
            "transition-logout",
            details: [
                "operation": "renew credentials",
                "reason": "invalid_refresh_token"
            ],
            fileID: "Phi/AuthManager.swift",
            function: "logCredentialsFailure(_:operation:)",
            line: 321
        )

        let rendered = buffer.renderedTrace()

        XCTAssertTrue(rendered.contains("transition-logout"))
        XCTAssertTrue(rendered.contains("operation=renew credentials"))
        XCTAssertTrue(rendered.contains("reason=invalid_refresh_token"))
        XCTAssertTrue(rendered.contains("Phi/AuthManager.swift:321"))
        XCTAssertTrue(rendered.contains("logCredentialsFailure(_:operation:)"))
    }

    func testAuthFailureTraceBufferEmitsCallStackWhenProvided() {
        let buffer = AuthFailureTraceBuffer(
            capacity: 2,
            dateProvider: { Date(timeIntervalSince1970: 1_713_600_200) }
        )

        buffer.record(
            "transition-to-logged-out",
            details: ["reason": "invalid_refresh_token"],
            callStackSymbols: ["0  Phi  AuthManager.renew", "1  Phi  AuthManager.run"]
        )

        let rendered = buffer.renderedTrace()
        XCTAssertTrue(
            rendered.contains("stack:"),
            "Trace lines for forced-logout transitions must include the captured call stack so refresh-token reuse incidents can be correlated to the triggering caller."
        )
        XCTAssertTrue(rendered.contains("Phi  AuthManager.renew"))
    }

    func testOmniBoxSearchCoordinatorSuppressesOnlyTheNextAutomaticSearchAfterPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "https://phibrowser.com", minInputLength: 1)

        XCTAssertFalse(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com", minInputLength: 1),
            "Prefilling the current tab URL should not immediately trigger a duplicate automatic search."
        )
        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "https://phibrowser.com/path", minInputLength: 1),
            "Only the next automatic search should be suppressed so later edits still update suggestions."
        )
    }

    func testOmniBoxSearchCoordinatorAcceptsOnlyTheLatestRequest() {
        let coordinator = OmniBoxSearchCoordinator()

        let first = coordinator.beginRequest(query: "phi", source: .inputChange)
        let second = coordinator.beginRequest(query: "phibrowser", source: .openPrefill)

        XCTAssertFalse(
            coordinator.shouldApplyResponse(for: first),
            "Stale suggestion responses should be ignored once a newer request has been issued."
        )
        XCTAssertTrue(
            coordinator.shouldApplyResponse(for: second),
            "The most recent request should be the only one allowed to update the UI."
        )
    }

    func testOmniBoxSearchCoordinatorDoesNotArmSuppressionForEmptyPrefill() {
        let coordinator = OmniBoxSearchCoordinator()

        coordinator.prepareForPrefilledOpen(text: "", minInputLength: 1)

        XCTAssertTrue(
            coordinator.shouldPerformAutomaticSearch(for: "g", minInputLength: 1),
            "An empty prefill should not consume the user's first real search edit."
        )
    }

    func testOmniBoxTraceSessionFormatsReadableElapsedLogMessages() {
        var ticks: [UInt64] = [1_000_000_000, 1_125_000_000]
        let session = OmniBoxTraceSession(
            trigger: "address-bar",
            timeProvider: { ticks.removeFirst() }
        )

        let message = session.message(for: "request-start", details: "queryLength=12")

        XCTAssertTrue(message.contains("[OmniboxTrace]"))
        XCTAssertTrue(message.contains("trigger=address-bar"))
        XCTAssertTrue(message.contains("stage=request-start"))
        XCTAssertTrue(message.contains("elapsed=125.0ms"))
        XCTAssertTrue(message.contains("queryLength=12"))
    }

    func testHoverableButtonNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let button = HoverableButtonNSView(
            config: HoverableButtonConfig(title: "Test", displayMode: .titleOnly),
            action: {}
        )
        var didInvokeSecondaryAction = false
        button.secondaryAction = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        button.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Pinned extension buttons should route right clicks through their secondary action."
        )
    }

    func testHoverableViewInvokesSecondaryClickActionOnRightMouseDown() throws {
        let view = HoverableView()
        var didInvokeSecondaryClick = false
        view.secondaryClickAction = {
            didInvokeSecondaryClick = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryClick,
            "Sidebar pinned extension items should route right clicks through their secondary click action."
        )
    }

    func testSecondaryClickPassthroughNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickPassthroughNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover extension items should route right clicks through the shared secondary click passthrough."
        )
    }

    func testSecondaryClickContainerNSViewInvokesSecondaryActionOnRightMouseDown() throws {
        let view = SecondaryClickContainerNSView()
        var didInvokeSecondaryAction = false
        view.onSecondaryClick = {
            didInvokeSecondaryAction = true
        }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        view.rightMouseDown(with: try XCTUnwrap(event))
        XCTAssertTrue(
            didInvokeSecondaryAction,
            "Popover grid items should handle right clicks through their dedicated AppKit container."
        )
    }
}
