// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class PhiUserDataImportDetectionTests: XCTestCase {
    private func makeStaging() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhiImportDetect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDetectsAIDataArchiveAtStagingRoot() throws {
        let staging = try makeStaging()
        let tarURL = staging.appendingPathComponent("ai-data.tar.gz", isDirectory: false)
        try Data("tar".utf8).write(to: tarURL)
        XCTAssertEqual(AppController.importedAIDataArchiveURL(inStaging: staging), tarURL)
    }

    func testReturnsNilWhenNoAIDataArchive() throws {
        let staging = try makeStaging()
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("Phi", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertNil(AppController.importedAIDataArchiveURL(inStaging: staging))
    }

    func testConfirmationBodyMentionsAIDataWhenPresent() {
        let combined = AppController.importConfirmationBody(hasAIData: true)
        let browserOnly = AppController.importConfirmationBody(hasAIData: false)
        XCTAssertNotEqual(combined, browserOnly)
        XCTAssertTrue(combined.localizedCaseInsensitiveContains("AI data"))
    }
}
