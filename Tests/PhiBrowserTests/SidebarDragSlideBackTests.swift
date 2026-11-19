// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class SidebarDragSlideBackTests: XCTestCase {
    func testCancelledDragSlidesBackWhileTheListHasNotScrolled() {
        XCTAssertTrue(SidebarDragSlideBack.animatesBack(startOffset: 120, currentOffset: 120))
    }

    func testCancelledDragFadesOnceTheListScrolledUnderIt() {
        XCTAssertFalse(SidebarDragSlideBack.animatesBack(startOffset: 120, currentOffset: 84))
        XCTAssertFalse(SidebarDragSlideBack.animatesBack(startOffset: 120, currentOffset: 160))
    }

    func testSubPointJitterStillSlidesBack() {
        XCTAssertTrue(SidebarDragSlideBack.animatesBack(startOffset: 120, currentOffset: 120.3))
    }

    func testListScrolledBackToItsStartSlidesBackAgain() {
        XCTAssertTrue(SidebarDragSlideBack.animatesBack(startOffset: 0, currentOffset: 0))
    }
}
