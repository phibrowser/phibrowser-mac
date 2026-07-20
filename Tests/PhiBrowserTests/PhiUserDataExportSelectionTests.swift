// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class PhiUserDataExportSelectionTests: XCTestCase {
    func testDefaultsSelectBothCategories() {
        let selection = PhiUserDataExportSelection()
        XCTAssertTrue(selection.includeBrowserData)
        XCTAssertTrue(selection.includeAIData)
        XCTAssertTrue(selection.isExportable)
        XCTAssertTrue(selection.shouldCoordinateAIData)
    }

    func testBrowserOnlyDoesNotCoordinateAIData() {
        let selection = PhiUserDataExportSelection(includeBrowserData: true, includeAIData: false)
        XCTAssertTrue(selection.isExportable)
        XCTAssertFalse(selection.shouldCoordinateAIData)
    }

    func testAIOnlyStillCoordinates() {
        let selection = PhiUserDataExportSelection(includeBrowserData: false, includeAIData: true)
        XCTAssertTrue(selection.isExportable)
        XCTAssertTrue(selection.shouldCoordinateAIData)
    }

    func testNothingSelectedIsNotExportable() {
        let selection = PhiUserDataExportSelection(includeBrowserData: false, includeAIData: false)
        XCTAssertFalse(selection.isExportable)
        XCTAssertFalse(selection.shouldCoordinateAIData)
    }
}
