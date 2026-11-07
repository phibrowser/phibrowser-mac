// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Cocoa
import Combine
import SnapKit

enum FloatingTrafficLightMetrics {
    static let leading: CGFloat = 12
    static let size: CGFloat = 16
    static let circleInset: CGFloat = 1
    static let spacing: CGFloat = 9
    static let width: CGFloat = size * 3 + spacing * 2
    static let maxX: CGFloat = leading + width
    /// Height of the right-sidebar layout's top band, which carries the
    /// native lights on its centre line.
    static let bandHeight: CGFloat = 32
    /// How close to the window's top edge the pointer must come to reveal
    /// the band.
    static let bandRevealDistance: CGFloat = 8
}

final class FloatingTrafficLightsView: NSView {
    /// `.sidebarHeader` draws stand-in lights in a collapsed left sidebar's
    /// header. `.topBand` is the right-sidebar layout's full-width titlebar
    /// band: hidden until the pointer reaches the window's top edge (always
    /// shown under VoiceOver, absent in full screen), it draws only the
    /// backdrop, and the native lights are revealed on it by
    /// `SpaceSessionController.applyTrafficLightVisibility`.
    enum Placement { case sidebarHeader, topBand }
    private var placement: Placement = .sidebarHeader
    private var voiceOverObservation: NSKeyValueObservation?
    private var pointerMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private(set) var isStripVisible = false
    /// Called when the top band is revealed or hidden.
    var onStripVisibilityChanged: ((Bool) -> Void)?

    private weak var browserState: BrowserState?
    private lazy var dotViews: [FloatingTrafficLightDotView] = FloatingTrafficLightRole.allCases.map { role in
        FloatingTrafficLightDotView(role: role)
    }
    private var trackingArea: NSTrackingArea?
    private var notificationObservers: [NSObjectProtocol] = []
    private var stateCancellables = Set<AnyCancellable>()
    private var hasSetupStateObservers = false
    private var isGroupHovered = false {
        didSet {
            dotViews.forEach { $0.isGroupHovered = isGroupHovered }
        }
    }

    private lazy var stackView: NSStackView = {
        let stack = NSStackView(views: dotViews)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = FloatingTrafficLightMetrics.spacing
        return stack
    }()

    init(browserState: BrowserState?, placement: Placement = .sidebarHeader) {
        self.browserState = browserState
        self.placement = placement
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
        var options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        if placement == .topBand { options.insert(.mouseMoved) }
        let area = NSTrackingArea(
            rect: .zero,
            options: options,
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if placement == .topBand { updateStripFromPointer() }
    }

    override func mouseEntered(with event: NSEvent) {
        isGroupHovered = true
        if placement == .topBand { updateStripFromPointer() }
    }

    override func mouseExited(with event: NSEvent) {
        isGroupHovered = false
        if placement == .topBand { updateStripFromPointer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if placement == .topBand, pointerMonitor == nil, window != nil {
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
        if placement == .topBand, voiceOverObservation == nil {
            voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateStripFromPointer() }
            }
        }
        startObservingWindowState()
        setupStateObserversIfNeeded()
        updateWindowActiveState()
        syncWindowButtonAvailability()
    }

    private func setupViews() {
        setAccessibilityElement(false)
        if placement == .topBand {
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
            return
        }
        addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        stackView.arrangedSubviews.forEach { view in
            view.snp.makeConstraints { make in
                make.size.equalTo(NSSize(width: FloatingTrafficLightMetrics.size,
                                         height: FloatingTrafficLightMetrics.size))
            }
        }
    }

    private func startObservingWindowState() {
        stopObservingWindowState()
        guard let window else {
            return
        }

        let center = NotificationCenter.default
        let windowNotifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
        ]
        notificationObservers = windowNotifications.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.updateWindowActiveState()
            }
        }
        if placement == .topBand {
            // A resize can carry the band away from a pointer that has not
            // moved since, so no mouse event re-checks it.
            notificationObservers.append(
                center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                    self?.updateStripFromPointer()
                }
            )
        }
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                self?.updateWindowActiveState()
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                self?.updateWindowActiveState()
            }
        )
    }

    private func stopObservingWindowState() {
        let center = NotificationCenter.default
        notificationObservers.forEach { center.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func updateWindowActiveState() {
        let isActive = NSApp.isActive
            && (window?.isKeyWindow == true || window?.isMainWindow == true)
        dotViews.forEach { $0.isWindowActive = isActive }
    }

    private func setupStateObserversIfNeeded() {
        guard hasSetupStateObservers == false,
              let browserState else {
            return
        }

        hasSetupStateObservers = true
        browserState.sidebarCollapsedPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWindowButtonAvailability()
            }
            .store(in: &stateCancellables)

        browserState.$isInFullScreenMode
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncWindowButtonAvailability()
            }
            .store(in: &stateCancellables)

        browserState.$layoutMode
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

    func refreshWindowButtons() {
        updateWindowActiveState()
        syncWindowButtonAvailability()
        scheduleHoverStateRefresh()
    }

    private func syncWindowButtonAvailability() {
        let isEnabled = shouldEnableWindowButtonActions
        isHidden = !isEnabled
        if placement == .topBand {
            if !isEnabled || window == nil {
                hideWorkItem?.cancel()
                hideWorkItem = nil
                setStripVisible(false)
            }
            updateStripFromPointer()
        } else {
            dotViews.forEach { $0.syncControlAvailability(from: window, isEnabled: isEnabled) }
            refreshHoverStateFromPointer()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if placement == .topBand && !isStripVisible { return nil }
        return super.hitTest(point)
    }

    /// Reveals the band while the pointer is at the window's top edge (or
    /// anywhere on the revealed band), and hides it shortly after it leaves.
    private func updateStripFromPointer() {
        guard placement == .topBand, let window else { return }
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
        guard placement == .topBand, isStripVisible != visible else { return }
        isStripVisible = visible
        onStripVisibilityChanged?(visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        }
    }

    private func scheduleHoverStateRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverStateFromPointer()
        }
    }

    private func refreshHoverStateFromPointer() {
        guard placement == .sidebarHeader else { return }
        guard isHidden == false, let window else {
            isGroupHovered = false
            return
        }

        let locationInSelf = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isGroupHovered = bounds.contains(locationInSelf)
    }

    private var shouldEnableWindowButtonActions: Bool {
        if placement == .topBand {
            return SidebarPosition.isOnRight && browserState?.isInFullScreenMode != true
                && window?.styleMask.contains(.fullScreen) != true
        }
        guard !SidebarPosition.isOnRight, browserState?.sidebarCollapsed == true,
              browserState?.isInFullScreenMode != true else {
            return false
        }
        return !PhiPreferences.GeneralSettings.loadLayoutMode().isTraditional
    }
}

private enum FloatingTrafficLightRole: CaseIterable {
    case close
    case minimize
    case zoom

    var windowButtonType: NSWindow.ButtonType {
        switch self {
        case .close:
            return .closeButton
        case .minimize:
            return .miniaturizeButton
        case .zoom:
            return .zoomButton
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .close:
            return "Close"
        case .minimize:
            return "Minimize"
        case .zoom:
            return "Zoom"
        }
    }

    func performFallbackAction(on window: NSWindow) {
        switch self {
        case .close:
            window.performClose(nil)
        case .minimize:
            window.performMiniaturize(nil)
        case .zoom:
            window.performZoom(nil)
        }
    }
}

private final class FloatingTrafficLightDotView: NSView {
    private let role: FloatingTrafficLightRole
    private lazy var drawingView = FloatingTrafficLightDrawingView(role: role)
    private var isPressed = false {
        didSet {
            drawingView.isPressed = isPressed
        }
    }

    var isGroupHovered = false {
        didSet {
            drawingView.isGroupHovered = isGroupHovered
        }
    }
    var isWindowActive = true {
        didSet {
            drawingView.isWindowActive = isWindowActive
        }
    }
    var isControlEnabled = true {
        didSet {
            drawingView.isControlEnabled = isControlEnabled
        }
    }

    init(role: FloatingTrafficLightRole) {
        self.role = role
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        self.role = .close
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(role.accessibilityLabel)

        addSubview(drawingView)
        drawingView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    func syncControlAvailability(from window: NSWindow?, isEnabled: Bool) {
        guard isEnabled else {
            isControlEnabled = false
            return
        }
        guard let window else {
            isControlEnabled = false
            return
        }
        isControlEnabled = window.standardWindowButton(role.windowButtonType)?.isEnabled ?? true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else {
            return
        }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isControlEnabled else {
            return
        }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isPressed = false }
        guard isControlEnabled else {
            return
        }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        performWindowButtonAction()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isControlEnabled else {
            return false
        }
        performWindowButtonAction()
        return true
    }

    private func performWindowButtonAction() {
        guard let window else {
            return
        }

        // Keep AppKit's standard buttons in the titlebar. Reparenting them into
        // this floating sidebar breaks the system zoom hover popover anchor when
        // the native controls are shown again.
        guard let button = window.standardWindowButton(role.windowButtonType) else {
            role.performFallbackAction(on: window)
            return
        }
        guard button.isEnabled else {
            return
        }

        button.performClick(nil)
    }
}

private final class FloatingTrafficLightDrawingView: NSView {
    private let role: FloatingTrafficLightRole
    var isGroupHovered = false {
        didSet {
            needsDisplay = true
        }
    }
    var isWindowActive = true {
        didSet {
            needsDisplay = true
        }
    }
    var isControlEnabled = true {
        didSet {
            needsDisplay = true
        }
    }
    var isPressed = false {
        didSet {
            needsDisplay = true
        }
    }

    init(role: FloatingTrafficLightRole) {
        self.role = role
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.role = .close
        super.init(coder: coder)
    }

    override var isOpaque: Bool {
        return false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = currentPalette()
        let circleRect = bounds.insetBy(dx: FloatingTrafficLightMetrics.circleInset,
                                        dy: FloatingTrafficLightMetrics.circleInset)
        let path = NSBezierPath(ovalIn: circleRect)
        let fill = isPressed
            ? palette.fill.blended(withFraction: 0.16, of: .black) ?? palette.fill
            : palette.fill
        fill.setFill()
        path.fill()
        palette.stroke.setStroke()
        path.lineWidth = 1
        path.stroke()

        guard isGroupHovered else {
            return
        }
        drawGlyph(in: circleRect, color: palette.glyph)
    }

    private func currentPalette() -> (fill: NSColor, stroke: NSColor, glyph: NSColor) {
        guard isWindowActive && isControlEnabled else {
            return (
                fill: NSColor(hex: 0xD0D0D0),
                stroke: NSColor(hex: 0xB6B6B6),
                glyph: NSColor(calibratedWhite: 0, alpha: 0.38)
            )
        }

        let glyph = NSColor(calibratedWhite: 0, alpha: 0.48)
        switch role {
        case .close:
            return (NSColor(hex: 0xFF5F57), NSColor(hex: 0xE0443E), glyph)
        case .minimize:
            return (NSColor(hex: 0xFEBC2E), NSColor(hex: 0xDEA123), glyph)
        case .zoom:
            return (NSColor(hex: 0x28C840), NSColor(hex: 0x1AAB29), glyph)
        }
    }

    private func drawGlyph(in rect: NSRect, color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch role {
        case .close:
            path.move(to: NSPoint(x: rect.minX + 3.6, y: rect.minY + 3.6))
            path.line(to: NSPoint(x: rect.maxX - 3.6, y: rect.maxY - 3.6))
            path.move(to: NSPoint(x: rect.maxX - 3.6, y: rect.minY + 3.6))
            path.line(to: NSPoint(x: rect.minX + 3.6, y: rect.maxY - 3.6))
        case .minimize:
            path.move(to: NSPoint(x: rect.minX + 3.8, y: rect.midY))
            path.line(to: NSPoint(x: rect.maxX - 3.8, y: rect.midY))
        case .zoom:
            drawZoomGlyph(in: rect, color: color)
            return
        }

        path.stroke()
    }

    private func drawZoomGlyph(in rect: NSRect, color: NSColor) {
        color.setFill()

        let iconRect = rect.insetBy(dx: 3.8, dy: 3.8)
        let gap: CGFloat = 1.0

        let upperLeft = NSBezierPath()
        upperLeft.move(to: NSPoint(x: iconRect.minX, y: iconRect.maxY))
        upperLeft.line(to: NSPoint(x: iconRect.maxX - gap, y: iconRect.maxY))
        upperLeft.line(to: NSPoint(x: iconRect.minX, y: iconRect.minY + gap))
        upperLeft.close()
        upperLeft.fill()

        let lowerRight = NSBezierPath()
        lowerRight.move(to: NSPoint(x: iconRect.maxX, y: iconRect.minY))
        lowerRight.line(to: NSPoint(x: iconRect.maxX, y: iconRect.maxY - gap))
        lowerRight.line(to: NSPoint(x: iconRect.minX + gap, y: iconRect.minY))
        lowerRight.close()
        lowerRight.fill()
    }
}
