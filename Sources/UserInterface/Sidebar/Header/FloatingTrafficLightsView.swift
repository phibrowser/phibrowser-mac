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
}

final class FloatingTrafficLightsView: NSView {
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
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isGroupHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isGroupHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindowState()
        setupStateObserversIfNeeded()
        updateWindowActiveState()
        syncWindowButtonAvailability()
    }

    private func setupViews() {
        setAccessibilityElement(false)
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
        dotViews.forEach { $0.syncControlAvailability(from: window, isEnabled: isEnabled) }
        refreshHoverStateFromPointer()
    }

    private func scheduleHoverStateRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshHoverStateFromPointer()
        }
    }

    private func refreshHoverStateFromPointer() {
        guard isHidden == false, let window else {
            isGroupHovered = false
            return
        }

        let locationInSelf = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isGroupHovered = bounds.contains(locationInSelf)
    }

    private var shouldEnableWindowButtonActions: Bool {
        guard browserState?.sidebarCollapsed == true,
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
