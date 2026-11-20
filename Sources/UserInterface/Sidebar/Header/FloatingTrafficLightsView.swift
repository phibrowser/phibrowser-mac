// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

enum FloatingTrafficLightMetrics {
    /// Height of the right-sidebar layout's top band, which carries the
    /// native lights on its centre line.
    static let bandHeight: CGFloat = 32
    /// How close to the window's top edge the pointer must come to reveal
    /// the band.
    static let bandRevealDistance: CGFloat = 8
}

/// The right-sidebar layout's full-width titlebar band: hidden until the
/// pointer reaches the window's top edge (always shown under VoiceOver, absent
/// in full screen), it draws only the backdrop, and the native lights are
/// revealed on it by `SpaceSessionController.applyTrafficLightVisibility`.
final class FloatingTrafficLightsView: NSView {
    private var voiceOverObservation: NSKeyValueObservation?
    private var pointerMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private(set) var isStripVisible = false
    /// Called when the top band is revealed or hidden.
    var onStripVisibilityChanged: ((Bool) -> Void)?

    private weak var browserState: BrowserState?
    private var trackingArea: NSTrackingArea?
    private var notificationObservers: [NSObjectProtocol] = []
    private var stateCancellables = Set<AnyCancellable>()
    private var hasSetupStateObservers = false

    init(browserState: BrowserState?) {
        self.browserState = browserState
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    deinit {
        stopObservingWindowState()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        hideWorkItem?.cancel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // A tracking area answers by geometry, so the band hears the pointer
        // even over the Chromium views that take the mouse-moved events.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateStripFromPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        updateStripFromPointer()
    }

    override func mouseExited(with event: NSEvent) {
        updateStripFromPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if pointerMonitor == nil, window != nil {
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .leftMouseUp {
                    // A drag that resized or moved the window ends here; read
                    // the pointer against the geometry it left behind.
                    DispatchQueue.main.async { [weak self] in self?.updateStripFromPointer() }
                } else {
                    updateStripFromPointer()
                }
                return event
            }
        }
        if voiceOverObservation == nil {
            voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateStripFromPointer() }
            }
        }
        startObservingWindowState()
        setupStateObserversIfNeeded()
        syncWindowButtonAvailability()
    }

    private func setupViews() {
        setAccessibilityElement(false)
        isHidden = true
        alphaValue = 0
        // The sidebar column's own backdrop recipe
        // (`ShellSidebarHostViewController`), so the band reads as window chrome.
        let backdrop = ColoredVisualEffectView()
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.themedBackgroundColor = .windowOverlayBackground
        backdrop.usesThemePalette = true
        addSubview(backdrop)
        backdrop.snp.makeConstraints { $0.edges.equalToSuperview() }
        let separator = NSView()
        separator.wantsLayer = true
        separator.phiLayer?.setBackgroundColor(.separator)
        addSubview(separator)
        separator.snp.makeConstraints { make in
            make.left.right.bottom.equalToSuperview()
            make.height.equalTo(1)
        }
    }

    private func startObservingWindowState() {
        stopObservingWindowState()
        guard let window else {
            return
        }

        // A resize can carry the band away from a pointer that has not
        // moved since, so no mouse event re-checks it.
        notificationObservers.append(
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                self?.updateStripFromPointer()
            }
        )
    }

    private func stopObservingWindowState() {
        let center = NotificationCenter.default
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func setupStateObserversIfNeeded() {
        guard hasSetupStateObservers == false,
              let browserState else {
            return
        }

        hasSetupStateObservers = true
        browserState.$isInFullScreenMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWindowButtonAvailability()
            }
            .store(in: &stateCancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWindowButtonAvailability()
            }
            .store(in: &stateCancellables)
    }

    private func syncWindowButtonAvailability() {
        let isEnabled = shouldEnableWindowButtonActions
        isHidden = !isEnabled
        if !isEnabled || window == nil {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            setStripVisible(false)
        }
        updateStripFromPointer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !isStripVisible { return nil }
        return super.hitTest(point)
    }

    /// Reveals the band while the pointer is at the window's top edge (or
    /// anywhere on the revealed band), and hides it shortly after it leaves.
    private func updateStripFromPointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let distanceFromTop = bounds.maxY - point.y
        let reach = isStripVisible ? bounds.height : FloatingTrafficLightMetrics.bandRevealDistance
        let isPointerOnBand = point.x >= bounds.minX && point.x <= bounds.maxX
            && distanceFromTop >= 0 && distanceFromTop <= reach
        let reveal = shouldEnableWindowButtonActions
            && (NSWorkspace.shared.isVoiceOverEnabled || isPointerOnBand)
        if reveal {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            setStripVisible(true)
        } else if isStripVisible && hideWorkItem == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                hideWorkItem = nil
                setStripVisible(false)
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    func setStripVisible(_ visible: Bool) {
        guard isStripVisible != visible else { return }
        isStripVisible = visible
        onStripVisibilityChanged?(visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        }
    }

    private var shouldEnableWindowButtonActions: Bool {
        SidebarPosition.isOnRight && browserState?.isInFullScreenMode != true
            && window?.styleMask.contains(.fullScreen) != true
    }
}
