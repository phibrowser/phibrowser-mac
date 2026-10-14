// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit

/// Reader overlay hosted in the main browser window, above the page and
/// below the floating sidebar. Each overlay belongs to its origin tab;
/// switching tabs hides or replaces its content without closing that tab.
/// Presentation only: BrowserState owns the overlay tab's lifecycle.
final class ReaderPanelController {
    /// Opaque backing matching the page pane's rounded corners, so the
    /// full-pane cover reads as the pane itself switching to the reader
    /// rather than a card floating over it.
    private final class ReaderContainerView: PageOverlayView {
        /// Above Peek: a reader can cover a peek's card.
        override var stackingRank: Int { 1 }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
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

    /// The rounded card a reader covers: edge to edge, or `inset` inside
    /// it to leave room for what the card draws at its edge (a split pane's
    /// focus ring).
    struct Card {
        let view: NSView
        let cornerRadius: CGFloat
        var inset: CGFloat = 0
    }

    private weak var browserState: BrowserState?
    private weak var parentWindow: NSWindow?
    /// The web-content container view; geometry-observation anchor and the
    /// sizing fallback while no tab content is mounted.
    private weak var anchorView: NSView?
    /// Resolves the card the hosted reader covers: its origin's rounded page
    /// card, or the peek card when the origin is a peek's page. A closure
    /// because those views belong to whichever `WebContentViewController` is
    /// displayed, or to the peek panel.
    private let cardViewProvider: (Tab) -> Card?
    private let containerView = ReaderContainerView()
    private weak var hostedTab: Tab?
    private var eventMonitor: Any?
    private var parentResizeObserver: NSObjectProtocol?
    private var anchorFrameObserver: NSObjectProtocol?
    /// Frame observation of the card itself: the card can move without the
    /// container or window resizing (AI Chat dock, layout-mode insets).
    private var cardFrameObserver: NSObjectProtocol?
    private weak var observedCardView: NSView?
    /// See `setConcealedByInWindowOverlay`.
    private var isConcealedByInWindowOverlay = false
    /// See `setEclipsedByInWindowOverlay`.
    private var isEclipsedByInWindowOverlay = false

    init(browserState: BrowserState,
         parentWindow: NSWindow,
         anchorView: NSView,
         cardViewProvider: @escaping (Tab) -> Card?) {
        self.browserState = browserState
        self.parentWindow = parentWindow
        self.anchorView = anchorView
        self.cardViewProvider = cardViewProvider
        anchorView.postsFrameChangedNotifications = true
    }

    deinit {
        removeEventMonitor()
        removeGeometryObservers()
        containerView.removeFromSuperview()
    }

    // MARK: - Presentation

    /// - Parameter focusContent: whether the reader takes keyboard focus —
    ///   true for the reader over the focused page, false for a split
    ///   partner's reader re-shown beside it.
    func present(tab: Tab, focusContent: Bool = true) {
        guard let browserState else { return }

        // Re-focus of the origin tab with the same reader still mounted:
        // just reveal — the panel is coming back from a tab switch.
        if hostedTab === tab, !containerView.subviews.isEmpty {
            reveal(focusContent: focusContent)
            return
        }

        guard let webView = tab.webContentView else {
            // Without a native view there is nothing to host — degrade to a
            // regular tab instead of showing an empty panel.
            AppLogWarn("📖 [ReaderOverlay] tab \(tab.guid) has no webContentView — expanding into a tab")
            browserState.expandReaderOverlayIntoTab(readerTabId: tab.guid)
            return
        }

        detachHostedContent()
        hostedTab = tab

        containerView.addSubview(webView)
        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        PageOverlayDevToolsDock.mount(tab, in: containerView)

        reveal(focusContent: focusContent)
    }

    /// Dock area for `tab`'s DevTools: the panel while it hosts the tab, nil
    /// otherwise (the dock state then waits on the `Tab` until `present`
    /// mounts it).
    func devToolsHost(for tab: Tab) -> NSView? {
        hostedTab === tab ? containerView : nil
    }

    /// Temporarily hides the panel while the origin tab is not focused. The
    /// hosted content stays alive; `present(tab:)` reveals again.
    func hide() {
        removeEventMonitor()
        containerView.removeFromSuperview()
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

    /// Un-conceal path: the hosted reader may have closed, or the focused
    /// tab may have changed, while the overlay was up — only come back when
    /// this panel's content is still the focused origin's reader.
    private func revealIfStillCurrent() {
        guard let tab = hostedTab,
              let browserState,
              browserState.visibleReaderOverlays(focusingTab: browserState.focusingTab)
                .contains(where: { $0 === tab }) else {
            return
        }
        reveal(focusContent: browserState.readerOverlayTakesFocus(tab))
    }

    /// Idempotent teardown of the panel. Never closes the tab itself — that
    /// is `BrowserState`'s job (`closeReaderOverlay`) or Chromium's (window
    /// teardown).
    func dismiss() {
        let restoreFocus = containerView.containsFirstResponder
        removeEventMonitor()
        removeGeometryObservers()
        containerView.removeFromSuperview()
        detachHostedContent()
        // Back to the page the reader stood over: the focused tab's, or the
        // peek in front of it.
        let pageTab = browserState?.focusingTab.map {
            browserState?.visiblePeek(focusingTab: $0)?.tab ?? $0
        }
        if restoreFocus, let page = pageTab?.webContentView,
           page.window === parentWindow {
            parentWindow?.makeFirstResponder(page)
            pageTab?.webContentWrapper?.focus()
        }
    }

    /// Detach before the closing WebContents goes away, including releasing
    /// its first responder. The later state-driven dismiss is idempotent.
    func detachContentIfHosting(tabId: Int) {
        guard hostedTab?.guid == tabId else { return }
        dismiss()
    }

    // MARK: - Internals

    /// Closes the reader the panel is currently hosting (the focused
    /// origin's).
    private func closeHostedReader() {
        guard let tab = hostedTab else { return }
        browserState?.closeReaderOverlay(readerTabId: tab.guid)
    }

    private func reveal(focusContent: Bool) {
        guard !isConcealedByInWindowOverlay,
              let parentWindow, anchorView?.window === parentWindow,
              let content = browserState?.windowController?.mainSplitViewController
                .webContentContainerViewController else { return }
        content.installPageOverlay(containerView)
        layoutOnAnchor()
        containerView.isHidden = false
        // The page, not `subviews.first` — docked DevTools sits below it.
        if focusContent, !isEclipsedByInWindowOverlay,
           let webView = hostedTab?.webContentView, webView.superview === containerView {
            parentWindow.makeKey()
            parentWindow.makeFirstResponder(webView)
            hostedTab?.webContentWrapper?.focus()
        }
        installEventMonitorIfNeeded()
        installGeometryObserversIfNeeded()
    }

    private func detachHostedContent() {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        hostedTab = nil
    }

    /// Screen rect of the page card the panel covers: the focused tab's
    /// rounded page card when one is mounted, else the whole container as a
    /// degraded fallback (the card excludes the window margins and the tab
    /// strip, which the panel must leave visible).
    private func paneScreenRect() -> NSRect? {
        let card = hostedTab.flatMap(cardViewProvider)
        containerView.layer?.cornerRadius = card?.cornerRadius
            ?? LiquidGlassCompatible.webContentContainerCornerRadius
        let target = card?.view ?? anchorView
        guard let target, let window = target.window else { return nil }
        refreshCardFrameObserverIfNeeded(for: target)
        let inWindow = target.convert(target.bounds, to: nil)
        let inset = card?.inset ?? 0
        return window.convertToScreen(inWindow).insetBy(dx: inset, dy: inset)
    }

    private func layoutOnAnchor() {
        guard let paneRect = paneScreenRect() else { return }
        // The whole card, edge to edge — the reader stands in for the page.
        containerView.setScreenFrame(paneRect)
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

    /// Re-fits the panel to its card; the window controller calls this when
    /// a card moves without any frame change the panel observes (a peek card
    /// relaid inside its own overlay).
    func relayoutIfVisible() {
        guard containerView.isPresented else { return }
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

    /// A click on a split pane's reader focuses that pane, as a click on the
    /// pane itself does (`SplitPaneHostView.onPaneInteraction`) — the reader
    /// sits above the split host, which so never sees it. The address bar
    /// and the focus ring follow the focused tab.
    private func activateOriginPaneIfClicked(_ event: NSEvent) {
        guard containerView.isPresented,
              let window = parentWindow, event.window === window,
              let hitView = window.contentView?.hitTest(event.locationInWindow),
              hitView.isDescendant(of: containerView),
              let readerTab = hostedTab, let browserState,
              let originTabId = browserState.readerOverlayState.originTabId(forReaderTabId: readerTab.guid),
              let origin = browserState.tabs.first(where: { $0.guid == originTabId }),
              !origin.isActive else { return }
        origin.makeSelfActive()
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown {
                self.activateOriginPaneIfClicked(event)
                return event
            }
            guard self.containerView.isPresented,
                  !self.isEclipsedByInWindowOverlay,
                  event.window === self.parentWindow,
                  self.parentWindow?.isKeyWindow == true,
                  self.containerView.containsFirstResponder else { return event }
            // Cmd-W must be swallowed here: strip-active is the origin while
            // the overlay is up, so letting it reach Chromium's
            // IDC_CLOSE_TAB would close the origin.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "w" {
                self.closeHostedReader()
                return nil
            }
            // Docked DevTools owns its keys: Esc toggles its console drawer
            // and Cmd-[ / Cmd-] switch its panels.
            if PageOverlayDevToolsDock.hasFocus(self.hostedTab) {
                return event
            }
            // Esc closes the reader.
            if event.keyCode == 53 {
                self.closeHostedReader()
                return nil
            }
            // The reader's web view holds focus while the overlay is active, so
            // handle its closing shortcuts before Chromium or the main menu
            // interprets them as commands for the origin tab:
            // - Toggle Reader View itself: the same press that opened the
            //   reader must close it.
            // - Back/Forward read as "leave the reader" — matching the
            //   in-place reader, where back left the reading surface.
            if let eventKeys = ShortcutsKey.eventKeys(for: event) {
                let closeKeys = [Shortcuts.key(for: .PHI_TOGGLE_READER),
                                 Shortcuts.key(for: .IDC_BACK),
                                 Shortcuts.key(for: .IDC_FORWARD)].compactMap { $0 }
                if eventKeys.matchingKeys.contains(where: closeKeys.contains) {
                    self.closeHostedReader()
                    return nil
                }
                // Focus Address Bar targets the origin — open the omnibox
                // (the panel then steps aside for it, see
                // setConcealedByInWindowOverlay).
                if let focusLocationKey = Shortcuts.key(for: .IDC_FOCUS_LOCATION),
                   eventKeys.matchingKeys.contains(focusLocationKey) {
                    self.browserState?.windowController?.openLocationBar(nil)
                    return nil
                }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
    }
}
