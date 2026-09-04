// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class TabItemViewCollapsedLayoutTests: XCTestCase {
    func test_zeroSizedTabItemDoesNotExposeContentSubviews() {
        let view = TabItemView()
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Example",
            url: "https://example.com",
            isActive: false,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))

        view.frame = .zero
        view.layout()

        let visibleNonEmptySubviews = view.subviews.filter {
            !$0.isHidden && !$0.frame.isEmpty
        }

        XCTAssertTrue(
            visibleNonEmptySubviews.isEmpty,
            "Zero-sized tab items must not expose favicon/title subviews."
        )
    }

    /// The background is the other half of that rule, and the half that is
    /// easy to miss: it lives in a sublayer rather than a subview, and
    /// `TabItemView` sets `layer.masksToBounds = false` so the active tab's
    /// inverse curves can reach past the cell. A path built at the cell's
    /// measured size therefore keeps drawing — outside the now-empty bounds —
    /// unless it is dropped too.
    func test_zeroSizedTabItemDropsItsBackgroundPath() {
        let view = TabItemView()
        view.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        view.configure(with: TabRenderData(
            id: "tab-1",
            title: "Example",
            url: "https://example.com",
            isActive: true,
            isPinned: false,
            isSplitGroupActive: false,
            sourceTab: nil
        ))
        view.layout()

        guard let background = view.layer?.sublayers?
            .compactMap({ $0 as? TabBackgroundLayer }).first else {
            return XCTFail("Tab items should own a TabBackgroundLayer.")
        }
        XCTAssertFalse(
            paintedBox(background).isEmpty,
            "Precondition: a measured active tab paints its background."
        )

        view.frame = .zero
        view.layout()

        XCTAssertTrue(
            paintedBox(background).isEmpty,
            "Zero-sized tab items must not keep painting a \(paintedBox(background)) "
            + "background; the layer is unclipped, so a stale path is a stale drawing."
        )

        // Measuring the cell again must bring the background back — dropping
        // the path may not turn into a one-way trip for expanding a group.
        view.frame = CGRect(x: 0, y: 0, width: 180, height: 32)
        view.layout()

        XCTAssertFalse(
            paintedBox(background).isEmpty,
            "Re-measuring the cell should rebuild its background path."
        )
    }

    func test_openInactivePinnedTabDrawsBorder() {
        let layer = makeBackgroundLayer()
        layer.isPinned = true
        layer.tabState = .inactive

        XCTAssertEqual(layer.lineWidth, 0)

        layer.pinnedBorderStyle = .solid

        XCTAssertEqual(layer.lineWidth, 1)
        XCTAssertGreaterThan(layer.strokeColor?.alpha ?? 0, 0)
        XCTAssertNil(layer.lineDashPattern)
    }

    func test_openPinnedTabBorderIsSuppressedWhenActiveOrNotPinned() {
        let layer = makeBackgroundLayer()
        layer.isPinned = true
        layer.pinnedBorderStyle = .solid
        layer.tabState = .active

        XCTAssertEqual(layer.lineWidth, 0)

        layer.tabState = .inactive
        layer.isPinned = false

        XCTAssertEqual(layer.lineWidth, 0)
    }

    func test_discardedOrUnloadedPinnedTabDrawsDashedBorder() {
        let layer = makeBackgroundLayer()
        layer.isPinned = true
        layer.tabState = .inactive

        layer.pinnedBorderStyle = .dashed

        XCTAssertEqual(layer.lineWidth, 1)
        XCTAssertEqual(
            layer.lineDashPattern?.map(\.doubleValue),
            TabStateBorderMetrics.dashPattern.map(Double.init)
        )
    }

    func test_sidebarPinnedTabStateBorderDrawsDashedOutline() {
        let view = PinnedTabStateBorderView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        view.update(style: .dashed, color: .labelColor)
        view.layout()

        guard let layer = view.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first else {
            return XCTFail("Pinned tabs should own a state border layer.")
        }
        XCTAssertFalse(layer.isHidden)
        XCTAssertEqual(layer.lineWidth, 1)
        XCTAssertEqual(
            layer.lineDashPattern?.map(\.doubleValue),
            TabStateBorderMetrics.dashPattern.map(Double.init)
        )
        XCTAssertNotNil(layer.path)
    }

    private func makeBackgroundLayer() -> TabBackgroundLayer {
        let sourceView = NSView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        let layer = TabBackgroundLayer()
        layer.sourceView = sourceView
        layer.frame = sourceView.bounds
        layer.updatePath(in: sourceView.bounds)
        return layer
    }

    /// Bounding box of what the layer actually draws. An absent path and an
    /// empty path both mean "paints nothing".
    private func paintedBox(_ layer: TabBackgroundLayer) -> CGRect {
        guard let path = layer.path else { return .zero }
        let box = path.boundingBoxOfPath
        return box.isNull || box.isInfinite ? .zero : box
    }
}
