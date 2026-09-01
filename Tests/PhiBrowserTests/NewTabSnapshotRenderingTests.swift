// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import XCTest
@testable import Phi

final class NewTabSnapshotRenderingTests: XCTestCase {
    func testSnapshotTitleImagePreservesTertiaryTextAlpha() throws {
        let expectedAlpha: CGFloat = 0.3
        let image = try XCTUnwrap(
            NewTabButtonCellView.makeSnapshotTitleImage(
                text: "New Tab",
                font: .systemFont(ofSize: 13),
                color: NSColor.black.withAlphaComponent(expectedAlpha),
                size: NSSize(width: 53, height: 16)
            )
        )

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageAlignment = .alignBottomLeft
        imageView.imageScaling = .scaleNone

        let maximumAlpha = try maximumRenderedAlpha(in: imageView)
        XCTAssertEqual(maximumAlpha, expectedAlpha, accuracy: 0.01)
    }

    func testStaticSnapshotContentRestoresLiveNewTabViews() {
        let cell = NewTabButtonCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        cell.layoutSubtreeIfNeeded()

        let title = cell.descendants(ofType: NSTextField.self).first
        XCTAssertNotNil(title)
        XCTAssertFalse(title?.isHidden ?? true)

        cell.withStaticSnapshotContent {
            XCTAssertTrue(title?.isHidden ?? false)
            let visibleImages = cell.descendants(ofType: NSImageView.self)
                .filter { !$0.isHidden && $0.image != nil }
            XCTAssertGreaterThanOrEqual(visibleImages.count, 1)
        }

        XCTAssertFalse(title?.isHidden ?? true)
    }

    func testStaticSnapshotContentKeepsTitleHorizontalPosition() throws {
        let cell = NewTabButtonCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        cell.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(cell.descendants(ofType: NSTextField.self).first)
        let snapshotTitle = try XCTUnwrap(cell.descendants(ofType: SnapshotTitleView.self).first)
        let liveBounds = try renderedAlphaBounds(in: title, within: title.bounds)
        var snapshotBounds: NSRect?

        try cell.withStaticSnapshotContent {
            snapshotBounds = try renderedAlphaBounds(in: snapshotTitle, within: snapshotTitle.bounds)
        }

        XCTAssertEqual(cell.convert(snapshotTitle.bounds, from: snapshotTitle).minX,
                       cell.convert(title.bounds, from: title).minX)
        XCTAssertEqual(snapshotBounds?.minX, liveBounds.minX)
        XCTAssertEqual(snapshotBounds?.maxX, liveBounds.maxX)
    }

    func testFloatingNewTabUsesTheSameSnapshotContentPath() {
        let floatingView = FloatingNewTabView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 36)
        )
        floatingView.layout()
        floatingView.cellView.layoutSubtreeIfNeeded()

        let title = floatingView.cellView.descendants(ofType: NSTextField.self).first

        floatingView.cellView.withStaticSnapshotContent {
            XCTAssertTrue(title?.isHidden ?? false)
        }

        XCTAssertFalse(title?.isHidden ?? true)
    }

    private func maximumRenderedAlpha(in view: NSView) throws -> CGFloat {
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)

        var maximumAlpha: CGFloat = 0
        for y in 0..<representation.pixelsHigh {
            for x in 0..<representation.pixelsWide {
                guard let color = representation.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                maximumAlpha = max(maximumAlpha, color.alphaComponent)
            }
        }
        return maximumAlpha
    }

    private func renderedAlphaBounds(in view: NSView, within rect: NSRect) throws -> NSRect {
        let representation = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)

        var minimumX = Int.max
        var maximumX = Int.min
        var minimumY = Int.max
        var maximumY = Int.min
        let scaleX = CGFloat(representation.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(representation.pixelsHigh) / view.bounds.height
        let minimumPixelX = Int((rect.minX * scaleX).rounded(.down))
        let maximumPixelX = Int((rect.maxX * scaleX).rounded(.up))
        let minimumPixelY = Int((rect.minY * scaleY).rounded(.down))
        let maximumPixelY = Int((rect.maxY * scaleY).rounded(.up))
        let xRange = minimumPixelX..<maximumPixelX
        let yRange = minimumPixelY..<maximumPixelY
        for y in yRange {
            for x in xRange {
                guard let alpha = representation.colorAt(x: x, y: y)?.alphaComponent,
                      alpha > 0.01 else { continue }
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
            }
        }

        guard minimumX <= maximumX, minimumY <= maximumY else {
            throw NSError(domain: "NewTabSnapshotRenderingTests", code: 1)
        }
        return NSRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX + 1,
            height: maximumY - minimumY + 1
        )
    }
}

private extension NSView {
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            let current = (subview as? T).map { [$0] } ?? []
            return current + subview.descendants(ofType: type)
        }
    }
}
