// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class ImagePreviewMessageHandlerTests: XCTestCase {
    private final class TestMessenger: ExtensionMessagingProtocol {
        var responses: [(response: String, requestId: String)] = []
        var errors: [(error: String, requestId: String)] = []
        var broadcasts: [(type: String, payload: String)] = []

        func sendResponse(_ response: String, requestId: String) {
            responses.append((response, requestId))
        }

        func sendError(_ error: String, requestId: String) {
            errors.append((error, requestId))
        }

        func broadcast(type: String, payload: String) {
            broadcasts.append((type, payload))
        }
    }

    private func context(
        _ payload: String,
        requestID: String = "preview-request",
        senderID: String = "test-extension"
    ) -> ExtensionMessageContext {
        ExtensionMessageContext(type: "imagePreview", payload: payload,
                                requestId: requestID, senderId: senderID)
    }

    func testRepliesOnceAfterOpeningWithoutWaitingForImageLoading() {
        let messenger = TestMessenger()
        var opens = 0
        ImagePreviewMessageHandler.handle(
            context(#"{"windowId":42,"items":["https://example.com/image.png"],"currentIndex":0}"#),
            messenger: messenger
        ) { items, index in
            opens += 1
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.source, .remoteURL(URL(string: "https://example.com/image.png")!))
            XCTAssertEqual(index, 0)
            XCTAssertTrue(messenger.responses.isEmpty, "Do not acknowledge before opening the preview")
        }

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(messenger.responses.count, 1)
        XCTAssertEqual(messenger.responses.first?.response, "{}")
        XCTAssertEqual(messenger.responses.first?.requestId, "preview-request")
        XCTAssertTrue(messenger.errors.isEmpty)
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testRequestsAlwaysOpenStandalonePreviewAndPreserveAuthorizedItems() throws {
        let senderID = "fenmfiepnpdlhplemgijlimpbebebljo"
        for windowID in [42, -1] {
            let messenger = TestMessenger()
            let existingWindows = Set(NSApp.windows.map { ObjectIdentifier($0) })
            ImagePreviewMessageHandler.handle(
                context(
                    #"{"windowId":\#(windowID),"items":["/tmp/preview-first.png","/api/v1/files/preview-second.png"],"currentIndex":99}"#,
                    senderID: senderID
                ),
                messenger: messenger
            )

            let previews = NSApp.windows.filter {
                !existingWindows.contains(ObjectIdentifier($0))
            }.compactMap {
                $0.windowController as? ImagePreviewWindowController
            }
            XCTAssertEqual(previews.count, 1)
            let controller = try XCTUnwrap(previews.first)
            defer { controller.close() }
            XCTAssertTrue(try XCTUnwrap(controller.window).isVisible)
            XCTAssertEqual(controller.state.items.count, 2)
            XCTAssertEqual(controller.state.currentIndex, 1)
            XCTAssertEqual(controller.state.activeItem?.source, .phiAgentFile(
                path: "/api/v1/files/preview-second.png", senderID: senderID
            ))
            XCTAssertEqual(messenger.responses.count, 1)
            XCTAssertEqual(messenger.responses.first?.response, "{}")
            XCTAssertEqual(messenger.responses.first?.requestId, "preview-request")
            XCTAssertTrue(messenger.errors.isEmpty)
            XCTAssertTrue(messenger.broadcasts.isEmpty)
        }
    }

    func testMalformedPayloadsRejectWithoutOpeningOrEchoingPrivateData() {
        for payload in [
            "not JSON",
            #"{"windowId":"invalid","items":["https://private.example/image?token=secret"],"currentIndex":0}"#,
            #"{"windowId":42,"items":[17],"currentIndex":0}"#,
            #"{"windowId":42,"items":["https://example.com/image.png"]}"#,
        ] {
            let messenger = TestMessenger()
            ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { _, _ in
                XCTFail("Malformed payload must not open a preview")
            }

            XCTAssertTrue(messenger.responses.isEmpty)
            XCTAssertEqual(messenger.errors.count, 1)
            XCTAssertEqual(messenger.errors.first?.error, "Invalid image preview payload")
            XCTAssertEqual(messenger.errors.first?.requestId, "preview-request")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
        }
    }

    func testEmptyAndBlankItemsRejectWithoutOpening() {
        for items in [#"[]"#, #"["", "  "]"#] {
            let messenger = TestMessenger()
            let payload = #"{"windowId":42,"items":\#(items),"currentIndex":0}"#
            ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { _, _ in
                XCTFail("Empty previews must not be acknowledged as opened")
            }

            XCTAssertTrue(messenger.responses.isEmpty)
            XCTAssertEqual(messenger.errors.count, 1)
            XCTAssertEqual(messenger.errors.first?.error, "No image preview items provided")
            XCTAssertEqual(messenger.errors.first?.requestId, "preview-request")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
        }
    }

    func testLegacyItemsRemainSupportedAndIndexIsPassedToPreviewState() {
        let messenger = TestMessenger()
        let payload = #"{"windowId":42,"items":[{"source":{"type":"url","url":"https://example.com/one.png"}},{"type":"file","path":"/tmp/preview-fixture.png"}],"currentIndex":99}"#
        ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { items, index in
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].source, .remoteURL(URL(string: "https://example.com/one.png")!))
            XCTAssertEqual(items[1].source, .localFile(URL(fileURLWithPath: "/tmp/preview-fixture.png")))
            XCTAssertEqual(index, 99, "BrowserImagePreviewState still owns index clamping")
        }

        XCTAssertEqual(messenger.responses.count, 1)
        XCTAssertTrue(messenger.errors.isEmpty)
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testRepliesStayScopedToEachRequest() {
        let messenger = TestMessenger()
        let payload = #"{"windowId":42,"items":["https://example.com/image.png"],"currentIndex":0}"#
        ImagePreviewMessageHandler.handle(context(payload, requestID: "first"), messenger: messenger) { _, _ in }
        ImagePreviewMessageHandler.handle(context("not JSON", requestID: "second"), messenger: messenger) { _, _ in
            XCTFail("Malformed payload must not open a preview")
        }

        XCTAssertEqual(messenger.responses.map(\.requestId), ["first"])
        XCTAssertEqual(messenger.errors.map(\.requestId), ["second"])
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }
}
