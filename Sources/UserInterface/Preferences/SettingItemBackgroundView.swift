// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class SettingItemBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        phiLayer?.setBorderColor(.border)
        phiLayer?.setBackgroundColor(.settingItemBackground)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
