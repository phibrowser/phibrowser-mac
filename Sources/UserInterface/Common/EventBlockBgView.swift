// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class EventBlockBgView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
    }
    
    var mouseDown: ((NSEvent) -> Void)?

    // Transparent but intercepts events
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        mouseDown?(event)
        super.mouseDown(with: event)
    }
    
    override func mouseMoved(with event: NSEvent) {
        
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        
    }
    
    override func rightMouseUp(with event: NSEvent) {
        
    }
    
    // Swallow hit-testing so A never receives click/hover when B is visible
//    override func hitTest(_ point: NSPoint) -> NSView? {
//        let p = convert(point, from: superview)
//        return bounds.contains(p) ? self : nil
//    }
//
//    // Force arrow cursor over the whole overlay (preempts A's cursor)
//    override func resetCursorRects() {
//        super.resetCursorRects()
//        discardCursorRects()
//        addCursorRect(bounds, cursor: .arrow)
//    }
}
