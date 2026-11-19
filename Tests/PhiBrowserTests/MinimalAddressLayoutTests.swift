// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class MinimalAddressLayoutTests: XCTestCase {
    func testAnAddressThatFitsIsCenteredOnTheWindow() {
        let f = MinimalAddressLayout.frame(textWidth: 100, centerX: 400, freeMinX: 100, freeMaxX: 900)
        XCTAssertEqual(f.minX, 350); XCTAssertEqual(f.width, 100)
    }

    func testItSlidesTowardTheFreeSide() {
        let f = MinimalAddressLayout.frame(textWidth: 200, centerX: 150, freeMinX: 120, freeMaxX: 900)
        XCTAssertEqual(f.minX, 120); XCTAssertEqual(f.width, 200)
    }

    func testALongAddressTruncatesBetweenTheZones() {
        let f = MinimalAddressLayout.frame(textWidth: 900, centerX: 400, freeMinX: 100, freeMaxX: 700)
        XCTAssertEqual(f.minX, 100); XCTAssertEqual(f.width, 600)
    }

    // MARK: - The centered unit

    func testTheWholeUnitIsCenteredNotTheText() {
        // 50pt of leading buttons, 100pt of text, 26pt of trailing buttons.
        let u = MinimalAddressLayout.unit(leadingWidth: 50, textWidth: 100, trailingWidth: 26, centerX: 400, freeMinX: 0, freeMaxX: 800)
        XCTAssertEqual(u.width, 176)
        XCTAssertEqual(u.minX, 312)
        XCTAssertEqual(u.textMinX, 362, "the leading buttons sit right before the text")
        XCTAssertEqual(u.textWidth, 100)
        XCTAssertEqual(u.trailingMinX, 462, "the trailing buttons sit right after it")
        XCTAssertEqual(u.minX + u.width / 2, 400)
    }

    func testTheUnitSlidesTowardTheFreeSide() {
        let u = MinimalAddressLayout.unit(leadingWidth: 48, textWidth: 200, trailingWidth: 48, centerX: 150, freeMinX: 120, freeMaxX: 900)
        XCTAssertEqual(u.minX, 120)
        XCTAssertEqual(u.textWidth, 200, "sliding truncates nothing")
        XCTAssertEqual(u.trailingMinX, 368)
    }

    func testOnlyTheTextTruncatesBetweenTheZones() {
        let u = MinimalAddressLayout.unit(leadingWidth: 48, textWidth: 900, trailingWidth: 24, centerX: 400, freeMinX: 100, freeMaxX: 700)
        XCTAssertEqual(u.minX, 100)
        XCTAssertEqual(u.leadingWidth, 48)
        XCTAssertEqual(u.trailingWidth, 24)
        XCTAssertEqual(u.textWidth, 528)
        XCTAssertEqual(u.minX + u.width, 700, "the unit fills the free space exactly")
    }

    func testButtonsWiderThanTheFreeSpaceLeaveNoText() {
        let u = MinimalAddressLayout.unit(leadingWidth: 100, textWidth: 80, trailingWidth: 100, centerX: 150, freeMinX: 100, freeMaxX: 250)
        XCTAssertEqual(u.minX, 100)
        XCTAssertEqual(u.textWidth, 0)
        XCTAssertEqual(u.width, 200, "the buttons keep their widths")
    }

    func testAUnitWithoutButtonsPlacesTheTextAsBefore() {
        let u = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 100, freeMaxX: 900)
        let f = MinimalAddressLayout.frame(textWidth: 100, centerX: 400, freeMinX: 100, freeMaxX: 900)
        XCTAssertEqual(u.textMinX, f.minX)
        XCTAssertEqual(u.textWidth, f.width)
    }

    func testOneSidedButtonsShiftTheTextOffCenter() {
        // The unit, not the text, is centered: leading buttons push the text right.
        let u = MinimalAddressLayout.unit(leadingWidth: 48, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800)
        XCTAssertEqual(u.minX, 326)
        XCTAssertEqual(u.textMinX, 374)
    }

    // MARK: - Customize-only buttons (R27)

    func testCustomizeOnlyTrailingButtonsDoNotMoveTheText() {
        // Browsing: Copy URL and Site Menu. Customizing adds Reader View and Site Memories.
        let browsing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 50, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 102, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    trailingCustomizeOnlyWidth: 52)
        XCTAssertEqual(customizing.textMinX, browsing.textMinX)
        XCTAssertEqual(customizing.textWidth, browsing.textWidth)
        XCTAssertEqual(customizing.trailingMinX, browsing.trailingMinX)
        XCTAssertEqual(customizing.minX + customizing.width, browsing.minX + browsing.width + 52, "the extras extend outward")
    }

    func testCustomizeOnlyLeadingButtonsExtendLeft() {
        let browsing = MinimalAddressLayout.unit(leadingWidth: 24, textWidth: 100, trailingWidth: 50, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 50, textWidth: 100, trailingWidth: 50, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    leadingCustomizeOnlyWidth: 26)
        XCTAssertEqual(customizing.textMinX, browsing.textMinX)
        XCTAssertEqual(customizing.minX, browsing.minX - 26)
    }

    func testASectionOfOnlyCustomizeOnlyButtonsCentersLikeAnEmptyOne() {
        // Reader View alone: 24pt drawn, 24 + 2 counted as customize-only.
        let extra = MinimalAddressLayout.customizeOnlyWidth(itemWidths: [24], spacing: 2)
        XCTAssertEqual(extra, 26)
        let empty = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 24, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    trailingCustomizeOnlyWidth: extra)
        XCTAssertEqual(customizing.textMinX, empty.textMinX, "clamped to the drawn width")
    }

    func testTheCustomizeOnlyInputCountsOnlyCustomizeOnlyItems() {
        let trailing: [ToolbarItemID] = [.readerView, .siteMemories, .copyURL, .siteMenu]
        XCTAssertEqual(WebContentAddressBarView.customizeOnlyWidth(of: trailing, customizeOnly: [.readerView, .siteMemories]), 52)
        XCTAssertEqual(WebContentAddressBarView.customizeOnlyWidth(of: trailing, customizeOnly: []), 0)
        XCTAssertEqual(WebContentAddressBarView.customizeOnlyWidth(of: [.copyURL], customizeOnly: [.readerView]), 0,
                       "an item of the other section")
    }

    // MARK: - An empty section's reserve while customizing

    func testAnEmptyLeadingSectionGetsTheReserveOutsideTheText() {
        let browsing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 24, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 24, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    leadingMinimumWidth: 24.5)
        XCTAssertEqual(customizing.leadingWidth, 24.5, "visible inside the outline")
        XCTAssertEqual(customizing.textMinX, browsing.textMinX, "the text stays put")
        XCTAssertEqual(customizing.trailingMinX, browsing.trailingMinX, "so does the trailing section")
        XCTAssertEqual(customizing.minX, browsing.minX - 24.5, "the reserve extends outward")
    }

    func testAnEmptyTrailingSectionGetsTheReserveOutsideTheText() {
        let browsing = MinimalAddressLayout.unit(leadingWidth: 24, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 24, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    trailingMinimumWidth: 24.5)
        XCTAssertEqual(customizing.trailingWidth, 24.5)
        XCTAssertEqual(customizing.minX, browsing.minX, "the leading side stays put")
        XCTAssertEqual(customizing.textMinX, browsing.textMinX)
        XCTAssertEqual(customizing.textWidth, browsing.textWidth)
        XCTAssertEqual(customizing.minX + customizing.width, browsing.minX + browsing.width + 24.5, "the reserve extends outward")
    }

    func testBothEmptySectionsKeepTheTextCentered() {
        let browsing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let customizing = MinimalAddressLayout.unit(leadingWidth: 0, textWidth: 100, trailingWidth: 0, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                                    leadingMinimumWidth: 24.5, trailingMinimumWidth: 24.5)
        XCTAssertEqual(customizing.textMinX, browsing.textMinX)
        XCTAssertEqual(customizing.textMinX + customizing.textWidth / 2, 400)
        XCTAssertEqual(customizing.width, 149)
    }

    func testNoReserveLeavesTheUnitAsItWas() {
        let without = MinimalAddressLayout.unit(leadingWidth: 50, textWidth: 100, trailingWidth: 26, centerX: 400, freeMinX: 0, freeMaxX: 800)
        let with = MinimalAddressLayout.unit(leadingWidth: 50, textWidth: 100, trailingWidth: 26, centerX: 400, freeMinX: 0, freeMaxX: 800,
                                             leadingMinimumWidth: 0, trailingMinimumWidth: 0)
        XCTAssertEqual(with, without)
    }

    func testOnlyAnEmptySectionReservesAndOnlyWhileCustomizing() {
        XCTAssertEqual(WebContentAddressBarView.sectionReserve(isEmpty: true, isCustomizing: false), 0, "browsing")
        XCTAssertEqual(WebContentAddressBarView.sectionReserve(isEmpty: false, isCustomizing: true), 0, "a section with buttons hugs them")
        XCTAssertEqual(WebContentAddressBarView.sectionReserve(isEmpty: true, isCustomizing: true),
                       ToolbarCustomizationLayout.addressSectionReserve)
    }

    func testTheWindowCenterIsShiftedByTheHeaderOffset() {
        // Sidebar docked: header starts 260pt into a 1000pt-wide window.
        XCTAssertEqual(MinimalAddressLayout.windowCenterX(windowWidth: 1000, headerMinXInWindow: 260), 240)
        XCTAssertEqual(MinimalAddressLayout.windowCenterX(windowWidth: 1000, headerMinXInWindow: 0), 500)
    }

    func testInASplitTheAddressCentersOnItsOwnHeader() {
        // Sidebar docked: a 740pt header starting 260pt into a 1000pt-wide window.
        XCTAssertEqual(MinimalAddressLayout.centerX(windowWidth: 1000, headerMinXInWindow: 260, headerWidth: 740, isSplitViewVisible: false), 240)
        XCTAssertEqual(MinimalAddressLayout.centerX(windowWidth: 1000, headerMinXInWindow: 260, headerWidth: 740, isSplitViewVisible: true), 370)
    }
}
