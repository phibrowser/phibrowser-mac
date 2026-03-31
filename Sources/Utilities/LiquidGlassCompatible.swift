// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
enum LiquidGlassCompatible {
    static var cornerRadius: CGFloat {
        return 12
    }
    
    static var liquidGlassOrVisualEffectBgView: NSView {
        return NSVisualEffectView()
    }
    
    static var webContentContainerCornerRadius: CGFloat {
        return SystemUtils.isMacOS26OrLater ? 14 : 6
    }
    
    static var webContentInnerComponentsCornerRadius: CGFloat {
        return SystemUtils.isMacOS26OrLater ? 10 : 6
    }
}
