// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CoreGraphics

enum ImagePreviewGeometry {
    static func fitScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return 1
        }

        return min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
    }

    static func clampedScale(_ value: CGFloat, min minScale: CGFloat, max maxScale: CGFloat) -> CGFloat {
        Swift.max(minScale, Swift.min(maxScale, value))
    }

    static func clampedContentPoint(candidate: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: Swift.max(0, Swift.min(candidate.x, imageSize.width)),
            y: Swift.max(0, Swift.min(candidate.y, imageSize.height))
        )
    }

    static func centeredOrigin(contentSize: CGSize, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: max((contentSize.width - viewportSize.width) * 0.5, 0),
            y: max((contentSize.height - viewportSize.height) * 0.5, 0)
        )
    }

    static func clampedOrigin(candidate: CGPoint, contentSize: CGSize, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: Swift.max(0, Swift.min(candidate.x, max(contentSize.width - viewportSize.width, 0))),
            y: Swift.max(0, Swift.min(candidate.y, max(contentSize.height - viewportSize.height, 0)))
        )
    }

    static func anchoredOrigin(
        viewportSize: CGSize,
        anchorContentPoint: CGPoint,
        imageFrameOrigin: CGPoint,
        scale: CGFloat,
        canvasSize: CGSize
    ) -> CGPoint {
        anchoredOrigin(
            viewportSize: viewportSize,
            anchorContentPoint: anchorContentPoint,
            imageFrameOrigin: imageFrameOrigin,
            scale: scale,
            canvasSize: canvasSize,
            anchorViewportPoint: CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
        )
    }

    static func anchoredOrigin(
        viewportSize: CGSize,
        anchorContentPoint: CGPoint,
        imageFrameOrigin: CGPoint,
        scale: CGFloat,
        canvasSize: CGSize,
        anchorViewportPoint: CGPoint
    ) -> CGPoint {
        let anchorPoint = CGPoint(
            x: imageFrameOrigin.x + (anchorContentPoint.x * scale),
            y: imageFrameOrigin.y + (anchorContentPoint.y * scale)
        )
        let candidate = CGPoint(
            x: anchorPoint.x - anchorViewportPoint.x,
            y: anchorPoint.y - anchorViewportPoint.y
        )
        return clampedOrigin(candidate: candidate, contentSize: canvasSize, viewportSize: viewportSize)
    }
}
