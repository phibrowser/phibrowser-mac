// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

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

    private func context(_ payload: String, requestID: String = "preview-request") -> ExtensionMessageContext {
        ExtensionMessageContext(type: "imagePreview", payload: payload,
                                requestId: requestID, senderId: "test-extension")
    }

    func testRepliesOnceAfterOpeningWithoutWaitingForImageLoading() {
        let messenger = TestMessenger()
        var opens = 0
        ImagePreviewMessageHandler.handle(
            context(#"{"windowId":42,"items":["https://example.com/image.png"],"currentIndex":0}"#),
            messenger: messenger
        ) { windowID, items, index in
            opens += 1
            XCTAssertEqual(windowID, 42)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.source, .remoteURL(URL(string: "https://example.com/image.png")!))
            XCTAssertEqual(index, 0)
            XCTAssertTrue(messenger.responses.isEmpty, "Do not acknowledge before opening the preview")
            return true
        }

        XCTAssertEqual(opens, 1)
        XCTAssertEqual(messenger.responses.count, 1)
        XCTAssertEqual(messenger.responses.first?.response, "{}")
        XCTAssertEqual(messenger.responses.first?.requestId, "preview-request")
        XCTAssertTrue(messenger.errors.isEmpty)
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testUnavailableWindowRejectsOnceInsteadOfTimingOut() {
        let messenger = TestMessenger()
        var opens = 0
        ImagePreviewMessageHandler.handle(
            context(#"{"windowId":42,"items":["https://example.com/image.png"],"currentIndex":0}"#),
            messenger: messenger
        ) { _, _, _ in
            opens += 1
            return false
        }

        XCTAssertEqual(opens, 1)
        XCTAssertTrue(messenger.responses.isEmpty)
        XCTAssertEqual(messenger.errors.count, 1)
        XCTAssertEqual(messenger.errors.first?.error, "Image preview window unavailable")
        XCTAssertEqual(messenger.errors.first?.requestId, "preview-request")
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testMalformedPayloadsRejectWithoutOpeningOrEchoingPrivateData() {
        for payload in [
            "not JSON",
            #"{"windowId":"invalid","items":["https://private.example/image?token=secret"],"currentIndex":0}"#,
            #"{"windowId":42,"items":[17],"currentIndex":0}"#,
            #"{"windowId":42,"items":["https://example.com/image.png"]}"#,
        ] {
            let messenger = TestMessenger()
            ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { _, _, _ in
                XCTFail("Malformed payload must not open a preview")
                return true
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
            ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { _, _, _ in
                XCTFail("Empty previews must not be acknowledged as opened")
                return true
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
        ImagePreviewMessageHandler.handle(context(payload), messenger: messenger) { _, items, index in
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items[0].source, .remoteURL(URL(string: "https://example.com/one.png")!))
            XCTAssertEqual(items[1].source, .localFile(URL(fileURLWithPath: "/tmp/preview-fixture.png")))
            XCTAssertEqual(index, 99, "BrowserImagePreviewState still owns index clamping")
            return true
        }

        XCTAssertEqual(messenger.responses.count, 1)
        XCTAssertTrue(messenger.errors.isEmpty)
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testRepliesStayScopedToEachRequest() {
        let messenger = TestMessenger()
        let payload = #"{"windowId":42,"items":["https://example.com/image.png"],"currentIndex":0}"#
        ImagePreviewMessageHandler.handle(context(payload, requestID: "first"), messenger: messenger) { _, _, _ in true }
        ImagePreviewMessageHandler.handle(context(payload, requestID: "second"), messenger: messenger) { _, _, _ in false }

        XCTAssertEqual(messenger.responses.map(\.requestId), ["first"])
        XCTAssertEqual(messenger.errors.map(\.requestId), ["second"])
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }
}
