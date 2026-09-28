// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Reader and Peek share the browser's window and responder chain. Their
/// unflipped roots keep screen-space geometry and Peek's animation aligned.
class PageOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.zPosition = WebContentContainerViewController.LayerZIndex.pageOverlay
        layer?.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isPresented: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    var containsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    var screenFrame: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    func setScreenFrame(_ rect: NSRect) {
        guard let window, let superview else { return }
        frame = superview.convert(window.convertFromScreen(rect), from: nil)
        layoutSubtreeIfNeeded()
    }

    override func removeFromSuperview() {
        // Do not leave keyboard input targeting a detached Chromium view.
        if containsFirstResponder { window?.makeFirstResponder(nil) }
        isHidden = true
        super.removeFromSuperview()
    }
}

extension WebContentContainerViewController {
    func installPageOverlay(_ overlay: PageOverlayView) {
        // AppKit hit testing follows subview order, independently of layer z.
        // In standalone windows the sidebar is a sibling here; in hosted
        // windows the shell already places it above this whole page tree.
        let sidebar = floatingSidebarHost.view
        view.addSubview(overlay,
                        positioned: sidebar.superview === view ? .below : .above,
                        relativeTo: sidebar.superview === view ? sidebar : nil)
    }
}
