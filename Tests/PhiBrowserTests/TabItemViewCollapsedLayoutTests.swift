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

    func testActiveTabUsesAddressBarColorAcrossBodyAndInverseCorners() throws {
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
        let addressBarColor = NSColor(srgbRed: 0.24, green: 0.07, blue: 0.31, alpha: 1)
        view.setActivePageStyle(backgroundColor: addressBarColor, appearance: .dark)
        view.layout()

        let background = try XCTUnwrap(
            view.layer?.sublayers?.compactMap { $0 as? TabBackgroundLayer }.first
        )
        let fillColor = try XCTUnwrap(background.fillColor.flatMap(NSColor.init(cgColor:)))
        let fill = try XCTUnwrap(fillColor.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(addressBarColor.usingColorSpace(.sRGB))
        XCTAssertEqual(fill.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(fill.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(fill.blueComponent, expected.blueComponent, accuracy: 0.001)

        let paintedBounds = try XCTUnwrap(background.path).boundingBoxOfPath
        XCTAssertLessThan(paintedBounds.minX, view.bounds.minX)
        XCTAssertGreaterThan(paintedBounds.maxX, view.bounds.maxX)
        XCTAssertEqual(view.appearance?.phiAppearance, .dark)
        XCTAssertTrue(view.subviews.allSatisfy { $0.effectiveAppearance.phiAppearance == .dark })

        view.setActivePageStyle(backgroundColor: nil, appearance: nil)
        XCTAssertNil(view.appearance)
        let fallbackFillColor = try XCTUnwrap(
            background.fillColor.flatMap(NSColor.init(cgColor:))
        )
        let fallbackFill = try XCTUnwrap(fallbackFillColor.usingColorSpace(.sRGB))
        let expectedFallback = try XCTUnwrap(
            ThemedColor.windowBackground.resolve(in: view).usingColorSpace(.sRGB)
        )
        XCTAssertEqual(fallbackFill.redComponent, expectedFallback.redComponent, accuracy: 0.001)
        XCTAssertEqual(fallbackFill.greenComponent, expectedFallback.greenComponent, accuracy: 0.001)
        XCTAssertEqual(fallbackFill.blueComponent, expectedFallback.blueComponent, accuracy: 0.001)
    }

    func test_inactivePinnedTabDoesNotDrawStateBorder() {
        let layer = makeBackgroundLayer()
        layer.isPinned = true
        layer.tabState = .inactive

        XCTAssertEqual(layer.lineWidth, 0)
        XCTAssertNil(layer.lineDashPattern)
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
