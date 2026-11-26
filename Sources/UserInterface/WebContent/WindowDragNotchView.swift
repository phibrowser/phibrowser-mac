// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Reveals a native titlebar drag handle on hover or direct touch in edge-to-edge content.
final class WindowDragNotchView: NSView, TitlebarAwareHitTestable {
    static let hoverBandHeight: CGFloat = 20
    private static let notchWidth: CGFloat = 96
    private static let notchHeight: CGFloat = 18
    private static let revealDelay: TimeInterval = 0.15
    private static let hideDelay: TimeInterval = 0.30
    private static let touchRevealDuration: TimeInterval = 4
    /// Hidden notch sits just above the band, clipped by masksToBounds.
    private static let hiddenOffset: CGFloat = notchHeight + 1

    var usesHoverNotch = false {
        didSet {
            guard usesHoverNotch != oldValue else { return }
            setNotchVisible(false, animated: false)
            touchObserver?.invalidate()
            touchObserver = usesHoverNotch ? TouchTapObserver(view: self) { [weak self] location in
                self?.revealForTouchTap(at: location)
            } : nil
            updateTrackingAreas()
        }
    }

    private var hoverTrackingArea: NSTrackingArea?
    private var pendingVisibilityChange: DispatchWorkItem?
    private var touchObserver: TouchTapObserver?
    private var pointerAfterTouch: PointerMotionObserver?
    var supportsTouch: (NSScreen?) -> Bool = { screen in
        if #available(macOS 27, *) { return screen?.touchCapabilities.contains(.multiTouch) == true }
        return false
    }
    private let notchLayer = CAShapeLayer()
    private let gripLayer = CALayer()
    private var themeObservation: AnyObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        notchLayer.anchorPoint = .zero
        notchLayer.opacity = 0
        notchLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: Self.hiddenOffset))
        gripLayer.cornerRadius = 1.5
        notchLayer.addSublayer(gripLayer)
        layer?.addSublayer(notchLayer)
        themeObservation = subscribe { [weak self] theme, appearance in
            self?.updateColors(theme: theme, appearance: appearance)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var notchPath: NSBezierPath {
        let width = min(Self.notchWidth, bounds.width)
        let top = bounds.maxY
        let bottom = top - Self.notchHeight
        let left = bounds.midX - width / 2
        let right = bounds.midX + width / 2
        let radius = min(8, width / 2)
        let shoulderRadius = min(4, (bounds.width - width) / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: left - shoulderRadius, y: top))
        path.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: left, y: bottom), radius: shoulderRadius)
        path.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: right, y: bottom), radius: radius)
        path.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: right, y: top), radius: radius)
        path.appendArc(from: NSPoint(x: right, y: top), to: NSPoint(x: right + shoulderRadius, y: top), radius: shoulderRadius)
        path.close()
        return path
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard usesHoverNotch else {
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            hoverTrackingArea = nil
            return
        }
        // AppKit updates an inVisibleRect area as the window changes size.
        guard hoverTrackingArea == nil else { return }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        let name = NSWindow.didResizeNotification
        if let window { center.removeObserver(self, name: name, object: window) }
        if let newWindow {
            center.addObserver(self, selector: #selector(dismissNotchForWindowChange(_:)), name: name, object: newWindow)
        }
        dismissNotchForWindowChange(nil)
    }

    @objc private func dismissNotchForWindowChange(_ notification: Notification?) {
        // Zoom can move the band away from a stationary pointer without delivering mouseExited.
        guard usesHoverNotch, notchLayer.opacity > 0 || pendingVisibilityChange != nil else { return }
        setNotchVisible(false, animated: false)
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleNotchVisibility(true)
    }

    override func mouseExited(with event: NSEvent) {
        scheduleNotchVisibility(false)
    }

    func revealForTouchTap(at locationInWindow: NSPoint) {
        guard usesHoverNotch, window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(locationInWindow, from: nil)) else { return }
        setNotchVisible(true, animated: true)
        // A touch may move the cursor under the finger. Resume hover timing
        // only after the pointer actually moves within the band.
        pointerAfterTouch = PointerMotionObserver(view: self, touchLocationInWindow: locationInWindow) { [weak self] in
            self?.cancelVisibilityChange()
        }
        let hide = DispatchWorkItem { [weak self] in self?.setNotchVisible(false, animated: true) }
        pendingVisibilityChange = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.touchRevealDuration, execute: hide)
    }

    private func scheduleNotchVisibility(_ visible: Bool) {
        guard usesHoverNotch, pointerAfterTouch == nil else { return }
        if visible == (notchLayer.opacity > 0) {
            pendingVisibilityChange?.cancel()
            pendingVisibilityChange = nil
            return
        }
        guard pendingVisibilityChange == nil else { return }
        let change = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingVisibilityChange = nil
            if visible && (window?.isVisible != true || isHiddenOrHasHiddenAncestor) { return }
            setNotchVisible(visible, animated: true)
        }
        pendingVisibilityChange = change
        let delay = visible ? Self.revealDelay : Self.hideDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: change)
    }

    private func cancelVisibilityChange() {
        pendingVisibilityChange?.cancel()
        pendingVisibilityChange = nil
        pointerAfterTouch?.invalidate()
        pointerAfterTouch = nil
    }

    private func setNotchVisible(_ visible: Bool, animated: Bool) {
        cancelVisibilityChange()
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !animate { notchLayer.removeAllAnimations() }
        let duration: TimeInterval = visible ? 0.2 : 0.14
        // Opacity carries the visible state and flips at once; only the
        // slide animates. Hold the hiding notch opaque until it is out of view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notchLayer.opacity = visible ? 1 : 0
        if animate && !visible {
            let hold = CABasicAnimation(keyPath: "opacity")
            hold.fromValue = 1
            hold.toValue = 1
            hold.duration = duration
            notchLayer.add(hold, forKey: "holdWhileSliding")
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(!animate)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: visible ? .easeOut : .easeIn))
        notchLayer.setAffineTransform(CGAffineTransform(translationX: 0, y: visible ? 0 : Self.hiddenOffset))
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard usesHoverNotch else { return hit }
        if notchLayer.opacity == 0 { return acceptsHiddenBandHit ? hit : nil }
        var local = convert(point, from: superview)
        // Test where the notch lands, so a press during the slide down still grabs it.
        local.y -= notchLayer.affineTransform().ty
        return notchLayer.path?.contains(local) == true ? hit : nil
    }

    private var acceptsHiddenBandHit: Bool {
        guard supportsTouch(window?.screen), NSEvent.pressedMouseButtons == 0 else { return false }
        // AppKit gathers the touch recognizer outside mouse dispatch. Keep
        // its emulated left down on this view as well, so the tap only reveals.
        let eventType = (window as? ShellWindow)?.dispatchingEventType
        return eventType == nil || eventType == .directTouch || eventType == .leftMouseDown
    }

    override var mouseDownCanMoveWindow: Bool {
        usesHoverNotch && notchLayer.opacity == 0 ? false : super.mouseDownCanMoveWindow
    }

    override func mouseDown(with event: NSEvent) {
        // The hidden touch target owns the first tap, including its emulated click.
        if !usesHoverNotch || notchLayer.opacity > 0 { super.mouseDown(with: event) }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notchLayer.bounds = bounds
        notchLayer.path = notchPath.cgPath
        gripLayer.frame = NSRect(x: bounds.midX - 14, y: bounds.maxY - 10, width: 28, height: 3)
        CATransaction.commit()
    }

    private func updateColors(theme: Theme, appearance: Appearance) {
        let base = ThemedColor.windowBackground.resolve(theme: theme, appearance: appearance)
        let accent = ThemedColor.themeColor.resolve(theme: theme, appearance: appearance)
        let tint = base.blended(withFraction: 0.25, of: accent) ?? accent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notchLayer.fillColor = tint.withAlphaComponent(0.72).cgColor
        gripLayer.backgroundColor = ThemedColor.textPrimary.resolve(theme: theme, appearance: appearance).cgColor
        CATransaction.commit()
    }

    func shouldConsumeHitTest(at point: NSPoint) -> Bool {
        usesHoverNotch && notchLayer.opacity == 0
    }
}
