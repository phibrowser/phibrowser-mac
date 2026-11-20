// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// The shell window is movable by its background, so the split view holding
/// the sidebar and page area must keep a mouse-down inside either column from
/// moving the window.
@MainActor
final class PhiSplitViewWindowDragTests: XCTestCase {
    func testTheSplitViewNeverLetsAMouseDownMoveTheWindow() {
        let split = PhiSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertFalse(split.mouseDownCanMoveWindow)
    }

    func testAPinnedTabCellAroundItsIconStillAsksToMoveTheWindow() {
        // The cell itself answers true, so the split view's answer is what
        // keeps a drag from around the favicon from moving the window.
        let cell = HoverableView(frame: NSRect(x: 0, y: 0, width: 53, height: 45))
        XCTAssertTrue(cell.mouseDownCanMoveWindow)
    }
}
