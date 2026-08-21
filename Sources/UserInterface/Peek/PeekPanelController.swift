// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Floating Peek panel: previews a cross-site page opened from a bookmark- or
/// pinned-bound tab in a child window floating over the page pane (the web-
/// content area only — the sidebar stays fully usable), instead of a normal
/// tab.
///
/// Each peek belongs to its opener tab and every opener can carry its own;
/// the single panel always hosts the focused opener's peek — switching tabs
/// swaps the hosted content (or hides the panel when the focused tab has no
/// peek), and only closing a peek (X, Esc, Cmd-W, click on the page around
/// it) or expanding it ends it. Presentation only — every state transition
/// goes through `BrowserState` (`closePeek` / `expandPeekIntoTab`), whose
/// `peekState` the window controller observes. The hosted view belongs to a live Chromium strip tab
/// kept off the Mac tab list; a child window is required so the panel
/// reliably draws above the accelerated web-content surface and moves with
/// the parent.
final class PeekPanelController {
    private final class PeekPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Rounded opaque backing for the panel. A plain layer-backed view
    /// instead of NSVisualEffectView: the effect view's behind-window
    /// backdrop is composited by the window server and ignores
    /// `layer.cornerRadius`, which left the panel corners square.
    private final class PeekContainerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            updateBackground()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackground()
        }

        private func updateBackground() {
            // Layers don't track appearance changes; resolve the dynamic
            // color under the current effective appearance before assigning.
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
    }

    /// Header button with a rounded hover background (AppKit counterpart of
    /// the sidebar's `themedFill(.hover)` button styling).
    private final class PeekHeaderButton: NSButton {
        private var isHovered = false {
            didSet { updateBackground() }
        }
        private var hoverTrackingArea: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 5
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea {
                removeTrackingArea(hoverTrackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            isHovered = true
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            isHovered = false
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateBackground()
        }

        private func updateBackground() {
            // Layers don't track appearance changes; resolve the dynamic
            // color under the current effective appearance before assigning.
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = isHovered
                    ? NSColor(resource: .sidebarTabHovered).cgColor
                    : NSColor.clear.cgColor
            }
        }
    }

    /// Horizontal margin between the page pane's edges and the panel; the
    /// panel spans the pane's height minus a small fixed breathing margin.
    private static let paneInsetRatio: CGFloat = 0.04
    private static let minPaneInset: CGFloat = 16
    private static let paneVerticalInset: CGFloat = 14
    private static let headerHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 12

    /// Width of the card the panel grows out of — link-sized, so the flight
    /// reads as "that link became this panel".
    private static let flightStartWidth: CGFloat = 44
    private static let flightDuration: TimeInterval = 0.26
    private static let flightContentFadeDuration: TimeInterval = 0.14

    private weak var browserState: BrowserState?
    private weak var parentWindow: NSWindow?
    /// The page-pane view the panel is anchored over (web-content container).
    private weak var anchorView: NSView?
    /// Supplies the press the peek was opened from; owned by the window
    /// controller because it must record presses from before the first peek,
    /// which is when this controller is built.
    private weak var originTracker: PeekOriginTracker?
    private let panel: PeekPanel
    private let containerView = PeekContainerView()
    private let headerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let webHostView = NSView()
    private weak var hostedTab: Tab?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    private var titleCancellable: AnyCancellable?
    /// True between an appear flight's start and its landing; keeps the
    /// landing idempotent across the completion block and the teardown paths.
    private var isFlying = false
    /// See `setConcealedByInWindowOverlay`.
    private var isConcealedByInWindowOverlay = false
    /// See `setEclipsedByInWindowOverlay`.
    private var isEclipsedByInWindowOverlay = false

    init(browserState: BrowserState,
         parentWindow: NSWindow,
         anchorView: NSView,
         originTracker: PeekOriginTracker?) {
        self.browserState = browserState
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        self.originTracker = originTracker
        anchorView.postsFrameChangedNotifications = true

        panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        panel.contentView = containerView

        buildHeader()

        containerView.addSubview(webHostView)
        webHostView.snp.makeConstraints { make in
            make.top.equalTo(headerView.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    deinit {
        removeEventMonitor()
        removeGeometryObservers()
    }

    // MARK: - Presentation

    /// - Parameter flyIn: whether this peek is one the user just opened, and
    ///   so may fly out of the press that opened it. Only the window
    ///   controller can tell — mounting content here happens both for a fresh
    ///   peek and for switching to another opener's existing one.
    func present(tab: Tab, flyIn: Bool) {
        guard let browserState else { return }

        // Re-focus of the opener tab with the same peek still mounted: just
        // reveal, no re-mount and no flight — nothing was opened here, the
        // panel is coming back from a tab switch.
        if hostedTab === tab, !webHostView.subviews.isEmpty {
            reveal(focusContent: true, flyIn: false)
            return
        }

        guard let webView = tab.webContentView else {
            // Without a native view there is nothing to host — degrade to a
            // regular tab instead of showing an empty panel.
            AppLogWarn("👀 [Peek] tab \(tab.guid) has no webContentView — expanding into a tab")
            browserState.expandPeekIntoTab(peekTabId: tab.guid)
            return
        }

        detachHostedContent()
        hostedTab = tab
        bindTitle(to: tab)

        webHostView.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        reveal(focusContent: true, flyIn: flyIn)
    }

    /// Temporarily hides the panel while the opener tab is not focused. The
    /// hosted content and bindings stay alive; `present(tab:)` reveals again.
    func hide() {
        guard panel.isVisible else { return }
        landAppearFlight()
        removeEventMonitor()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// While the omnibox floats over the panel (it lives in its own child
    /// window one level up), the panel stays visible but goes input-inert:
    /// its local monitor must not fight the omnibox for Esc/shortcuts or
    /// close the peek on the omnibox's background clicks, and reveals must
    /// not steal the omnibox's key. On un-eclipse the panel takes key back.
    func setEclipsedByInWindowOverlay(_ eclipsed: Bool) {
        guard isEclipsedByInWindowOverlay != eclipsed else { return }
        isEclipsedByInWindowOverlay = eclipsed
        if !eclipsed {
            revealIfStillCurrent()
        }
    }

    /// While an in-window blocking overlay (tab search) is up, the panel
    /// steps aside entirely: it is a child window, which draws above every
    /// in-window view, so left in place it would cover the overlay. Content
    /// stays mounted — the opener's page shows beneath, which is what the
    /// overlay targets anyway (a committed navigation closes the peek
    /// through `closePeekForAddressBarNavigation`).
    func setConcealedByInWindowOverlay(_ concealed: Bool) {
        guard isConcealedByInWindowOverlay != concealed else { return }
        isConcealedByInWindowOverlay = concealed
        if concealed {
            hide()
        } else {
            revealIfStillCurrent()
        }
    }

    /// Un-conceal path: the hosted peek may have closed, or the focused tab
    /// may have changed, while the overlay was up — only come back when this
    /// panel's content is still the focused opener's peek.
    private func revealIfStillCurrent() {
        guard let tab = hostedTab,
              let browserState,
              let focusedTabId = browserState.focusingTab?.guid,
              browserState.peekState.peek(forOpener: focusedTabId) === tab else {
            return
        }
        reveal(focusContent: true, flyIn: false)
    }

    /// Idempotent teardown of the panel. Never closes the tab itself — that
    /// is `BrowserState`'s job (`closePeek`) or Chromium's (window teardown).
    func dismiss() {
        removeEventMonitor()
        removeGeometryObservers()
        // Detach the Chromium view BEFORE the window goes away: its lifetime
        // is owned by Chromium and it must not linger in a dying hierarchy.
        detachHostedContent()
        if let parent = panel.parent {
            parent.removeChildWindow(panel)
            panel.orderOut(nil)
            parent.makeKey()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Synchronous best-effort detach used from `tabWillBeRemove`, while the
    /// closing WebContents is still alive. The full dismiss follows through
    /// the async `closeTab` → `peekState` path.
    func detachContentIfHosting(tabId: Int) {
        guard hostedTab?.guid == tabId else { return }
        detachHostedContent()
    }

    // MARK: - Actions

    @objc private func closeButtonClicked(_ sender: Any?) {
        closeHostedPeek()
    }

    @objc private func expandButtonClicked(_ sender: Any?) {
        guard let tab = hostedTab else { return }
        browserState?.expandPeekIntoTab(peekTabId: tab.guid)
    }

    @objc private func splitButtonClicked(_ sender: Any?) {
        guard let tab = hostedTab else { return }
        browserState?.openPeekAsSplitWithOpener(peekTabId: tab.guid)
    }

    /// Closes the peek the panel is currently hosting (the focused opener's).
    private func closeHostedPeek() {
        guard let tab = hostedTab else { return }
        browserState?.closePeek(peekTabId: tab.guid)
    }

    // MARK: - Internals

    private func reveal(focusContent: Bool, flyIn: Bool) {
        // Content mounts regardless, but the panel stays down until the
        // in-window overlay it stepped aside for goes away.
        guard !isConcealedByInWindowOverlay else { return }
        guard let parentWindow else { return }
        layoutOnAnchor()
        // Before the panel is ordered in, so the first frame the window server
        // paints is already the flight's first frame instead of the settled
        // panel.
        if flyIn {
            beginAppearFlight()
        }
        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        if isEclipsedByInWindowOverlay {
            // Visible beneath the floating omnibox, but never its key.
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            if focusContent, let webView = webHostView.subviews.first {
                // Re-parenting a Chromium view clears the first responder;
                // without this, keyboard input inside the peek page is dead.
                panel.makeFirstResponder(webView)
                hostedTab?.webContentWrapper?.focus()
            }
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    private func detachHostedContent() {
        landAppearFlight()
        titleCancellable = nil
        webHostView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
    }

    // MARK: - Appear flight

    /// Grows the panel out of the press that opened the peek.
    ///
    /// An EXPLICIT Core Animation layer animation, like the Spaces strip's
    /// chip flight: it is the one animation kind that keeps playing in the
    /// render server while the main thread is blocked — and a peek presents
    /// right on top of Chromium's tab creation and web-view re-parenting,
    /// which block it. The model geometry stays settled throughout, so an
    /// expired animation leaves the panel exactly where it belongs.
    ///
    /// No-ops without a usable origin (keyboard open, session restore, a
    /// press already spent on an earlier flight); the panel then appears the
    /// way it did before this existed.
    private func beginAppearFlight() {
        // Order matters: the origin is consumed FIRST, then Reduce Motion is
        // honoured. The press belongs to this peek whether or not it gets an
        // animation, and `PeekOriginTracker` promises each press funds at most
        // one flight — leaving it unspent here would let the peek the user
        // just opened statically hand its press to a later one. Reduce Motion
        // is the same check `EdgeFogOverlayView` and `CustomTooltipController`
        // make; a scale-and-travel animation this large steps aside entirely,
        // so nothing visual happens below this line on that path.
        guard let originScreenPoint = originTracker?.consumeOrigin(),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = containerView.layer,
              let start = Self.appearFlightTransform(
                  originScreenPoint: originScreenPoint,
                  panelScreenFrame: panel.frame,
                  startWidth: Self.flightStartWidth) else { return }
        isFlying = true
        // The window shadow is drawn from the panel's full frame; left on, it
        // would hang in the air around the small card. Restored on landing.
        panel.hasShadow = false
        // The hosted Chromium view is a remote layer — don't scale it. It sits
        // the flight out and fades in once the panel is at full size.
        webHostView.isHidden = true

        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.landAppearFlight()
        }

        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = start
        grow.toValue = CATransform3DIdentity
        grow.duration = Self.flightDuration
        grow.timingFunction = timing
        layer.add(grow, forKey: "phiPeekAppearFlight")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.flightDuration / 2
        fade.timingFunction = timing
        layer.add(fade, forKey: "phiPeekAppearFade")

        // Corners are scaled down with everything else, so the card would
        // start out with hairline corners. Starting at half the short side
        // keeps the radius visually constant: a link-shaped capsule that
        // settles into the panel's 12pt corners.
        let corners = CABasicAnimation(keyPath: "cornerRadius")
        // From the panel's frame, not the layer's bounds: the layer may not
        // have picked up the frame `layoutOnAnchor` just set.
        corners.fromValue = min(panel.frame.width, panel.frame.height) / 2
        corners.toValue = Self.cornerRadius
        corners.duration = Self.flightDuration
        corners.timingFunction = timing
        layer.add(corners, forKey: "phiPeekAppearCorners")

        CATransaction.commit()
    }

    /// Settles a flight: content back, window shadow back. Idempotent, and
    /// called from the teardown paths as well as the flight's completion, so
    /// a peek that dies mid-flight never leaves its content hidden.
    private func landAppearFlight() {
        guard isFlying else { return }
        isFlying = false
        if let layer = containerView.layer {
            layer.removeAnimation(forKey: "phiPeekAppearFlight")
            layer.removeAnimation(forKey: "phiPeekAppearFade")
            layer.removeAnimation(forKey: "phiPeekAppearCorners")
        }
        webHostView.isHidden = false
        panel.hasShadow = true
        panel.invalidateShadow()
        // The page arrives at full size; a short fade keeps that from being a
        // hard cut.
        if let contentLayer = webHostView.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.flightContentFadeDuration
            contentLayer.add(fade, forKey: "phiPeekContentFade")
        }
    }

    /// The container layer's starting transform for a flight out of
    /// `originScreenPoint`: the panel shrunk to `startWidth` and moved so the
    /// card's centre sits on the press. The press is clamped to keep the card
    /// wholly inside the panel — it can land up to the pane inset outside it,
    /// and the window clips whatever leaves its frame.
    ///
    /// Nil — "don't fly" — for a degenerate panel or a start width that isn't
    /// a real shrink, so a caller that can't produce a sane flight falls back
    /// to the plain appearance instead of showing a broken one.
    static func appearFlightTransform(originScreenPoint: CGPoint,
                                      panelScreenFrame: CGRect,
                                      startWidth: CGFloat) -> CATransform3D? {
        guard startWidth > 0,
              panelScreenFrame.width > startWidth,
              panelScreenFrame.height > 0 else { return nil }
        let scale = startWidth / panelScreenFrame.width
        let travelBounds = panelScreenFrame.insetBy(
            dx: startWidth / 2,
            dy: panelScreenFrame.height * scale / 2
        )
        let anchor = CGPoint(
            x: min(max(originScreenPoint.x, travelBounds.minX), travelBounds.maxX),
            y: min(max(originScreenPoint.y, travelBounds.minY), travelBounds.maxY)
        )
        // Screen space and the container's layer space are both bottom-up
        // (the panel's content view is unflipped), so the offset carries over
        // unchanged.
        let travel = CATransform3DMakeTranslation(anchor.x - panelScreenFrame.midX,
                                                  anchor.y - panelScreenFrame.midY,
                                                  0)
        // Scale about the layer's centre anchor first, then travel.
        return CATransform3DScale(travel, scale, scale, 1)
    }

    private func bindTitle(to tab: Tab) {
        titleCancellable = tab.$title
            .combineLatest(tab.$url)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, url in
                let fallbackHost = url.flatMap { URL(string: $0)?.host } ?? ""
                self?.titleLabel.stringValue = title.isEmpty ? fallbackHost : title
            }
    }

    private func buildHeader() {
        containerView.addSubview(headerView)
        headerView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.headerHeight)
        }

        let closeButton = makeHeaderButton(
            symbolName: "xmark",
            tooltip: NSLocalizedString(
                "peek.panel.closeButtonTooltip",
                value: "Close",
                comment: "Peek popup panel - Tooltip of the button that closes the floating page preview and its page"
            ),
            action: #selector(closeButtonClicked(_:))
        )
        let expandButton = makeHeaderButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            tooltip: NSLocalizedString(
                "peek.panel.expandButtonTooltip",
                value: "Open as Tab",
                comment: "Peek popup panel - Tooltip of the button that converts the floating page preview into a regular tab"
            ),
            action: #selector(expandButtonClicked(_:))
        )
        let splitButton = makeHeaderButton(
            symbolName: "rectangle.split.2x1",
            tooltip: NSLocalizedString(
                "peek.panel.splitButtonTooltip",
                value: "Open as Split View",
                comment: "Peek popup panel - Tooltip of the button that pairs the floating page preview with its bound tab in a side-by-side split view"
            ),
            action: #selector(splitButtonClicked(_:))
        )

        headerView.addSubview(closeButton)
        closeButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        headerView.addSubview(expandButton)
        expandButton.snp.makeConstraints { make in
            make.leading.equalTo(closeButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        headerView.addSubview(splitButton)
        splitButton.snp.makeConstraints { make in
            make.leading.equalTo(expandButton.snp.trailing).offset(8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(22)
        }

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        headerView.addSubview(titleLabel)
        titleLabel.snp.makeConstraints { make in
            make.centerX.centerY.equalToSuperview()
            make.leading.greaterThanOrEqualTo(splitButton.snp.trailing).offset(12)
            make.trailing.lessThanOrEqualToSuperview().inset(72)
        }
    }

    private func makeHeaderButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = PeekHeaderButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        return button
    }

    /// Screen rect of the page pane the panel floats over.
    private func anchorScreenRect() -> NSRect? {
        guard let anchorView, let window = anchorView.window else { return nil }
        let inWindow = anchorView.convert(anchorView.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func layoutOnAnchor() {
        guard let paneRect = anchorScreenRect() else { return }
        // Near-full pane height; width follows the pane (and thus the
        // window) with a proportional side margin.
        let insetX = max(Self.minPaneInset, paneRect.width * Self.paneInsetRatio)
        panel.setFrame(paneRect.insetBy(dx: insetX, dy: Self.paneVerticalInset),
                       display: true)
    }

    private func installGeometryObserversIfNeeded() {
        if parentResizeObserver == nil, let parentWindow {
            // Child windows do not follow parent resizes on their own.
            parentResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: parentWindow,
                queue: .main
            ) { [weak self] _ in
                self?.relayoutIfVisible()
            }
        }
        if anchorFrameObserver == nil, let anchorView {
            // Sidebar collapse / split-divider drags resize the page pane
            // without resizing the window.
            anchorFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: anchorView,
                queue: .main
            ) { [weak self] _ in
                self?.relayoutIfVisible()
            }
        }
    }

    private func relayoutIfVisible() {
        guard panel.isVisible else { return }
        layoutOnAnchor()
    }

    private func removeGeometryObservers() {
        if let parentResizeObserver {
            NotificationCenter.default.removeObserver(parentResizeObserver)
        }
        parentResizeObserver = nil
        if let anchorFrameObserver {
            NotificationCenter.default.removeObserver(anchorFrameObserver)
        }
        anchorFrameObserver = nil
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.panel.isVisible,
                  !self.isEclipsedByInWindowOverlay else { return event }
            switch event.type {
            case .keyDown:
                // Esc closes the peek. Cmd-W must be swallowed here: strip-
                // active is the bound opener while the peek is up, so letting
                // it reach Chromium's IDC_CLOSE_TAB would close the opener.
                if event.keyCode == 53 {
                    self.closeHostedPeek()
                    return nil
                }
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers?.lowercased() == "w" {
                    self.closeHostedPeek()
                    return nil
                }
                // Back/Forward reads as "leave the preview": close the peek
                // and swallow the key. Matched here (against the configured
                // shortcuts) because the peek's web view holds focus — the
                // event would otherwise walk the peek page's own history
                // instead of reaching the menu command.
                if let eventKeys = ShortcutsKey.eventKeys(for: event) {
                    let backForwardKeys = [Shortcuts.key(for: .IDC_BACK),
                                           Shortcuts.key(for: .IDC_FORWARD)].compactMap { $0 }
                    if eventKeys.matchingKeys.contains(where: backForwardKeys.contains) {
                        self.closeHostedPeek()
                        return nil
                    }
                }
                return event
            case .leftMouseDown, .rightMouseDown:
                // Only clicks on the page pane around the panel close the
                // peek (Arc behavior). Sidebar/toolbar clicks pass through so
                // the user can switch tabs — the peek then hides with its
                // opener instead of closing.
                let location = NSEvent.mouseLocation
                if self.panel.frame.contains(location) {
                    return event
                }
                if let paneRect = self.anchorScreenRect(), paneRect.contains(location) {
                    self.closeHostedPeek()
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
