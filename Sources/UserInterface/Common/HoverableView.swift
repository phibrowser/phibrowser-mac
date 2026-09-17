// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

class HoverableView: NSView {
    var backgroundColor = NSColor.controlBackgroundColor
    var hoveredColor = NSColor.lightGray
    var selectedColor = NSColor.systemGray
    
    private var trackingArea: NSTrackingArea?
    
    private var mouseEntered = false {
        didSet {
            needsDisplay = true
            hoverStateChanged?(mouseEntered)
        }
    }
    private var mouseDownModifierFlags: NSEvent.ModifierFlags?
    
    private(set) var responseToHoverAnimation = false
    
    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }
    
    var responseToClickAction = true
    var enableClickAnimation = false
    
    /// Opt in only for tab activation; other controls keep release-to-click behavior.
    var shouldClickOnMouseDown: (() -> Bool)?
    private var clickedOnMouseDown = false
    private var handledMouseDownEvent: NSEvent?

    /// Ancestor drag owners can forward this press without activating it again.
    func handledClick(onMouseDown event: NSEvent) -> Bool {
        handledMouseDownEvent === event
    }

    var clickAction: (() -> Void)?
    /// Single-click callback that preserves the mouse-down modifiers.
    /// When set, it replaces `clickAction` for single clicks.
    var clickActionWithModifierFlags: ((NSEvent.ModifierFlags) -> Void)?
    var doubleClickAction: ((NSEvent) -> Void)?
    var secondaryClickAction: (() -> Void)?
    var hoverStateChanged: ((Bool) -> Void)?
    
    init(frame frameRect: NSRect = .zero, clickAction: (() -> Void)? = nil) {
        super.init(frame: .zero)
        clipsToBounds = true
        self.clickAction = clickAction
        wantsLayer = true
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        wantsLayer = true
        setupLayer()
    }
    
    private func setupLayer() {
        // Keep the default anchor point at the top-left corner.
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            if isSelected {
                layer?.backgroundColor = selectedColor.cgColor
            } else if mouseEntered {
                layer?.backgroundColor = hoveredColor.cgColor
            } else {
                layer?.backgroundColor = backgroundColor.cgColor
            }
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let _trackingArea = NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .activeInActiveApp],
                                           owner: self)
        addTrackingArea(_trackingArea)
        trackingArea = _trackingArea
        
        responseToHoverAnimation = false
        checkMouseIsInCurruntBoundsOrNot()
        responseToHoverAnimation = true
    }
    
    private func checkMouseIsInCurruntBoundsOrNot() {
        guard let window = self.window else { return }
        let screenPoint = NSEvent.mouseLocation
        let screenRect = CGRect(x: screenPoint.x, y: screenPoint.y, width: 1, height: 1)
        let windowRect = window.convertFromScreen(screenRect)
        let pointInView = convert(windowRect.origin, from: nil)
        let rectInView = CGRect(x: pointInView.x, y: pointInView.y, width: 1.0, height: 1.0)
        if self.bounds.contains(rectInView) {
            mouseEntered = true
        } else {
            mouseEntered = false
        }
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseEntered = true
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseEntered = false
    }
    
    override func mouseDown(with event: NSEvent) {
        mouseDownModifierFlags = event.modifierFlags
        clickedOnMouseDown = responseToClickAction
            && event.clickCount == 1
            && event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
            && shouldClickOnMouseDown?() == true
        handledMouseDownEvent = clickedOnMouseDown ? event : nil
        if clickedOnMouseDown {
            if let clickActionWithModifierFlags {
                clickActionWithModifierFlags(event.modifierFlags)
            } else {
                clickAction?()
            }
        }
        // The parent collection/table may track the entire drag inside this call.
        super.mouseDown(with: event)
        if responseToClickAction && enableClickAnimation {
            animateScaleDown()
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownModifierFlags = nil
            clickedOnMouseDown = false
            handledMouseDownEvent = nil
        }
        super.mouseUp(with: event)
        if responseToClickAction && enableClickAnimation {
            animateScaleUp()
        }
        if responseToClickAction && !clickedOnMouseDown {
            if event.clickCount == 2, let doubleClickAction {
                doubleClickAction(event)
            } else if let clickActionWithModifierFlags {
                clickActionWithModifierFlags(mouseDownModifierFlags ?? event.modifierFlags)
            } else {
                clickAction?()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let secondaryClickAction else {
            super.rightMouseDown(with: event)
            return
        }
        secondaryClickAction()
    }
    
    // MARK: - Animation Methods
    
    private func animateScaleDown() {
        let scale: CGFloat = 0.985
        let transform = createCenterScaleTransform(scale: scale)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.transform = transform
        }
    }
    
    private func animateScaleUp() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.transform = CATransform3DIdentity
        }
    }
    
    private func createCenterScaleTransform(scale: CGFloat) -> CATransform3D {
        let bounds = self.bounds
        let centerX = bounds.width / 2
        let centerY = bounds.height / 2
        
        // Build a scale transform around the visual center.
        var transform = CATransform3DMakeTranslation(centerX, centerY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1.0)
        transform = CATransform3DTranslate(transform, -centerX, -centerY, 0)
        
        return transform
    }
}
