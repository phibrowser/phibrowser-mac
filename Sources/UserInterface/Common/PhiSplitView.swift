// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class PhiSplitView: NSSplitView {

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }
    
//    override func drawDivider(in rect: NSRect) {
//        
//    }
    override var dividerColor: NSColor { .clear }
    override var dividerThickness: CGFloat { 0 }
}
