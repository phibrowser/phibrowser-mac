// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
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
    /// See `ChromiumHostingPanel`: hosting a re-parented Chromium view in a
    /// key panel needs the shared key-equivalent routing, or every shortcut
    /// this panel's event monitor does not name is swallowed.
    private final class PeekPanel: ChromiumHostingPanel {}

    /// Rounded opaque backing for the card, and what casts its shadow. A
    /// plain layer-backed view instead of NSVisualEffectView: the effect
    /// view's behind-window backdrop is composited by the window server and
    /// ignores `layer.cornerRadius`, which left the panel corners square.
    ///
    /// Deliberately unclipped — `masksToBounds` would clip the layer's own
    /// shadow away, so the rounding of the page itself is `webHostView`'s job
    /// and this view only draws the card's background beneath it.
    private final class PeekContainerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.35
            layer?.shadowRadius = 10
            layer?.shadowOffset = CGSize(width: 0, height: -3)
            updateBackground()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            // An explicit path keeps the window server from deriving the
            // shadow from the card's alpha on every frame of the appear
            // flight; the card is pane-sized, and that is not cheap.
            let radius = PeekPanelController.cornerRadius
            layer?.shadowPath = CGPath(roundedRect: bounds,
                                       cornerWidth: radius,
                                       cornerHeight: radius,
                                       transform: nil)
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

    /// Control button: an accent-tinted glyph on an opaque rounded chip.
    /// The chip is what makes it readable — the strip it sits in is
    /// transparent, so a bare glyph competes with whatever the page behind
    /// the peek happens to be showing there.
    private final class PeekControlButton: NSButton {
        /// Window whose theme the accent resolves against. The panel is a
        /// child window with no window controller of its own, so resolving
        /// against it would fall back to the global theme instead of the
        /// browser window's (each window carries its own theme context).
        weak var themeHostWindow: NSWindow?

        private var isHovered = false {
            didSet { updateColors() }
        }
        private var hoverTrackingArea: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.controlCornerRadius
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            // Unclipped, so the chip's own shadow survives; `cornerRadius`
            // rounds the fill and the border on its own, and the glyph never
            // reaches the corners.
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.24
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: -1)
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
            updateColors()
        }

        /// Re-resolves both themed colors. Called on appearance changes and
        /// whenever the panel is revealed, so a theme switched between peeks
        /// is picked up.
        func updateColors() {
            let accent = (isHovered ? ThemedColor.themeColorOnHover : ThemedColor.themeColor)
                .resolve(in: themeHostWindow)
            contentTintColor = accent
            // The page card's own material, so a control reads as a chip of
            // the peek rather than as part of the page underneath it.
            let chip = ThemedColor.contentOverlayBackground.resolve(in: themeHostWindow)
            layer?.backgroundColor = (isHovered
                ? chip.blended(withFraction: 0.14, of: accent) ?? chip
                : chip).cgColor
            layer?.borderColor = ThemedColor.border.resolve(in: themeHostWindow).cgColor
        }
    }

    /// Transparent strip to the right of the card holding the controls.
    /// Hit-transparent where no button sits: the strip is page pane like any
    /// other area around the card, so clicks in the gaps must reach the
    /// dismiss monitor instead of dying on this view.
    private final class PeekControlColumnView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === self ? nil : hit
        }
    }

    /// Horizontal margin between the page card's edges and the panel; the
    /// panel spans the card's height minus a small fixed breathing margin.
    private static let paneInsetRatio: CGFloat = 0.04
    private static let minPaneInset: CGFloat = 16
    private static let paneVerticalInset: CGFloat = 14
    private static let cornerRadius: CGFloat = 12

    /// The card carries no chrome of its own (Arc's peek layout): the page
    /// fills it edge to edge and the controls live in a transparent strip the
    /// panel window keeps to the card's right, over the page pane.
    private static let controlGutterWidth: CGFloat = 44
    private static let controlButtonSize: CGFloat = 28
    private static let controlCornerRadius: CGFloat = 8
    private static let controlSpacing: CGFloat = 6
    private static let controlTopInset: CGFloat = 6

    /// Room the window keeps around the card and the controls for their
    /// shadows to draw into. A window clips its own content, and the system
    /// window shadow can't be styled — so the panel carries its shadows
    /// itself and holds a margin for them. Taken out of the card's pane
    /// inset (`paneVerticalInset` is the tightest side), never added to the
    /// window's reach: the panel still stops at the page card's edges.
    private static let shadowMargin: CGFloat = 14

    /// Width of the card the panel grows out of — link-sized, so the flight
    /// reads as "that link became this panel".
    private static let flightStartWidth: CGFloat = 44
    private static let flightDuration: TimeInterval = 0.26
    private static let flightContentFadeDuration: TimeInterval = 0.14

    private weak var browserState: BrowserState?
    private weak var parentWindow: NSWindow?
    /// The web-content container view: the click-to-dismiss region, and the
    /// sizing fallback while no page card is mounted.
    private weak var anchorView: NSView?
    /// Resolves the focused tab's rounded page card — the region the panel
    /// insets itself inside. A closure because the card view belongs to
    /// whichever `WebContentViewController` is currently displayed.
    private let cardViewProvider: () -> NSView?
    /// Supplies the press the peek was opened from; owned by the window
    /// controller because it must record presses from before the first peek,
    /// which is when this controller is built.
    private weak var originTracker: PeekOriginTracker?
    private let panel: PeekPanel
    /// Transparent content view spanning card + control gutter.
    private let rootView = NSView()
    private let containerView = PeekContainerView()
    private let controlColumn = PeekControlColumnView()
    private let webHostView = NSView()
    private weak var hostedTab: Tab?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    /// Frame observation of the card itself: the card can move without the
    /// container or window resizing (AI Chat dock, layout-mode insets).
    private var cardFrameObserver: NSObjectProtocol?
    private weak var observedCardView: NSView?
    /// True between an appear flight's start and its landing; keeps the
    /// landing idempotent across the completion block and the teardown paths.
    private var isFlying = false
    /// The armed flight's start transform, held between `armAppearFlight`
    /// (before the panel is ordered in) and `runAppearFlight` (once it is on
    /// screen). Non-nil only inside that gap.
    private var pendingFlightStart: CATransform3D?
    /// The armed flight's start corner radius; see `pendingFlightStart`.
    private var pendingFlightStartCornerRadius: CGFloat = 0
    /// See `setConcealedByInWindowOverlay`.
    private var isConcealedByInWindowOverlay = false
    /// See `setEclipsedByInWindowOverlay`.
    private var isEclipsedByInWindowOverlay = false
    /// The omnibox host window this panel is currently eclipsed by, so
    /// reveals can re-order themselves under it. See
    /// `setEclipsedByInWindowOverlay`.
    private weak var eclipsingOverlayWindow: NSWindow?

    init(browserState: BrowserState,
         parentWindow: NSWindow,
         anchorView: NSView,
         cardViewProvider: @escaping () -> NSView?,
         originTracker: PeekOriginTracker?) {
        self.browserState = browserState
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        self.cardViewProvider = cardViewProvider
        self.originTracker = originTracker
        anchorView.postsFrameChangedNotifications = true

        panel = PeekPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        // The card draws its own shadow (see `shadowMargin`); the system
        // window shadow would add a second halo around the whole frame,
        // which now spans the page card almost edge to edge.
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false

        panel.contentView = rootView

        rootView.addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.top.leading.bottom.equalToSuperview().inset(Self.shadowMargin)
            make.trailing.equalToSuperview().inset(Self.shadowMargin + Self.controlGutterWidth)
        }

        buildControls()

        // The page's own rounding: the card behind it stays unclipped so it
        // can cast a shadow.
        webHostView.wantsLayer = true
        webHostView.layer?.cornerRadius = Self.cornerRadius
        webHostView.layer?.cornerCurve = .continuous
        webHostView.layer?.masksToBounds = true
        containerView.addSubview(webHostView)
        webHostView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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

    /// While the omnibox floats over the panel (it lives in a sibling child
    /// window of the same browser window), the panel stays visible but goes
    /// input-inert: its local monitor must not fight the omnibox for
    /// Esc/shortcuts or close the peek on the omnibox's background clicks,
    /// and reveals must not steal the omnibox's key. On un-eclipse the panel
    /// takes key back.
    func setEclipsedByInWindowOverlay(_ eclipsed: Bool, by overlayWindow: NSWindow? = nil) {
        guard isEclipsedByInWindowOverlay != eclipsed else { return }
        isEclipsedByInWindowOverlay = eclipsed
        eclipsingOverlayWindow = eclipsed ? overlayWindow : nil
        if eclipsed {
            // Already on screen: drop under the host that just came up.
            if panel.isVisible { orderUnderEclipsingOverlay() }
        } else {
            revealIfStillCurrent()
        }
    }

    /// Places the panel directly under the omnibox host, ordering it in if it
    /// was off screen. The host and this panel are child windows of the same
    /// browser window sharing its level, so which one covers the other is a
    /// question of sibling order — the omnibox cannot buy that layering with a
    /// raised level without also floating above other applications. Returns
    /// false when there is no host on screen to sit under.
    @discardableResult
    private func orderUnderEclipsingOverlay() -> Bool {
        guard let overlayWindow = eclipsingOverlayWindow,
              overlayWindow.isVisible else { return false }
        panel.order(.below, relativeTo: overlayWindow.windowNumber)
        return true
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
        refreshControlTints()
        layoutOnAnchor()
        // Before the panel is ordered in, so the first frame the window server
        // paints is already the flight's first frame instead of the settled
        // panel. Arming only sets the model geometry — the animations need a
        // panel that is actually on screen, and go on below.
        if flyIn {
            armAppearFlight()
        }
        if panel.parent == nil {
            parentWindow.addChildWindow(panel, ordered: .above)
        }
        var focusesContent = false
        if isEclipsedByInWindowOverlay {
            // Visible beneath the floating omnibox, but never its key — and
            // never over it: come in under the host rather than to the front.
            if !orderUnderEclipsingOverlay() {
                panel.orderFront(nil)
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
            focusesContent = focusContent
        }
        // On screen now, so the flight plays against a live render context.
        // Before the Chromium focus hop below on purpose: that call blocks the
        // main thread, and an explicit layer animation already handed to the
        // render server keeps playing straight through it.
        runAppearFlight()
        if focusesContent, let webView = webHostView.subviews.first {
            // Re-parenting a Chromium view clears the first responder;
            // without this, keyboard input inside the peek page is dead.
            panel.makeFirstResponder(webView)
            hostedTab?.webContentWrapper?.focus()
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    /// Re-applies the theme accent to the controls; the theme can change
    /// while no peek is up.
    private func refreshControlTints() {
        for button in controlColumn.subviews.compactMap({ $0 as? PeekControlButton }) {
            button.updateColors()
        }
    }

    private func detachHostedContent() {
        landAppearFlight()
        webHostView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
    }

    // MARK: - Appear flight

    /// Arms a flight out of the press that opened the peek: the card's MODEL
    /// geometry is put ON the press, so the very first frame the window
    /// server paints once the panel is ordered in is already the flight's
    /// first frame. `runAppearFlight` plays it from there.
    ///
    /// The animations themselves cannot be added here, which is what stopped
    /// this working. A layer in a window that has never been ordered in is
    /// not attached to a live render context: animations committed against it
    /// run against a clock nothing is drawing to, and the transaction's
    /// completion block — which lands the flight, removing all three
    /// animations — fires on that same commit. The peek then just appeared.
    ///
    /// No-ops without a usable origin (keyboard open, session restore, a
    /// press already spent on an earlier flight); the panel then appears the
    /// way it did before this existed.
    private func armAppearFlight() {
        // Order matters: the origin is consumed FIRST, then Reduce Motion is
        // honoured. The press belongs to this peek whether or not it gets an
        // animation, and `PeekOriginTracker` promises each press funds at most
        // one flight — leaving it unspent here would let the peek the user
        // just opened statically hand its press to a later one. Reduce Motion
        // is the same check `EdgeFogOverlayView` and `CustomTooltipController`
        // make; a scale-and-travel animation this large steps aside entirely,
        // so nothing visual happens below this line on that path.
        guard let originScreenPoint = originTracker?.consumeOrigin() else {
            // Every non-flying open lands here; the log says which kind, so a
            // peek that should have flown and did not is one line away from
            // being placed.
            AppLogInfo("👀 [Peek] appear flight skipped: no press to fly out of")
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = containerView.layer,
              let start = Self.appearFlightTransform(
                  originScreenPoint: originScreenPoint,
                  cardScreenFrame: cardScreenRect,
                  startWidth: Self.flightStartWidth,
                  anchorPoint: layer.anchorPoint) else {
            AppLogInfo("👀 [Peek] appear flight skipped: reduce motion or unflyable card \(cardScreenRect)")
            return
        }
        AppLogInfo("👀 [Peek] appear flight armed from \(originScreenPoint) card=\(cardScreenRect)")
        isFlying = true
        // The card's shadow is its own layer's, so it travels and shrinks
        // with the card — nothing to switch off here.
        // The hosted Chromium view is a remote layer — don't scale it. It sits
        // the flight out and fades in once the panel is at full size.
        webHostView.isHidden = true
        // The controls belong beside the settled card, not hanging in the
        // pane next to the travelling one — they come in with the page.
        controlColumn.isHidden = true

        // Corners are scaled down with everything else, so the card would
        // start out with hairline corners. Starting at half the short side
        // keeps the radius visually constant: a link-shaped capsule that
        // settles into the panel's 12pt corners. From the card's frame, not
        // the layer's bounds: the layer may not have picked up the frame
        // `layoutOnAnchor` just set.
        let startCornerRadius = min(cardScreenRect.width, cardScreenRect.height) / 2
        pendingFlightStart = start
        pendingFlightStartCornerRadius = startCornerRadius

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = start
        layer.cornerRadius = startCornerRadius
        CATransaction.commit()
        // Through the view, not `layer.opacity`: AppKit drives a layer-backed
        // view's opacity from `alphaValue` and would clobber a raw assignment
        // on the next display pass.
        containerView.alphaValue = 0
    }

    /// Plays the armed flight, now that the panel is on screen.
    ///
    /// EXPLICIT Core Animation layer animations, like the Spaces strip's chip
    /// flight: they are the one animation kind that keeps playing in the
    /// render server while the main thread is blocked — and a peek presents
    /// right on top of Chromium's web-view re-parenting and focus hop, which
    /// block it. The model geometry goes back to settled in the same
    /// transaction, so an expired animation leaves the card exactly where it
    /// belongs.
    ///
    /// No-op unless `armAppearFlight` armed one.
    private func runAppearFlight() {
        guard let start = pendingFlightStart,
              let layer = containerView.layer else { return }
        let startCornerRadius = pendingFlightStartCornerRadius
        pendingFlightStart = nil

        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            self?.landAppearFlight()
        }

        // Model back at rest and the animations that hide it added in the
        // SAME transaction, so no frame ever shows the settled card before
        // the flight takes over.
        layer.transform = CATransform3DIdentity
        layer.cornerRadius = Self.cornerRadius
        containerView.alphaValue = 1

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

        let corners = CABasicAnimation(keyPath: "cornerRadius")
        corners.fromValue = startCornerRadius
        corners.toValue = Self.cornerRadius
        corners.duration = Self.flightDuration
        corners.timingFunction = timing
        layer.add(corners, forKey: "phiPeekAppearCorners")

        CATransaction.commit()
    }

    /// Settles a flight: model geometry back at rest, content back.
    /// Idempotent, and called from the teardown paths as well as the flight's
    /// completion, so a peek that dies mid-flight — or one armed and then torn
    /// down before it ever ran — never leaves its card shrunk onto the press
    /// or its content hidden.
    private func landAppearFlight() {
        guard isFlying else { return }
        isFlying = false
        pendingFlightStart = nil
        if let layer = containerView.layer {
            layer.removeAnimation(forKey: "phiPeekAppearFlight")
            layer.removeAnimation(forKey: "phiPeekAppearFade")
            layer.removeAnimation(forKey: "phiPeekAppearCorners")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            layer.cornerRadius = Self.cornerRadius
            CATransaction.commit()
        }
        containerView.alphaValue = 1
        webHostView.isHidden = false
        controlColumn.isHidden = false
        // The page and its controls arrive at full size; a short fade keeps
        // that from being a hard cut.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.flightContentFadeDuration
        webHostView.layer?.add(fade, forKey: "phiPeekContentFade")
        controlColumn.layer?.add(fade, forKey: "phiPeekContentFade")
    }

    /// The container layer's starting transform for a flight out of
    /// `originScreenPoint`: the card shrunk to `startWidth` and moved so its
    /// centre sits on the press. The press is clamped to keep the shrunk card
    /// wholly inside the card's own frame — it can land up to the pane inset
    /// outside it, and the window clips whatever leaves its frame.
    ///
    /// - Parameter anchorPoint: the layer's own `anchorPoint`, which is what
    ///   the scale pins. It is NOT the UIKit-familiar (0.5, 0.5) here:
    ///   `NSViewBackingLayer` anchors at (0, 0), the layer's bottom-left, so
    ///   a shrink leaves the card in the corner and the travel has to carry
    ///   its centre the rest of the way. Taking it as a parameter rather than
    ///   assuming a convention is what keeps this rule honest — the first cut
    ///   assumed a centred anchor and every peek flew out of the bottom
    ///   corner.
    ///
    /// Nil — "don't fly" — for a degenerate card or a start width that isn't
    /// a real shrink, so a caller that can't produce a sane flight falls back
    /// to the plain appearance instead of showing a broken one.
    static func appearFlightTransform(originScreenPoint: CGPoint,
                                      cardScreenFrame: CGRect,
                                      startWidth: CGFloat,
                                      anchorPoint: CGPoint) -> CATransform3D? {
        guard startWidth > 0,
              cardScreenFrame.width > startWidth,
              cardScreenFrame.height > 0 else { return nil }
        let scale = startWidth / cardScreenFrame.width
        let travelBounds = cardScreenFrame.insetBy(
            dx: startWidth / 2,
            dy: cardScreenFrame.height * scale / 2
        )
        let anchor = CGPoint(
            x: min(max(originScreenPoint.x, travelBounds.minX), travelBounds.maxX),
            y: min(max(originScreenPoint.y, travelBounds.minY), travelBounds.maxY)
        )
        // Core Animation maps a bounds point p to `position + M·(p - a)`,
        // where `a` is the anchor in bounds coordinates. The card's centre is
        // therefore already at `cardScreenFrame.origin + a + scale·(size/2 -
        // a)` once the shrink lands, and the travel makes up the remainder.
        // Screen space and the container's layer space are both bottom-up
        // (the panel's content view is unflipped), so the offset carries over
        // unchanged.
        let a = CGPoint(x: anchorPoint.x * cardScreenFrame.width,
                        y: anchorPoint.y * cardScreenFrame.height)
        let travel = CATransform3DMakeTranslation(
            anchor.x - cardScreenFrame.minX - a.x - scale * (cardScreenFrame.width / 2 - a.x),
            anchor.y - cardScreenFrame.minY - a.y - scale * (cardScreenFrame.height / 2 - a.y),
            0
        )
        // Scale about the layer's anchor first, then travel.
        return CATransform3DScale(travel, scale, scale, 1)
    }

    private func buildControls() {
        rootView.addSubview(controlColumn)
        controlColumn.snp.makeConstraints { make in
            make.top.trailing.equalToSuperview().inset(Self.shadowMargin)
            make.width.equalTo(Self.controlGutterWidth)
        }

        let closeButton = makeControlButton(
            symbolName: "xmark",
            tooltip: NSLocalizedString(
                "peek.panel.closeButtonTooltip",
                value: "Close",
                comment: "Peek popup panel - Tooltip of the button that closes the floating page preview and its page"
            ),
            action: #selector(closeButtonClicked(_:))
        )
        let expandButton = makeControlButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            tooltip: NSLocalizedString(
                "peek.panel.expandButtonTooltip",
                value: "Open as Tab",
                comment: "Peek popup panel - Tooltip of the button that converts the floating page preview into a regular tab"
            ),
            action: #selector(expandButtonClicked(_:))
        )
        let splitButton = makeControlButton(
            symbolName: "rectangle.split.2x1",
            tooltip: NSLocalizedString(
                "peek.panel.splitButtonTooltip",
                value: "Open as Split View",
                comment: "Peek popup panel - Tooltip of the button that pairs the floating page preview with its bound tab in a side-by-side split view"
            ),
            action: #selector(splitButtonClicked(_:))
        )

        var previous: NSView?
        for button in [closeButton, expandButton, splitButton] {
            controlColumn.addSubview(button)
            button.snp.makeConstraints { make in
                make.centerX.equalToSuperview()
                make.width.height.equalTo(Self.controlButtonSize)
                if let previous {
                    make.top.equalTo(previous.snp.bottom).offset(Self.controlSpacing)
                } else {
                    make.top.equalToSuperview().offset(Self.controlTopInset)
                }
            }
            previous = button
        }
        // The column is only as tall as its buttons; the rest of the strip
        // beside the card stays empty page pane.
        previous?.snp.makeConstraints { make in
            make.bottom.equalToSuperview()
        }
    }

    private func makeControlButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let button = PeekControlButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        button.toolTip = tooltip
        button.themeHostWindow = parentWindow
        button.updateColors()
        button.target = self
        button.action = action
        return button
    }

    /// Screen rect of the web-content container: the region whose clicks
    /// dismiss the peek. Wider than the page card by the window margins,
    /// which is what "click on the page around it" should cover.
    private func anchorScreenRect() -> NSRect? {
        guard let anchorView, let window = anchorView.window else { return nil }
        let inWindow = anchorView.convert(anchorView.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Screen rect of the page card the panel floats over: the focused tab's
    /// rounded card when one is mounted, else the whole container as a
    /// degraded fallback. The card, not the container — the container also
    /// spans the window margins around the card, and insetting from those
    /// left the panel all but flush with the page's edges.
    private func pageCardScreenRect() -> NSRect? {
        guard let card = cardViewProvider() else { return anchorScreenRect() }
        guard let window = card.window else { return anchorScreenRect() }
        refreshCardFrameObserverIfNeeded(for: card)
        return window.convertToScreen(card.convert(card.bounds, to: nil))
    }

    private func layoutOnAnchor() {
        guard let cardRect = pageCardScreenRect() else { return }
        // Near-full card height; width follows the card (and thus the
        // window) with a proportional side margin.
        let insetX = max(Self.minPaneInset, cardRect.width * Self.paneInsetRatio)
        let card = cardRect.insetBy(dx: insetX, dy: Self.paneVerticalInset)
        // The window spans the card, the control gutter to its right, and the
        // shadow margin around the lot — the card view sits back inside it at
        // exactly the inset it had before there was a shadow, so the peek
        // keeps its place on the page. The gutter is taken out of the card's
        // own right margin; a margin too narrow to hold it narrows the card
        // instead of pushing the controls off the page pane.
        let maxX = min(card.maxX + Self.controlGutterWidth + Self.shadowMargin, cardRect.maxX)
        let originX = card.minX - Self.shadowMargin
        panel.setFrame(CGRect(x: originX,
                              y: card.minY - Self.shadowMargin,
                              width: max(maxX - originX, Self.controlGutterWidth),
                              height: card.height + Self.shadowMargin * 2),
                       display: true)
        // Auto Layout has to catch up before the appear flight transforms the
        // card's layer: the scale is applied about the layer's OWN centre, so
        // a layer still carrying its pre-frame bounds would shrink about the
        // wrong point and fly out of the wrong place. `setFrame(display:)`
        // lays out nothing on a window that has never been ordered in, which
        // is exactly the first-peek case.
        rootView.layoutSubtreeIfNeeded()
    }

    /// Screen rect of the card alone: the window frame minus the shadow
    /// margin and the control gutter. Derived from the frame rather than read
    /// off the view so it is right before the first layout pass — the appear
    /// flight runs on the frame `layoutOnAnchor` has only just set.
    private var cardScreenRect: NSRect {
        var rect = panel.frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin)
        rect.size.width = max(0, rect.width - Self.controlGutterWidth)
        return rect
    }

    /// Follows the card view currently being covered; re-registered when the
    /// displayed tab (and so the card view) changes.
    private func refreshCardFrameObserverIfNeeded(for view: NSView) {
        guard observedCardView !== view else { return }
        if let cardFrameObserver {
            NotificationCenter.default.removeObserver(cardFrameObserver)
        }
        observedCardView = view
        view.postsFrameChangedNotifications = true
        cardFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.relayoutIfVisible()
        }
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
        if let cardFrameObserver {
            NotificationCenter.default.removeObserver(cardFrameObserver)
        }
        cardFrameObserver = nil
        observedCardView = nil
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
                    // The window is wider than the card: a click in the
                    // control gutter that misses a button is a click on the
                    // page around the peek, and closes it like any other.
                    if self.isPointOnPanelContent(screenPoint: location) {
                        return event
                    }
                    self.closeHostedPeek()
                    return nil
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

    /// Whether a screen point lands on the card (page included) or on one of
    /// the controls, as opposed to the empty strip around them.
    private func isPointOnPanelContent(screenPoint: NSPoint) -> Bool {
        let inWindow = panel.convertPoint(fromScreen: screenPoint)
        let inRoot = rootView.convert(inWindow, from: nil)
        guard let hit = rootView.hitTest(inRoot) else { return false }
        return hit !== rootView
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
