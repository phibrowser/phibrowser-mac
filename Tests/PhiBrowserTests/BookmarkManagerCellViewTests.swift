// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

@MainActor
final class BookmarkManagerCellViewTests: XCTestCase {
    private let scope = BookmarkManagementScope(
        accountId: "account-1",
        profileId: "profile-1",
        spaceId: "space-1"
    )

    func testAddressColumnDisplaysPhiBrandedNewTabURL() throws {
        let bookmark = Bookmark(
            guid: "new-tab",
            title: "New Tab",
            url: "chrome://newtab"
        )
        let cell = BookmarkManagerCellView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))

        cell.configure(
            bookmark: bookmark,
            scope: scope,
            column: .address,
            onCommit: nil
        )

        XCTAssertEqual(try XCTUnwrap(cell.textField).stringValue, "phi://newtab")
    }

    func testInlineAddressEditingStartsWithPhiBrandedURL() throws {
        let bookmark = Bookmark(
            guid: "new-tab",
            title: "New Tab",
            url: "chrome://newtab"
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 28),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let cell = BookmarkManagerCellView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = cell
        cell.configure(
            bookmark: bookmark,
            scope: scope,
            column: .address,
            onCommit: { _ in true }
        )

        cell.beginEditing()

        XCTAssertEqual(try XCTUnwrap(cell.textField).stringValue, "phi://newtab")
    }
}
