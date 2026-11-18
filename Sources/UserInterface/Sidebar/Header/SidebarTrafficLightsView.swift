// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa

/// The window's close, minimize and zoom buttons in the floating sidebar's
/// header, while the titlebar's own are hidden for the collapsed column
/// (`SpaceSessionController.applyTrafficLightVisibility`).
///
/// Fresh instances from `NSWindow.standardWindowButton(_:for:)`, the public
/// way to have the real buttons outside the titlebar: they act on the window
/// they are in and look exactly like the titlebar's, key and active state
/// included.
///
/// Outside a titlebar nothing tells the buttons about the pointer, so this
/// view does what the titlebar does: answers `_mouseInGroup:` and sends
/// `mouseEnteredOrExited` for the hover glyphs, and starts the zoom button's
/// own hover for the window-tiling menu.
final class SidebarTrafficLightsView: NSView {
    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private static let fallbackButtonWidth: CGFloat = 14

    /// The titlebar's pitch from one light to the next: 23 pt on macOS 26,
    /// 20 pt on macOS 14 and 15. Read from `window` when it has its own.
    static func pitch(in window: NSWindow?) -> CGFloat {
        if let close = window?.titlebarButton(.closeButton),
           let minimize = window?.titlebarButton(.miniaturizeButton) {
            let measured = minimize.frame.midX - close.frame.midX
            if (16...32).contains(measured) { return measured }
        }
        if #available(macOS 26, *) { return 23 }
        return 20
    }

    /// Centre of the close button from this view's leading edge.
    var firstCenter: CGFloat = 20 {
        didSet {
            guard firstCenter != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// Whether the buttons are in the view. While any are in a window,
    /// `NSWindow.standardWindowButton(_:)` answers with them; read the
    /// titlebar's own with `NSWindow.titlebarButton(_:)`.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            reinstall()
        }
    }

    /// The zoom button's trailing edge, from this view's leading edge.
    var trailingEdge: CGFloat {
        firstCenter + 2 * pitch + (buttons.last?.frame.width ?? Self.fallbackButtonWidth) / 2
    }

    private var buttons: [NSButton] = []
    private var pitch = SidebarTrafficLightsView.pitch(in: nil)
    private var windowObservers: [NSObjectProtocol] = []
    private var modifierMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var startedZoomHover = false
    private var isPointerInGroup = false {
        didSet {
            guard isPointerInGroup != oldValue else { return }
            updateModifierMonitor()
            tell()
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: trailingEdge, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reinstall()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(x: firstCenter + CGFloat(index) * pitch - size.width / 2,
                                 y: ((bounds.height - size.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// Only the buttons take clicks; the gaps between them are titlebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Asked by each button before it draws, as the titlebar is asked: all
    /// three show their glyphs while the pointer is over any of them.
    @objc func _mouseInGroup(_ button: NSButton) -> Bool {
        isPointerInGroup
    }

    func refresh() {
        guard let window, !buttons.isEmpty else { return }
        for (type, button) in zip(Self.types, buttons) {
            button.isEnabled = window.titlebarButton(type)?.isEnabled ?? true
        }
        updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        tell()
    }

    private func reinstall() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        isPointerInGroup = false
        startedZoomHover = false
        guard isActive, let window else {
            invalidateIntrinsicContentSize()
            return
        }
        pitch = Self.pitch(in: window)
        for type in Self.types {
            guard let button = NSWindow.standardWindowButton(type, for: window.styleMask) else { continue }
            addSubview(button)
            buttons.append(button)
        }
        observe(window)
        invalidateIntrinsicContentSize()
        needsLayout = true
        refresh()
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        let windowNames: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in windowNames {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            windowObservers.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInGroup = false
        startedZoomHover = false
    }

    private func updatePointer(at point: NSPoint) {
        guard let first = buttons.first, let zoom = buttons.last,
              !isHiddenOrHasHiddenAncestor else {
            isPointerInGroup = false
            startedZoomHover = false
            return
        }
        isPointerInGroup = first.frame.union(zoom.frame).contains(point)
        if zoom.frame.contains(point) {
            startZoomHoverIfNeeded(zoom)
        } else {
            startedZoomHover = false
        }
    }

    /// The zoom button's cell hears the pointer come onto it but, outside a
    /// titlebar, never starts the dwell that shows the tiling menu. Started,
    /// AppKit waits, shows the menu from its own service and takes it down.
    private func startZoomHoverIfNeeded(_ zoom: NSButton) {
        guard !startedZoomHover, let window, window.isKeyWindow, NSApp.isActive,
              NSEvent.pressedMouseButtons == 0, zoom.isEnabled else { return }
        let start = NSSelectorFromString("startTrackingHover")
        guard let cell = zoom.cell, cell.responds(to: start) else { return }
        startedZoomHover = true
        _ = cell.perform(start)
    }

    /// Holding Option over the lights turns the zoom glyph into a plus.
    private func updateModifierMonitor() {
        if isPointerInGroup, modifierMonitor == nil {
            modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.tell()
                return event
            }
        } else if !isPointerInGroup, let monitor = modifierMonitor {
            NSEvent.removeMonitor(monitor)
            modifierMonitor = nil
        }
    }

    /// A button keeps the look it last worked out, and asks `_mouseInGroup:`
    /// and the window's state again only when the titlebar tells it the
    /// pointer came or went; `needsDisplay` alone redraws the same look.
    private func tell() {
        let told = NSSelectorFromString("mouseEnteredOrExited")
        for button in buttons {
            if button.responds(to: told) { _ = button.perform(told) }
            button.needsDisplay = true
        }
    }
}

private var titlebarButtonsKey: UInt8 = 0

extension NSWindow {
    /// The titlebar's own button of `type`. Once a `SidebarTrafficLightsView`
    /// has its buttons in the window, `standardWindowButton(_:)` answers with
    /// one of those instead, so the titlebar is searched for a button of the
    /// same kind.
    ///
    /// In full screen AppKit moves the titlebar, these same buttons included,
    /// into an `NSToolbarFullScreenWindow`, the bar that slides down with the
    /// menu bar. A shell window does not list that window as a child, so the
    /// buttons last found here stand in until the titlebar comes back.
    func titlebarButton(_ type: NSWindow.ButtonType) -> NSButton? {
        let key = NSNumber(value: type.rawValue)
        if let button = standardWindowButton(type), !(button.superview is SidebarTrafficLightsView) {
            knownTitlebarButtons.setObject(button, forKey: key)
            return button
        }
        if let button = searchTitlebar(for: type) {
            knownTitlebarButtons.setObject(button, forKey: key)
            return button
        }
        guard let known = knownTitlebarButtons.object(forKey: key), known.superview != nil else { return nil }
        return known
    }

    private var knownTitlebarButtons: NSMapTable<NSNumber, NSButton> {
        if let table = objc_getAssociatedObject(self, &titlebarButtonsKey) as? NSMapTable<NSNumber, NSButton> {
            return table
        }
        let table = NSMapTable<NSNumber, NSButton>.strongToWeakObjects()
        objc_setAssociatedObject(self, &titlebarButtonsKey, table, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return table
    }

    private func searchTitlebar(for type: NSWindow.ButtonType) -> NSButton? {
        guard let template = NSWindow.standardWindowButton(type, for: styleMask),
              let titlebar = contentView?.superview?.subviews.first(where: {
                  NSStringFromClass(Swift.type(of: $0)).contains("TitlebarContainer")
              }) else { return nil }
        func find(in view: NSView) -> NSButton? {
            for subview in view.subviews {
                if let button = subview as? NSButton,
                   Swift.type(of: button) == Swift.type(of: template),
                   button.action == template.action {
                    return button
                }
                if let found = find(in: subview) { return found }
            }
            return nil
        }
        return find(in: titlebar)
    }

    /// Hides or shows the titlebar's own three. A set of `isHidden` re-tiles
    /// the titlebar, so only actual changes are applied.
    func setTitlebarButtonsHidden(_ hidden: Bool) {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = titlebarButton(type), button.isHidden != hidden else { continue }
            button.isHidden = hidden
        }
    }
}
