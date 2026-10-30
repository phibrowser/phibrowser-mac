// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// Peek overlay hosted in the main browser window, above the page and
/// below the floating sidebar. Each overlay belongs to its origin tab;
/// switching tabs hides or replaces its content without closing that tab.
/// Presentation only: BrowserState owns the overlay tab's lifecycle.
final class PeekPanelController {
    /// Rounded opaque backing for the card, and what casts its shadow. A
    /// plain layer-backed view instead of NSVisualEffectView: the effect
    /// view's behind-window backdrop is composited by the window server and
    /// ignores `layer.cornerRadius`, which left the panel corners square.
    ///
    /// Deliberately unclipped — `masksToBounds` would clip the layer's own
    /// shadow away, so the rounding of the page itself is `webHostView`'s job
    /// and this view only draws the card's background beneath it.
    ///
    /// The shadow is the view-level `NSView.shadow`, NOT `layer.shadow*`:
    /// AppKit owns a backing layer's shadow properties and re-asserts the
    /// view's (nil) shadow onto them when the view joins a superview —
    /// values written straight to the layer are silently zeroed there
    /// (macOS 26). A non-nil view shadow also keeps AppKit from adopting
    /// `clipsToBounds = true` when the appear flight writes
    /// `layer.cornerRadius`, which would clip the shadow just the same.
    private final class PeekContainerView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = false
            updateShadow()
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
            updateShadow()
            updateBackground()
        }

        /// A soft black shadow all but disappears against dark pages, so the
        /// dark appearance gets a denser one.
        private func updateShadow() {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let cardShadow = NSShadow()
            cardShadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.6 : 0.44)
            // Leave room for the blur to fade within the shadow margins, including
            // the downward offset, before the panel clips it.
            cardShadow.shadowBlurRadius = 8
            cardShadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow = cardShadow
        }

        private func updateBackground() {
            // Layers don't track appearance changes; resolve the dynamic
            // color under the current effective appearance before assigning.
            effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
                layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
    }

    /// Hosts the peek's page and its docked DevTools, without the vibrancy
    /// filter that would wash them out (`PageOverlayVibrancySuppressor`).
    private final class PeekWebHostView: NSView {
        private let vibrancySuppressor = PageOverlayVibrancySuppressor()

        override func didAddSubview(_ subview: NSView) {
            super.didAddSubview(subview)
            vibrancySuppressor.didAddSubview(subview)
        }

        override func willRemoveSubview(_ subview: NSView) {
            vibrancySuppressor.willRemoveSubview(subview)
            super.willRemoveSubview(subview)
        }
    }

    /// Control button: a white glyph in dark appearance, otherwise accent-tinted.
    /// The chip is what makes it readable — the strip it sits in is
    /// transparent, so a bare glyph competes with whatever the page behind
    /// the peek happens to be showing there.
    private final class PeekControlButton: NSButton {
        /// Resolve the accent against the owning browser window's theme.
        weak var themeHostWindow: NSWindow?

        private var usesDarkAppearance: Bool {
            (themeHostWindow?.themeStateProvider ?? ThemeManager.shared).currentAppearance.isDark
        }

        private var isHovered = false {
            didSet { updateColors() }
        }
        private var hoverTrackingArea: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = PeekPanelController.controlCornerRadius
            layer?.cornerCurve = .continuous
            // Unclipped, so the chip's own shadow survives; `cornerRadius`
            // rounds the fill, and the glyph never reaches the corners.
            layer?.masksToBounds = false
            // Via `NSView.shadow`, not `layer.shadow*` — see
            // `PeekContainerView` for why direct layer writes don't survive.
            let chipShadow = NSShadow()
            chipShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            chipShadow.shadowBlurRadius = 4
            chipShadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow = chipShadow
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// AppKit gives a square-bezel button 2.5pt top / 1.5pt bottom
        /// alignment insets for a bezel this button never draws. Constraints
        /// size the alignment rect, so without this the frame — and the layer
        /// that paints the chip — came out 28×32 with the glyph riding high.
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

        /// Places the glyph by its ink, not by the symbol's alignment rect.
        /// `NSButtonCell` centres the alignment rect and rounds its origin
        /// down to whole points, which lands the wider symbols (the split and
        /// reader glyphs) half a point left of centre. The ink box is read
        /// once per image by rasterising it; the glyph is then drawn at a
        /// half-point-snapped origin so it stays pixel-aligned on 2x.
        private final class Cell: NSButtonCell {
            /// Vertical nudge of the ink centre from the chip centre, in
            /// points, should the chip ever want optical rather than exact
            /// centring. Exact centring was judged right against the shadow.
            static let opticalDrop: CGFloat = 0

            private var inkCache: [ObjectIdentifier: NSRect] = [:]

            override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
                let ink = inkRect(of: image)
                let bounds = controlView.bounds
                // The control is flipped: +y is down.
                let target = CGPoint(x: bounds.midX, y: bounds.midY + Self.opticalDrop)
                let inkCentreFromTop = image.size.height - ink.midY
                func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
                let origin = CGPoint(x: snap(target.x - ink.midX), y: snap(target.y - inkCentreFromTop))
                let tint = (controlView as? NSButton)?.contentTintColor ?? .labelColor
                let keepsWhiteGlyph = (controlView as? PeekControlButton)?.usesDarkAppearance == true
                let color = isHighlighted && !keepsWhiteGlyph
                    ? (tint.blended(withFraction: 0.3, of: .black) ?? tint) : tint
                let config = image.symbolConfiguration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                let tinted = image.withSymbolConfiguration(config) ?? image
                tinted.draw(in: NSRect(origin: origin, size: image.size), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            /// Bounding box of the image's opaque pixels, in image points with
            /// a bottom-left origin. Falls back to the whole image.
            private func inkRect(of image: NSImage) -> NSRect {
                if let cached = inkCache[ObjectIdentifier(image)] { return cached }
                let scale: CGFloat = 2
                let width = Int((image.size.width * scale).rounded(.up))
                let height = Int((image.size.height * scale).rounded(.up))
                var rect = NSRect(origin: .zero, size: image.size)
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = image.size
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    image.draw(in: NSRect(origin: .zero, size: image.size))
                    NSGraphicsContext.restoreGraphicsState()
                    var minX = width, minY = height, maxX = -1, maxY = -1
                    for y in 0..<height {
                        for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                            minX = min(minX, x); maxX = max(maxX, x)
                            minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                    if maxX >= 0 {
                        // The rep is top-down; image coordinates are bottom-up.
                        rect = NSRect(x: CGFloat(minX) / scale,
                                      y: CGFloat(height - 1 - maxY) / scale,
                                      width: CGFloat(maxX - minX + 1) / scale,
                                      height: CGFloat(maxY - minY + 1) / scale)
                    }
                }
                inkCache[ObjectIdentifier(image)] = rect
                return rect
            }
        }

        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
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

        func resetInteractionState() {
            // Removing the panel during an action can skip mouseExited. The
            // controls are reused, so each presentation starts unhighlighted.
            isHovered = false
            highlight(false)
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        /// Re-resolves the glyph, chip and outline. Called on appearance changes and
        /// whenever the panel is revealed, so a theme switched between peeks
        /// is picked up.
        func updateColors() {
            let isDark = usesDarkAppearance
            let accent = (isHovered ? ThemedColor.themeColorOnHover : ThemedColor.themeColor)
                .resolve(in: themeHostWindow)
            contentTintColor = isDark ? .white : accent
            layer?.borderWidth = isDark ? 1 : 0
            layer?.borderColor = isDark
                ? NSColor.white.withAlphaComponent(isHovered ? 0.28 : 0.2).cgColor : nil
            // The page card's own material, so a control reads as a chip of
            // the peek rather than as part of the page underneath it.
            let chip = ThemedColor.contentOverlayBackground.resolve(in: themeHostWindow)
            layer?.backgroundColor = (isHovered
                ? chip.blended(withFraction: 0.14, of: accent) ?? chip
                : chip).cgColor
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
            clipsToBounds = false
            layer?.masksToBounds = false
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
    private static let minPaneInset: CGFloat = 24
    private static let paneVerticalInset: CGFloat = 0
    static let cornerRadius: CGFloat = 12

    /// The card carries no chrome of its own (Arc's peek layout): the page
    /// fills it edge to edge and the controls live in a transparent strip the
    /// panel window keeps to the card's right, over the page pane.
    private static let controlGutterWidth: CGFloat = 48
    private static let controlButtonSize: CGFloat = 32
    private static let controlCornerRadius: CGFloat = 8
    private static let controlSpacing: CGFloat = 6
    private static let controlTopInset: CGFloat = 6

    /// Margins position the card and controls without changing the page inset.
    /// The root remains unclipped so shadows can extend beyond these margins.
    private static let shadowMargin: CGFloat = 24
    private static let verticalShadowMargin = min(shadowMargin, paneVerticalInset)

    /// Width of the card the panel grows out of — link-sized, so the flight
    /// reads as "that link became this panel".
    private static let flightStartWidth: CGFloat = 44
    private static let flightDuration: TimeInterval = 0.2

    private final class TransitionView: PageOverlayView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

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
    /// Transparent content view spanning card + control gutter.
    private let rootView = PageOverlayView()
    private let containerView = PeekContainerView()
    private let controlColumn = PeekControlColumnView()
    private let webHostView = PeekWebHostView()
    // Peek shares its parent's window ID but owns its visible toast lifecycle.
    private let toastCenter = OverlayToastCenter()
    private let toastViewController: OverlayToastViewController
    private weak var hostedTab: Tab?
    /// Top-down order of the control column; hidden buttons leave no gap
    /// (`restackControlButtons`).
    private var controlButtons: [NSButton] = []
    /// Shown while the hosted page is readable or already has a reader up
    /// (so the same button closes it).
    private weak var readerButton: NSButton?
    private var controlVisibility: AnyCancellable?
    /// Fires after every relayout: a reader covering the card has to follow
    /// it, and a card moved inside the overlay posts no frame change.
    var onLayout: (() -> Void)?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    /// Frame observation of the card itself: the card can move without the
    /// container or window resizing (AI Chat dock, layout-mode insets).
    private var cardFrameObserver: NSObjectProtocol?
    private weak var observedCardView: NSView?
    private weak var backgroundContentController: WebContentContainerViewController?
    /// True between an appear flight's start and its landing; keeps the
    /// landing idempotent across the completion block and the teardown paths.
    private var isFlying = false
    /// The armed flight's start transform, held between `armAppearFlight`
    /// (before the overlay is revealed) and `runAppearFlight` (once it is on
    /// screen). Non-nil only inside that gap.
    private var pendingFlightStart: CATransform3D?
    private var appearanceOriginScreenPoint: CGPoint?
    private var transitionView: TransitionView?
    private var expandingTabId: Int?
    /// See `setConcealedByInWindowOverlay`.
    private var isConcealedByInWindowOverlay = false
    /// See `setEclipsedByInWindowOverlay`.
    private var isEclipsedByInWindowOverlay = false

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
        toastViewController = OverlayToastViewController(
            state: browserState, toastCenter: toastCenter, isPanel: true)
        anchorView.postsFrameChangedNotifications = true

        rootView.clipsToBounds = false
        rootView.layer?.masksToBounds = false
        rootView.addSubview(containerView)
        containerView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(Self.verticalShadowMargin)
            make.leading.equalToSuperview().inset(Self.shadowMargin)
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

        containerView.addSubview(toastViewController.view)
        toastViewController.view.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    deinit {
        transitionView?.removeFromSuperview()
        backgroundContentController?.setPeekBackgroundDeemphasized(false, animated: false)
        removeEventMonitor()
        removeGeometryObservers()
        rootView.removeFromSuperview()
    }

    // MARK: - Presentation

    /// - Parameter flyIn: whether this peek is one the user just opened, and
    ///   so may fly out of the press that opened it. Only the window
    ///   controller can tell — mounting content here happens both for a fresh
    ///   peek and for switching to another opener's existing one.
    func present(tab: Tab, flyIn: Bool) {
        guard let browserState else { return }
        cancelTransition()

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
        PageOverlayDevToolsDock.mount(tab, in: webHostView)
        bindControlVisibility(to: tab, in: browserState)

        reveal(focusContent: true, flyIn: flyIn)
    }

    /// The page card, for a reader opened over the hosted page to cover.
    var pageCardView: NSView { containerView }

    func isHosting(_ tab: Tab) -> Bool {
        hostedTab === tab
    }

    /// Dock area for `tab`'s DevTools: the page card while this panel hosts
    /// the tab, nil otherwise (the dock state then waits on the `Tab` until
    /// `present` mounts it).
    func devToolsHost(for tab: Tab) -> NSView? {
        hostedTab === tab ? webHostView : nil
    }

    /// Temporarily hides the panel while the opener tab is not focused. The
    /// hosted content and bindings stay alive; `present(tab:)` reveals again.
    func hide() {
        if let expandingTabId, browserState?.focusingTab?.guid == expandingTabId { return }
        cancelTransition()
        backgroundContentController?.setPeekBackgroundDeemphasized(false, animated: false)
        toastCenter.clearWindow(windowId: toastViewController.state.windowId)
        landAppearFlight()
        removeEventMonitor()
        rootView.removeFromSuperview()
        setHostedPeekPresented(false)
    }

    /// Chromium's page commands (Reload, Stop, Zoom, Print, Save Page, View
    /// Source, DevTools, Find) act on the presented peek instead of the
    /// strip-active opener behind it, mirroring `BrowserState
    /// .pageCommandTarget` on the native side. Tracks the panel being on
    /// screen with `hostedTab`'s page: set on reveal, cleared on hide and
    /// detach. An eclipsing omnibox leaves the page visible, so it keeps the
    /// bit; tab search conceals the panel through `hide()`, so it drops it.
    private func setHostedPeekPresented(_ presented: Bool) {
        guard let wrapper = hostedTab?.webContentWrapper,
              wrapper.responds(to: #selector(WebContentWrapper.updateIsPeekPresented(_:))) else {
            return
        }
        wrapper.updateIsPeekPresented(presented)
    }

    /// The omnibox keeps keyboard ownership while the page remains visible.
    func setEclipsedByInWindowOverlay(_ eclipsed: Bool) {
        guard isEclipsedByInWindowOverlay != eclipsed else { return }
        isEclipsedByInWindowOverlay = eclipsed
        if !eclipsed { revealIfStillCurrent() }
    }

    /// Tab search temporarily exposes the origin page beneath the overlay.
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
              browserState.visiblePeek(focusingTab: browserState.focusingTab)?.tab === tab else {
            return
        }
        reveal(focusContent: true, flyIn: false)
    }

    /// Idempotent teardown of the panel. Never closes the tab itself — that
    /// is `BrowserState`'s job (`closePeek`) or Chromium's (window teardown).
    func dismiss() {
        // Keep the live page in this window until the normal page host has
        // adopted it. Removing the overlay first makes Chromium hide it.
        if let expandingTabId {
            if browserState?.focusingTab?.guid == expandingTabId { return }
            cancelTransition()
        }
        if let tabId = hostedTab?.guid { prepareToClose(tabId: tabId) }
        backgroundContentController?.setPeekBackgroundDeemphasized(false, animated: true)
        let restoreFocus = rootView.containsFirstResponder
        removeEventMonitor()
        removeGeometryObservers()
        rootView.removeFromSuperview()
        detachHostedContent()
        if restoreFocus, let page = browserState?.focusingTab?.webContentView,
           page.window === parentWindow {
            parentWindow?.makeFirstResponder(page)
            browserState?.focusingTab?.webContentWrapper?.focus()
        }
    }

    /// Detach before the closing WebContents goes away, including releasing
    /// its first responder. The later state-driven dismiss is idempotent.
    func detachContentIfHosting(tabId: Int) {
        guard hostedTab?.guid == tabId else { return }
        dismiss()
    }

    @discardableResult
    func showToast(id: UUID, message: String, shareURLs: [URL], duration: TimeInterval, tabId: Int) -> Bool {
        guard rootView.isPresented, hostedTab?.guid == tabId else { return false }
        return toastCenter.show(
            title: message, duration: duration, placement: .topTrailing,
            shareURLs: shareURLs, in: .windowId(toastViewController.state.windowId), id: id) != nil
    }

    func dismissToast(id: UUID) {
        toastCenter.dismiss(id: id)
    }

    func showHighlightLinkCopyConfirmation(url: URL, tabId: Int) {
        guard rootView.isPresented, hostedTab?.guid == tabId else { return }
        toastCenter.showHighlightLinkCopyConfirmation(url: url, in: toastViewController.state)
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

    @objc private func readerButtonClicked(_ sender: Any?) {
        guard let tab = hostedTab, let browserState else { return }
        MainActor.assumeIsolated {
            browserState.toggleReaderView(for: tab, from: .peekPanel)
        }
    }

    private func bindControlVisibility(to tab: Tab, in browserState: BrowserState) {
        // The id, not the tab: a hidden panel keeps this subscription, and
        // must not keep a closed peek's Tab alive with it.
        let tabId = tab.guid
        controlVisibility = tab.$isReaderOfferable
            .combineLatest(browserState.readerOverlayState.$readersByOrigin)
            .map { offerable, readers in offerable || readers[tabId] != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shown in
                self?.setReaderButtonShown(shown)
            }
    }

    private func setReaderButtonShown(_ shown: Bool) {
        readerButton?.isHidden = !shown
        restackControlButtons()
    }

    /// Chains the visible control buttons top-down: a hidden button leaves
    /// the chain rather than a gap in the column.
    private func restackControlButtons() {
        var previous: NSView?
        for button in controlButtons {
            guard !button.isHidden else {
                button.snp.removeConstraints()
                continue
            }
            button.snp.remakeConstraints { make in
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

    /// Closes the peek the panel is currently hosting (the focused opener's).
    private func closeHostedPeek() {
        guard let tab = hostedTab else { return }
        browserState?.closePeek(peekTabId: tab.guid)
    }

    // MARK: - Internals

    private func reveal(focusContent: Bool, flyIn: Bool) {
        guard !isConcealedByInWindowOverlay,
              let parentWindow, anchorView?.window === parentWindow,
              let content = browserState?.windowController?.mainSplitViewController
                .webContentContainerViewController else { return }
        content.installPageOverlay(rootView)
        refreshControlTints()
        layoutOnAnchor()
        backgroundContentController = content
        content.setPeekBackgroundDeemphasized(true, animated: true)
        if flyIn { armAppearFlight() }
        rootView.isHidden = false
        setHostedPeekPresented(true)
        runAppearFlight()
        // The page, not `subviews.first` — docked DevTools sits below it.
        if focusContent, !isEclipsedByInWindowOverlay,
           let webView = hostedTab?.webContentView, webView.superview === webHostView {
            parentWindow.makeKey()
            parentWindow.makeFirstResponder(webView)
            hostedTab?.webContentWrapper?.focus()
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    /// Clear interaction state from the previous presentation and re-apply
    /// the theme, which can change while no peek is up.
    private func refreshControlTints() {
        for button in controlColumn.subviews.compactMap({ $0 as? PeekControlButton }) {
            button.resetInteractionState()
        }
    }

    private func detachHostedContent() {
        toastCenter.clearWindow(windowId: toastViewController.state.windowId)
        landAppearFlight()
        setHostedPeekPresented(false)
        webHostView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
        controlVisibility = nil
        setReaderButtonShown(false)
    }

    // MARK: - Presentation transitions

    /// Keep the page and its controls visible throughout the flight. Only the
    /// root's opacity and transform animate; card corners and clipping stay fixed.
    private func armAppearFlight() {
        appearanceOriginScreenPoint = originTracker?.consumeOrigin()
        guard let layer = rootView.layer else { return }
        let frame = rootView.screenFrame
        let origin = appearanceOriginScreenPoint ?? CGPoint(x: frame.midX, y: frame.midY)
        let width = appearanceOriginScreenPoint == nil ? frame.width * 0.97 : Self.flightStartWidth
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let start = Self.appearFlightTransform(originScreenPoint: origin,
                                                     cardScreenFrame: frame,
                                                     startWidth: width,
                                                     anchorPoint: layer.anchorPoint) else { return }
        isFlying = true
        pendingFlightStart = start
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = start
        rootView.alphaValue = 0
        CATransaction.commit()
    }

    private func runAppearFlight() {
        guard let start = pendingFlightStart, let layer = rootView.layer else { return }
        pendingFlightStart = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.landAppearFlight() }
        layer.transform = CATransform3DIdentity
        rootView.alphaValue = 1
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Self.flightDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "phiPeekAppearFlight")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.flightDuration
        fade.timingFunction = grow.timingFunction
        layer.add(fade, forKey: "phiPeekAppearFade")
        CATransaction.commit()
    }

    private func landAppearFlight() {
        guard isFlying else { return }
        isFlying = false
        pendingFlightStart = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootView.layer?.removeAnimation(forKey: "phiPeekAppearFlight")
        rootView.layer?.removeAnimation(forKey: "phiPeekAppearFade")
        rootView.layer?.transform = CATransform3DIdentity
        rootView.alphaValue = 1
        CATransaction.commit()
    }

    /// Snapshot before BrowserState destroys the page, so closing can run the
    /// reverse flight without retaining or delaying the WebContents lifecycle.
    func prepareToClose(tabId: Int) {
        guard hostedTab?.guid == tabId, expandingTabId == nil,
              transitionView == nil, let snapshot = snapshotOverlay(of: rootView),
              let layer = snapshot.layer else { return }
        transitionView = snapshot
        let frame = snapshot.screenFrame
        let origin = appearanceOriginScreenPoint ?? CGPoint(x: frame.midX, y: frame.midY)
        let width = appearanceOriginScreenPoint == nil ? frame.width * 0.97 : Self.flightStartWidth
        let end = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DIdentity
            : Self.appearFlightTransform(originScreenPoint: origin, cardScreenFrame: frame,
                                         startWidth: width, anchorPoint: layer.anchorPoint)
                ?? CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak snapshot] in
            guard let self, let snapshot, self.transitionView === snapshot else { return }
            snapshot.removeFromSuperview()
            self.transitionView = nil
        }
        layer.transform = end
        snapshot.alphaValue = 0
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: end)
        shrink.duration = Self.flightDuration
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(shrink, forKey: "phiPeekCloseFlight")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Self.flightDuration
        fade.timingFunction = shrink.timingFunction
        layer.add(fade, forKey: "phiPeekCloseFade")
        CATransaction.commit()
    }

    /// Install a painted cover before adoption. The live page stays mounted in
    /// the overlay until the normal tab host takes it, avoiding a hidden frame.
    func prepareToExpand(tabId: Int) {
        guard hostedTab?.guid == tabId, rootView.isPresented,
              let content = backgroundContentController else { return }
        cancelTransition()
        landAppearFlight()
        transitionView = snapshotOverlay(of: webHostView)
        expandingTabId = tabId
        content.setPeekBackgroundDeemphasized(false, animated: false)
        removeEventMonitor()
        removeGeometryObservers()
        setHostedPeekPresented(false)
        content.whenPageIsMounted(tabId: tabId) { [weak self] destination in
            guard let self, self.expandingTabId == tabId else { return }
            self.rootView.removeFromSuperview()
            self.detachHostedContent()
            self.animateExpansion(into: destination)
        }
    }

    private func animateExpansion(into destination: NSView) {
        guard let snapshot = transitionView, let layer = snapshot.layer,
              let window = destination.window, snapshot.window === window else {
            cancelTransition()
            return
        }
        let startFrame = snapshot.screenFrame
        let endFrame = window.convertToScreen(destination.convert(destination.bounds, to: nil))
        guard let start = Self.expansionTransform(from: startFrame, to: endFrame,
                                                  anchorPoint: layer.anchorPoint) else {
            cancelTransition()
            return
        }
        snapshot.setScreenFrame(endFrame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak snapshot] in
            // The destination has painted during the flight. Retire the cover
            // on the next main turn, after the mount transaction has committed.
            DispatchQueue.main.async {
                guard let self, let snapshot, self.transitionView === snapshot else { return }
                snapshot.removeFromSuperview()
                self.transitionView = nil
                self.expandingTabId = nil
            }
        }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                 ? CATransform3DIdentity : start)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = Self.flightDuration
        grow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(grow, forKey: "phiPeekExpandIntoTab")
        CATransaction.commit()
    }

    private func snapshotOverlay(of source: NSView) -> TransitionView? {
        guard rootView.isPresented, let content = backgroundContentController,
              let window = source.window,
              let image = WebContentSnapshotter.captureOnScreen(webHostView, resolution: .bestResolution) else { return nil }
        let snapshot = TransitionView()
        snapshot.clipsToBounds = false
        snapshot.layer?.masksToBounds = false
        content.installPageOverlay(snapshot)
        snapshot.setScreenFrame(window.convertToScreen(source.convert(source.bounds, to: nil)))
        // Window-server captures flatten transparent regions against the page
        // beneath Peek. Capture only the page, then rebuild its native chrome
        // on a transparent root so the background never joins the close flight.
        let pageFrame = source.convert(webHostView.bounds, from: webHostView)
        let card = PeekContainerView(frame: pageFrame)
        card.autoresizingMask = [.width, .height]
        snapshot.addSubview(card)
        let imageView = NSImageView(frame: card.bounds)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        card.addSubview(imageView)
        if source === rootView {
            for button in controlButtons where !button.isHidden {
                let control = PeekControlButton(frame: source.convert(button.bounds, from: button))
                control.bezelStyle = .regularSquare
                control.isBordered = false
                control.imagePosition = .imageOnly
                control.image = button.image
                control.isEnabled = button.isEnabled
                control.themeHostWindow = parentWindow
                control.updateColors()
                snapshot.addSubview(control)
            }
        }
        snapshot.isHidden = false
        return snapshot
    }

    private func cancelTransition() {
        if let expandingTabId { backgroundContentController?.cancelPageMountWait(tabId: expandingTabId) }
        expandingTabId = nil
        transitionView?.removeFromSuperview()
        transitionView = nil
    }

    /// Maps the destination's pixels onto the current Peek frame, independently
    /// of AppKit's backing-layer anchor. The animation then settles at identity.
    static func expansionTransform(from source: CGRect, to destination: CGRect,
                                   anchorPoint: CGPoint) -> CATransform3D? {
        guard source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0 else { return nil }
        let sx = source.width / destination.width
        let sy = source.height / destination.height
        let tx = source.minX - destination.minX + (sx - 1) * destination.width * anchorPoint.x
        let ty = source.minY - destination.minY + (sy - 1) * destination.height * anchorPoint.y
        return CATransform3DScale(CATransform3DMakeTranslation(tx, ty, 0), sx, sy, 1)
    }

    /// Shrinks toward the recorded press, compensating for AppKit's actual
    /// backing-layer anchor and clamping the small card inside the page region.
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
        // (the overlay root is unflipped), so the offset carries over
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
            make.top.equalToSuperview().inset(Self.verticalShadowMargin)
            make.trailing.equalToSuperview().inset(Self.shadowMargin)
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
        let expandTooltip = NSLocalizedString(
            "peek.panel.expandButtonTooltip",
            value: "Open as Tab",
            comment: "Peek popup panel - Tooltip of the button that converts the floating page preview into a regular tab"
        )
        let expandButton = makeControlButton(
            symbolName: "arrow.up.left.and.arrow.down.right",
            tooltip: expandTooltip,
            action: #selector(expandButtonClicked(_:))
        )
        MainActor.assumeIsolated {
            expandButton.setCustomTooltip {
                CommandShortcutTooltipContent(
                    title: expandTooltip,
                    command: .PHI_KIOSK_OPEN_IN_SPACE
                )
            }
        }
        let splitButton = makeControlButton(
            symbolName: "rectangle.split.2x1",
            tooltip: NSLocalizedString(
                "peek.panel.splitButtonTooltip",
                value: "Open as Split View",
                comment: "Peek popup panel - Tooltip of the button that pairs the floating page preview with its bound tab in a side-by-side split view"
            ),
            action: #selector(splitButtonClicked(_:))
        )
        let readerTooltip = NSLocalizedString(
            "peek.panel.readerButtonTooltip",
            value: "Reader View",
            comment: "Peek popup panel - Tooltip of the button that opens or closes Reader View for the page shown in the floating page preview"
        )
        let readerButton = makeControlButton(
            symbolName: "doc.plaintext",
            tooltip: readerTooltip,
            action: #selector(readerButtonClicked(_:))
        )
        MainActor.assumeIsolated {
            readerButton.setCustomTooltip {
                CommandShortcutTooltipContent(
                    title: readerTooltip,
                    command: .PHI_TOGGLE_READER
                )
            }
        }
        // Hidden until the page is readable.
        readerButton.isHidden = true
        self.readerButton = readerButton

        controlButtons = [closeButton, expandButton, splitButton, readerButton]
        controlButtons.forEach { controlColumn.addSubview($0) }
        restackControlButtons()
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
        // The overlay spans the card, the control gutter to its right, and the
        // shadow margin around the lot — the card view sits back inside it at
        // exactly the inset it had before there was a shadow, so the peek
        // keeps its place on the page. The gutter is taken out of the card's
        // own right margin; a margin too narrow to hold it narrows the card
        // instead of pushing the controls off the page pane.
        let maxX = min(card.maxX + Self.controlGutterWidth + Self.shadowMargin, cardRect.maxX)
        let originX = card.minX - Self.shadowMargin
        rootView.setScreenFrame(CGRect(x: originX,
                              y: card.minY - Self.verticalShadowMargin,
                              width: max(maxX - originX, Self.controlGutterWidth),
                              height: card.height + Self.verticalShadowMargin * 2))
        // Auto Layout has to catch up before the appear flight transforms the
        // card's layer: the scale is applied about the layer's OWN centre, so
        // a layer still carrying its pre-frame bounds would shrink about the
        // wrong point and fly out of the wrong place. `setScreenFrame` above
        // also completes that layout before the flight is armed.
        onLayout?()
    }

    /// Screen rect of the card alone: the overlay frame minus the shadow
    /// margin and the control gutter. Derived from the frame rather than read
    /// off the view so it is right before the first layout pass — the appear
    /// flight runs on the frame `layoutOnAnchor` has only just set.
    private var cardScreenRect: NSRect {
        var rect = rootView.screenFrame.insetBy(dx: Self.shadowMargin, dy: Self.verticalShadowMargin)
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
            // Recompute the overlay frame when the browser window resizes.
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
        guard rootView.isPresented else { return }
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

    /// Consumes only keys owned by this visible, focused overlay. Closing the
    /// preview must never pass the same Close Tab command to its opener.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, rootView.isPresented,
              !isEclipsedByInWindowOverlay,
              event.window === parentWindow, parentWindow?.isKeyWindow == true,
              rootView.containsFirstResponder else { return false }
        let eventKeys = ShortcutsKey.eventKeys(for: event)
        if eventKeys?.matches(Shortcuts.key(for: .IDC_CLOSE_TAB)) == true {
            closeHostedPeek()
            return true
        }
        // DevTools retains Escape and navigation unless the user explicitly
        // bound that key to Close Tab, which must still protect the opener.
        guard !PageOverlayDevToolsDock.hasFocus(hostedTab) else { return false }
        if event.keyCode == 53,
           event.modifierFlags.intersection(ShortcutsKey.supportedModifierFlags).isEmpty {
            closeHostedPeek()
            return true
        }
        guard let eventKeys else { return false }
        if NSApp.keyWindow === parentWindow,
           eventKeys.matches(Shortcuts.key(for: .PHI_KIOSK_OPEN_IN_SPACE)) {
            expandButtonClicked(nil)
            return true
        }
        if eventKeys.matches(Shortcuts.key(for: .IDC_BACK))
            || eventKeys.matches(Shortcuts.key(for: .IDC_FORWARD)) {
            closeHostedPeek()
            return true
        }
        return false
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.rootView.isPresented,
                  !self.isEclipsedByInWindowOverlay else { return event }
            switch event.type {
            case .keyDown:
                return self.handleKeyEquivalent(event) ? nil : event
            case .leftMouseDown, .rightMouseDown:
                // Only clicks on the page pane around the panel close the
                // peek (Arc behavior). Sidebar/toolbar clicks pass through so
                // the user can switch tabs — the peek then hides with its
                // opener instead of closing.
                let location = NSEvent.mouseLocation
                // A press in another child window floating over the pane —
                // the find bar Cmd-F opens for the peek — is aimed at that
                // window, not at the page around the peek.
                if event.window !== self.parentWindow {
                    return event
                }
                // The floating sidebar now shares this window. A click on it
                // must reach its controls even where it overlaps the peek.
                if let sidebar = self.browserState?.windowController?.mainSplitViewController
                    .webContentContainerViewController.floatingSidebarContainerView,
                   !sidebar.isHiddenOrHasHiddenAncestor,
                   sidebar.bounds.contains(sidebar.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                // Reader may have been opened above an existing peek. Only
                // the top page overlay should interpret clicks in its area.
                if let topOverlay = self.rootView.superview?.subviews.reversed()
                    .compactMap({ $0 as? PageOverlayView })
                    .first(where: { $0.isPresented && $0.screenFrame.contains(location) }),
                   topOverlay !== self.rootView {
                    return event
                }
                // A press in the resize corridor is grabbing the window's
                // resize handle, not clicking the page: it still flows
                // through `sendEvent`, and the pane runs flush against the
                // frame's edges, so an edge-grab landing a point inside the
                // frame would otherwise read as a dismiss click.
                if event.type == .leftMouseDown,
                   self.isResizeCorridorGrab(screenPoint: location) {
                    return event
                }
                if self.rootView.screenFrame.contains(location) {
                    // The overlay is wider than the card: a click in the
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

    /// Reach of the window's resize corridor on the frame's inside: AppKit's
    /// edge hot zone is about 4pt on each side of the frame line, held
    /// slightly wider here so a resize grab is never mistaken for a dismiss
    /// click. The cost is a hairline strip of page pane along the window
    /// edges that no longer dismisses the peek.
    private static let resizeCorridorWidth: CGFloat = 6

    /// Whether a press at `screenPoint` is grabbing the parent window's
    /// resize corridor — within `resizeCorridorWidth` of a resizable frame's
    /// edge — rather than clicking the page pane.
    private func isResizeCorridorGrab(screenPoint: NSPoint) -> Bool {
        guard let parentWindow,
              parentWindow.styleMask.contains(.resizable) else { return false }
        let inner = parentWindow.frame.insetBy(dx: Self.resizeCorridorWidth,
                                               dy: Self.resizeCorridorWidth)
        return !inner.contains(screenPoint)
    }

    /// Whether a screen point lands on the card (page included) or on one of
    /// the controls, as opposed to the empty strip around them.
    private func isPointOnPanelContent(screenPoint: NSPoint) -> Bool {
        guard let parentWindow, let superview = rootView.superview else { return false }
        let inWindow = parentWindow.convertPoint(fromScreen: screenPoint)
        let inSuperview = superview.convert(inWindow, from: nil)
        guard let hit = rootView.hitTest(inSuperview) else { return false }
        return hit !== rootView
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
