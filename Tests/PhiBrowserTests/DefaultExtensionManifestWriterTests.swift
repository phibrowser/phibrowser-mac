// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// The native-messaging manifests Phi writes at launch must be valid JSON
/// whose host name matches the file name Chromium looks the host up by.
final class DefaultExtensionManifestWriterTests: XCTestCase {
    private func manifest(_ ext: DefaultExtensionManifestWriter.Extension) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(ext.content.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testEveryManifestIsValidAndNamedAfterItsHost() throws {
        for ext in DefaultExtensionManifestWriter.Extension.allCases {
            let manifest = try manifest(ext)
            let name = try XCTUnwrap(manifest["name"] as? String)
            XCTAssertEqual(ext.fileName, "\(name).json")
            XCTAssertEqual(manifest["type"] as? String, "stdio")
            XCTAssertTrue((manifest["path"] as? String)?.hasPrefix("/") == true)
        }
    }

    func testBitwardenManifestAllowsTheBitwardenExtension() throws {
        let manifest = try manifest(.bitwarden)
        XCTAssertEqual(manifest["path"] as? String, "/Applications/Bitwarden.app/Contents/MacOS/desktop_proxy")
        let origins = try XCTUnwrap(manifest["allowed_origins"] as? [String])
        XCTAssertTrue(origins.contains("chrome-extension://\(PhiExtensionID.bitwarden)/"))
    }
}
