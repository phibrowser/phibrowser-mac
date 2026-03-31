// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// Delegate protocol for handling middle mouse button click events on outline view items
protocol SideBarOutlineViewDelegate: AnyObject {
    /// Called when a row is clicked with the middle mouse button
    /// - Parameters:
    ///   - outlineView: The outline view that received the click
    ///   - row: The row index that was clicked, or -1 if click was outside any row
    func outlineView(_ outlineView: SideBarOutlineView, didMiddleClickRow row: Int)
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint)
    func outlineView(_ outlineView: NSOutlineView, draggingEntered sender: any NSDraggingInfo)
}

class SideBarOutlineView: NSOutlineView {
    static let indentation = 10
    var bottomPadding: CGFloat = 0 {
        didSet {
            updateDocumentHeightIfNeeded()
        }
    }

    private(set) var rightClickedRow: Int?
    private var isUpdatingDocumentHeight = false
    
    /// Delegate for handling middle mouse button click events
    weak var phiOutlineDelegate: SideBarOutlineViewDelegate?

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
        let index = row(at: convert(event.locationInWindow, from: nil))
//        willChangeValue(for: \.rightClickedRow)
        self.rightClickedRow = index
//        didChangeValue(for: \.rightClickedRow)
        return self.menu
    }
    
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index >= 0 {
            super.mouseDown(with: event)
        } else if let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
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
        phiOutlineDelegate?.outlineView(self, didMiddleClickRow: clickedRow)
    }
    
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // hide disclosure triangle
        return .zero
        
    }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
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
    
    override func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        phiOutlineDelegate?.outlineView(self, draggingSession: session, movedTo: screenPoint)
    }
    
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        phiOutlineDelegate?.outlineView(self, draggingEntered: sender)
        return super.draggingEntered(sender)
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
}
