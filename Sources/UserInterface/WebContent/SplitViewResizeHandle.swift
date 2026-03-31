// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
class SplitViewResizeHandle: NSView {
    private var isDragging = false
    private var isMouseEntered = false
    private var lastMouseLocation: NSPoint = .zero
    private var trackingArea: NSTrackingArea?
    private var accumulatedDeadZoneDelta: CGFloat = 0

    private var hoverIndicatorLayer: CALayer?
    private var showDelayTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
        setupTrackingArea()
    }

    /// Returns whether resize handling should be disabled for the current layout.
    private func shouldIgnoreResize() -> Bool {
        return PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
    }

    private func setupView() {
        wantsLayer = true

        // Build the hover indicator shown while the handle is active.
        hoverIndicatorLayer = CALayer()
        hoverIndicatorLayer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        hoverIndicatorLayer?.cornerRadius = 2
        hoverIndicatorLayer?.opacity = 0.0 // Start fully transparent.

        layer?.addSublayer(hoverIndicatorLayer!)
    }

    override func layout() {
        super.layout()
        updateHoverIndicatorFrame()
    }

    private func updateHoverIndicatorFrame() {
        let indicatorWidth: CGFloat = 4
        let verticalMargin: CGFloat = 8
        let indicatorFrame = CGRect(
            x: (bounds.width - indicatorWidth) / 2,
            y: verticalMargin,
            width: indicatorWidth,
            height: bounds.height - verticalMargin * 2
        )
        hoverIndicatorLayer?.frame = indicatorFrame
    }

    private func setupTrackingArea() {
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        setupTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)

        // Hidden in traditional layout because the sidebar is not resizable there.
        if shouldIgnoreResize() {
            return
        }

        isMouseEntered = true
        AppLogDebug("mouseEntered resize handle")
        NSCursor.resizeLeftRight.set()
        scheduleShowHoverIndicator()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseEntered = false
        AppLogDebug("mouseExited resize handle")
        if !isDragging {
            NSCursor.arrow.set()
        }
        hideHoverIndicator()
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if (isMouseEntered || isDragging) && NSCursor.current != .resizeLeftRight {
            // Restore the resize cursor if the split view reset it while hovering.
            NSCursor.resizeLeftRight.set()
        }
    }

    private func scheduleShowHoverIndicator() {
        // Restart the delayed reveal timer.
        showDelayTimer?.invalidate()

        // Delay the indicator slightly so quick passes do not flash it.
        showDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.showHoverIndicatorWithAnimation()
        }
    }

    private func showHoverIndicatorWithAnimation() {
        guard let layer = hoverIndicatorLayer else { return }

        // Skip redundant fade-ins.
        if layer.opacity > 0 { return }

        // Fade the indicator in.
        let fadeInAnimation = CABasicAnimation(keyPath: "opacity")
        fadeInAnimation.fromValue = 0.0
        fadeInAnimation.toValue = 1.0
        fadeInAnimation.duration = 0.2
        fadeInAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.opacity = 1.0
        layer.add(fadeInAnimation, forKey: "fadeIn")
    }

    private func hideHoverIndicator() {
        // Cancel any pending delayed reveal.
        showDelayTimer?.invalidate()

        guard let layer = hoverIndicatorLayer else { return }

        // Skip redundant fade-outs.
        if layer.opacity == 0 { return }

        // Fade the indicator out.
        let fadeOutAnimation = CABasicAnimation(keyPath: "opacity")
        fadeOutAnimation.fromValue = 1.0
        fadeOutAnimation.toValue = 0.0
        fadeOutAnimation.duration = 0.15
        fadeOutAnimation.timingFunction = CAMediaTimingFunction(name: .easeIn)

        layer.opacity = 0.0
        layer.add(fadeOutAnimation, forKey: "fadeOut")
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)

        // Traditional layout has no resizable sidebar.
        if shouldIgnoreResize() {
            return
        }

        isDragging = true
        lastMouseLocation = event.locationInWindow
        accumulatedDeadZoneDelta = 0
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)

        // Traditional layout has no resizable sidebar.
        if shouldIgnoreResize() {
            return
        }

        guard isDragging else { return }

        let currentLocation = event.locationInWindow
        let deltaX = currentLocation.x - lastMouseLocation.x
        lastMouseLocation = currentLocation

        // Walk the responder chain to resize the owning split view.
        if let splitViewController = findMainSplitViewController() {
            // Use the handle edge in window coordinates for dead-zone logic.
            let resizeHandleFrame = convert(bounds, to: nil)
            let resizeHandleRightEdge = resizeHandleFrame.maxX

            _ = splitViewController.adjustSidebarWidthWithDeadZone(
                by: deltaX,
                currentMouseX: currentLocation.x,
                resizeHandleRightEdge: resizeHandleRightEdge,
                accumulatedDelta: &accumulatedDeadZoneDelta
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        isDragging = false

        // Restore the correct cursor and indicator state after dragging.
        let locationInView = convert(event.locationInWindow, from: nil)
        if bounds.contains(locationInView) {
            NSCursor.resizeLeftRight.set()
            // Keep the indicator visible while the pointer remains inside.
            scheduleShowHoverIndicator()
        } else {
            NSCursor.arrow.set()
            // Hide the indicator once the pointer leaves the handle.
            hideHoverIndicator()
        }
    }

    private func findMainSplitViewController() -> MainSplitViewController? {
        var responder: NSResponder? = self
        while responder != nil {
            if let splitViewController = responder as? MainSplitViewController {
                return splitViewController
            }
            responder = responder?.nextResponder
        }
        return nil
    }
}
