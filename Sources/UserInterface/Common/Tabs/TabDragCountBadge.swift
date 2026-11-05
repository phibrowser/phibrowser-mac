// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

enum TabDragCountBadge {
    private static let height: CGFloat = 21
    private static let horizontalPadding: CGFloat = 10.5
    private static let font = NSFont.systemFont(ofSize: 12, weight: .bold)

    static func size(for count: Int) -> CGSize {
        let text = displayText(for: count) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = ceil(text.size(withAttributes: attributes).width)
        return CGSize(
            width: max(height, textWidth + horizontalPadding),
            height: height
        )
    }

    static func image(_ image: NSImage, drawingBadgeCount count: Int, nearAnchor anchor: CGPoint) -> NSImage {
        let badgeSize = size(for: count)
        let badgeOrigin = badgeOrigin(nearAnchor: anchor, badgeSize: badgeSize, canvasSize: image.size)
        let result = NSImage(size: image.size)
        result.lockFocus()
        defer { result.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: CGRect(origin: .zero, size: image.size),
            from: CGRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        draw(
            count: count,
            in: CGRect(origin: badgeOrigin, size: badgeSize)
        )
        return result
    }

    static func draw(count: Int, in rect: CGRect) {
        let drawingRect = rect.insetBy(dx: 0.5, dy: 0.5)
        guard drawingRect.width > 0, drawingRect.height > 0 else { return }

        let path = NSBezierPath(
            roundedRect: drawingRect,
            xRadius: drawingRect.height * 0.5,
            yRadius: drawingRect.height * 0.5
        )
        NSColor.systemRed.setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = displayText(for: count) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: drawingRect.midX - textSize.width * 0.5,
                y: drawingRect.midY - textSize.height * 0.5 - 0.375
            ),
            withAttributes: attributes
        )
    }

    static func visibleUnitCount(tabIds: [Int], browserState: BrowserState) -> Int {
        visibleRepresentativeTabIds(tabIds: tabIds, browserState: browserState).count
    }

    static func visibleRepresentativeTabIds(tabIds: [Int], browserState: BrowserState) -> [Int] {
        let representedIds = Set(tabIds)
        var consumedIds = Set<Int>()
        var visibleIds: [Int] = []

        for tabId in tabIds {
            guard !consumedIds.contains(tabId) else { continue }
            consumedIds.insert(tabId)

            // A split travels as one unit: every other pane that is also
            // represented folds into this one.
            if let group = browserState.splitGroup(forTabId: tabId), !group.isPinned {
                for otherId in group.otherTabIds(of: tabId) where representedIds.contains(otherId) {
                    consumedIds.insert(otherId)
                }
            }

            visibleIds.append(tabId)
        }

        return visibleIds
    }

    private static func badgeOrigin(nearAnchor anchor: CGPoint, badgeSize: CGSize, canvasSize: CGSize) -> CGPoint {
        let gap: CGFloat = 4
        let inset: CGFloat = 2
        let minX = inset
        let minY = inset
        let maxX = Swift.max(minX, canvasSize.width - badgeSize.width - inset)
        let maxY = Swift.max(minY, canvasSize.height - badgeSize.height - inset)
        return CGPoint(
            x: Swift.min(Swift.max(anchor.x + gap, minX), maxX),
            y: Swift.min(Swift.max(anchor.y - badgeSize.height * 0.5, minY), maxY)
        )
    }

    private static func displayText(for count: Int) -> String {
        "\(max(0, count))"
    }
}

final class TabDragCountBadgeView: NSView {
    var count: Int = 0 {
        didSet {
            guard oldValue != count else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        TabDragCountBadge.draw(count: count, in: bounds)
    }
}
