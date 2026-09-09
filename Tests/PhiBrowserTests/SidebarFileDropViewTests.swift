// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import XCTest
@testable import Phi

@MainActor
final class SidebarFileDropViewTests: XCTestCase {
    func testReadsMultipleFileURLsInOrderWithoutChangingEscapedPaths() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [
            URL(fileURLWithPath: "/tmp/quarterly report #1.pdf"),
            URL(fileURLWithPath: "/tmp/image %20.png")
        ]
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))

        XCTAssertEqual(SidebarFileDropView.fileURLs(from: pasteboard), urls)
    }

    func testLeavesPreviewSupportToChromium() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let urls = [
            URL(fileURLWithPath: "/tmp/page.html"),
            URL(fileURLWithPath: "/tmp/data.unknown-extension"),
            URL(fileURLWithPath: "/tmp/no-extension")
        ]
        XCTAssertTrue(pasteboard.writeObjects(urls as [NSURL]))

        XCTAssertEqual(SidebarFileDropView.fileURLs(from: pasteboard), urls)
    }

    func testIgnoresWebURLsInMixedDrop() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/page.html")
        let web = URL(string: "https://example.com/page.html")!
        XCTAssertTrue(pasteboard.writeObjects([web, file] as [NSURL]))

        XCTAssertEqual(SidebarFileDropView.fileURLs(from: pasteboard), [file])
    }

    func testIgnoresInternalTabPayloadAndPlainTextFilePath() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("123", forType: .normalTab)
        item.setString("/tmp/page.html", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertTrue(SidebarFileDropView.fileURLs(from: pasteboard).isEmpty)
    }
}
