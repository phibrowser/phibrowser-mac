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

    func testCreateDropHintRectsMatchFigmaReferenceGeometry() {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let rects = SplitTabDropContainer.createDropHintRects(in: area)

        XCTAssertEqual(rects[.left], CGRect(x: 14, y: 114.5, width: 160, height: 460))
        XCTAssertEqual(rects[.right], CGRect(x: 1116, y: 114.5, width: 160, height: 460))
        XCTAssertEqual(rects[.top], CGRect(x: 495, y: 551, width: 300, height: 120))
        XCTAssertEqual(rects[.bottom], CGRect(x: 495, y: 18, width: 300, height: 120))
    }

    func testCreateDropHintRectsPreserveFigmaAspectRatiosWithoutOverlap() throws {
        let areas = [
            CGRect(x: 0, y: 0, width: 800, height: 1000),
            CGRect(x: 0, y: 0, width: 2000, height: 400),
            CGRect(x: 0, y: 0, width: 320, height: 180),
        ]

        for area in areas {
            let rects = SplitTabDropContainer.createDropHintRects(in: area)
            let left = try XCTUnwrap(rects[.left])
            let top = try XCTUnwrap(rects[.top])
            XCTAssertEqual(left.width / left.height, 160.0 / 460.0, accuracy: 0.0001)
            XCTAssertEqual(top.width / top.height, 300.0 / 120.0, accuracy: 0.0001)

            let zones: [SplitTabDropContainer.DropZone] = [.left, .right, .top, .bottom]
            for firstIndex in zones.indices {
                for secondIndex in zones.index(after: firstIndex)..<zones.endIndex {
                    let first = try XCTUnwrap(rects[zones[firstIndex]])
                    let second = try XCTUnwrap(rects[zones[secondIndex]])
                    XCTAssertFalse(first.intersects(second), "\(zones[firstIndex]) and \(zones[secondIndex]) must not overlap in \(area).")
                }
            }
        }
    }

    func testDropHintLabelWrapsWithoutLeavingNarrowCard() {
        let label = NSTextField(labelWithString: "Eine neue geteilte Ansicht auf der linken Seite hinzufügen")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true

        let narrowCard = CGRect(x: 50, y: 80, width: 40, height: 114)
        let wideCard = CGRect(x: 50, y: 80, width: 300, height: 120)
        let narrowFrame = SplitTabDropContainer.dropHintLabelFrame(
            for: label,
            in: narrowCard
        )
        let wideFrame = SplitTabDropContainer.dropHintLabelFrame(
            for: label,
            in: wideCard
        )

        XCTAssertGreaterThan(narrowFrame.height, wideFrame.height)
        XCTAssertGreaterThanOrEqual(narrowFrame.minX, narrowCard.minX)
        XCTAssertLessThanOrEqual(narrowFrame.maxX, narrowCard.maxX)
        XCTAssertGreaterThanOrEqual(narrowFrame.minY, narrowCard.minY)
        XCTAssertLessThanOrEqual(narrowFrame.maxY, narrowCard.maxY)
    }

    func testActiveCreateDropHintUsesCurrentExpandedScale() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let base = try XCTUnwrap(SplitTabDropContainer.createDropHintRects(in: area)[.left])
        let active = SplitTabDropContainer.createDropHintRect(
            for: .left,
            in: area,
            isActive: true,
            dragPoint: nil
        )

        XCTAssertEqual(active.width, base.width * 1.3, accuracy: 0.0001)
        XCTAssertEqual(active.height, base.height * 1.3, accuracy: 0.0001)
        XCTAssertEqual(active, CGRect(x: 0, y: 45.5, width: 208, height: 598))
    }

    func testApproachingCreateDropHintMovesMonotonicallyAsPointerConverges() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let base = try XCTUnwrap(SplitTabDropContainer.createDropHintRects(in: area)[.left])
        let dragPoints = [
            CGPoint(x: 430, y: area.midY),
            CGPoint(x: 300, y: area.midY),
            CGPoint(x: 200, y: area.midY),
        ]
        var presentedRect = base
        var approachTargetCenter: CGPoint?
        var approachRects: [CGRect] = []

        for dragPoint in dragPoints {
            let center = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: .left,
                in: area,
                presentedRect: presentedRect,
                currentTargetCenter: approachTargetCenter,
                dragPoint: dragPoint
            )
            approachTargetCenter = center
            presentedRect = SplitTabDropContainer.createDropHintRect(
                for: .left,
                in: area,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: center
            )
            approachRects.append(presentedRect)
        }

        XCTAssertEqual(approachRects[0].midX, 242.5, accuracy: 0.0001)
        XCTAssertEqual(approachRects[1].midX, 242.5, accuracy: 0.0001)
        XCTAssertEqual(approachRects[2].midX, 242.5, accuracy: 0.0001)
        XCTAssertTrue(zip(approachRects, approachRects.dropFirst()).allSatisfy {
            $0.1.midX >= $0.0.midX
        })
        XCTAssertTrue(approachRects.allSatisfy { $0.size == base.size })
        let entryRect = try XCTUnwrap(approachRects.last)
        let entryPoint = try XCTUnwrap(dragPoints.last)
        XCTAssertTrue(entryRect.contains(entryPoint))
        let entered = SplitTabDropContainer.createDropHintRect(
            for: .left,
            in: area,
            isActive: true,
            isExpanded: true,
            dragPoint: entryPoint,
            followDragAnchor: entryPoint,
            followCenterAnchor: CGPoint(
                x: entryRect.midX,
                y: entryRect.midY
            )
        )

        XCTAssertEqual(entered.maxX, entryRect.maxX, accuracy: 0.0001)
        XCTAssertEqual(entered.midY, entryRect.midY, accuracy: 0.0001)
        XCTAssertEqual(entered.width, base.width * 1.3, accuracy: 0.0001)
        XCTAssertEqual(entered.height, base.height * 1.3, accuracy: 0.0001)
        XCTAssertFalse(SplitTabDropContainer.shouldExpandCreateDropHint(
            presentedRect: approachRects[0],
            wasExpandedInCurrentZone: false,
            dragPoint: dragPoints[0]
        ))
        XCTAssertTrue(SplitTabDropContainer.shouldExpandCreateDropHint(
            presentedRect: entryRect,
            wasExpandedInCurrentZone: false,
            dragPoint: entryPoint
        ))
        XCTAssertTrue(SplitTabDropContainer.shouldExpandCreateDropHint(
            presentedRect: base,
            wasExpandedInCurrentZone: true,
            dragPoint: dragPoints[0]
        ), "An expanded card must remain stable until its directional zone changes.")
    }

    func testApproachingCreateDropHintCanReachPointerWithoutAnotherDragEvent() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let base = try XCTUnwrap(SplitTabDropContainer.createDropHintRects(in: area)[.left])
        let dragPoint = CGPoint(x: 200, y: area.midY)
        let center = SplitTabDropContainer.nextApproachingDropHintCenter(
            for: .left,
            in: area,
            presentedRect: base,
            currentTargetCenter: nil,
            dragPoint: dragPoint
        )
        let target = SplitTabDropContainer.createDropHintRect(
            for: .left,
            in: area,
            isActive: true,
            isExpanded: false,
            dragPoint: nil,
            approachingCenter: center
        )

        XCTAssertTrue(target.contains(dragPoint))
    }

    func testApproachingCreateDropHintUsesMirroredPrimaryDirections() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let baseRects = SplitTabDropContainer.createDropHintRects(in: area)
        let cases: [(zone: SplitTabDropContainer.DropZone, first: CGPoint, second: CGPoint, increasing: Bool)] = [
            (.left, CGPoint(x: 430, y: area.midY), CGPoint(x: 300, y: area.midY), true),
            (.right, CGPoint(x: 860, y: area.midY), CGPoint(x: 990, y: area.midY), false),
            (.top, CGPoint(x: area.midX, y: 460), CGPoint(x: area.midX, y: 520), false),
            (.bottom, CGPoint(x: area.midX, y: 229), CGPoint(x: area.midX, y: 170), true),
        ]

        for testCase in cases {
            let base = try XCTUnwrap(baseRects[testCase.zone])
            let firstCenter = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: testCase.zone,
                in: area,
                presentedRect: base,
                currentTargetCenter: nil,
                dragPoint: testCase.first
            )
            let firstRect = SplitTabDropContainer.createDropHintRect(
                for: testCase.zone,
                in: area,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: firstCenter
            )
            let secondCenter = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: testCase.zone,
                in: area,
                presentedRect: firstRect,
                currentTargetCenter: firstCenter,
                dragPoint: testCase.second
            )
            let firstPrimary = testCase.zone == .left || testCase.zone == .right
                ? firstCenter.x
                : firstCenter.y
            let secondPrimary = testCase.zone == .left || testCase.zone == .right
                ? secondCenter.x
                : secondCenter.y

            if testCase.increasing {
                XCTAssertGreaterThanOrEqual(secondPrimary, firstPrimary, "\(testCase.zone) approach must not reverse.")
            } else {
                XCTAssertLessThanOrEqual(secondPrimary, firstPrimary, "\(testCase.zone) approach must not reverse.")
            }
        }
    }

    func testApproachingCreateDropHintNeverMovesAwayFromPointerAtOuterEdge() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let baseRects = SplitTabDropContainer.createDropHintRects(in: area)
        let cases: [(zone: SplitTabDropContainer.DropZone, point: CGPoint)] = [
            (.left, CGPoint(x: area.minX + 1, y: area.midY)),
            (.right, CGPoint(x: area.maxX - 1, y: area.midY)),
            (.top, CGPoint(x: area.midX, y: area.maxY - 1)),
            (.bottom, CGPoint(x: area.midX, y: area.minY + 1)),
        ]

        for testCase in cases {
            let base = try XCTUnwrap(baseRects[testCase.zone])
            let center = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: testCase.zone,
                in: area,
                presentedRect: base,
                currentTargetCenter: nil,
                dragPoint: testCase.point
            )
            let oldPrimary = testCase.zone == .left || testCase.zone == .right
                ? base.midX
                : base.midY
            let newPrimary = testCase.zone == .left || testCase.zone == .right
                ? center.x
                : center.y
            let pointerPrimary = testCase.zone == .left || testCase.zone == .right
                ? testCase.point.x
                : testCase.point.y

            XCTAssertLessThan(
                abs(newPrimary - pointerPrimary),
                abs(oldPrimary - pointerPrimary),
                "Approach must not move the \(testCase.zone) card away from the pointer."
            )

            let target = SplitTabDropContainer.createDropHintRect(
                for: testCase.zone,
                in: area,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: center
            )
            XCTAssertTrue(target.contains(testCase.point))
        }
    }

    func testSideCardsKeepInnerEdgeEntryInsideWhileGrowing() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let baseRects = SplitTabDropContainer.createDropHintRects(in: area)
        let cases: [(zone: SplitTabDropContainer.DropZone, point: CGPoint)] = [
            (.left, CGPoint(x: 173, y: area.midY)),
            (.right, CGPoint(x: 1117, y: area.midY)),
        ]

        for testCase in cases {
            let base = try XCTUnwrap(baseRects[testCase.zone])
            let center = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: testCase.zone,
                in: area,
                presentedRect: base,
                currentTargetCenter: nil,
                dragPoint: testCase.point
            )
            let approach = SplitTabDropContainer.createDropHintRect(
                for: testCase.zone,
                in: area,
                isActive: true,
                isExpanded: false,
                dragPoint: nil,
                approachingCenter: center
            )
            let expanded = SplitTabDropContainer.createDropHintRect(
                for: testCase.zone,
                in: area,
                isActive: true,
                isExpanded: true,
                dragPoint: testCase.point,
                followDragAnchor: testCase.point,
                followCenterAnchor: center
            )

            XCTAssertTrue(approach.contains(testCase.point))
            XCTAssertTrue(expanded.contains(testCase.point))
            XCTAssertTrue(area.contains(expanded))
        }
    }

    func testExpandedSideCardsKeepOuterEdgeEntryInsideAfterSafeAlignment() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let baseRects = SplitTabDropContainer.createDropHintRects(in: area)
        let cases: [(zone: SplitTabDropContainer.DropZone, point: CGPoint)] = [
            (.left, CGPoint(x: 14, y: area.midY)),
            (.right, CGPoint(x: 1276, y: area.midY)),
        ]

        for testCase in cases {
            let base = try XCTUnwrap(baseRects[testCase.zone])
            let safeCenter = SplitTabDropContainer.nextApproachingDropHintCenter(
                for: testCase.zone,
                in: area,
                presentedRect: base,
                currentTargetCenter: nil,
                dragPoint: testCase.point
            )
            let expanded = SplitTabDropContainer.createDropHintRect(
                for: testCase.zone,
                in: area,
                isActive: true,
                isExpanded: true,
                dragPoint: testCase.point,
                followDragAnchor: testCase.point,
                followCenterAnchor: safeCenter
            )

            XCTAssertTrue(expanded.contains(testCase.point))
        }
    }

    func testExpandedCreateDropHintDampsPointerMotionFromEntryAnchor() throws {
        let area = CGRect(x: 0, y: 0, width: 1290, height: 689)
        let leftEntryPoint = CGPoint(x: 200, y: area.midY)
        let leftEntryCenter = CGPoint(x: 150, y: area.midY)
        let movingLeft = SplitTabDropContainer.createDropHintRect(
            for: .left,
            in: area,
            isActive: true,
            dragPoint: CGPoint(x: 300, y: area.midY + 40),
            followDragAnchor: leftEntryPoint,
            followCenterAnchor: leftEntryCenter
        )
        XCTAssertEqual(movingLeft.midX, leftEntryCenter.x + 30, accuracy: 0.0001)
        XCTAssertEqual(movingLeft.midY, leftEntryCenter.y + 4, accuracy: 0.0001)

        let topEntryPoint = CGPoint(x: area.midX, y: 600)
        let topEntryCenter = CGPoint(x: area.midX, y: 600)
        let movingTop = SplitTabDropContainer.createDropHintRect(
            for: .top,
            in: area,
            isActive: true,
            dragPoint: CGPoint(x: area.midX + 40, y: 590),
            followDragAnchor: topEntryPoint,
            followCenterAnchor: topEntryCenter
        )
        XCTAssertEqual(movingTop.midX, topEntryCenter.x + 4, accuracy: 0.0001)
        XCTAssertEqual(movingTop.midY, topEntryCenter.y - 3, accuracy: 0.0001)

        let extremePoints: [SplitTabDropContainer.DropZone: CGPoint] = [
            .left: CGPoint(x: area.minX, y: area.minY),
            .right: CGPoint(x: area.maxX, y: area.maxY),
            .top: CGPoint(x: area.maxX, y: area.maxY),
            .bottom: CGPoint(x: area.minX, y: area.minY),
        ]
        for (zone, point) in extremePoints {
            let active = SplitTabDropContainer.createDropHintRect(
                for: zone,
                in: area,
                isActive: true,
                dragPoint: point
            )
            XCTAssertTrue(area.contains(active), "\(zone) must remain inside the page area while following the pointer.")
        }
    }

    func testActiveCreateDropHintDoesNotOverlapInactiveCardsAtMotionExtremes() throws {
        let areas = [
            CGRect(x: 0, y: 0, width: 1290, height: 689),
            CGRect(x: 0, y: 0, width: 800, height: 1000),
            CGRect(x: 0, y: 0, width: 2000, height: 400),
            CGRect(x: 50, y: 80, width: 320, height: 180),
        ]
        let zones: [SplitTabDropContainer.DropZone] = [.left, .right, .top, .bottom]

        for area in areas {
            let dragPoints: [SplitTabDropContainer.DropZone: CGPoint] = [
                .left: CGPoint(x: area.maxX, y: area.maxY),
                .right: CGPoint(x: area.minX, y: area.minY),
                .top: CGPoint(x: area.maxX, y: area.minY),
                .bottom: CGPoint(x: area.minX, y: area.maxY),
            ]
            for activeZone in zones {
                let base = try XCTUnwrap(SplitTabDropContainer.createDropHintRects(in: area)[activeZone])
                let active = SplitTabDropContainer.createDropHintRect(
                    for: activeZone,
                    in: area,
                    isActive: true,
                    dragPoint: dragPoints[activeZone],
                    followDragAnchor: CGPoint(x: base.midX, y: base.midY),
                    followCenterAnchor: CGPoint(x: base.midX, y: base.midY)
                )
                for inactiveZone in zones where inactiveZone != activeZone {
                    let inactive = try XCTUnwrap(SplitTabDropContainer.createDropHintRects(in: area)[inactiveZone])
                    XCTAssertFalse(active.intersects(inactive), "\(activeZone) must not overlap \(inactiveZone) while following in \(area).")
                }
            }
        }
    }

    func testActiveCreateDropHintDoesNotCrossConfiguredMovementBoundary() {
        let areas = [
            CGRect(x: 0, y: 0, width: 1290, height: 689),
            CGRect(x: 50, y: 80, width: 320, height: 180),
        ]

        for area in areas {
            let dragPoints: [SplitTabDropContainer.DropZone: CGPoint] = [
                .left: CGPoint(x: area.maxX, y: area.midY),
                .right: CGPoint(x: area.minX, y: area.midY),
                .top: CGPoint(x: area.midX, y: area.minY),
                .bottom: CGPoint(x: area.midX, y: area.maxY),
            ]
            for (zone, point) in dragPoints {
                let rect = SplitTabDropContainer.createDropHintRect(
                    for: zone,
                    in: area,
                    isActive: true,
                    dragPoint: point
                )
                let minimumFraction = zone == .left || zone == .right
                    ? rect.width / area.width
                    : rect.height / area.height
                let configuredFraction = min(
                    max(
                        SplitTabDropContainer.dropHintMovementRangeFraction,
                        minimumFraction
                    ),
                    0.5
                )
                let fraction = minimumFraction
                    + (configuredFraction - minimumFraction)
                    * SplitTabDropContainer.dropHintMovementTravelScale
                switch zone {
                case .left:
                    XCTAssertEqual(
                        rect.maxX,
                        area.minX + area.width * fraction,
                        accuracy: 0.0001
                    )
                case .right:
                    XCTAssertEqual(
                        rect.minX,
                        area.maxX - area.width * fraction,
                        accuracy: 0.0001
                    )
                case .top:
                    XCTAssertEqual(
                        rect.minY,
                        area.maxY - area.height * fraction,
                        accuracy: 0.0001
                    )
                case .bottom:
                    XCTAssertEqual(
                        rect.maxY,
                        area.minY + area.height * fraction,
                        accuracy: 0.0001
                    )
                }
            }
        }
    }

    func testActiveCreateDropZoneUsesExitHysteresisNearInitialEdge() {
        let area = CGRect(x: 0, y: 0, width: 900, height: 600)

        XCTAssertNil(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: 306, y: area.midY),
            in: area
        ))
        XCTAssertEqual(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: 306, y: area.midY),
            in: area,
            retaining: .left
        ), .left)
        XCTAssertNil(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: 320, y: area.midY),
            in: area,
            retaining: .left
        ))

        XCTAssertNil(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: area.midX, y: 394),
            in: area
        ))
        XCTAssertEqual(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: area.midX, y: 394),
            in: area,
            retaining: .top
        ), .top)
        XCTAssertNil(SplitTabDropContainer.createDropZone(
            for: CGPoint(x: area.midX, y: 380),
            in: area,
            retaining: .top
        ))

        for x in [301, 299, 301] {
            XCTAssertEqual(SplitTabDropContainer.createDropZone(
                for: CGPoint(x: CGFloat(x), y: 500),
                in: area,
                retaining: .top
            ), .top, "Corner overlap must not make the active zone oscillate.")
        }
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
