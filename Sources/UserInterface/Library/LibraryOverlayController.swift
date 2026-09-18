// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import QuartzCore

/// Presents Library inside the browser window, with a flight from the avatar.
final class LibraryOverlayController {
    private final class OverlayView: NSView {
        var dismiss: (() -> Void)?
        var layoutCard: (() -> Void)?
        weak var cardView: NSView?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // Unhandled clicks in SwiftUI content bubble up the responder chain.
            // Only the area outside the Library card is a dismiss target.
            let point = convert(event.locationInWindow, from: nil)
            guard let cardView, !cardView.frame.contains(point) else { return }
            dismiss?()
        }
        override func rightMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
        override func cancelOperation(_ sender: Any?) { dismiss?() }
        override func layout() {
            super.layout()
            layoutCard?()
        }
    }

    private weak var parent: NSWindow?
    private weak var source: NSView?
    private weak var previousResponder: NSResponder?
    private let module: LibraryViewModule
    private let overlay = OverlayView()
    private let scrim = CALayer()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var generation = 0
    private var isClosing = false
    var isVisible: Bool { overlay.superview != nil }

    init(parent: NSWindow, browserState: BrowserState) {
        self.parent = parent
        module = LibraryViewModule(browserState: browserState)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        scrim.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        overlay.layer?.addSublayer(scrim)
        let card = module.view
        card.wantsLayer = true
        overlay.addSubview(card)
        overlay.cardView = card
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        card.shadow = shadow
        overlay.dismiss = { [weak self] in self?.dismiss() }
        overlay.layoutCard = { [weak self] in self?.layoutContent() }
        module.onDismiss = { [weak self] in self?.dismiss() }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.dismiss(animated: false, restoreFocus: false)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        overlay.removeFromSuperview()
    }

    func show(from source: NSView, animated: Bool = true) {
        guard let parent, let content = parent.contentView, source.window === parent else { return }
        guard !isVisible || isClosing else { return }
        generation += 1
        isClosing = false
        self.source = source
        if !isVisible { previousResponder = parent.firstResponder }
        overlay.frame = content.bounds
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        layoutContent()
        overlay.layer?.removeAllAnimations()
        module.view.layer?.removeAllAnimations()
        scrim.removeAllAnimations()
        announceVisibility(true)
        parent.makeFirstResponder(overlay)
        installEventMonitor()
        guard animated else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fade(layer: scrim, from: 0, to: 1, duration: 0.16)
        fade(layer: module.view.layer, from: 0, to: 1, duration: 0.12)
        if !reduceMotion, let layer = module.view.layer {
            let flight = CASpringAnimation(keyPath: "transform")
            flight.fromValue = NSValue(caTransform3D: sourceTransform())
            flight.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            flight.mass = 1
            flight.stiffness = 620
            flight.damping = 36
            flight.initialVelocity = 0
            flight.duration = 0.36
            layer.add(flight, forKey: "library.flight")
        }
    }

    func dismiss(animated: Bool = true, restoreFocus: Bool = true) {
        guard isVisible else { return }
        if isClosing && animated { return }
        generation += 1
        let closingGeneration = generation
        isClosing = true
        let finish = { [weak self] in
            guard let self, self.generation == closingGeneration else { return }
            let ownsFocus = (self.parent?.firstResponder as? NSView)?.isDescendant(of: self.overlay) == true
            self.overlay.removeFromSuperview()
            self.isClosing = false
            if let eventMonitor = self.eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            self.eventMonitor = nil
            self.announceVisibility(false)
            if restoreFocus, ownsFocus {
                self.parent?.makeFirstResponder(self.previousResponder)
            }
            self.previousResponder = nil
        }
        guard animated else { finish(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(finish)
        fade(layer: scrim, from: scrim.presentation()?.opacity ?? 1, to: 0, duration: 0.16)
        fade(layer: module.view.layer, from: module.view.layer?.presentation()?.opacity ?? 1, to: 0, duration: 0.16)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = module.view.layer {
            let flight = CABasicAnimation(keyPath: "transform")
            flight.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
            flight.toValue = NSValue(caTransform3D: sourceTransform())
            flight.duration = 0.18
            flight.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flight.fillMode = .forwards
            flight.isRemovedOnCompletion = false
            layer.add(flight, forKey: "library.flight")
        }
        CATransaction.commit()
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = overlay.bounds
        module.view.frame = overlay.bounds.insetBy(dx: 32, dy: 32)
        CATransaction.commit()
    }

    /// Accounts for AppKit's layer anchor, which is not necessarily the center.
    static func flightTransform(card: CGRect, origin: CGRect, anchorPoint: CGPoint) -> CATransform3D {
        guard card.width > 0, card.height > 0 else { return CATransform3DIdentity }
        let scale = max(0.02, min(0.12, min(origin.width / card.width, origin.height / card.height)))
        let anchor = CGPoint(x: card.width * anchorPoint.x, y: card.height * anchorPoint.y)
        var transform = CATransform3DMakeScale(scale, scale, 1)
        transform.m41 = origin.midX - card.minX - anchor.x + (anchor.x - card.width / 2) * scale
        transform.m42 = origin.midY - card.minY - anchor.y + (anchor.y - card.height / 2) * scale
        return transform
    }

    private func sourceTransform() -> CATransform3D {
        guard let source, source.window === parent, let layer = module.view.layer else { return CATransform3DIdentity }
        return Self.flightTransform(card: module.view.frame, origin: source.convert(source.bounds, to: overlay), anchorPoint: layer.anchorPoint)
    }

    private func fade(layer: CALayer?, from: Float, to: Float, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer?.add(animation, forKey: "library.opacity")
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseEntered, .cursorUpdate]) { [weak self] event in
            guard let self, event.window === self.parent, self.isVisible else { return event }
            if event.type == .mouseEntered || event.type == .cursorUpdate {
                // Tracking-area delivery bypasses hit testing. Leave mouseExited
                // untouched so covered controls can clear their existing hover.
                guard let content = self.parent?.contentView else { return event }
                return Self.isBackgroundTrackingArea(event.trackingArea, in: content, overlay: self.overlay) ? nil : event
            }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (event.keyCode == 53 && modifiers.isEmpty)
                || (event.charactersIgnoringModifiers == "w" && modifiers == .command) {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    /// Block only areas positively identified in a covered view. SwiftUI can
    /// deliver tracking events with private/shared areas absent from trackingAreas;
    /// treating an unknown area as background suppresses Library's own onHover.
    static func isBackgroundTrackingArea(_ area: NSTrackingArea?, in root: NSView, overlay: NSView) -> Bool {
        guard let area, root !== overlay else { return false }
        // An ancestor may host shared tracking for both Library and the browser.
        if !overlay.isDescendant(of: root),
           root.trackingAreas.contains(where: { $0 === area }) {
            return true
        }
        return root.subviews.contains { isBackgroundTrackingArea(area, in: $0, overlay: overlay) }
    }

    private func announceVisibility(_ visible: Bool) {
        guard let parent else { return }
        NotificationCenter.default.post(name: .phiInWindowOverlayVisibilityChanged, object: parent,
                                        userInfo: ["surface": "library", "visible": visible])
    }
}
