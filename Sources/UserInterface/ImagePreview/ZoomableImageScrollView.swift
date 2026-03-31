// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

final class ZoomableImageScrollView: NSScrollView {
    private final class CanvasView: NSView {
        weak var owner: ZoomableImageScrollView?
        private var panStartPoint: NSPoint?
        private var panStartOrigin: CGPoint = .zero

        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let owner, owner.canPan else {
                super.mouseDown(with: event)
                return
            }

            panStartPoint = event.locationInWindow
            panStartOrigin = owner.contentView.bounds.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let owner, owner.canPan, let panStartPoint else {
                super.mouseDragged(with: event)
                return
            }

            let deltaX = event.locationInWindow.x - panStartPoint.x
            let deltaY = event.locationInWindow.y - panStartPoint.y
            owner.pan(from: panStartOrigin, deltaX: deltaX, deltaY: deltaY)
        }
    }

    private let canvasView = CanvasView()
    private let imageView = NSImageView()
    private var intrinsicImageSize: CGSize = .zero
    private var lastViewportSize: CGSize = .zero
    private var activeMagnifyAnchorContentPoint: CGPoint?

    var fitScale: CGFloat = 1
    var zoomScale: CGFloat = 1
    var minimumScale: CGFloat = 1
    var maximumScale: CGFloat = 8
    var onZoomChanged: ((CGFloat, CGFloat, CGFloat) -> Void)?

    /// Smallest scale vs. intrinsic image size (1 = native); clamp floor is `min(fitScale, this)`.
    private static let subFitMinimumScaleRelativeToOriginal: CGFloat = 0.2

    var canPan: Bool {
        zoomScale > fitScale + 0.001
    }

    /// Center of the visible area in viewport coordinates (origin top-left of visible rect), for zoom anchor math.
    private var viewportCenterAnchor: CGPoint {
        let b = contentView.bounds
        return CGPoint(x: b.width * 0.5, y: b.height * 0.5)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        scrollerStyle = .overlay
        allowsMagnification = false

        canvasView.owner = self
        documentView = canvasView

        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleAxesIndependently
        canvasView.addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        let viewportSize = contentView.bounds.size
        guard viewportSize != .zero else { return }
        guard lastViewportSize != viewportSize else { return }

        let shouldPreserveFocus = canPan
        lastViewportSize = viewportSize

        if shouldPreserveFocus {
            relayoutPreservingVisibleCenter()
        } else {
            resetToFit()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        let anchorInWindow = event.locationInWindow
        let anchorInViewport = anchorViewportPoint(fromWindowPoint: anchorInWindow)
        let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.12 : (1 / 1.12)
        zoom(by: factor, anchorInContentView: anchorInViewport)
    }

    override func magnify(with event: NSEvent) {
        guard intrinsicImageSize.width > 0, intrinsicImageSize.height > 0 else {
            super.magnify(with: event)
            return
        }

        if event.phase.contains(.began) || activeMagnifyAnchorContentPoint == nil {
            let previousAnchor = activeMagnifyAnchorContentPoint
            let anchorInViewport = anchorViewportPoint(fromWindowPoint: event.locationInWindow)
            activeMagnifyAnchorContentPoint = contentPoint(
                for: anchorInViewport
            )
            AppLogDebug(
                "\(Self.pinchLogPrefix) anchor set phase=\(describe(phase: event.phase)) " +
                "locationInWindow=\(describe(point: event.locationInWindow)) " +
                "anchorInViewport=\(describe(point: anchorInViewport)) " +
                "previousAnchor=\(describe(point: previousAnchor)) " +
                "newAnchor=\(describe(point: activeMagnifyAnchorContentPoint)) " +
                "zoomScale=\(String(format: "%.4f", zoomScale))"
            )
        }

        // AppKit reports magnification as a delta; convert it to a scale factor.
        let factor = max(0.01, 1 + event.magnification)
        if let activeMagnifyAnchorContentPoint {
            let oldScale = zoomScale
            let anchorInViewport = anchorViewportPoint(fromWindowPoint: event.locationInWindow)
            zoom(
                by: factor,
                anchorContentPoint: activeMagnifyAnchorContentPoint,
                anchorViewportPoint: anchorInViewport
            )
            AppLogDebug(
                "\(Self.pinchLogPrefix) apply phase=\(describe(phase: event.phase)) " +
                "magnification=\(String(format: "%.4f", event.magnification)) " +
                "factor=\(String(format: "%.4f", factor)) " +
                "anchor=\(describe(point: activeMagnifyAnchorContentPoint)) " +
                "anchorInViewport=\(describe(point: anchorInViewport)) " +
                "scale=\(String(format: "%.4f", oldScale))->\(String(format: "%.4f", zoomScale)) " +
                "origin=\(describe(point: contentView.bounds.origin))"
            )
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            AppLogDebug(
                "\(Self.pinchLogPrefix) anchor cleared in magnify phase=\(describe(phase: event.phase)) " +
                "anchor=\(describe(point: activeMagnifyAnchorContentPoint))"
            )
            activeMagnifyAnchorContentPoint = nil
        }
    }

    override func endGesture(with event: NSEvent) {
        AppLogDebug(
            "\(Self.pinchLogPrefix) endGesture phase=\(describe(phase: event.phase)) " +
            "anchor=\(describe(point: activeMagnifyAnchorContentPoint))"
        )
        activeMagnifyAnchorContentPoint = nil
        super.endGesture(with: event)
    }

    func display(asset: ImagePreviewAsset) {
        imageView.image = asset.image
        intrinsicImageSize = asset.pixelSize == .zero ? asset.image.size : asset.pixelSize
        lastViewportSize = .zero
        resetToFit()
    }

    func clear() {
        imageView.image = nil
        intrinsicImageSize = .zero
        canvasView.frame = .zero
        imageView.frame = .zero
        activeMagnifyAnchorContentPoint = nil
        fitScale = 1
        zoomScale = 1
        minimumScale = 1
        scroll(to: .zero)
        onZoomChanged?(zoomScale, fitScale, minimumScale)
    }

    func resetToFit() {
        guard intrinsicImageSize.width > 0, intrinsicImageSize.height > 0 else { return }
        let viewportSize = contentView.bounds.size
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }

        fitScale = ImagePreviewGeometry.fitScale(imageSize: intrinsicImageSize, viewportSize: viewportSize)
        minimumScale = min(fitScale, Self.subFitMinimumScaleRelativeToOriginal)
        zoomScale = fitScale
        activeMagnifyAnchorContentPoint = nil
        relayout()
        scroll(to: .zero)
        onZoomChanged?(zoomScale, fitScale, minimumScale)
    }

    func zoomIn() {
        zoom(by: 1.12, anchorInContentView: viewportCenterAnchor)
    }

    func zoomOut() {
        zoom(by: 1 / 1.12, anchorInContentView: viewportCenterAnchor)
    }

    func zoom(by factor: CGFloat, anchorInContentView: CGPoint) {
        let anchorContentPt = contentPoint(for: anchorInContentView)
        zoom(by: factor, anchorContentPoint: anchorContentPt, anchorViewportPoint: anchorInContentView)
    }

    private func zoom(by factor: CGFloat, anchorContentPoint: CGPoint) {
        zoom(by: factor, anchorContentPoint: anchorContentPoint, anchorViewportPoint: nil)
    }

    private func zoom(by factor: CGFloat, anchorContentPoint: CGPoint, anchorViewportPoint: CGPoint?) {
        guard intrinsicImageSize.width > 0, intrinsicImageSize.height > 0 else { return }
        let clampMin = min(fitScale, Self.subFitMinimumScaleRelativeToOriginal)
        let newScale = ImagePreviewGeometry.clampedScale(zoomScale * factor, min: clampMin, max: maximumScale)
        guard abs(newScale - zoomScale) > 0.0001 else { return }
        zoomScale = newScale
        minimumScale = effectiveLowerBound()

        if abs(zoomScale - minimumScale) < 0.0001 {
            relayout()
            let centered = ImagePreviewGeometry.centeredOrigin(
                contentSize: canvasView.bounds.size,
                viewportSize: contentView.bounds.size
            )
            scroll(to: centered)
            onZoomChanged?(zoomScale, fitScale, minimumScale)
            return
        }

        if zoomScale < fitScale - 0.0001 {
            relayout()
            let centered = ImagePreviewGeometry.centeredOrigin(
                contentSize: canvasView.bounds.size,
                viewportSize: contentView.bounds.size
            )
            scroll(to: centered)
            onZoomChanged?(zoomScale, fitScale, minimumScale)
            return
        }

        relayout(anchorContentPoint: anchorContentPoint, anchorViewportPoint: anchorViewportPoint)

        let newOrigin: CGPoint
        if let anchorViewportPoint {
            newOrigin = ImagePreviewGeometry.anchoredOrigin(
                viewportSize: contentView.bounds.size,
                anchorContentPoint: anchorContentPoint,
                imageFrameOrigin: imageView.frame.origin,
                scale: zoomScale,
                canvasSize: canvasView.bounds.size,
                anchorViewportPoint: anchorViewportPoint
            )
        } else {
            newOrigin = ImagePreviewGeometry.anchoredOrigin(
                viewportSize: contentView.bounds.size,
                anchorContentPoint: anchorContentPoint,
                imageFrameOrigin: imageView.frame.origin,
                scale: zoomScale,
                canvasSize: canvasView.bounds.size
            )
        }
        scroll(to: newOrigin)
        onZoomChanged?(zoomScale, fitScale, minimumScale)
    }

    private func effectiveLowerBound() -> CGFloat {
        min(fitScale, Self.subFitMinimumScaleRelativeToOriginal)
    }

    private func anchorViewportPoint(fromWindowPoint point: CGPoint) -> CGPoint {
        let anchorInSelf = convert(point, from: nil)
        let anchorInDocument = contentView.convert(anchorInSelf, from: self)
        return CGPoint(
            x: anchorInDocument.x - contentView.bounds.origin.x,
            y: anchorInDocument.y - contentView.bounds.origin.y
        )
    }

    private func contentPoint(for anchorInContentView: CGPoint) -> CGPoint {
        let documentAnchorPoint = CGPoint(
            x: contentView.bounds.origin.x + anchorInContentView.x,
            y: contentView.bounds.origin.y + anchorInContentView.y
        )
        let oldImageFrame = imageView.frame
        let oldScale = max(zoomScale, 0.0001)
        let candidate = CGPoint(
            x: (documentAnchorPoint.x - oldImageFrame.minX) / oldScale,
            y: (documentAnchorPoint.y - oldImageFrame.minY) / oldScale
        )
        return ImagePreviewGeometry.clampedContentPoint(candidate: candidate, imageSize: intrinsicImageSize)
    }

    private func relayoutPreservingVisibleCenter() {
        let oldImageFrame = imageView.frame
        let oldScale = max(zoomScale, 0.0001)
        let visibleCenter = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        let anchorContentPoint = CGPoint(
            x: max((visibleCenter.x - oldImageFrame.minX) / oldScale, 0),
            y: max((visibleCenter.y - oldImageFrame.minY) / oldScale, 0)
        )

        let viewportSize = contentView.bounds.size
        let nextFitScale = ImagePreviewGeometry.fitScale(imageSize: intrinsicImageSize, viewportSize: viewportSize)
        fitScale = nextFitScale
        zoomScale = max(zoomScale, nextFitScale)
        relayout()

        let origin = ImagePreviewGeometry.anchoredOrigin(
            viewportSize: viewportSize,
            anchorContentPoint: anchorContentPoint,
            imageFrameOrigin: imageView.frame.origin,
            scale: zoomScale,
            canvasSize: canvasView.bounds.size
        )
        scroll(to: origin)
        minimumScale = effectiveLowerBound()
        onZoomChanged?(zoomScale, fitScale, minimumScale)
    }

    private func relayout() {
        let viewportSize = contentView.bounds.size
        let scaledSize = CGSize(width: intrinsicImageSize.width * zoomScale, height: intrinsicImageSize.height * zoomScale)
        let canvasSize = CGSize(width: max(scaledSize.width, viewportSize.width), height: max(scaledSize.height, viewportSize.height))
        canvasView.frame = CGRect(origin: .zero, size: canvasSize)

        let imageOrigin = centeredImageOrigin(canvasSize: canvasSize, scaledSize: scaledSize)
        imageView.frame = CGRect(origin: imageOrigin, size: scaledSize)
    }

    private func relayout(anchorContentPoint: CGPoint, anchorViewportPoint: CGPoint?) {
        guard let anchorViewportPoint else {
            relayout()
            return
        }

        let viewportSize = contentView.bounds.size
        let scaledSize = CGSize(width: intrinsicImageSize.width * zoomScale, height: intrinsicImageSize.height * zoomScale)
        let canvasSize = CGSize(width: max(scaledSize.width, viewportSize.width), height: max(scaledSize.height, viewportSize.height))
        canvasView.frame = CGRect(origin: .zero, size: canvasSize)

        let centeredOrigin = centeredImageOrigin(canvasSize: canvasSize, scaledSize: scaledSize)
        let anchoredOrigin = CGPoint(
            x: anchoredImageOrigin(
                scaledDimension: scaledSize.width,
                viewportDimension: viewportSize.width,
                anchorContentOffset: anchorContentPoint.x * zoomScale,
                anchorViewportOffset: anchorViewportPoint.x
            ),
            y: anchoredImageOrigin(
                scaledDimension: scaledSize.height,
                viewportDimension: viewportSize.height,
                anchorContentOffset: anchorContentPoint.y * zoomScale,
                anchorViewportOffset: anchorViewportPoint.y
            )
        )
        let imageOrigin = CGPoint(
            x: scaledSize.width < viewportSize.width ? anchoredOrigin.x : centeredOrigin.x,
            y: scaledSize.height < viewportSize.height ? anchoredOrigin.y : centeredOrigin.y
        )
        imageView.frame = CGRect(origin: imageOrigin, size: scaledSize)
    }

    private func pan(from startOrigin: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        let candidate = CGPoint(
            x: startOrigin.x - deltaX,
            y: startOrigin.y + deltaY
        )
        let origin = ImagePreviewGeometry.clampedOrigin(
            candidate: candidate,
            contentSize: canvasView.bounds.size,
            viewportSize: contentView.bounds.size
        )
        scroll(to: origin)
    }

    private func scroll(to origin: CGPoint) {
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func centeredImageOrigin(canvasSize: CGSize, scaledSize: CGSize) -> CGPoint {
        CGPoint(
            x: max((canvasSize.width - scaledSize.width) * 0.5, 0),
            y: max((canvasSize.height - scaledSize.height) * 0.5, 0)
        )
    }

    private func anchoredImageOrigin(
        scaledDimension: CGFloat,
        viewportDimension: CGFloat,
        anchorContentOffset: CGFloat,
        anchorViewportOffset: CGFloat
    ) -> CGFloat {
        guard scaledDimension < viewportDimension else { return 0 }
        let candidate = anchorViewportOffset - anchorContentOffset
        return max(0, min(candidate, viewportDimension - scaledDimension))
    }

    private static let pinchLogPrefix = "[ImagePreview][Pinch]"

    private func describe(point: CGPoint?) -> String {
        guard let point else { return "nil" }
        return String(format: "(%.2f, %.2f)", point.x, point.y)
    }

    private func describe(phase: NSEvent.Phase) -> String {
        if phase.isEmpty {
            return "[]"
        }

        var parts: [String] = []
        if phase.contains(.mayBegin) { parts.append("mayBegin") }
        if phase.contains(.began) { parts.append("began") }
        if phase.contains(.stationary) { parts.append("stationary") }
        if phase.contains(.changed) { parts.append("changed") }
        if phase.contains(.ended) { parts.append("ended") }
        if phase.contains(.cancelled) { parts.append("cancelled") }
        return "[" + parts.joined(separator: ",") + "]"
    }
}
