// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The reader-page URL parsers: how a reading-surface tab is bound back to
/// the origin tab it covers (`tab=`) and to the article it stands in for
/// (`src=`). The fragment shape is produced by `readerPageUrl` in the
/// extension's background script; keep the two in agreement.
final class ReaderExtensionBridgeURLTests: XCTestCase {
    private let readerBase =
        "chrome-extension://\(ReaderExtensionBridge.extensionId)/reader.html"

    func testOriginTabIdParsesFromReaderPageURL() {
        XCTAssertEqual(
            ReaderExtensionBridge.originTabId(
                fromReaderPageURL: "\(readerBase)#tab=42&src=https%3A%2F%2Fexample.com%2Farticle"),
            42
        )
    }

    func testOriginTabIdParsesWhenTabIsNotTheFirstParameter() {
        XCTAssertEqual(
            ReaderExtensionBridge.originTabId(
                fromReaderPageURL: "\(readerBase)#src=https%3A%2F%2Fexample.com&tab=7"),
            7
        )
    }

    func testOriginTabIdRefusesForeignAndMalformedURLs() {
        // Another extension serving an identically named page must not bind.
        XCTAssertNil(ReaderExtensionBridge.originTabId(
            fromReaderPageURL: "chrome-extension://aaaabbbbccccddddeeeeffffgggghhhh/reader.html#tab=42"))
        // A web page can never be a reader surface.
        XCTAssertNil(ReaderExtensionBridge.originTabId(
            fromReaderPageURL: "https://example.com/reader.html#tab=42"))
        // No fragment, no tab parameter, junk id.
        XCTAssertNil(ReaderExtensionBridge.originTabId(fromReaderPageURL: readerBase))
        XCTAssertNil(ReaderExtensionBridge.originTabId(
            fromReaderPageURL: "\(readerBase)#src=https%3A%2F%2Fexample.com"))
        XCTAssertNil(ReaderExtensionBridge.originTabId(
            fromReaderPageURL: "\(readerBase)#tab=abc"))
    }

    func testSourceURLStillParsesAlongsideTab() {
        XCTAssertEqual(
            ReaderExtensionBridge.sourceURLString(
                fromReaderPageURL: "\(readerBase)#tab=42&src=https%3A%2F%2Fexample.com%2Farticle"),
            "https://example.com/article"
        )
    }
}
