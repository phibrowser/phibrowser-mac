//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.


import Cocoa

/// Paints no backdrop of its own: the owner masks the list content beneath
/// it, so whatever the sidebar host paints (palette gradient, glass panel,
/// Space-switch ramp) shows through.
class FloatingNewTabView: NSView {
    let cellView = NewTabButtonCellView(frame: .zero)
    private let separatorView = NSView()
    private var trackingArea: NSTrackingArea?
    var hoverStateChanged: ((Bool) -> Void)?
    /// The row sits above the scroll view rather than inside it, so wheel
    /// events are handed back to the list explicitly.
    weak var scrollView: NSScrollView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func layout() {
        super.layout()
        cellView.frame = bounds
        separatorView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let newTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(newTrackingArea)
        trackingArea = newTrackingArea
        updateHoverStateForCurrentMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hoverStateChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverStateChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        return cellView.hitTest(localPoint) ?? self
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        cellView.clickAction?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollView else {
            super.scrollWheel(with: event)
            return
        }
        scrollView.scrollWheel(with: event)
    }

    private func setupViews() {
        addSubview(cellView)

        separatorView.wantsLayer = true
        separatorView.phiLayer?.setBackgroundColor(.separator)
        addSubview(separatorView)
    }

    private func updateHoverStateForCurrentMouseLocation() {
        guard let window else {
            hoverStateChanged?(false)
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        hoverStateChanged?(bounds.contains(localPoint))
    }
}
