// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import QuartzCore

/// Presents Library over the browser in an attached panel, with a flight from the avatar.
final class LibraryOverlayController {
    private final class OverlayPanel: NSPanel {
        var dismiss: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func performClose(_ sender: Any?) { dismiss?() }
    }

    private final class OverlayView: NSView {
        var dismiss: (() -> Void)?
        var layoutCard: (() -> Void)?
        weak var cardView: NSView?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            // Unhandled clicks in SwiftUI content bubble up the responder chain.
            let point = convert(event.locationInWindow, from: nil)
            guard let cardView else { return }
            if cardView.frame.contains(point) {
                // End field editing while keeping focus owned by the overlay.
                window?.makeFirstResponder(self)
            } else {
                dismiss?()
            }
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
    private let panel = OverlayPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView],
                                     backing: .buffered, defer: true)
    private let overlay = OverlayView()
    private let scrim = CALayer()
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var themeSubscription: AnyCancellable?
    private var focusedTabSubscription: AnyCancellable?
    private var generation = 0
    private var isClosing = false
    var isVisible: Bool { panel.isVisible }

    init(parent: NSWindow, browserState: BrowserState) {
        self.parent = parent
        module = LibraryViewModule(browserState: browserState)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.appearance = browserState.themeContext.windowAppearance
        themeSubscription = browserState.themeContext.themeAppearancePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserState] _ in
                self?.panel.appearance = browserState?.themeContext.windowAppearance
            }
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
        panel.dismiss = { [weak self] in self?.dismiss() }
        focusedTabSubscription = browserState.$focusingTab
            .map { $0?.guid }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // Let the tab switch own focus instead of restoring the previous tab's responder.
                self?.dismiss(animated: false, restoreFocus: false)
            }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                self?.dismiss(animated: false, restoreFocus: false)
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.layoutPanel()
            })
        }
        if let content = parent.contentView {
            content.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                    object: content, queue: .main) { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.layoutPanel()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    func show(from source: NSView, section: LibraryViewModule.Section? = nil, animated: Bool = true) {
        guard let parent, parent.contentView != nil, source.window === parent else { return }
        if let section { module.navigationState.selection = section }
        guard !isVisible || isClosing else { return }
        generation += 1
        isClosing = false
        self.source = source
        if !isVisible { previousResponder = parent.firstResponder }
        panel.contentView = overlay
        layoutPanel()
        overlay.layer?.removeAllAnimations()
        module.view.layer?.removeAllAnimations()
        scrim.removeAllAnimations()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let startTransform = animated && !reduceMotion ? sourceTransform() : CATransform3DIdentity
        // Arm the first frame before ordering the panel in. The panel itself
        // always covers the full background, including during the card flight.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.opacity = animated ? 0 : 1
        module.view.layer?.opacity = animated ? 0 : 1
        module.view.layer?.transform = startTransform
        CATransaction.commit()
        announceVisibility(true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(overlay)
        installEventMonitor()
        guard animated else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.opacity = 1
        module.view.layer?.opacity = 1
        module.view.layer?.transform = CATransform3DIdentity
        fade(layer: scrim, from: 0, to: 1, duration: 0.16)
        fade(layer: module.view.layer, from: 0, to: 1, duration: 0.12)
        if !reduceMotion, let layer = module.view.layer {
            let flight = CASpringAnimation(keyPath: "transform")
            flight.fromValue = NSValue(caTransform3D: startTransform)
            flight.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            flight.mass = 1
            flight.stiffness = 620
            flight.damping = 36
            flight.initialVelocity = 0
            flight.duration = 0.36
            layer.add(flight, forKey: "library.flight")
        }
        CATransaction.commit()
    }

    func dismiss(animated: Bool = true, restoreFocus: Bool = true) {
        guard isVisible else { return }
        if isClosing && animated { return }
        generation += 1
        let closingGeneration = generation
        isClosing = true
        if (panel.firstResponder as? NSView)?.isDescendant(of: overlay) == true {
            // End field editing before the card animates so its focus ring cannot linger.
            panel.makeFirstResponder(overlay)
        }
        let finish = { [weak self] in
            guard let self, self.generation == closingGeneration else { return }
            let ownsFocus = self.panel.isKeyWindow
            self.panel.parent?.removeChildWindow(self.panel)
            self.panel.orderOut(nil)
            self.panel.contentView = nil
            self.isClosing = false
            if let eventMonitor = self.eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            self.eventMonitor = nil
            if restoreFocus, ownsFocus {
                self.parent?.makeKey()
                self.parent?.makeFirstResponder(self.previousResponder)
            }
            self.previousResponder = nil
            self.announceVisibility(false)
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

    private func layoutPanel() {
        guard let parent, let content = parent.contentView else { return }
        // Let AppKit clip the panel to the same system window corners as its
        // parent. Fullscreen and borderless parents have square corners.
        let rounded = parent.styleMask.contains(.titled) && !parent.styleMask.contains(.fullScreen)
        let style: NSWindow.StyleMask = rounded ? [.titled, .fullSizeContentView] : [.borderless, .fullSizeContentView]
        if panel.styleMask != style { panel.styleMask = style }
        let frame = parent.convertToScreen(content.convert(content.bounds, to: nil))
        panel.setFrame(frame, display: true)
        overlay.frame = NSRect(origin: .zero, size: frame.size)
        layoutContent()
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.frame = overlay.bounds
        module.view.frame = overlay.bounds.insetBy(dx: 36, dy: 36)
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
        guard let parent, let source, source.window === parent, let layer = module.view.layer else { return CATransform3DIdentity }
        let screenRect = parent.convertToScreen(source.convert(source.bounds, to: nil))
        let origin = overlay.convert(panel.convertFromScreen(screenRect), from: nil)
        return Self.flightTransform(card: module.view.frame, origin: origin, anchorPoint: layer.anchorPoint)
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
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, event.window === self.panel, self.isVisible else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, modifiers.isEmpty,
               let handle = self.panel.firstResponder as? LibrarySpaceDragHandle.Handle, handle.isDragging {
                handle.cancelOperation(nil)
                return nil
            }
            // Let inline editors consume Escape to cancel their draft first.
            if event.keyCode == 53, modifiers.isEmpty,
               let editor = self.panel.firstResponder as? NSTextView, editor.isFieldEditor {
                return event
            }
            if (event.keyCode == 53 && modifiers.isEmpty)
                || (event.charactersIgnoringModifiers == "w" && modifiers == .command) {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func announceVisibility(_ visible: Bool) {
        guard let parent else { return }
        NotificationCenter.default.post(name: .phiInWindowOverlayVisibilityChanged, object: parent,
                                        userInfo: ["surface": "library", "visible": visible])
    }
}
