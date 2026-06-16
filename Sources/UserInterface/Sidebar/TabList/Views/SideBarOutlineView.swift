// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Symbols

enum SidebarDragAutoscrollResolver {
    static func scrollDelta(
        dragY: CGFloat,
        visibleRect: CGRect,
        isFlipped: Bool,
        topObstructionHeight: CGFloat,
        hotZoneHeight: CGFloat,
        minStep: CGFloat,
        maxStep: CGFloat
    ) -> CGFloat {
        let hotZoneHeight = max(0, hotZoneHeight)
        guard hotZoneHeight > 0, visibleRect.height > 0 else { return 0 }

        let minStep = max(0, minStep)
        let maxStep = max(minStep, maxStep)
        let topObstructionHeight = max(0, min(topObstructionHeight, visibleRect.height))

        let topDistance: CGFloat
        let bottomDistance: CGFloat
        let topSign: CGFloat
        let bottomSign: CGFloat
        if isFlipped {
            topDistance = dragY - (visibleRect.minY + topObstructionHeight)
            bottomDistance = visibleRect.maxY - dragY
            topSign = -1
            bottomSign = 1
        } else {
            topDistance = (visibleRect.maxY - topObstructionHeight) - dragY
            bottomDistance = dragY - visibleRect.minY
            topSign = 1
            bottomSign = -1
        }

        if topDistance < hotZoneHeight {
            return topSign * scrollStep(
                distanceFromEdge: topDistance,
                hotZoneHeight: hotZoneHeight,
                minStep: minStep,
                maxStep: maxStep
            )
        }
        if bottomDistance < hotZoneHeight {
            return bottomSign * scrollStep(
                distanceFromEdge: bottomDistance,
                hotZoneHeight: hotZoneHeight,
                minStep: minStep,
                maxStep: maxStep
            )
        }
        return 0
    }

    private static func scrollStep(
        distanceFromEdge: CGFloat,
        hotZoneHeight: CGFloat,
        minStep: CGFloat,
        maxStep: CGFloat
    ) -> CGFloat {
        let clampedDistance = max(0, min(distanceFromEdge, hotZoneHeight))
        let intensity = 1 - clampedDistance / hotZoneHeight
        return minStep + (maxStep - minStep) * intensity
    }
}

private final class SidebarDragAutoscrollCueView: NSView {
    enum Edge: CaseIterable, Hashable {
        case top
        case bottom
    }

    private let symbolImageView = NSImageView(frame: .zero)
    private var isAnimating = false

    var edge: Edge = .top {
        didSet {
            guard edge != oldValue else { return }
            updateSymbol()
            needsDisplay = true
            if isAnimating {
                restartSymbolEffect()
            }
        }
    }

    override var isFlipped: Bool {
        true
    }

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
        let side: CGFloat = 18
        symbolImageView.frame = NSRect(
            x: floor((bounds.width - side) * 0.5),
            y: floor((bounds.height - side) * 0.5),
            width: side,
            height: side
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let baseColor = NSColor.white
        let gradient: NSGradient?
        switch edge {
        case .top:
            gradient = NSGradient(colors: [
                baseColor.withAlphaComponent(0.18),
                baseColor.withAlphaComponent(0.08),
                baseColor.withAlphaComponent(0.0)
            ])
        case .bottom:
            gradient = NSGradient(colors: [
                baseColor.withAlphaComponent(0.0),
                baseColor.withAlphaComponent(0.08),
                baseColor.withAlphaComponent(0.18)
            ])
        }

        gradient?.draw(
            from: NSPoint(x: bounds.midX, y: bounds.minY),
            to: NSPoint(x: bounds.midX, y: bounds.maxY),
            options: []
        )
    }

    func startAnimatingIfNeeded() {
        guard !isAnimating else { return }
        isAnimating = true
        addSymbolEffectIfAvailable()
    }

    private func restartSymbolEffect() {
        if #available(macOS 15.0, *) {
            symbolImageView.removeAllSymbolEffects(options: .default, animated: false)
        }
        addSymbolEffectIfAvailable()
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        if #available(macOS 15.0, *) {
            symbolImageView.removeAllSymbolEffects(options: .default, animated: false)
        }
    }

    private func addSymbolEffectIfAvailable() {
        if #available(macOS 15.0, *) {
            let effect: WiggleSymbolEffect = edge == .top ? .wiggle.up : .wiggle.down
            symbolImageView.addSymbolEffect(
                effect.wholeSymbol,
                options: .speed(1.2).repeat(.periodic),
                animated: true
            )
        }
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false
        symbolImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(symbolImageView)
        updateTheme()
        updateSymbol()
    }

    func updateTheme() {
        symbolImageView.contentTintColor = ThemedColor.themeColor.resolve(in: self)
        needsDisplay = true
    }

    private func updateSymbol() {
        let symbolName = edge == .top
            ? "arrowtriangle.up.2.fill"
            : "arrowtriangle.down.2.fill"
        symbolImageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
    }
}

/// Delegate protocol for handling middle mouse button click events on outline view items
protocol SideBarOutlineViewDelegate: AnyObject {
    /// Called when a row is clicked with the middle mouse button
    /// - Parameters:
    ///   - outlineView: The outline view that received the click
    ///   - row: The row index that was clicked, or -1 if click was outside any row
    ///   - location: Click location in outline-view coordinates — lets the
    ///     delegate route middle-click within a merged splitPair row to the
    ///     specific pane (left/right) the user actually hit.
    func outlineView(_ outlineView: SideBarOutlineView,
                     didMiddleClickRow row: Int,
                     at location: NSPoint)
    func outlineView(_ outlineView: SideBarOutlineView, didClickRow row: Int)
    func outlineView(_ outlineView: SideBarOutlineView,
                     beginDraggingTabAtRow row: Int,
                     with mouseDownEvent: NSEvent)
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint)
    func outlineView(_ outlineView: NSOutlineView, draggingEntered sender: any NSDraggingInfo)
    func outlineView(_ outlineView: NSOutlineView, draggingExited sender: (any NSDraggingInfo)?)
    func outlineView(_ outlineView: NSOutlineView, draggingEnded sender: any NSDraggingInfo)
}

class SideBarOutlineView: DiffableOutlineView {
    static let indentation = 10
    private static let dragThreshold: CGFloat = 5
    private static let dragAutoscrollHotZoneHeight: CGFloat = 92
    private static let dragAutoscrollMinStep: CGFloat = 5
    private static let dragAutoscrollMaxStep: CGFloat = 22
    private static let dragAutoscrollCueHeight: CGFloat = 44

    var bottomPadding: CGFloat = 0 {
        didSet {
            updateDocumentHeightIfNeeded()
        }
    }

    var dragAutoscrollTopObstructionHeight: CGFloat = 0

    private(set) var rightClickedRow: Int?
    /// Click location in outline-view coordinates, set together with
    /// `rightClickedRow` when the context menu is requested.
    private(set) var rightClickedLocation: NSPoint?
    private var isUpdatingDocumentHeight = false
    
    /// Delegate for handling middle mouse button click events
    weak var phiOutlineDelegate: SideBarOutlineViewDelegate?

    private var pendingTabDragRow: Int?
    private var pendingTabDragStartPoint: NSPoint?
    private var pendingTabMouseDownEvent: NSEvent?
    private var tabDragThresholdPassed = false
    private var tabDragBelowThresholdLogged = false
    private var dragAutoscrollCueViews: [SidebarDragAutoscrollCueView.Edge: SidebarDragAutoscrollCueView] = [:]

    override func setFrameSize(_ newSize: NSSize) {
        var adjusted = newSize
        if !isUpdatingDocumentHeight {
            let minH = Self.documentHeight(
                contentHeight: contentHeightForRows(),
                visibleHeight: enclosingScrollView?.contentSize.height ?? 0,
                bottomPadding: bottomPadding
            )
            adjusted.height = max(adjusted.height, minH)
        }

        let oldSize = frame.size
        super.setFrameSize(adjusted)

        if !isUpdatingDocumentHeight,
           abs(oldSize.width - adjusted.width) > 0.5 || abs(oldSize.height - adjusted.height) > 0.5 {
            updateDocumentHeightIfNeeded()
        }
    }

    override func reloadData() {
        super.reloadData()
        updateDocumentHeightIfNeeded()
    }

    override func noteNumberOfRowsChanged() {
        super.noteNumberOfRowsChanged()
        updateDocumentHeightIfNeeded()
    }
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        rightClickedLocation = location
        rightClickedRow = row(at: location)
        return self.menu
    }
    
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDown ignored type=\(event.type.rawValue)"
            )
            resetTabDragThresholdState()
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = row(at: point)
        let itemTypeDescription: String = {
            guard index >= 0,
                  let item = item(atRow: index) as? SidebarItem else {
                return "none"
            }
            return String(describing: item.itemType)
        }()
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDown row=\(index) " +
            "itemType=\(itemTypeDescription) point=\(point)"
        )
        if index >= 0,
           let item = item(atRow: index) as? SidebarItem,
           item.itemType == .tab {
            pendingTabDragRow = index
            pendingTabDragStartPoint = point
            pendingTabMouseDownEvent = event
            tabDragThresholdPassed = false
            tabDragBelowThresholdLogged = false
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] pending normal tab row=\(index)"
            )
            return
        } else {
            resetTabDragThresholdState()
        }
        if index >= 0 {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] forwarding mouseDown to super row=\(index)"
            )
            super.mouseDown(with: event)
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] super mouseDown returned row=\(index)"
            )
        } else if let window {
            AppLogDebug("[SIDEBAR_TAB_DRAG_THRESHOLD] dragging window from empty area")
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let row = pendingTabDragRow,
              let startPoint = pendingTabDragStartPoint,
              let mouseDownEvent = pendingTabMouseDownEvent,
              row >= 0,
              row < numberOfRows,
              let item = item(atRow: row) as? SidebarItem,
              item.itemType == .tab else {
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseDragged passthrough " +
                "pendingRow=\(pendingTabDragRow.map(String.init) ?? "nil")"
            )
            super.mouseDragged(with: event)
            return
        }

        if !tabDragThresholdPassed {
            let currentPoint = convert(event.locationInWindow, from: nil)
            let dx = abs(currentPoint.x - startPoint.x)
            let dy = abs(currentPoint.y - startPoint.y)

            guard dx > Self.dragThreshold || dy > Self.dragThreshold else {
                if !tabDragBelowThresholdLogged {
                    tabDragBelowThresholdLogged = true
                    AppLogDebug(
                        "[SIDEBAR_TAB_DRAG_THRESHOLD] below threshold row=\(row) " +
                        "dx=\(dx) dy=\(dy)"
                    )
                }
                return
            }

            tabDragThresholdPassed = true
            AppLogDebug(
                "[SIDEBAR_TAB_DRAG_THRESHOLD] threshold passed row=\(row) " +
                "dx=\(dx) dy=\(dy)"
            )
            phiOutlineDelegate?.outlineView(
                self,
                beginDraggingTabAtRow: row,
                with: mouseDownEvent)
        }
    }

    override func mouseUp(with event: NSEvent) {
        AppLogDebug(
            "[SIDEBAR_TAB_DRAG_THRESHOLD] mouseUp reset " +
            "pendingRow=\(pendingTabDragRow.map(String.init) ?? "nil") " +
            "passed=\(tabDragThresholdPassed)"
        )
        defer {
            resetTabDragThresholdState()
        }
        if let pendingRow = pendingTabDragRow {
            if !tabDragThresholdPassed {
                let point = convert(event.locationInWindow, from: nil)
                if pendingRow == row(at: point) {
                    AppLogDebug("[SIDEBAR_TAB_DRAG_THRESHOLD] click normal tab row=\(pendingRow)")
                    phiOutlineDelegate?.outlineView(self, didClickRow: pendingRow)
                }
            }
            return
        }
        super.mouseUp(with: event)
    }
    
    override func otherMouseDown(with event: NSEvent) {
        // Check if it's a middle mouse button click (button number 2)
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        
        let clickLocation = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: clickLocation)

        // Notify delegate about the middle click
        phiOutlineDelegate?.outlineView(self,
                                        didMiddleClickRow: clickedRow,
                                        at: clickLocation)
    }
    
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        // Tab-group rows render as self-contained `TabGroupCellView`
        // leaves; let them span the full row width starting at x=0.
        if let item = item(atRow: row) as? SidebarItem,
           item.itemType == .tabGroup {
            let rowRect = rect(ofRow: row)
            return NSRect(x: 0,
                          y: rowRect.minY,
                          width: rowRect.width,
                          height: rowRect.height)
        }
        let origin = super.frameOfCell(atColumn: column, row: row)
        guard let item = item(atRow: row) as? SidebarItem, item.isBookmark else {
            return origin
        }
        var rect = origin
        rect.size.width = self.frame.width
        let baseLevel = max(0, level(forRow: row))
        let effectiveLevel: Int
        if let override = (item as? SidebarIndentationLevelProviding)?.indentationLevelOverride {
            effectiveLevel = max(baseLevel, override)
        } else {
            effectiveLevel = baseLevel
        }
        let indent = CGFloat(effectiveLevel * Self.indentation)
        rect.origin.x = indent
        rect.size.width -= indent /*+ NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)*/
        return rect
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // hide disclosure triangle
        return .zero
    }
    
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        phiOutlineDelegate?.outlineView(self, draggingSession: session, movedTo: screenPoint)
    }
    
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        phiOutlineDelegate?.outlineView(self, draggingEntered: sender)
        let operation = super.draggingEntered(sender)
        updateDragAutoscrollCueVisibility()
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender)
        updateDragAutoscrollCueVisibility()
        autoscrollNearEdgeIfNeeded(draggingLocationInWindow: sender.draggingLocation)
        return operation
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        hideDragAutoscrollCue()
        phiOutlineDelegate?.outlineView(self, draggingExited: sender)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        hideDragAutoscrollCue()
        phiOutlineDelegate?.outlineView(self, draggingEnded: sender)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        hideDragAutoscrollCue()
        phiOutlineDelegate?.outlineView(self, draggingExited: sender)
        super.concludeDragOperation(sender)
    }

    static func documentHeight(contentHeight: CGFloat, visibleHeight: CGFloat, bottomPadding: CGFloat) -> CGFloat {
        max(visibleHeight, contentHeight + max(0, bottomPadding))
    }

    private func updateDocumentHeightIfNeeded() {
        guard !isUpdatingDocumentHeight else { return }

        let targetHeight = Self.documentHeight(
            contentHeight: contentHeightForRows(),
            visibleHeight: enclosingScrollView?.contentSize.height ?? 0,
            bottomPadding: bottomPadding
        )

        guard abs(frame.height - targetHeight) > 0.5 else { return }

        isUpdatingDocumentHeight = true
        setFrameSize(NSSize(width: frame.width, height: targetHeight))
        isUpdatingDocumentHeight = false
    }

    private func contentHeightForRows() -> CGFloat {
        guard numberOfRows > 0 else { return 0 }
        return rect(ofRow: numberOfRows - 1).maxY
    }

    func autoscrollNearEdgeIfNeeded(draggingLocationInWindow location: NSPoint) {
        guard let scrollView = enclosingScrollView else { return }

        let clipView = scrollView.contentView
        let visibleRect = clipView.documentVisibleRect
        let dragPoint = convert(location, from: nil)
        let deltaY = SidebarDragAutoscrollResolver.scrollDelta(
            dragY: dragPoint.y,
            visibleRect: visibleRect,
            isFlipped: isFlipped,
            topObstructionHeight: dragAutoscrollTopObstructionHeight,
            hotZoneHeight: Self.dragAutoscrollHotZoneHeight,
            minStep: Self.dragAutoscrollMinStep,
            maxStep: Self.dragAutoscrollMaxStep
        )

        guard abs(deltaY) > 0.5 else { return }

        let maxY = max(0, frame.height - visibleRect.height)
        let targetY = max(0, min(visibleRect.origin.y + deltaY, maxY))
        guard abs(targetY - visibleRect.origin.y) > 0.5 else { return }

        let edge = dragAutoscrollEdge(forDeltaY: deltaY)
        guard canAutoscroll(for: edge, visibleRect: visibleRect) else { return }

        clipView.scroll(to: NSPoint(x: visibleRect.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        updateDragAutoscrollCueVisibility()
    }

    func hideDragAutoscrollCue() {
        for cueView in dragAutoscrollCueViews.values {
            cueView.stopAnimating()
            cueView.removeFromSuperview()
        }
        dragAutoscrollCueViews.removeAll()
    }

    func updateDragAutoscrollCueVisibility() {
        guard let scrollView = enclosingScrollView else {
            hideDragAutoscrollCue()
            return
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let visibleEdges = SidebarDragAutoscrollCueView.Edge.allCases.filter {
            hasInvisibleRow(for: $0, visibleRect: visibleRect)
        }
        let visibleEdgeSet = Set(visibleEdges)

        for edge in SidebarDragAutoscrollCueView.Edge.allCases where !visibleEdgeSet.contains(edge) {
            hideDragAutoscrollCue(edge: edge)
        }
        for edge in visibleEdges {
            showDragAutoscrollCue(edge: edge, in: scrollView)
        }
    }

    private func hideDragAutoscrollCue(edge: SidebarDragAutoscrollCueView.Edge) {
        guard let cueView = dragAutoscrollCueViews.removeValue(forKey: edge) else { return }
        cueView.stopAnimating()
        cueView.removeFromSuperview()
    }

    private func showDragAutoscrollCue(edge: SidebarDragAutoscrollCueView.Edge, in scrollView: NSScrollView) {
        let cueView = dragAutoscrollCueViews[edge] ?? SidebarDragAutoscrollCueView(frame: .zero)
        dragAutoscrollCueViews[edge] = cueView
        cueView.edge = edge

        if cueView.superview == nil {
            scrollView.addFloatingSubview(cueView, for: .vertical)
        }
        cueView.updateTheme()

        let size = scrollView.contentSize
        let height = min(Self.dragAutoscrollCueHeight, size.height)
        let y: CGFloat
        if let superview = cueView.superview, !superview.isFlipped {
            y = edge == .top ? max(0, size.height - height) : 0
        } else {
            y = edge == .top ? 0 : max(0, size.height - height)
        }
        cueView.frame = NSRect(x: 0, y: y, width: size.width, height: height)
        cueView.startAnimatingIfNeeded()
    }

    private func dragAutoscrollEdge(forDeltaY deltaY: CGFloat) -> SidebarDragAutoscrollCueView.Edge {
        if isFlipped {
            return deltaY < 0 ? .top : .bottom
        }
        return deltaY > 0 ? .top : .bottom
    }

    private func hasInvisibleRow(
        for edge: SidebarDragAutoscrollCueView.Edge,
        visibleRect: NSRect
    ) -> Bool {
        guard numberOfRows > 0 else { return false }

        let firstRowRect = rect(ofRow: 0)
        let lastRowRect = rect(ofRow: numberOfRows - 1)
        let rowBounds = firstRowRect.union(lastRowRect)
        let tolerance: CGFloat = 0.5

        switch (edge, isFlipped) {
        case (.top, true):
            return rowBounds.minY < visibleRect.minY - tolerance
        case (.bottom, true):
            return rowBounds.maxY > visibleRect.maxY + tolerance
        case (.top, false):
            return rowBounds.maxY > visibleRect.maxY + tolerance
        case (.bottom, false):
            return rowBounds.minY < visibleRect.minY - tolerance
        }
    }

    private func canAutoscroll(
        for edge: SidebarDragAutoscrollCueView.Edge,
        visibleRect: NSRect
    ) -> Bool {
        if edge == .bottom {
            return true
        }
        return hasInvisibleRow(for: edge, visibleRect: visibleRect)
    }

    private func resetTabDragThresholdState() {
        pendingTabDragRow = nil
        pendingTabDragStartPoint = nil
        pendingTabMouseDownEvent = nil
        tabDragThresholdPassed = false
        tabDragBelowThresholdLogged = false
    }
}
