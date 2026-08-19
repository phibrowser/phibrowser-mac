// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

/// Layout-mode selection for split-merged cells: below
/// `splitCompactModeThreshold` (2x the single-tab cutoff) the cell must
/// fall back to the centered two-favicon compact rendering. In the
/// 64-128pt band the per-pane normal layout has no room — hover close
/// buttons land on top of the pane favicons, so a click meant to focus
/// a pane closes it instead.
@MainActor
final class TabItemViewSplitLayoutTests: XCTestCase {
    private func makeMergedSplitView(width: CGFloat, partner: Tab) -> TabItemView {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Primary",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            pinnedSplitPartner: partner,
            sourceTab: nil
        ))
        view.frame = CGRect(x: 0, y: 0, width: width, height: TabStripMetrics.Strip.tabHeight)
        view.layout()
        return view
    }

    private func visibleFrames(of view: TabItemView) -> [CGRect] {
        view.subviews
            .filter { !$0.isHidden && !$0.frame.isEmpty }
            .map(\.frame)
            .sorted { $0.minX < $1.minX }
    }

    func test_mergedSplitCellBelowSplitThresholdShowsOnlyCenteredFaviconPair() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: 100, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertEqual(frames.count, 2,
            "A merged split cell narrower than the split compact threshold must show only the two pane favicons.")
        // 16 + 2 + 16 pair centered in the 100pt cell -> x = 33 and 51.
        XCTAssertEqual(frames[0], CGRect(x: 33, y: 8, width: faviconSize.width, height: faviconSize.height))
        XCTAssertEqual(frames[1], CGRect(x: 51, y: 8, width: faviconSize.width, height: faviconSize.height))
    }

    func test_mergedSplitCellAboveSplitThresholdRendersPerPaneLayout() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: 140, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "Left pane favicon must sit at its leading position in normal mode.")
        XCTAssertTrue(frames.contains(CGRect(x: 76, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "Right pane favicon must sit at its leading position past the cell midpoint.")
        XCTAssertTrue(frames.contains { $0.size == TabStripMetrics.Content.separatorSize },
            "The split divider must be visible in normal mode.")
    }

    /// Couples the strip's active-split width floor to the render
    /// threshold: at `Tab.activeSplitMinWidth` (what the layout engine
    /// allocates to a focused merged cell under pressure) the cell must
    /// still render the per-pane layout, not the compact favicon pair.
    func test_mergedSplitCellAtActiveSplitMinWidthRendersPerPaneLayout() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: TabStripMetrics.Tab.activeSplitMinWidth, partner: partner)

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "At the active-split width floor the left pane favicon must sit at its leading position.")
        XCTAssertTrue(frames.contains { $0.size == TabStripMetrics.Content.separatorSize },
            "At the active-split width floor the cell must keep the per-pane layout (divider visible).")
    }

    /// Guards the mute-wins rule against over-triggering: with no audio on
    /// either pane, a hovered merged cell keeps both per-pane close buttons.
    func test_hoveredMergedSplitCellShowsPerPaneCloseButtons() {
        let partner = Tab(guid: 2, url: "https://partner.example", isActive: false, index: 1)
        let view = makeMergedSplitView(width: 140, partner: partner)
        view.mouseEntered(with: makeHoverEvent())

        let frames = visibleFrames(of: view)
        let closeSize = TabStripMetrics.Content.closeButtonSize
        // half = 70 → left close x = 70 - 4 - 24 = 42; right x = 140 - 28 = 112.
        XCTAssertTrue(frames.contains(CGRect(x: 42, y: 4, width: closeSize.width, height: closeSize.height)),
            "Hovering a merged cell with no audio must show the left pane close button.")
        XCTAssertTrue(frames.contains(CGRect(x: 112, y: 4, width: closeSize.width, height: closeSize.height)),
            "Hovering a merged cell with no audio must show the right pane close button.")
    }

    func test_compactMergedSplitCellExposesPerPaneToolTips() {
        let primary = Tab(guid: 1, url: "https://a.example", isActive: false, index: 0, title: "Alpha")
        let partner = Tab(guid: 2, url: "https://b.example", isActive: false, index: 1, title: "Beta")
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Alpha",
            url: "https://a.example",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            pinnedSplitPartner: partner,
            sourceTab: primary
        ))
        view.frame = CGRect(x: 0, y: 0, width: 100, height: TabStripMetrics.Strip.tabHeight)
        view.layout()

        XCTAssertEqual(view.paneToolTipTags.count, 2,
            "A compact merged cell must cover each half with its own tooltip rect.")
        XCTAssertEqual(
            view.view(view, stringForToolTip: view.paneToolTipTags[0], point: NSPoint(x: 20, y: 16), userData: nil),
            "Alpha")
        XCTAssertEqual(
            view.view(view, stringForToolTip: view.paneToolTipTags[1], point: NSPoint(x: 80, y: 16), userData: nil),
            "Beta")

        // Growing past the split threshold returns tooltip duty to the
        // per-pane title views.
        view.frame = CGRect(x: 0, y: 0, width: 140, height: TabStripMetrics.Strip.tabHeight)
        view.layout()
        XCTAssertTrue(view.paneToolTipTags.isEmpty,
            "A merged cell in per-pane mode must drop the half tooltip rects.")
    }

    private func makeHoverEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    func test_singleTabKeepsSingleTabCompactThreshold() {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Single",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))
        view.frame = CGRect(x: 0, y: 0, width: 100, height: TabStripMetrics.Strip.tabHeight)
        view.layout()

        let frames = visibleFrames(of: view)
        let faviconSize = TabStripMetrics.Content.faviconSize
        XCTAssertTrue(frames.contains(CGRect(x: 6, y: 8, width: faviconSize.width, height: faviconSize.height)),
            "A 100pt single tab must keep the leading favicon (normal mode), not the centered compact layout.")
    }
}

final class SplitViewLayoutTests: XCTestCase {
    func testLayoutTogglePreservesDividerOrientationSemantics() {
        XCTAssertEqual(SplitLayout.vertical.toggled, .horizontal)
        XCTAssertEqual(SplitLayout.horizontal.toggled, .vertical)
    }

    func testDirectionalDropZonesMapToExpectedLayoutAndSlot() {
        XCTAssertEqual(SplitTabDropContainer.DropZone.left.layout, .vertical)
        XCTAssertEqual(SplitTabDropContainer.DropZone.right.layout, .vertical)
        XCTAssertEqual(SplitTabDropContainer.DropZone.top.layout, .horizontal)
        XCTAssertEqual(SplitTabDropContainer.DropZone.bottom.layout, .horizontal)

        XCTAssertTrue(SplitTabDropContainer.DropZone.left.isPrimarySlot)
        XCTAssertFalse(SplitTabDropContainer.DropZone.right.isPrimarySlot)
        XCTAssertTrue(SplitTabDropContainer.DropZone.top.isPrimarySlot)
        XCTAssertFalse(SplitTabDropContainer.DropZone.bottom.isPrimarySlot)
    }

    func testCreateDropZoneRecognizesAllFourEdgesAndRejectsCenter() {
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)

        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 100, y: 300), in: area),
            .left
        )
        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 800, y: 300), in: area),
            .right
        )
        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 450, y: 550), in: area),
            .top
        )
        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 450, y: 50), in: area),
            .bottom
        )
        XCTAssertNil(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 450, y: 300), in: area)
        )
        XCTAssertNil(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: -1, y: 300), in: area)
        )
    }

    func testCreateDropZoneKeepsExistingLeftRightPriorityAtCorners() {
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)

        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 50, y: 550), in: area),
            .left
        )
        XCTAssertEqual(
            SplitTabDropContainer.createDropZone(for: CGPoint(x: 850, y: 50), in: area),
            .right
        )
    }

    func testStackedDividerDragUsesVisualHandleDirection() {
        let start = CGPoint(x: 100, y: 100)

        XCTAssertEqual(
            SplitPaneHostView.primaryPaneGrowthDistance(
                layout: .horizontal,
                from: start,
                to: CGPoint(x: 100, y: 140)
            ),
            -40,
            "Dragging upward must shrink the top pane so the divider also moves upward."
        )
        XCTAssertEqual(
            SplitPaneHostView.primaryPaneGrowthDistance(
                layout: .horizontal,
                from: start,
                to: CGPoint(x: 100, y: 60)
            ),
            40,
            "Dragging downward must grow the top pane so the divider also moves downward."
        )
    }
}
