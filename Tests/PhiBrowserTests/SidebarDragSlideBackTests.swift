// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarDragSlideBackTests: XCTestCase {
    func testCancelledDragSlidesBackWhileTheListHasNotScrolled() {
        XCTAssertTrue(SidebarDragSlideBack.animatesBack(current: true, startOffset: 120, currentOffset: 120))
    }

    func testCancelledDragFadesOnceTheListScrolledUnderIt() {
        XCTAssertFalse(SidebarDragSlideBack.animatesBack(current: true, startOffset: 120, currentOffset: 84))
        XCTAssertFalse(SidebarDragSlideBack.animatesBack(current: true, startOffset: 120, currentOffset: 160))
    }

    func testSubPointJitterStillSlidesBack() {
        XCTAssertTrue(SidebarDragSlideBack.animatesBack(current: true, startOffset: 120, currentOffset: 120.3))
    }

    func testTearOffOutsideTheWindowKeepsItsSlideBackOff() {
        XCTAssertFalse(SidebarDragSlideBack.animatesBack(current: false, startOffset: 120, currentOffset: 120))
    }
}
