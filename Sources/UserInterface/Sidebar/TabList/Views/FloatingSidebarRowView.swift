//
// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.


import Cocoa

/// A sidebar row pinned to an edge of the tab list while its real row is
/// scrolled out of view: the New Tab row, and the Space name row at the top.
///
/// Paints no backdrop of its own: the owner masks the list content beneath
/// it, so whatever the sidebar host paints (palette gradient, glass panel,
/// Space-switch ramp) shows through.
class FloatingSidebarRowView: NSView {
    let cellView: SidebarCellView
    var sticksToTop = true {
        didSet { if oldValue != sticksToTop { needsLayout = true } }
    }
    /// Off while another pinned row stacks below this one, so the hairline
    /// only marks where the pinned rows end and the list begins.
    var showsSeparator = true {
        didSet { separatorView.isHidden = !showsSeparator }
    }
    /// Runs on a click the cell itself leaves unhandled, such as on the
    /// Space name row, whose cell passes clicks up the responder chain.
    var clickAction: (() -> Void)?
    private let separatorView = NSView()
    private var trackingArea: NSTrackingArea?
    /// Whether the pointer is over the row; the owner keeps the rows under
    /// the pinned rows hover-suppressed while either pinned row has it.
    private(set) var isHovered = false
    var hoverStateChanged: ((Bool) -> Void)?
    /// The row sits above the scroll view rather than inside it, so wheel
    /// events are handed back to the list explicitly.
    weak var scrollView: NSScrollView?
    /// The list under a row that stays up during drags. A drag over the row
    /// keeps scrolling that list toward the top instead of stalling on the
    /// row; the row itself never takes a drop, since the rows under it are
    /// masked.
    weak var dragAutoscrollTarget: SideBarOutlineView? {
        didSet {
            unregisterDraggedTypes()
            if let dragAutoscrollTarget {
                registerForDraggedTypes(dragAutoscrollTarget.registeredDraggedTypes)
            }
        }
    }

    init(cellView: SidebarCellView) {
        self.cellView = cellView
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        cellView.frame = bounds
        separatorView.frame = NSRect(x: 0, y: sticksToTop ? 0 : max(0, bounds.height - 1),
                                     width: bounds.width, height: 1)
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
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    /// With a `clickAction` the whole row is one target, so a click on the
    /// title label folds instead of starting the label's own tracking. A
    /// button in the row, such as the Space row's "…", keeps its own click.
    /// Hover and the folder preview use tracking areas, not hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        let hit = cellView.hitTest(localPoint)
        guard clickAction != nil else { return hit ?? self }
        var view = hit
        while let candidate = view, candidate !== cellView {
            // The button's hosted SwiftUI view, deepest in the chain, runs
            // its action; the button view itself would pass the click up.
            if candidate is HoverableButtonNSView { return hit }
            view = candidate.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A Control-click is a right-click: it opens `menu`, never folds.
        guard bounds.contains(point), !event.modifierFlags.contains(.control) else { return }
        clickAction?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragAutoscrollTarget?.autoscrollNearEdgeIfNeeded(draggingLocationInWindow: sender.draggingLocation)
        return []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragAutoscrollTarget?.autoscrollNearEdgeIfNeeded(draggingLocationInWindow: sender.draggingLocation)
        return []
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        dragAutoscrollTarget != nil
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
            setHovered(false)
            return
        }

        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        setHovered(bounds.contains(localPoint))
    }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        hoverStateChanged?(hovered)
    }
}
